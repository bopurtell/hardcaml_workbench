(** One component of the execution environment a job ran in.

    Two runs of the same build in different environments are not the same run. A process
    design kit, a pinned tool virtual environment, harness support tooling, and an
    interpreter version are each a component here. Recording an environment is not
    provisioning one: provisioning stays explicit and external to the Workbench.

    Never record credentials or license secrets in [identity]. *)

open! Core

type t =
  { component : string (** [pdk], [flow_venv], [python], ... *)
  ; identity : string option
  (** a version, commit, or digest that distinguishes this environment from another;
      [None] when the component is known to be involved but cannot be identified *)
  }
[@@deriving bin_io, compare, equal, hash, sexp]
