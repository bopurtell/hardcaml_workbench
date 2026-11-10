open! Core
open Hardcaml_workbench_protocol
open Bonsai_term
module O = Overview_tiles

let supports = function
  | "synthesis" | "timing" | "placement" | "routing" | "checks" | "finalization" -> true
  | _ -> false
;;

let legacy_rows
  ?(now = Time_ns.now ())
  ?(finalizations = [])
  ?(compact = false)
  ?(freshness = true)
  ?(decimal_places = 3)
  ?stage_id
  ~kind
  ~run
  ~summary
  ~stages
  ()
  =
  let show_freshness = freshness in
  let stage_id = Option.value stage_id ~default:kind in
  let summary =
    Option.filter summary ~f:(fun (s : Asic.Summary.t) -> Run_ref.equal s.run run)
  in
  let details =
    [ "Run: " ^ O.run_identity run; "Stage ID: " ^ stage_id ]
    @ Option.value_map summary ~default:[] ~f:(fun s ->
      [ "Source digest: " ^ s.source_digest
      ; "Producer: " ^ s.producer
      ; "Execution file: " ^ s.execution_file
      ]
      @ Evidence_time_view.summary_lines s.observed_at
      @ Option.value_map s.terminal ~default:[] ~f:(fun t ->
        [ "Finalization attempt: " ^ t.attempt
        ; "Results digest: " ^ t.results_digest
        ; "Results file: " ^ t.results_file
        ]))
  in
  let plain ?(role = O.Role.Muted) ?indicator ?(extra = []) label value =
    O.row ~role ?indicator ~details:(details @ extra) label value
  in
  let stage =
    match
      List.filter stages ~f:(fun (s : Asic.Stage.t) -> String.equal s.id stage_id)
    with
    | [ stage ] -> { (O.asic_stage_row ~now ~run ~selected:false stage) with time = None }
    | stages ->
      plain
        "Stage"
        (if List.is_empty stages then "not reported" else "ambiguous duplicate stage IDs")
  in
  let timing, scope =
    if String.equal kind "finalization"
    then (
      match
        List.filter finalizations ~f:(fun (f : Asic.Finalization.t) ->
          Run_ref.equal f.run run)
      with
      | [ f ] -> f.execution_timing, "Finalization receipt"
      | [] ->
        ( Option.bind summary ~f:(fun s ->
            Option.bind s.terminal ~f:(fun t -> t.execution_timing))
        , "Finalization terminal result" )
      | _ -> None, "Finalization receipts ambiguous")
    else (
      match
        List.filter stages ~f:(fun (s : Asic.Stage.t) -> String.equal s.id stage_id)
      with
      | [ s ] -> s.execution_timing, "Stage: " ^ stage_id
      | _ -> None, "Stage: " ^ stage_id ^ " (no exact unique timing)")
  in
  let time_value = Execution_time_view.value ~now timing in
  let time_value =
    if String.equal time_value "unknown"
       && List.mem [ "timing"; "checks" ] kind ~equal:String.equal
    then "unknown (stage " ^ stage_id ^ ")"
    else time_value
  in
  let time = plain ~extra:[ "Execution time scope: " ^ scope ] "Time" time_value in
  let freshness =
    match summary with
    | None -> plain ~indicator:Unavailable "Evidence" "not loaded for this run"
    | Some s ->
      let value, role = O.freshness_label s.freshness in
      plain
        ~role
        ~indicator:(O.freshness_indicator s.freshness)
        ~extra:
          (match s.freshness with
           | Refresh_failed reason -> [ "Refresh error: " ^ reason ]
           | _ -> [])
        "Evidence"
        value
  in
  let metric (m : Asic.Metric.t) =
    plain
      ~extra:
        ([ "Metric key: " ^ m.key ]
         @ Option.to_list (Option.map m.source ~f:(fun s -> "Metric source: " ^ s)))
      ("Aggregate " ^ if String.is_empty m.label then m.key else m.label)
      (let value =
         match m.value with
         | Some value when not (Float.is_finite value) -> "invalid (non-finite)"
         | Some value when String.equal m.availability "available" ->
           (if String.equal kind "timing"
            then O.timing_metric_value ~decimal_places ~key:m.key ~unit_:m.unit_ value
            else sprintf "%g" value)
           ^ Option.value_map m.unit_ ~default:" (unit not reported)" ~f:(fun u ->
             " " ^ u)
         | _ -> "unavailable"
       in
       value
       ^ " ["
       ^ (if String.is_empty m.availability
          then "availability not reported"
          else m.availability)
       ^ "]")
  in
  let fact field label value =
    plain
      ~role:(O.Fact.role field value)
      label
      (if String.is_empty value then "not reported" else value)
  in
  let evidence =
    match summary with
    | None -> []
    | Some s ->
      let terminal = s.terminal in
      let terminal_metrics keys =
        Option.value_map terminal ~default:[] ~f:(fun t ->
          List.filter_map t.metrics ~f:(fun m ->
            if List.mem keys m.Asic.Metric.key ~equal:String.equal
            then Some (metric m)
            else None))
      in
      (match kind with
       | "synthesis" ->
         [ plain
             "Reported cells (agg.)"
             (match Synthesis.Total.of_reported s.cell_count with
              | Unknown -> "not reported"
              | Zero -> "0"
              | Positive n -> Int.to_string n
              | Invalid n -> sprintf "invalid (%d)" n)
         ; plain
             "Cell breakdown"
             (if List.is_empty s.cells
              then "not reported"
              else sprintf "%d reported types" (List.length (Synthesis.project s).rows))
         ]
       | "timing" ->
         (match terminal_metrics [ "setup_slack"; "hold_slack" ] with
          | [] -> [ plain "Aggregate slack" "unavailable / not reported" ]
          | rows -> rows)
       | "placement" ->
         (match terminal_metrics [ "final_standard_cell_area"; "final_utilization" ] with
          | [] -> [ plain "Aggregate resources" "unavailable / not reported" ]
          | rows -> rows)
       | "routing" -> [ plain "Routing-stage metrics" "unsupported / not reported" ]
       | "checks" ->
         Option.value_map
           terminal
           ~default:[ plain "Checks" "terminal result not imported" ]
           ~f:(fun t ->
             if List.is_empty t.checks
             then [ plain "Checks" "not reported" ]
             else
               List.map t.checks ~f:(fun c ->
                 let r = fact Verdict ("Check " ^ c.name) c.status in
                 { r with
                   details =
                     r.details
                     @ Option.to_list (Option.map c.reason ~f:(fun s -> "Reason: " ^ s))
                     @ Option.to_list (Option.map c.source ~f:(fun s -> "Source: " ^ s))
                 }))
       | "finalization" ->
         Option.value_map
           terminal
           ~default:[ plain "Terminal result" "not imported" ]
           ~f:(fun t ->
             [ fact Verdict "Acceptance (agg.)" t.acceptance
             ; fact Physical_completion "Physical (agg.)" t.physical_completion
             ; fact Operation "Operation (agg.)" t.operation_status
             ; fact Verdict "Timing goal (agg.)" t.timing_goal
             ])
       | _ -> [ plain "Domain" "unsupported" ])
  in
  (* Keep freshness ahead of cached facts even in a very short panel. Stage request and
     outcomes remain independent of imported metrics and terminal acceptance. *)
  let freshness_rows =
    if show_freshness
       || not
            (Option.exists summary ~f:(fun s ->
               Asic.Summary.Freshness.equal s.freshness Validated))
    then [ freshness ]
    else []
  in
  if not compact
  then (stage :: time :: freshness_rows) @ evidence
  else (
    let evidence =
      let failures, others =
        List.partition_tf evidence ~f:(fun r -> O.Role.equal r.role Failure)
      in
      List.map (failures @ others) ~f:(fun (r : O.row) ->
        { r with
          value =
            (r.value
             ^
             match summary with
             | Some { freshness = Validated; _ } -> ""
             | _ -> " (" ^ freshness.value ^ ")")
        ; details = r.details @ O.inspection_lines [ stage; freshness ]
        })
    in
    match evidence with
    | [] -> [ stage; time ] @ freshness_rows
    | first :: rest -> (first :: stage :: time :: rest) @ freshness_rows)
