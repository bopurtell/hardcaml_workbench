open! Core
open! Async
open Hardcaml_workbench_protocol
module W = Workspace
module Service = Hardcaml_workbench_backend.Workspace_service

let require condition message = if not condition then failwith message

let ok = function
  | Ok value -> value
  | Error error -> raise_s [%message "workspace error" (error : V1.Error.t)]
;;

let expect_error kind = function
  | Error (error : V1.Error.t) ->
    require (V1.Error.Kind.equal kind error.kind) "Wrong error kind"
  | Ok _ -> failwith "Expected error"
;;

let run id : Run_ref.t =
  { backend = Backend_id.of_string "fixture"; id; build = None; label = None }
;;

let mutate (s : W.Snapshot.t) mutation =
  W.apply s (Mutate { expected_revision = s.revision; mutation }) |> ok
;;

let selected s tile = (W.resolve_tile s tile |> ok).run

let select s workspace run =
  let w = W.workspace s workspace in
  let c = W.context s w.context in
  mutate
    s
    (Select_run
       { workspace
       ; context = c.id
       ; expected_selection_revision = c.selection_revision
       ; run
       })
;;

let pure_transitions () =
  let s = W.initial ~session_id:(W.Session_id.of_string "test-session") in
  W.validate s |> ok;
  let overview = List.nth_exn s.workspaces 0 in
  let timing = List.nth_exn s.workspaces 1 in
  let large = List.nth_exn s.tiles 0 in
  let compact = List.nth_exn s.tiles 1 in
  let a = Some (run "A") in
  let b = Some (run "B") in
  let s = select s overview.id a in
  require
    (Option.equal Run_ref.equal (selected s compact.id) a)
    "Linked selector did not follow";
  let old_view = W.resolve_tile s large.id |> ok in
  let old_revision = s.revision in
  let old_context_revision = (W.context s s.main_context).selection_revision in
  let s = select s timing.id b in
  require (not (W.view_is_current s old_view)) "Late query was accepted";
  require
    (Option.equal Run_ref.equal (selected s large.id) b)
    "Second selector cannot write Main";
  W.apply
    s
    (Mutate { expected_revision = old_revision; mutation = Make_independent timing.id })
  |> expect_error Conflict;
  W.apply
    s
    (Mutate
       { expected_revision = s.revision
       ; mutation =
           Select_run
             { workspace = overview.id
             ; context = s.main_context
             ; expected_selection_revision = old_context_revision
             ; run = a
             }
       })
  |> expect_error Conflict;
  let s =
    mutate s (Set_tile_binding { tile = compact.id; binding = Pin_run (run "reference") })
  in
  let s = mutate s (Make_independent timing.id) in
  let independent = (W.workspace s timing.id).context in
  require
    (not (W.Context_id.equal independent s.main_context))
    "Unlink reused Main identity";
  require
    (Option.equal Run_ref.equal (W.context s independent).selected_run b)
    "Unlink lost selection";
  let s = select s overview.id a in
  require
    (Option.equal Run_ref.equal (W.context s independent).selected_run b)
    "Independent context changed";
  let s = mutate s (Link_context { workspace = timing.id; context = s.main_context }) in
  require
    (Option.equal Run_ref.equal (selected s compact.id) (Some (run "reference")))
    "Relink changed pin";
  let s = mutate s (Set_tile_binding { tile = compact.id; binding = Follow }) in
  require
    (Option.equal Run_ref.equal (selected s compact.id) a)
    "Relink did not adopt Main";
  let s = mutate s (Set_zoom { workspace = overview.id; tile = Some large.id }) in
  let s = mutate s (Set_tile_hidden { tile = large.id; hidden = true }) in
  require
    (Option.is_none (W.workspace s overview.id).zoomed_tile)
    "Hidden tile remained zoomed";
  let s = select s timing.id b in
  require
    (Option.equal Run_ref.equal (selected s large.id) b)
    "Hidden selector owned context lifetime";
  let s = mutate s (Set_tile_hidden { tile = large.id; hidden = false }) in
  let s =
    mutate s (Set_tile_binding { tile = large.id; binding = Pin_run (run "reference") })
  in
  let s = mutate s (Move_tile { tile = large.id; workspace = timing.id }) in
  require
    (Option.equal Run_ref.equal (selected s large.id) (Some (run "reference")))
    "Move lost pin";
  let s = mutate s (Make_independent overview.id) in
  let s = select s overview.id a in
  let s = mutate s (Move_tile { tile = compact.id; workspace = overview.id }) in
  require
    (Option.equal Run_ref.equal (selected s compact.id) a)
    "Moved following tile retained source context";
  let before = W.resolve_tile s compact.id |> ok in
  let s = mutate s (Create_window { name = "Second surface" }) in
  let second = List.last_exn s.windows in
  let s = mutate s (Move_workspace { workspace = overview.id; window = second.id }) in
  let after = W.resolve_tile s compact.id |> ok in
  require
    (Option.equal W.Context_id.equal before.context after.context)
    "Window move lost context";
  let s =
    mutate
      s
      (Resize_tile
         { tile = compact.id; geometry = { x = 200; y = 100; width = 300; height = 80 } })
  in
  require
    ((W.tile s compact.id).requested_geometry.width = 300)
    "Requested size was clamped";
  W.validate { s with schema_version = 999 } |> expect_error Invalid_request;
  W.validate { s with contexts = [] } |> expect_error Not_found;
  W.validate { s with tiles = large :: large :: s.tiles } |> expect_error Invalid_request;
  W.apply
    s
    (Mutate
       { expected_revision = s.revision
       ; mutation =
           Resize_tile
             { tile = compact.id; geometry = { x = 0; y = 0; width = 0; height = 1 } }
       })
  |> expect_error Invalid_request;
  W.Snapshot.sexp_of_t s
  |> W.Snapshot.t_of_sexp
  |> fun restored ->
  require (W.Snapshot.equal s restored) "Snapshot codec lost identities"
