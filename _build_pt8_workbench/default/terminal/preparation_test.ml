open! Core
open Hardcaml_workbench_protocol
module H = Workspace_host
module O = Overview_tiles

let%test_unit "manual launch palette retains exact local stage receipt through \
               same-selection supersession and restaging"
  =
  let host, _, _ =
    Host_view.refinement_fixture Hardcaml_workbench_workspaces.Overview.definition
  in
  let first = Fs0_fixture.fresh_intent "local-receipt" in
  let foreign = { first with id = "other-client-same-selection-and-scope" } in
  let snapshot intent = { Fs0_fixture.snapshot with fresh_intent = Some intent } in
  let pending, ticket =
    Planned_run.begin_fresh host.planned_run ~elaboration_only:false first.selection
  in
  let pending = Planned_run.fresh_receipt pending ticket ~floor:1 (Ok first) in
  let replaced = Planned_run.receive pending ~revision:1 (snapshot foreign) in
  let commands state =
    H.launch_commands { host with planned_run = state } ~preview:None ~view_pending:false
  in
  List.iter (commands replaced) ~f:(fun command ->
    assert (Option.is_some command.unavailable);
    match command.action with
    | Launch_fresh_intent (captured, _) -> assert (Asic.Fresh.Intent.equal captured first)
    | _ -> assert false);
  let restaged = { first with id = "new-local-receipt" } in
  let pending, ticket =
    Planned_run.begin_fresh replaced ~elaboration_only:false restaged.selection
  in
  let pending = Planned_run.fresh_receipt pending ticket ~floor:2 (Ok restaged) in
  let ready = Planned_run.receive pending ~revision:2 (snapshot restaged) in
  List.iter (commands ready) ~f:(fun command ->
    assert (Option.is_none command.unavailable);
    match command.action with
    | Launch_fresh_intent (captured, _) ->
      assert (Asic.Fresh.Intent.equal captured restaged)
    | _ -> assert false)
;;

let%test_unit "selected run Elaboration uses durable workflow linkage, never latest \
               preparation or matching plan"
  =
  let host, data, find =
    Host_view.refinement_fixture Hardcaml_workbench_workspaces.Overview.definition
  in
  let intent = Fs0_fixture.fresh_intent "linked" in
  let linked =
    { (Fs0_fixture.workflow ~run:Fs0_fixture.run_a ~phase:Completed "old" intent) with
      elaboration_status = "completed"
    ; elaboration_finished_at =
        Some (Timestamp.of_time_ns (Time_ns.add Time_ns.epoch (Time_ns.Span.of_sec 12.)))
    }
  in
  let unrelated =
    { (Fs0_fixture.workflow ~run:Fs0_fixture.run_b ~phase:Failed "new" intent) with
      elaboration_status = "emission_failed"
    }
  in
  let asic = { Fs0_fixture.snapshot with workflows = [ unrelated; linked ] } in
  let data = { data with asic = Some asic } in
  let host = { host with preparation = Some (Preparation_view.fixture_snapshot ()) } in
  let row host =
    Host_view.utility_rows host data (find "stage-checklist")
    |> Option.value_exn
    |> List.hd_exn
  in
  let result = row host in
  assert (Option.equal O.Status.equal result.status (Some Completed));
  assert (Option.equal String.equal result.time (Some "12s"));
  assert (List.mem result.details "Workflow: workflow-old" ~equal:String.equal);
  assert (not (List.mem result.details "Workflow: workflow-new" ~equal:String.equal));
  let host = { host with preparation = None } in
  assert (Option.equal O.Status.equal (row host).status (Some Completed));
  let historical =
    O.workflow_for_run
      ~asic:(Some { asic with workflows = [ unrelated ] })
      ~run:Fs0_fixture.run_a
  in
  assert (Option.is_none historical);
  assert (
    String.equal
      (O.elaboration_row ~now:Time_ns.epoch ~selected:false historical).value
      "unavailable")
;;

