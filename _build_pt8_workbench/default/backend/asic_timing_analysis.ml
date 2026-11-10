open! Core
module Inspection = Asic_inspection
open Hardcaml_workbench_protocol
module Public = Asic_public
module Wire = Asic.Timing_analysis

let validate_target = Inspection.validate_analysis_target

let goal = function
  | `String "pass" -> Wire.Goal.Pass
  | `String "fail" -> Fail
  | _ -> Unknown
;;

let number = function
  | `Float f when Float.is_finite f -> Some f
  | `Int n -> Some (Float.of_int n)
  | _ -> None
;;

(* The source hash belongs to the frozen Timing prefix, while inspection envelopes
   describe the main execution. Validate their shared execution identities explicitly. *)
let validate_source
  ?enclosing_status
  ~execution_file
  (target : Asic_inspection.Analysis_target.t)
  =
  Option.iter target.execution_file ~f:(fun source ->
    Public.require
      (String.equal source execution_file
       || (String.equal target.stage "timing"
           && String.equal source (execution_file ^ ".timing-source")))
      "Unexpected timing execution source";
    let bytes = Asic_evidence_file.read_bounded source (8 * 1024 * 1024) in
    Public.require
      (String.equal (Public.digest bytes) target.execution_sha256)
      "Timing execution source changed";
    let frozen = Public.decode bytes in
    Option.iter enclosing_status ~f:(fun status ->
      Public.require
        (Poly.equal (Public.field "status" frozen) (`String status))
        "Timing enclosing status differs from captured execution source");
    let main =
      Asic_evidence_file.read_bounded execution_file (8 * 1024 * 1024) |> Public.decode
    in
    let field = Public.field in
    Public.require
      (Poly.equal (field "attempt_id" frozen) (`String target.attempt_id)
       && Poly.equal (field "attempt_id" main) (`String target.attempt_id)
       && Poly.equal
            (Public.canonical_json (field "plan" frozen))
            (Public.canonical_json (field "plan" main)))
      "Timing execution source attempt/plan mismatch";
    if not (String.equal source execution_file)
    then (
      let selected execution key name value =
        Public.list (field key execution)
        |> List.filter ~f:(fun entry -> Poly.equal (field name entry) (`String value))
      in
      List.iter
        [ "occurrences", "occurrence_id", target.occurrence_id
        ; "artifacts", "boundary", "timing"
        ]
        ~f:(fun (key, name, value) ->
          let a = selected frozen key name value in
          let b = selected main key name value in
          Public.require
            (List.length a = 1
             && Poly.equal
                  (Public.canonical_json (`List a))
                  (Public.canonical_json (`List b)))
            "Timing execution source occurrence/checkpoint mismatch")))
;;