;;

let rec remove_tree path =
  if Sys_unix.is_directory_exn ~follow_symlinks:false path
  then (
    List.iter (Sys_unix.ls_dir path) ~f:(fun name ->
      remove_tree (Filename.concat path name));
    Core_unix.rmdir path)
  else Core_unix.unlink path
;;

let persistence () =
  let state_dir = Filename_unix.temp_dir "workspace-test-" "" in
  Monitor.protect
    ~finally:(fun () -> In_thread.run (fun () -> remove_tree state_dir))
    (fun () ->
      let service = Service.create ~state_dir in
      let project_key = "/stable/project|environment-A" in
      let handle service operation =
        Service.handle service ~project_key operation >>| ok
      in
      let%bind initial = handle service Get in
      let overview = List.hd_exn initial.workspaces in
      let timing = List.nth_exn initial.workspaces 1 in
      let mutation : W.Operation.t =
        Mutate
          { expected_revision = initial.revision
          ; mutation =
              Select_run
                { workspace = overview.id
                ; context = initial.main_context
                ; expected_selection_revision = 0
                ; run = Some (run "missing-on-restore")
                }
          }
      in
      (* Two simultaneous writers must not both accept the same revision. *)
      let first = Service.handle service ~project_key mutation in
      let second = Service.handle service ~project_key mutation in
      let%bind first in
      let%bind second in
      let selected = ok first in
      expect_error Conflict second;
      let%bind restored = handle (Service.create ~state_dir) Get in
      require
        (W.Snapshot.equal selected restored)
        "Restart changed registry identity/state";
      require
        (W.Context_id.equal
           (W.workspace restored timing.id).context
           restored.main_context)
        "Restart cloned shared context";
      require
        (Option.equal
           Run_ref.equal
           (W.context restored restored.main_context).selected_run
           (Some (run "missing-on-restore")))
        "Missing provider reference was silently replaced";
      let%bind detached =
        handle
          service
          (Mutate
             { expected_revision = selected.revision
             ; mutation = Make_independent timing.id
             })
      in
      let pin = List.hd_exn detached.tiles in
      let%bind pinned =
        handle
          service
          (Mutate
             { expected_revision = detached.revision
             ; mutation =
                 Set_tile_binding { tile = pin.id; binding = Pin_run (run "pinned") }
             })
      in
      let%bind restored = handle (Service.create ~state_dir) Get in
      require (W.Snapshot.equal pinned restored) "Restart lost independent context or pin";
      let%bind other =
        Service.handle service ~project_key:"/stable/project|environment-B" Get >>| ok
      in
      require
        (not (W.Session_id.equal other.session_id restored.session_id))
        "Environments shared session";
      (* Corrupt/schema-invalid snapshots are explicit errors, never reset defaults. *)
      let path = Service.snapshot_path service ~project_key in
      let%bind () =
        In_thread.run (fun () ->
          let stored : Service.Stored.t =
            { schema_version = 999; project_key; snapshot = pinned }
          in
          Out_channel.write_all
            path
            ~data:(Sexp.to_string (Service.Stored.sexp_of_t stored)))
      in
      let%bind rejected = Service.handle (Service.create ~state_dir) ~project_key Get in
      expect_error Invalid_request rejected;
      let%bind () =
        In_thread.run (fun () -> Out_channel.write_all path ~data:"not-a-snapshot")
      in
      let%bind rejected = Service.handle (Service.create ~state_dir) ~project_key Get in
      expect_error Invalid_request rejected;
      let%bind () =
        In_thread.run (fun () ->
          let snapshot = { pinned with contexts = [] } in
          let stored : Service.Stored.t =
            { schema_version = W.schema_version; project_key; snapshot }
          in
          Out_channel.write_all
            path
            ~data:(Sexp.to_string (Service.Stored.sexp_of_t stored)))
      in
      let%bind rejected = Service.handle (Service.create ~state_dir) ~project_key Get in
      expect_error Not_found rejected;
      (* A failed write must not publish its revision to subsequent readers. *)
      let failure_dir = Filename.concat state_dir "write-failure" in
      let failure_service = Service.create ~state_dir:failure_dir in
      let%bind before = Service.handle failure_service ~project_key Get >>| ok in
      let%bind () =
        In_thread.run (fun () ->
          remove_tree failure_dir;
          Out_channel.write_all failure_dir ~data:"blocks directory creation")
      in
      let%bind failed =
        Service.handle
          failure_service
          ~project_key
          (Mutate
             { expected_revision = before.revision
             ; mutation = Make_independent (List.hd_exn before.workspaces).id
             })
      in
      expect_error Internal_failure failed;
      let%map after = Service.handle failure_service ~project_key Get >>| ok in
      require (W.Snapshot.equal before after) "Failed save advanced the read cache")
