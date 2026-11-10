open! Core
open Hardcaml_workbench_protocol
module W = Workspace
module Host = Workspace_host
module T = Tile_presentation

(** This file contains only client presentation choices. In particular, neither
    registry/run state nor transient navigation belongs in this schema. *)
type tile_headers =
  { tile : W.Tile_id.t
  ; workspace : W.Workspace_id.t
  ; kind : string
  ; headers : bool
  }
[@@deriving sexp]

(** Schema 3 (WB-048): the remaining explicit per-tile appearance overrides. Absent fields
    inherit. Header stays in [tile_headers]; run reference and freshness never persist. *)
type tile_appearance =
  { tile : W.Tile_id.t
  ; workspace : W.Workspace_id.t
  ; kind : string
  ; title : bool option [@sexp.option]
  ; badge : T.Badge.t option [@sexp.option]
  ; hints : bool option [@sexp.option]
  ; frame : bool option [@sexp.option]
  ; padding : int option [@sexp.option]
  ; run_selector_rows : int option [@sexp.option]
  ; string_compression : bool option [@sexp.option]
  ; decimal_places : int option [@sexp.option]
  }
[@@deriving sexp]

type workspace_compression =
  { workspace : W.Workspace_id.t
  ; string_compression : bool
  }
[@@deriving sexp]

type t =
  { schema_version : int
  ; project_key : string
  ; appearance : Appearance.t
  ; layout_mode : Host.layout_mode
  ; chrome : bool
  ; main_hints : bool option [@sexp.option]
  ; palette_hints : bool option [@sexp.option]
  ; timing_preload : bool option [@sexp.option]
  ; quick_launch_view : bool option [@sexp.option]
  ; global_compression : bool option [@sexp.option]
  ; workspace_compression : workspace_compression list option [@sexp.option]
  ; session : W.Session_id.t option
  ; tile_headers : tile_headers list
  ; tile_appearance : tile_appearance list option [@sexp.option]
  }
[@@deriving sexp]

let path ~state_directory ~project_key =
  Filename.concat
    state_directory
    ("presentation-" ^ Plain_rpc.digest project_key ^ ".sexp")
;;

(* Schema 2 adds the independent main-window/palette hint choices (WB-019). Schema 1 files
   remain readable: they predate the choices, so both hint areas stay visible. Schema 3
   adds [tile_appearance] (WB-048); schema 1/2 files predate it, so those tiles inherit. *)
(* Schema 4 adds optional compression/precision. Schema 3 entries retain their explicit
   choices and inherit compact strings and three decimals for these absent fields. *)
(* Schema 5 adds the optional project Timing index preload policy. Schemas 1–4 inherit
   background-index; newly captured preferences always record the choice. *)
(* Schema 6 adds sparse project/global and session/workspace compression choices. *)
(* WB004 adds an optional quick-launch context-follow choice. Existing files inherit
   [true]; their stock layout/default migration is independent of this preference. *)
let schema_version = 6

let appearance_of_overrides (o : T.overrides) ~tile ~workspace ~kind =
  match T.persisted { o with header = None } with
  | overrides when T.equal_overrides overrides T.inherit_ -> None
  | _ ->
    Some
      { tile
      ; workspace
      ; kind
      ; title = o.title
      ; badge = o.badge
      ; hints = o.hints
      ; frame = o.frame
      ; padding = o.padding
      ; run_selector_rows = o.run_selector_rows
      ; string_compression = o.string_compression
      ; decimal_places = o.decimal_places
      }
;;

let capture ~project_key (host : Host.t) =
  { schema_version
  ; project_key
  ; appearance = host.appearance
  ; layout_mode = host.layout_mode
  ; chrome = host.chrome
  ; main_hints = Some host.main_hints
  ; palette_hints = Some host.palette_hints
  ; timing_preload = Some host.timing_preload
  ; quick_launch_view = Some host.quick_launch_view
  ; global_compression = host.presentation.string_compression
  ; workspace_compression =
      (let entries =
         Option.value_map host.registry ~default:[] ~f:(fun registry ->
           List.filter_map registry.workspaces ~f:(fun workspace ->
             List.Assoc.find
               host.workspace_presentation
               (W.Workspace_id.to_string workspace.id)
               ~equal:String.equal
             |> Option.bind ~f:(fun o -> o.string_compression)
             |> Option.map ~f:(fun string_compression ->
               { workspace = workspace.id; string_compression })))
       in
       if List.is_empty entries then None else Some entries)
  ; session = Option.map host.registry ~f:(fun registry -> registry.session_id)
  ; tile_headers =
      Option.value_map host.registry ~default:[] ~f:(fun registry ->
        (* Only explicit header overrides persist; absent tiles inherit policy. *)
        List.filter_map registry.tiles ~f:(fun tile ->
          Option.map (Host.local host tile.id).presentation.header ~f:(fun headers ->
            { tile = tile.id; workspace = tile.workspace; kind = tile.kind; headers })))
  ; tile_appearance =
      Some
        (Option.value_map host.registry ~default:[] ~f:(fun registry ->
           List.filter_map registry.tiles ~f:(fun tile ->
             appearance_of_overrides
               (Host.local host tile.id).presentation
               ~tile:tile.id
               ~workspace:tile.workspace
               ~kind:tile.kind)))
  }
