open! Core
open Hardcaml_workbench_protocol
module W = Workspace
module C = Workspace_config

let ok = function
  | Ok x -> x
  | Error error -> raise_s [%sexp (error : V1.Error.t)]
;;

let%test_unit "targeted reorder and guarded separate close preserve remaining user work" =
  let initial = W.initial ~session_id:(W.Session_id.of_string "lifecycle") in
  let mutate s mutation =
    W.apply s (Mutate { expected_revision = s.W.Snapshot.revision; mutation }) |> ok
  in
  let main = List.hd_exn initial.workspaces in
  let s =
    mutate
      initial
      (Create_workspace
         { window = main.window
         ; name = "Timing · captured exact-source"
         ; context = main.context
         })
  in
  let separate = List.last_exn s.workspaces in
  let close s =
    W.apply
      s
      (Mutate
         { expected_revision = s.W.Snapshot.revision
         ; mutation = Close_separate_investigation separate.id
         })
  in
  assert (Result.is_error (close s));
  let s = mutate s (Make_independent separate.id) in
  let s =
    mutate
      s
      (Create_tile
         { workspace = separate.id
         ; kind = "timing-paths"
         ; geometry = { x = 0; y = 0; width = 80; height = 10 }
         })
  in
  let before_tiles =
    List.filter s.tiles ~f:(fun tile ->
      not (W.Workspace_id.equal tile.workspace separate.id))
  in
  let s =
    mutate s (Reorder_workspace { workspace = separate.id; before = Some main.id })
  in
  assert (W.Workspace_id.equal (List.hd_exn s.workspaces).id separate.id);
  assert (
    List.equal
      W.Context.equal
      s.contexts
      (mutate s (Reorder_workspace { workspace = main.id; before = Some separate.id }))
        .contexts);
  let stale =
    W.apply
      s
      (Mutate
         { expected_revision = initial.revision
         ; mutation = Close_separate_investigation separate.id
         })
  in
  assert (Result.is_error stale);
  let closed = close s |> ok in
  assert (List.equal W.Tile.equal closed.tiles before_tiles);
  assert (List.equal W.Arrangement.equal closed.workspaces initial.workspaces);
  assert (List.equal W.Context.equal closed.contexts initial.contexts);
  assert (
    Result.is_error
      (W.apply
         closed
         (Mutate
            { expected_revision = closed.revision
            ; mutation = Close_separate_investigation main.id
            })))
;;

let definition kinds : C.Definition.t =
  let d =
    C.definition_of_template ~key:"desk" (Workspace_template.starter "Desk" kinds)
    |> Or_error.ok_exn
  in
  { d with
    layout = Some (Leaf { tile = "tile-1"; min_width = 10; min_height = 2; weight = 1 })
  }
;;

let config kinds : C.Resolved.t =
  { version = C.version
  ; id = "project-desks"
  ; definitions = [ definition kinds ]
  ; windows =
      List.map [ "left"; "right" ] ~f:(fun key ->
        { C.Window.key
        ; name = "Same display name"
        ; workspaces =
            [ { C.Instance.key = "desk"; name = "Desk"; definition = Custom "desk" } ]
        })
  }
;;

let initial () = W.initial ~session_id:(W.Session_id.of_string "composition-test")
let initialize s c = W.apply s (Initialize_config c) |> ok

let mutate (s : W.Snapshot.t) mutation =
  W.apply s (Mutate { expected_revision = s.revision; mutation }) |> ok
;;

let%test_unit "initialize replaces only placeholders and persists complete keyed policy" =
  let s = initialize (initial ()) (config [ "logs"; "logs" ]) in
  assert (s.revision = 1);
  assert (List.length s.windows = 2 && List.length s.workspaces = 2);
  assert (List.length s.tiles = 4);
  List.iter s.workspaces ~f:(fun w ->
    assert (W.Context_id.equal w.context s.main_context));
  List.iter s.tiles ~f:(fun t -> assert (W.Binding.equal t.binding Follow));
  List.iter s.config_workspaces ~f:(fun p ->
    assert (C.Definition.equal p.definition (definition [ "logs"; "logs" ])));
  let restored = W.Snapshot.t_of_sexp (W.Snapshot.sexp_of_t s) in
  assert (W.Snapshot.equal s restored);
  assert (W.Snapshot.equal s (initialize restored (config [ "different" ])));
  let reapplied = mutate restored (Apply_config (config [ "logs"; "logs" ])) in
  assert (W.Snapshot.equal { s with revision = reapplied.revision } reapplied)
