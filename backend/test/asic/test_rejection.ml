open! Core
open Hardcaml_workbench_protocol
module Rejection = Hardcaml_workbench_backend.Asic_rejection
module Public = Hardcaml_workbench_backend.Asic_public

let require condition message = if not condition then failwith message
let stream = "9e6e0de93bd1497c88f502aa9b2d1c23"
let identity = String.make 64 'a'
let run : Asic.Run.t =
  { run = { backend = Backend_id.of_string "asic"; id = stream; build = None; label = None }
  ; reference = { attempt = "/fixture/attempt"; stream_id = stream }
  ; selection = None; cursor = 0; status = "allocated"; execution_file = None
  ; error = None; stages = []; execution_timing = None
  }
;;

let allocation =
  "allocated", `Assoc [ "request", `Assoc
    [ "expected_plan_identity", `String identity
    ; "methodology_launch", `Assoc
        [ "attempt_id", `String stream; "expected_plan_identity", `String identity ] ] ]
;;
let planned =
  "planned", `Assoc [ "plan", `Assoc
    [ "schema_version", `Int 4; "initial_boundary", `Null
    ; "stages", `List (List.map [ "synthesis"; "floorplan"; "placement" ] ~f:(fun s -> `String s)) ] ]
;;
let outcome status exit =
  "outcome", `Assoc [ "status", `String status; "exit_code", `Int exit; "error", `String "original rejection" ]
;;
let updates events =
  `Assoc [ "contract", `String "hardcaml-asic.stage-observation"; "schema_version", `Int 2
         ; "stream_id", `String stream; "after", `Int 0; "cursor", `Int (List.length events)
         ; "events", `List (List.mapi events ~f:(fun i (event, data) ->
             `Assoc [ "contract", `String "hardcaml-asic.stage-observation"; "schema_version", `Int 2
                    ; "stream_id", `String stream; "sequence", `Int (i + 1)
                    ; "event", `String event; "data", data ])) ]
;;

let () =
  let events = [ allocation; planned; outcome "failed" 2 ] in
  let project ?(run = run) ?(expected = Some identity) events =
    let updates = updates events in
    ignore (Public.updates run updates : int);
    Rejection.from_updates run ~expected_plan:expected updates
  in
  let rejected = Option.value_exn (project events) in
  require (Rejection.is_rejection rejected) "Definitive rejection not recognized";
  require (String.equal rejected.status "failed") "Rejection not failed";
  require (Option.is_some rejected.error) "Original failure missing";
  require
    (Option.is_some
       (project ~run:{ run with status = "observation_unavailable"; error = Some "old inspect failure" } events))
    "Historical unavailable observation did not recover";
  List.iter
    [ [ allocation; planned ]
    ; [ planned; outcome "failed" 2 ]
    ; [ allocation; outcome "failed" 2 ]
    ; [ allocation; planned; outcome "completed" 0 ]
    ; [ allocation; planned; outcome "interrupted" 130 ]
    ; [ allocation; planned; outcome "failed" 0 ]
    ; [ allocation; planned; "prepared", `Assoc [ "runtime_record", `Null ]; outcome "failed" 2 ]
    ; [ allocation; planned; "started", `Assoc []; outcome "failed" 2 ]
    ; [ allocation; planned; outcome "failed" 2; "started", `Assoc [] ]
    ]
    ~f:(fun events -> require (Option.is_none (project events)) "Uncertain execution inferred as admission failure");
  require (Option.is_none (project ~expected:None events)) "Unfenced plan accepted";
  require (Option.is_none (project ~expected:(Some (String.make 64 'b')) events)) "Wrong plan accepted";
  require (Option.is_none (project ~run:{ run with execution_file = Some "/execution.json" } events))
    "Execution evidence ignored";
  require (Option.is_none (Rejection.from_updates { run with cursor = 1 } ~expected_plan:(Some identity) (updates events)))
    "Partial journal inferred as rejection";
  printf "Pre-execution rejection controls passed\n"
;;
