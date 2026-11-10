(** An opened project: the Workbench session's view of an externally owned checkout.

    A project is session state associated with a validated external root. It is not a
    collection of source modules the Workbench owns, and opening one must not modify it.
    The project itself remains authoritative for design constructors and configuration;
    everything here is derived from what the project declares.

    A generic Dune project has no targets and no configurations. That is the normal state
    at integration level {!Project_integration.Level.Generic_dune}, so [targets] being
    empty means the project declared none, never that discovery failed. Discovery failures
    are reported through {!Project_integration.Component_status}. *)

open! Core

type t =
  { id : Project_id.t
  ; root : Project_root.t
  ; name : string
  (** the project's declared name, or the root's basename when it declares none *)
  ; integration : Project_integration.t
  ; targets : Target.t list
  ; configurations : Configuration.t list
  }
[@@deriving bin_io, compare, equal, sexp]

let target t id = List.find t.targets ~f:(fun target -> Target_id.equal target.id id)

let configurations_for_target t target_id =
  List.filter t.configurations ~f:(fun configuration ->
    Target_id.equal configuration.Configuration.target target_id)
;;
