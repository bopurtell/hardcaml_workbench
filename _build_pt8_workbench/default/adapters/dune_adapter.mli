(** Pure translation between Workbench Dune requests and native command invocations.

    This module does not start or supervise processes. The daemon executes the returned
    invocation and supplies completed command output to the parsing functions. *)

open! Core
open Hardcaml_workbench_protocol

module Invocation : sig
  type t =
    { executable : string
    ; argv : string list (** Complete argv, including [executable] as [argv.(0)]. *)
    ; cwd : string
    ; environment : V1.Environment_selection.t
    }
  [@@deriving compare, equal, sexp]
end

val command_prefix : V1.Environment_selection.t -> string list

val environment_summary
  :  V1.Environment_selection.t
  -> dune_version:string
  -> V1.Environment_summary.t

val invocation : root:string -> V1.Environment_selection.t -> string list -> Invocation.t

(** Probe the selected environment's Dune executable. *)
val probe_invocation : root:string -> V1.Environment_selection.t -> Invocation.t

(** Parse [dune --version] output and require Dune 3.22 or newer. *)
val parse_probe_output : string -> (string, string) Result.t

(** Inspect Dune's versioned workspace S-expression format. *)
val inspect_invocation : root:string -> V1.Environment_selection.t -> Invocation.t

val parse_workspace : string -> (V1.Dune_workspace.Inspection.t, string) Result.t

(** Translate a typed generic action without a shell. *)
val action_invocation
  :  ?build_alias:string
  -> ?test_alias:string
  -> root:string
  -> environment:V1.Environment_selection.t
  -> V1.Dune_action.t
  -> Invocation.t
