open! Core
open! Async
open Hardcaml_workbench_protocol
module Service = Hardcaml_workbench_backend.Asic_service
module Config = Hardcaml_workbench_project_integration.Asic_config
module Public = Hardcaml_workbench_backend.Asic_public
module Evidence_file = Hardcaml_workbench_backend.Asic_evidence_file
module Owned_process = Hardcaml_workbench_backend.Asic_process
module Adapter = Hardcaml_workbench_adapters.Asic_adapter

let require condition message = if not condition then failwith message
let environment = V1.Environment_selection.Inherit_daemon

let handle service root operation =
  Service.handle service ~root ~environment operation
  >>| function
  | Ok snapshot -> snapshot
  | Error error -> raise_s [%message "ASIC request failed" (error : V1.Error.t)]
;;

let settled service root operation =
  let%bind (_ : Asic.Snapshot.t) = handle service root operation in
  let%bind () = Service.completion service in
  handle service root Get
;;

let selection profile : Asic.Selection.t =
  { flow = "standard"; profile; endpoint = "synthesis"; assignments = [] }
;;

let summary (snapshot : Asic.Snapshot.t) id =
  List.find_exn snapshot.summaries ~f:(fun s -> String.equal s.Asic.Summary.run.id id)
;;

let reports root =
  In_thread.run (fun () ->
    In_channel.read_lines (Filename.concat root "calls")
    |> List.count ~f:(fun line -> String.is_prefix line ~prefix:"[\"report\""))
;;

let launches root profile =
  In_thread.run (fun () ->
    In_channel.read_lines (Filename.concat root "calls")
    |> List.count ~f:(fun line ->
      if not (String.is_prefix line ~prefix:"[\"stages\"")
      then false
      else (
        let args = Public.list (Public.decode line) |> List.map ~f:Public.text in
        let index =
          List.findi_exn args ~f:(fun _ s -> String.equal s "--methodology-plan") |> fst
        in
        let plan = Public.decode (In_channel.read_all (List.nth_exn args (index + 1))) in
        Poly.equal (Public.field "fixture_profile" plan) (`String profile))))
;;

(* These tests isolate provider observation/lifecycle. The full source supervisor, receipt
   validation and exact bundle contract are exercised by test_preparation. *)
let attach_preparation service =
  let latest = ref None in
  Service.set_preparation_runner
    service
    (fun ~root ~environment ~unique:_ ~cancelled:_ operation ->
       (match operation with
        | Preparation.Operation.Prepare
            { submission_key; selection; expected_plan_identity } ->
          let plan =
            `Assoc
              [ "contract", `String "hardcaml-asic.methodology-plan"
              ; "schema_version", `Int 1
              ; "plan_identity", `String (String.make 64 'a')
              ; "bundle_identity", `String (String.make 64 'b')
              ; "fixture_profile", `String selection.profile
              ; "fixture_endpoint", `String selection.endpoint
              ]
          in
          let created_at = Timestamp.of_time_ns (Time_ns.now ()) in
          latest
          := Some
               { Preparation.Attempt.id = submission_key
               ; selection
               ; selection_identity = submission_key
               ; expected_plan_identity
               ; source_root = root
               ; build_target = "fixture.exe"
               ; source_executable = root ^ "/fixture.exe"
               ; environment
               ; results_root = root
               ; timeout_seconds = 10
               ; created_at
               ; outcome = Completed
               ; build_job = None
               ; emission_job = None
               ; diagnostic = None
               ; bundle =
                   Some
                     { bundle_identity = String.make 64 'b'
                     ; plan_identity = String.make 64 'a'
                     ; output_dir = root
                     ; reused = false
                     ; plan_json = Yojson.Safe.to_string plan
                     ; artifacts = []
                     }
               }
        | Get | Cancel _ -> ()
        | _ -> failwith "Unexpected preparation operation");
       return
         (Ok
            { Preparation.Snapshot.availability = Available
            ; session_only = true
            ; requested_attempt = Option.map !latest ~f:(fun a -> a.id)
            ; latest = !latest
            ; history = Option.to_list !latest
            ; staged = None
            }))
;;

let metric_fixtures () =
  let source =
    `Assoc [ "path", `String "/public/segment.json"; "field", `String "metrics.key" ]
  in
  let metric ?(availability = "available") ?(unit_ = `String "count") key value =
    `Assoc
      [ "raw_key", `String key
      ; "value", value
      ; "availability", `String availability
      ; "unit", unit_
      ; "source", source
      ]
  in
  let key = "design__lint_warning__count" in
  let project j = List.hd_exn (Public.project_metrics [ j ]) in
  List.iter
    [ metric key (`Int 2), Some 2.
    ; metric key (`Float 0.), Some 0.
    ; metric key (`Intlit "3"), Some 3.
    ; metric key (`Float 0.5), None
    ; metric key (`Int (-1)), None
    ; metric key (`Float Float.infinity), None
    ; metric key (`Float Float.nan), None
    ; metric key (`String "2"), None
    ; metric key `Null, None
    ; metric ~availability:"unavailable" key (`Int 0), None
    ; metric ~availability:"unknown" key (`Int 0), None
    ; metric ~unit_:(`String "cells") key (`Int 2), None
    ; metric ~unit_:`Null key (`Int 2), None
    ; ( metric ~unit_:(`String "µm²") "design__instance__area" (`Float 13041.6048)
      , Some 13041.6048 )
    ]
    ~f:(fun (raw, expected) ->
      let m = project raw in
      require (Option.equal Float.equal m.value expected) "Wrong normalized metric value";
      require
        (String.equal
           m.availability
           (if Option.is_some expected then "available" else "unavailable"))
        "Invalid metric claimed availability";
      require
        (Option.equal String.equal m.source (Some (Yojson.Safe.to_string source)))
        "Public metric source lost");
  require (List.is_empty (Public.project_metrics [])) "Missing metrics fabricated";
  let absent = project (`Assoc [ "raw_key", `String key ]) in
  require
    (Option.is_none absent.value
     && Option.is_none absent.unit_
     && Option.is_none absent.source)
    "Missing metric fields defaulted to evidence";
  require
    (Option.equal
       String.equal
       (project (metric ~unit_:(`String "ns") key (`Int 2))).unit_
       (Some "ns"))
    "Mismatched supplied unit was rewritten";
  require
    (List.is_empty (Public.project_metrics [ metric "timing__setup__ws" (`Int 1) ]))
    "Unknown timing metric inferred";
  List.iter Public.known_metrics ~f:(fun (key, (_, unit_, _)) ->
    require
      (Option.equal
         Float.equal
         (project (metric ~unit_:(`String unit_) key (`Int 0))).value
         (Some 0.))
      "Recognized public metric omitted");
  require
    (Result.is_error
       (Or_error.try_with (fun () ->
          Public.project_metrics (List.init 65 ~f:(fun _ -> metric key (`Int 0))))))
    "Metric budget not enforced";
  let r : Asic.Run.t =
    { run =
        { backend = Backend_id.of_string "asic"
        ; id = "fixture"
        ; build = None
        ; label = None
        }
    ; reference = { attempt = "/public/attempt"; stream_id = "fixture" }
    ; selection = None
    ; cursor = 0
    ; status = "completed"
    ; execution_file = Some "/public/execution.json"
    ; error = None
    ; stages = []
    ; execution_timing = None
    }
  in
  let checkpoint ?(boundary = "synthesis") n =
    `Assoc
      [ "reference", `Assoc [ "identity", `Int n; "boundary", `String boundary ]
      ; "metric_origin", `String "boundary_snapshot"
      ; ( "metrics"
        , `List [ metric ~unit_:(`String "cells") "design__instance__count" (`Int n) ] )
      ; ( "supplementary"
        , `List [ `Assoc [ "mapped_cell_types", `Assoc [ "cell", `Int n ] ] ] )
      ]
  in
  let report ?(status = "completed") checkpoints =
    `Assoc
      [ "contract", `String "hardcaml-asic.report"
      ; "schema_version", `Int 1
      ; "execution", `Assoc [ "attempt_id", `String "fixture"; "status", `String status ]
      ; "acceptance", `String "not_evaluated"
      ; ( "methodology"
        , `Assoc
            [ "contract", `String "hardcaml-asic.historical-methodology"
            ; "schema_version", `Int 1
            ; "state", `String "recorded"
            ; "reference", `Assoc [ "attempt_id", `String "fixture" ]
            ] )
      ; "checkpoints", `List checkpoints
      ]
  in
  let summarize ?status checkpoints =
    Public.summary
      r
      ~expected_plan:None
      ~execution_file:"/public/execution.json"
      (report ?status checkpoints)
  in
  let s =
    summarize ~status:"failed" [ checkpoint 7; checkpoint ~boundary:"routing" 1042 ]
  in
  require
    (Option.equal Int.equal s.cell_count (Some 7)
     && Option.equal Float.equal (List.hd_exn s.metrics).value (Some 7.)
     && Poly.equal
          (Public.field "reference" (Public.decode s.producer))
          (`Assoc [ "identity", `Int 7; "boundary", `String "synthesis" ])
     && List.equal Poly.equal s.cells [ "cell", 7 ]
     && String.equal s.completion "failed"
     && String.equal s.acceptance "not_evaluated"
     && Option.is_none s.terminal)
    "Metrics/count/producer selected different checkpoints";
  require (List.is_empty (summarize []).metrics) "Checkpoint absence fabricated metrics";
  require (List.is_empty (summarize [ `Assoc [] ]).metrics) "Missing metrics fabricated";
  let missing = summarize ~status:"failed" [ checkpoint ~boundary:"routing" 1042 ] in
  require
    (Option.is_none missing.cell_count
     && List.is_empty missing.cells
     && List.is_empty missing.metrics
     && String.equal missing.producer "no synthesis checkpoint"
     && String.equal missing.completion "failed")
    "Routing-only evidence was guessed to be synthesis";
  let missing =
    summarize
      [ `Assoc
          [ ( "metrics"
            , `List
                [ metric ~unit_:(`String "cells") "design__instance__count" (`Int 99) ] )
          ]
      ]
  in
  require
    (Option.is_none missing.cell_count && List.is_empty missing.metrics)
    "Missing boundary guessed to be synthesis";
  require
    (Result.is_error
       (Or_error.try_with (fun () -> summarize [ checkpoint 1; checkpoint 7 ])))
    "Ambiguous synthesis evidence silently selected";
  let mismatched =
    summarize
      [ `Assoc
          [ "reference", `Assoc [ "boundary", `String "synthesis" ]
          ; ( "metrics"
            , `List [ metric ~unit_:(`String "count") "design__instance__count" (`Int 7) ]
            )
          ]
      ]
  in
  require
    (Option.is_none mismatched.cell_count
     && Option.is_none (List.hd_exn mismatched.metrics).value)
    "Unit mismatch remained available in cell count"
;;

(* Recreate the original v1 blob shape and digest without depending on private cache
   implementation helpers. The normal service read path must reopen this offline. *)