;;

let rows
  ?now
  ?finalizations
  ?(compact = false)
  ?freshness
  ?(decimal_places = 3)
  ?stage_id
  ~kind
  ~run
  ~summary
  ~stages
  ()
  =
  if not (String.equal kind "timing")
  then
    legacy_rows
      ?now
      ?finalizations
      ~compact
      ?freshness
      ~decimal_places
      ?stage_id
      ~kind
      ~run
      ~summary
      ~stages
      ()
  else (
    let summary =
      Option.filter summary ~f:(fun (s : Asic.Summary.t) -> Run_ref.equal s.run run)
    in
    let analysis = Option.bind summary ~f:(fun s -> s.Asic.Summary.timing_analysis) in
    let details = O.analysis_details ~decimal_places ~run summary in
    let fact ?(role = O.Role.Muted) ?indicator label value =
      O.row ~role ?indicator ~details label value
    in
    let physical = List.find stages ~f:(fun s -> String.equal s.Asic.Stage.id "timing") in
    let stage =
      Option.value_map
        physical
        ~default:(O.analysis_row ~decimal_places ~run ~selected:false summary)
        ~f:(O.asic_stage_row ?now ~run ~selected:false)
    in
    let time =
      fact
        (if Option.is_some physical then "Stage time" else "Time")
        (Option.value stage.time ~default:"unknown")
    in
    let sta_runtime =
      if Option.is_none physical
      then []
      else
        [ fact
            "STA runtime"
            (Option.value_map analysis ~default:"unknown" ~f:O.analysis_duration)
        ]
    in
    let evidence =
      match analysis with
      | None -> [ fact "Analysis" "not yet observed; no authoritative STA evidence" ]
      | Some a ->
        [ fact
            ~role:
              (match a.timing_goal with
               | Fail -> Failure
               | Pass -> Success
               | Unknown -> Muted)
            "Goal"
            (O.goal_label a.timing_goal ^ " · " ^ a.target.stage ^ " / post-PNR STA")
        ]
        @ List.map a.metrics ~f:(fun m ->
          fact
            (m.key ^ " / " ^ m.corner)
            (Option.value_map m.value ~default:"unavailable" ~f:(fun v ->
               if Float.is_finite v
               then O.timing_metric_value ~decimal_places ~key:m.key ~unit_:m.unit_ v
               else "unavailable")
             ^ " "
             ^ Option.value m.unit_ ~default:"unit unknown"))
        @ [ fact "Source" (a.target.stage ^ " / post-PNR STA")
          ; fact "Current execution" (Option.value_exn summary).completion
          ; fact "Captured source" a.enclosing_status
          ]
    in
    let freshness =
      Option.value_map summary ~default:"not loaded" ~f:(fun s ->
        fst (O.freshness_label s.freshness))
    in
    let freshness_indicator =
      Option.value_map summary ~default:Indicator.Unavailable ~f:(fun s ->
        O.freshness_indicator s.freshness)
    in
    let freshness_row = fact ~indicator:freshness_indicator "Evidence" freshness in
    if compact
    then (
      (* At the stock five-cell height there are only three body rows. Keep status AND
         time on the first row, ahead of metrics and verbose provenance. *)
      let stale =
        not
          (Option.exists summary ~f:(fun s ->
             Asic.Summary.Freshness.equal s.freshness Validated))
      in
      let compact_evidence =
        match analysis with
        | None -> (if stale then [ freshness_row ] else []) @ evidence
        | Some a ->
          let goal = List.hd_exn evidence in
           ({ goal with
              value = (goal.value ^ if stale then " [" ^ freshness ^ "]" else "")
            ; indicator = (if stale then Some freshness_indicator else goal.indicator)
           }
           :: List.map a.corners ~f:(fun c ->
             let metrics =
               List.filter_map a.metrics ~f:(fun m ->
                 if not (String.equal m.corner c.corner)
                 then None
                 else (
                   let label =
                     match m.key with
                     | "setup_slack" -> "setup"
                     | "hold_slack" -> "hold"
                     | "setup_violations" -> "setup violations"
                     | "hold_violations" -> "hold violations"
                     | key -> key
                   in
                   Some
                     (label
                      ^ " "
                      ^ Option.value_map m.value ~default:"unavailable" ~f:(fun v ->
                        if Float.is_finite v
                        then
                          O.timing_metric_value
                            ~decimal_places
                            ~key:m.key
                            ~unit_:m.unit_
                            v
                        else "unavailable")
                      ^ Option.value_map
                          m.unit_
                          ~default:" (unit unknown)"
                          ~f:(fun unit_ -> " " ^ unit_))))
             in
             fact
               c.corner
               (if List.is_empty metrics
                then "unavailable"
                else String.concat ~sep:" · " metrics)))
          @ [ fact "Source" (a.target.stage ^ " / post-PNR STA")
            ; fact "Current execution" (Option.value_exn summary).completion
            ; fact "Captured source" a.enclosing_status
            ]
      in
      ({ stage with
         label = ""
       ; status = None
       ; time = None
       ; value =
           (stage.value
            ^ " "
            ^ time.value
            ^ " · "
            ^ if Option.is_some physical then "stage time" else "STA runtime")
       ; details
       }
       :: sta_runtime)
      @ compact_evidence)
    else (stage :: time :: sta_runtime) @ (freshness_row :: evidence))
