open! Core
open Hardcaml_workbench_protocol
open Simulation
module Codec = Hardcaml_workbench_project_integration.Simulation_protocol
module Reducer = Hardcaml_workbench_backend.Simulation_reducer

let () =
  let path = (Sys.get_argv ()).(1) in
  let lines = In_channel.read_lines path in
  let events =
    List.map lines ~f:(fun line -> Codec.parse_event_line line |> Or_error.ok_exn)
  in
  let id = (List.hd_exn events).attempt_id in
  let cases =
    List.filter_map events ~f:(fun event ->
      match event.payload with
      | Case_started id -> Some id
      | _ -> None)
  in
  let initial : Attempt.t =
    { id
    ; job = Job_id.of_string "independent-review"
    ; project_root = "/private-review"
    ; created_at = "0"
    ; parent = None
    ; captured =
        { selection =
            { suite = "review"; cases; seed = "0"; parameters = []; asic_inputs = [] }
        ; discovery_digest = "review"
        ; provider_executable = "/retained/provider"
        ; provider_args = []
        ; environment = Inherit_daemon
        }
    ; lifecycle = Running
    ; outcome = Unknown
    ; exit_code = None
    ; diagnostic = None
    ; progress = None
    ; cases =
        List.map cases ~f:(fun case_id ->
          { Case_result.case_id; status = Pending; message = None; progress = None })
    ; artifacts = []
    ; next_sequence = 0
    ; recent_events = []
    ; execution_timing = None
    }
  in
  let reducer = Reducer.create initial in
  List.iter lines ~f:(fun line ->
    Reducer.line reducer line ~artifact:(fun _ ->
      failwith "Unexpected cancellation artifact"));
  assert (Option.is_none reducer.attempt.diagnostic);
  assert (Option.is_none (Reducer.finish reducer ~cancelled:true (Some (Exited 130))));
  assert (Lifecycle.equal reducer.attempt.lifecycle Cancelled);
  assert (Outcome.equal reducer.attempt.outcome Incomplete);
  printf
    "PASS actual FS2 codec/reducer accepted retained cancellation prefix: %s (%d events)\n"
    path
    (List.length events)
;;
