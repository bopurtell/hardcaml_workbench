open! Core
open Hardcaml_workbench_protocol
open Bonsai_term
module O = Overview_tiles
module H = Workspace_host

let%test_unit "generic Timing chooses observed stage when no analysis is published" =
  let asic = Fs0_fixture.snapshot in
  let run = Fs0_fixture.run_a in
  let legacy, analysis = O.timing_inspection_target ~asic:(Some asic) ~run in
  assert (String.equal legacy "signoff" && Option.is_none analysis);
  let runs =
    List.map asic.runs ~f:(fun r ->
      if Run_ref.equal r.run run
      then
        { r with
          stages =
            [ { Asic.Stage.id = "timing"
              ; name = "Timing"
              ; status = Not_requested
              ; requested = false
              ; reason = None
              ; action = None
              ; execution_timing = None
              }
            ]
        }
      else r)
  in
  let stage, analysis = O.timing_inspection_target ~asic:(Some { asic with runs }) ~run in
  assert (String.equal stage "timing" && Option.is_none analysis)
;;

let%test_unit "asynchronous unsupported Timing feedback survives registry polls before \
               draw"
  =
  let host, data, find =
    Host_view.refinement_fixture Hardcaml_workbench_workspaces.Overview.definition
  in
  let reason =
    "Stage preparation failed: Unsupported fresh endpoint: legacy/timing; press r to \
     retry"
  in
  let host =
    { host with
      stage_preparation = Some reason
    ; notice = reason
    ; focus = Some (find "stage-checklist").id
    }
  in
  let registry = Option.value_exn host.registry in
  let polled =
    List.fold (List.init 30 ~f:Fn.id) ~init:host ~f:(fun host _ ->
      H.receive host registry)
  in
  assert (String.equal polled.notice reason);
  let screen =
    Host_view.render polled data { Bonsai_term.Dimensions.width = 120; height = 40 }
    |> Host_view.plain_text
  in
  assert (String.is_substring screen ~substring:"Unsupported fresh endpoint");
  let dismissed = H.receive { polled with notice = "" } registry in
  assert (String.is_empty dismissed.notice);
  let replanned =
    H.receive { polled with stage_preparation = None; notice = "new plan" } registry
  in
  assert (String.is_empty replanned.notice)
;;

let target : Asic_inspection.Analysis_target.t =
  { attempt_id = "attempt-A"
  ; occurrence_id = "attempt-A/implementation.signoff"
  ; analysis_id = "attempt-A/post-pnr-sta"
  ; source_digest = String.make 64 'a'
  ; execution_sha256 = String.make 64 'e'
  ; stage = "signoff"
  ; execution_file = None
  }
;;

let analysis : Asic.Timing_analysis.t =
  { target
  ; status = Completed
  ; reason = None
  ; duration =
      Some
        { seconds = 1.575
        ; basis = "native wall clock"
        ; precision_seconds = 0.001
        ; source = "runtime.txt"
        }
  ; enclosing_status = "failed: later DRC timeout"
  ; producer = Some "OpenROAD.STAPostPNR"
  ; corners =
      [ { corner = "slow"; measured = true; setup_goal = Fail; hold_goal = Pass } ]
  ; metrics =
      [ { key = "setup_slack"
        ; corner = "slow"
        ; raw_key = "timing__setup__ws"
        ; value = Some (-0.125)
        ; unit_ = Some "ns"
        ; reason = None
        ; provenance = "slow/sta.log:1"
        }
      ]
  ; timing_goal = Fail
  ; evidence = "retained STA; no checkpoint"
  }
;;

let fixture () =
  let host, data, find =
    Host_view.refinement_fixture Hardcaml_workbench_workspaces.Overview.definition
  in
  let summary = Option.value_exn (data.Host_view.summary Fs0_fixture.run_a) in
  let summary = { summary with timing_analysis = Some analysis; freshness = Validated } in
  let asic = Option.value_exn data.asic in
  let runs =
    List.map asic.runs ~f:(fun r ->
      if not (Run_ref.equal r.run Fs0_fixture.run_a)
      then r
      else
        { r with
          stages =
            List.map r.stages ~f:(fun s ->
              if String.equal s.id "signoff" then { s with status = Failed } else s)
        })
  in
  let asic = { asic with runs; summaries = [ summary ] } in
  let data =
    { data with
      asic = Some asic
    ; summary = (fun run -> if Run_ref.equal run summary.run then Some summary else None)
    }
  in
  host, data, find, summary
