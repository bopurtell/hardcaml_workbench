open! Core
open Async
open Hardcaml_workbench_protocol
module H = Terminal_presentation.Workspace_host
module N = Terminal_presentation.Navigation_preferences
module T = Terminal_presentation.Testing_workspace
module Timing = Terminal_presentation.Timing_workspace
module L = Terminal_presentation.Retained_hydration
module W = Workspace
module P = Hardcaml_workbench_workspaces

let registry () =
  let apply snapshot mutation =
    W.apply
      snapshot
      (Mutate { expected_revision = snapshot.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let registry = W.initial ~session_id:(W.Session_id.of_string "navigation-restart") in
  let testing = List.hd_exn registry.workspaces in
  let timing = List.last_exn registry.workspaces in
  let registry =
    apply registry (P.Definition.apply P.Testing.definition ~workspace:testing.id)
  in
  let registry =
    apply registry (P.Definition.apply P.Timing.definition ~workspace:timing.id)
  in
  let context = W.context registry timing.context in
  apply
    registry
    (Select_run
       { workspace = timing.id
       ; context = context.id
       ; expected_selection_revision = context.selection_revision
       ; run = Some Terminal_presentation.Fs0_fixture.run_a
       })
;;

let find registry kind =
  List.find_exn registry.W.Snapshot.tiles ~f:(fun tile -> String.equal tile.kind kind)
;;

let timing_snapshot ?(digest = "saved-source") run =
  let row : Asic_inspection.Row.t =
    { id = "saved-row"
    ; name = "endpoint/Q"
    ; category = "path"
    ; producer = "sta"
    ; corner = None
    ; group = None
    ; value = Some (-1.)
    ; unit_ = Some "ns"
    ; status = "violated"
    ; source = "source"
    ; fields = []
    }
  in
  let index : Asic_inspection.Index.t =
    { run
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = digest
    ; execution_file = "/execution"
    ; execution_sha256 = "sha"
    ; rows = [ row ]
    ; diagnostics = []
    ; truncated = false
    ; cached_unverified = true
    ; analysis = None
    ; times = Evidence_time.Index.empty
    }
  in
  { Terminal_presentation.Fs0_fixture.snapshot with inspections = [ index ] }
;;

let expected registry =
  let testing = find registry "simulation-artifacts" in
  let timing = find registry "timing-paths" in
  let host = H.receive H.empty registry in
  let host =
    H.set_testing
      host
      testing.id
      ( ref ()
      , "current-project"
      , T.restore_selection
          T.empty
          ~attempt:"old-attempt-outside-newest-page"
          ~case_id:(Some "saved-case")
          ~artifact:
            (Some { id = "saved-vcd"; sha256 = Some (String.make 64 'a'); size = Some 42 })
      )
  in
  let view =
    Timing.create
      ~generation:0
      ~run:Terminal_presentation.Fs0_fixture.run_a
      ~stage:"signoff"
  in
  let host =
    H.set_timing
      host
      timing
      (Timing.attach_retained
         { view with filter = "endpoint/Q"; selected = Some "saved-row" }
         (timing_snapshot view.run))
  in
  let host = H.switch host timing.workspace in
  { host with focus = Some timing.id }
;;

let check_restore saved registry =
  let fresh = H.receive H.empty registry in
  let restored =
    H.restore_navigation_focus saved fresh
    |> fun host ->
    H.restore_navigation_selections saved host ~scope:"replacement-project-id"
  in
  let testing = find registry "simulation-artifacts" in
  let timing = find registry "timing-paths" in
  assert (Option.equal W.Workspace_id.equal restored.active (Some timing.workspace));
  assert (Option.equal W.Tile_id.equal restored.focus (Some timing.id));
  let _, scope, state = Option.value_exn (H.testing restored testing.id) in
  assert (String.equal scope "replacement-project-id");
  assert (
    Option.equal
      String.equal
      (T.view state).attempt
      (Some "old-attempt-outside-newest-page"));
  assert (Option.equal String.equal (T.view state).case_id (Some "saved-case"));
  assert (String.equal (Option.value_exn (T.artifact_identity state)).id "saved-vcd");
  assert (Option.is_none (T.artifact state));
  let view = Option.value_exn (H.timing restored timing) in
  assert (String.equal view.stage "signoff" && String.equal view.filter "endpoint/Q");
  assert (Option.is_none view.selected);
  let restored = H.reconcile_navigation_timing restored None in
  assert (Option.is_none (Option.value_exn (H.timing restored timing)).selected);
  let restored =
    H.reconcile_navigation_timing restored (Some (timing_snapshot view.run))
  in
  let view = Option.value_exn (H.timing restored timing) in
  assert (Option.equal String.equal view.selected (Some "saved-row"));
  (* Inactive Testing state survives local switches and same-session reconnect. *)
  let switched =
    H.switch restored testing.workspace |> fun h -> H.switch h timing.workspace
  in
  let same = H.reconnect switched ~replacement:false |> fun h -> H.receive h registry in
  assert (
    Option.equal
      String.equal
      (H.simulation same testing.id).attempt
      (Some "old-attempt-outside-newest-page"));
  let replacement =
    H.receive H.empty { registry with session_id = W.Session_id.of_string "different" }
  in
  assert (List.is_empty (H.valid_navigation_workspaces saved replacement));
  let removed =
    H.receive
      H.empty
      { registry with
        tiles =
          List.filter registry.tiles ~f:(fun tile ->
            not (W.Tile_id.equal tile.id testing.id))
      }
  in
  let removed =
    H.restore_navigation_selections saved removed ~scope:"replacement-project-id"
  in
  assert (List.is_empty removed.testing);
  (* A second capture before any detail arrives retains the exact saved evidence. *)
  let captured =
    Option.value_exn (H.navigation_preferences ~project_key:saved.N.project_key restored)
  in
  let pref =
    List.find_exn captured.workspaces ~f:(fun p ->
      String.equal p.id (W.Workspace_id.to_string testing.workspace))
  in
  assert (
    String.equal
      (Option.value_exn (Option.value_exn pref.testing).artifact).id
      "saved-vcd")
;;

let restoration_regressions () =
  let registry = registry () in
  let host = expected registry in
  let project_key = "navigation-fixture/inherited" in
  let saved = Option.value_exn (H.navigation_preferences ~project_key host) in
  let fresh = H.receive H.empty registry in
  (* Unknown input must not suppress a delayed sidecar's active/focus restoration. *)
  let unchanged, _ = H.input fresh (Character '\000') ~commands:[] in
  let active, focus, selections = H.navigation_input_changes fresh unchanged in
  assert ((not active) && Option.is_none focus && List.is_empty selections);
  let restored = H.restore_navigation_focus saved unchanged in
  assert (Option.equal W.Workspace_id.equal restored.active host.active);
  assert (Option.equal W.Tile_id.equal restored.focus host.focus);
  (* Tab's actual focus override is independent of saved inactive-workspace focus. *)
  let focused, _ = H.input fresh Focus ~commands:[] in
  let active, focus, _ = H.navigation_input_changes fresh focused in
  assert ((not active) && Option.is_some focus);
  let restored =
    H.restore_navigation_focus
      saved
      focused
      ~restore_active:false
      ~preserve_focus:(Option.to_list focus)
  in
  assert (Option.equal W.Tile_id.equal restored.focus focused.focus);
  assert (Option.equal W.Workspace_id.equal restored.active focused.active);
  (* Sidebar Enter returns the same Switch effect consumed by main's command route. *)
  let sidebar = find registry "workspace-tabs" in
  let sidebar_host = { fresh with focus = Some sidebar.id } in
  let browsed = H.browse_workspaces sidebar_host sidebar.id ~delta:1 in
  let before_switch, effect = H.input browsed Enter ~commands:[] in
  assert (Option.equal W.Workspace_id.equal before_switch.active browsed.active);
  (match effect with
   | Execute (_, Switch id) ->
     assert (
       W.Workspace_id.equal
         id
         (Option.value_exn (H.workspace_cursor browsed sidebar.id)).id)
   | _ -> failwith "Sidebar bypassed activation effect");
  let tile = find registry "timing-paths" in
  let check_rejected saved snapshot =
    let restored = H.restore_navigation_selections saved fresh ~scope:"project" in
    let restored = H.reconcile_navigation_timing restored (Some snapshot) in
    let view = Option.value_exn (H.timing restored tile) in
    assert (Option.is_none view.selected && Option.is_some view.error);
    assert (Run_ref.equal view.run Terminal_presentation.Fs0_fixture.run_a);
    (* Ordinary cached attachment cannot silently choose an equal row ID afterward. *)
    let normalized = H.set_timing restored tile (Timing.attach_retained view snapshot) in
    let guarded = H.reconcile_navigation_timing normalized (Some snapshot) in
    assert (Option.is_none (Option.value_exn (H.timing guarded tile)).selected)
  in
  let change_timing f =
    { saved with
      workspaces =
        List.map saved.workspaces ~f:(fun w -> { w with timing = Option.map w.timing ~f })
    }
  in
  check_rejected
    (change_timing (fun timing -> { timing with run = None; source_digest = None }))
    (timing_snapshot Terminal_presentation.Fs0_fixture.run_a);
  check_rejected
    (change_timing (fun timing ->
       { timing with
         run =
           Some
             (Sexp.to_string_mach
                (Run_ref.sexp_of_t Terminal_presentation.Fs0_fixture.run_b))
       }))
    (timing_snapshot Terminal_presentation.Fs0_fixture.run_a);
  check_rejected
    saved
    (timing_snapshot ~digest:"changed-source" Terminal_presentation.Fs0_fixture.run_a)
;;

let suite_artifact_regression () =
  let registry = registry () in
  let tile = find registry "simulation-artifacts" in
  let suite : Simulation.Suite.t =
    { id = "suite"; label = "Suite"; default_seed = "7"; cases = []; parameters = [] }
  in
  let artifact : Simulation.Artifact.t =
    { id = "suite-vcd"
    ; attempt_id = "suite-attempt"
    ; case_id = None
    ; label = "Suite VCD"
    ; kind = "waveform"
    ; media_type = "text/vcd"
    ; size = Some 42
    ; sha256 = Some (String.make 64 'a')
    ; availability = Available
    }
  in
  let attempt : Simulation.Attempt.t =
    { id = artifact.attempt_id
    ; job = Job_id.of_string "job"
    ; project_root = "/project"
    ; created_at = "now"
    ; parent = None
    ; captured =
        { selection = Terminal_presentation.Simulation_view.selection suite
        ; discovery_digest = "digest"
        ; provider_executable = "/synthetic"
        ; provider_args = []
        ; environment = V1.Environment_selection.Inherit_daemon
        }
    ; lifecycle = Finished
    ; outcome = Passed
    ; exit_code = Some 0
    ; diagnostic = None
    ; progress = None
    ; cases = []
    ; artifacts = [ artifact ]
    ; next_sequence = 0
    ; recent_events = []
    ; execution_timing = None
    }
  in
  let snapshot : Simulation.Snapshot.t =
    { configured = true
    ; discovery = Some { protocol_version = 1; suites = [ suite ] }
    ; discovery_digest = Some "digest"
    ; discovery_job = None
    ; discovery_error = None
    ; attempts = []
    ; next_before = None
    ; history_error = None
    ; detail = Some attempt
    ; byte_page = None
    }
  in
  let receive state =
    let state = T.begin_request state in
    let view = T.view state in
    T.receive
      state
      ~ticket:view.request
      ~selected:view.attempt
      (Observe attempt.id)
      (Ok snapshot)
  in
  let state = T.select_attempt T.empty attempt.id |> receive in
  assert (Option.is_none (T.view state).case_id);
  assert (Option.is_some (T.artifact state));
  let host =
    H.set_testing (H.receive H.empty registry) tile.id (ref (), "project", state)
  in
  let saved =
    Option.value_exn (H.navigation_preferences ~project_key:"suite-artifact" host)
  in
  let decoded = N.decode ~project_key:"suite-artifact" (N.encode saved) in
  let restored =
    H.restore_navigation_selections
      decoded
      (H.receive H.empty registry)
      ~scope:"new-project"
  in
  let _, _, state = Option.value_exn (H.testing restored tile.id) in
  assert (
    Option.is_none (T.view state).case_id && Option.is_some (T.artifact_identity state));
  assert (
    Simulation.Artifact.equal artifact (Option.value_exn (T.artifact (receive state))))
;;

let coordinator_regressions () =
  let module C = L.Coordinator in
  let module Load = L.Load in
  let load = Load.create () in
  let old = Load.begin_load load in
  Load.reconnect load ~replacement:false;
  assert (not (Load.loaded load "project"));
  let replacement = Load.begin_load load in
  assert (not (Load.complete load old "project"));
  assert (not (Load.ready load));
  assert (Load.complete load replacement "project");
  assert (Load.loaded load "project");
  Load.reconnect load ~replacement:false;
  assert (Load.loaded load "project");
  let coordinator = C.create () in
  let first_response = Ivar.create ()
  and rerun_response = Ivar.create () in
  let calls = ref 0
  and saves = ref 0
  and dirty = ref true in
  let idle () =
    assert (not (C.busy coordinator));
    if !dirty
    then (
      incr saves;
      dirty := false);
    return ()
  in
  let work () =
    incr calls;
    Ivar.read (if !calls = 1 then first_response else rerun_response)
  in
  (* Exactly the production refresh/start + refresh_host/join sequence. *)
  let started = C.request coordinator ~idle work in
  let joined = C.request coordinator ~idle work in
  assert (phys_equal started joined && !calls = 1);
  (* Activation may explicitly invalidate while the periodic caller only joins. *)
  let activation = C.request coordinator ~reschedule:true ~idle work in
  assert (phys_equal started activation);
  Ivar.fill_exn first_response ();
  let%bind () = joined in
  assert (!saves = 1);
  let%bind () = Scheduler.yield () in
  assert (!calls = 2 && C.busy coordinator);
  dirty := true;
  let joined = C.request coordinator ~idle work in
  Ivar.fill_exn rerun_response ();
  let%bind () = joined in
  assert (!saves = 2 && !calls = 2 && not (C.busy coordinator));
  printf
    "coordinator: reconnect-during-load, join vs invalidation, idle save before rerun \
     passed\n\
     %!";
  return ()
;;

let simulation_refresh_regressions () =
  let registry = registry () in
  let tile = find registry "simulation-attempts" in
  let host = H.receive H.empty registry in
  let host = H.establish_testing_scope host tile.id ~scope:"old-project" in
  let host = H.update_testing host tile.id T.begin_request in
  let identity = H.simulation_identity host tile.id in
  let same = H.establish_testing_scope host tile.id ~scope:"old-project" in
  assert (phys_equal identity (H.simulation_identity same tile.id));
  assert ((H.simulation same tile.id).busy);
  let replacement = H.establish_testing_scope host tile.id ~scope:"new-project" in
  assert (not (phys_equal identity (H.simulation_identity replacement tile.id)));
  assert (not (H.simulation replacement tile.id).busy);
  let summary id : Simulation.Summary.t =
    { id
    ; job = Job_id.of_string "retained-job"
    ; suite = "suite"
    ; seed = "7"
    ; created_at = "now"
    ; parent = None
    ; lifecycle = Finished
    ; outcome = Passed
    ; execution_timing = None
    }
  in
  let snapshot : Simulation.Snapshot.t =
    { configured = true
    ; discovery = None
    ; discovery_digest = None
    ; discovery_job = None
    ; discovery_error = None
    ; attempts = [ summary "newest" ]
    ; next_before = Some "older"
    ; history_error = None
    ; detail = None
    ; byte_page = None
    }
  in
  Deferred.List.iter ~how:`Sequential [ "normal"; "page"; "restore"; "replacement" ] ~f:(fun scenario ->
    let state =
      ref (if String.equal scenario "page" then T.select_attempt T.empty "retained" else T.empty)
    in
    let valid = ref true in
    let calls = Queue.create () in
    let request operation =
      state := T.begin_request !state;
      let issued = T.view !state in
      let response = Ivar.create () in
      Queue.enqueue calls (operation, response);
      let%map snapshot = Ivar.read response in
      state
      := T.receive
           !state
           ~ticket:issued.request
           ~selected:issued.attempt
           operation
           (Ok snapshot)
    in
    let lanes = L.create () in
    let refresh () =
      L.run lanes ~key:"testing" (fun () ->
        L.refresh_simulation
          ~current:(fun () -> if !valid then Some (T.view !state) else None)
          ~request)
    in
    let pending = refresh () in
    let joined = refresh () in
    assert (phys_equal pending joined && Queue.length calls = 1);
    let operation, response = Queue.dequeue_exn calls in
    assert (Simulation.Operation.equal operation Get);
    let page =
      match scenario with
      | "page" -> Some (request (History { before = Some "older"; limit = 25 }))
      | "restore" ->
        state := T.restore_selection !state ~attempt:"saved-old" ~case_id:None ~artifact:None;
        assert (not (T.view !state).busy);
        None
      | "replacement" -> valid := false; None
      | _ -> None
    in
    Ivar.fill_exn response snapshot;
    let%bind () = Scheduler.yield_until_no_jobs_remain () in
    (match scenario with
     | "normal" ->
       assert (not (Deferred.is_determined pending));
       let operation, response = Queue.dequeue_exn calls in
       assert (Simulation.Operation.equal operation (Observe "newest"));
       Ivar.fill_exn response snapshot
     | "page" ->
       assert (Deferred.is_determined pending && (T.view !state).busy);
       let operation, response = Queue.dequeue_exn calls in
       assert (Simulation.Operation.equal operation (History { before = Some "older"; limit = 25 }));
       Ivar.fill_exn response { snapshot with attempts = [ summary "older" ]; next_before = None }
     | _ -> assert (Deferred.is_determined pending));
    let%bind () = pending in
    let%bind () = Option.value page ~default:(return ()) in
    assert (Queue.is_empty calls);
    (match scenario with
     | "page" ->
       assert ((T.view !state).older && not (T.view !state).busy);
       assert (String.equal (List.hd_exn (Option.value_exn (T.view !state).snapshot).attempts).id "older");
       let next = refresh () in
       let operation, response = Queue.dequeue_exn calls in
       assert (Simulation.Operation.equal operation (Observe "retained"));
       Ivar.fill_exn response snapshot;
       let%map () = next in
       assert ((T.view !state).older);
       let page = Option.value_exn (T.view !state).snapshot in
       assert (Option.is_none page.next_before);
       assert (String.equal (List.hd_exn page.attempts).id "older")
     | "restore" ->
       assert (Option.equal String.equal (T.view !state).attempt (Some "saved-old"));
       let next = refresh () in
       let _, response = Queue.dequeue_exn calls in
       Ivar.fill_exn response snapshot;
       let%bind () = Scheduler.yield_until_no_jobs_remain () in
       let operation, response = Queue.dequeue_exn calls in
       assert (Simulation.Operation.equal operation (Observe "saved-old"));
       Ivar.fill_exn response snapshot;
       next
     | _ -> return ()))
;;

let held_scheduler () =
  let lanes = L.create () in
  let updates = Ivar.create ()
  and waveform = Ivar.create ()
  and asic = Ivar.create () in
  let calls = ref [] in
  let held key ivar =
    L.run lanes ~key (fun () ->
      calls := key :: !calls;
      Ivar.read ivar)
  in
  let _updates = held "Updates" updates in
  let _waveform = held "waveform" waveform in
  let asic_read = held "ASIC Get" asic in
  let coalesced = held "ASIC Get" asic in
  assert (phys_equal asic_read coalesced);
  let got = Ivar.create () in
  let simulation =
    L.run lanes ~key:"Testing Get/Observe" (fun () ->
      calls := "Simulation Get" :: !calls;
      calls := "Simulation Observe old-attempt-outside-newest-page" :: !calls;
      Ivar.fill_exn got ();
      return ())
  in
  let%bind () = Ivar.read got in
  assert (not (Deferred.is_determined asic_read));
  assert ((not (Ivar.is_full updates)) && not (Ivar.is_full waveform));
  assert (List.count !calls ~f:(String.equal "ASIC Get") = 1);
  assert (
    not
      (List.exists !calls ~f:(fun call ->
         String.is_substring call ~substring:"Discover"
         || String.is_substring call ~substring:"Launch")));
  (* A replacement lane starts even while its predecessor's response remains held. *)
  let replacement = L.create () in
  let%bind () = L.run replacement ~key:"ASIC Get" (fun () -> return ()) in
  assert (not (Deferred.is_determined asic_read));
  Ivar.fill_exn asic ();
  Ivar.fill_exn updates ();
  Ivar.fill_exn waveform ();
  let%map () = Deferred.all_unit [ asic_read; simulation ] in
  printf
    "held scheduler: independent Get/Observe completed before Updates/waveform/ASIC \
     release\n\
     %!"
;;

let main () =
  let argv = Sys.get_argv () in
  let mode = argv.(1) in
  if String.equal mode "scheduler"
  then (
    restoration_regressions ();
    suite_artifact_regression ();
    let%bind () = coordinator_regressions () in
    let%bind () = simulation_refresh_regressions () in
    held_scheduler ())
  else (
    let state_directory = argv.(2) in
    let project_key = "navigation-fixture/inherited" in
    let registry = registry () in
    (match mode with
     | "write" ->
       N.save
         ~state_directory
         (Option.value_exn (H.navigation_preferences ~project_key (expected registry)))
     | "read" ->
       check_restore (Option.value_exn (N.load ~state_directory ~project_key)) registry
     | _ -> failwith "unknown probe mode");
    return ())
;;

let () =
  don't_wait_for
    (let%bind () = main () in
     Shutdown.exit 0);
  never_returns (Scheduler.go ())
;;