;;

let%test_unit "typed metrics preserve zero, units, missing and nonfinite without a \
               verdict"
  =
  let run = Fs0_fixture.run_a in
  let metric value availability : Asic.Metric.t =
    { key = "setup_slack"
    ; label = "pass is a provider label"
    ; value
    ; availability
    ; unit_ = Some "ns"
    ; source = Some "exact metric source"
    }
  in
  let terminal metrics : Asic.Terminal_result.t =
    { attempt = "attempt"
    ; results_file = "results"
    ; results_digest = "results-digest"
    ; operation_status = "completed"
    ; physical_completion = "incomplete"
    ; acceptance = "not_evaluated"
    ; timing_goal = "unknown"
    ; metrics
    ; checks = []
    ; evidence = "{}"
    ; execution_timing = None
    }
  in
  let summary metrics : Asic.Summary.t =
    { run
    ; source_digest = "digest"
    ; execution_file = "execution"
    ; plan_identity = None
    ; cell_count = None
    ; cells = []
    ; metrics = []
    ; terminal = Some (terminal metrics)
    ; timing_analysis = None
    ; timing = []
    ; completion = "completed"
    ; acceptance = "pass"
    ; producer = "provider"
    ; observed_at = "now"
    ; freshness = Refresh_failed "offline"
    }
  in
  List.iter
    [ Some 0., "available", "0.000 ns [available]"
    ; None, "available", "unavailable [available]"
    ; Some 12., "not_requested", "unavailable [not_requested]"
    ; Some Float.nan, "available", "invalid (non-finite) [available]"
    ]
    ~f:(fun (value, availability, expected) ->
      let rs =
        legacy_rows
          ~kind:"timing"
          ~run
          ~summary:(Some (summary [ metric value availability ]))
          ~stages:[]
          ()
      in
      let r =
        List.find_exn rs ~f:(fun r -> String.is_prefix r.label ~prefix:"Aggregate ")
      in
      [%test_result: string] r.value ~expect:expected;
      [%test_result: O.Role.t] r.role ~expect:Muted;
      assert (Option.is_none r.status);
      List.iter
        [ "Metric source: exact metric source"
        ; "Source digest: digest"
        ; "Results digest: results-digest"
        ]
        ~f:(fun text -> assert (List.mem r.details text ~equal:String.equal)));
  let rs = rows ~kind:"finalization" ~run ~summary:(Some (summary [])) ~stages:[] () in
  let precise =
    legacy_rows
      ~decimal_places:6
      ~kind:"timing"
      ~run
      ~summary:(Some (summary [ metric (Some (-0.000987654)) "available" ]))
      ~stages:[]
      ()
    |> List.find_exn ~f:(fun row -> String.is_prefix row.label ~prefix:"Aggregate ")
  in
  [%test_result: string] precise.value ~expect:"-0.000987 ns [available]";
  let acceptance =
    List.find_exn rs ~f:(fun r -> String.equal r.label "Acceptance (agg.)")
  in
  [%test_result: string] acceptance.value ~expect:"not_evaluated";
  [%test_result: O.Role.t] acceptance.role ~expect:Warning;
  let failed : Asic.Stage.t =
    { id = "timing"
    ; name = "Timing"
    ; status = Failed
    ; requested = true
    ; reason = Some "tool failed"
    ; action = None
    ; execution_timing = None
    }
  in
  let compact =
    rows
      ~compact:true
      ~kind:"timing"
      ~run
      ~summary:(Some (summary [ metric (Some 0.) "available" ]))
      ~stages:[ failed ]
      ()
  in
  let first = List.hd_exn compact in
  assert (not (String.is_substring first.value ~substring:"0 ns"));
  assert (String.is_substring first.value ~substring:"unknown");
  assert (Option.is_none first.status);
  assert (String.is_substring first.value ~substring:"failed");
  assert (
    List.exists compact ~f:(fun r ->
      String.is_substring r.value ~substring:"refresh failed"));
  let inspected = O.inspection_lines compact |> String.concat ~sep:"\n" in
  assert (not (String.is_substring inspected ~substring:"tool failed"));
  assert (String.is_substring inspected ~substring:"offline");
  let quiet =
    rows
      ~compact:true
      ~freshness:false
      ~kind:"timing"
      ~run
      ~summary:(Some (summary [ metric (Some 0.) "available" ]))
      ~stages:[ failed ]
      ()
  in
  assert (
    List.exists quiet ~f:(fun r ->
      String.is_substring r.value ~substring:"refresh failed"));
  assert (List.exists quiet ~f:(fun row -> String.equal row.label "Evidence"));
  let failed_summary =
    { (summary []) with
      terminal = Some { (terminal []) with operation_status = "failed" }
    }
  in
  let compact =
    rows
      ~compact:true
      ~kind:"finalization"
      ~run
      ~summary:(Some failed_summary)
      ~stages:[]
      ()
  in
  [%test_result: string] (List.hd_exn compact).label ~expect:"Operation (agg.)";
  [%test_result: O.Role.t] (List.hd_exn compact).role ~expect:Failure
