open! Core
open Hardcaml_workbench_protocol

let supports = function
  | "timing" | "placement" | "cts" | "routing" | "checks" | "finalization" -> true
  | _ -> false
;;

module State = struct
  type identity = Run_ref.t * string option * (string * string) option [@@deriving equal]

  type t =
    { identity : identity option
    ; detail : bool
    ; offset : int
    }

  let empty = { identity = None; detail = false; offset = 0 }

  let reconcile t ~run ~summary =
    let summary =
      Option.filter summary ~f:(fun (s : Asic.Summary.t) -> Run_ref.equal run s.run)
    in
    let identity =
      Some
        ( run
        , Option.map summary ~f:(fun s -> s.source_digest)
        , Option.bind summary ~f:(fun s ->
            Option.map s.terminal ~f:(fun terminal ->
              terminal.attempt, terminal.results_digest)) )
    in
    if Option.equal equal_identity t.identity identity then t else { empty with identity }
  ;;

  let inspect t = { t with detail = true; offset = 0 }
  let back t = { t with detail = false; offset = 0 }

  let scroll t ~delta ~max_offset =
    let current = Int.min t.offset (Int.max 0 max_offset) in
    let offset =
      Int64.(
        max zero (min (of_int (Int.max 0 max_offset)) (of_int current + of_int delta)))
    in
    { t with offset = Int64.to_int_exn offset }
  ;;
end

let metric_line (metric : Asic.Metric.t) =
  let value =
    match metric.value with
    | Some value when not (Float.is_finite value) -> "invalid (non-finite)"
    | Some value when String.equal metric.availability "available" ->
      sprintf
        "%g%s"
        value
        (Option.value_map metric.unit_ ~default:" (unit not reported)" ~f:(fun unit_ ->
           " " ^ unit_))
    | None | Some _ -> "unavailable"
  in
  sprintf
    "%s: %s [%s]"
    (if String.is_empty metric.label then metric.key else metric.label)
    value
    (if String.is_empty metric.availability
     then "availability not reported"
     else metric.availability)
;;

let check_line (check : Asic.Check.t) =
  sprintf
    "%s: %s%s"
    check.name
    (if String.is_empty check.status then "unknown (not reported)" else check.status)
    (Option.value_map check.reason ~default:"" ~f:(fun reason -> " — " ^ reason))
;;

let context (terminal : Asic.Terminal_result.t) =
  [ "Operation status (reported): " ^ terminal.operation_status
  ; "Physical completion (reported): " ^ terminal.physical_completion
  ; "Acceptance (reported): " ^ terminal.acceptance
  ; "Timing goal (reported): " ^ terminal.timing_goal
  ]
;;

let semantic_context (terminal : Asic.Terminal_result.t) =
  [ Evidence_style.fact
      ~label:"Operation status (reported): "
      Operation
      terminal.operation_status
  ; Evidence_style.fact
      ~label:"Physical completion (reported): "
      Physical_completion
      terminal.physical_completion
  ; Evidence_style.fact ~label:"Acceptance (reported): " Verdict terminal.acceptance
  ; Evidence_style.fact ~label:"Timing goal (reported): " Verdict terminal.timing_goal
  ]
;;

let is_timing (metric : Asic.Metric.t) =
  List.mem [ "setup_slack"; "hold_slack" ] metric.key ~equal:String.equal
;;

let is_physical (metric : Asic.Metric.t) =
  List.mem
    [ "final_standard_cell_area"; "final_utilization" ]
    metric.key
    ~equal:String.equal
;;

let is_declared_clock (metric : Asic.Metric.t) =
  String.equal metric.key "declared_clock_period"
;;

