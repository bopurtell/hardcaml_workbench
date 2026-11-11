open! Core
open Hardcaml_workbench_protocol
module Public = Asic_public

(* Only a complete, provider-validated journal prefix proves rejection before
   execution. EOF, stderr, a missing preflight sidecar, or a suffix cannot. The
   provider's Prepared event is the transition into execution, even when its
   runtime_record is null. Never accept that event on this path. *)
let from_updates (run : Asic.Run.t) ~expected_plan journal =
  let open Public in
  let events = list (field "events" journal) in
  let names = List.map events ~f:(fun e -> text (field "event" e)) in
  if run.cursor <> 0
     || not (List.equal String.equal names [ "allocated"; "planned"; "outcome" ])
     || integer (field "cursor" journal) <> 3
     || not (List.for_alli events ~f:(fun i e -> integer (field "sequence" e) = i + 1))
  then None
  else (
    let allocation = field "data" (List.nth_exn events 0) in
    let request = field "request" allocation in
    let launch = field "methodology_launch" request in
    let outcome = field "data" (List.nth_exn events 2) in
    let plan = field "plan" (field "data" (List.nth_exn events 1)) in
    let identity_matches =
      Option.value_map expected_plan ~default:false ~f:(fun expected ->
        Poly.equal (field "expected_plan_identity" launch) (`String expected)
        && Poly.equal (field "expected_plan_identity" request) (`String expected))
    in
    if not identity_matches
       || not (Poly.equal (field "attempt_id" launch) (`String run.reference.stream_id))
       || not (Poly.equal (field "status" outcome) (`String "failed"))
       || integer (field "exit_code" outcome) = 0
       || Option.is_some run.execution_file
    then None
    else (
      let error =
        sprintf
          "Provider admission failed before execution (exit %d): %s"
          (integer (field "exit_code" outcome))
          (text (field "error" outcome))
      in
      require (String.length error <= 4096) "Rejected admission error exceeds budget";
      let stages =
        observation_stages
          (`Assoc
            [ "stream_id", `String run.reference.stream_id
            ; "state", `Assoc
                [ "attempt_id", `String run.reference.stream_id
                ; "plan", plan
                ; "occurrences", `List []
                ]
            ])
        |> List.map ~f:(fun stage ->
          if stage.Asic.Stage.requested
          then { stage with status = Skipped; reason = Some error }
          else stage)
      in
      require (not (List.is_empty stages)) "Missing rejected stage recipe";
      validate_stages stages;
      Some { run with cursor = 3; status = "failed"; error = Some error; stages
                    ; execution_timing = None }))
;;

let is_rejection (run : Asic.Run.t) =
  String.equal run.status "failed"
  && Option.is_none run.execution_file
  && Option.value_map run.error ~default:false
       ~f:(String.is_prefix ~prefix:"Provider admission failed before execution (")
;;
