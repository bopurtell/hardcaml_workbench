(** One separately runnable stage of a flow.

    Some flows are a sequence of stages rather than one invocation: an ASIC flow can emit,
    preflight, run synthesis or implementation, postcheck, collect, and report, and the
    user must be able to run only the later stages against an existing run. Stages are
    named by the backend rather than enumerated here, because no fixed stage sequence fits
    every backend.

    Requested and completed are recorded separately and must stay distinguishable. A
    completed earlier stage is not evidence that a later stage passed, and a stage that
    was never requested is not a stage that failed. *)

open! Core

module Status = struct
  type t =
    | Not_run
    | Running
    | Completed
    | Failed of { reason : string }
    | Skipped of { reason : string }
  [@@deriving bin_io, compare, equal, sexp]

  let is_completed = function
    | Completed -> true
    | Not_run | Running | Failed _ | Skipped _ -> false
  ;;
end

type t =
  { name : string
  ; requested : bool
  ; status : Status.t
  }
[@@deriving bin_io, compare, equal, sexp]
