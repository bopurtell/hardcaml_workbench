open! Core
open Hardcaml_workbench_protocol
module H = Workspace_host
module W = Workspace
module C = Stage_launch_commands

let fixture () =
  let selection : Asic.Selection.t =
    { flow = "selected"
    ; profile = "balanced"
    ; endpoint = "synthesis"
    ; assignments = [ "X=1" ]
    }
  in
  let stage id : Asic.Stage.t =
    { id
    ; name = String.capitalize id
    ; status = Completed
    ; requested = true
    ; reason = None
    ; action = None
    ; execution_timing = None
    }
  in
  let preview : Asic.Preview.t =
    { selection; plan_identity = "captured-plan"; plan_json = "{}" }
  in
  let snapshot =
    { Fs0_fixture.snapshot with
      flows =
        [ { Asic.Flow.id = "selected"
          ; profiles = [ "balanced" ]
          ; default_profile = "balanced"
          ; fresh_stage_endpoints = [ "synthesis"; "routing"; "timing"; "metal-fill" ]
          }
        ; { id = "unselected"
          ; profiles = [ "other" ]
          ; default_profile = "other"
          ; fresh_stage_endpoints = [ "unselected-only" ]
          }
        ]
    ; catalog_default = Some { flow = "selected"; profile = "balanced" }
    ; preview = Some preview
    ; operations =
        [ { Asic.Pending.key =
              List.hd_exn (Plain_rpc.keys (Plan selection) Fs0_fixture.snapshot)
          ; kind = "plan"
          ; state = "completed"
          ; run = None
          ; error = None
          ; activity = Unreported
          }
        ]
    ; runs =
        [ { (Fs0_fixture.run Fs0_fixture.run_a) with
            selection = Some selection
          ; stages = List.map [ "synthesis"; "placement"; "routing"; "signoff" ] ~f:stage
          }
        ]
    }
  in
  let registry = W.initial ~session_id:(W.Session_id.of_string "launch-palette") in
  let overview = List.hd_exn registry.workspaces in
  let registry =
    W.apply
      registry
      (Mutate
         { expected_revision = registry.revision
         ; mutation =
             Hardcaml_workbench_workspaces.Definition.apply
               Hardcaml_workbench_workspaces.Overview.definition
               ~workspace:overview.id
         })
    |> Result.ok
    |> Option.value_exn
  in
  let registry =
    { registry with
      contexts =
        List.map registry.contexts ~f:(fun context ->
          if W.Context_id.equal context.id overview.context
          then { context with selected_run = Some Fs0_fixture.run_a }
          else context)
    }
  in
  let checklist =
    List.find_exn registry.tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace overview.id
      && String.equal tile.kind "stage-checklist")
  in
  let host =
    { (H.receive H.empty registry) with
      focus = Some checklist.id
    ; quick_launch_view = false
    ; planned_preparation = false
    ; preparation =
        Some { (Preparation_view.fixture_snapshot ()) with latest = None; history = [] }
    ; planned_run = Planned_run.receive Planned_run.empty ~revision:1 snapshot
    }
  in
  let host =
    H.set_local
      host
      checklist.id
      { (H.local host checklist.id) with
        cursor = Some "routing"
      ; stage_run = Some Fs0_fixture.run_a
      }
  in
  host, checklist, snapshot, selection
;;

let full_catalog host snapshot selection =
  (* Include actual settings, aliases, project/tile/workspace actions, and the same launch
     families assembled by main, with competing settings deliberately placed first. *)
  H.contextual
    host
    (H.catalog host ~project:(Some Baseline_fixture.project) ~jobs:[]
     @ [ H.command
           "fixture.settings"
           "Quick launch behavior diagnostics"
           "launch and view settings"
           H.Toggle_chrome
       ; H.command
           "fixture.alias"
           "Inspect syntax report"
           "launch synth metadata"
           H.Toggle_chrome
       ]
     @ C.commands host ~asic:(Some snapshot) ~remembered:(Some selection)
     @ H.launch_commands host ~preview:snapshot.preview ~view_pending:false)