;;

let%test_unit "Overview Timing precision is display-only in compact and expanded views" =
  let host, data, find, summary = fixture () in
  let base = List.hd_exn analysis.metrics in
  let analysis =
    { analysis with
      metrics =
        [ { base with value = Some 16.23669876 }
        ; { base with key = "hold_slack"; value = Some (-0.0009876549) }
        ; { base with key = "setup_violations"; value = Some 2.; unit_ = Some "count" }
        ; { base with key = "hold_violations"; value = Some 0.; unit_ = Some "count" }
        ]
    ; evidence = "technical report: 16.23669876 / -0.0009876549"
    }
  in
  let summary = { summary with timing_analysis = Some analysis } in
  let raw = Asic.Summary.sexp_of_t summary in
  let render ?decimal_places compact =
    Overview_summary.rows
      ?decimal_places
      ~compact
      ~kind:"timing"
      ~run:summary.run
      ~summary:(Some summary)
      ~stages:[]
      ()
    |> List.map ~f:(fun row -> row.O.label ^ ": " ^ row.value)
    |> String.concat ~sep:"\n"
  in
  List.iter [ false; true ] ~f:(fun compact ->
    let three = render compact
    and six = render ~decimal_places:6 compact in
    List.iter [ "16.236 ns"; "-0.000 ns"; "2 count"; "0 count" ] ~f:(fun substring ->
      assert (String.is_substring three ~substring));
    List.iter
      [ "16.236698 ns"; "-0.000987 ns"; "2 count"; "0 count" ]
      ~f:(fun substring -> assert (String.is_substring six ~substring));
    assert (not (String.is_substring three ~substring:"2.000"));
    assert (not (String.is_substring six ~substring:"2.000000")));
  let data =
    { data with
      summary = (fun _ -> Some summary)
    ; asic =
        Option.map data.asic ~f:(fun snapshot ->
          { snapshot with
            runs =
              List.map snapshot.runs ~f:(fun run ->
                { run with
                  stages =
                    [ { (List.hd_exn run.stages) with id = "timing"; name = "Timing" } ]
                })
          })
    }
  in
  let tile = find "timing" in
  List.iter [ false; true ] ~f:(fun detail ->
    List.iter
      [ 0, "16 ns", "-0 ns"
      ; 3, "16.236 ns", "-0.000 ns"
      ; 6, "16.236698 ns", "-0.000987 ns"
      ; 9, "16.236698760 ns", "-0.000987654 ns"
      ]
      ~f:(fun (decimal_places, positive, negative) ->
        let local = H.local host tile.id in
        let host =
          H.set_local
            host
            tile.id
            { local with
              utility_detail = detail
            ; presentation =
                { local.presentation with decimal_places = Some decimal_places }
            }
        in
        let text =
          Host_view.tile_view host data tile ~width:160 ~height:40 |> Host_view.plain_text
        in
        assert (String.is_substring text ~substring:positive);
        if not (String.is_substring text ~substring:negative)
        then
          failwithf
            "Missing %s at precision %d detail=%b:\n%s"
            negative
            decimal_places
            detail
            text
            ();
        if detail
        then (
          assert (String.is_substring text ~substring:"2 count");
          assert (String.is_substring text ~substring:analysis.evidence))));
  assert (Sexp.equal raw (Asic.Summary.sexp_of_t summary));
  assert (Asic.Timing_analysis.Goal.equal analysis.timing_goal Fail)
;;