;;

let%test_unit "typed compact facts fence run, availability and acceptance" =
  let run = Fs0_fixture.run_a in
  let summary : Asic.Summary.t =
    { run
    ; source_digest = "digest"
    ; execution_file = "execution"
    ; plan_identity = None
    ; cell_count = Some 0
    ; cells = []
    ; metrics = []
    ; terminal = None
    ; timing_analysis = None
    ; timing = []
    ; completion = "completed"
    ; acceptance = "pass"
    ; producer = "provider"
    ; observed_at = "now"
    ; freshness = Cached_unverified
    }
  in
  let get kind summary = rows ~kind ~run ~summary ~stages:[] () in
  let rs = get "synthesis" (Some summary) in
  assert (String.equal (List.nth_exn rs 3).value "0");
  assert (String.equal (List.nth_exn rs 2).value "cached/unverified");
  assert (List.for_all rs ~f:(fun r -> Option.is_none r.status));
  let other = { summary with run = { run with id = "foreign" } } in
  assert (List.length (get "synthesis" (Some other)) = 3);
  let finalization = get "finalization" (Some summary) in
  assert (String.equal (List.nth_exn finalization 3).value "not imported");
  assert (List.for_all finalization ~f:(fun r -> not (String.equal r.value "pass")))
;;

let%test_unit "compact evidence uses actual panel content bounds at accepted terminal \
               sizes"
  =
  let module W = Hardcaml_workbench_workspaces in
  let d = W.Overview.definition in
  let kinds = List.map d.tiles ~f:(fun t -> t.W.Common.kind) in
  let appearance = Appearance.default in
  List.iter
    [ 80, 24; 120, 40; 240, 80 ]
    ~f:(fun (width, terminal_height) ->
      let height = terminal_height - 2 in
      let cells =
        match W.Layout.compute d ~width ~height ~kinds with
        | Compact ->
          assert (width = 80);
          [ "synthesis", { Workspace.Geometry.x = 0; y = 0; width; height } ]
        | Grid cells -> List.zip_exn kinds cells
      in
      let evidence = List.filter cells ~f:(fun (kind, _) -> supports kind) in
      assert (List.length evidence = if width = 80 then 1 else 6);
      List.iter evidence ~f:(fun (kind, g) ->
        let geometry =
          Panel.geometry
            ~framed:true
            ~width:g.width
            ~height:g.height
            ~horizontal_padding:1
            ~vertical_padding:0
        in
        assert (geometry.content_height >= 3);
        let content =
          O.render
            ~appearance
            ~attrs:(fun _ -> [])
            ~width:geometry.content_width
            ~height:geometry.content_height
            (rows ~kind ~run:Fs0_fixture.run_a ~summary:None ~stages:[] ())
        in
        let view =
          Panel.render
            appearance
            ~attrs:[]
            ~title:(View.text kind)
            ~geometry
            ~width:g.width
            ~height:g.height
            content
        in
        assert (View.width view = g.width && View.height view = g.height)))