let downgrade_summary_blob ?(version = 1) filename =
  match Sexp.of_string (In_channel.read_all filename) with
  | Sexp.List fields ->
    let summary =
      List.find_map_exn fields ~f:(function
        | Sexp.List [ Atom "summary"; summary ] ->
          (match Asic.Summary.sexp_of_t (Asic.Summary.t_of_sexp summary) with
           | Sexp.List fields -> Some fields
           | _ -> failwith "Expected summary record")
        | _ -> None)
      |> List.filter ~f:(function
        | Sexp.List (Atom "metrics" :: _) when version = 1 -> false
        | Sexp.List (Atom "terminal" :: _) -> false
        | _ -> true)
      |> fun fields -> Sexp.List fields
    in
    let digest = Public.digest (Sexp.to_string_mach summary) in
    let legacy =
      Sexp.List
        [ List [ Atom "version"; Atom (Int.to_string version) ]
        ; List [ Atom "normalized_digest"; Atom digest ]
        ; List [ Atom "summary"; summary ]
        ]
    in
    Out_channel.write_all filename ~data:(Sexp.to_string legacy)
  | _ -> failwith "Expected cache blob record"
;;

let terminal_fixture ~attempt ~execution_file ~execution_bytes ~references =
  let operation = Filename.concat attempt "operation.json" in
  let results_file = Filename.concat attempt "published-results.json" in
  let metric value unit_ =
    `Assoc
      [ "value", value
      ; "unit", `String unit_
      ; "unavailable_reason", `Null
      ; "source", `String "evidence/final/metrics.csv"
      ; "tool", `Assoc [ "name", `String "LibreLane" ]
      ; "stage", `String "final"
      ; "corner", `String "slow"
      ; "mode", `String "setup"
      ; "origin_boundary", `String "signoff"
      ]
  in
  let results =
    `Assoc
      [ "schema_version", `Int 1
      ; "run_id", `String "operation-1"
      ; "build_identity", `String (String.make 64 'b')
      ; ( "provenance"
        , `Assoc
            [ "contract", `String "hardcaml-asic.segment-finalization"
            ; "operation", `String operation
            ] )
      ; ( "metrics"
        , `Assoc
            [ "setup_slack", metric (`Float (-0.25)) "ns"
            ; "hold_slack", metric (`Float 0.125) "ns"
            ; "final_utilization", metric (`Float 0.3) "fraction"
            ; "mapped_cells", metric (`Float 73.) "cells"
            ] )
      ; ( "checks"
        , `Assoc
            [ ( "drc"
              , `Assoc
                  [ "status", `String "fail"
                  ; "reason", `String "violations"
                  ; "raw", `Assoc [ "count", `Int 2 ]
                  ; "source", `String "evidence/final/metrics.csv"
                  ] )
            ; "lvs", `Assoc [ "status", `String "pass"; "reason", `Null ]
            ] )
      ; "timing_goal", `String "fail"
      ; "timing_unconstrained_modes", `List []
      ; "errors", `List [ `String "retained diagnostic" ]
      ]
  in
  let results_bytes = Yojson.Safe.to_string results in
  let receipt =
    `Assoc
      [ "contract", `String "hardcaml-asic.segment-finalization"
      ; "schema_version", `Int 1
      ; "attempt_id", `String "operation-1"
      ; "status", `String "failed"
      ; "phase", `String "acceptance"
      ; "ended_at", `String "recorded"
      ; "exit_code", `Int 1
      ; "request", `Assoc [ "accept", `Bool true; "execution", `String execution_file ]
      ; "external_postcheck", `String "failed"
      ; "evidence_context", `Assoc [ "build_identity", `String (String.make 64 'b') ]
      ; "acceptance", `String "fail"
      ; ( "execution"
        , `Assoc
            [ "path", `String execution_file
            ; "sha256", `String (Public.digest execution_bytes)
            ; "attempt_id", Public.field "attempt_id" (Public.decode execution_bytes)
            ] )
      ; "selected_checkpoints", `List references
      ; ( "results"
        , `Assoc
            [ "path", `String results_file
            ; "sha256", `String (Public.digest results_bytes)
            ] )
      ]
  in
  receipt, results_bytes
;;

let legacy_physical_blob filename ~run_id =
  match Sexp.of_string (In_channel.read_all filename) with
  | Sexp.List fields ->
    let summary =
      List.find_map_exn fields ~f:(function
        | Sexp.List [ Atom "summary"; summary ] -> Some (Asic.Summary.t_of_sexp summary)
        | _ -> None)
    in
    if String.equal summary.run.id run_id && Option.is_some summary.terminal
    then (
      let summary =
        { summary with
          cell_count = Some 1042
        ; cells = [ "post_routing", 1042 ]
        ; metrics =
            List.map summary.metrics ~f:(fun m ->
              if String.equal m.Asic.Metric.key "design__instance__count"
              then { m with value = Some 1042. }
              else m)
        ; producer =
            "{\"reference\":{\"boundary\":\"routing\"},\"metric_origin\":\"boundary_snapshot\"}"
        }
      in
      let sexp = Asic.Summary.sexp_of_t summary in
      Out_channel.write_all
        filename
        ~data:
          (Sexp.to_string
             (Sexp.List
                [ List [ Atom "version"; Atom "3" ]
                ; List
                    [ Atom "normalized_digest"
                    ; Atom (Public.digest (Sexp.to_string_mach sexp))
                    ]
                ; List [ Atom "summary"; sexp ]
                ])))
  | _ -> failwith "Expected summary blob"
;;