;;

let%test_unit "any accepted edit consumes config initialization even if reverted" =
  let s = initial () in
  let w = List.hd_exn s.workspaces in
  let s = mutate s (Rename_workspace { workspace = w.id; name = "Edited" }) in
  let s = mutate s (Rename_workspace { workspace = w.id; name = w.name }) in
  assert (W.Snapshot.equal s (initialize s (config [ "logs" ])));
  (* Revision is not the marker: a legacy revision-zero session wins as well. *)
  let legacy : Sexp.t =
    match W.Snapshot.sexp_of_t (initial ()) with
    | Sexp.List fields ->
      Sexp.List
        (List.filter fields ~f:(function
          | Sexp.List
              (Sexp.Atom
                 ( "configuration_pending"
                 | "config_windows"
                 | "config_workspaces"
                 | "defaults_initialized" )
              :: _) -> false
          | _ -> true))
    | _ -> assert false
  in
  let s = W.Snapshot.t_of_sexp legacy in
  assert (W.Snapshot.equal s (initialize s (config [ "logs" ])))
;;

let%test_unit "additive reapply preserves moved edited pinned independent instances and \
               adds keys"
  =
  let s = initialize (initial ()) (config [ "logs"; "logs" ]) in
  let p = List.hd_exn s.config_workspaces in
  let tile = snd (List.hd_exn p.tiles) in
  let zoomed_tile = snd (List.nth_exn p.tiles 1) in
  let other = List.nth_exn s.workspaces 1 in
  let s =
    mutate
      s
      (Select_run
         { workspace = p.workspace
         ; context = s.main_context
         ; expected_selection_revision = 0
         ; run =
             Some
               { backend = Backend_id.of_string "fixture"
               ; id = "saved-selection"
               ; build = None
               ; label = None
               }
         })
  in
  let s = mutate s (Make_independent p.workspace) in
  let s = mutate s (Set_zoom { workspace = p.workspace; tile = Some zoomed_tile }) in
  let s = mutate s (Rename_workspace { workspace = p.workspace; name = "My edits" }) in
  let s = mutate s (Move_workspace { workspace = p.workspace; window = other.window }) in
  let s = mutate s (Move_tile { tile; workspace = other.id }) in
  let other_tile =
    List.find_exn s.tiles ~f:(fun t ->
      W.Workspace_id.equal t.workspace other.id && not (W.Tile_id.equal t.id tile))
  in
  let s = mutate s (Reorder_tile { tile; before = Some other_tile.id }) in
  let s =
    mutate
      s
      (Set_tile_binding
         { tile
         ; binding =
             Pin_run
               { backend = Backend_id.of_string "fixture"
               ; id = "saved-pin"
               ; build = None
               ; label = None
               }
         })
  in
  let s = mutate s (Set_tile_hidden { tile; hidden = true }) in
  let s =
    mutate s (Resize_tile { tile; geometry = { x = 9; y = 2; width = 37; height = 4 } })
  in
  let before_workspace = W.workspace s p.workspace in
  let before_tile = W.tile s tile in
  let contexts = s.contexts in
  let next = mutate s (Apply_config (config [ "changed-kind"; "logs"; "new-kind" ])) in
  assert (W.Arrangement.equal before_workspace (W.workspace next p.workspace));
  assert (W.Tile.equal before_tile (W.tile next tile));
  assert (List.equal W.Tile.equal s.tiles (List.take next.tiles (List.length s.tiles)));
  assert (List.equal W.Context.equal contexts next.contexts);
  assert (List.length next.tiles = 6);
  assert (List.length next.windows = 2 && List.length next.workspaces = 2);
  List.iter next.config_workspaces ~f:(fun p ->
    let added = W.tile next (snd (List.last_exn p.tiles)) in
    assert (String.equal added.kind "new-kind");
    assert (W.Binding.equal added.binding Follow));
  let removed = mutate next (Apply_config (config [ "logs" ])) in
  assert (List.equal W.Tile.equal next.tiles removed.tiles)