;;

let decode ~project_key content =
  if String.length content > 64 * 1024
  then failwith "Terminal presentation preference size limit exceeded";
  let stored = t_of_sexp (Sexp.of_string content) in
  (match stored.schema_version, stored.main_hints, stored.palette_hints with
   | 1, None, None | (2 | 3 | 4 | 5 | 6), Some _, Some _ -> ()
   | (1 | 2 | 3 | 4 | 5 | 6), _, _ ->
     failwith "Terminal presentation hint fields do not match schema"
   | _ -> failwith "Unsupported terminal presentation preference schema");
  (match stored.schema_version, stored.tile_appearance with
   | (1 | 2), None | (3 | 4 | 5 | 6), Some _ -> ()
   | _ -> failwith "Terminal tile appearance fields do not match schema");
  let appearance = Option.value stored.tile_appearance ~default:[] in
  let workspaces = Option.value stored.workspace_compression ~default:[] in
  if stored.schema_version < 6
     && (Option.is_some stored.global_compression
         || Option.is_some stored.workspace_compression)
  then failwith "Compression scopes require schema 6";
  if List.length workspaces > 128
  then failwith "Too many workspace compression preferences";
  if List.contains_dup workspaces ~compare:(fun a b ->
       W.Workspace_id.compare a.workspace b.workspace)
  then failwith "Duplicate workspace compression preference";
  if not (String.equal stored.project_key project_key)
  then failwith "Terminal presentation preference project/environment mismatch";
  if Option.is_none stored.session
     && not
          (List.is_empty stored.tile_headers
           && List.is_empty appearance
           && List.is_empty workspaces)
  then failwith "Tile header preferences require a workspace session";
  let ids = List.map stored.tile_headers ~f:(fun tile -> W.Tile_id.to_string tile.tile) in
  if List.contains_dup ids ~compare:String.compare
  then failwith "Duplicate terminal tile header preference";
  let ids = List.map appearance ~f:(fun tile -> W.Tile_id.to_string tile.tile) in
  if List.contains_dup ids ~compare:String.compare
  then failwith "Duplicate terminal tile appearance preference";
  List.iter appearance ~f:(fun pref ->
    (* Only explicit choices are written; an all-absent entry is not a value we produce. *)
    if List.for_all
         ~f:Fn.id
         [ Option.is_none pref.title
         ; Option.is_none pref.badge
         ; Option.is_none pref.hints
         ; Option.is_none pref.frame
         ; Option.is_none pref.padding
         ; Option.is_none pref.run_selector_rows
         ; Option.is_none pref.string_compression
         ; Option.is_none pref.decimal_places
         ]
    then failwith "Empty terminal tile appearance preference";
    if Option.exists pref.decimal_places ~f:(fun n -> n < 0 || n > 9)
    then failwith "Terminal decimal places must be between 0 and 9";
    if Option.exists pref.padding ~f:(fun padding -> padding < 0)
    then failwith "Terminal tile padding preference must be non-negative";
    if Option.exists pref.run_selector_rows ~f:(fun rows -> rows < 1)
    then failwith "Terminal tile row-count preference must be positive");
  stored
;;

let encode t = Sexp.to_string_hum (sexp_of_t t) ^ "\n"

(** Applies every persisted per-tile field (header and appearance) from a matching
    session/tile/workspace/kind identity; anything unmatched inherits. Run reference and
    freshness are not stored and keep their current local value. *)
