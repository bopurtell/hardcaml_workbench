open! Core

(** Generic project execution views. Attempts are the supervisor's jobs, not backend runs
    or a second execution identity. These projections preserve input order and all job
    metadata; they neither infer results nor manufacture build/run references. *)
let is_test (job : Job.t) =
  String.equal job.kind.namespace "dune" && String.equal job.kind.name "test"
;;

let is_generic (job : Job.t) =
  String.equal job.kind.namespace "dune"
  && (String.equal job.kind.name "build" || String.equal job.kind.name "test")
;;

type t =
  { project : Project_id.t
  ; attempts : Job.t list
  ; tests : Job.t list
  }
[@@deriving equal, sexp]

(** [tests] is the test-only subset of [attempts], scoped to exactly [project]. *)
let project_snapshot ~project jobs =
  let attempts =
    List.filter jobs ~f:(fun (job : Job.t) ->
      Project_id.equal job.project project && is_generic job)
  in
  { project; attempts; tests = List.filter attempts ~f:is_test }
;;