;;

let%test_unit "invalid whole composition and stale CAS cannot partially apply" =
  let s = initial () in
  let c = config [ "logs" ] in
  let bad =
    { c with
      windows =
        c.windows
        @ [ { C.Window.key = "bad"
            ; name = "Bad"
            ; workspaces =
                [ { C.Instance.key = "missing"
                  ; name = "Missing"
                  ; definition = Custom "missing"
                  }
                ]
            }
          ]
    }
  in
  assert (Result.is_error (W.apply s (Initialize_config bad)));
  assert (
    Result.is_error
      (W.apply s (Mutate { expected_revision = 0; mutation = Apply_config bad })));
  let next = initialize s c in
  (match W.apply next (Mutate { expected_revision = 0; mutation = Apply_config c }) with
   | Error error -> assert (V1.Error.Kind.equal error.kind Conflict)
   | Ok _ -> assert false);
  let p = List.hd_exn next.config_workspaces in
  assert (
    Result.is_error
      (W.validate { next with config_workspaces = [ { p with tiles = [] } ] }))
;;

let%test_unit "new keys add objects while renamed and removed keys keep identity" =
  let c = config [ "logs" ] in
  let s = initialize (initial ()) c in
  let first = List.hd_exn c.windows in
  let instance = List.hd_exn first.workspaces in
  let changed =
    { c with
      windows =
        [ { first with
            name = "Renamed window"
          ; workspaces =
              [ { instance with name = "Renamed desk" }; { instance with key = "extra" } ]
          }
        ; { first with key = "new-window" }
        ]
    }
  in
  let next = mutate s (Apply_config changed) in
  assert (List.length next.windows = 3);
  assert (List.length next.workspaces = 4);
  List.iter s.workspaces ~f:(fun w ->
    assert (W.Arrangement.equal w (W.workspace next w.id)));
  let again = mutate next (Apply_config changed) in
  assert (W.Snapshot.equal { next with revision = again.revision } again);
  let distinct = mutate again (Apply_config { c with id = "another-config" }) in
  assert (List.length distinct.windows = 5 && List.length distinct.workspaces = 6)
;;

let%test_unit "changed definition reference cannot reset an existing keyed instance" =
  let c = config [ "logs" ] in
  let s = initialize (initial ()) c in
  let replacement : C.Definition.t =
    { (definition [ "replacement-kind" ]) with key = "replacement" }
  in
  let changed : C.Resolved.t =
    { c with
      definitions = [ replacement ]
    ; windows =
        List.map c.windows ~f:(fun w ->
          { w with
            workspaces =
              List.map w.workspaces ~f:(fun i ->
                { i with definition = C.Reference.Custom "replacement" })
          })
    }
  in
  let next = mutate s (Apply_config changed) in
  assert (W.Snapshot.equal { s with revision = next.revision } next)
;;