let apply_tiles t (host : Host.t) =
  match host.registry with
  | None -> host
  | Some registry ->
    let same_session =
      Option.equal W.Session_id.equal t.session (Some registry.session_id)
    in
    let host =
      List.fold registry.workspaces ~init:host ~f:(fun host workspace ->
        let value =
          if same_session
          then
            List.find (Option.value t.workspace_compression ~default:[]) ~f:(fun pref ->
              W.Workspace_id.equal pref.workspace workspace.id)
            |> Option.map ~f:(fun pref -> pref.string_compression)
          else None
        in
        Host.set_workspace_compression host workspace.id value)
    in
    List.fold registry.tiles ~init:host ~f:(fun host (tile : W.Tile.t) ->
      let matches pref_tile pref_workspace pref_kind =
        same_session
        && W.Tile_id.equal pref_tile tile.id
        && W.Workspace_id.equal pref_workspace tile.workspace
        && String.equal pref_kind tile.kind
      in
      let header =
        List.find t.tile_headers ~f:(fun (pref : tile_headers) ->
          matches pref.tile pref.workspace pref.kind)
        |> Option.map ~f:(fun pref -> pref.headers)
      in
      let appearance =
        Option.value t.tile_appearance ~default:[]
        |> List.find ~f:(fun (pref : tile_appearance) ->
          matches pref.tile pref.workspace pref.kind)
      in
      let get f = Option.bind appearance ~f in
      let local = Host.local host tile.id in
      Host.set_local
        host
        tile.id
        { local with
          presentation =
            { local.presentation with
              header
            ; title = get (fun pref -> pref.title)
            ; badge = get (fun pref -> pref.badge)
            ; hints = get (fun pref -> pref.hints)
            ; frame = get (fun pref -> pref.frame)
            ; padding = get (fun pref -> pref.padding)
            ; run_selector_rows = get (fun pref -> pref.run_selector_rows)
            ; string_compression = get (fun pref -> pref.string_compression)
            ; decimal_places = get (fun pref -> pref.decimal_places)
            }
        })
;;

let apply t (host : Host.t) =
  apply_tiles
    t
    { host with
      appearance = t.appearance
    ; layout_mode = t.layout_mode
    ; chrome = t.chrome
    ; main_hints = Option.value t.main_hints ~default:true
    ; palette_hints = Option.value t.palette_hints ~default:true
    ; timing_preload = Option.value t.timing_preload ~default:true
    ; quick_launch_view = Option.value t.quick_launch_view ~default:true
    ; presentation = { host.presentation with string_compression = t.global_compression }
    }
;;

(** Restoration is a one-shot handoff, not a policy replayed on every poll. Consume even a
    mismatching/empty registry: removed identities must not regain old preferences if
    their IDs are subsequently reused. *)
let receive pending host snapshot =
  let host = Host.receive host snapshot in
  Option.value_map pending ~default:host ~f:(fun saved -> apply_tiles saved host), None
;;

let%test_unit "preload schema migration and durable explicit policy" =
  let project_key = "preload/project" in
  let stored = capture ~project_key { Host.empty with timing_preload = false } in
  let restore stored = apply (decode ~project_key (encode stored)) Host.empty in
  assert (not (restore stored).timing_preload);
  List.iter [ 1; 2; 3; 4 ] ~f:(fun schema_version ->
    let legacy =
      { stored with
        schema_version
      ; timing_preload = None
      ; main_hints = (if schema_version = 1 then None else Some true)
      ; palette_hints = (if schema_version = 1 then None else Some true)
      ; tile_appearance = (if schema_version < 3 then None else Some [])
      }
    in
    assert (restore legacy).timing_preload);
  assert (restore { stored with timing_preload = Some true }).timing_preload
;;

let%test_unit "quick launch legacy preferences default to view and explicit no-view \
               round trips"
  =
  let project_key = "quick-launch/project" in
  let stored = capture ~project_key { Host.empty with quick_launch_view = false } in
  let restore stored = apply (decode ~project_key (encode stored)) Host.empty in
  assert (not (restore stored).quick_launch_view);
  assert (restore { stored with quick_launch_view = None }).quick_launch_view;
  assert (restore { stored with quick_launch_view = Some true }).quick_launch_view
;;