;;

let composition_persistence () =
  let module C = Workspace_config in
  let definition : C.Definition.t =
    C.definition_of_template
      ~key:"custom"
      (Workspace_template.starter "Custom" [ "logs"; "logs" ])
    |> Or_error.ok_exn
  in
  let definition : C.Definition.t =
    { definition with
      layout =
        Some
          (Columns
             [ Leaf { tile = "tile-1"; min_width = 12; min_height = 3; weight = 1 }
             ; Leaf { tile = "tile-2"; min_width = 12; min_height = 3; weight = 1 }
             ])
    }
  in
  let config : C.Resolved.t =
    { version = C.version
    ; id = "persisted-composition"
    ; definitions = [ definition ]
    ; windows =
        List.map [ "one"; "two" ] ~f:(fun key ->
          { C.Window.key
          ; name = "Window"
          ; workspaces =
              [ { C.Instance.key = "desk"; name = "Desk"; definition = Custom "custom" } ]
          })
    }
  in
  let state_dir = Filename_unix.temp_dir "workspace-composition-" "" in
  Monitor.protect
    ~finally:(fun () -> In_thread.run (fun () -> remove_tree state_dir))
    (fun () ->
      let project_key = "/composition|environment" in
      let service = Service.create ~state_dir in
      let handle service operation = Service.handle service ~project_key operation in
      (* Get persists placeholders; a fresh service can still initialize them. *)
      let%bind (_ : W.Snapshot.t) = handle service Get >>| ok in
      let service = Service.create ~state_dir in
      let first = handle service (Initialize_config config) in
      let second =
        handle service (Initialize_config { config with id = "losing-initializer" })
      in
      let%bind first = first >>| ok in
      let%bind second = second >>| ok in
      require (W.Snapshot.equal first second) "Second initializer replaced the winner";
      require (List.length first.windows = 2) "Composition not initialized atomically";
      let p = List.hd_exn first.config_workspaces in
      let tile = snd (List.hd_exn p.tiles) in
      let%bind edited =
        handle
          service
          (Mutate
             { expected_revision = first.revision
             ; mutation =
                 Set_tile_binding { tile; binding = Pin_run (run "retained-pin") }
             })
        >>| ok
      in
      let operation : W.Operation.t =
        Mutate { expected_revision = edited.revision; mutation = Apply_config config }
      in
      let a = handle service operation in
      let b = handle service operation in
      let%bind applied = a >>| ok in
      let%bind rejected = b in
      expect_error Conflict rejected;
      require
        (List.equal W.Tile.equal edited.tiles applied.tiles)
        "Reapply changed live tiles";
      (* The new service receives no configuration or source filename. *)
      let%bind restored = handle (Service.create ~state_dir) Get >>| ok in
      require
        (W.Snapshot.equal applied restored)
        "Restart lost composition provenance/policy";
      require
        (C.Definition.equal
           (List.hd_exn restored.config_workspaces).definition
           definition)
        "Custom layout did not survive restart";
      let%bind applied =
        handle
          service
          (Mutate
             { expected_revision = applied.revision
             ; mutation =
                 Restore_default_layout
                   { workspace = p.workspace
                   ; preset = "overview"
                   ; tiles = [ "logs", { x = 0; y = 0; width = 80; height = 12 } ]
                   }
             })
        >>| ok
      in
      let%bind restored = handle (Service.create ~state_dir) Get >>| ok in
      require
        (W.Snapshot.equal applied restored)
        "Restart lost restored preset or detached config policy";
      require
        (List.hd_exn restored.config_workspaces).policy_detached
        "Restart reattached obsolete configured layout/presentation";
      let%bind repeated =
        handle
          service
          (Mutate { expected_revision = applied.revision; mutation = Apply_config config })
        >>| ok
      in
      require
        (W.Snapshot.equal { applied with revision = repeated.revision } repeated)
        "Reapply after Restore duplicated identity or reattached config policy";
      let applied = repeated in
      let bad = { config with id = "bad id" } in
      let%bind rejected =
        handle
          service
          (Mutate { expected_revision = applied.revision; mutation = Apply_config bad })
      in
      expect_error Invalid_request rejected;
      let%bind unchanged = handle service Get >>| ok in
      require (W.Snapshot.equal applied unchanged) "Invalid apply published state";
      let%bind () =
        In_thread.run (fun () ->
          let p = List.hd_exn applied.config_workspaces in
          let stored : Service.Stored.t =
            { schema_version = W.schema_version
            ; project_key
            ; snapshot = { applied with config_workspaces = [ { p with tiles = [] } ] }
            }
          in
          Out_channel.write_all
            (Service.snapshot_path service ~project_key)
            ~data:(Sexp.to_string (Service.Stored.sexp_of_t stored)))
      in
      let%bind rejected = handle (Service.create ~state_dir) (Initialize_config config) in
      expect_error Invalid_request rejected;
      (* A failed composition save cannot leak windows, mappings, or revision. *)
      let failure_dir = Filename.concat state_dir "failed-composition" in
      let failure_service = Service.create ~state_dir:failure_dir in
      let%bind before = handle failure_service Get >>| ok in
      let%bind () =
        In_thread.run (fun () ->
          remove_tree failure_dir;
          Out_channel.write_all failure_dir ~data:"blocks directory creation")
      in
      let%bind rejected = handle failure_service (Initialize_config config) in
      expect_error Internal_failure rejected;
      let%bind after = handle failure_service Get >>| ok in
      require (W.Snapshot.equal before after) "Failed initialize published composition";
      let%bind rejected =
        handle
          failure_service
          (Mutate { expected_revision = before.revision; mutation = Apply_config config })
      in
      expect_error Internal_failure rejected;
      let%map after = handle failure_service Get >>| ok in
      require
        (W.Snapshot.equal before after)
        "Failed additive apply published composition")
