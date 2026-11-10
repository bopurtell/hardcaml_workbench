(** The identity of one tool that participated in a job.

    Provenance records requested and actual tool versions separately, because a flow that
    asked for one version and ran another is not reproducible from the request alone. An
    unknown version is [None]; it is never a guess and never the requested version
    repeated back. *)

open! Core

type t =
  { tool : string (** [vivado], [yosys], [dune], the project driver, ... *)
  ; version : string option (** as reported by the tool, verbatim; [None] when unknown *)
  }
[@@deriving bin_io, compare, equal, hash, sexp]
