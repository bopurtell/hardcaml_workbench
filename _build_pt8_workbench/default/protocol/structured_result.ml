(** The structured outcome of a job, with its three categories kept apart.

    - [completion] is which stages the tool actually finished.
    - [goals] is the timing and resource objectives, measured.
    - [verification] is the required checks: passed, failed, or not run.

    These answer different questions and must never be displayed as one another. A flow
    that completed every stage may still have missed its timing goal, and a design that
    met timing may still fail physical verification. A client that collapses them into one
    status is reporting something the tools did not say. *)

open! Core

type t =
  { completion : Stage.t list
  ; goals : Metric.t list
  ; verification : Check.t list
  }
[@@deriving bin_io, compare, equal, sexp]

let empty = { completion = []; goals = []; verification = [] }

(** Whether every requested stage completed. This is completion only: it says nothing
    about goals or verification. *)
let all_requested_stages_completed t =
  List.for_all t.completion ~f:(fun (stage : Stage.t) ->
    (not stage.requested) || Stage.Status.is_completed stage.status)
;;
