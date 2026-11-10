open! Core
open Hardcaml_workbench_protocol
open Simulation
module Codec = Hardcaml_workbench_project_integration.Simulation_protocol

type t =
  { mutable attempt : Attempt.t
  ; mutable started : bool
  ; mutable finished : Outcome.t option
  ; artifact_ids : String.Hash_set.t
  }

let create attempt =
  { attempt
  ; started = false
  ; finished = None
  ; artifact_ids = Hash_set.create (module String)
  }
;;

let fail t message =
  if Option.is_none t.attempt.diagnostic
  then
    t.attempt
    <- { t.attempt with diagnostic = Some (String.prefix message Limits.string_bytes) }
;;

let require = Simulation_files.require

let case t id =
  List.find_exn t.attempt.cases ~f:(fun case -> String.equal case.Case_result.case_id id)
;;

let update_case t result =
  t.attempt
  <- { t.attempt with
       cases =
         List.map t.attempt.cases ~f:(fun old ->
           if String.equal old.case_id result.Case_result.case_id then result else old)
     }
;;

let check_progress (old : Progress.t option) (progress : Progress.t) =
  Option.iter old ~f:(fun old ->
    require (String.equal old.unit_ progress.unit_) "Progress unit changed";
    require (progress.completed >= old.completed) "Progress decreased";
    Option.iter old.total ~f:(fun total ->
      require
        (Option.equal Int.equal progress.total (Some total))
        "Progress total changed"))
;;

let accept t (event : Provider.Event.t) ~artifact =
  let a = t.attempt in
  require (Option.is_none a.diagnostic) "Stream already invalid";
  require (String.equal event.attempt_id a.id) "Wrong event attempt identity";
  require (event.sequence = a.next_sequence) "Event sequence gap or duplicate";
  require (a.next_sequence < Limits.events) "Too many simulation events";
  require (Option.is_none t.finished) "Event after Finished";
  (match event.payload with
   | Started ->
     require ((not t.started) && event.sequence = 0) "Duplicate or misplaced Started";
     t.started <- true
   | payload ->
     require t.started "First event must be Started";
     (match payload with
      | Started -> assert false
      | Case_started id ->
        let result = case t id in
        require (Case_status.equal result.status Pending) "Case started twice";
        update_case t { result with status = Running }
      | Case_finished { case_id; status; message } ->
        let result = case t case_id in
        require
          (Case_status.equal result.status Running)
          "Case finished without active start";
        update_case t { result with status; message }
      | Progress progress ->
        (match progress.case_id with
         | None ->
           check_progress t.attempt.progress progress;
           t.attempt <- { t.attempt with progress = Some progress }
         | Some id ->
           let result = case t id in
           require (Case_status.equal result.status Running) "Progress for inactive case";
           check_progress result.progress progress;
           update_case t { result with progress = Some progress })
      | Artifact declaration ->
        require (Hash_set.length t.artifact_ids < Limits.artifacts) "Too many artifacts";
        require (not (Hash_set.mem t.artifact_ids declaration.id)) "Duplicate artifact ID";
        Option.iter declaration.case_id ~f:(fun id ->
          require
            (not (Case_status.equal (case t id).status Pending))
            "Artifact for unstarted case");
        let captured = artifact declaration in
        Hash_set.add t.artifact_ids declaration.id;
        t.attempt <- { t.attempt with artifacts = t.attempt.artifacts @ [ captured ] }
      | Finished outcome ->
        require
          (List.for_all t.attempt.cases ~f:(fun result ->
             match result.status with
             | Passed | Failed | Skipped -> true
             | _ -> false))
          "Finished with unfinished cases";
        let failed =
          List.exists t.attempt.cases ~f:(fun result ->
            Case_status.equal result.status Failed)
        in
        require
          (Bool.equal failed (Outcome.equal outcome Failed))
          "Finished outcome contradicts case results";
        t.finished <- Some outcome));
  t.attempt
  <- { t.attempt with
       next_sequence = a.next_sequence + 1
     ; recent_events =
         List.drop
           (a.recent_events @ [ event ])
           (Int.max 0 (List.length a.recent_events + 1 - Limits.retained_events))
     }
;;

let line t text ~artifact =
  if Option.is_none t.attempt.diagnostic
  then (
    match
      Or_error.bind (Codec.parse_event_line text) ~f:(fun event ->
        Or_error.try_with (fun () -> accept t event ~artifact))
    with
    | Ok () -> ()
    | Error error -> fail t (Error.to_string_hum error))
;;

let finish t ~cancelled status =
  let exit_code =
    match status with
    | Some (Job.Exit_status.Exited code) -> Some code
    | _ -> None
  in
  if not cancelled
  then (
    if not (Option.equal Int.equal exit_code (Some 0))
    then fail t "Provider did not exit successfully";
    if Option.is_none t.finished then fail t "Missing Finished event");
  let outcome =
    if cancelled || Option.is_some t.attempt.diagnostic
    then Outcome.Incomplete
    else Option.value t.finished ~default:Outcome.Incomplete
  in
  t.attempt
  <- { t.attempt with
       lifecycle = (if cancelled then Cancelled else Finished)
     ; outcome
     ; exit_code
     ; cases =
         List.map t.attempt.cases ~f:(fun case ->
           match case.status with
           | Pending | Running -> { case with status = Incomplete }
           | _ -> case)
     };
  t.attempt.diagnostic
;;