let%test_unit "fresh manual launch captures intent, preallocation progress cancels exact \
               workflow and late allocation keeps context guard"
  =
  let host, data, find =
    Host_view.refinement_fixture Hardcaml_workbench_workspaces.Overview.definition
  in
  let intent = Fs0_fixture.fresh_intent "manual" in
  let snapshot = { Fs0_fixture.snapshot with fresh_intent = Some intent } in
  let planned_run = Planned_run.receive host.planned_run ~revision:1 snapshot in
  let host = { host with planned_run; planned_preparation = false } in
  List.iter (H.launch_commands host ~preview:None ~view_pending:false) ~f:(fun command ->
    assert (Option.is_none command.unavailable);
    match command.action with
    | Launch_fresh_intent (captured, _) ->
      assert (Asic.Fresh.Intent.equal captured intent);
      assert (Option.is_none captured.expected_plan_identity)
    | _ -> assert false);
  let target = H.launch_target host |> Option.value_exn in
  let w = Fs0_fixture.workflow "manual-key" intent in
  let snapshot = { snapshot with workflows = [ w ] } in
  assert (
    match Asic_intents.allocation ~key:w.key snapshot with
    | Awaiting -> true
    | _ -> false);
  let planned_run = Planned_run.receive planned_run ~revision:2 snapshot in
  let tile = find "planned-run" in
  let host = { host with planned_run; focus = Some tile.id } in
  let text =
    Host_view.planned_source_rows host tile
    |> List.map ~f:(fun r -> r.Planned_run.text)
    |> String.concat ~sep:"\n"
  in
  assert (String.is_substring text ~substring:"Elaboration: building");
  assert (String.is_substring text ~substring:w.id);
  assert (String.is_substring text ~substring:"x cancel workflow");
  (match snd (H.input host (Character 'x') ~commands:[]) with
   | Execute (_, Asic (Cancel_workflow id)) -> assert (String.equal id w.id)
   | _ -> assert false);
  let commands =
    Stage_launch_commands.commands host ~asic:(Some snapshot) ~remembered:None
  in
  assert (
    List.exists commands ~f:(fun c ->
      match c.H.action with
      | Asic (Cancel_workflow id) -> String.equal id w.id
      | _ -> false));
  let allocated = { w with phase = Physical; run = Some Fs0_fixture.run_b } in
  assert (
    match
      Asic_intents.allocation ~key:w.key { snapshot with workflows = [ allocated ] }
    with
    | Allocated run -> Run_ref.equal run Fs0_fixture.run_b
    | _ -> false);
  let registry = Option.value_exn host.registry in
  assert (Option.is_some (H.selection_after_allocation registry target Fs0_fixture.run_b));
  let changed =
    { registry with
      revision = registry.revision + 1
    ; contexts =
        List.map registry.contexts ~f:(fun c ->
          { c with
            selected_run = Some Fs0_fixture.run_b
          ; selection_revision = c.selection_revision + 1
          })
    }
  in
  assert (Option.is_none (H.selection_after_allocation changed target Fs0_fixture.run_b));
  let _ = data in
  List.iter [ Asic.Fresh.Phase.Failed; Cancelled; Interrupted ] ~f:(fun phase ->
    let terminal = { w with phase } in
    assert (
      match
        Asic_intents.allocation ~key:w.key { snapshot with workflows = [ terminal ] }
      with
      | Allocation_failed _ -> true
      | _ -> false))
;;

let%test_unit "emission and checklist distinguish unavailable from supported not \
               requested, including no selected ASIC run"
  =
  let host, data, find =
    Host_view.refinement_fixture Hardcaml_workbench_workspaces.Overview.definition
  in
  let empty =
    { (Preparation_view.fixture_snapshot ()) with latest = None; history = [] }
  in
  let cases =
    [ None, O.Status.Unsupported
    ; Some { empty with availability = Unavailable Not_configured }, Unsupported
    ; ( Some
          { empty with
            availability = Unavailable (Invalid_configuration "invalid fixture")
          }
      , Unsupported )
    ; Some empty, Not_requested
    ]
  in
  List.iter cases ~f:(fun (snapshot, expected) ->
    let host = { host with preparation = snapshot } in
    let check rows label =
      let row = List.find_exn rows ~f:(fun r -> String.equal r.O.label label) in
      assert (Option.equal O.Status.equal row.status (Some expected));
      assert (String.equal row.value (Preparation_view.status_label expected))
    in
    check
      (Host_view.utility_rows host data (find "preparation") |> Option.value_exn)
      "Elaboration-bundle emission";
    let check_linkage rows =
      let row = List.find_exn rows ~f:(fun r -> String.equal r.O.label "Elaboration") in
      assert (Option.equal O.Status.equal row.status (Some Unknown));
      assert (String.equal row.value "unavailable")
    in
    check_linkage
      (Host_view.utility_rows host data (find "stage-checklist") |> Option.value_exn);
    let registry = Option.value_exn host.registry in
    let registry =
      { registry with
        contexts = List.map registry.contexts ~f:(fun c -> { c with selected_run = None })
      }
    in
    check_linkage
      (Host_view.utility_rows
         { host with registry = Some registry }
         data
         (find "stage-checklist")
       |> Option.value_exn))