;;

let open_palette host commands =
  List.fold [ ' '; 'c'; 'c' ] ~init:host ~f:(fun host c ->
    fst (H.input host (Character c) ~commands))
;;

let selected host =
  let palette = Option.value_exn host.H.palette in
  List.nth_exn (H.matches palette) palette.index
;;

let type_query host commands query =
  String.fold query ~init:host ~f:(fun host c ->
    let next, _ = H.input host (Character c) ~commands in
    let palette = Option.value_exn next.palette in
    assert (palette.index = 0);
    next)
;;

let%test_unit "incremental action-first launch queries rank actual catalog ahead of \
               settings and aliases"
  =
  let host, _, snapshot, selection = fixture () in
  let catalog = full_catalog host snapshot selection in
  List.iter
    [ "launch and vi", "asic.launch-view"
    ; "quick lau", "stage.quick-selected"
    ; "quick launch", "stage.quick-selected"
    ; "launch syn", "stage.launch-view.synthesis"
    ; "launch elab", "preparation.quick-launch"
    ; "quick launch synthesis", "stage.launch-view.synthesis"
    ; "quick launch elaboration", "preparation.quick-launch"
    ]
    ~f:(fun (query, expected) ->
      let typed = type_query (open_palette host catalog) catalog query in
      let actual = (selected typed).id in
      if not (String.equal actual expected)
      then failwithf "query %S selected %S rather than %S" query actual expected ());
  let typed =
    type_query (open_palette host catalog) catalog "quick-launch behavior keep"
  in
  assert (String.equal (selected typed).id "launch.quick.no-view");
  List.iter catalog ~f:(fun command ->
    match command.H.action with
    | Set_quick_launch_view _ ->
      assert (not (String.is_substring command.title ~substring:"R "))
    | _ -> ())
;;

let%test_unit "manual arrows and Enter retain explicit choice; editing and backspace \
               follow new top rank"
  =
  let host, _, snapshot, selection = fixture () in
  let catalog = full_catalog host snapshot selection in
  let typed = type_query (open_palette host catalog) catalog "launch and vi" in
  let moved, _ = H.input typed Next ~commands:catalog in
  assert (not (String.equal (selected typed).id (selected moved).id));
  let chosen = selected moved in
  let unchanged =
    { moved with
      palette = Option.map moved.palette ~f:(fun p -> H.palette_query p p.query)
    }
  in
  assert (String.equal (selected unchanged).id chosen.id);
  let _, effect = H.input unchanged Enter ~commands:catalog in
  (match chosen.unavailable, effect with
   | None, Execute (_, _) -> ()
   | Some reason, No_effect ->
     let next, _ = H.input unchanged Enter ~commands:catalog in
     assert (String.equal next.notice reason)
   | _ -> assert false);
  let edited, _ = H.input moved (Character 'e') ~commands:catalog in
  assert ((Option.value_exn edited.palette).index = 0);
  assert (String.equal (selected edited).id "asic.launch-view");
  let back, _ = H.input edited Backspace ~commands:catalog in
  assert ((Option.value_exn back.palette).index = 0);
  assert (String.equal (selected back).id "asic.launch-view")
;;