let parse_for_attempt
  ?(validate_files = true)
  ~attempt_id
  ~execution_file
  ~execution_sha256
  report
  =
  match Public.field "timing_analysis" report with
  | `Null -> None
  | j ->
    let evidence = Yojson.Safe.to_string j in
    Public.require
      (String.length evidence <= 1024 * 1024)
      "Timing analysis exceeds budget";
    let version = Public.integer (Public.field "schema_version" j) in
    Public.require (version = 1 || version = 2) "Unsupported timing analysis schema";
    let j = Public.envelope j "hardcaml-asic.timing-analysis" version in
    let field name = Public.field name j in
    let target : Asic_inspection.Analysis_target.t =
      { attempt_id = Public.text (field "attempt_id")
      ; occurrence_id = Public.text (field "occurrence_id")
      ; analysis_id = Public.text (field "analysis_id")
      ; source_digest = Public.text (field "source_digest")
      ; execution_sha256 = Public.text (field "execution_sha256")
      ; stage = Public.text (field "stage")
      ; execution_file =
          (if version = 1
           then None
           else Some (Public.absolute (Public.text (field "execution_file"))))
      }
    in
    validate_target target;
    Public.require
      (String.equal target.attempt_id attempt_id
       &&
       if version = 1
       then
         String.equal target.execution_sha256 execution_sha256
         && Poly.equal (field "execution_file") (`String execution_file)
         && String.equal target.stage "signoff"
         && Poly.equal
              (field "evidence_scope")
              (`String "terminal_supplementary_not_checkpoint")
       else
         String.equal target.stage "timing"
         && Poly.equal
              (field "evidence_scope")
              (`String "immutable_timing_execution_source_not_checkpoint"))
      "Timing analysis execution/attempt mismatch";
    if validate_files
    then
      validate_source
        ~enclosing_status:(Public.text (field "enclosing_status"))
        ~execution_file
        target;
    let enclosing_status = Public.text (field "enclosing_status") in
    Public.require
      (List.mem
         [ "running"; "completed"; "failed"; "interrupted" ]
         enclosing_status
         ~equal:String.equal
       && (version = 2
           || Poly.equal
                (Public.field "status" (Public.field "execution" report))
                (`String enclosing_status)))
      "Invalid timing enclosing status";
    let inventory = Public.list (field "inventory") in
    Public.require (List.length inventory <= 512) "Timing inventory exceeds budget";
    List.iter inventory ~f:(fun source ->
      ignore (Public.absolute (Public.text (Public.field "path" source)) : string);
      Inspection.validate_digest (Public.text (Public.field "sha256" source)));
    let source_valid source =
      match Public.field "path" source, Public.field "sha256" source with
      | `String path, `String hash ->
        Filename.is_absolute path
        && Result.is_ok (Or_error.try_with (fun () -> Inspection.validate_digest hash))
        && List.exists inventory ~f:(fun entry ->
          Poly.equal (Public.field "path" entry) (`String path)
          && Poly.equal (Public.field "sha256" entry) (`String hash))
      | _ -> false
    in
    let status =
      match field "status" with
      | `String "completed" -> Wire.Status.Completed
      | `String "unavailable" -> Unavailable
      | _ -> failwith "Unsupported timing analysis status"
    in
    let reason = Public.optional_text (field "reason") in
    let producer_json = field "producer" in
    let producer_dir = Public.optional_text (Public.field "directory" producer_json) in
    let producer_source source suffix =
      source_valid source
      && Option.value_map producer_dir ~default:false ~f:(fun directory ->
        Poly.equal
          (Public.field "path" source)
          (`String (Filename.concat directory suffix)))
    in
    if Wire.Status.equal status Completed
    then
      Public.require
        (Poly.equal
           (field "native_grammar")
           (`String "librelane-3.1.0.dev3-step-output-runtime-v1")
         && Poly.equal
              (Public.field "class_id" producer_json)
              (`String "OpenROAD.STAPostPNR")
         && producer_source (Public.field "config" producer_json) "config.json")
        "Unsupported timing native producer";
    let duration =
      match field "duration" with
      | `Null -> None
      | d ->
        let seconds = Option.value_exn (number (Public.field "seconds" d)) in
        let precision_seconds =
          Option.value_exn (number (Public.field "precision_seconds" d))
        in
        let basis = Public.text (Public.field "basis" d) in
        let source = Public.field "source" d in
        Public.require
          (Float.(seconds >= 0. && precision_seconds > 0.)
           && String.equal basis "librelane_step_wall_clock"
           && producer_source source "runtime.txt")
          "Invalid timing duration/provenance";
        Some
          { Wire.Duration.seconds
          ; basis
          ; precision_seconds
          ; source = Yojson.Safe.to_string source
          }
    in
    let corners_json = Public.list (field "corners") in
    let metrics_json = Public.list (field "metrics") in
    Public.require
      (List.length corners_json <= 64 && List.length metrics_json <= 256)
      "Timing corner/metric budget exceeded";
    let metrics =
      List.map metrics_json ~f:(fun m ->
        let get name = Public.field name m in
        let key = Public.text (get "key") in
        let corner = Public.text (get "corner") in
        let raw_key = Public.text (get "raw_key") in
        let unit_ = Public.optional_text (get "unit") in
        let count =
          List.mem [ "setup_violations"; "hold_violations" ] key ~equal:String.equal
        in
        let known =
          count || List.mem [ "setup_slack"; "hold_slack" ] key ~equal:String.equal
        in
        let source = get "source" in
        let valid =
          known
          && List.exists corners_json ~f:(fun c ->
            Poly.equal (Public.field "corner" c) (`String corner)
            && Poly.equal (Public.field "status" c) (`String "measured"))
          && Poly.equal (get "availability") (`String "available")
          && Option.equal String.equal unit_ (Some (if count then "count" else "ns"))
          && producer_source (Public.field "file" source) (corner ^ "/sta.log")
          && producer_source (Public.field "state" source) "state_out.json"
          && (match Public.field "line" source with
              | `Int n -> n > 0
              | _ -> false)
          && (count || source_valid (get "units_source"))
          && String.equal
               raw_key
               ((match key with
                 | "setup_slack" -> "timing__setup__ws"
                 | "hold_slack" -> "timing__hold__ws"
                 | "setup_violations" -> "timing__setup_vio__count"
                 | "hold_violations" -> "timing__hold_vio__count"
                 | _ -> "unknown")
                ^ "__corner:"
                ^ corner)
        in
        let value =
          Option.filter
            (number (get "value"))
            ~f:(fun f ->
              valid
              && Float.(abs f < 1e30)
              && ((not count)
                  || Float.(f >= 0. && f <= 9007199254740991. && round_down f = f)))
        in
        { Wire.Metric.key
        ; corner
        ; raw_key
        ; value
        ; unit_
        ; reason =
            (if Option.is_some value
             then None
             else
               Some
                 (Option.value
                    (Public.optional_text (get "reason"))
                    ~default:"unavailable or unvalidated provenance"))
        ; provenance = Yojson.Safe.to_string m
        })
    in
    let metric_ids = List.map metrics ~f:(fun m -> m.Wire.Metric.corner, m.key) in
    Public.require
      (List.length metric_ids
       = List.length (List.dedup_and_sort metric_ids ~compare:[%compare: string * string])
      )
      "Duplicate timing metric";
    let scoped corner mode measured supplied =
      let value suffix =
        List.find_map metrics ~f:(fun m ->
          if String.equal m.corner corner && String.equal m.key (mode ^ suffix)
          then m.value
          else None)
      in
      let derived =
        if not measured
        then Wire.Goal.Unknown
        else (
          match value "_slack", value "_violations" with
          | Some s, _ when Float.(s < 0.) -> Wire.Goal.Fail
          | _, Some n when Float.(n > 0.) -> Fail
          | Some _, Some n when measured && Float.equal n 0. -> Pass
          | _ -> Unknown)
      in
      if Wire.Goal.equal derived (goal supplied) then derived else Unknown
    in
    let corners =
      List.map corners_json ~f:(fun c ->
        let corner = Public.text (Public.field "corner" c) in
        let measured = Poly.equal (Public.field "status" c) (`String "measured") in
        { Wire.Corner.corner
        ; measured
        ; setup_goal = scoped corner "setup" measured (Public.field "setup_goal" c)
        ; hold_goal = scoped corner "hold" measured (Public.field "hold_goal" c)
        })
    in
    let corner_ids = List.map corners ~f:(fun c -> c.Wire.Corner.corner) in
    Public.require
      (List.length corner_ids
       = List.length (List.dedup_and_sort corner_ids ~compare:String.compare)
       && List.for_all metrics ~f:(fun m ->
         List.mem corner_ids m.corner ~equal:String.equal))
      "Invalid timing corner attribution";
    let goals = List.concat_map corners ~f:(fun c -> [ c.setup_goal; c.hold_goal ]) in
    let derived =
      if List.mem goals Wire.Goal.Fail ~equal:Wire.Goal.equal
      then Wire.Goal.Fail
      else if (not (List.is_empty goals)) && List.for_all goals ~f:(Wire.Goal.equal Pass)
      then Pass
      else Unknown
    in
    let timing_goal =
      if Wire.Goal.equal derived (goal (field "timing_goal")) then derived else Unknown
    in
    let producer =
      match field "producer" with
      | `Null -> None
      | p -> Some (Yojson.Safe.to_string p)
    in
    (match status with
     | Completed ->
       Public.require
         (Option.is_some duration && Option.is_some producer)
         "Completed timing lacks native provenance"
     | Unavailable ->
       Public.require
         (Option.is_some reason
          && Option.is_none duration
          && Option.is_none producer
          && List.is_empty metrics
          && List.is_empty corners
          && Wire.Goal.equal timing_goal Unknown)
         "Unavailable timing claims measurements";
       Public.require
         (Poly.equal (field "timing_goal") (`String "unknown"))
         "Unavailable timing claims measurements");
    Some
      { Wire.target
      ; status
      ; reason
      ; duration
      ; enclosing_status
      ; producer
      ; corners
      ; metrics
      ; timing_goal
      ; evidence
      }
;;

let parse ~(registered : Asic.Run.t) ~execution_file ~execution_sha256 report =
  parse_for_attempt
    ~attempt_id:registered.reference.stream_id
    ~execution_file
    ~execution_sha256
    report
;;

let validate_cached ~execution_file (analysis : Wire.t) =
  let report =
    `Assoc
      [ "timing_analysis", Public.decode analysis.evidence
      ; "execution", `Assoc [ "status", `String analysis.enclosing_status ]
      ]
  in
  let parsed =
    parse_for_attempt
      ~validate_files:false
      ~attempt_id:analysis.target.attempt_id
      ~execution_file
      ~execution_sha256:analysis.target.execution_sha256
      report
    |> Option.value_exn
  in
  Public.require (Wire.equal parsed analysis) "Corrupt normalized timing analysis"
;;