;;

let%test_unit "generic RTL fallback is bounded to latest exact selected project target \
               configuration and never publishes an ASIC bundle"
  =
  let target : Target.t =
    { id = Target_id.of_string "target"
    ; name = "target"
    ; top = "top"
    ; backend = Backend_id.of_string "generic"
    ; clocks = []
    ; facts = []
    }
  in
  let configuration : Configuration.t =
    { id = Configuration_id.of_string "configuration"
    ; target = target.id
    ; name = "configuration"
    ; description = None
    }
  in
  let project =
    State.test_project
      ~id:(Project_id.of_string "project")
      ~name:"generic"
      ~driver:(Available { version = Some 1 })
      ~targets:[ target ]
      ~configurations:[ configuration ]
      ()
  in
  let scope =
    Preparation_view.Rtl_scope.create
      ~project:(Some project)
      ~target:(Some target.id)
      ~configuration:(Some configuration.id)
  in
  assert (Option.is_some scope);
  assert (
    Option.is_none
      (Preparation_view.Rtl_scope.create
         ~project:(Some project)
         ~target:(Some (Target_id.of_string "other"))
         ~configuration:(Some configuration.id)));
  let job id time state =
    { (Job.create
         ~id:(Job_id.of_string id)
         ~kind:{ namespace = "project-driver"; name = "generate-rtl" }
         ~project:project.id
         ~created_at:(Timestamp.of_time_ns (Time_ns.of_int_ns_since_epoch time)))
      with
      target = Some target.id
    ; configuration = Some configuration.id
    ; state
    ; artifacts = [ Artifact_id.of_string (id ^ "/rtl") ]
    }
  in
  let old = job "old-success" 1 Complete
  and failed = job "latest-failure" 2 Failed in
  let foreign =
    { (job "other-project" 3 Complete) with project = Project_id.of_string "elsewhere" }
  in
  let other_config =
    { (job "other-config" 4 Complete) with
      configuration = Some (Configuration_id.of_string "elsewhere")
    }
  in
  let generic_build =
    { (job "generic-build" 5 Complete) with
      kind = { namespace = "dune"; name = "build" }
    }
  in
  let jobs = [ old; foreign; failed; other_config; generic_build ] in
  let rows scope jobs =
    Preparation_view.rows
      ~snapshot:None
      ~jobs
      ~project:(Some project.id)
      ~rtl_scope:scope
      ~cursor:None
      ~detail:false
      ~log_lines:(fun id -> [ "RTL LOG " ^ Job_id.to_string id ])
  in
  let projected = rows scope jobs in
  let rtl = List.last_exn projected in
  assert (String.equal rtl.label "Generic RTL (not ASIC bundle)");
  assert (Option.equal O.Status.equal rtl.status (Some Failed));
  assert (List.mem rtl.details "RTL LOG latest-failure" ~equal:String.equal);
  assert (
    List.exists rtl.details ~f:(fun s ->
      String.is_substring s ~substring:"latest-failure/rtl"));
  let emission =
    List.find_exn projected ~f:(fun r ->
      String.equal r.O.label "Elaboration-bundle emission")
  in
  assert (Option.equal O.Status.equal emission.status (Some Unsupported));
  assert (List.length (rows None jobs) = 4);
  (* Available driver component/declared target alone is not a generate-rtl capability
     advertisement. *)
  assert (List.length (rows scope []) = 4);
  List.iter
    [ Job.State.Queued; Starting; Running; Complete; Failed; Cancelled ]
    ~f:(fun state ->
      let r = List.last_exn (rows scope [ job "observed" 1 state ]) in
      assert (
        Option.equal
          O.Status.equal
          r.status
          (Some (Preparation_view.job_status (job "observed" 1 state)))))
;;

