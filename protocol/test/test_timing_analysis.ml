open! Core
open Hardcaml_workbench_protocol

module Legacy_summary = struct
  type t =
    { run : Run_ref.t
    ; source_digest : string
    ; execution_file : string
    ; plan_identity : string option
    ; cell_count : int option
    ; cells : (string * int) list
    ; metrics : Asic.Metric.t list
    ; terminal : Asic.Terminal_result.t option
    ; timing : (string * float * string) list
    ; completion : string
    ; acceptance : string
    ; producer : string
    ; observed_at : string
    ; freshness : Asic.Summary.Freshness.t
    }
  [@@deriving sexp]
end

let%test_unit "supplementary analysis negotiates populated fields for strict old readers" =
  let run : Run_ref.t =
    { backend = Backend_id.of_string "asic"; id = "r"; build = None; label = None }
  in
  let target : Asic_inspection.Analysis_target.t =
    { attempt_id = "r"
    ; occurrence_id = "r/implementation.signoff"
    ; analysis_id = "r/post-pnr-sta"
    ; source_digest = String.make 64 'a'
    ; execution_sha256 = String.make 64 'b'
    ; stage = "signoff"
    ; execution_file = None
    }
  in
  let analysis : Asic.Timing_analysis.t =
    { target
    ; status = Completed
    ; reason = None
    ; duration =
        Some
          { seconds = 0.
          ; basis = "librelane_step_wall_clock"
          ; precision_seconds = 0.001
          ; source = "{}"
          }
    ; enclosing_status = "failed"
    ; producer = Some "{}"
    ; corners = []
    ; metrics = []
    ; timing_goal = Unknown
    ; evidence = "{}"
    }
  in
  let summary : Asic.Summary.t =
    { run
    ; source_digest = "summary"
    ; execution_file = "/execution.json"
    ; plan_identity = None
    ; cell_count = None
    ; cells = []
    ; metrics = []
    ; terminal = None
    ; timing_analysis = Some analysis
    ; timing = []
    ; completion = "failed"
    ; acceptance = "not_evaluated"
    ; producer = "STA"
    ; observed_at = "now"
    ; freshness = Cached_unverified
    }
  in
  let index : Asic_inspection.Index.t =
    { run
    ; execution_file = summary.execution_file
    ; execution_sha256 = target.execution_sha256
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = String.make 64 'c'
    ; rows = []
    ; diagnostics = []
    ; truncated = false
    ; cached_unverified = true
    ; analysis = Some target
    ; times = Evidence_time.Index.empty
    }
  in
  let snapshot : Asic.Snapshot.t =
    { configured = true
    ; flows = []
    ; catalog_default = None
    ; description_json = None
    ; preview = None
    ; runs = []
    ; operations = []
    ; launches = []
    ; summaries = [ summary ]
    ; finalizations = []
    ; artifacts = []
    ; artifact_pages = []
    ; artifact_byte_pages = []
    ; inspections = [ index ]
    ; inspection_details = []
    ; cache_error = None
    ; fresh_intent = None
    ; workflows = []
    ; resources = None
    ; workloads = None
    }
  in
  let old_target = Asic_inspection.Analysis_target.sexp_of_t target in
  assert (not (String.is_substring (Sexp.to_string_mach old_target) ~substring:"stage"));
  assert (
    Asic_inspection.Analysis_target.equal
      target
      (Asic_inspection.Analysis_target.t_of_sexp old_target));
  let timing_target =
    { target with
      stage = "timing"
    ; occurrence_id = "r/implementation.timing"
    ; execution_file = Some "/execution.json.timing-source"
    }
  in
  assert (
    not
      (String.equal
         (Asic_inspection.analysis_index_key ~run ~target)
         (Asic_inspection.analysis_index_key ~run ~target:timing_target)));
  let executable_snapshot =
    { snapshot with
      summaries =
        [ { summary with timing_analysis = Some { analysis with target = timing_target } }
        ]
    ; inspections = [ { index with stage = "timing"; analysis = Some timing_target } ]
    }
  in
  List.iter [ None; Some "1"; Some "2" ] ~f:(fun header ->
    let response =
      Asic.Evidence_metadata.sexp_of_response
        ~timing_analysis_header_value:header
        ~header_value:(Some "1")
        (Ok executable_snapshot)
      |> Asic.Response.t_of_sexp
      |> Result.ok
      |> Option.value_exn
    in
    let expected = Option.equal String.equal header (Some "2") in
    assert (
      Bool.equal
        expected
        (Option.is_some (List.hd_exn response.summaries).timing_analysis));
    assert (
      Bool.equal expected (Option.is_some (List.hd_exn response.inspections).analysis)));
  List.iter [ None; Some ""; Some "0"; Some "2"; Some "1" ] ~f:(fun header ->
    let wire =
      Asic.Evidence_metadata.sexp_of_response
        ~timing_analysis_header_value:header
        ~header_value:(Some "1")
        (Ok snapshot)
    in
    let decoded = Asic.Response.t_of_sexp wire |> Result.ok |> Option.value_exn in
    let expected =
      List.mem [ Some "1"; Some "2" ] header ~equal:(Option.equal String.equal)
    in
    assert (
      Bool.equal (Option.is_some (List.hd_exn decoded.summaries).timing_analysis) expected);
    assert (
      Bool.equal (Option.is_some (List.hd_exn decoded.inspections).analysis) expected);
    if not expected
    then (
      ignore
        (Legacy_summary.t_of_sexp (Asic.Summary.sexp_of_t (List.hd_exn decoded.summaries))
         : Legacy_summary.t);
      ignore
        (Test_asic_inspection.Legacy_index.t_of_sexp
           (Asic_inspection.Index.sexp_of_t (List.hd_exn decoded.inspections))
         : Test_asic_inspection.Legacy_index.t)));
  assert (
    Result.is_error
      (Or_error.try_with (fun () ->
         Legacy_summary.t_of_sexp (Asic.Summary.sexp_of_t summary))));
  let legacy =
    Legacy_summary.t_of_sexp
      (Asic.Summary.sexp_of_t { summary with timing_analysis = None })
  in
  assert (
    Option.is_none
      (Asic.Summary.t_of_sexp (Legacy_summary.sexp_of_t legacy)).timing_analysis);
  List.iter
    [ Asic.Operation.Inspect_analysis { run; target; refresh = false }
    ; Inspect_analysis { run; target; refresh = true }
    ; Inspect_analysis_detail
        { run; target; source_digest = index.source_digest; row_id = "path" }
    ]
    ~f:
      (Test_asic_inspection.round_trip
         Asic.Operation.equal
         Asic.Operation.sexp_of_t
         Asic.Operation.t_of_sexp
         Asic.Operation.bin_size_t
         Asic.Operation.bin_write_t
         Asic.Operation.bin_read_t);
  Test_asic_inspection.round_trip
    Asic.Timing_analysis.equal
    Asic.Timing_analysis.sexp_of_t
    Asic.Timing_analysis.t_of_sexp
    Asic.Timing_analysis.bin_size_t
    Asic.Timing_analysis.bin_write_t
    Asic.Timing_analysis.bin_read_t
    analysis;
  assert (
    not
      (String.equal
         (Asic_inspection.analysis_index_key ~run ~target)
         (Asic_inspection.analysis_index_key
            ~run
            ~target:{ target with source_digest = String.make 64 'd' })))
;;
