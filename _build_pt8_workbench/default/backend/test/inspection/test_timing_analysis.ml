open! Core
open! Async
open Hardcaml_workbench_protocol
module Backend = Hardcaml_workbench_backend
module Public = Backend.Asic_public
module Parser = Backend.Asic_timing_analysis
module Service = Backend.Asic_service
module Inspection = Backend.Asic_inspection
module Config = Hardcaml_workbench_project_integration.Asic_config
module Timing = Asic.Timing_analysis

let require condition message = if not condition then failwith message
let str s = `String s
let obj fields = `Assoc fields
let hash = String.make 64 'a'
let analysis_digest = String.make 64 'c'
let index_digest = String.make 64 'b'

let replace j key value =
  match j with
  | `Assoc fields -> obj ((key, value) :: List.Assoc.remove fields key ~equal:String.equal)
  | _ -> assert false
;;

let rejects f =
  require (Result.is_error (Or_error.try_with f)) "Expected timing rejection"
;;

let run : Run_ref.t =
  { backend = Backend_id.of_string "asic"; id = "run-1"; build = None; label = None }
;;

let environment = V1.Environment_selection.Inherit_daemon

let fixture root execution_file execution_sha256 =
  let directory = Filename.concat root "producer" in
  let source suffix =
    obj [ "path", str (Filename.concat directory suffix); "sha256", str hash ]
  in
  let metric key raw_key value unit_ line =
    obj
      [ "key", str key
      ; "raw_key", str (raw_key ^ "__corner:slow")
      ; "corner", str "slow"
      ; "availability", str "available"
      ; "value", `Float value
      ; "unit", str unit_
      ; "reason", `Null
      ; ( "source"
        , obj
            [ "file", source "slow/sta.log"
            ; "state", source "state_out.json"
            ; "line", `Int line
            ] )
      ; ( "units_source"
        , if String.equal unit_ "ns" then source "slow/generated.lib" else `Null )
      ]
  in
  obj
    [ "contract", str "hardcaml-asic.timing-analysis"
    ; "schema_version", `Int 1
    ; "analysis_id", str "run-1/post-pnr-sta"
    ; "attempt_id", str run.id
    ; "occurrence_id", str "run-1/implementation.signoff"
    ; "stage", str "signoff"
    ; "execution_file", str execution_file
    ; "execution_sha256", str execution_sha256
    ; "source_digest", str analysis_digest
    ; "status", str "completed"
    ; "reason", `Null
    ; "enclosing_status", str "failed"
    ; "evidence_scope", str "terminal_supplementary_not_checkpoint"
    ; "native_grammar", str "librelane-3.1.0.dev3-step-output-runtime-v1"
    ; ( "duration"
      , obj
          [ "seconds", `Float 0.
          ; "precision_seconds", `Float 0.001
          ; "basis", str "librelane_step_wall_clock"
          ; "source", source "runtime.txt"
          ] )
    ; ( "producer"
      , obj
          [ "class_id", str "OpenROAD.STAPostPNR"
          ; "directory", str directory
          ; "config", source "config.json"
          ] )
    ; ( "inventory"
      , `List
          (List.map
             [ "config.json"
             ; "runtime.txt"
             ; "state_out.json"
             ; "slow/sta.log"
             ; "slow/generated.lib"
             ]
             ~f:source) )
    ; ( "corners"
      , `List
          [ obj
              [ "corner", str "slow"
              ; "status", str "measured"
              ; "setup_goal", str "fail"
              ; "hold_goal", str "pass"
              ]
          ] )
    ; ( "metrics"
      , `List
          [ metric "setup_slack" "timing__setup__ws" (-0.125) "ns" 1
          ; metric "setup_violations" "timing__setup_vio__count" 0. "count" 2
          ; metric "hold_slack" "timing__hold__ws" 0. "ns" 3
          ; metric "hold_violations" "timing__hold_vio__count" 0. "count" 4
          ] )
    ; "timing_goal", str "fail"
    ]