let%test_unit "compression scope round trips, guards, sparse resets and schema 5 preload" =
  let registry = W.initial ~session_id:(W.Session_id.of_string "compression-scopes") in
  let tile = List.hd_exn registry.tiles in
  let base = Host.receive Host.empty registry in
  let round_trip host snapshot =
    let saved =
      decode ~project_key:"scopes" (encode (capture ~project_key:"scopes" host))
    in
    saved, apply saved (Host.receive Host.empty snapshot)
  in
  let choices = [ None; Some true; Some false ] in
  List.iter choices ~f:(fun global ->
    List.iter choices ~f:(fun workspace ->
      List.iter choices ~f:(fun tile_choice ->
        let host = Host.set_global_compression base global in
        let host = Host.set_workspace_compression host tile.workspace workspace in
        let overrides =
          { T.inherit_ with
            string_compression = tile_choice
          ; decimal_places = Some 8
          ; hints = Some false
          ; frame = Some false
          }
        in
        let host, _ = Host.set_presentation host tile.id overrides in
        let expected =
          Option.first_some tile_choice (Option.first_some workspace global)
          |> Option.value ~default:true
        in
        let saved, restored = round_trip host registry in
        assert (Bool.equal (Host.policy restored tile).string_compression expected);
        assert ((Host.policy restored tile).decimal_places = 8);
        assert (Option.equal Bool.equal restored.presentation.string_compression global);
        let command =
          Host.catalog restored ~project:None ~jobs:[]
          |> List.find_exn ~f:(fun c ->
            String.equal c.id "tile.presentation.strings.reset")
        in
        let reset =
          match command.action with
          | Set_presentation (id, o) -> fst (Host.set_presentation restored id o)
          | _ -> assert false
        in
        assert (
          T.equal_overrides
            (Host.local reset tile.id).presentation
            { overrides with string_compression = None });
        let reset =
          Host.set_workspace_compression reset tile.workspace None
          |> fun h -> Host.set_global_compression h None
        in
        let sparse, reset = round_trip reset registry in
        assert (Option.is_none sparse.global_compression);
        assert (Option.is_none sparse.workspace_compression);
        assert (Host.policy reset tile).string_compression;
        assert ((Host.policy reset tile).decimal_places = 8);
        assert (Option.equal W.Snapshot.equal host.registry base.registry);
        assert (Option.equal W.Tile_id.equal host.focus base.focus);
        assert (phys_equal host.planned_run base.planned_run);
        let renamed =
          { registry with
            workspaces =
              List.map registry.workspaces ~f:(fun w -> { w with name = "Renamed" })
          }
        in
        assert (
          Bool.equal
            (Host.policy (apply saved (Host.receive Host.empty renamed)) tile)
              .string_compression
            expected);
        let replaced =
          Host.receive
            restored
            { registry with session_id = W.Session_id.of_string "replacement" }
        in
        assert (List.is_empty replaced.workspace_presentation);
        assert (
          Option.is_none (Host.local replaced tile.id).presentation.string_compression);
        assert (
          Bool.equal
            (Host.policy replaced tile).string_compression
            (Option.value global ~default:true));
        let removed =
          Host.receive restored { registry with workspaces = []; tiles = [] }
        in
        let readded =
          Host.receive removed { registry with revision = registry.revision + 1 }
        in
        assert (List.is_empty readded.workspace_presentation);
        assert (
          Option.is_none (Host.local readded tile.id).presentation.string_compression);
        let absent, pending =
          receive
            (Some saved)
            (apply saved Host.empty)
            { registry with workspaces = []; tiles = [] }
        in
        let readded, _ = receive pending absent registry in
        assert (List.is_empty readded.workspace_presentation))));
  let saved = capture ~project_key:"scopes" { base with timing_preload = false } in
  let legacy = { saved with schema_version = 5 } in
  let migrated = decode ~project_key:"scopes" (encode legacy) in
  let restored = apply migrated base in
  assert (not restored.timing_preload);
  assert ((capture ~project_key:"scopes" restored).schema_version = 6);
  let pref = { workspace = tile.workspace; string_compression = false } in
  let rejects saved =
    assert (
      Result.is_error
        (Or_error.try_with (fun () -> decode ~project_key:"scopes" (encode saved))))
  in
  rejects { saved with workspace_compression = Some [ pref; pref ] };
  rejects { saved with session = None; workspace_compression = Some [ pref ] };
  rejects { saved with workspace_compression = Some (List.init 129 ~f:(fun _ -> pref)) };
  rejects { legacy with global_compression = Some false };
  List.iter [ -1; 10 ] ~f:(fun decimal_places ->
    let host, _ =
      Host.set_presentation
        base
        tile.id
        { T.inherit_ with decimal_places = Some decimal_places }
    in
    rejects (capture ~project_key:"scopes" host))
;;

(* Reads and writes run on the caller's I/O worker. Rename is in the same directory:
   readers see a complete old or new file, never a partial sexp. *)
