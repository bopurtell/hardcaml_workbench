open! Core
open Hardcaml_workbench_protocol

(** Simulation provider setup assistance (WB-039).

    Generates the FS2 opt-in root file [hardcaml-workbench-simulation.sexp] from explicit
    provider inputs, and checks a configured project by running provider discovery once.
    Provider executables and their build instructions remain project-owned: nothing here
    builds, installs or searches [PATH] for a provider, and no test is ever launched. *)

module Config = Hardcaml_workbench_project_integration.Simulation_config

val default_discovery_timeout_seconds : int
val default_run_timeout_seconds : int

(** Human explanation of provider prerequisites, shared by help text and output. *)
val prerequisites : string

(** {1 Configuration generation} *)

(** A validated configuration plan. Preparing one only reads filesystem metadata. *)
type t

(** [root] is validated exactly as by the initializer (it must directly contain a regular
    [dune-project]). [provider_executable] must be absolute; it need not exist yet, but
    its current state is reported by {!preview}. The rendered file is required to
    round-trip through the strict {!Config.parse_string} to an equal value. Any existing
    entry at the destination, including a dangling symlink, is an error. *)
val prepare
  :  root:string
  -> provider_executable:string
  -> provider_args:string list
  -> ?discovery_timeout_seconds:int
  -> ?run_timeout_seconds:int
  -> unit
  -> (t, string) Result.t

val root : t -> string
val path : t -> string
val config : t -> Config.t

(** Exactly the bytes {!publish} writes. *)
val contents : t -> string

(** Destination, each rendered field, the provider executable's current state and the
    rendered file. *)
val preview : t -> string

(** No-clobber atomic publication; see {!No_clobber.publish}. Invokes no provider. *)
val publish : t -> (unit, string) Result.t

(** {1 Discovery check} *)

val parse_environment : string -> (V1.Environment_selection.t, string) Result.t

module Outcome : sig
  type discovery_run =
    { argv : string list
    ; cwd : string
    ; stderr : string (** Bounded tail of the provider's stderr. *)
    }

  type t =
    | Not_configured of { path : string }
    | Invalid_configuration of
        { path : string
        ; error : string
        }
    | Discovery_failed of
        { run : discovery_run
        ; reason : string
        }
    | Configured_empty of { run : discovery_run }
    | Discovered of
        { run : discovery_run
        ; discovery : Simulation.Discovery.t
        }

  (** Whether the configured provider produced a valid catalog (possibly empty). *)
  val ok : t -> bool

  val render : t -> string
end

(** Read the canonical [root]'s configuration with the daemon's restrictions (regular
    file, not a symlink, at most 16 KiB, strict parser), then run exactly
    [EXEC [ARGS...] discover --protocol-version 1] from [root] with the environment's
    command prefix, the configured discovery timeout and the 1 MiB stdout bound, and
    validate the output with the daemon's discovery decoder. The provider's process group
    is killed on timeout or overflow. Never runs tests or builds. *)
val check : root:string -> environment:V1.Environment_selection.t -> Outcome.t