let%test_unit "preparation input form captures exact selected inputs and rejects stale \
               captured workspace"
  =
  let host, _, _ =
    Host_view.refinement_fixture Hardcaml_workbench_workspaces.Overview.definition
  in
  let capture = H.capture host |> Option.value_exn in
  let form capture =
    { host with
      H.palette =
        Some
          { capture
          ; commands = []
          ; query = "routing X=1 Y=exact"
          ; index = 0
          ; argument = Some (H.Preparation_inputs ("chosen-flow", "chosen-profile"))
          }
    }
  in
  (match snd (H.input (form capture) Enter ~commands:[]) with
   | Execute (_, Select_preparation selection) ->
     assert (
       Asic.Selection.equal
         selection
         { flow = "chosen-flow"
         ; profile = "chosen-profile"
         ; endpoint = "routing"
         ; assignments = [ "X=1"; "Y=exact" ]
         })
   | _ -> assert false);
  match
    snd
      (H.input (form { capture with revision = capture.revision - 1 }) Enter ~commands:[])
  with
  | No_effect -> ()
  | _ -> assert false
;;

let%test_unit "preparation tile keyboard inspection and history preserve stage logs and \
               physical run isolation"
  =
  let host, data, find =
    Host_view.refinement_fixture Hardcaml_workbench_workspaces.Overview.definition
  in
  let tile = find "preparation" in
  let snapshot = Preparation_view.fixture_snapshot () in
  let host = { host with preparation = Some snapshot; focus = Some tile.id } in
  let data = { data with log_lines = (fun id -> [ "LOG " ^ Job_id.to_string id ]) } in
  let press host key = H.input host key ~commands:[] in
  let before = host.registry in
  let inspected, effect = press host Enter in
  (match effect with
   | No_effect -> ()
   | _ -> assert false);
  assert (H.local inspected tile.id).utility_detail;
  let rows = Host_view.utility_rows inspected data tile |> Option.value_exn in
  let text = O.inspection_lines rows |> String.concat ~sep:"\n" in
  List.iter
    [ "LOG new-failure/build"
    ; "LOG new-failure/emit"
    ; "old-success"
    ; "bundle-old-success"
    ; "independent of selected historical ASIC run"
    ]
    ~f:(fun substring -> assert (String.is_substring text ~substring));
  let older, effect = press inspected (Character 'j') in
  (match effect with
   | No_effect -> ()
   | _ -> assert false);
  assert (Option.equal String.equal (H.local older tile.id).cursor (Some "old-success"));
  let old_text =
    Host_view.utility_rows older data tile
    |> Option.value_exn
    |> O.inspection_lines
    |> String.concat ~sep:"\n"
  in
  assert (String.is_substring old_text ~substring:"LOG old-success/emit");
  assert (phys_equal before older.registry);
  List.iter
    [ 'r', `Prepare; 'x', `Cancel; 'a', `Artifact ]
    ~f:(fun (key, expected) ->
      match snd (press older (Character key)), expected with
      | Execute (_, Prepare_project), `Prepare
      | Execute (_, Cancel_preparation), `Cancel
      | Execute (_, Preparation_artifact), `Artifact -> ()
      | _ -> assert false);
  let checklist = find "stage-checklist" in
  let items = O.checklist_items ~asic:data.asic ~run:Fs0_fixture.run_a in
  assert (String.equal (O.checklist_id (List.hd_exn items)) "preparation:elaboration");
  assert (Option.is_none (Host_view.checklist_preview host data checklist));
  let rows = Host_view.utility_rows host data checklist |> Option.value_exn in
  assert (String.equal (List.hd_exn rows).label "Elaboration");
  assert (Option.equal O.Status.equal (List.hd_exn rows).status (Some Unknown));
  let matching_summary =
    { (Option.value_exn (data.summary Fs0_fixture.run_a)) with
      Asic.Summary.plan_identity = Some "plan"
    }
  in
  let matching_data = { data with summary = (fun _ -> Some matching_summary) } in
  let relation host =
    Host_view.utility_rows host matching_data checklist
    |> Option.value_exn
    |> List.hd_exn
    |> fun row -> String.concat ~sep:"\n" row.O.details
  in
  assert (String.is_substring (relation host) ~substring:"linkage unavailable");
  let completed = Preparation_view.fixture_attempt "matched-current" Completed in
  let matched_host =
    { host with preparation = Some { snapshot with latest = Some completed } }
  in
  assert (String.is_substring (relation matched_host) ~substring:"linkage unavailable");
  List.iter [ false; true ] ~f:(fun horizontal ->
    let rendered =
      Host_view.tile_view
        ~horizontal_stages:horizontal
        host
        data
        checklist
        ~width:120
        ~height:12
      |> Host_view.plain_text
    in
    assert (String.is_substring rendered ~substring:"Elaboration"));
  let catalog = H.catalog host ~project:data.project ~jobs:[] in
  List.iter
    [ "preparation.prepare"; "preparation.cancel"; "tile.add.preparation" ]
    ~f:(fun id ->
      assert (List.exists catalog ~f:(fun command -> String.equal command.H.id id)))
