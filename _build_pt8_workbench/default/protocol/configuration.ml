(** One build configuration a project offers for a target.

    Configurations are discovered through the project, which decides what is valid; the
    Workbench selects among them and records which one produced a job or artifact. The
    settings a configuration carries are part of the versioned project-driver contract and
    are added in milestone 1C, so this type identifies and describes a configuration
    without reproducing its contents. *)

open! Core

type t =
  { id : Configuration_id.t
  ; target : Target_id.t
  ; name : string
  ; description : string option
  }
[@@deriving bin_io, compare, equal, sexp]