let load ~state_directory ~project_key =
  let path = path ~state_directory ~project_key in
  match Sys_unix.file_exists path with
  | `No -> None
  | `Unknown -> failwith ("Cannot inspect terminal presentation preferences: " ^ path)
  | `Yes ->
    let size = (Core_unix.stat path).st_size in
    if Int64.(size > 65536L)
    then failwith "Terminal presentation preference size limit exceeded";
    Some (decode ~project_key (In_channel.read_all path))
;;

let save ~state_directory t =
  let data = encode t in
  (* Do not write a file that our reader would reject. *)
  ignore (decode ~project_key:t.project_key data : t);
  Core_unix.mkdir_p state_directory ~perm:0o700;
  let temp = Filename_unix.temp_file ~in_dir:state_directory ".presentation-" ".tmp" in
  Exn.protect
    ~finally:(fun () ->
      if Poly.equal (Sys_unix.file_exists temp) `Yes then Core_unix.unlink temp)
    ~f:(fun () ->
      Out_channel.write_all temp ~data;
      Core_unix.rename ~src:temp ~dst:(path ~state_directory ~project_key:t.project_key))
;;

let%test_unit "restart restores presentation, never navigation or daemon state" =
  let registry = W.initial ~session_id:(W.Session_id.of_string "retained-session") in
  let host = Host.receive Host.empty registry in
  let tile = List.hd_exn registry.tiles in
  let host =
    Host.set_local
      host
      tile.id
      { Host.default_local with
        presentation = { Host.default_local.presentation with header = Some false }
      ; filter = "temporary"
      ; scroll = 99
      }
  in
  let host =
    { host with
      appearance =
        { preset = Studio
        ; color = Restrained
        ; scheme = Slate
        ; icons = Unicode
        ; density = Comfortable
        }
    ; layout_mode = Preferred
    ; chrome = false
    ; focus = Some (List.last_exn registry.tiles).id
    }
  in
  let stored =
    decode ~project_key:"root/env" (encode (capture ~project_key:"root/env" host))
  in
  let refreshed = apply stored host in
  assert (String.equal (Host.local refreshed tile.id).filter "temporary");
  assert ((Host.local refreshed tile.id).scroll = 99);
  assert (Option.equal W.Tile_id.equal refreshed.focus host.focus);
  let restarted = apply stored (Host.receive Host.empty registry) in
  assert (Appearance.equal restarted.appearance host.appearance);
  assert (Host.equal_layout_mode restarted.layout_mode Preferred);
  assert (not restarted.chrome);
  assert (
    Option.equal
      Bool.equal
      (Host.local restarted tile.id).presentation.header
      (Some false));
  assert (String.is_empty (Host.local restarted tile.id).filter);
  assert ((Host.local restarted tile.id).scroll = 0);
  assert (Option.is_none restarted.palette);
  assert (Option.equal W.Tile_id.equal restarted.focus (Some tile.id));
  assert (Option.equal W.Snapshot.equal restarted.registry (Some registry));
  let encoded = encode stored in
  assert (not (String.is_substring encoded ~substring:"temporary"));
  let other_session =
    { registry with session_id = W.Session_id.of_string "replacement" }
  in
  let replaced = apply stored (Host.receive restarted other_session) in
  assert (Option.is_none (Host.local replaced tile.id).presentation.header);
  assert (Appearance.equal replaced.appearance host.appearance);
  let changed_kind =
    { registry with
      tiles = List.map registry.tiles ~f:(fun t -> { t with kind = "new-kind" })
    }
  in
  assert (
    Option.is_none
      (Host.local (apply stored (Host.receive Host.empty changed_kind)) tile.id)
        .presentation
        .header);
  let changed_workspace =
    { registry with
      tiles =
        List.map registry.tiles ~f:(fun tile ->
          { tile with workspace = W.Workspace_id.of_string "another-workspace" })
    }
  in
  assert (
    Option.is_none
      (Host.local (apply stored (Host.receive Host.empty changed_workspace)) tile.id)
        .presentation
        .header);
  let removed = apply stored (Host.receive Host.empty { registry with tiles = [] }) in
  assert (List.is_empty removed.locals)
;;