;;

let%test_unit "generic verification process completion and generic RTL cannot publish \
               bundle evidence"
  =
  let job =
    { (Option.value_exn (Preparation_view.fixture_attempt "test" Completed).build_job) with
      kind = { namespace = "dune"; name = "test" }
    }
  in
  let rows =
    Preparation_view.rows
      ~snapshot:None
      ~jobs:[ job ]
      ~project:(Some job.project)
      ~rtl_scope:None
      ~cursor:None
      ~detail:false
      ~log_lines:(fun _ -> [])
  in
  let emission = List.nth_exn rows 2
  and verification = List.nth_exn rows 3 in
  assert (Option.equal O.Status.equal emission.status (Some Unsupported));
  assert (String.equal emission.value "unavailable");
  assert (String.equal verification.value "process succeeded");
  assert (
    List.exists verification.details ~f:(fun s ->
      String.is_substring s ~substring:"not semantic test pass"));
  let unsupported =
    Preparation_view.rows
      ~snapshot:
        (Some
           { (Preparation_view.fixture_snapshot ()) with
             latest = None
           ; history = []
           ; availability = Unavailable Not_configured
           })
      ~jobs:[]
      ~project:None
      ~rtl_scope:None
      ~cursor:None
      ~detail:false
      ~log_lines:(fun _ -> [])
  in
  assert (
    String.is_substring
      (List.hd_exn unsupported).value
      ~substring:"unavailable: not configured")
;;

