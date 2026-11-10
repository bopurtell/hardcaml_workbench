open! Core
open Hardcaml_workbench_protocol
module W = Workspace
module T = Workspace_template

let ok = function
  | Ok value -> value
  | Error (error : V1.Error.t) -> raise_s [%sexp (error : V1.Error.t)]
;;

let mutate (s : W.Snapshot.t) mutation =
  W.apply s (Mutate { expected_revision = s.revision; mutation }) |> ok
;;

let error kind = function
  | Ok _ -> failwith "Expected registry error"
  | Error (e : V1.Error.t) -> assert (V1.Error.Kind.equal kind e.kind)
;;

let initial () = W.initial ~session_id:(W.Session_id.of_string "private-session")

let without_field sexp name =
  match sexp with
  | Sexp.List fields ->
    Sexp.List
      (List.filter fields ~f:(function
        | Sexp.List (Sexp.Atom field :: _) -> not (String.equal field name)
        | _ -> true))
  | _ -> assert false
;;

let%test_unit "legacy templates are custom; explicit unknown preset identities roundtrip" =
  let legacy = T.sexp_of_t T.generic |> fun s -> without_field s "preset" in
  let decoded = T.decode (Sexp.to_string legacy) |> Or_error.ok_exn in
  assert (Option.is_none decoded.preset);
  let s = initial () in
  List.iter [ None; Some "overview"; Some "future/preset-v2" ] ~f:(fun preset ->
    let template =
      { decoded with
        name = "Renamed desk"
      ; preset
      ; views = List.rev_map decoded.views ~f:(fun view -> { view with hidden = true })
      }
    in
    let template = T.encode template |> Or_error.ok_exn |> T.decode |> Or_error.ok_exn in
    let next =
      mutate s (Instantiate_template { window = (List.hd_exn s.windows).id; template })
    in
    let w = List.last_exn next.workspaces in
    assert (Option.equal String.equal w.preset preset);
    assert (T.equal template (W.export_template next w.id |> ok)))
;;

let%test_unit "clone override precedes portable name validation" =
  let s = initial () in
  let w = List.hd_exn s.workspaces in
  let s = mutate s (Rename_workspace { workspace = w.id; name = "Nonportable\nname" }) in
  assert (Result.is_error (W.export_template s w.id));
  let template = W.export_template ~name:"Valid clone" s w.id |> ok in
  let next = mutate s (Instantiate_template { window = w.window; template }) in
  let clone = List.last_exn next.workspaces in
  assert (String.equal clone.name "Valid clone");
  assert (Option.equal String.equal clone.preset w.preset);
  assert (not (W.Workspace_id.equal clone.id w.id));
  assert (Result.is_error (W.export_template ~name:"" s w.id))
;;

let bootstrap_templates =
  [ { T.generic with name = "Overview"; preset = Some "overview" }
  ; { T.asic with name = "Timing"; preset = Some "timing" }
  ]
;;

let%test_unit "legacy saved snapshots at any revision are conservatively initialized" =
  List.iter [ 0; 17 ] ~f:(fun revision ->
    let s = { (initial ()) with revision } in
    let sexp = without_field (W.Snapshot.sexp_of_t s) "defaults_initialized" in
    let legacy = W.Snapshot.t_of_sexp sexp in
    assert legacy.defaults_initialized;
    assert (W.Snapshot.equal legacy (W.apply legacy (Bootstrap bootstrap_templates) |> ok)))
;;

