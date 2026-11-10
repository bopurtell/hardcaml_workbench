(** A namespaced, backend-declared fact about a target.

    Target facts are extensible and backend-tagged rather than a fixed record. An FPGA
    part number is one backend's fact, not a field every target has; an ASIC target
    instead carries harness, technology, and resolved geometry facts, and a
    simulation-only target may carry neither. Adding a backend must not revise this
    schema, so one backend's vocabulary is never promoted into the shared target type.

    Facts are derived from the opened project, which remains authoritative. They are a
    view of the project's own declarations, not a second independently edited design
    description, and a client must not treat editing a fact as configuring a target. *)

open! Core

module Value = struct
  type t =
    | String of string
    | Int of int
    | Float of float
    | Bool of bool
    | Sexp of Sexp.t
    (** Structured facts a backend needs to carry whole. The UI shows these generically;
        only the declaring backend interprets them. *)
  [@@deriving bin_io, compare, equal, hash, sexp]
end

type t =
  { namespace : string (** the declaring backend or tool: [vivado], [asic], [tt], ... *)
  ; name : string (** [part], [technology], [harness], ... *)
  ; value : Value.t
  ; display : string option
  (** how the declaring backend wants the value shown, when the generic rendering of
      [value] would be misleading *)
  }
[@@deriving bin_io, compare, equal, hash, sexp]
