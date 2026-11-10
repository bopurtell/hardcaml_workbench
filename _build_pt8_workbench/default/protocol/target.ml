(** One hardware top level a project declares, plus the backend that realizes it.

    Targets come from project integration: a generic Dune project has none, and having
    none is a normal state rather than a degraded one. Nothing here requires a target to
    have an FPGA part or to produce a bitstream. Backend-specific facts live in
    {!Target_fact}. *)

open! Core

module Clock_constraint = struct
  (** A clock the target declares and the period it is constrained to.

      The period is optional because a target can declare a clock domain before any timing
      objective exists for it. A missing period is unknown, not unconstrained. *)
  type t =
    { name : string
    ; period_ns : float option
    ; description : string option
    }
  [@@deriving bin_io, compare, equal, sexp]
end

type t =
  { id : Target_id.t
  ; name : string
  ; top : string (** the project's own name for the top-level module *)
  ; backend : Backend_id.t
  ; clocks : Clock_constraint.t list
  ; facts : Target_fact.t list
  }
[@@deriving bin_io, compare, equal, sexp]

(** [fact t ~namespace ~name] is the declared fact, or [None] when the backend did not
    declare it. Callers must render [None] as unknown rather than substituting a default. *)
let fact t ~namespace ~name =
  List.find t.facts ~f:(fun (fact : Target_fact.t) ->
    String.equal fact.namespace namespace && String.equal fact.name name)
;;