let%test_unit "selected shortcut captures checklist from another tile and rejects \
               ambiguous or changed selections"
  =
  let host, checklist, snapshot, selection = fixture () in
  let asic = Some snapshot in
  let other =
    List.find_exn (Option.value_exn host.registry).tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace checklist.workspace
      && not (String.equal tile.kind "stage-checklist"))
  in
  let unfocused = { host with focus = Some other.id } in
  let shortcut = List.hd_exn (C.selected_commands unfocused ~asic) in
  assert (Option.is_none shortcut.unavailable);
  (match shortcut.action with
   | Quick_launch_selected (item, run) ->
     assert (String.equal (Overview_tiles.checklist_id item) "routing");
     assert (Run_ref.equal run Fs0_fixture.run_a);
     assert (Result.is_ok (C.validate_selected unfocused ~asic ~item ~run));
     let changed =
       H.set_local
         unfocused
         checklist.id
         { (H.local host checklist.id) with cursor = Some "synthesis" }
     in
     assert (Result.is_error (C.validate_selected changed ~asic ~item ~run))
   | _ -> assert false);
  let registry = Option.value_exn host.registry in
  let second = { checklist with id = W.Tile_id.of_string "second-checklist" } in
  let ambiguous =
    H.receive unfocused { registry with tiles = registry.tiles @ [ second ] }
  in
  let disabled = List.hd_exn (C.selected_commands ambiguous ~asic) in
  assert (
    String.is_substring
      (Option.value_exn disabled.unavailable)
      ~substring:"Multiple checklist");
  let focused = { ambiguous with focus = Some checklist.id } in
  assert (Option.is_none (List.hd_exn (C.selected_commands focused ~asic)).unavailable);
  let absent =
    H.receive
      unfocused
      { registry with
        tiles =
          List.filter registry.tiles ~f:(fun t ->
            not (String.equal t.kind "stage-checklist"))
      }
  in
  assert (
    String.is_substring
      (Option.value_exn (List.hd_exn (C.selected_commands absent ~asic)).unavailable)
      ~substring:"No stage checklist");
  let catalog = full_catalog absent snapshot selection in
  let disabled_query = type_query (open_palette absent catalog) catalog "quick lau" in
  assert (String.equal (selected disabled_query).id "stage.quick-selected");
  let rejected, effect = H.input disabled_query Enter ~commands:catalog in
  assert (String.is_substring rejected.notice ~substring:"No stage checklist");
  (match effect with
   | No_effect -> ()
   | _ -> assert false);
  let no_run =
    H.receive
      host
      { registry with
        contexts = List.map registry.contexts ~f:(fun c -> { c with selected_run = None })
      }
  in
  assert (
    String.is_substring
      (Option.value_exn (List.hd_exn (C.selected_commands no_run ~asic)).unavailable)
      ~substring:"no current run")
;;

let%test_unit "named shortcuts capture fresh inputs, force view independently of \
               preference, and reject capability drift"
  =
  let host, _, snapshot, selection = fixture () in
  let named = C.named_commands host ~asic:(Some snapshot) ~remembered:(Some selection) in
  let find endpoint =
    List.find_exn named ~f:(fun c ->
      String.equal c.H.id ("stage.launch-view." ^ endpoint))
  in
  assert (Option.is_some (find "placement").unavailable);
  assert (Option.is_none (find "timing").unavailable);
  assert (Option.is_none (find "metal-fill").unavailable);
  assert (
    not
      (List.exists named ~f:(fun c ->
         String.is_substring c.H.id ~substring:"unselected-only")));
  assert (not host.quick_launch_view);
  (match (find "synthesis").action with
   | Launch_stage_and_view (intent, run, captured) ->
     assert (Asic.Selection.equal captured selection);
     assert (
       Result.is_ok
         (C.validate_named
            ~asic:(Some snapshot)
            ~remembered:(Some selection)
            ~run
            ~intent
            ~selection:captured));
     let stale = { snapshot with flows = [] } in
     assert (
       Result.is_error
         (C.validate_named
            ~asic:(Some stale)
            ~remembered:(Some selection)
            ~run
            ~intent
            ~selection:captured));
     assert (
       Result.is_error
         (C.validate_named
            ~asic:(Some snapshot)
            ~remembered:(Some { selection with assignments = [ "X=changed" ] })
            ~run
            ~intent
            ~selection:captured))
   | _ -> assert false);
  let execution = List.hd_exn snapshot.runs in
  let stage = { (List.hd_exn execution.stages) with action = Some selection } in
  let advertised =
    { snapshot with flows = []; runs = [ { execution with stages = [ stage ] } ] }
  in
  let command =
    List.find_exn
      (C.named_commands host ~asic:(Some advertised) ~remembered:(Some selection))
      ~f:(fun c -> String.equal c.H.id "stage.launch-view.synthesis")
  in
  assert (Option.is_none command.unavailable);
  match command.action with
  | Launch_stage_and_view (intent, run, captured) ->
    assert (
      Result.is_ok
        (C.validate_named
           ~asic:(Some advertised)
           ~remembered:(Some selection)
           ~run
           ~intent
           ~selection:captured));
    assert (
      Result.is_error
        (C.validate_named
           ~asic:(Some { advertised with runs = [] })
           ~remembered:(Some selection)
           ~run
           ~intent
           ~selection:captured))
  | _ -> assert false
