(** One required check with a pass, fail, or not-run result.

    Physical-verification and submission checks — DRC, LVS, antenna, harness precheck —
    are first-class results, not timing metrics. A check that did not run is [Not_run]
    with its reason; it is never a pass.

    An emitted build is not a completed run, a completed run is not timing closure, and
    timing closure is not physical verification. Keep the three separate; see
    {!Structured_result}. *)

open! Core

module Status = struct
  type t =
    | Passed
    | Failed of { reason : string }
    | Not_run of { reason : string }
  [@@deriving bin_io, compare, equal, sexp]
end

type t =
  { name : string
  ; status : Status.t
  ; tool : Tool_version.t
  ; stage : string
  ; source : Artifact_id.t option (** the report the result was read from *)
  }
[@@deriving bin_io, compare, equal, sexp]