let%test_unit "strict schema validation and isolated identities" =
  let stored = capture ~project_key:"root/env" Host.empty in
  let rejects value =
    assert (
      Result.is_error (Or_error.try_with (fun () -> decode ~project_key:"root/env" value)))
  in
  rejects "(";
  rejects (encode { stored with schema_version = 7 });
  rejects (encode { stored with schema_version = 99 });
  rejects (encode { stored with main_hints = None });
  (* Schema 3 requires the appearance list; earlier schemas predate it. *)
  rejects (encode { stored with tile_appearance = None });
  rejects (encode { stored with schema_version = 2 });
  rejects (encode { stored with schema_version = 1 });
  rejects
    (String.substr_replace_first
       (encode stored)
       ~pattern:"(main_hints true)"
       ~with_:"(main_hints maybe)");
  rejects (encode { stored with project_key = "root/other-env" });
  rejects (String.make ((64 * 1024) + 1) ' ');
  rejects "((unknown true))";
  rejects
    (String.substr_replace_first
       (encode stored)
       ~pattern:"Instrument"
       ~with_:"Unknown_skin");
  rejects
    (String.substr_replace_first
       (encode stored)
       ~pattern:"(chrome true)"
       ~with_:"(chrome perhaps)");
  let pref =
    { tile = W.Tile_id.of_string "tile"
    ; workspace = W.Workspace_id.of_string "ws"
    ; kind = "log"
    ; headers = false
    }
  in
  rejects (encode { stored with tile_headers = [ pref ] });
  let look =
    { tile = W.Tile_id.of_string "tile"
    ; workspace = W.Workspace_id.of_string "ws"
    ; kind = "log"
    ; title = Some false
    ; badge = None
    ; hints = None
    ; frame = None
    ; padding = None
    ; run_selector_rows = None
    ; string_compression = None
    ; decimal_places = None
    }
  in
  let in_session = { stored with session = Some (W.Session_id.of_string "s") } in
  ignore
    (decode
       ~project_key:"root/env"
       (encode { in_session with tile_appearance = Some [ look ] })
     : t);
  rejects (encode { stored with tile_appearance = Some [ look ] });
  rejects (encode { in_session with tile_appearance = Some [ look; look ] });
  rejects
    (encode { in_session with tile_appearance = Some [ { look with title = None } ] });
  rejects
    (encode
       { in_session with tile_appearance = Some [ { look with padding = Some (-1) } ] });
  rejects
    (encode
       { in_session with
         tile_appearance = Some [ { look with run_selector_rows = Some 0 } ]
       });
  rejects
    (String.substr_replace_first
       (encode { in_session with tile_appearance = Some [ look ] })
       ~pattern:"(title false)"
       ~with_:"(title sometimes)");
  rejects
    (String.substr_replace_first
       (encode
          { in_session with tile_appearance = Some [ { look with badge = Some Always } ] })
       ~pattern:"Always"
       ~with_:"Sometimes");
  rejects (encode { in_session with schema_version = 2; tile_appearance = Some [ look ] });
  rejects
    (encode
       { stored with
         session = Some (W.Session_id.of_string "s")
       ; tile_headers = [ pref; pref ]
       });
  assert (
    not
      (String.equal
         (path ~state_directory:"state" ~project_key:"root/env")
         (path ~state_directory:"state" ~project_key:"root/other-env")));
  assert (
    not
      (String.equal
         (path ~state_directory:"state" ~project_key:"root/env")
         (Launch_preferences.path ~state_directory:"state" ~project_key:"root/env")))
;;

let%test_unit "catalog header/reset intent survives polling without replaying sparse \
               overrides"
  =
  let registry = W.initial ~session_id:(W.Session_id.of_string "catalog-preferences") in
  let tile = List.hd_exn registry.tiles in
  let choose host id =
    let command =
      Host.catalog host ~project:None ~jobs:[]
      |> List.find_exn ~f:(fun command -> String.equal command.id id)
    in
    match command.action with
    | Set_presentation (id, overrides) -> Host.set_presentation host id overrides
    | _ -> assert false
  in
  let host = Host.receive Host.empty registry in
  let inherited = (Host.policy host tile).header in
  let toggled, save = choose host "tile.headers" in
  assert save;
  assert (Bool.equal (Host.policy toggled tile).header (not inherited));
  let titled, save = choose toggled "tile.presentation.title" in
  assert save;
  (* Run reference and freshness are selection/data choices: local only, never saved. *)
  let referenced, save = choose titled "tile.presentation.run-reference" in
  assert (not save);
  let referenced, save = choose referenced "tile.presentation.freshness" in
  assert (not save);
  let saved = capture ~project_key:"catalog" referenced in
  assert (List.length saved.tile_headers = 1);
  assert (List.length (Option.value_exn saved.tile_appearance) = 1);
  let starting = apply saved Host.empty in
  let restored, pending = receive (Some saved) starting registry in
  assert (Option.is_none pending);
  assert (Bool.equal (Host.policy restored tile).header (not inherited));
  assert (
    Option.equal
      Bool.equal
      (Host.local restored tile.id).presentation.title
      (Host.local titled tile.id).presentation.title);
  assert (Option.is_none (Host.local restored tile.id).presentation.run_reference);
  assert (Option.is_none (Host.local restored tile.id).presentation.freshness);
  let reset, save = choose restored "tile.presentation.reset" in
  assert save;
  assert (Bool.equal (Host.policy reset tile).header inherited);
  (* A newer appearance and reset must survive polling even before the save worker
     completes; the initially loaded snapshot has already been consumed. *)
  let reset = { reset with chrome = false; layout_mode = Preferred } in
  let polled, pending =
    receive pending reset { registry with revision = registry.revision + 1 }
  in
  assert (Option.is_none pending);
  assert ((not polled.chrome) && Host.equal_layout_mode polled.layout_mode Preferred);
  assert (Option.is_none (Host.local polled tile.id).presentation.header);
  assert (Option.is_none (Host.local polled tile.id).presentation.title);
  let saved_reset = capture ~project_key:"catalog" polled in
  assert (List.is_empty saved_reset.tile_headers);
  assert (List.is_empty (Option.value_exn saved_reset.tile_appearance));
  let restarted = apply saved_reset (Host.receive Host.empty registry) in
  assert (Bool.equal (Host.policy restarted tile).header inherited);
  assert (T.equal_overrides (Host.local restarted tile.id).presentation T.inherit_);
  (* Consuming a missing identity is final, even if an ID is later reused. *)
  let absent, pending = receive (Some saved) starting { registry with tiles = [] } in
  let readded, _ =
    receive pending absent { registry with revision = registry.revision + 2 }
  in
  assert (Option.is_none (Host.local readded tile.id).presentation.header);
  let ignored, save =
    Host.set_presentation
      absent
      tile.id
      { Tile_presentation.inherit_ with header = Some true }
  in
  assert ((not save) && List.is_empty ignored.locals)