let%test_unit "same-builtin Restore detaches frozen policy but retains additive identity" =
  (* Simulate an older resolved builtin with layout/presentation different from today's
     stock catalog. The registry deliberately has no catalog dependency. *)
  let original = definition [ "logs"; "logs" ] in
  let frozen : C.Definition.t =
    { original with
      key = "overview"
    ; template = { original.template with preset = Some "overview" }
    ; tiles =
        List.map original.tiles ~f:(fun tile ->
          { tile with
            presentation =
              Some { C.Presentation.inherit_defaults with title = Some false }
          })
    }
  in
  let c = config [ "logs"; "logs" ] in
  let window = List.hd_exn c.windows in
  let c : C.Resolved.t =
    { c with
      definitions = [ frozen ]
    ; windows =
        [ { window with
            workspaces =
              List.map window.workspaces ~f:(fun instance ->
                { instance with definition = C.Reference.Builtin "overview" })
          }
        ]
    }
  in
  let s = initialize (initial ()) c in
  let p = List.hd_exn s.config_workspaces in
  assert (not p.policy_detached);
  let tile = snd (List.hd_exn p.tiles) in
  let s = mutate s (Make_independent p.workspace) in
  let s =
    mutate
      s
      (Set_tile_binding
         { tile
         ; binding =
             Pin_run
               { backend = Backend_id.of_string "fixture"
               ; id = "restore-pin"
               ; build = None
               ; label = None
               }
         })
  in
  let s = mutate s (Set_zoom { workspace = p.workspace; tile = Some tile }) in
  let geometry : W.Geometry.t = { x = 0; y = 0; width = 90; height = 11 } in
  let restore : W.Mutation.t =
    Restore_default_layout
      { workspace = p.workspace; preset = "overview"; tiles = [ "logs", geometry ] }
  in
  let restored = mutate s restore in
  let detached = List.hd_exn restored.config_workspaces in
  assert detached.policy_detached;
  assert (W.Config_workspace.equal { p with policy_detached = true } detached);
  assert (W.Workspace_id.equal (W.workspace restored p.workspace).id p.workspace);
  assert (
    Option.equal String.equal (W.workspace restored p.workspace).preset (Some "overview"));
  assert (Option.is_none (W.workspace restored p.workspace).zoomed_tile);
  assert (
    W.Context_id.equal
      (W.workspace s p.workspace).context
      (W.workspace restored p.workspace).context);
  assert (List.equal W.Context.equal s.contexts restored.contexts);
  assert (W.Binding.equal (W.tile s tile).binding (W.tile restored tile).binding);
  assert (W.Geometry.equal (W.tile restored tile).requested_geometry geometry);
  assert (W.tile restored (snd (List.nth_exn p.tiles 1))).hidden;
  let roundtrip = W.Snapshot.t_of_sexp (W.Snapshot.sexp_of_t restored) in
  assert (W.Snapshot.equal restored roundtrip);
  let reapplied = mutate roundtrip (Apply_config c) in
  assert (W.Snapshot.equal { restored with revision = reapplied.revision } reapplied);
  let repeated = mutate reapplied restore in
  assert (W.Snapshot.equal { reapplied with revision = repeated.revision } repeated);
  let expanded : C.Definition.t =
    { frozen with
      tiles = frozen.tiles @ [ { C.Tile.key = "new-key"; presentation = None } ]
    ; template =
        { frozen.template with
          views = frozen.template.views @ [ List.hd_exn frozen.template.views ]
        }
    }
  in
  let expanded_config = { c with definitions = [ expanded ] } in
  let extended = mutate repeated (Apply_config expanded_config) in
  let origin = List.hd_exn extended.config_workspaces in
  assert origin.policy_detached;
  assert (List.length extended.windows = 1 && List.length extended.workspaces = 1);
  assert (List.length extended.tiles = List.length repeated.tiles + 1);
  assert (
    List.equal
      W.Tile.equal
      repeated.tiles
      (List.take extended.tiles (List.length repeated.tiles)));
  assert (
    List.equal
      (fun (key, id) (other_key, other_id) ->
        String.equal key other_key && W.Tile_id.equal id other_id)
      p.tiles
      (List.take origin.tiles (List.length p.tiles)));
  let again = mutate extended (Apply_config expanded_config) in
  assert (W.Snapshot.equal { extended with revision = again.revision } again);
  (* Missing field on pre-marker provenance keeps the original attached behavior. *)
  let legacy : Sexp.t =
    match W.Config_workspace.sexp_of_t p with
    | Sexp.List fields ->
      Sexp.List
        (List.filter fields ~f:(function
          | Sexp.List (Sexp.Atom "policy_detached" :: _) -> false
          | _ -> true))
    | _ -> assert false
  in
  assert (not (W.Config_workspace.t_of_sexp legacy).policy_detached)
;;
