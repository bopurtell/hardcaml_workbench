(** A reference to a backend's own execution identity.

    A run is one execution of a {!Build_ref}. Many runs can share a build, and the stages
    of one run are supervised as parent and child jobs over this shared identity. As with
    {!Build_ref}, the identifier belongs to the backend: reopening a stored result must
    not execute the flow again, and importing results must not invent a new run. *)

open! Core

type t =
  { backend : Backend_id.t
  ; id : string (** the backend's own identifier, carried verbatim *)
  ; build : Build_ref.t option
  (** the build this run executed, when the backend has one *)
  ; label : string option
  }
[@@deriving bin_io, compare, equal, sexp]