let%test_unit "hidden builtin follows exact resolved analysis without navigation or pin \
               edits"
  =
  let module W = Workspace in
  let initial = W.initial ~session_id:(W.Session_id.of_string "hidden-builtin") in
  let registry =
    W.apply
      initial
      (Hardcaml_workbench_workspaces.Presets.startup_operation initial |> Option.value_exn)
    |> Result.ok
    |> Option.value_exn
  in
  let mutate registry mutation =
    W.apply
      registry
      (Mutate { expected_revision = registry.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let main = List.hd_exn registry.workspaces in
  let choose registry run =
    let c = W.context registry main.context in
    mutate
      registry
      (Select_run
         { workspace = main.id
         ; context = c.id
         ; expected_selection_revision = c.selection_revision
         ; run = Some run
         })
  in
  let registry = choose registry Fs0_fixture.run_a in
  let host = H.receive H.empty registry in
  let workspace =
    H.builtin_timing_in_window registry ~window:main.window |> Option.value_exn
  in
  let tile =
    List.find_exn registry.tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace workspace.id
      && String.equal tile.kind "timing-paths")
  in
  let target =
    { target with stage = "timing"; execution_file = Some "/exact/frozen-source" }
  in
  let snapshot =
    { Fs0_fixture.snapshot with
      summaries =
        [ { (Fs0_fixture.summary Fs0_fixture.run_a 1 []) with
            timing_analysis = Some { analysis with target }
          }
        ]
    }
  in
  let prepared = H.reconcile_builtin_timing host (Some snapshot) in
  assert (Option.equal W.Snapshot.equal prepared.registry host.registry);
  assert (Option.equal W.Workspace_id.equal prepared.active host.active);
  assert (Option.equal W.Tile_id.equal prepared.focus host.focus);
  let view = H.timing prepared tile |> Option.value_exn in
  assert (String.equal view.stage "timing");
  assert (Option.equal Asic_inspection.Analysis_target.equal view.analysis (Some target));
  let legacy =
    H.set_timing
      prepared
      tile
      (Timing_workspace.create ~generation:10 ~run:Fs0_fixture.run_a ~stage:"signoff")
  in
  let recovered = H.reconcile_builtin_timing legacy (Some snapshot) in
  assert (String.equal (Option.value_exn (H.timing recovered tile)).stage "timing");
  let prepared =
    H.set_timing prepared tile { view with filter = "keep"; selected = Some "old-row" }
  in
  let again = H.reconcile_builtin_timing prepared (Some snapshot) in
  assert (String.equal (Option.value_exn (H.timing again tile)).filter "keep");
  let target2 = { target with source_digest = String.make 64 'c' } in
  let snapshot2 =
    { snapshot with
      summaries =
        List.map snapshot.summaries ~f:(fun s ->
          { s with timing_analysis = Some { analysis with target = target2 } })
    }
  in
  let changed = H.reconcile_builtin_timing again (Some snapshot2) in
  let view2 = H.timing changed tile |> Option.value_exn in
  assert (Option.is_none view2.selected && String.is_empty view2.filter);
  assert (view2.generation > view.generation);
  let switched_registry = choose registry Fs0_fixture.run_b in
  let switched =
    H.reconcile_builtin_timing (H.receive changed switched_registry) (Some snapshot)
  in
  let switched_view = H.timing switched tile |> Option.value_exn in
  assert (Run_ref.equal switched_view.run Fs0_fixture.run_b);
  assert (
    String.equal switched_view.stage "signoff" && Option.is_none switched_view.analysis);
  let pinned_registry =
    mutate
      switched_registry
      (Set_tile_binding { tile = tile.id; binding = Pin_run Fs0_fixture.run_a })
  in
  let pinned =
    H.reconcile_builtin_timing (H.receive switched pinned_registry) (Some snapshot)
  in
  assert (Option.equal W.Snapshot.equal pinned.registry (Some pinned_registry));
  assert (
    Option.is_none
      (H.matching_timing ~workspace:workspace.id pinned_registry ~run:Fs0_fixture.run_b));
  assert (
    Option.is_none
      (H.matching_timing ~workspace:workspace.id pinned_registry ~run:Fs0_fixture.run_a))
;;

let%test_unit "generic Timing captures complete authoritative identity including legacy" =
  let _, data, _, summary = fixture () in
  let stage, captured = O.timing_inspection_target ~asic:data.asic ~run:summary.run in
  assert (String.equal stage "signoff");
  assert (Option.equal Asic_inspection.Analysis_target.equal captured (Some target));
  let target =
    { target with stage = "timing"; execution_file = Some "/frozen/timing-source" }
  in
  let asic = Option.value_exn data.asic in
  let summaries = [ { summary with timing_analysis = Some { analysis with target } } ] in
  let stage, captured =
    O.timing_inspection_target ~asic:(Some { asic with summaries }) ~run:summary.run
  in
  assert (String.equal stage "timing");
  assert (Option.equal Asic_inspection.Analysis_target.equal captured (Some target));
  let _, other =
    O.timing_inspection_target ~asic:(Some { asic with summaries }) ~run:Fs0_fixture.run_b
  in
  assert (Option.is_none other)
;;

let executable_fixture status =
  let host, data, find, summary = fixture () in
  let target =
    { target with
      stage = "timing"
    ; occurrence_id = "attempt-A/implementation.timing"
    ; execution_file = Some "/frozen/execution.json.timing-source"
    }
  in
  let summary =
    { summary with
      completion = "failed"
    ; timing_analysis = Some { analysis with target; enclosing_status = "running" }
    }
  in
  let timing : Asic.Stage.t =
    { id = "timing"
    ; name = "Timing"
    ; status
    ; requested = true
    ; reason = None
    ; action =
        Some
          { flow = "fixture"; profile = "default"; endpoint = "timing"; assignments = [] }
    ; execution_timing =
        Execution_timing.make ~measured_seconds:2.798826 ~running:false ()
    }
  in
  let asic = Option.value_exn data.asic in
  let runs =
    List.map asic.runs ~f:(fun r ->
      if Run_ref.equal r.run summary.run
      then
        { r with
          stages =
            List.concat_map r.stages ~f:(fun s ->
              if String.equal s.id "routing" then [ s; timing ] else [ s ])
        }
      else r)
  in
  ( host
  , { data with
      asic = Some { asic with runs; summaries = [ summary ] }
    ; summary = (fun _ -> Some summary)
    }
  , find
  , summary )
;;

let%test_unit "executable Timing merges physical row, seven-stage cursor and independent \
               STA evidence"
  =
  List.iter [ Asic.Stage.Status.Pending; Running; Completed; Failed ] ~f:(fun status ->
    let host, data, find, summary = executable_fixture status in
    let items = O.checklist_items ~asic:data.asic ~run:summary.run in
    assert (List.length items = 8);
    assert (List.count items ~f:(fun i -> String.equal (O.checklist_id i) "timing") = 1);
    assert (
      not
        (List.exists items ~f:(function
          | O.Timing_analysis _ -> true
          | _ -> false)));
    let tile = find "stage-checklist" in
    let host = H.browse_checklist host tile.id ~run:summary.run ~items ~delta:6 in
    (match H.checklist_cursor (H.local host tile.id) ~run:summary.run ~items with
     | Some (Physical_stage s) ->
       assert (String.equal s.id "timing");
       assert (String.equal (Option.value_exn s.action).endpoint "timing")
     | _ -> assert false);
    let rows = Host_view.utility_rows host data tile |> Option.value_exn in
    let row = List.find_exn rows ~f:(fun r -> String.equal r.O.label "Timing") in
    assert (String.equal row.value (O.Status.label (O.asic_stage_status status)));
    assert (not (Option.equal String.equal row.time (Some "1.575s")));
    let details = String.concat ~sep:"\n" row.details in
    assert (String.is_substring details ~substring:"Current execution outcome: failed");
    assert (String.is_substring details ~substring:"Captured source status: running");
    List.iter [ 24; 40; 80 ] ~f:(fun width ->
      let rendered =
        O.render ~appearance:host.appearance ~attrs:(fun _ -> []) ~width ~height:8 rows
      in
      assert (View.width rendered = width && View.height rendered = 8);
      let lines = Host_view.plain_text rendered |> String.split_lines in
      let columns =
        List.map2_exn rows lines ~f:(fun row line ->
          String.substr_index_exn line ~pattern:row.O.value
          |> fun offset -> O.cell_width (String.prefix line offset))
      in
      assert (List.for_all columns ~f:(Int.equal (List.hd_exn columns))));
    let compact =
      Overview_summary.rows
        ~compact:true
        ~kind:"timing"
        ~run:summary.run
        ~summary:(Some summary)
        ~stages:(O.observed_stages ~asic:data.asic ~run:summary.run)
        ()
    in
    assert (String.is_substring (List.hd_exn compact).value ~substring:"stage");
    assert (String.equal (List.nth_exn compact 1).label "STA runtime");
    assert (String.equal (List.nth_exn compact 1).value "1.575s"))
;;

let%test_unit "physical Timing actions require an advertised fresh catalog endpoint" =
  let _, data, _, summary = executable_fixture Completed in
  let snapshot = Option.value_exn data.asic in
  let selection : Asic.Selection.t =
    { flow = "new-provider"
    ; profile = "balanced"
    ; endpoint = "signoff"
    ; assignments = [ "CLOCK=9" ]
    }
  in
  let runs =
    List.map snapshot.runs ~f:(fun r ->
      { r with
        selection = Some selection
      ; stages = List.map r.stages ~f:(fun s -> { s with action = None })
      })
  in
  let flow : Asic.Flow.t =
    { id = selection.flow
    ; profiles = [ selection.profile ]
    ; default_profile = selection.profile
    ; fresh_stage_endpoints = []
    }
  in
  let timing flow =
    O.checklist_items
      ~asic:(Some { snapshot with runs; flows = [ flow ] })
      ~run:summary.run
    |> List.find_map_exn ~f:(function
      | O.Physical_stage s when String.equal s.id "timing" -> Some s
      | _ -> None)
  in
  assert (Option.is_none (timing flow).action);
  let s = timing { flow with fresh_stage_endpoints = [ "timing" ] } in
  assert (
    Asic.Selection.equal
      (Option.value_exn s.action)
      { selection with endpoint = "timing" })
;;

let%test_unit "live physical Timing remains visible before any STA observation" =
  let host, data, find, summary = executable_fixture Running in
  let now = Time_ns.of_int_ns_since_epoch 10_000_000_000 in
  let asic = Option.value_exn data.asic in
  let summary = { summary with timing_analysis = None } in
  let runs =
    List.map asic.runs ~f:(fun r ->
      { r with
        stages =
          List.map r.stages ~f:(fun s ->
            if String.equal s.id "timing"
            then
              { s with
                execution_timing =
                  Execution_timing.make
                    ~started_at:(Timestamp.of_time_ns Time_ns.epoch)
                    ~running:true
                    ()
              }
            else s)
      })
  in
  let data =
    { data with
      asic = Some { asic with runs; summaries = [ summary ] }
    ; summary = (fun _ -> Some summary)
    }
  in
  let rows =
    Host_view.utility_rows ~now host data (find "stage-checklist") |> Option.value_exn
  in
  let timing = List.find_exn rows ~f:(fun r -> String.equal r.O.label "Timing") in
  assert (String.equal timing.value "running");
  assert (Option.equal String.equal timing.time (Some "10s"));
  let rows =
    Overview_summary.rows
      ~now
      ~compact:true
      ~kind:"timing"
      ~run:summary.run
      ~summary:(Some summary)
      ~stages:(O.observed_stages ~asic:data.asic ~run:summary.run)
      ()
  in
  assert (String.is_substring (List.hd_exn rows).value ~substring:"running 10s");
  assert (String.equal (List.nth_exn rows 1).value "unknown")
;;

let%test_unit "WB069 both Overview surfaces share completion/duration and independent \
               failing goal"
  =
  let host, data, find, summary = fixture () in
  let rows =
    Host_view.utility_rows host data (find "stage-checklist") |> Option.value_exn
  in
  let names = List.map rows ~f:(fun r -> r.O.label) in
  assert (
    List.equal
      String.equal
      names
      [ "Elaboration"
      ; "synthesis"
      ; "floorplan"
      ; "placement"
      ; "cts"
      ; "routing"
      ; "Timing"
      ; "signoff"
      ]);
  let timing = List.find_exn rows ~f:(fun r -> String.equal r.label "Timing") in
  assert (String.equal timing.value "completed");
  assert (Option.equal String.equal timing.time (Some "1.575s"));
  assert (String.equal (List.last_exn rows).value "failed");
  let tile = find "timing" in
  List.iter [ 24; 30; 50; 80 ] ~f:(fun width ->
    let text =
      Host_view.tile_view host data tile ~width ~height:5 |> Host_view.plain_text
    in
    assert (String.is_substring text ~substring:"completed");
    if not (String.is_substring text ~substring:"1.575s")
    then raise_s [%message "duration clipped" (width : int) (text : string)]);
  let text =
    Host_view.tile_view host data tile ~width:80 ~height:8 |> Host_view.plain_text
  in
  List.iter [ "fail"; "slow"; "-0.125 ns" ] ~f:(fun substring ->
    assert (String.is_substring text ~substring));
  let details =
    O.analysis_details ~run:summary.run (Some summary) |> String.concat ~sep:"\n"
  in
  List.iter
    [ "later DRC timeout"
    ; target.source_digest
    ; "runtime.txt"
    ; "precision: 0.001"
    ; "setup=fail"
    ; "slow/sta.log:1"
    ]
    ~f:(fun substring -> assert (String.is_substring details ~substring));
  let unknown =
    Overview_summary.rows
      ~compact:true
      ~kind:"timing"
      ~run:summary.run
      ~summary:(Some { summary with timing_analysis = None })
      ~stages:[]
      ()
  in
  assert (String.is_substring (List.hd_exn unknown).value ~substring:"unknown");
  assert (
    not
      (List.exists unknown ~f:(fun r -> String.is_substring r.value ~substring:"-0.125")));
  let zero =
    O.analysis_row
      ~run:summary.run
      ~selected:false
      (Some
         { summary with
           timing_analysis =
             Some
               { analysis with
                 duration =
                   Some { (Option.value_exn analysis.duration) with seconds = 0. }
               }
         })
  in
  assert (Option.equal String.equal zero.time (Some "0s"))
;;

let%test_unit "WB069 projected cursor reaches Timing without physical action inference" =
  let host, data, find, summary = fixture () in
  let tile = find "stage-checklist" in
  let items = O.checklist_items ~asic:data.asic ~run:summary.run in
  let host = H.browse_checklist host tile.id ~run:summary.run ~items ~delta:6 in
  (match H.checklist_cursor (H.local host tile.id) ~run:summary.run ~items with
   | Some (Timing_analysis _) -> ()
   | _ -> assert false);
  assert (Option.is_none (Host_view.checklist_preview host data tile));
  List.iter [ Appearance.Icons.Unicode; Ascii; None_ ] ~f:(fun icons ->
    let appearance = { host.appearance with icons } in
    let host = { host with appearance } in
    let rows = Host_view.utility_rows host data tile |> Option.value_exn in
    List.iter [ 24; 30; 40; 60 ] ~f:(fun width ->
      let view = O.render ~appearance ~attrs:(fun _ -> []) ~width ~height:8 rows in
      assert (View.width view <= width);
      let text = Host_view.plain_text view in
      assert (String.is_substring text ~substring:"completed");
      assert (String.is_substring text ~substring:"failed");
      let columns =
        List.map2_exn rows (String.split_lines text) ~f:(fun row line ->
          let offset = String.substr_index_exn line ~pattern:row.O.value in
          O.cell_width (String.prefix line offset))
      in
      assert (List.for_all columns ~f:(Int.equal (List.hd_exn columns))));
    let strip =
      O.render_checklist_strip ~appearance ~attrs:(fun _ -> []) ~width:40 ~height:1 rows
      |> Host_view.plain_text
    in
    assert (String.is_substring strip ~substring:"Timing");
    assert (String.is_substring strip ~substring:"1.575s"));
  let local =
    H.reconcile_checklist
      (H.local host tile.id)
      ~run:(Some Fs0_fixture.run_b)
      ~items:(O.checklist_items ~asic:data.asic ~run:Fs0_fixture.run_b)
  in
  assert (not (Option.equal String.equal local.cursor (Some "analysis:post-pnr-sta")))
;;

let%test_unit "historical Timing remains supplementary while upgraded catalog permits \
               fresh preparation"
  =
  let host, data, find, summary = fixture () in
  let snapshot = Option.value_exn data.asic in
  let selected : Asic.Selection.t =
    { flow = "upgraded"
    ; profile = "balanced"
    ; endpoint = "signoff"
    ; assignments = [ "CLOCK=9" ]
    }
  in
  let snapshot =
    { snapshot with
      runs = List.map snapshot.runs ~f:(fun r -> { r with selection = Some selected })
    ; flows =
        [ { id = "upgraded"
          ; profiles = [ "balanced" ]
          ; default_profile = "balanced"
          ; fresh_stage_endpoints = [ "timing" ]
          }
        ]
    }
  in
  let data = { data with asic = Some snapshot } in
  let items = O.checklist_items ~asic:data.asic ~run:summary.run in
  assert (
    List.count items ~f:(function
      | O.Timing_analysis _ -> true
      | _ -> false)
    = 1);
  assert (
    not
      (List.exists items ~f:(function
        | O.Physical_stage s -> String.equal s.id "timing"
        | _ -> false)));
  let action =
    Host_view.checklist_intent_selection
      host
      data
      summary.run
      (Stage_action.Fresh_endpoint "timing")
    |> Result.ok_or_failwith
  in
  assert (Asic.Selection.equal action { selected with endpoint = "timing" });
  let local = H.default_local in
  assert (Option.is_none local.cursor);
  (match
     H.checklist_cursor local ~run:summary.run ~items:[ O.Timing_analysis (Some summary) ]
   with
   | Some (Timing_analysis _) -> ()
   | _ -> assert false);
  let tile = find "stage-checklist" in
  let host = H.browse_checklist host tile.id ~run:summary.run ~items ~delta:6 in
  assert (
    Option.equal String.equal (H.local host tile.id).cursor (Some "analysis:post-pnr-sta"));
  assert (Asic.Summary.equal (Option.value_exn (data.summary summary.run)) summary)
;;

let%test_unit "WB069 exact target gates index, refresh, detail, demand and stale receipt" =
  let _, data, _, _ = fixture () in
  let snapshot = Option.value_exn data.asic in
  let view =
    Timing_workspace.create ~generation:1 ~run:Fs0_fixture.run_a ~stage:"signoff"
    |> fun view -> Timing_workspace.with_analysis view (Some target)
  in
  let index : Asic_inspection.Index.t =
    { run = view.run
    ; execution_file = "/exact/execution.json"
    ; execution_sha256 = target.execution_sha256
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = String.make 64 'b'
    ; analysis = Some target
    ; cached_unverified = false
    ; times = Evidence_time.Index.empty
    ; rows =
        [ { id = "path-A"
          ; category = "timing_path"
          ; producer = "STA"
          ; corner = Some "slow"
          ; group = None
          ; name = "path-A"
          ; value = Some (-0.125)
          ; unit_ = Some "ns"
          ; status = "violated"
          ; source = "{}"
          ; fields = []
          }
        ]
    ; diagnostics = []
    ; truncated = false
    }
  in
  let different = { target with analysis_id = "another-analysis" } in
  let wrong = { index with analysis = Some different } in
  let view =
    Inspection_view.reconcile view { snapshot with inspections = [ wrong; index ] }
  in
  assert (Option.is_some view.index);
  let operation = Inspection_view.operation ~refresh:true view in
  (match operation with
   | Inspect_analysis { target = captured; refresh = true; _ } ->
     assert (Asic_inspection.Analysis_target.equal captured target)
   | _ -> assert false);
  let refreshed, _ = Inspection_view.input ~width:80 ~height:20 view Refresh in
  let refreshed = Option.value_exn refreshed in
  assert (
    Option.equal
      String.equal
      refreshed.operation_key
      (Some (Asic_inspection.analysis_index_key ~run:view.run ~target)));
  let opened, operation = Inspection_view.input ~width:80 ~height:20 view Open in
  let opened = Option.value_exn opened in
  (match operation with
   | Some (Inspect_analysis_detail { target = captured; source_digest; row_id; _ }) ->
     assert (Asic_inspection.Analysis_target.equal captured target);
     assert (String.equal source_digest index.source_digest);
     assert (String.equal row_id "path-A")
   | _ -> assert false);
  let demand = Timing_demand.create ~neighbors:0 view in
  let _, _, request =
    Timing_demand.step demand ~view { snapshot with inspections = [ index ] }
  in
  (match (Option.value_exn request).operation with
   | Inspect_analysis_detail _ -> ()
   | _ -> assert false);
  let stale = Inspection_view.capture opened (Option.value_exn operation) in
  let replaced =
    Inspection_view.reconcile opened { snapshot with inspections = [ wrong ] }
  in
  assert (Option.is_none replaced.index && Option.is_none replaced.requested);
  let response = Inspection_view.apply_response replaced stale (Error "obsolete") in
  assert (Option.is_none response.error);
  let generic = Timing_workspace.create ~generation:1 ~run:view.run ~stage:"signoff" in
  assert (
    Option.is_some
      (Inspection_view.reconcile generic { snapshot with inspections = [ index ] }).index);
  (match Inspection_view.operation generic with
   | Inspect _ -> ()
   | _ -> assert false);
  let generic =
    Inspection_view.reconcile generic { snapshot with inspections = [ index ] }
  in
  let opened, _ = Inspection_view.input ~width:80 ~height:20 generic Open in
  let opened = Option.value_exn opened in
  let changed =
    Inspection_view.reconcile opened { snapshot with inspections = [ wrong ] }
  in
  assert (changed.generation > opened.generation && Option.is_none changed.requested)
;;

let%test_unit "WB069 persisted navigation and reuse retain exact analysis rather than \
               only run"
  =
  let host, data, find =
    Host_view.refinement_fixture Hardcaml_workbench_workspaces.Timing.definition
  in
  let target =
    { target with stage = "timing"; execution_file = Some "/exact/frozen-source" }
  in
  let paths = find "timing-paths" in
  let view =
    Timing_workspace.create ~generation:1 ~run:Fs0_fixture.run_a ~stage:"signoff"
    |> fun view -> Timing_workspace.with_analysis view (Some target)
  in
  let host = H.set_timing host paths { view with filter = "fixture filter" } in
  let registry = Option.value_exn host.registry in
  assert (
    Option.is_some
      (H.matching_timing_analysis host registry ~run:view.run ~analysis:(Some target)));
  assert (
    Option.is_none (H.matching_timing_analysis host registry ~run:view.run ~analysis:None));
  assert (
    Option.is_none
      (H.matching_timing_analysis
         host
         registry
         ~run:view.run
         ~analysis:(Some { target with source_digest = String.make 64 'c' })));
  assert (
    Option.is_none
      (H.matching_timing_analysis
         host
         registry
         ~run:view.run
         ~analysis:(Some { target with stage = "signoff" })));
  let saved = H.navigation_preferences ~project_key:"wb069" host |> Option.value_exn in
  let reopened =
    Navigation_preferences.encode saved
    |> Navigation_preferences.decode ~project_key:"wb069"
  in
  let restored =
    H.restore_navigation_selections reopened { host with timing = [] } ~scope:"wb069"
  in
  let view = H.timing restored paths |> Option.value_exn in
  assert (Option.equal Asic_inspection.Analysis_target.equal view.analysis (Some target));
  assert (String.equal view.stage "timing");
  assert (String.equal view.filter "fixture filter");
  assert (
    Option.is_none
      (Timing_workspace.attach_retained view (Option.value_exn data.asic)).index)
;;