let semantic_lines (terminal : Asic.Terminal_result.t) ~kind ~detail =
  let metrics =
    match kind with
    | "timing" -> List.filter terminal.metrics ~f:is_timing
    | "placement" -> List.filter terminal.metrics ~f:is_physical
    | "cts" -> List.filter terminal.metrics ~f:is_declared_clock
    | "finalization" -> terminal.metrics
    | _ -> []
  in
  let heading =
    match kind with
    | "timing" -> [ "Terminal timing (aggregate)" ]
    | "placement" -> [ "Terminal physical resources (aggregate)" ]
    | "cts" -> [ "Declared clocks (recorded configuration)" ]
    | "routing" -> [ "Routing-stage detail: unsupported / not reported" ]
    | "checks" -> [ "Terminal checks (reported statuses)" ]
    | _ -> [ "Finalization (imported terminal result)" ]
  in
  let notes =
    match kind with
    | "timing" ->
      [ "Signed slack; units as reported"
      ; "Corner / mode / path-group context: inspect original sources (e)"
      ; (if List.exists terminal.metrics ~f:is_declared_clock
         then
           "Declared clock configuration: see CTS tile; measured path details not \
            reported"
         else "Declared clock configuration / path details: not reported")
      ]
    | "placement" ->
      [ "Aggregate resources, not placement-stage evidence"
      ; "Utilization is a fraction when reported as fraction; no percent conversion"
      ; "Placement congestion: unsupported / not reported"
      ]
    | "checks" ->
      [ "Check statuses are independent of acceptance and physical completion" ]
    | "cts" ->
      [ "Recorded methodology configuration, not measured CTS"
      ; "CTS tree / skew / clock coverage: unsupported / not reported"
      ; "Enter/e: full clock configuration evidence and source identity"
      ]
    | _ -> []
  in
  let measurements =
    if String.equal kind "checks"
    then
      if List.is_empty terminal.checks
      then [ Evidence_style.plain "Checks: unknown / not reported" ]
      else List.map terminal.checks ~f:Evidence_style.check
    else if String.equal kind "cts"
    then
      if List.is_empty metrics
      then [ Evidence_style.plain "Declared clock period: unavailable / not reported" ]
      else List.map metrics ~f:(fun metric -> Evidence_style.plain (metric_line metric))
    else if List.mem [ "timing"; "placement"; "finalization" ] kind ~equal:String.equal
    then
      if List.is_empty metrics
      then [ Evidence_style.plain "Metrics: unavailable / not reported" ]
      else List.map metrics ~f:(fun metric -> Evidence_style.plain (metric_line metric))
    else []
  in
  List.map heading ~f:Evidence_style.plain
  @ measurements
  @ semantic_context terminal
  @ List.map notes ~f:Evidence_style.plain
  @ [ Evidence_style.plain
        "Enter / e: full context & evidence | j/k or [ ] scroll | Esc overview"
    ]
  @
  if not detail
  then []
  else
    List.map
      ([ "Finalization attempt (exact): " ^ terminal.attempt
       ; "Results file (full): " ^ terminal.results_file
       ; "Results digest: " ^ terminal.results_digest
       ; "All terminal metrics (reported; no inferred stage attribution)"
       ]
       @ List.concat_map terminal.metrics ~f:(fun metric ->
         [ "Key: " ^ metric.key
         ; metric_line metric
         ; "Metric source (full): " ^ Option.value metric.source ~default:"not reported"
         ])
       @ [ "All terminal checks (reported)" ])
      ~f:Evidence_style.plain
    @ List.concat_map terminal.checks ~f:(fun check ->
      [ Evidence_style.check check
      ; Evidence_style.plain
          ("Check source (full): " ^ Option.value check.source ~default:"not reported")
      ])
    @ List.map [ "Terminal evidence (full):"; terminal.evidence ] ~f:Evidence_style.plain
;;

let lines terminal ~kind ~detail =
  semantic_lines terminal ~kind ~detail |> List.map ~f:Evidence_style.text
;;