let declared_clock_fixtures () =
  let plan_identity = String.make 64 'a'
  and bundle_identity = String.make 64 'b' in
  let replace key value = function
    | `Assoc fields ->
      `Assoc ((key, value) :: List.Assoc.remove fields key ~equal:String.equal)
    | _ -> failwith "Expected clock fixture object"
  in
  let fixture configuration_bytes =
    let snapshot =
      `Assoc
        [ "contract", `String "hardcaml-asic.methodology-plan"
        ; "schema_version", `Int 1
        ; "plan_identity", `String plan_identity
        ; "bundle_identity", `String bundle_identity
        ; "configuration_bytes", `String configuration_bytes
        ; "resolved_settings", `Assoc [ "CLOCK_PERIOD", `String "clock" ]
        ]
    in
    let bytes = Yojson.Safe.to_string snapshot in
    let reference =
      `Assoc
        [ "snapshot_path", `String "/historical/plan.json"
        ; "snapshot_sha256", `String (Public.digest bytes)
        ; "plan_identity", `String plan_identity
        ; "bundle_identity", `String bundle_identity
        ; "attempt_id", `String "implementation"
        ]
    in
    let report =
      `Assoc
        [ "execution", `Assoc [ "attempt_id", `String "implementation" ]
        ; ( "methodology"
          , `Assoc
              [ "plan_identity", `String plan_identity
              ; "bundle_identity", `String bundle_identity
              ; "reference", reference
              ] )
        ]
    in
    let receipt =
      `Assoc
        [ "execution", `Assoc [ "attempt_id", `String "implementation" ]
        ; "evidence_context", `Assoc [ "build_identity", `String bundle_identity ]
        ]
    in
    report, receipt, bytes
  in
  let project report receipt bytes =
    Public.declared_clock_metric ~report ~receipt ~snapshot_bytes:(Some bytes)
  in
  let report, receipt, bytes = fixture "{\"CLOCK_PORT\":\"clk\",\"CLOCK_PERIOD\":20.0}" in
  let clock = project report receipt bytes in
  require
    (String.equal clock.key "declared_clock_period"
     && String.equal clock.label "Declared clock clk period"
     && String.equal clock.availability "available"
     && Option.equal Float.equal clock.value (Some 20.)
     && Option.equal String.equal clock.unit_ (Some "ns"))
    "Declared clock period was not projected as a constraint";
  let source = Public.decode (Option.value_exn clock.source) in
  require
    (Poly.equal (Public.field "snapshot_sha256" source) (`String (Public.digest bytes))
     && Poly.equal (Public.field "snapshot_path" source) (`String "/historical/plan.json")
     && Poly.equal (Public.field "plan_identity" source) (`String plan_identity)
     && Poly.equal (Public.field "bundle_identity" source) (`String bundle_identity)
     && Poly.equal
          (Public.field "CLOCK_PORT" (Public.field "fields" source))
          (`String "clk"))
    "Declared clock provenance lost";
  let absent =
    Public.declared_clock_metric ~report:(`Assoc []) ~receipt ~snapshot_bytes:None
  in
  require
    (Option.is_none absent.value && String.equal absent.availability "unavailable")
    "Missing historical clock was invented";
  List.iter
    [ "{}"
    ; "not-json"
    ; "{\"CLOCK_PORT\":\"clk\",\"CLOCK_PERIOD\":0}"
    ; "{\"CLOCK_PORT\":\"clk\",\"CLOCK_PERIOD\":-1}"
    ; "{\"CLOCK_PORT\":\"clk\",\"CLOCK_PERIOD\":\"20\"}"
    ; "{\"CLOCK_PORT\":\"clk\",\"CLOCK_PERIOD\":null}"
    ; "{\"CLOCK_PORT\":\" \",\"CLOCK_PERIOD\":20}"
    ; "{\"CLOCK_PERIOD\":20}"
    ]
    ~f:(fun configuration ->
      let report, receipt, bytes = fixture configuration in
      let clock = project report receipt bytes in
      require
        (Option.is_none clock.value && String.equal clock.availability "unavailable")
        "Invalid declared clock remained available");
  let rejected f =
    require (Result.is_error (Or_error.try_with f)) "Uncorrelated clock snapshot accepted"
  in
  rejected (fun () -> project report receipt (bytes ^ " "));
  let methodology = Public.field "methodology" report in
  rejected (fun () ->
    project
      (replace
         "methodology"
         (replace "plan_identity" (`String "different") methodology)
         report)
      receipt
      bytes);
  rejected (fun () ->
    project
      (replace
         "methodology"
         (replace "bundle_identity" (`String "different") methodology)
         report)
      receipt
      bytes);
  rejected (fun () ->
    project
      report
      (replace
         "evidence_context"
         (`Assoc [ "build_identity", `String "different" ])
         receipt)
      bytes);
  rejected (fun () ->
    project
      report
      (replace "execution" (`Assoc [ "attempt_id", `String "different" ]) receipt)
      bytes);
  let reference = Public.field "reference" methodology in
  let wrong_envelope_bytes =
    Yojson.Safe.to_string (replace "schema_version" (`Int 2) (Public.decode bytes))
  in
  let wrong_envelope_report =
    replace
      "methodology"
      (replace
         "reference"
         (replace
            "snapshot_sha256"
            (`String (Public.digest wrong_envelope_bytes))
            reference)
         methodology)
      report
  in
  rejected (fun () -> project wrong_envelope_report receipt wrong_envelope_bytes);
  rejected (fun () ->
    Public.declared_clock_snapshot
      (replace
         "methodology"
         (replace "reference" (replace "snapshot_sha256" `Null reference) methodology)
         report))
;;

let terminal_fixtures () =
  let reference =
    `Assoc
      [ "path", `String "/public/checkpoint"
      ; "identity", `String "identity"
      ; "boundary", `String "signoff"
      ]
  in
  let execution =
    `Assoc
      [ "attempt_id", `String "implementation-1"
      ; "status", `String "completed"
      ; "artifacts", `List [ reference ]
      ; ( "occurrences"
        , `List
            [ `Assoc
                [ "action_key", `String "implementation.signoff"
                ; "status", `String "completed"
                ; "exit_code", `Int 0
                ]
            ] )
      ]
  in
  let execution_bytes = Yojson.Safe.to_string execution in
  let report =
    `Assoc
      [ "execution", execution
      ; "completion", `Assoc [ "physical", `String "full" ]
      ; "checkpoints", `List [ `Assoc [ "reference", reference ] ]
      ]
  in
  let attempt = "/public/finalization"
  and execution_file = "/public/execution.json" in
  let receipt, results_bytes =
    terminal_fixture ~attempt ~execution_file ~execution_bytes ~references:[ reference ]
  in
  let project
    ?(report = report)
    ?(execution_bytes = execution_bytes)
    ?(results_bytes = results_bytes)
    receipt
    =
    Public.terminal_result
      ~attempt
      ~execution_file
      ~execution_bytes
      ~report
      ~receipt
      ~results_bytes
  in
  let terminal = project receipt in
  let setup =
    List.find_exn terminal.metrics ~f:(fun m ->
      String.equal m.Asic.Metric.key "setup_slack")
  in
  require (Option.equal Float.equal setup.value (Some (-0.25))) "Signed slack discarded";
  require
    (String.is_substring (Option.value_exn setup.source) ~substring:"slow"
     && String.is_substring
          (Option.value_exn setup.source)
          ~substring:"/public/finalization/evidence/final/metrics.csv"
     && String.is_substring terminal.evidence ~substring:"retained diagnostic")
    "Terminal provenance/diagnostics lost";
  require
    (String.equal terminal.operation_status "failed"
     && String.equal terminal.acceptance "fail"
     && String.equal terminal.physical_completion "full"
     && String.equal terminal.timing_goal "fail")
    "Distinct terminal facts conflated";
  require
    (String.equal
       (List.find_exn terminal.checks ~f:(fun c ->
          String.equal c.Asic.Check.name "antenna"))
         .status
       "unknown")
    "Missing check promoted to pass";
  let replace key value = function
    | `Assoc fields ->
      `Assoc ((key, value) :: List.Assoc.remove fields key ~equal:String.equal)
    | _ -> failwith "Expected fixture object"
  in
  let rejected f =
    require (Result.is_error (Or_error.try_with f)) "Invalid terminal evidence accepted"
  in
  let rec reorder_objects = function
    | `Assoc fields ->
      `Assoc (List.rev_map fields ~f:(fun (key, value) -> key, reorder_objects value))
    | `List values -> `List (List.map values ~f:reorder_objects)
    | scalar -> scalar
  in
  ignore
    (project ~report:(replace "execution" (reorder_objects execution) report) receipt
     : Asic.Terminal_result.t);
  rejected (fun () ->
    project
      ~report:(replace "execution" (replace "status" (`String "failed") execution) report)
      receipt);
  let changed_occurrences =
    Public.list (Public.field "occurrences" execution)
    |> List.map ~f:(fun occurrence -> replace "status" (`String "failed") occurrence)
  in
  rejected (fun () ->
    project
      ~report:
        (replace
           "execution"
           (replace "occurrences" (`List changed_occurrences) execution)
           report)
      receipt);
  rejected (fun () -> project ~results_bytes:(results_bytes ^ " ") receipt);
  rejected (fun () -> project ~execution_bytes:(execution_bytes ^ " ") receipt);
  rejected (fun () ->
    project (replace "execution" (`Assoc [ "path", `String "/wrong" ]) receipt));
  rejected (fun () ->
    project
      (replace
         "execution"
         (replace
            "attempt_id"
            (`String "different-implementation")
            (Public.field "execution" receipt))
         receipt));
  rejected (fun () -> project (replace "selected_checkpoints" (`List []) receipt));
  let with_results results =
    let results_bytes = Yojson.Safe.to_string results in
    let receipt =
      replace
        "results"
        (`Assoc
          [ "path", Public.field "path" (Public.field "results" receipt)
          ; "sha256", `String (Public.digest results_bytes)
          ])
        receipt
    in
    project ~results_bytes receipt
  in
  let results = Public.decode results_bytes in
  rejected (fun () ->
    with_results (replace "run_id" (`String "implementation-1") results));
  rejected (fun () -> with_results (replace "schema_version" (`Int 2) results));
  rejected (fun () ->
    with_results
      (replace
         "provenance"
         (`Assoc [ "operation", `String "/other/operation.json" ])
         results));
  let invalid_metric =
    `Assoc [ "value", `Float (-2.); "unit", `String "um^2"; "unavailable_reason", `Null ]
  in
  let invalid =
    with_results (replace "metrics" (`Assoc [ "setup_slack", invalid_metric ]) results)
  in
  require
    (Option.is_none (List.hd_exn invalid.metrics).value)
    "Slack unit mismatch accepted";
  let invalid =
    with_results (replace "metrics" (`Assoc [ "mapped_area", invalid_metric ]) results)
  in
  require (Option.is_none (List.hd_exn invalid.metrics).value) "Negative area accepted";
  let invalid =
    with_results
      (replace
         "checks"
         (`Assoc [ "drc", `Assoc [ "status", `String "unrecognized" ] ])
         results)
  in
  require
    (String.equal (List.hd_exn invalid.checks).status "unknown")
    "Unknown check invented pass";
  let unavailable =
    replace
      "unavailable_reason"
      (`String "no constrained timing paths reported")
      (`Assoc [ "value", `Float 0.; "unit", `String "ns" ])
  in
  let invalid =
    with_results (replace "metrics" (`Assoc [ "setup_slack", unavailable ]) results)
  in
  require
    (Option.is_none (List.hd_exn invalid.metrics).value)
    "Unconstrained timing displayed zero slack";
  let invalid =
    with_results
      (replace
         "metrics"
         (`Assoc
           [ ( "mapped_cells"
             , `Assoc
                 [ "value", `Float 2.5
                 ; "unit", `String "cells"
                 ; "unavailable_reason", `Null
                 ] )
           ])
         results)
  in
  require
    (Option.is_none (List.hd_exn invalid.metrics).value)
    "Fractional terminal cell count accepted";
  let physical : Asic.Selection.t =
    { flow = "standard"; profile = "balanced"; endpoint = "signoff"; assignments = [] }
  in
  let description =
    `Assoc
      [ "contract", `String "hardcaml-asic.flow-describe"
      ; "schema_version", `Int 1
      ; ( "entry"
        , `Assoc
            [ ( "methodology"
              , `Assoc
                  [ "id", `String "standard"; "endpoints", `List [ `String "signoff" ] ] )
            ; "profiles", `List [ `Assoc [ "id", `String "balanced" ] ]
            ] )
      ; ( "capabilities"
        , `Assoc
            [ "stage_selection", `String "complete-prefix-through-declared-endpoint" ] )
      ]
  in
  Public.validate_physical_selection physical description;
  rejected (fun () ->
    Public.validate_physical_selection { physical with endpoint = "routing" } description);
  rejected (fun () ->
    Public.validate_physical_selection
      { physical with endpoint = "arbitrary" }
      description);
  rejected (fun () ->
    Public.validate_physical_selection
      physical
      (replace "capabilities" (`Assoc []) description))
;;

let evidence_file_fixtures () =
  let%bind directory =
    In_thread.run (fun () -> Filename_unix.temp_dir "asic-evidence-" "")
  in
  let regular = Filename.concat directory "regular" in
  let fifo = Filename.concat directory "fifo" in
  Monitor.protect
    ~finally:(fun () ->
      In_thread.run (fun () ->
        List.iter [ regular; fifo ] ~f:(fun path ->
          if Poly.equal (Sys_unix.file_exists path) `Yes then Core_unix.unlink path);
        Core_unix.rmdir directory))
    (fun () ->
      let%bind () =
        In_thread.run (fun () ->
          Out_channel.write_all regular ~data:"abc\000";
          require
            (String.equal (Evidence_file.read_bounded regular 4) "abc\000")
            "Regular evidence bytes changed";
          require
            (Result.is_error
               (Or_error.try_with (fun () -> Evidence_file.read_bounded regular 3)))
            "Oversized regular evidence accepted";
          Core_unix.mkfifo fifo ~perm:0o600)
      in
      let read =
        In_thread.run (fun () ->
          Or_error.try_with (fun () -> Evidence_file.read_bounded fifo 16))
      in
      match%bind Clock.with_timeout (Time_float.Span.of_sec 2.) read with
      | `Result result ->
        require
          (match result with
           | Error error ->
             String.is_substring
               (Error.to_string_hum error)
               ~substring:"not a regular file"
           | Ok _ -> false)
          "Writerless FIFO was not rejected as nonregular";
        Deferred.unit
      | `Timeout ->
        (* Release a regressed blocking open before failing the fixture, so the test does
           not leave an owned worker waiting forever for a FIFO peer. *)
        let%bind () =
          In_thread.run (fun () ->
            let peer = Core_unix.openfile fifo ~mode:[ O_RDWR; O_NONBLOCK; O_CLOEXEC ] in
            Core_unix.close peer)
        in
        failwith "Evidence FIFO open blocked waiting for a writer")
;;

let finalization_lifecycle ~root ~state_dir ~reference =
  let directory = state_dir ^ "-finalize" in
  let services = ref [] in
  let create () =
    let service = Service.create ~state_dir:directory in
    services := service :: !services;
    service
  in
  let flag name enabled =
    In_thread.run (fun () ->
      let path = Filename.concat root name in
      if enabled then Out_channel.write_all path ~data:"" else Core_unix.unlink path)
  in
  let launches () =
    In_thread.run (fun () ->
      In_channel.read_lines (Filename.concat root "calls")
      |> List.count ~f:(fun line -> String.is_prefix line ~prefix:"[\"finalize\""))
  in
  let value (snapshot : Asic.Snapshot.t) key =
    List.find_exn snapshot.finalizations ~f:(fun f ->
      String.equal f.Asic.Finalization.key key)
  in
  let pending (snapshot : Asic.Snapshot.t) key =
    List.find_exn snapshot.operations ~f:(fun p -> String.equal p.Asic.Pending.key key)
  in
  let rec wait service key predicate remaining =
    require (remaining > 0) ("Finalization state not delivered: " ^ key);
    let%bind snapshot = handle service root Get in
    if predicate (value snapshot key)
    then return snapshot
    else (
      let%bind () = Clock.after (Time_float.Span.of_sec 0.02) in
      wait service key predicate (remaining - 1))
  in
  Monitor.protect
    ~finally:(fun () -> Deferred.List.iter !services ~how:`Sequential ~f:Service.shutdown)
    (fun () ->
      let service = create () in
      let%bind registered = handle service root (Register reference) in
      let run = (List.hd_exn registered.runs).run in
      let%bind loaded = settled service root (Load_summary run) in
      let execution_file = (summary loaded run.id).execution_file in
      let finalize key acceptance =
        Asic.Operation.Finalize { key; run; execution_file; acceptance }
      in
      let%bind before = launches () in
      let%bind wrong_path =
        settled
          service
          root
          (Finalize
             { key = "wrong-execution"
             ; run
             ; execution_file = execution_file ^ ".other"
             ; acceptance = None
             })
      in
      require
        (String.equal (pending wrong_path "finalize:wrong-execution").state "failed")
        "Mismatched selected execution was not a pending-operation failure";
      let%bind () = flag "finalize-resumed" true in
      let%bind resumed = settled service root (finalize "resumed" None) in
      require
        (String.equal (value resumed "resumed").state "failed"
         && Option.is_none (value resumed "resumed").attempt)
        "A resumed physical execution was eligible for finalization";
      let%bind () = flag "finalize-resumed" false in
      let%bind rejected_launches = launches () in
      require (before = rejected_launches) "Ineligible finalization launched a producer";
      let%bind () = flag "finalize-late" true in
      let%bind requests =
        Deferred.all
          [ handle service root (finalize "collection" None)
          ; handle service root (finalize "collection" None)
          ]
      in
      List.iter requests ~f:(fun snapshot ->
        require
          (Option.is_none (value snapshot "collection").attempt)
          "Late allocation fixture was not pending");
      let%bind collected = settled service root Get in
      let collection = value collected "collection" in
      require
        (String.equal collection.state "completed"
         && (not collection.owned)
         && Option.is_some collection.attempt)
        "Collection lifecycle did not complete";
      require
        (String.equal
           (Option.value_exn (summary collected run.id).terminal).attempt
           (Option.value_exn collection.attempt))
        "Collection did not auto-adopt matching terminal result";
      let%bind after = launches () in
      require (after = before + 1) "Concurrent/late retry duplicated finalization";
      let%bind () = flag "finalize-late" false in
      let%bind catalog = settled service root (List_artifacts run) in
      require
        (List.length catalog.artifacts = 1)
        "Adopted terminal artifact catalog missing";
      let artifact = List.hd_exn catalog.artifacts in
      let%bind paged =
        settled
          service
          root
          (Read_artifact { run; artifact_id = artifact.id; offset = 0; limit = 32 })
      in
      let page = List.hd_exn paged.artifact_pages in
      require
        (String.equal page.artifact_id artifact.id
         && Option.is_none page.error
         && (not (String.is_empty page.text))
         && page.next_offset <= 32)
        "Server-authorized artifact page missing";
      (* Distinct clients issue reads before either request is settled. Both offset and
         limit belong to the scheduling/page identity, including equal-offset reads. *)
      let read offset limit =
        Asic.Operation.Read_artifact { run; artifact_id = artifact.id; offset; limit }
      in
      let%bind (_ : Asic.Snapshot.t * Asic.Snapshot.t) =
        Deferred.both (handle service root (read 16 24)) (handle service root (read 0 16))
      in
      let%bind concurrent = settled service root Get in
      let%bind artifact_bytes =
        In_thread.run (fun () -> In_channel.read_all artifact.path)
      in
      List.iter
        [ 0, 32; 16, 24; 0, 16 ]
        ~f:(fun (offset, limit) ->
          let key = Asic_artifact.read_key ~run ~artifact_id:artifact.id ~offset ~limit in
          require
            (String.equal (pending concurrent key).state "completed")
            "Concurrent artifact read was discarded/coalesced with another page";
          let page =
            List.find_exn concurrent.artifact_pages ~f:(fun page ->
              Run_ref.equal page.run run
              && String.equal page.artifact_id artifact.id
              && String.equal page.terminal_attempt artifact.terminal_attempt
              && String.equal page.sha256 artifact.sha256
              && page.offset = offset
              && page.limit = limit)
          in
          require
            (Option.is_none page.error
             && String.equal page.text (String.sub artifact_bytes ~pos:offset ~len:limit)
            )
            "Concurrent artifact read delivered the wrong requested bytes");
      let%bind repeated = settled service root (read 0 16) in
      require
        (List.length repeated.artifact_pages = 3)
        "Repeated artifact read duplicated a complete page identity";
      let%bind () =
        Deferred.List.iter (List.init 10 ~f:Fn.id) ~how:`Sequential ~f:(fun offset ->
          let%map bounded = settled service root (read offset 8) in
          require
            (List.length bounded.artifact_pages <= 8)
            "Artifact page cache exceeded cap")
      in
      let%bind bounded = handle service root Get in
      require
        (List.length bounded.artifact_pages = 8)
        "Artifact page cache did not retain its bounded working set";
      let acceptance : Asic.Acceptance.t =
        { support_tools = root
        ; precheck_python = Filename.concat root "python"
        ; testbench = Filename.concat root "replay.v"
        ; testbench_top = "replay"
        ; replay_trace = Filename.concat root "trace"
        }
      in
      let%bind conflict =
        Service.handle
          service
          ~root
          ~environment
          (finalize "collection" (Some acceptance))
      in
      require (Result.is_error conflict) "Conflicting finalization inputs accepted";
      let%bind failed = settled service root (finalize "acceptance" (Some acceptance)) in
      let failed_value = value failed "acceptance" in
      require
        (String.equal failed_value.state "failed"
         && Option.equal String.equal failed_value.acceptance (Some "fail")
         && Option.is_some failed_value.error
         && String.equal (pending failed "finalize:acceptance").state "failed")
        "Nonzero provider exit lost independent failed acceptance/process outcome";
      let terminal = Option.value_exn (summary failed run.id).terminal in
      require
        (String.equal terminal.acceptance "fail"
         && String.equal terminal.attempt (Option.value_exn failed_value.attempt))
        "Nonzero acceptance results were not auto-imported";
      require
        (List.is_empty failed.artifacts && List.is_empty failed.artifact_pages)
        "Terminal adoption retained a stale artifact catalog/page";
      let%bind stale =
        settled
          service
          root
          (Read_artifact { run; artifact_id = artifact.id; offset = 0; limit = 32 })
      in
      require
        (List.exists stale.operations ~f:(fun p ->
           String.equal p.Asic.Pending.kind "artifact-read"
           && String.equal p.state "failed"))
        "Stale artifact ID was accepted after terminal adoption";
      let%bind () = flag "finalize-no-allocation" true in
      let%bind no_allocation =
        settled service root (finalize "allocation-failure" None)
      in
      require
        (String.equal (value no_allocation "allocation-failure").state "failed"
         && Option.is_none (value no_allocation "allocation-failure").attempt)
        "Allocation failure outcome missing";
      let%bind () = flag "finalize-no-allocation" false in
      let%bind () = Service.shutdown service in
      let restarted = create () in
      let%bind count = launches () in
      let%bind retry = settled restarted root (finalize "allocation-failure" None) in
      require (not (value retry "acceptance").owned) "Restart retained process ownership";
      let%bind (_ : Asic.Snapshot.t) =
        settled restarted root (finalize "collection" None)
      in
      let%bind () = flag "finalize-inspect-fail" true in
      let%bind unavailable_collection =
        settled restarted root (Observe_finalization "collection")
      in
      require
        (Option.is_some (value unavailable_collection "collection").error
         && String.equal
              (pending unavailable_collection "finalize-observe:collection").state
              "failed")
        "Transient observation failure was not surfaced";
      let%bind unavailable_acceptance =
        settled restarted root (Observe_finalization "acceptance")
      in
      require
        (String.is_substring
           (Option.value_exn (value unavailable_acceptance "acceptance").error)
           ~substring:"fixture finalization inspection unavailable")
        "Observation failure did not retain its own diagnostic beside producer failure";
      let%bind () = Service.shutdown restarted in
      let restarted = create () in
      let%bind () = flag "finalize-inspect-fail" false in
      let%bind recovered_collection =
        settled restarted root (Observe_finalization "collection")
      in
      require
        (String.equal (value recovered_collection "collection").state "completed"
         && Option.is_none (value recovered_collection "collection").error
         && String.equal
              (pending recovered_collection "finalize-observe:collection").state
              "completed"
         && String.equal
              (Option.value_exn (summary recovered_collection run.id).terminal).attempt
              (Option.value_exn collection.attempt))
        "Validated reconnect/import retained a transient observation error after restart";
      let%bind observed = settled restarted root (Observe_finalization "acceptance") in
      require
        (String.equal (value observed "acceptance").state "failed"
         && (not (value observed "acceptance").owned)
         && Option.equal
              String.equal
              (value observed "acceptance").error
              failed_value.error
         && String.equal
              (pending observed "finalize-observe:acceptance").state
              "completed")
        "Read-only observation failed to recover exact failed receipt";
      let%bind missing =
        settled restarted root (Observe_finalization "allocation-failure")
      in
      require
        (String.equal
           (pending missing "finalize-observe:allocation-failure").state
           "failed")
        "Missing-reference observation failure was not propagated";
      let%bind unchanged = launches () in
      require (count = unchanged) "Restart/retry/observation relaunched finalization";
      let%bind () = flag "finalize-hold" true in
      let%bind (_ : Asic.Snapshot.t) = handle restarted root (finalize "cancel" None) in
      let%bind early =
        wait
          restarted
          "cancel"
          (fun f -> Option.is_some f.attempt && Option.is_some f.phase && f.owned)
          200
      in
      let attempt = Option.value_exn (value early "cancel").attempt in
      (* A second daemon object models restart: only the persisted reference survives. It
         must not signal the original service's still-owned producer. *)
      let detached = create () in
      let%bind detached_state = handle detached root Get in
      require
        ((not (value detached_state "cancel").owned)
         && String.equal (value detached_state "cancel").state "unknown")
        "Restart invented ownership or completion";
      let%bind historical_cancel =
        Service.handle detached ~root ~environment (Cancel "finalize:cancel")
      in
      require (Result.is_error historical_cancel) "Historical task was cancellable";
      let%bind (_ : Asic.Snapshot.t) =
        handle restarted root (finalize "queued-cancel" None)
      in
      let%bind (_ : Asic.Snapshot.t) =
        handle restarted root (Cancel "finalize:queued-cancel")
      in
      let%bind (_ : Asic.Snapshot.t) = handle restarted root (Cancel "finalize:cancel") in
      let%bind cancelled = settled restarted root Get in
      require
        (String.equal (value cancelled "cancel").state "interrupted"
         && (not (value cancelled "cancel").owned)
         && String.equal (value cancelled "queued-cancel").state "interrupted"
         && String.equal (pending cancelled "finalize:cancel").state "failed")
        "Owned/queued cancellation outcome missing";
      let%bind () =
        In_thread.run (fun () ->
          require
            (Poly.equal
               (Sys_unix.file_exists (Filename.concat attempt "terminated"))
               `Yes)
            "Owned finalize process was not terminated")
      in
      let%bind recovered = settled detached root (Observe_finalization "cancel") in
      require
        (String.equal (value recovered "cancel").state "interrupted"
         && not (value recovered "cancel").owned)
        "Detached read-only observation did not reconcile interruption";
      let%bind () = flag "finalize-hold" false in
      Deferred.unit)
;;

let stage_entry ?(status = "pending") ?(action = `Null) id =
  `Assoc
    [ "id", `String id
    ; "name", `String ("Stage " ^ id)
    ; "status", `String status
    ; "requested", `Bool true
    ; "reason", `String "Explicit provider evidence"
    ; "action", action
    ]
;;

let stage_plan entries =
  `Assoc
    [ "contract", `String "hardcaml-asic.stage-plan"
    ; "schema_version", `Int 1
    ; "stages", `List entries
    ]
;;

let stage_observation ?(cursor = 0) ?(stream = "stage-fixture") ?(plan = `Null) () =
  `Assoc
    [ "contract", `String "hardcaml-asic.stage-observation"
    ; "schema_version", `Int 2
    ; "stream_id", `String stream
    ; "cursor", `Int cursor
    ; "writer_active", `Bool true
    ; "observation_status", `String "active"
    ; "state", `Assoc [ "outcome", `Null ]
    ; "execution_file", `Null
    ; "stage_plan", plan
    ; ( "methodology"
      , `Assoc
          [ "contract", `String "hardcaml-asic.historical-methodology"
          ; "schema_version", `Int 1
          ; "state", `String "pending"
          ; "launch", `Assoc [ "attempt_id", `String stream ]
          ] )
    ]
;;

let replace_field j key value =
  match j with
  | `Assoc fields ->
    `Assoc ((key, value) :: List.Assoc.remove fields key ~equal:String.equal)
  | _ -> assert false
;;

let stage_fixtures () =
  let rejected f =
    require (Result.is_error (Or_error.try_with f)) "Invalid stage plan accepted"
  in
  let action =
    `Assoc
      [ "flow", `String "synthetic"
      ; "profile", `String "success"
      ; "endpoint", `String "placement"
      ; "assignments", `List [ `String "CLOCK_PERIOD=10" ]
      ]
  in
  let statuses : (string * Asic.Stage.Status.t) list =
    [ "pending", Pending
    ; "running", Running
    ; "completed", Completed
    ; "failed", Failed
    ; "skipped", Skipped
    ; "cancelled", Cancelled
    ; "not_requested", Not_requested
    ; "unsupported", Unsupported
    ; "future_state", Unknown "future_state"
    ]
  in
  let entries =
    List.map statuses ~f:(fun (status, _) -> stage_entry ~status ~action status)
  in
  let observation = stage_observation ~plan:(stage_plan entries) () in
  let stages = Public.stage_plan observation in
  require
    (List.is_empty (Public.stage_plan (`Assoc [])))
    "Absent extension fabricated stages";
  require
    (List.equal
       Asic.Stage.Status.equal
       (List.map stages ~f:(fun s -> s.status))
       (List.map statuses ~f:snd))
    "Stage statuses were inferred or lost";
  List.iter stages ~f:(fun stage ->
    require
      (stage.requested
       && Option.equal String.equal stage.reason (Some "Explicit provider evidence")
       && Option.equal
            Asic.Selection.equal
            stage.action
            (Some
               { flow = "synthetic"
               ; profile = "success"
               ; endpoint = "placement"
               ; assignments = [ "CLOCK_PERIOD=10" ]
               }))
      "Stage action/metadata lost");
  let no_action =
    Public.stage_plan
      (stage_observation
         ~plan:
           (stage_plan
              [ replace_field (stage_entry "omitted") "requested" (`Bool false) ])
         ())
    |> List.hd_exn
  in
  require
    ((not no_action.requested) && Option.is_none no_action.action)
    "Unrequested stage acquired an action";
  List.iter
    [ `Null
    ; replace_field (stage_plan entries) "schema_version" (`Int 2)
    ; replace_field (stage_plan entries) "contract" (`String "another.extension")
    ]
    ~f:(fun plan ->
      require
        (List.is_empty (Public.stage_plan (stage_observation ~plan ())))
        "Absent/unsupported extension fabricated stages");
  List.iter
    [ `String "malformed"
    ; `Assoc []
    ; replace_field (stage_plan []) "schema_version" (`String "1")
    ; replace_field (stage_plan []) "stages" `Null
    ; stage_plan [ stage_entry "same"; stage_entry "same" ]
    ; stage_plan [ stage_entry "" ]
    ; stage_plan [ stage_entry "has space" ]
    ; stage_plan [ stage_entry "bad\nidentity" ]
    ; stage_plan [ stage_entry (String.make 257 'x') ]
    ; stage_plan [ stage_entry ~status:"" "empty-status" ]
    ; stage_plan [ stage_entry ~status:(String.make 257 'x') "long-status" ]
    ; stage_plan [ replace_field (stage_entry "a") "requested" (`String "true") ]
    ; stage_plan [ replace_field (stage_entry "a") "name" (`String "") ]
    ; stage_plan [ replace_field (stage_entry "a") "reason" (`Int 1) ]
    ; stage_plan
        [ replace_field (stage_entry "a") "reason" (`String (String.make 4097 'x')) ]
    ; stage_plan [ stage_entry ~action:(`Bool false) "a" ]
    ; stage_plan [ stage_entry ~action:(replace_field action "flow" (`String "")) "a" ]
    ; stage_plan [ stage_entry ~action:(replace_field action "assignments" `Null) "a" ]
    ; stage_plan
        [ stage_entry ~action:(replace_field action "assignments" (`List [ `Int 1 ])) "a"
        ]
    ; stage_plan
        [ stage_entry
            ~action:
              (replace_field
                 action
                 "assignments"
                 (`List (List.init 65 ~f:(fun _ -> `String "X=1"))))
            "a"
        ]
    ; stage_plan (List.init 129 ~f:(fun i -> stage_entry (Int.to_string i)))
    ; stage_plan
        (List.init 128 ~f:(fun i ->
           replace_field
             (stage_entry (Int.to_string i))
             "reason"
             (`String (String.make 4096 'x'))))
    ]
    ~f:(fun plan -> rejected (fun () -> Public.stage_plan (stage_observation ~plan ())));
  rejected (fun () ->
    Public.decode
      "{\"stage_plan\":{\"contract\":\"hardcaml-asic.stage-plan\",\"schema_version\":1,\"stages\":[{\"id\":\"a\",\"id\":\"b\"}]}}");
  let run : Asic.Run.t =
    { run =
        { backend = Backend_id.of_string "asic"
        ; id = "stage-fixture"
        ; build = None
        ; label = None
        }
    ; reference = { attempt = "/public/stage-fixture"; stream_id = "stage-fixture" }
    ; selection = None
    ; cursor = 0
    ; status = "allocated"
    ; execution_file = None
    ; error = None
    ; stages = []
    ; execution_timing = None
    }
  in
  let next, final = Public.inspection run ~cursor:0 observation in
  require
    ((not final) && Option.is_none next.execution_file && List.length next.stages = 9)
    "Stage publication waited for execution evidence";
  let ahead, _ =
    Public.inspection next ~cursor:0 (replace_field observation "cursor" (`Int 1))
  in
  require
    (List.is_empty ahead.stages && ahead.cursor = 0)
    "Ahead-of-updates stage state attached to old cursor";
  let caught_up, _ =
    Public.inspection ahead ~cursor:1 (replace_field observation "cursor" (`Int 1))
  in
  require
    (caught_up.cursor = 1 && List.length caught_up.stages = 9)
    "Caught-up stages were not published";
  rejected (fun () -> Public.inspection caught_up ~cursor:0 observation);
  rejected (fun () -> Public.inspection run ~cursor:1 observation);
  rejected (fun () ->
    Public.inspection
      run
      ~cursor:0
      (replace_field observation "stream_id" (`String "other")));
  let cleared, _ = Public.inspection next ~cursor:0 (stage_observation ()) in
  require (List.is_empty cleared.stages) "Absent extension retained previous actions";
  let unsupported, _ =
    Public.inspection
      next
      ~cursor:0
      (stage_observation
         ~plan:(replace_field (stage_plan entries) "schema_version" (`Int 2))
         ())
  in
  require
    (List.is_empty unsupported.stages)
    "Unsupported extension retained previous actions";
  let completed =
    stage_observation ()
    |> fun j ->
    replace_field j "writer_active" (`Bool false)
    |> fun j ->
    replace_field j "observation_status" (`String "final")
    |> fun j ->
    replace_field
      j
      "state"
      (`Assoc [ "outcome", `Assoc [ "status", `String "completed" ] ])
  in
  let completed, final = Public.inspection next ~cursor:0 completed in
  require
    (final && List.is_empty completed.stages)
    "Aggregate completion fabricated stage success";
  let explicit, _ =
    Public.inspection
      next
      ~cursor:0
      (stage_observation ~plan:(stage_plan [ stage_entry "pending" ]) ()
       |> fun j ->
       replace_field j "writer_active" (`Bool false)
       |> fun j ->
       replace_field j "observation_status" (`String "final")
       |> fun j ->
       replace_field
         j
         "state"
         (`Assoc [ "outcome", `Assoc [ "status", `String "completed" ] ]))
  in
  require
    (Asic.Stage.Status.equal (List.hd_exn explicit.stages).status Pending)
    "Aggregate completion overwrote explicit stage status"
;;

let stage_service_fixtures root state_dir =
  let services = ref [] in
  let create () =
    let service = Service.create ~state_dir:(state_dir ^ "-stages") in
    services := service :: !services;
    service
  in
  let reference stream : Asic.Reference.t =
    { attempt = Filename.concat root stream; stream_id = stream }
  in
  let run stream : Run_ref.t =
    { backend = Backend_id.of_string "asic"; id = stream; build = None; label = None }
  in
  let value (snapshot : Asic.Snapshot.t) stream =
    List.find_exn snapshot.runs ~f:(fun r -> String.equal r.Asic.Run.run.id stream)
  in
  let write stream observation =
    In_thread.run (fun () ->
      let attempt = (reference stream).attempt in
      Core_unix.mkdir_p attempt;
      Out_channel.write_all
        (Filename.concat attempt "observation.json")
        ~data:(Yojson.Safe.to_string observation))
  in
  let first = "stage-fixture"
  and other = "stage-other" in
  let advertised_action =
    `Assoc
      [ "flow", `String "synthetic"
      ; "profile", `String "success"
      ; "endpoint", `String "placement"
      ; "assignments", `List []
      ]
  in
  let observation stream cursor status =
    stage_observation
      ~stream
      ~cursor
      ~plan:(stage_plan [ stage_entry ~status ~action:advertised_action "placement" ])
      ()
  in
  Monitor.protect
    ~finally:(fun () -> Deferred.List.iter !services ~how:`Sequential ~f:Service.shutdown)
    (fun () ->
      let service = create () in
      let%bind (_ : Asic.Snapshot.t) =
        settled service root (Register (reference first))
      in
      let%bind (_ : Asic.Snapshot.t) =
        settled service root (Register (reference other))
      in
      let%bind () = write first (observation first 1 "running") in
      let%bind () = write other (observation other 4 "future_state") in
      let%bind observed = settled service root (Observe (run first)) in
      let first_run = value observed first in
      require
        (first_run.cursor = 1
         && Option.is_none first_run.execution_file
         && String.equal first_run.status "observing"
         && Asic.Stage.Status.equal (List.hd_exn first_run.stages).status Running
         && List.is_empty (value observed other).stages
         && List.is_empty observed.summaries)
        "Observe did not publish pre-execution stages independently of summaries/runs";
      let%bind both = settled service root (Observe (run other)) in
      let other_run = value both other in
      require
        (other_run.cursor = 4
         && Asic.Stage.Status.equal
              (List.hd_exn other_run.stages).status
              (Unknown "future_state")
         && Asic.Run.equal first_run (value both first))
        "Stage observations leaked between registered runs";
      let%bind () = write first (observation first 2 "cancelled") in
      let%bind cancelled = settled service root (Observe (run first)) in
      let cancelled_run = value cancelled first in
      require
        (cancelled_run.cursor = 2
         && Asic.Stage.Status.equal (List.hd_exn cancelled_run.stages).status Cancelled
         && Asic.Run.equal other_run (value cancelled other))
        "Cancelled stage did not replace running stage at its new cursor";
      let%bind () = Service.shutdown service in
      let restarted = create () in
      let%bind restored = handle restarted root Get in
      require
        (Asic.Run.equal cancelled_run (value restored first)
         && Asic.Run.equal other_run (value restored other))
        "Stage state/actions/cursors did not survive registry reopening";
      (* Invalid new evidence cannot partially replace a valid persisted observation. *)
      let malformed =
        stage_observation
          ~stream:first
          ~cursor:3
          ~plan:(stage_plan [ stage_entry "duplicate"; stage_entry "duplicate" ])
          ()
      in
      let%bind () = write first malformed in
      let%bind invalid = settled restarted root (Observe (run first)) in
      require
        (Asic.Run.equal cancelled_run (value invalid first)
         && List.exists invalid.operations ~f:(fun op ->
           String.equal op.Asic.Pending.key ("observe:" ^ first)
           && String.equal op.state "failed"))
        "Malformed stage plan partially committed or lacked an observation error";
      let%bind () = write first (stage_observation ~stream:first ~cursor:3 ()) in
      let%bind absent = settled restarted root (Observe (run first)) in
      require
        ((value absent first).cursor = 3
         && List.is_empty (value absent first).stages
         && Asic.Run.equal other_run (value absent other))
        "Provider without extension retained stale stage actions";
      (* Stage inspection and reopening never start a named flow. The advertised action is
         consumed only by an explicit ordinary Plan request. *)
      let action = Option.value_exn (List.hd_exn cancelled_run.stages).action in
      let%bind planned = settled restarted root (Plan action) in
      require
        (Option.value_map planned.preview ~default:false ~f:(fun preview ->
           Asic.Selection.equal preview.selection action))
        "Stage action could not use existing planning";
      In_thread.run (fun () ->
        require
          (not
             (List.exists
                (In_channel.read_lines (Filename.concat root "calls"))
                ~f:(fun line -> String.is_prefix line ~prefix:"[\"flow\", \"run\"")))
          "Stage observation or planning launched execution"))
;;

let main () =
  let%bind () = evidence_file_fixtures () in
  declared_clock_fixtures ();
  terminal_fixtures ();
  metric_fixtures ();
  stage_fixtures ();
  let rejected f message = require (Result.is_error (Or_error.try_with f)) message in
  rejected
    (fun () -> ignore (Public.decode "{\"cursor\":0,\"cursor\":1}" : Yojson.Safe.t))
    "Duplicate public JSON keys accepted";
  rejected
    (fun () ->
      Public.metadata
        (Public.decode
           "{\"cli_contract\":{\"version\":3,\"capabilities\":{\"namedflow1\":true}}}"))
    "Incompatible provider accepted";
  let%bind root, state_dir =
    In_thread.run (fun () ->
      let root = Filename_unix.temp_dir "workbench-asic-" "" in
      let state_dir = Filename.concat root "cache" in
      let fixture = Filename.concat root "fixture.py" in
      Out_channel.write_all fixture ~data:(In_channel.read_all "fake_provider.py");
      Out_channel.write_all
        (Filename.concat root "production_flow_list.json")
        ~data:(In_channel.read_all "production_flow_list.json");
      Core_unix.chmod fixture ~perm:0o700;
      let config : Config.t =
        { schema_version = 1
        ; project_executable = fixture
        ; provider_executable = fixture
        ; results_root = Filename.concat root "results"
        ; toolchain = root
        ; python = None
        ; support_tools = None
        ; pdk_root = None
        ; stage_timeout_seconds = Some 2
        }
      in
      Out_channel.write_all
        (Filename.concat root Config.filename)
        ~data:(Sexp.to_string (Config.sexp_of_t config));
      Out_channel.write_all
        (Filename.concat root "hardcaml-workbench-preparation.sexp")
        ~data:
          (sprintf
             "((schema_version 1)(build_target fixture.exe)(results_root \
              %s)(timeout_seconds 10))"
             config.results_root);
      root, state_dir)
  in
  let%bind () = stage_service_fixtures root state_dir in
  (* Reaping and repeated cleanup use the same Async Process ownership record. No raw PID
     signalling or independent waitpid is involved. *)
  let%bind exited =
    Process.create_exn
      ~working_dir:root
      ~prog:(Filename.concat root "fixture.py")
      ~args:[ "lifecycle-exit" ]
      ()
  in
  let%bind () =
    Monitor.protect
      ~finally:(fun () ->
        let%bind () = Owned_process.stop exited in
        let%bind () = Writer.close (Process.stdin exited) in
        let%bind () = Reader.close (Process.stdout exited) in
        Reader.close (Process.stderr exited))
      (fun () ->
        let%bind status = Process.wait exited in
        require (Result.is_ok status) "Natural-exit fixture failed";
        let%bind () = Owned_process.stop exited in
        Owned_process.stop exited)
  in
  let%bind () =
    Deferred.List.iter
      [ "lifecycle-wait", "timeout"
      ; "lifecycle-output", "record too large"
      ; "lifecycle-malformed", "Yojson"
      ; "lifecycle-cancel", "cancelled"
      ]
      ~how:`Sequential
      ~f:(fun (mode, expected_error) ->
        let cancel = Ivar.create () in
        let on_line line =
          if String.equal mode "lifecycle-malformed"
          then ignore (Public.decode line : Yojson.Safe.t);
          if String.equal mode "lifecycle-cancel" then Ivar.fill_if_empty cancel ();
          Deferred.unit
        in
        let invocation =
          Adapter.invocation
            ~root
            ~environment
            (Filename.concat root "fixture.py")
            [ mode ]
        in
        let%bind result =
          Monitor.try_with (fun () ->
            Owned_process.run
              ~seconds:(if String.equal mode "lifecycle-wait" then 3. else 10.)
              ~cancel:(Ivar.read cancel)
              ~on_process:ignore
              ~on_line
              invocation)
        in
        (match result with
         | Ok _ -> failwith ("Process failure fixture unexpectedly succeeded: " ^ mode)
         | Error exn ->
           require
             (String.is_substring (Exn.to_string exn) ~substring:expected_error)
             ("Wrong process failure: " ^ Exn.to_string exn));
        In_thread.run (fun () ->
          require
            (Poly.equal
               (Sys_unix.file_exists (Filename.concat root (mode ^ "-terminated")))
               `Yes)
            ("Process failure did not terminate/reap owned fixture: " ^ mode)))
  in
  let services = ref [] in
  let create ?(directory = state_dir) () =
    let service = Service.create ~state_dir:directory in
    attach_preparation service;
    services := service :: !services;
    service
  in
  Monitor.protect
    ~finally:(fun () -> Deferred.List.iter !services ~how:`Sequential ~f:Service.shutdown)
    (fun () ->
      let service = create () in
      let%bind discovered = settled service root Discover in
      require (List.length discovered.flows = 1) "Public discovery failed";
      require
        (List.equal
           String.equal
           (List.hd_exn discovered.flows).fresh_stage_endpoints
           (Public.recipe_stages (`Assoc [ "schema_version", `Int 3 ]))
         && Option.equal
              Asic.Flow_default.equal
              discovered.catalog_default
              (Some { flow = "standard"; profile = "balanced" }))
        "Discovery did not publish exact capabilities/default together";
      let timing_selection = { (selection "balanced") with endpoint = "timing" } in
      let marker name = Filename.concat root name in
      Out_channel.write_all (marker "timing-catalog") ~data:"";
      let%bind unsupported = settled service root Discover in
      require
        (not
           (List.mem
              (List.hd_exn unsupported.flows).fresh_stage_endpoints
              "timing"
              ~equal:String.equal))
        "Catalog alone granted executable Timing";
      let%bind unsupported = settled service root (Plan timing_selection) in
      require
        (Option.is_none unsupported.preview)
        "Legacy provider planned executable Timing";
      Out_channel.write_all (marker "timing-capability") ~data:"";
      let timing_service = create ~directory:(state_dir ^ "-timing") () in
      let%bind discovered = settled timing_service root Discover in
      require
        (List.equal
           String.equal
           (List.hd_exn discovered.flows).fresh_stage_endpoints
           Public.canonical_stages)
        "Executable Timing capability/catalog not discovered";
      let before = In_channel.read_all (marker "calls") in
      let%bind planned = settled timing_service root (Plan timing_selection) in
      let preview = Option.value_exn planned.preview in
      require
        (Asic.Selection.equal preview.selection timing_selection
         && not
              (String.is_substring
                 (String.drop_prefix
                    (In_channel.read_all (marker "calls"))
                    (String.length before))
                 ~substring:"\"run\""))
        "Timing preparation launched execution";
      let%bind executed =
        settled timing_service root (Run { key = "timing-only"; preview })
      in
      let timing_run =
        List.find_exn executed.runs ~f:(fun r ->
          String.equal r.Asic.Run.run.id "stream-balanced-timing")
      in
      let timing =
        List.find_exn timing_run.stages ~f:(fun s -> String.equal s.id "timing")
      in
      let signoff =
        List.find_exn timing_run.stages ~f:(fun s -> String.equal s.id "signoff")
      in
      require
        (List.length timing_run.stages = 7
         && timing.requested
         && Asic.Stage.Status.equal timing.status Completed
         && (not signoff.requested)
         && Asic.Stage.Status.equal signoff.status Not_requested)
        "Standalone timing launch did not stop before Signoff";
      Core_unix.unlink (marker "timing-catalog");
      Core_unix.unlink (marker "timing-capability");
      let%bind prior_reports = reports root in
      let%bind () =
        Deferred.List.iter
          [ "fail-discovery"; "invalid-discovery" ]
          ~how:`Sequential
          ~f:(fun marker ->
            let path = Filename.concat root marker in
            let%bind () = In_thread.run (fun () -> Out_channel.write_all path ~data:"") in
            let%bind pending = handle service root Discover in
            require
              (List.is_empty pending.flows && Option.is_none pending.catalog_default)
              "Pending discovery retained ready mapping";
            let%bind () = Service.completion service in
            let%bind failed = handle service root Get in
            require
              (List.is_empty failed.flows
               && Option.is_none failed.catalog_default
               && List.exists failed.operations ~f:(fun p ->
                 String.equal p.kind "discover" && Option.is_some p.error))
              "Failed discovery retained ready mapping or lost error";
            let%bind () = In_thread.run (fun () -> Core_unix.unlink path) in
            let%map recovered = settled service root Discover in
            require
              (List.length recovered.flows = 1 && Option.is_some recovered.catalog_default)
              "Discovery did not recover coherently after failure")
      in
      let launch profile key =
        let%bind planned = settled service root (Plan (selection profile)) in
        let preview = Option.value_exn planned.preview in
        let%bind reserved = handle service root (Run { key; preview }) in
        require
          (List.exists reserved.workflows ~f:(fun w ->
             String.equal w.key key
             && Option.equal
                  String.equal
                  w.intent.expected_plan_identity
                  (Some preview.plan_identity)))
          "Acknowledged launch lost exact durable fresh expectation/key";
        let%bind (_ : Asic.Snapshot.t) = handle service root (Run { key; preview }) in
        let rec allocation tries =
          require (tries > 0) "Early allocation not delivered";
          let%bind snapshot = handle service root Get in
          if List.exists snapshot.runs ~f:(fun r ->
               String.equal r.Asic.Run.run.id ("stream-" ^ profile))
             && List.exists snapshot.launches ~f:(fun l ->
               String.equal l.Asic.Launch.key key
               && Option.equal String.equal l.run_id (Some ("stream-" ^ profile)))
          then return snapshot
          else (
            let%bind () = Clock.after (Time_float.Span.of_sec 0.01) in
            allocation (tries - 1))
        in
        let%bind early = allocation 40 in
        let r : Asic.Run.t =
          List.find_exn early.runs ~f:(fun r ->
            String.equal r.Asic.Run.run.id ("stream-" ^ profile))
        in
        require (Option.is_none r.execution_file) "Allocation was not early";
        require
          (List.exists early.launches ~f:(fun l ->
             String.equal l.key key
             && Asic.Preview.equal l.preview preview
             && Option.equal String.equal l.run_id (Some r.run.id)))
          "Early allocation lost durable launch/run association";
        let%bind () = Service.completion service in
        handle service root Get
      in
      let%bind first = launch "balanced" "one" in
      require
        (List.exists first.runs ~f:(fun r ->
           String.equal r.Asic.Run.run.id "stream-balanced"
           && String.equal r.status "completed"
           && Option.is_none r.error)
         && List.exists first.operations ~f:(fun op ->
           String.equal op.Asic.Pending.key "observe:stream-balanced"
           && String.equal op.state "completed"))
        "Successful EOF did not retain completed observation";
      require
        (Option.equal Int.equal (summary first "stream-balanced").cell_count (Some 50))
        "R1 count";
      let first_metrics = (summary first "stream-balanced").metrics in
      require (List.length first_metrics = 4) "Synthesis metrics missing";
      require
        (String.equal (summary first "stream-balanced").acceptance "not_evaluated"
         && List.is_empty (summary first "stream-balanced").timing)
        "Metrics invented acceptance/timing";
      let%bind second = launch "synth_delay" "two" in
      require
        (List.equal
           String.equal
           (List.map second.launches ~f:(fun l -> l.key))
           [ "two"; "one" ])
        "Launch projection is not newest reservation order";
      require
        (Option.equal
           Int.equal
           (summary second "stream-synth_delay").cell_count
           (Some 73))
        "R2 count";
      let%bind initial_reports = reports root in
      require (initial_reports = prior_reports + 2) "Duplicate launch/materialization";
      let run id : Run_ref.t =
        let r : Asic.Run.t =
          List.find_exn second.runs ~f:(fun r -> String.equal r.Asic.Run.run.id id)
        in
        r.run
      in
      let r1 = run "stream-balanced"
      and r2 = run "stream-synth_delay" in
      let%bind (_ : Asic.Snapshot.t) = settled service root (Load_summary r1) in
      let%bind (_ : Asic.Snapshot.t) = settled service root (Load_summary r2) in
      let%bind (_ : Asic.Snapshot.t) = handle service root (Load_summary r1) in
      let%bind (_ : Asic.Snapshot.t) = handle service root (Load_summary r1) in
      let%bind () = Service.completion service in
      let%bind warm_reports = reports root in
      require (warm_reports = initial_reports) "Warm switch queried provider report";
      let%bind () = Service.shutdown service in
      let restarted = create () in
      let%bind restored = settled restarted root (Load_summary r1) in
      require
        (List.is_empty restored.flows && Option.is_none restored.catalog_default)
        "Restart implicitly restored/discovered catalog capabilities";
      let%bind rediscovered = settled restarted root Discover in
      require
        (List.length rediscovered.flows = 1 && Option.is_some rediscovered.catalog_default)
        "Explicit discovery after restart failed";
      require
        (List.equal Asic.Launch.equal second.launches restored.launches)
        "Restart changed exact durable launch attribution/order";
      require
        (Asic.Summary.Freshness.equal
           (summary restored r1.id).freshness
           Cached_unverified)
        "L2 incorrectly claims source validation";
      require
        (List.equal Asic.Metric.equal (summary restored r1.id).metrics first_metrics)
        "New metric projection lost on cache reopening";
      let%bind restart_reports = reports root in
      require (restart_reports = initial_reports) "L2 rematerialized report";
      let%bind () =
        In_thread.run (fun () ->
          Out_channel.write_all (Filename.concat root "revision") ~data:"")
      in
      let%bind revised = settled restarted root (Refresh r1) in
      require
        (Option.equal Int.equal (summary revised r1.id).cell_count (Some 51))
        "Revision did not refresh";
      let%bind (_ : Asic.Snapshot.t) = settled restarted root (Load_summary r2) in
      let%bind () =
        In_thread.run (fun () ->
          Out_channel.write_all (Filename.concat root "missing") ~data:"")
      in
      let%bind missing = settled restarted root (Refresh r1) in
      require
        (Asic.Summary.Freshness.equal (summary missing r1.id).freshness Missing_source)
        "Missing source not explicit";
      require
        (Option.equal Int.equal (summary missing r2.id).cell_count (Some 73))
        "Refresh affected another run";
      let%bind () = Service.shutdown restarted in
      let%bind () =
        In_thread.run (fun () ->
          Core_unix.unlink (Filename.concat root "missing");
          List.iter (Sys_unix.ls_dir state_dir) ~f:(fun name ->
            if String.is_suffix name ~suffix:".summary.sexp"
            then downgrade_summary_blob (Filename.concat state_dir name)))
      in
      let legacy = create () in
      let%bind before_legacy = reports root in
      let%bind old = settled legacy root (Load_summary r1) in
      require
        (List.is_empty (summary old r1.id).metrics
         && Option.equal Int.equal (summary old r1.id).cell_count (Some 51)
         && Asic.Summary.Freshness.equal (summary old r1.id).freshness Cached_unverified)
        "Old L2 did not reopen with explicitly absent metrics";
      let%bind after_legacy = reports root in
      require (before_legacy = after_legacy) "Old L2 implicitly queried provider";
      let%bind upgraded = settled legacy root (Refresh r1) in
      require
        (List.length (summary upgraded r1.id).metrics = 4)
        "Explicit refresh did not upgrade old projection";
      let%bind () = Service.shutdown legacy in
      let%bind () =
        In_thread.run (fun () ->
          List.iter (Sys_unix.ls_dir state_dir) ~f:(fun name ->
            if String.is_suffix name ~suffix:".summary.sexp"
            then downgrade_summary_blob ~version:2 (Filename.concat state_dir name)))
      in
      let v2 = create () in
      let%bind before_v2 = reports root in
      let%bind old_v2 = settled v2 root (Load_summary r1) in
      require
        (List.length (summary old_v2 r1.id).metrics = 4
         && Option.is_none (summary old_v2 r1.id).terminal)
        "v2 projection did not reopen without terminal evidence";
      let%bind after_v2 = reports root in
      require (before_v2 = after_v2) "v2 cache implicitly queried provider";
      let terminal_attempt = Filename.concat root "terminal-operation" in
      let physical_attempt = Filename.concat root "attempt-terminal" in
      let%bind () =
        In_thread.run (fun () ->
          Core_unix.mkdir_p physical_attempt ~perm:0o700;
          Core_unix.mkdir_p terminal_attempt ~perm:0o700;
          Out_channel.write_all (Filename.concat physical_attempt "done") ~data:"")
      in
      let%bind registered =
        handle
          v2
          root
          (Register { attempt = physical_attempt; stream_id = "stream-terminal" })
      in
      let physical_run =
        (List.find_exn registered.runs ~f:(fun r ->
           String.equal r.Asic.Run.run.id "stream-terminal"))
          .run
      in
      let%bind physical = settled v2 root (Load_summary physical_run) in
      let physical = summary physical physical_run.id in
      let%bind () =
        finalization_lifecycle
          ~root
          ~state_dir
          ~reference:
            { Asic.Reference.attempt = physical_attempt; stream_id = "stream-terminal" }
      in
      require
        (Option.equal Int.equal physical.cell_count (Some 74)
         && Poly.equal
              (Public.field
                 "boundary"
                 (Public.field "reference" (Public.decode physical.producer)))
              (`String "synthesis"))
        "Completed physical run projected final cells as synthesis";
      let%bind () =
        In_thread.run (fun () ->
          let execution_file = physical.execution_file in
          let execution_bytes = In_channel.read_all execution_file in
          let references =
            Public.list (Public.field "artifacts" (Public.decode execution_bytes))
          in
          let receipt, results_bytes =
            terminal_fixture
              ~attempt:terminal_attempt
              ~execution_file
              ~execution_bytes
              ~references
          in
          Out_channel.write_all (Public.terminal_results_file receipt) ~data:results_bytes;
          Out_channel.write_all
            (Filename.concat terminal_attempt "operation.json")
            ~data:(Yojson.Safe.to_string receipt))
      in
      let%bind adopted =
        settled
          v2
          root
          (Inspect_finalization { run = physical_run; attempt = terminal_attempt })
      in
      let adopted = summary adopted physical_run.id in
      let terminal = Option.value_exn adopted.terminal in
      require
        (Option.equal
           Float.equal
           (List.find_exn terminal.metrics ~f:(fun m ->
              String.equal m.Asic.Metric.key Public.declared_clock_key))
             .value
           (Some 20.))
        "Terminal adoption omitted historical declared clock";
      require
        (String.equal adopted.acceptance "not_evaluated"
         && String.equal terminal.acceptance "fail"
         && List.equal Asic.Metric.equal physical.metrics adopted.metrics)
        "Terminal adoption overwrote stage evidence";
      let%bind () = Service.shutdown v2 in
      let%bind () =
        In_thread.run (fun () ->
          List.iter (Sys_unix.ls_dir state_dir) ~f:(fun name ->
            if String.is_suffix name ~suffix:".summary.sexp"
            then
              legacy_physical_blob
                (Filename.concat state_dir name)
                ~run_id:physical_run.id))
      in
      let combined = create () in
      let%bind before_combined = reports root in
      let%bind cached = settled combined root (Load_summary physical_run) in
      require
        (Option.equal
           Asic.Terminal_result.equal
           (summary cached physical_run.id).terminal
           (Some terminal))
        "Terminal evidence lost after reopening";
      let legacy = summary cached physical_run.id in
      require
        (Option.is_none legacy.cell_count
         && List.is_empty legacy.cells
         && List.is_empty legacy.metrics)
        "Legacy routing projection reopened as synthesis";
      let%bind after_combined = reports root in
      require (before_combined = after_combined) "Combined cache queried provider";
      let%bind refreshed = settled combined root (Refresh physical_run) in
      require
        (Option.equal
           Asic.Terminal_result.equal
           (summary refreshed physical_run.id).terminal
           (Some terminal))
        "Refresh lost persisted finalization reference";
      require
        (List.equal
           Asic.Metric.equal
           (summary refreshed physical_run.id).metrics
           physical.metrics
         && Option.equal
              Int.equal
              (summary refreshed physical_run.id).cell_count
              physical.cell_count)
        "Refresh did not recover explicit synthesis evidence from legacy cache";
      let clock_snapshot = Filename.concat physical_attempt "methodology-plan.json" in
      let%bind clock_bytes =
        In_thread.run (fun () ->
          let bytes = In_channel.read_all clock_snapshot in
          Out_channel.write_all clock_snapshot ~data:(bytes ^ " ");
          bytes)
      in
      let%bind rejected_clock = settled combined root (Refresh physical_run) in
      let rejected_clock = summary rejected_clock physical_run.id in
      require
        (Option.equal Asic.Terminal_result.equal rejected_clock.terminal (Some terminal)
         &&
         match rejected_clock.freshness with
         | Refresh_failed _ -> true
         | _ -> false)
        "Tampered historical clock replaced prior terminal evidence without failure label";
      let%bind () =
        In_thread.run (fun () -> Out_channel.write_all clock_snapshot ~data:clock_bytes)
      in
      let%bind () = Service.shutdown combined in
      (* Corrupt derived entries rebuild only through the explicit public references. *)
      let%bind () =
        In_thread.run (fun () ->
          List.iter (Sys_unix.ls_dir state_dir) ~f:(fun name ->
            if String.is_suffix name ~suffix:".summary.sexp"
            then Out_channel.write_all (Filename.concat state_dir name) ~data:"partial("))
      in
      let recovered = create () in
      let%bind before_cold = reports root in
      let%bind (_ : Asic.Snapshot.t) = handle recovered root (Load_summary r1) in
      let%bind (_ : Asic.Snapshot.t) = handle recovered root (Load_summary r1) in
      let%bind () = Service.completion recovered in
      let%bind rebuilt = handle recovered root Get in
      require
        (Option.equal Int.equal (summary rebuilt r1.id).cell_count (Some 51))
        "Corrupt L2 did not rebuild";
      let%bind after_cold = reports root in
      require (after_cold = before_cold + 1) "Concurrent cold reads were not coalesced";
      (* Drive the actual public registration/read path past the L1 working-set budget. *)
      let%bind () =
        Deferred.List.iter (List.init 34 ~f:Fn.id) ~how:`Sequential ~f:(fun index ->
          let profile = "extra-" ^ Int.to_string index in
          let attempt = Filename.concat root ("attempt-" ^ profile) in
          let%bind () =
            In_thread.run (fun () ->
              Core_unix.mkdir_p attempt ~perm:0o700;
              Out_channel.write_all (Filename.concat attempt "done") ~data:"")
          in
          let%bind registered =
            handle recovered root (Register { attempt; stream_id = "stream-" ^ profile })
          in
          let registered_run : Asic.Run.t =
            List.find_exn registered.runs ~f:(fun r ->
              String.equal r.Asic.Run.run.id ("stream-" ^ profile))
          in
          let run : Run_ref.t = registered_run.run in
          let%map loaded = settled recovered root (Load_summary run) in
          require (List.length loaded.summaries <= 32) "L1 exceeded entry budget")
      in
      let%bind before_evicted = reports root in
      let%bind reloaded = settled recovered root (Load_summary r1) in
      require
        (Option.equal Int.equal (summary reloaded r1.id).cell_count (Some 51))
        "Evicted run loaded wrong summary";
      let%bind after_evicted = reports root in
      require (before_evicted = after_evicted) "L1 eviction failed to reuse L2";
      (* Both overlapping requests must see a failed reservation, not one error and one
         apparent success. A normal file obstructing mkdir makes the write fail without
         modifying provider evidence or adding a persistence injection API. *)
      let reservation_dir = Filename.concat root "reservation-cache" in
      let reserving = create ~directory:reservation_dir () in
      let%bind planned = settled reserving root (Plan (selection "reservation")) in
      let preview = Option.value_exn planned.preview in
      let request = Asic.Operation.Run { key = "retry"; preview } in
      let%bind () =
        In_thread.run (fun () -> Out_channel.write_all reservation_dir ~data:"blocked")
      in
      let first = Service.handle reserving ~root ~environment request in
      let second = Service.handle reserving ~root ~environment request in
      let%bind first, second = Deferred.both first second in
      (match first, second with
       | Error a, Error b ->
         (* Async may add a different caller backtrace to each shared exception. *)
         require
           (V1.Error.Kind.equal a.kind b.kind
            && (not (String.is_empty a.message))
            && not (String.is_empty b.message))
           "Duplicate reservations did not both receive the write failure"
       | _ -> failwith "Failed reservation was acknowledged as successful");
      let%bind failed = handle reserving root Get in
      require
        (not
           (List.exists failed.operations ~f:(fun op ->
              String.equal op.Asic.Pending.key "run:retry")))
        "Failed reservation poisoned submission key";
      let%bind before_retry = launches root "reservation" in
      require (before_retry = 0) "Failed reservation launched provider";
      let%bind () = In_thread.run (fun () -> Core_unix.unlink reservation_dir) in
      let first = handle reserving root request in
      let second = handle reserving root request in
      let%bind (_ : Asic.Snapshot.t * Asic.Snapshot.t) = Deferred.both first second in
      let%bind () = Service.completion reserving in
      let%bind after_retry = launches root "reservation" in
      require (after_retry = 1) "Transient reservation retry did not launch exactly once";
      let%bind () = Service.shutdown reserving in
      let reopened = create ~directory:reservation_dir () in
      let%bind (_ : Asic.Snapshot.t) = settled reopened root request in
      let%bind after_reopen = launches root "reservation" in
      require (after_reopen = 1) "Committed reservation lost deduplication on restart";
      let%bind () = Service.shutdown reopened in
      (* Cancel only a daemon-owned launcher, including its automatic reader. *)
      let%bind () =
        In_thread.run (fun () ->
          Out_channel.write_all (Filename.concat root "hold") ~data:"")
      in
      let%bind planned = settled recovered root (Plan (selection "cancel")) in
      let%bind (_ : Asic.Snapshot.t) =
        handle
          recovered
          root
          (Run { key = "cancel"; preview = Option.value_exn planned.preview })
      in
      let rec wait_allocation attempts =
        require (attempts > 0) "Cancellation fixture allocation missing";
        let%bind snapshot = handle recovered root Get in
        if List.exists snapshot.runs ~f:(fun r ->
             String.equal r.Asic.Run.run.id "stream-cancel")
        then Deferred.unit
        else (
          let%bind () = Clock.after (Time_float.Span.of_sec 0.01) in
          wait_allocation (attempts - 1))
      in
      let%bind () = wait_allocation 100 in
      let%bind (_ : Asic.Snapshot.t) = handle recovered root (Cancel "run:cancel") in
      let%bind () = Service.completion recovered in
      let%bind cancelled = handle recovered root Get in
      require
        (List.exists cancelled.runs ~f:(fun r ->
           String.equal r.Asic.Run.run.id "stream-cancel"
           && String.equal r.status "observation_unavailable"
           && Option.is_some r.error))
        "Cancellation without provider terminal records retained stale observation";
      require
        (List.exists cancelled.operations ~f:(fun op ->
           String.equal op.Asic.Pending.key "run:cancel" && String.equal op.state "failed"))
        "Owned launcher cancellation was not recorded";
      let%bind () =
        In_thread.run (fun () ->
          require
            (Poly.equal
               (Sys_unix.file_exists (Filename.concat root "attempt-cancel/terminated"))
               `Yes)
            "Cancellation did not await owned launcher SIGTERM/reaping";
          require
            (Poly.equal
               (Sys_unix.file_exists (Filename.concat root "attempt-cancel/done"))
               `No)
            "Cancelled launcher completed unexpectedly";
          List.iter [ "balanced"; "synth_delay" ] ~f:(fun profile ->
            require
              (Poly.equal
                 (Sys_unix.file_exists
                    (Filename.concat root ("attempt-" ^ profile ^ "/terminated")))
                 `No)
              "Natural completion was signalled"))
      in
      let%bind () = Service.shutdown recovered in
      let race_service = create () in
      let%bind () =
        Deferred.List.iter
          [ "exit-race"; "exit-race-unavailable"; "exit-race-active" ]
          ~how:`Sequential
          ~f:(fun profile ->
            let%bind planned = settled race_service root (Plan (selection profile)) in
            let preview = Option.value_exn planned.preview in
            let%bind raced = settled race_service root (Run { key = profile; preview }) in
            let run =
              List.find_exn raced.runs ~f:(fun r ->
                String.equal r.Asic.Run.run.id ("stream-" ^ profile))
            in
            let operation key =
              List.find_exn raced.operations ~f:(fun op ->
                String.equal op.Asic.Pending.key key)
            in
            require
              (String.equal (operation ("run:" ^ profile)).state "failed"
               && Option.is_some (operation ("run:" ^ profile)).error)
              "Final reconciliation erased producer failure";
            if String.equal profile "exit-race"
            then
              require
                (String.equal run.status "failed"
                 && run.cursor = 2
                 && Asic.Stage.Status.equal (List.hd_exn run.stages).status Failed
                 && Option.is_none run.error
                 && String.equal (operation ("observe:" ^ run.run.id)).state "completed")
                "Nonzero EOF discarded terminal records while observation was in flight"
            else
              require
                (String.equal run.status "observation_unavailable"
                 && Option.is_some run.error
                 && (not (List.is_empty run.stages))
                 && List.for_all run.stages ~f:(fun stage ->
                   match stage.status with
                   | Running | Pending -> false
                   | _ -> true))
                "Unavailable final observation retained stale active stages";
            let%bind before = launches root profile in
            let%bind (_ : Asic.Snapshot.t) =
              settled race_service root (Run { key = profile; preview })
            in
            let%bind after = launches root profile in
            require (before = 1 && after = before) "Failed run retry relaunched producer";
            (* Refresh reads retained provider truth, even after the automatic reader
               failed. No process execution is needed to repair a historical run. *)
            let%bind () =
              In_thread.run (fun () ->
                Out_channel.write_all (Filename.concat root "race-recover") ~data:"")
            in
            let%bind refreshed = settled race_service root (Refresh run.run) in
            let repaired =
              List.find_exn refreshed.runs ~f:(fun r ->
                Run_ref.equal r.Asic.Run.run run.run)
            in
            require
              (String.equal repaired.status "failed"
               && repaired.cursor = 2
               && Asic.Stage.Status.equal (List.hd_exn repaired.stages).status Failed
               && Option.is_none repaired.error)
              "Read-only Refresh did not repair stale failed run";
            let%bind after_refresh = launches root profile in
            require (after_refresh = before) "Refresh launched a producer";
            In_thread.run (fun () ->
              Core_unix.unlink (Filename.concat root "race-recover")))
      in
      let%bind () = Service.shutdown race_service in
      Out_channel.write_all (Filename.concat root "seven-stage-finalization") ~data:"";
      let seven = create ~directory:(state_dir ^ "-seven-finalization") () in
      let%bind registered =
        handle
          seven
          root
          (Register { attempt = physical_attempt; stream_id = "stream-terminal" })
      in
      let run = (List.hd_exn registered.runs).run in
      let%bind loaded = settled seven root (Load_summary run) in
      let execution_file = (summary loaded run.id).execution_file in
      let%bind finalized =
        settled
          seven
          root
          (Finalize { key = "seven-stage"; run; execution_file; acceptance = None })
      in
      let result =
        List.find_exn finalized.finalizations ~f:(fun f ->
          String.equal f.Asic.Finalization.key "seven-stage")
      in
      require
        (String.equal result.state "completed" && Option.is_some result.attempt)
        "Seven-stage finalization failed eligibility/hydration";
      require
        (String.equal
           (Option.value_exn (summary finalized run.id).terminal).physical_completion
           "full")
        "Seven-stage finalized terminal result did not hydrate";
      Deferred.unit)
;;

let () =
  Command.async
    ~summary:"FS0 public ASIC adapter and summary cache fixtures"
    (Command.Param.return main)
  |> Command_unix.run
;;