let%test_unit "staged elaboration plan shares compact planned-run rendering and retains \
               exact expanded receipts for ready, stale, consumed and unavailable inputs"
  =
  let host, data, find =
    Host_view.refinement_fixture Hardcaml_workbench_workspaces.Overview.definition
  in
  let tile = find "planned-run" in
  let staged : Preparation.Staged.t =
    { id = "Exact-Stage-Receipt-AbC-0123456789"
    ; selection =
        { flow = "standard"
        ; profile = "balanced"
        ; endpoint = "routing"
        ; assignments = []
        }
    ; expected_plan_identity = Some "Exact-Expected-Plan-AbC"
    ; source_root = "/exact/source/with/a/long/path/界界"
    ; build_target = "exact/source.exe"
    ; source_executable = "_build/default/exact/source.exe"
    ; results_root = "/exact/results/with/a/long/path"
    ; timeout_seconds = 123
    ; environment = Inherit_daemon
    ; created_at = Timestamp.of_time_ns Time_ns.epoch
    }
  in
  let snapshot : Preparation.Snapshot.t =
    { availability = Available
    ; staged = Some staged
    ; latest = None
    ; history = []
    ; session_only = true
    ; requested_attempt = None
    }
  in
  let host = { host with planned_preparation = true; preparation = Some snapshot } in
  let expected =
    [ "ready: elaboration input plan / launch: not requested"
    ; "endpoint: elaboration"
    ; "launch: build and emit (EDA-less)"
    ; "flow: standard / profile: balanced"
    ; "assignments: (none)"
    ]
  in
  let source host = Host_view.planned_source_rows host tile in
  assert (
    List.equal
      String.equal
      (List.map (source host) ~f:(fun r -> r.Planned_run.text))
      expected);
  assert (Planned_run.equal_role (List.hd_exn (source host)).role Success);
  let cases =
    [ host, "ready:", Indicator.Ready, "staged, unconsumed"
    ; ( { host with stage_preparation = Some "Exact stale reason: inputs changed AbC" }
      , "stale:"
      , Stale
      , "Exact stale reason: inputs changed AbC" )
    ; ( { host with
          preparation =
            Some
              { snapshot with
                latest =
                  Some
                    (Preparation_view.fixture_attempt "Exact-Consuming-Attempt" Completed)
              }
        }
      , "consumed/stale:"
      , Stale
      , "Exact-Consuming-Attempt" )
    ; ( { host with
          preparation =
            Some
              { snapshot with
                availability =
                  Unavailable (Invalid_configuration "Exact configuration reason")
              }
        }
      , "unavailable:"
      , Unavailable
      , "Exact configuration reason" )
    ]
  in
  List.iter cases ~f:(fun (host, headline, indicator, reason) ->
    assert (
      Bool.equal
        (Planned_run.equal_role (List.hd_exn (source host)).role Success)
        (Poly.equal indicator Indicator.Ready));
    List.iter [ Appearance.Icons.Unicode; Ascii; None_ ] ~f:(fun icons ->
      let host = { host with appearance = { host.appearance with icons } } in
      List.iter [ true; false ] ~f:(fun compression ->
        let host =
          H.set_local
            host
            tile.id
            { H.default_local with
              presentation =
                { Tile_presentation.inherit_ with string_compression = Some compression }
            }
        in
        List.iter [ 24; 60; 100 ] ~f:(fun width ->
          let views = Host_view.planned_view_rows host tile ~width in
          assert (List.length views = 5);
          List.iter views ~f:(fun view ->
            assert (
              Bonsai_term.View.width view = width && Bonsai_term.View.height view = 1));
          let first = Host_view.plain_text (List.hd_exn views) in
          assert (String.is_substring first ~substring:headline);
          let glyph = Indicator.text icons indicator in
          assert (String.is_empty glyph || String.is_prefix first ~prefix:(glyph ^ " "));
          let shallow =
            Host_view.tile_view host data tile ~width:60 ~height:4 |> Host_view.plain_text
          in
          assert (String.is_substring shallow ~substring:"endpoint: elaboration");
          assert (not (String.is_substring shallow ~substring:"routing"));
          assert (not (String.is_substring shallow ~substring:staged.id));
          let detail =
            H.set_local host tile.id { (H.local host tile.id) with utility_detail = true }
          in
          let rows = Host_view.planned_rows detail tile ~width in
          let rendered = Host_view.planned_view_rows detail tile ~width in
          assert (List.length rows = List.length rendered);
          let text = List.map rows ~f:(fun r -> r.Planned_run.text) |> String.concat in
          List.iter
            [ staged.id
            ; staged.source_root
            ; staged.build_target
            ; staged.source_executable
            ; staged.results_root
            ; "Exact-Expected-Plan-AbC"
            ; "Timeout: 123 seconds"
            ; "Environment: Inherit_daemon"
            ; "Created:"
            ; "provider endpoint: routing"
            ; "Not a generated provider preview"
            ; "source bytes are not frozen"
            ; reason
            ]
            ~f:(fun substring -> assert (String.is_substring text ~substring));
          List.iter rendered ~f:(fun view -> assert (Bonsai_term.View.width view = width));
          (* The production scroll limit uses planned_rows; reach the actual final row. *)
          let _, _, _, body_width, body_height =
            Host_view.body_geometry detail tile ~width ~height:4
          in
          let body_rows = Host_view.planned_rows detail tile ~width:body_width in
          let scroll = Int.max 0 (List.length body_rows - body_height) in
          let scrolled =
            H.set_local detail tile.id { (H.local detail tile.id) with scroll }
          in
          let bottom =
            Host_view.tile_view scrolled data tile ~width ~height:4
            |> Host_view.plain_text
          in
          assert (
            String.is_substring
              bottom
              ~substring:(String.strip (List.last_exn body_rows).text))))));
  let assigned =
    { host with
      preparation =
        Some
          { snapshot with
            staged =
              Some
                { staged with
                  selection = { staged.selection with assignments = [ "EXACT=a b" ] }
                }
          }
    }
  in
  assert (String.equal (List.last_exn (source assigned)).text "assignments: EXACT=a b");
  List.iter
    [ None; Some { snapshot with staged = None } ]
    ~f:(fun preparation ->
      let rows = source { host with preparation } in
      assert (String.is_prefix (List.hd_exn rows).text ~prefix:"unavailable:"));
  let provider = source { host with planned_preparation = false } in
  assert (
    not
      (List.exists provider ~f:(fun row ->
         String.is_substring row.Planned_run.text ~substring:"elaboration input plan")))
;;