let semantic_rows
  ?(fallback = [])
  ?(request_context = [])
  state
  ~run
  ~summary
  ~kind
  ~width
  ~height
  =
  if width <= 0 || height <= 0
  then []
  else (
    let state = State.reconcile state ~run ~summary in
    let fallback = List.map fallback ~f:Evidence_style.plain in
    let request_context = List.map request_context ~f:Evidence_style.plain in
    let content =
      match summary with
      | Some s when Run_ref.equal run s.Asic.Summary.run ->
        (match s.terminal with
         | Some terminal ->
           [ Evidence_style.plain
               ("Run: " ^ Backend_id.to_string run.backend ^ "/" ^ run.id)
           ; [ { Evidence_style.text = "Freshness: "; role = Plain }
             ; { text = Sexp.to_string_hum (Asic.Summary.Freshness.sexp_of_t s.freshness)
               ; role = Evidence_style.freshness_role s.freshness
               }
             ]
           ]
           @ request_context
           @ semantic_lines terminal ~kind ~detail:state.detail
           @
           if state.detail
           then
             List.map
               [ "Run reference (full): " ^ Sexp.to_string_hum (Run_ref.sexp_of_t run)
               ; "Summary source digest: " ^ s.source_digest
               ; "Execution file (full): " ^ s.execution_file
               ]
               ~f:Evidence_style.plain
           else []
         | None ->
           if (not state.detail) && not (List.is_empty fallback)
           then fallback
           else
             [ Evidence_style.plain
                 "No terminal result imported; inspect exact finalization reference"
             ]
             @ request_context)
      | None | Some _ ->
        if (not state.detail) && not (List.is_empty fallback)
        then fallback
        else
          [ Evidence_style.plain "Terminal result unavailable for this exact run" ]
          @ request_context
    in
    Evidence_style.page ~width ~height ~offset:state.offset content)
;;

let rows ?fallback ?request_context state ~run ~summary ~kind ~width ~height =
  semantic_rows ?fallback ?request_context state ~run ~summary ~kind ~width ~height
  |> List.map ~f:Evidence_style.text
;;

let scroll
  ?(fallback = [])
  ?(request_context = [])
  state
  ~run
  ~summary
  ~kind
  ~width
  ~height
  ~delta
  =
  let state = State.reconcile state ~run ~summary in
  let content =
    rows
      ~fallback
      ~request_context
      { state with offset = 0 }
      ~run
      ~summary
      ~kind
      ~width
      ~height:Int.max_value
  in
  State.scroll
    state
    ~delta
    ~max_offset:
      (if height <= 0 || width <= 0 then 0 else Int.max 0 (List.length content - height))
;;