let%test_unit "bootstrap is atomic and idempotent independently of revision and restart" =
  let s = initial () in
  assert (not s.defaults_initialized);
  let window = (List.hd_exn s.windows).id in
  let imported = mutate s (Instantiate_template { window; template = T.generic }) in
  let custom = List.last_exn imported.workspaces in
  let original = List.hd_exn s.workspaces in
  let imported =
    mutate imported (Rename_workspace { workspace = original.id; name = "Renamed" })
  in
  let reloaded = W.Snapshot.t_of_sexp (W.Snapshot.sexp_of_t imported) in
  assert (not reloaded.defaults_initialized);
  (* Missing/invalid definitions cannot persist partial defaults or the marker. *)
  W.apply reloaded (Bootstrap [ List.hd_exn bootstrap_templates ]) |> error Not_found;
  W.apply reloaded (Bootstrap ({ T.generic with version = 999 } :: bootstrap_templates))
  |> error Invalid_request;
  let exhausted = { reloaded with next_id = Int.max_value - 1 } in
  W.apply exhausted (Bootstrap bootstrap_templates) |> error Invalid_request;
  assert (not exhausted.defaults_initialized);
  assert (List.equal W.Tile.equal exhausted.tiles reloaded.tiles);
  assert (not reloaded.defaults_initialized);
  let next = W.apply reloaded (Bootstrap bootstrap_templates) |> ok in
  assert next.defaults_initialized;
  assert (next.revision = reloaded.revision + 1);
  assert (String.equal (W.workspace next original.id).name "Renamed");
  assert (
    W.Arrangement.equal (W.workspace reloaded custom.id) (W.workspace next custom.id));
  assert (T.equal T.generic (W.export_template next custom.id |> ok));
  let restarted = W.Snapshot.t_of_sexp (W.Snapshot.sexp_of_t next) in
  (* A concurrent second startup, even with no definitions, is a strict no-op. *)
  assert (W.Snapshot.equal next (W.apply restarted (Bootstrap []) |> ok));
  let operation = W.Operation.Bootstrap bootstrap_templates in
  assert (
    W.Operation.equal
      operation
      (V1.Codec.encode W.Operation.sexp_of_t operation
       |> V1.Codec.decode W.Operation.t_of_sexp
       |> ok));
  W.apply
    next
    (Mutate
       { expected_revision = reloaded.revision
       ; mutation = Create_window { name = "stale" }
       })
  |> error Conflict;
  let before_import = W.apply s (Bootstrap bootstrap_templates) |> ok in
  let after_import =
    mutate before_import (Instantiate_template { window; template = T.generic })
  in
  assert (
    W.Snapshot.equal
      after_import
      (W.apply after_import (Bootstrap bootstrap_templates) |> ok));
  List.iter [ next; after_import ] ~f:(fun s ->
    List.iter s.workspaces ~f:(fun w ->
      if Option.is_some w.preset
      then
        assert (
          List.length
            (List.filter s.tiles ~f:(fun t -> W.Workspace_id.equal t.workspace w.id))
          > 1)))
;;

let%test_unit "generic starter is project-scoped; ASIC starter includes supported \
               evidence views"
  =
  let kinds template = List.map template.T.views ~f:(fun view -> view.T.View.kind) in
  let generic = kinds T.generic in
  let asic = kinds T.asic in
  assert (
    List.equal String.equal generic [ "project"; "execution"; "project-tests"; "logs" ]);
  let asic_kinds =
    [ "run-selector"
    ; "asic"
    ; "synthesis"
    ; "placement"
    ; "cts"
    ; "routing"
    ; "timing"
    ; "checks"
    ; "finalization"
    ]
  in
  List.iter asic_kinds ~f:(fun kind ->
    assert (not (List.mem generic kind ~equal:String.equal)));
  assert (List.mem asic "synthesis" ~equal:String.equal);
  assert (List.equal String.equal asic asic_kinds);
  List.iter [ T.generic; T.asic ] ~f:(fun template ->
    T.validate template |> Or_error.ok_exn;
    assert (
      T.equal
        template
        (T.encode template |> Or_error.ok_exn |> T.decode |> Or_error.ok_exn)))
;;

let%test_unit "template mutation uses the existing workspace wire envelope" =
  let s = initial () in
  let request : W.Request.t =
    { instance_id = "instance"
    ; project = Project_id.of_string "project"
    ; operation =
        Mutate
          { expected_revision = s.revision
          ; mutation =
              Instantiate_template
                { window = (List.hd_exn s.windows).id; template = T.asic }
          }
    }
  in
  let encoded = V1.Codec.encode W.Request.sexp_of_t request in
  let decoded = V1.Codec.decode W.Request.t_of_sexp encoded |> ok in
  assert (W.Request.equal request decoded);
  W.apply s decoded.operation |> ok |> W.validate |> ok
;;

