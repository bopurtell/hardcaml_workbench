(** A reference to a backend's own immutable build identity.

    Some backends separate an immutable build description from repeated executions of it.
    One emitted ASIC build bundle, for example, can be executed many times. The Workbench
    references those identities; it does not replace them and does not mint a local
    substitute for an identity the backend already has. Re-running must not alter the
    original build's provenance.

    A backend that has no such identity — an FPGA invocation that both defines and
    performs the work — leaves the reference absent. *)

open! Core

type t =
  { backend : Backend_id.t
  ; id : string (** the backend's own identifier, carried verbatim *)
  ; label : string option (** a human-readable name, when the backend supplies one *)
  }
[@@deriving bin_io, compare, equal, sexp]