module%test Tests = struct
  let terminal : Asic.Terminal_result.t =
    { attempt = "exact-attempt"
    ; results_file = "/private/results.json"
    ; results_digest = "results-digest"
    ; operation_status = "completed"
    ; physical_completion = "incomplete"
    ; acceptance = "unknown"
    ; timing_goal = "1 ns, corner slow"
    ; metrics =
        [ { Asic.Metric.key = "setup_slack"
          ; label = "Setup slack"
          ; value = Some (-0.25)
          ; unit_ = Some "ns"
          ; availability = "available"
          ; source = Some "/private/timing#slow"
          }
        ; { Asic.Metric.key = "final_standard_cell_area"
          ; label = "Final standard-cell area"
          ; value = Some 100.
          ; unit_ = Some "um^2"
          ; availability = "available"
          ; source = None
          }
        ; { Asic.Metric.key = "final_utilization"
          ; label = "Utilization"
          ; value = Some 0.4
          ; unit_ = Some "fraction"
          ; availability = "available"
          ; source = None
          }
        ; { Asic.Metric.key = "declared_clock_period"
          ; label = "Declared clock clk_i period"
          ; value = Some 10.
          ; unit_ = Some "ns"
          ; availability = "available"
          ; source =
              Some
                "{\"configuration\":\"/private/recorded/config.json\",\"sha256\":\"exact-config-digest\",\"clock_port\":\"clk_i\"}"
          }
        ]
    ; checks =
        [ { Asic.Check.name = "DRC"
          ; status = "unknown"
          ; reason = Some "not run"
          ; source = Some "/private/checks"
          }
        ]
    ; evidence = "full raw terminal evidence"
    ; execution_timing = None
    }
  ;;

  let%test_unit "declared clock is configuration, with full source and no measured CTS \
                 claim"
    =
    let cts = lines terminal ~kind:"cts" ~detail:false in
    assert (
      List.mem cts "Declared clock clk_i period: 10 ns [available]" ~equal:String.equal);
    assert (
      List.mem
        cts
        "Recorded methodology configuration, not measured CTS"
        ~equal:String.equal);
    assert (
      List.mem
        cts
        "CTS tree / skew / clock coverage: unsupported / not reported"
        ~equal:String.equal);
    assert (
      not (List.exists cts ~f:(String.is_substring ~substring:"exact-config-digest")));
    let detail = lines terminal ~kind:"cts" ~detail:true in
    let clock = List.find_exn terminal.metrics ~f:is_declared_clock in
    assert (
      List.mem
        detail
        ("Metric source (full): " ^ Option.value_exn clock.source)
        ~equal:String.equal);
    let absent =
      { terminal with
        metrics = List.filter terminal.metrics ~f:(Fn.non is_declared_clock)
      }
    in
    let cts = lines absent ~kind:"cts" ~detail:false in
    assert (
      List.mem cts "Declared clock period: unavailable / not reported" ~equal:String.equal);
    let s =
      { (List.hd_exn Fs0_fixture.snapshot.summaries) with terminal = Some terminal }
    in
    let state =
      State.reconcile State.empty ~run:s.run ~summary:(Some s) |> State.inspect
    in
    let output =
      rows state ~run:s.run ~summary:(Some s) ~kind:"cts" ~width:30 ~height:200
    in
    assert (
      String.is_substring
        (String.concat output)
        ~substring:(Option.value_exn clock.source));
    assert (not (State.back state).detail)
  ;;

  let%test_unit "signed slack, area units and fractional utilization retain context" =
    let timing = lines terminal ~kind:"timing" ~detail:false in
    assert (List.mem timing "Setup slack: -0.25 ns [available]" ~equal:String.equal);
    assert (
      List.mem timing "Timing goal (reported): 1 ns, corner slow" ~equal:String.equal);
    let physical = lines terminal ~kind:"placement" ~detail:false in
    assert (
      List.mem
        physical
        "Final standard-cell area: 100 um^2 [available]"
        ~equal:String.equal);
    assert (List.mem physical "Utilization: 0.4 fraction [available]" ~equal:String.equal);
    assert (not (List.exists physical ~f:(String.is_substring ~substring:"40%")));
    let checks = lines terminal ~kind:"checks" ~detail:false in
    assert (List.mem checks "DRC: unknown — not run" ~equal:String.equal);
    assert (List.mem checks "Acceptance (reported): unknown" ~equal:String.equal);
    assert (
      List.mem checks "Physical completion (reported): incomplete" ~equal:String.equal);
    let absent = lines { terminal with checks = [] } ~kind:"checks" ~detail:false in
    assert (List.mem absent "Checks: unknown / not reported" ~equal:String.equal);
    List.iter [ "cts"; "routing" ] ~f:(fun kind ->
      let output = lines terminal ~kind ~detail:false in
      assert (
        List.exists
          output
          ~f:(String.is_substring ~substring:"unsupported / not reported"));
      assert (not (List.exists output ~f:(String.is_substring ~substring:"100 um^2"))));
    let detail = lines terminal ~kind:"finalization" ~detail:true in
    assert (List.mem detail terminal.evidence ~equal:String.equal);
    assert (
      List.mem detail "Metric source (full): /private/timing#slow" ~equal:String.equal)
  ;;

  let%test_unit "typed terminal spans isolate failed checks from reasons and raw evidence"
    =
    let terminal =
      { terminal with
        acceptance = "fail"
      ; checks =
          [ { name = "DRC"
            ; status = "pending"
            ; reason = Some "passed failed"
            ; source = None
            }
          ]
      ; evidence = "Validated passed failed pending"
      }
    in
    let spans = List.concat (semantic_lines terminal ~kind:"checks" ~detail:true) in
    let has text role =
      List.exists spans ~f:(fun span ->
        String.equal span.text text && Evidence_style.Role.equal span.role role)
    in
    assert (has "fail" Failed);
    assert (has "pending" Pending);
    assert (has " — passed failed" Plain);
    assert (has terminal.evidence Plain);
    let s =
      { (List.hd_exn Fs0_fixture.snapshot.summaries) with
        terminal = Some terminal
      ; freshness = Validated
      }
    in
    List.iter [ 1; 17; 80 ] ~f:(fun width ->
      let styled =
        semantic_rows
          State.empty
          ~run:s.run
          ~summary:(Some s)
          ~kind:"checks"
          ~width
          ~height:100
      in
      let spans = List.concat styled in
      assert (
        List.exists spans ~f:(fun span -> Evidence_style.Role.equal span.role Validated));
      assert (
        List.for_all styled ~f:(fun row ->
          Bonsai_term.View.width (Bonsai_term.View.text (Evidence_style.text row))
          <= width)));
    assert (
      List.is_empty
        (semantic_rows
           State.empty
           ~run:{ s.run with id = "other" }
           ~summary:(Some s)
           ~kind:"checks"
           ~width:80
           ~height:0))
  ;;

  let%test_unit "run/result replacement clears details and paging; rendering is bounded" =
    let s =
      { (List.hd_exn Fs0_fixture.snapshot.summaries) with terminal = Some terminal }
    in
    let state =
      State.reconcile State.empty ~run:s.run ~summary:(Some s) |> State.inspect
    in
    let state = State.scroll state ~delta:Int.max_value ~max_offset:100 in
    let changed = { s.run with id = "different-run" } in
    let reset = State.reconcile state ~run:changed ~summary:(Some s) in
    assert (not reset.detail);
    assert (reset.offset = 0);
    let output =
      rows state ~run:changed ~summary:(Some s) ~kind:"timing" ~width:80 ~height:5
    in
    assert (not (List.exists output ~f:(String.is_substring ~substring:"-0.25")));
    let updated =
      { s with terminal = Some { terminal with results_digest = "new-result" } }
    in
    assert (not (State.reconcile state ~run:s.run ~summary:(Some updated)).detail);
    let replaced =
      { s with terminal = Some { terminal with attempt = "another-attempt" } }
    in
    assert (not (State.reconcile state ~run:s.run ~summary:(Some replaced)).detail);
    assert (not (State.reconcile state ~run:s.run ~summary:None).detail);
    let output =
      rows state ~run:s.run ~summary:(Some s) ~kind:"finalization" ~width:8 ~height:3
    in
    assert (List.length output <= 3);
    assert (
      List.for_all output ~f:(fun line ->
        Bonsai_term.View.width (Bonsai_term.View.text line) <= 8));
    assert (
      List.is_empty
        (rows state ~run:s.run ~summary:(Some s) ~kind:"timing" ~width:0 ~height:3));
    assert ((State.scroll state ~delta:Int.min_value ~max_offset:100).offset = 0);
    assert (not (State.back state).detail)
  ;;

  let%test_unit "bottom paging reverses immediately, including after viewport resize" =
    let s =
      { (List.hd_exn Fs0_fixture.snapshot.summaries) with terminal = Some terminal }
    in
    let initial =
      State.reconcile State.empty ~run:s.run ~summary:(Some s) |> State.inspect
    in
    let move state ~width ~height delta =
      scroll state ~run:s.run ~summary:(Some s) ~kind:"finalization" ~width ~height ~delta
    in
    let view state ~width ~height =
      rows state ~run:s.run ~summary:(Some s) ~kind:"finalization" ~width ~height
    in
    let bottom =
      List.fold (List.init 100 ~f:Fn.id) ~init:initial ~f:(fun state _ ->
        move state ~width:20 ~height:3 1)
    in
    let bottom = move bottom ~width:20 ~height:3 Int.max_value in
    let still_bottom = move bottom ~width:20 ~height:3 100 in
    assert (still_bottom.offset = bottom.offset);
    let reverse = move still_bottom ~width:20 ~height:3 (-1) in
    assert (reverse.offset = bottom.offset - 1);
    assert (
      List.equal
        String.equal
        (List.drop (view reverse ~width:20 ~height:3) 1)
        (List.take (view bottom ~width:20 ~height:3) 2));
    let resized_bottom = view bottom ~width:100 ~height:8 in
    let resized_reverse = move bottom ~width:100 ~height:8 (-1) in
    assert (
      List.equal
        String.equal
        (List.drop (view resized_reverse ~width:100 ~height:8) 1)
        (List.take resized_bottom 7));
    assert (resized_reverse.offset < bottom.offset);
    assert (initial.offset = 0)
  ;;
end
