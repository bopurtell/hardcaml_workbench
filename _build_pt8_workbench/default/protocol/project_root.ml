(** The external directory a project was opened from.

    A project root is an absolute path on the machine running the daemon. It appears in
    protocol values because it is how a user recognizes which checkout a project, job, or
    artifact belongs to, and because it is part of artifact provenance. It is not a
    handle: clients must not resolve it, read it, or derive project-local paths from it.
    The daemon validates the root when the project is opened and resolves every
    project-local path relative to the validated root itself.

    This type carries no validation of its own. Validation belongs to the backend that
    opens the project, and a value that reaches a client has already been validated. *)

open! Core

type t = { path : string } [@@deriving bin_io, compare, equal, hash, sexp]

let of_absolute_path path = { path }
let to_absolute_path t = t.path

(** The last component of the root, which is what the UI shows when a project has no
    declared name. *)
let basename t = Filename.basename t.path