;;

let%test_unit "named fresh launch can fill an empty context; elaboration captures inputs \
               and never claims ASIC allocation"
  =
  let host, _, snapshot, selection = fixture () in
  let registry = Option.value_exn host.registry in
  let empty_context =
    H.receive
      host
      { registry with
        contexts = List.map registry.contexts ~f:(fun c -> { c with selected_run = None })
      }
  in
  let synthesis =
    List.find_exn
      (C.named_commands empty_context ~asic:(Some snapshot) ~remembered:(Some selection))
      ~f:(fun c -> String.equal c.H.id "stage.launch-view.synthesis")
  in
  assert (Option.is_none synthesis.unavailable);
  (match synthesis.action with
   | Launch_stage_and_view (_, None, captured) ->
     assert (Asic.Selection.equal captured selection)
   | _ -> assert false);
  let prep =
    C.elaboration_command host ~asic:(Some snapshot) ~remembered:(Some selection)
  in
  assert (Option.is_none prep.unavailable);
  assert (String.is_substring prep.title ~substring:"context retained");
  (match prep.action with
   | Launch_elaboration_bundle captured ->
     assert (Asic.Selection.equal captured selection);
     assert (
       Result.is_ok
         (C.validate_elaboration
            ~asic:(Some snapshot)
            ~remembered:(Some selection)
            captured));
     assert (
       Result.is_error
         (C.validate_elaboration
            ~asic:(Some snapshot)
            ~remembered:(Some { selection with profile = "changed" })
            captured))
   | _ -> assert false);
  let unavailable =
    C.elaboration_command
      { host with preparation = None }
      ~asic:(Some snapshot)
      ~remembered:(Some selection)
  in
  assert (
    String.is_substring
      (Option.value_exn unavailable.unavailable)
      ~substring:"capability unavailable")
;;

let%test_unit "launch-and-view prefix follows the captured staged preparation rather \
               than a physical or settings action"
  =
  let host, _, snapshot, selection = fixture () in
  let staged : Preparation.Staged.t =
    { id = "captured-preparation"
    ; selection
    ; expected_plan_identity = None
    ; source_root = "/captured/source"
    ; build_target = "publisher.exe"
    ; source_executable = "/captured/source/_build/default/publisher.exe"
    ; results_root = "/captured/results"
    ; timeout_seconds = 30
    ; environment = Inherit_daemon
    ; created_at = Timestamp.of_time_ns Time_ns.epoch
    }
  in
  let host =
    { host with
      planned_preparation = true
    ; preparation = Some { (Option.value_exn host.preparation) with staged = Some staged }
    }
  in
  let catalog = full_catalog host snapshot selection in
  let typed = type_query (open_palette host catalog) catalog "launch and vi" in
  let chosen = selected typed in
  assert (String.equal chosen.id "asic.launch-view");
  assert (String.is_prefix chosen.title ~prefix:"Launch and view planned PREPARATION");
  (match chosen.action with
   | Launch_preparation id -> assert (String.equal id staged.id)
   | _ -> assert false);
  let registry = Option.value_exn host.registry in
  let stale =
    H.receive
      typed
      { registry with
        revision = registry.revision + 1
      ; contexts =
          List.map registry.contexts ~f:(fun c ->
            { c with selection_revision = c.selection_revision + 1 })
      }
  in
  let _, effect = H.input stale Enter ~commands:catalog in
  match effect with
  | No_effect -> ()
  | _ -> assert false