;;

let%test_unit "main-window and palette hints persist independently of global chrome" =
  let registry = W.initial ~session_id:(W.Session_id.of_string "hint-preferences") in
  let base = Host.receive Host.empty registry in
  List.iter [ true; false ] ~f:(fun chrome ->
    List.iter [ true; false ] ~f:(fun main_hints ->
      List.iter [ true; false ] ~f:(fun palette_hints ->
        let host = { base with chrome; main_hints; palette_hints } in
        let stored =
          decode ~project_key:"root/env" (encode (capture ~project_key:"root/env" host))
        in
        let restored = apply stored (Host.receive Host.empty registry) in
        assert (Bool.equal restored.chrome chrome);
        assert (Bool.equal restored.main_hints main_hints);
        assert (Bool.equal restored.palette_hints palette_hints))));
  (* A schema 1 file (written before WB-019) keeps its chrome choice and shows hints. *)
  let legacy =
    { (capture ~project_key:"root/env" { base with chrome = false }) with
      schema_version = 1
    ; main_hints = None
    ; palette_hints = None
    ; tile_appearance = None
    }
  in
  let encoded = encode legacy in
  assert (not (String.is_substring encoded ~substring:"hints"));
  let restored =
    apply
      (decode ~project_key:"root/env" encoded)
      { base with main_hints = false; palette_hints = false }
  in
  assert (not restored.chrome);
  assert (restored.main_hints && restored.palette_hints)
;;

