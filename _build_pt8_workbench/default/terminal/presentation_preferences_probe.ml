open! Core
open Hardcaml_workbench_protocol
module P = Terminal_presentation.Presentation_preferences
module Host = Terminal_presentation.Workspace_host
module W = Workspace
module T = Terminal_presentation.Tile_presentation

let choose host id =
  let command =
    Host.catalog host ~project:None ~jobs:[]
    |> List.find_exn ~f:(fun command -> String.equal command.id id)
  in
  match command.action with
  | Set_presentation (tile, overrides) -> Host.set_presentation host tile overrides
  | Set_global_compression value -> Host.set_global_compression host value, true
  | Set_workspace_compression (workspace, value) ->
    Host.set_workspace_compression host workspace value, true
  | _ -> failwith "Expected catalog presentation action"
;;

(* Invoked in separate processes by the restart test; uses the production store,
   serializer and host restoration rather than a second preference implementation. *)
let () =
  let argv = Sys.get_argv () in
  let mode = argv.(1)
  and state_directory = argv.(2) in
  let project_key = "restart-fixture/inherited" in
  let registry = W.initial ~session_id:(W.Session_id.of_string "restart-session") in
  let host = Host.receive Host.empty registry in
  let tile = List.hd_exn registry.tiles in
  let expected =
    { host with
      appearance =
        { preset = Minimal
        ; color = Vivid
        ; scheme = Slate
        ; icons = None_
        ; density = Comfortable
        }
    ; layout_mode = Preferred
    ; chrome = false
    }
    |> fun host ->
    let host, save = choose host "tile.headers" in
    assert save;
    (* WB-048: every persisted appearance field, through the production catalog. *)
    let host =
      List.fold
        [ "tile.presentation.title"
        ; "tile.presentation.badge.hidden"
        ; "tile.presentation.hints"
        ; "tile.presentation.frame"
        ; "tile.presentation.padding"
        ; "tile.presentation.rows.more"
        ; "tile.presentation.rows.more"
        ; "tile.presentation.strings.full"
        ; "tile.presentation.decimals.9"
        ]
        ~init:host
        ~f:(fun host id ->
          let host, save = choose host id in
          assert save;
          host)
    in
    (* Selection/data choices stay local: not saved, not restored. *)
    let host, save = choose host "tile.presentation.run-reference" in
    assert (not save);
    let local = Host.local host tile.id in
    Host.set_local host tile.id { local with filter = "not-persistent"; scroll = 23 }
  in
  match mode with
  | "matrix-write" | "matrix-read" ->
    let combo = argv.(3) in
    let choice i =
      match combo.[i] with
      | 'i' -> None
      | 't' -> Some true
      | 'f' -> Some false
      | _ -> assert false
    in
    let expected =
      Host.set_global_compression host (choice 0)
      |> fun host -> Host.set_workspace_compression host tile.workspace (choice 1)
    in
    let expected, _ =
      Host.set_presentation expected tile.id
        { T.inherit_ with string_compression = choice 2; decimal_places = Some 7 }
    in
    if String.equal mode "matrix-write"
    then P.save ~state_directory (P.capture ~project_key expected)
    else (
      let saved = Option.value_exn (P.load ~state_directory ~project_key) in
      let restored, pending = P.receive (Some saved) (P.apply saved Host.empty) registry in
      assert (Option.is_none pending);
      List.iter registry.tiles ~f:(fun tile ->
        assert (T.equal (Host.policy restored tile) (Host.policy expected tile)));
      assert ((Host.policy restored tile).decimal_places = 7))
  | "scopes-write" ->
    let host, _ = choose expected "global.strings.full" in
    let host, _ = choose host "workspace.strings.compact" in
    P.save ~state_directory (P.capture ~project_key { host with timing_preload = false })
  | "scopes-read" ->
    let preferences = Option.value_exn (P.load ~state_directory ~project_key) in
    let restored, pending =
      P.receive (Some preferences) (P.apply preferences Host.empty) registry
    in
    assert (Option.is_none pending);
    assert (not restored.timing_preload);
    assert (not (Host.policy restored tile).string_compression);
    let reset, _ = choose restored "tile.presentation.strings.reset" in
    assert (Host.policy reset tile).string_compression;
    assert ((Host.policy reset tile).decimal_places = 9);
    let reset, _ = choose reset "workspace.strings.reset" in
    assert (not (Host.policy reset tile).string_compression);
    let reset, _ = choose reset "global.strings.reset" in
    assert (Host.policy reset tile).string_compression;
    let replaced =
      P.apply
        preferences
        (Host.receive
           Host.empty
           { registry with session_id = W.Session_id.of_string "replacement" })
    in
    assert (List.is_empty replaced.workspace_presentation);
    assert (not (Host.policy replaced tile).string_compression);
    P.save ~state_directory (P.capture ~project_key reset)
  | "scopes-read-reset" ->
    let preferences = Option.value_exn (P.load ~state_directory ~project_key) in
    assert (Option.is_none preferences.global_compression);
    assert (Option.is_none preferences.workspace_compression);
    let restored = P.apply preferences host in
    assert (Host.policy restored tile).string_compression;
    assert ((Host.policy restored tile).decimal_places = 9);
    assert (not restored.timing_preload)
  | "write" -> P.save ~state_directory (P.capture ~project_key expected)
  | "read" ->
    let preferences = Option.value_exn (P.load ~state_directory ~project_key) in
    let restored = P.apply preferences host in
    assert (Terminal_presentation.Appearance.equal restored.appearance expected.appearance);
    assert (Host.equal_layout_mode restored.layout_mode expected.layout_mode);
    assert (not restored.chrome);
    assert (
      Option.equal
        Bool.equal
        (Host.local restored tile.id).presentation.header
        (Host.local expected tile.id).presentation.header);
    let saved = (Host.local expected tile.id).presentation in
    assert (Option.is_some saved.run_reference);
    assert (
      T.equal_overrides (Host.local restored tile.id).presentation (T.persisted saved));
    assert (Option.is_some saved.title && Option.is_some saved.run_selector_rows);
    assert (String.is_empty (Host.local restored tile.id).filter);
    assert ((Host.local restored tile.id).scroll = 0);
    assert (Option.equal W.Snapshot.equal restored.registry (Some registry));
    let replacement =
      { registry with session_id = W.Session_id.of_string "new-session" }
    in
    let replaced = P.apply preferences (Host.receive Host.empty replacement) in
    assert (T.equal_overrides (Host.local replaced tile.id).presentation T.inherit_);
    assert (not replaced.chrome);
    assert (
      Option.is_none (P.load ~state_directory ~project_key:"other-project/inherited"))
  | "reset" ->
    let preferences = Option.value_exn (P.load ~state_directory ~project_key) in
    let restored, pending =
      P.receive (Some preferences) (P.apply preferences host) registry
    in
    let restored, save = choose restored "tile.presentation.padding" in
    assert save;
    let reset, save = choose restored "tile.presentation.reset" in
    assert save;
    let polled, pending =
      P.receive pending reset { registry with revision = registry.revision + 1 }
    in
    assert (Option.is_none pending);
    assert (T.equal_overrides (Host.local polled tile.id).presentation T.inherit_);
    P.save ~state_directory (P.capture ~project_key polled)
  | "read-reset" ->
    let preferences = Option.value_exn (P.load ~state_directory ~project_key) in
    assert (List.is_empty preferences.tile_headers);
    assert (List.is_empty (Option.value_exn preferences.tile_appearance));
    let restored = P.apply preferences host in
    assert (T.equal_overrides (Host.local restored tile.id).presentation T.inherit_);
    let inherited = { host with appearance = expected.appearance } in
    assert (
      Bool.equal (Host.policy restored tile).header (Host.policy inherited tile).header);
    assert (Terminal_presentation.Appearance.equal restored.appearance expected.appearance)
  | "hints-write" | "hints-read" ->
    (* argv.(3) is "<main><palette>" with 1 = visible, 0 = hidden. *)
    let combo = argv.(3) in
    let main_hints = Char.equal combo.[0] '1'
    and palette_hints = Char.equal combo.[1] '1' in
    if String.equal mode "hints-write"
    then
      P.save
        ~state_directory
        (P.capture ~project_key { expected with main_hints; palette_hints })
    else (
      let preferences = Option.value_exn (P.load ~state_directory ~project_key) in
      let restored = P.apply preferences host in
      assert (Bool.equal restored.main_hints main_hints);
      assert (Bool.equal restored.palette_hints palette_hints);
      (* Hint choices never alter the existing global chrome choice. *)
      assert (not restored.chrome);
      assert (Host.equal_layout_mode restored.layout_mode expected.layout_mode))
  | "headers-write" ->
    (* Header only, so the file has an empty appearance list for the legacy rewrite. *)
    let local = Host.local expected tile.id in
    P.save
      ~state_directory
      (P.capture
         ~project_key
         (Host.set_local
            expected
            tile.id
            { local with
              presentation = { T.inherit_ with header = local.presentation.header }
            }))
  | "read-legacy" ->
    (* argv.(3) is the legacy schema version written by the test (1 or 2). *)
    let version = Int.of_string argv.(3) in
    let preferences = Option.value_exn (P.load ~state_directory ~project_key) in
    assert (preferences.schema_version = version);
    assert (Option.is_none preferences.tile_appearance);
    let restored =
      P.apply preferences { host with main_hints = false; palette_hints = false }
    in
    assert (not restored.chrome);
    assert (restored.main_hints && restored.palette_hints);
    (* Missing appearance fields inherit; the legacy header choice is kept. *)
    assert (
      T.equal_overrides
        (Host.local restored tile.id).presentation
        { T.inherit_ with header = (Host.local expected tile.id).presentation.header })
  | "missing" -> assert (Option.is_none (P.load ~state_directory ~project_key))
  | "malformed" ->
    let path = P.path ~state_directory ~project_key in
    let before = In_channel.read_all path in
    assert (
      Result.is_error (Or_error.try_with (fun () -> P.load ~state_directory ~project_key)));
    assert (String.equal before (In_channel.read_all path))
  | "save-error" ->
    assert (
      Result.is_error
        (Or_error.try_with (fun () ->
           P.save ~state_directory (P.capture ~project_key expected))))
  | _ -> failwith "Unknown preference probe mode"
;;