;;

let%test_unit "live selected launch guards reject tile-local drift and same-row \
               capability withdrawal after resolution"
  =
  let host, checklist, snapshot, selection = fixture () in
  let item, run =
    C.selected_checklist host ~asic:(Some snapshot) |> Result.ok_or_failwith
  in
  let stage =
    match item with
    | Overview_tiles.Physical_stage stage -> stage
    | _ -> assert false
  in
  let intent = Stage_action.Physical_stage stage in
  let resolved =
    C.resolve ~asic:(Some snapshot) ~remembered:(Some selection) ~run:(Some run) intent
    |> Result.ok_or_failwith
  in
  let captured = H.capture host |> Option.value_exn in
  let current_host = ref host
  and current_snapshot = ref snapshot in
  (* A long-running action reads live state at each boundary, rather than validating just
     when the palette action is converted to a preparation action. *)
  let validate () =
    Result.bind
      (C.validate_selected !current_host ~asic:(Some !current_snapshot) ~item ~run)
      ~f:(fun () ->
        C.validate_named
          ~asic:(Some !current_snapshot)
          ~remembered:(Some selection)
          ~run:(Some run)
          ~intent
          ~selection:resolved)
  in
  assert (Result.is_ok (validate ()));
  current_host
  := H.set_local
       host
       checklist.id
       { (H.local host checklist.id) with cursor = Some "synthesis" };
  assert (H.current !current_host captured);
  assert (Result.is_error (validate ()));
  current_host := host;
  current_snapshot
  := { snapshot with
       flows =
         List.map snapshot.flows ~f:(fun flow ->
           { flow with
             fresh_stage_endpoints =
               List.filter flow.fresh_stage_endpoints ~f:(Fn.non (String.equal "routing"))
           })
     };
  assert (H.current !current_host captured);
  assert (
    Result.is_ok
      (C.validate_selected !current_host ~asic:(Some !current_snapshot) ~item ~run));
  assert (Result.is_error (validate ()));
  let advertised = { stage with action = Some resolved } in
  let execution = List.hd_exn snapshot.runs in
  let action_snapshot =
    { snapshot with flows = []; runs = [ { execution with stages = [ advertised ] } ] }
  in
  let action_host =
    H.set_local
      host
      checklist.id
      { (H.local host checklist.id) with cursor = Some stage.id }
  in
  assert (
    Result.is_ok
      (C.validate_selected
         action_host
         ~asic:(Some action_snapshot)
         ~item:(Physical_stage advertised)
         ~run));
  assert (
    Result.is_ok
      (C.validate_named
         ~asic:(Some action_snapshot)
         ~remembered:(Some selection)
         ~run:(Some run)
         ~intent:(Physical_stage advertised)
         ~selection:resolved));
  let withdrawn =
    { action_snapshot with
      runs = [ { execution with stages = [ { advertised with action = None } ] } ]
    }
  in
  assert (H.current action_host captured);
  assert (
    Result.is_error
      (C.validate_selected
         action_host
         ~asic:(Some withdrawn)
         ~item:(Physical_stage advertised)
         ~run));
  assert (
    Result.is_error
      (C.validate_named
         ~asic:(Some withdrawn)
         ~remembered:(Some selection)
         ~run:(Some run)
         ~intent:(Physical_stage advertised)
         ~selection:resolved));
  let preparation = Overview_tiles.Elaboration_preparation in
  let prep_host =
    H.set_local
      host
      checklist.id
      { (H.local host checklist.id) with
        cursor = Some (Overview_tiles.checklist_id preparation)
      }
  in
  assert (
    Result.is_ok
      (C.validate_selected prep_host ~asic:(Some snapshot) ~item:preparation ~run));
  assert (H.current host captured);
  assert (
    Result.is_error
      (C.validate_selected host ~asic:(Some snapshot) ~item:preparation ~run))
;;