let%test_unit "every persisted tile appearance field round-trips, resets and is guarded" =
  let registry = W.initial ~session_id:(W.Session_id.of_string "appearance-session") in
  let tile = List.hd_exn registry.tiles in
  let base = Host.receive Host.empty registry in
  let set host overrides =
    let host, save = Host.set_presentation host tile.id overrides in
    host, save
  in
  let round_trip host =
    let stored =
      decode ~project_key:"root/env" (encode (capture ~project_key:"root/env" host))
    in
    stored, apply stored (Host.receive Host.empty registry)
  in
  let explicit : T.overrides list =
    List.init 10 ~f:(fun n -> { T.inherit_ with decimal_places = Some n })
    @ [ { T.inherit_ with title = Some false }
      ; { T.inherit_ with title = Some true }
      ; { T.inherit_ with badge = Some Exceptions }
      ; { T.inherit_ with badge = Some Always }
      ; { T.inherit_ with badge = Some Hidden }
      ; { T.inherit_ with hints = Some false }
      ; { T.inherit_ with hints = Some true }
      ; { T.inherit_ with frame = Some false }
      ; { T.inherit_ with frame = Some true }
      ; { T.inherit_ with padding = Some 0 }
      ; { T.inherit_ with padding = Some 3 }
      ; { T.inherit_ with run_selector_rows = Some 1 }
      ; { T.inherit_ with run_selector_rows = Some 9 }
      ; { T.inherit_ with string_compression = Some false }
      ; { T.inherit_ with string_compression = Some true }
      ; { T.inherit_ with
          header = Some false
        ; title = Some false
        ; badge = Some Hidden
        ; hints = Some false
        ; frame = Some false
        ; padding = Some 2
        ; run_selector_rows = Some 7
        }
      ]
  in
  List.iter explicit ~f:(fun overrides ->
    let host, save = set base overrides in
    assert save;
    let _, restarted = round_trip host in
    assert (T.equal_overrides (Host.local restarted tile.id).presentation overrides);
    (* Reset-to-inherit removes the stored override and survives a later restart. *)
    let reset, save = set host T.inherit_ in
    assert save;
    let stored, restarted = round_trip reset in
    assert (List.is_empty stored.tile_headers);
    assert (List.is_empty (Option.value_exn stored.tile_appearance));
    assert (T.equal_overrides (Host.local restarted tile.id).presentation T.inherit_));
  (* Absent fields inherit: only the explicit field is written for a sparse override. *)
  let sparse, _ = set base { T.inherit_ with padding = Some 3 } in
  let legacy_v3 = { (capture ~project_key:"root/env" sparse) with schema_version = 3 } in
  let migrated =
    decode ~project_key:"root/env" (encode legacy_v3)
    |> fun saved -> apply saved (Host.receive Host.empty registry)
  in
  assert ((Host.policy migrated tile).padding = 3);
  assert ((Host.policy migrated tile).decimal_places = 3);
  assert (Host.policy migrated tile).string_compression;
  assert (
    T.equal_overrides
      (Host.local migrated tile.id).presentation
      { T.inherit_ with padding = Some 3 });
  let encoded = encode (capture ~project_key:"root/env" sparse) in
  assert (String.is_substring encoded ~substring:"(padding 3)");
  assert (not (String.is_substring encoded ~substring:"(title"));
  assert (not (String.is_substring encoded ~substring:"run_reference"));
  assert (not (String.is_substring encoded ~substring:"freshness"));
  (* Run reference/freshness never persist, even alongside persisted fields. *)
  let mixed, _ =
    set
      base
      { T.inherit_ with
        frame = Some false
      ; run_reference = Some true
      ; freshness = Some false
      }
  in
  let _, restarted = round_trip mixed in
  assert (
    T.equal_overrides
      (Host.local restarted tile.id).presentation
      { T.inherit_ with frame = Some false });
  let changed, save =
    set mixed { (Host.local mixed tile.id).presentation with run_reference = Some false }
  in
  assert (not save);
  assert (
    Option.equal
      Bool.equal
      (Host.local changed tile.id).presentation.run_reference
      (Some false));
  (* Identity guards: replacement session, retyped, moved and removed tiles inherit. *)
  let full, _ = set base (List.last_exn explicit) in
  let stored, _ = round_trip full in
  let inherits snapshot =
    let host = apply stored (Host.receive Host.empty snapshot) in
    List.for_all snapshot.tiles ~f:(fun (t : W.Tile.t) ->
      T.equal_overrides (Host.local host t.id).presentation T.inherit_)
  in
  assert (inherits { registry with session_id = W.Session_id.of_string "replacement" });
  assert (
    inherits
      { registry with
        tiles = List.map registry.tiles ~f:(fun t -> { t with kind = "new-kind" })
      });
  assert (
    inherits
      { registry with
        tiles =
          List.map registry.tiles ~f:(fun t ->
            { t with workspace = W.Workspace_id.of_string "another-workspace" })
      });
  assert (
    List.is_empty
      (apply stored (Host.receive Host.empty { registry with tiles = [] })).locals);
  (* One-shot restoration: a newer reset is never replayed over by polling. *)
  let starting = apply stored Host.empty in
  let restored, pending = receive (Some stored) starting registry in
  assert (
    T.equal_overrides (Host.local restored tile.id).presentation (List.last_exn explicit));
  let reset, _ = set restored T.inherit_ in
  let polled, _ =
    receive pending reset { registry with revision = registry.revision + 1 }
  in
  assert (T.equal_overrides (Host.local polled tile.id).presentation T.inherit_);
  (* Schema 1/2 files predate tile appearance: every such field inherits. *)
  List.iter [ 1; 2 ] ~f:(fun schema_version ->
    let older =
      { (capture ~project_key:"root/env" full) with
        schema_version
      ; tile_appearance = None
      ; main_hints = (if schema_version = 1 then None else Some true)
      ; palette_hints = (if schema_version = 1 then None else Some true)
      }
    in
    let encoded = encode older in
    assert (not (String.is_substring encoded ~substring:"tile_appearance"));
    let loaded = decode ~project_key:"root/env" encoded in
    let restored = apply loaded (Host.receive Host.empty registry) in
    assert (
      T.equal_overrides
        (Host.local restored tile.id).presentation
        { T.inherit_ with header = Some false }))
;;