;;

let handle service root operation =
  Service.handle service ~root ~environment operation
  >>| function
  | Ok snapshot -> snapshot
  | Error error -> raise_s [%message "Timing service request failed" (error : V1.Error.t)]
;;

let settled service root operation =
  let%bind (_ : Asic.Snapshot.t) = handle service root operation in
  let%bind () = Service.completion service in
  handle service root Get
;;

let main () =
  let root =
    Core_unix.mkdtemp "/tmp/workbench-timing-analysis-" |> Filename_unix.realpath
  in
  let file name = Filename.concat root name in
  let write name j = Out_channel.write_all (file name) ~data:(Yojson.Safe.to_string j) in
  let execution_file = file "execution.json" in
  write "execution.json" (obj [ "attempt_id", str run.id; "status", str "failed" ]);
  let execution_sha256 = Public.digest (In_channel.read_all execution_file) in
  let registered : Asic.Run.t =
    { run
    ; reference = { attempt = root; stream_id = run.id }
    ; selection = None
    ; cursor = 1
    ; status = "failed"
    ; execution_file = Some execution_file
    ; error = Some "later DRC timeout"
    ; stages = []
    ; execution_timing = None
    }
  in
  let analysis = fixture root execution_file execution_sha256 in
  let report =
    obj
      [ "contract", str "hardcaml-asic.report"
      ; "schema_version", `Int 1
      ; "execution", obj [ "attempt_id", str run.id; "status", str "failed" ]
      ; ( "methodology"
        , obj
            [ "contract", str "hardcaml-asic.historical-methodology"
            ; "schema_version", `Int 1
            ; "state", str "recorded"
            ; "reference", obj [ "attempt_id", str run.id ]
            ] )
      ; "checkpoints", `List []
      ; "acceptance", str "not_evaluated"
      ; "timing_analysis", analysis
      ]
  in
  let parse a =
    Parser.parse
      ~registered
      ~execution_file
      ~execution_sha256
      (replace report "timing_analysis" a)
    |> Option.value_exn
  in
  let value = parse analysis in
  Parser.validate_cached ~execution_file value;
  rejects (fun () ->
    Parser.validate_cached
      ~execution_file
      { value with
        duration = Some { (Option.value_exn value.duration) with seconds = 42. }
      });
  require
    (Timing.Status.equal value.status Completed
     && Timing.Goal.equal value.timing_goal Fail
     && Float.equal (Option.value_exn value.duration).seconds 0.
     && List.for_all value.metrics ~f:(fun m -> Option.is_some m.value))
    "Completed timing/zero metrics lost";
  require
    (Option.is_none
       (Parser.parse
          ~registered
          ~execution_file
          ~execution_sha256
          (replace report "timing_analysis" `Null)))
    "Legacy report invented timing";
  List.iter
    [ "attempt_id", str "other"
    ; "analysis_id", str "other/post-pnr-sta"
    ; "occurrence_id", str "other/implementation.signoff"
    ; "execution_sha256", str hash
    ; "source_digest", str "bad"
    ; "execution_file", str "/other"
    ]
    ~f:(fun (key, v) -> rejects (fun () -> parse (replace analysis key v)));
  let duration = Public.field "duration" analysis in
  List.iter [ -1.; Float.nan; Float.infinity ] ~f:(fun f ->
    rejects (fun () ->
      parse (replace analysis "duration" (replace duration "seconds" (`Float f)))));
  let change_metrics f =
    replace
      analysis
      "metrics"
      (`List (List.map (Public.list (Public.field "metrics" analysis)) ~f))
  in
  let unknown = parse (change_metrics (fun m -> replace m "source" `Null)) in
  require
    (List.for_all unknown.metrics ~f:(fun m -> Option.is_none m.value)
     && Timing.Goal.equal unknown.timing_goal Unknown)
    "Invalid provenance earned a metric/goal";
  let unknown =
    parse (change_metrics (fun m -> replace m "value" (`Float Float.infinity)))
  in
  require
    (List.for_all unknown.metrics ~f:(fun m -> Option.is_none m.value)
     && Timing.Goal.equal unknown.timing_goal Unknown)
    "Nonfinite metrics earned a goal";
  let unknown = parse (change_metrics (fun m -> replace m "unit" (str "unknown"))) in
  require
    (List.for_all unknown.metrics ~f:(fun m -> Option.is_none m.value)
     && Timing.Goal.equal unknown.timing_goal Unknown)
    "Unknown units earned measurements";
  let unknown = parse (change_metrics (fun m -> replace m "raw_key" (str "inherited"))) in
  require
    (List.for_all unknown.metrics ~f:(fun m -> Option.is_none m.value)
     && Timing.Goal.equal unknown.timing_goal Unknown)
    "Unattributed metrics earned measurements";
  let missing =
    obj
      [ "corner", str "missing"
      ; "status", str "missing_or_equivalent"
      ; "setup_goal", str "unknown"
      ; "hold_goal", str "unknown"
      ]
  in
  let pass_metrics = change_metrics (fun m -> replace m "value" (`Float 0.)) in
  let pass_corner =
    obj
      [ "corner", str "slow"
      ; "status", str "measured"
      ; "setup_goal", str "pass"
      ; "hold_goal", str "pass"
      ]
  in
  let all_pass =
    replace pass_metrics "corners" (`List [ pass_corner ])
    |> fun a -> replace a "timing_goal" (str "pass")
  in
  require
    (Timing.Goal.equal (parse all_pass).timing_goal Pass)
    "Zero slack/count did not pass";
  let unknown = parse (replace all_pass "corners" (`List [ pass_corner; missing ])) in
  require (Timing.Goal.equal unknown.timing_goal Unknown) "Missing corner earned a pass";
  let unavailable =
    analysis
    |> fun a ->
    replace a "status" (str "unavailable")
    |> fun a ->
    replace a "reason" (str "STA unreached")
    |> fun a ->
    replace a "duration" `Null
    |> fun a ->
    replace a "producer" `Null
    |> fun a ->
    replace a "metrics" (`List [])
    |> fun a ->
    replace a "corners" (`List []) |> fun a -> replace a "timing_goal" (str "unknown")
  in
  require
    (Timing.Status.equal (parse unavailable).status Unavailable)
    "Unreached STA lost";
  rejects (fun () -> parse (replace unavailable "duration" duration));
  let executable = file "fixture-provider" in
  Out_channel.write_all executable ~data:(In_channel.read_all "inspection_provider.py");
  Core_unix.chmod executable ~perm:0o700;
  let config : Config.t =
    { schema_version = 1
    ; project_executable = executable
    ; provider_executable = executable
    ; results_root = file "results"
    ; toolchain = file "toolchain"
    ; python = None
    ; support_tools = None
    ; pdk_root = None
    ; stage_timeout_seconds = None
    }
  in
  Out_channel.write_all
    (file Config.filename)
    ~data:(Sexp.to_string_mach (Config.sexp_of_t config));
  let identity =
    Sexp.to_string_mach
      [%sexp
        (root : string)
        , (environment : V1.Environment_selection.t)
        , (Some config : Config.t option)]
  in
  let state_dir = file "cache" in
  Core_unix.mkdir_p state_dir ~perm:0o700;
  let registry =
    Sexp.List
      [ [%sexp "version", (1 : int)]
      ; [%sexp "identity", (identity : string)]
      ; [%sexp "runs", ([ registered ] : Asic.Run.t list)]
      ; [%sexp "submissions", ([] : (string * Asic.Preview.t * string option) list)]
      ; [%sexp "index", ([] : (string * string) list)]
      ; [%sexp
          "terminal_attempts"
          , ([ run.id, "stale-adopted-finalization" ] : (string * string) list)]
      ]
  in
  Out_channel.write_all
    (Filename.concat state_dir ("asic-" ^ Public.digest identity ^ ".sexp"))
    ~data:(Sexp.to_string_mach registry);
  Out_channel.write_all (file "cursor") ~data:"1";
  write "report.json" report;
  let response =
    obj
      [ "contract", str "hardcaml-asic.inspection"
      ; "schema_version", `Int 1
      ; "execution_file", str execution_file
      ; "execution_sha256", str execution_sha256
      ; "attempt_id", str run.id
      ; "domain", str "timing"
      ; "stage", str "signoff"
      ; "analysis_id", str value.target.analysis_id
      ; "analysis_digest", str analysis_digest
      ; "source_digest", str index_digest
      ; ( "rows"
        , `List
            [ obj
                [ "id", str "path-1"
                ; "category", str "timing_path"
                ; "producer", str "STA"
                ; "corner", str "slow"
                ; "group", `Null
                ; "name", str "path"
                ; "value", `Float (-0.125)
                ; "unit", str "ns"
                ; "status", str "violated"
                ; "source", str "{}"
                ; "fields", `List []
                ]
            ] )
      ; "diagnostics", `List []
      ; "truncated", `Bool false
      ]
  in
  write "response.json" response;
  let service = Service.create ~state_dir in
  let%bind snapshot = settled service root (Load_summary run) in
  let summary = List.hd_exn snapshot.summaries in
  require
    (Option.is_none summary.terminal
     && Timing.equal (Option.value_exn summary.timing_analysis) value
     && String.equal summary.completion "failed")
    "Failed run failed to materialize independent STA";
  require
    (match summary.freshness with
     | Refresh_failed _ -> true
     | _ -> false)
    "Adopted finalization failure hid independent timing or lost diagnostics";
  let inspect refresh =
    Asic.Operation.Inspect_analysis { run; target = value.target; refresh }
  in
  let calls () = In_channel.read_all (file "inspection-calls") in
  let inspection_calls () =
    In_channel.read_lines (file "inspection-calls")
    |> List.filter_map ~f:(fun line ->
      match Public.decode line with
      | `List (`String "inspect" :: args) -> Some args
      | _ -> None)
  in
  let generic_response =
    replace response "analysis_id" `Null
    |> fun r ->
    replace r "analysis_digest" `Null
    |> fun r -> replace r "source_digest" (str (String.make 64 'd'))
  in
  let generic_index =
    Inspection.parse_index
      ~registered
      ~execution_file
      ~execution_sha256
      ~domain:"timing"
      ~stage:"signoff"
      generic_response
  in
  Inspection.save ~state_dir ~identity generic_index;
  let before = List.length (inspection_calls ()) in
  let%bind snapshot = settled service root (inspect false) in
  require
    (Option.equal
       Asic_inspection.Analysis_target.equal
       (List.hd_exn snapshot.inspections).analysis
       (Some value.target)
     && List.length (inspection_calls ()) = before + 1)
    "Generic persisted cache prevented bounded exact-target fetch";
  let generic refresh =
    Asic.Operation.Inspect { run; domain = "timing"; stage = "signoff"; refresh }
  in
  write "response.json" generic_response;
  let%bind snapshot = settled service root (generic true) in
  require
    (Option.is_none (List.hd_exn snapshot.inspections).analysis)
    "Generic signoff inspection did not retain checkpoint-backed behavior";
  write "response.json" response;
  let before = calls () in
  let%bind snapshot = settled service root (generic false) in
  require
    (Option.is_none (List.hd_exn snapshot.inspections).analysis
     && String.equal before (calls ()))
    "Generic cache reopen unexpectedly selected supplementary evidence";
  let before = List.length (inspection_calls ()) in
  let%bind snapshot = settled service root (inspect false) in
  require
    (List.length (inspection_calls ()) = before + 1
     && List.mem
          (List.last_exn (inspection_calls ()))
          (str analysis_digest)
          ~equal:Poly.equal
     && List.mem
          (List.last_exn (inspection_calls ()))
          (str "--expected-digest")
          ~equal:Poly.equal)
    "Generic L1 cache miss did not fetch with captured analysis digest";
  let index = List.hd_exn snapshot.inspections in
  require
    (Option.equal
       Asic_inspection.Analysis_target.equal
       index.analysis
       (Some value.target))
    "Analysis inspection identity lost";
  let detail target =
    Asic.Operation.Inspect_analysis_detail
      { run; target; source_digest = index.source_digest; row_id = "path-1" }
  in
  let%bind snapshot = settled service root (detail value.target) in
  require
    (Option.is_none (List.hd_exn snapshot.inspection_details).error)
    "Exact analysis detail failed";
  let wrong_target = { value.target with source_digest = hash } in
  let before = List.length (inspection_calls ()) in
  let%bind snapshot =
    settled
      service
      root
      (Inspect_analysis { run; target = wrong_target; refresh = false })
  in
  require
    (List.length (inspection_calls ()) = before + 1
     && List.exists snapshot.operations ~f:(fun p ->
       String.equal p.key (Asic_inspection.analysis_index_key ~run ~target:wrong_target)
       && String.equal p.state "failed")
     && Option.equal
          Asic_inspection.Analysis_target.equal
          (List.hd_exn snapshot.inspections).analysis
          (Some value.target))
    "Incompatible exact cache accepted replacement instead of rejecting pinned fetch";
  let%bind snapshot = settled service root (detail wrong_target) in
  require
    (Option.is_some (List.hd_exn snapshot.inspection_details).error)
    "Cached detail silently replaced captured analysis";
  let%bind () = Service.shutdown service in
  let before = calls () in
  write "response.json" (replace response "analysis_digest" (str hash));
  Core_unix.unlink execution_file;
  let restarted = Service.create ~state_dir in
  let%bind snapshot = settled restarted root (Load_summary run) in
  let summary = List.hd_exn snapshot.summaries in
  require
    (Asic.Summary.Freshness.equal summary.freshness Cached_unverified
     && Timing.equal (Option.value_exn summary.timing_analysis) value)
    "Cached STA identity changed";
  let%bind snapshot = settled restarted root (inspect false) in
  require
    ((List.hd_exn snapshot.inspections).cached_unverified
     && String.equal before (calls ()))
    "Warm exact reopen contacted provider";
  let%bind snapshot =
    settled
      restarted
      root
      (Inspect_analysis { run; target = wrong_target; refresh = false })
  in
  require
    (List.exists snapshot.operations ~f:(fun p -> String.equal p.state "failed")
     && Option.equal
          Asic_inspection.Analysis_target.equal
          (List.hd_exn snapshot.inspections).analysis
          (Some value.target))
    "Warm cache retargeted captured source";
  let%bind snapshot = settled restarted root (inspect true) in
  require
    (List.exists snapshot.operations ~f:(fun p -> String.equal p.state "failed")
     && Timing.equal
          (Option.value_exn (List.hd_exn snapshot.summaries).timing_analysis)
          value)
    "Missing inspection evidence erased immutable timing completion";
  write "execution.json" (obj [ "attempt_id", str run.id; "status", str "failed" ]);
  Out_channel.write_all (file "ignore-pin") ~data:"malicious provider";
  write "response.json" (replace response "analysis_digest" (str hash));
  let%bind snapshot = settled restarted root (inspect true) in
  require
    (List.exists snapshot.operations ~f:(fun p ->
       String.equal p.key (Asic_inspection.analysis_index_key ~run ~target:value.target)
       && String.equal p.state "failed"))
    "Replaced analysis envelope accepted";
  write "response.json" (replace response "analysis_id" (str "other/post-pnr-sta"));
  let%bind snapshot = settled restarted root (detail value.target) in
  require
    (Option.is_some (List.hd_exn snapshot.inspection_details).error)
    "Wrong detail analysis ID accepted";
  let calls = calls () in
  require
    (String.is_substring calls ~substring:analysis_digest
     && String.is_substring calls ~substring:index_digest
     && (not (String.is_substring calls ~substring:"\"finalize\""))
     && not (String.is_substring calls ~substring:"execute"))
    "Inspection contract or read-only guarantee lost";
  let%bind () = Service.shutdown restarted in
  (* Executable Timing freezes a prefix before downstream Signoff finishes. The inspection
     envelope still hashes the mutable main execution. *)
  let stages =
    [ "synthesis"; "floorplan"; "placement"; "cts"; "routing"; "timing"; "signoff" ]
  in
  let plan =
    obj
      [ "schema_version", `Int 4
      ; "initial_boundary", `Null
      ; "stages", `List (List.map stages ~f:str)
      ]
  in
  let occurrence =
    obj
      [ "action_key", str "implementation.timing"
      ; "occurrence_id", str "run-1/implementation.timing"
      ; "status", str "completed"
      ; "exit_code", `Int 0
      ; "best_effort", `Bool false
      ; "verdict", `Null
      ; "duration_seconds", `Float 12.5
      ]
  in
  let prefix =
    obj
      [ "attempt_id", str run.id
      ; "status", str "running"
      ; "plan", plan
      ; "occurrences", `List [ occurrence ]
      ; "artifacts", `List [ obj [ "boundary", str "timing"; "identity", str hash ] ]
      ]
  in
  let source_file = execution_file ^ ".timing-source" in
  Out_channel.write_all source_file ~data:(Yojson.Safe.to_string prefix);
  let frozen_hash = Public.digest (In_channel.read_all source_file) in
  let current = replace prefix "status" (str "failed") in
  write "execution.json" current;
  let main_hash () = Public.digest (In_channel.read_all execution_file) in
  let executable_analysis =
    analysis
    |> fun a ->
    replace a "schema_version" (`Int 2)
    |> fun a ->
    replace a "stage" (str "timing")
    |> fun a ->
    replace a "occurrence_id" (str "run-1/implementation.timing")
    |> fun a ->
    replace a "execution_file" (str source_file)
    |> fun a ->
    replace a "execution_sha256" (str frozen_hash)
    |> fun a ->
    replace a "enclosing_status" (str "running")
    |> fun a ->
    replace a "evidence_scope" (str "immutable_timing_execution_source_not_checkpoint")
  in
  let new_report =
    replace report "execution" current
    |> fun r -> replace r "timing_analysis" executable_analysis
  in
  write "report.json" new_report;
  let parsed =
    Parser.parse ~registered ~execution_file ~execution_sha256:(main_hash ()) new_report
    |> Option.value_exn
  in
  Parser.validate_cached ~execution_file parsed;
  require
    (String.equal parsed.target.stage "timing"
     && Option.equal String.equal parsed.target.execution_file (Some source_file)
     && not (String.equal frozen_hash (main_hash ())))
    "Frozen source identity lost";
  List.iter
    [ "attempt_id", str "other"
    ; "plan", replace plan "initial_boundary" (str "routing")
    ; "occurrences", `List []
    ; "artifacts", `List []
    ]
    ~f:(fun (key, v) ->
      write "execution.json" (replace current key v);
      rejects (fun () ->
        Parser.parse
          ~registered
          ~execution_file
          ~execution_sha256:(main_hash ())
          new_report));
  write "execution.json" current;
  let inspect_new refresh =
    Asic.Operation.Inspect_analysis { run; target = parsed.target; refresh }
  in
  let new_response =
    replace response "stage" (str "timing")
    |> fun r -> replace r "execution_sha256" (str (main_hash ()))
  in
  write "response.json" new_response;
  let service = Service.create ~state_dir in
  let%bind snapshot = settled service root (Refresh run) in
  let summary = List.hd_exn snapshot.summaries in
  require
    (String.equal summary.completion "failed"
     && String.equal (Option.value_exn summary.timing_analysis).enclosing_status "running"
    )
    "Frozen enclosing status replaced current outcome";
  let%bind snapshot = settled service root (inspect_new true) in
  let index =
    List.find_exn snapshot.inspections ~f:(fun index -> String.equal index.stage "timing")
  in
  require
    (Option.equal
       Asic_inspection.Analysis_target.equal
       index.analysis
       (Some parsed.target))
    "Timing index lost captured prefix target";
  (* Main hash evolves between index and detail without changing Timing evidence. *)
  write "execution.json" (replace current "status" (str "completed"));
  write "response.json" (replace new_response "execution_sha256" (str (main_hash ())));
  let%bind snapshot =
    settled
      service
      root
      (Inspect_analysis_detail
         { run
         ; target = parsed.target
         ; source_digest = index.source_digest
         ; row_id = "path-1"
         })
  in
  require
    (List.exists snapshot.inspection_details ~f:(fun d ->
       String.equal d.stage "timing" && Option.is_none d.error))
    "Main execution advancement incorrectly invalidated frozen Timing detail";
  let%bind () = Service.shutdown service in
  Core_unix.unlink source_file;
  let service = Service.create ~state_dir in
  let%bind snapshot = settled service root (inspect_new false) in
  require
    (List.exists snapshot.inspections ~f:(fun i ->
       String.equal i.stage "timing"
       && i.cached_unverified
       && Option.equal
            Asic_inspection.Analysis_target.equal
            i.analysis
            (Some parsed.target)))
    "Stage-aware source target failed offline cache restart";
  Out_channel.write_all source_file ~data:"replaced";
  let%bind snapshot = settled service root (inspect_new true) in
  require
    (List.exists snapshot.operations ~f:(fun p ->
       String.equal p.key (Asic_inspection.analysis_index_key ~run ~target:parsed.target)
       && String.equal p.state "failed"))
    "Frozen execution source replacement accepted";
  let%map () = Service.shutdown service in
  print_endline
    "timing analysis parser, failed-run ingestion, exact inspection, cache restart and \
     replacement fences passed"
;;

let retained execution_file provider =
  let execution_bytes =
    Backend.Asic_evidence_file.read_bounded execution_file (8 * 1024 * 1024)
  in
  let execution = Public.decode execution_bytes in
  let attempt_id = Public.text (Public.field "attempt_id" execution) in
  let execution_sha256 = Public.digest execution_bytes in
  let registered : Asic.Run.t =
    { run
    ; reference = { attempt = Filename.dirname execution_file; stream_id = attempt_id }
    ; selection = None
    ; cursor = 1
    ; status = "failed"
    ; execution_file = Some execution_file
    ; error = None
    ; stages = []
    ; execution_timing = None
    }
  in
  let query args =
    Process.run ~prog:provider ~args ()
    >>| fun result -> Public.decode (Or_error.ok_exn result)
  in
  let%bind report = query [ "report"; execution_file; "--json" ] in
  let normalized =
    Public.observation_stages (obj [ "stream_id", str attempt_id; "state", execution ])
  in
  require
    (List.length normalized
     = List.length (Public.recipe_stages (Public.field "plan" execution)))
    "Provider execution recipe did not normalize in its actual stage order";
  let summary = Public.summary registered ~expected_plan:None ~execution_file report in
  let analysis =
    Parser.parse ~registered ~execution_file ~execution_sha256 report |> Option.value_exn
  in
  Parser.validate_cached ~execution_file analysis;
  if String.equal analysis.target.stage "timing"
  then (
    let segment =
      List.find_exn normalized ~f:(fun stage -> String.equal stage.id "timing")
    in
    let segment_seconds =
      Option.value_exn (Option.value_exn segment.execution_timing).measured_seconds
    in
    require
      (not (Float.equal segment_seconds (Option.value_exn analysis.duration).seconds))
      "Native STA runtime incorrectly replaced full Timing segment duration");
  require
    (Timing.Status.equal analysis.status Completed
     && String.equal summary.completion (Public.text (Public.field "status" execution))
     && Float.equal (Option.value_exn analysis.duration).seconds 1.575)
    "Provider handoff projection mismatch";
  let args =
    [ "inspect"
    ; execution_file
    ; "--domain"
    ; "timing"
    ; "--stage"
    ; analysis.target.stage
    ; "--json"
    ]
  in
  let%bind response =
    query (args @ [ "--expected-digest"; analysis.target.source_digest ])
  in
  let index =
    Inspection.parse_index
      ~analysis:analysis.target
      ~registered
      ~execution_file
      ~execution_sha256
      ~domain:"timing"
      ~stage:analysis.target.stage
      response
  in
  require
    (Option.equal
       Asic_inspection.Analysis_target.equal
       index.analysis
       (Some analysis.target))
    "Provider index source mismatch";
  let row_id = (List.hd_exn index.rows).id in
  let%map response =
    query (args @ [ "--row-id"; row_id; "--expected-digest"; index.source_digest ])
  in
  let detail = Inspection.parse_detail ~registered ~index ~row_id response in
  require
    (Option.is_none detail.error && not (String.is_empty detail.text))
    "Provider detail mismatch";
  print_endline
    "retained provider report, recipe, exact analysis index and detail parsed \
     successfully"
;;

let continuations routing timing signoff provider =
  let load path =
    let execution =
      Backend.Asic_evidence_file.read_bounded path (8 * 1024 * 1024) |> Public.decode
    in
    let attempt = Public.text (Public.field "attempt_id" execution) in
    let stages =
      Public.observation_stages (obj [ "stream_id", str attempt; "state", execution ])
    in
    execution, attempt, stages
  in
  let routing_execution, routing_attempt, routing_stages = load routing in
  let timing_execution, timing_attempt, timing_stages = load timing in
  let signoff_execution, signoff_attempt, signoff_stages = load signoff in
  require
    ((not (String.equal routing_attempt timing_attempt))
     && not (String.equal timing_attempt signoff_attempt))
    "Continuation borrowed attempt identity";
  let requested stages =
    List.filter_map stages ~f:(fun s ->
      if s.Asic.Stage.requested then Some s.id else None)
  in
  require
    (List.equal
       String.equal
       (requested routing_stages)
       (List.take Public.canonical_stages 5)
     && List.equal String.equal (requested timing_stages) [ "timing" ]
     && List.equal String.equal (requested signoff_stages) [ "signoff" ])
    "Continuation invented repeated physical occurrences";
  List.iter
    [ routing_execution, `Null
    ; timing_execution, str "routing"
    ; signoff_execution, str "timing"
    ]
    ~f:(fun (execution, initial) ->
      require
        (Poly.equal
           (Public.field "initial_boundary" (Public.field "plan" execution))
           initial
         && Poly.equal (Public.field "status" execution) (str "completed"))
        "Continuation recipe boundary/outcome mismatch");
  let registered : Asic.Run.t =
    { run
    ; reference = { attempt = Filename.dirname signoff; stream_id = signoff_attempt }
    ; selection = None
    ; cursor = 0
    ; status = "completed"
    ; execution_file = Some signoff
    ; error = None
    ; stages = signoff_stages
    ; execution_timing = None
    }
  in
  let%map bytes = Process.run ~prog:provider ~args:[ "report"; signoff; "--json" ] () in
  require
    (Option.is_none
       (Parser.parse
          ~registered
          ~execution_file:signoff
          ~execution_sha256:(Public.digest (In_channel.read_all signoff))
          (Public.decode (Or_error.ok_exn bytes))))
    "Signoff-only attempt borrowed Timing analysis";
  print_endline
    "retained Routing -> Timing -> Signoff exact continuation identities validated"
;;

let () =
  don't_wait_for
    (let%bind () =
       match Array.to_list (Sys.get_argv ()) with
       | [ _; "--retained"; execution_file; provider ] -> retained execution_file provider
       | [ _; "--continuations"; routing; timing; signoff; provider ] ->
         continuations routing timing signoff provider
       | _ -> main ()
     in
     Shutdown.exit 0);
  never_returns (Scheduler.go ())
;;