;;

let blank_workspace_persistence () =
  let state_dir = Filename_unix.temp_dir "blank-workspace-" "" in
  Monitor.protect
    ~finally:(fun () -> In_thread.run (fun () -> remove_tree state_dir))
    (fun () ->
      let project_key = "/blank|environment" in
      let handle service operation = Service.handle service ~project_key operation in
      let service = Service.create ~state_dir in
      let%bind before = handle service Get >>| ok in
      let window = (List.hd_exn before.workspaces).window in
      let operation : W.Operation.t =
        Mutate
          { expected_revision = before.revision
          ; mutation =
              Create_workspace
                { window; name = "Workspace 1"; context = before.main_context }
          }
      in
      let%bind created = handle service operation >>| ok in
      let blank = List.last_exn created.workspaces in
      require (List.equal W.Tile.equal before.tiles created.tiles) "Creation added tiles";
      require (W.Context_id.equal blank.context created.main_context) "Not Main-linked";
      let%bind rejected = handle service operation in
      expect_error Conflict rejected;
      let service = Service.create ~state_dir in
      let%bind restored = handle service Get >>| ok in
      require (W.Snapshot.equal created restored) "Restart lost blank workspace";
      let%bind populated =
        handle
          service
          (Mutate
             { expected_revision = restored.revision
             ; mutation =
                 Create_tile
                   { workspace = blank.id
                   ; kind = "logs"
                   ; geometry = { x = 0; y = 0; width = 40; height = 10 }
                   }
             })
        >>| ok
      in
      let%bind with_selection =
        handle
          service
          (Mutate
             { expected_revision = populated.revision
             ; mutation =
                 Select_run
                   { workspace = blank.id
                   ; context = restored.main_context
                   ; expected_selection_revision = 0
                   ; run = Some (run "shared")
                   }
             })
        >>| ok
      in
      let%map restored = handle (Service.create ~state_dir) Get >>| ok in
      require (W.Snapshot.equal with_selection restored) "Restart lost populated workspace";
      require
        (Option.equal
           Run_ref.equal
           (selected restored (List.last_exn restored.tiles).id)
           (Some (run "shared")))
        "Added tile does not follow shared selection")
;;

let run_tests () =
  pure_transitions ();
  let%bind () = persistence () in
  let%bind () = blank_workspace_persistence () in
  composition_persistence ()
;;

let () =
  Command_unix.run
    (Command.async
       ~summary:"Workspace reducer and persistence contracts"
       (Command.Param.return run_tests))
;;