;;

let%test_unit "execution duration never guesses aliases or ambiguous stage identities" =
  let stage id seconds : Asic.Stage.t =
    { id
    ; name = "Same display label"
    ; requested = true
    ; status = Completed
    ; reason = None
    ; action = None
    ; execution_timing = Execution_timing.make ~measured_seconds:seconds ~running:false ()
    }
  in
  let stages =
    [ stage "synthesis" 127.
    ; stage "placement" 14.
    ; stage "routing" 61.
    ; stage "signoff" 3723.
    ]
  in
  let time ?stage_id kind stages =
    rows
      ~now:Time_ns.epoch
      ?stage_id
      ~kind
      ~run:Fs0_fixture.run_a
      ~summary:None
      ~stages
      ()
    |> List.find_exn ~f:(fun r -> String.equal r.O.label "Time")
  in
  List.iter
    [ "synthesis", "2m 07s"; "placement", "14s"; "routing", "1m 01s" ]
    ~f:(fun (kind, expected) -> assert (String.equal (time kind stages).value expected));
  assert (String.equal (time "timing" stages).value "unknown");
  assert (String.equal (time "checks" stages).value "unknown (stage checks)");
  assert (String.equal (time "finalization" stages).value "unknown");
  assert (String.equal (time "synthesis" (stage "synthesis" 0. :: stages)).value "unknown");
  assert (String.equal (time ~stage_id:"Synthesis" "synthesis" stages).value "unknown");
  assert (String.equal (time ~stage_id:"routing" "synthesis" stages).value "1m 01s")
;;
