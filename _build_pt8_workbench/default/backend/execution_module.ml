open! Core
open! Async
open Hardcaml_workbench_protocol

type t = { service : Service.t }

let of_service service = { service }

let snapshot t request ~project =
  Result.bind (Service.snapshot t.service request) ~f:(fun snapshot ->
    if List.exists snapshot.projects ~f:(fun (candidate : Project.t) ->
         Project_id.equal candidate.id project)
    then Ok (Execution.project_snapshot ~project snapshot.jobs)
    else Error (V1.Error.create Not_found "project is not open"))
;;

let submit t request = Service.submit_job t.service request
let read_log t request = Service.read_log t.service request
let cancel t request = Service.cancel_job t.service request