let%test_unit "export strips live state; repeated import allocates fresh Main-linked \
               views"
  =
  let s = initial () in
  let source = List.hd_exn s.workspaces in
  let first = List.hd_exn s.tiles in
  let run : Run_ref.t =
    { backend = Backend_id.of_string "private-provider"
    ; id = "private-run"
    ; build = None
    ; label = None
    }
  in
  let s = mutate s (Make_independent source.id) in
  let independent = (W.workspace s source.id).context in
  let s =
    mutate
      s
      (Select_run
         { workspace = source.id
         ; context = independent
         ; expected_selection_revision = 0
         ; run = Some run
         })
  in
  let s = mutate s (Set_tile_binding { tile = first.id; binding = Pin_run run }) in
  let s = mutate s (Set_zoom { workspace = source.id; tile = Some first.id }) in
  let s =
    mutate
      s
      (Create_tile
         { workspace = source.id
         ; kind = "future-extension"
         ; geometry = { x = 5; y = 7; width = 11; height = 13 }
         })
  in
  let last = List.last_exn s.tiles in
  let s = mutate s (Set_tile_hidden { tile = last.id; hidden = true }) in
  let template = W.export_template s source.id |> ok in
  let encoded = T.encode template |> Or_error.ok_exn in
  List.iter
    [ "private-session"
    ; "private-provider"
    ; "private-run"
    ; W.Context_id.to_string independent
    ; W.Tile_id.to_string first.id
    ; W.Workspace_id.to_string source.id
    ]
    ~f:(fun secret -> assert (not (String.is_substring encoded ~substring:secret)));
  assert (T.equal template (T.decode encoded |> Or_error.ok_exn));
  let import s = mutate s (Instantiate_template { window = source.window; template }) in
  let next = import s in
  assert (next.revision = s.revision + 1);
  assert (List.equal W.Context.equal s.contexts next.contexts);
  assert (W.Arrangement.equal (W.workspace s source.id) (W.workspace next source.id));
  let created = List.last_exn next.workspaces in
  assert (W.Context_id.equal created.context s.main_context);
  assert (Option.is_none created.zoomed_tile);
  assert (T.equal template (W.export_template next created.id |> ok));
  let new_tiles =
    List.filter next.tiles ~f:(fun t -> W.Workspace_id.equal t.workspace created.id)
  in
  assert (List.length new_tiles = 2);
  List.iter new_tiles ~f:(fun t ->
    assert (W.Binding.equal t.binding Follow);
    assert (Option.is_none (W.resolve_tile next t.id |> ok).run);
    assert (not (List.exists s.tiles ~f:(fun old -> W.Tile_id.equal old.id t.id))));
  let again = import next in
  let second = List.last_exn again.workspaces in
  assert (not (W.Workspace_id.equal created.id second.id));
  assert (List.length again.tiles = List.length next.tiles + 2);
  W.apply
    next
    (Mutate
       { expected_revision = s.revision
       ; mutation = Instantiate_template { window = source.window; template }
       })
  |> error Conflict
;;

let%test_unit "invalid portable files are rejected before registry allocation" =
  let s = initial () in
  let window = (List.hd_exn s.windows).id in
  let bad_geometry : T.View.t =
    { kind = "timing"
    ; hidden = false
    ; geometry = { x = Int.max_value; y = 0; width = 1; height = 1 }
    }
  in
  let invalid =
    [ { T.generic with version = 999 }
    ; { T.generic with name = "  " }
    ; { T.generic with name = "bad\nname" }
    ; { T.generic with views = [ bad_geometry ] }
    ; { T.generic with
        views = List.init (T.max_views + 1) ~f:(fun _ -> List.hd_exn T.generic.views)
      }
    ]
  in
  List.iter invalid ~f:(fun template ->
    assert (Result.is_error (T.validate template));
    W.apply
      s
      (Mutate
         { expected_revision = s.revision
         ; mutation = Instantiate_template { window; template }
         })
    |> error Invalid_request);
  List.iter
    [ "("
    ; "((version 1) (name A) (views ()) (session_id forbidden))"
    ; String.make (T.max_encoded_bytes + 1) ' '
    ]
    ~f:(fun text -> assert (Result.is_error (T.decode text)));
  W.apply
    s
    (Mutate
       { expected_revision = s.revision
       ; mutation =
           Instantiate_template
             { window = W.Window_id.of_string "missing"; template = T.generic }
       })
  |> error Not_found;
  (* Failure after workspace allocation still cannot expose a partial import. *)
  let exhausted = { s with next_id = Int.max_value - 1 } in
  W.apply
    exhausted
    (Mutate
       { expected_revision = s.revision
       ; mutation = Instantiate_template { window; template = T.generic }
       })
  |> error Invalid_request;
  assert (exhausted.revision = s.revision);
  assert (List.length exhausted.workspaces = List.length s.workspaces);
  List.iter
    [ T.generic; T.asic; { T.generic with views = [] } ]
    ~f:(fun template ->
      let next = mutate s (Instantiate_template { window; template }) in
      W.validate next |> ok)
;;
