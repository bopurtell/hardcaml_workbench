open! Core
open Hardcaml_workbench_protocol
module Config = Hardcaml_workbench_project_integration.Asic_config

val invocation
  :  root:string
  -> environment:V1.Environment_selection.t
  -> string
  -> string list
  -> Dune_adapter.Invocation.t

val project
  :  Config.t
  -> root:string
  -> environment:V1.Environment_selection.t
  -> string list
  -> Dune_adapter.Invocation.t

val provider
  :  Config.t
  -> root:string
  -> environment:V1.Environment_selection.t
  -> string list
  -> Dune_adapter.Invocation.t

val selection_args : root:string -> Asic.Selection.t -> string list

val discover
  :  Config.t
  -> root:string
  -> environment:V1.Environment_selection.t
  -> Dune_adapter.Invocation.t

val describe
  :  Config.t
  -> root:string
  -> environment:V1.Environment_selection.t
  -> string
  -> Dune_adapter.Invocation.t

val plan
  :  Config.t
  -> root:string
  -> environment:V1.Environment_selection.t
  -> Asic.Selection.t
  -> Dune_adapter.Invocation.t

val metadata
  :  Config.t
  -> root:string
  -> environment:V1.Environment_selection.t
  -> Dune_adapter.Invocation.t

val resources
  : Config.t -> root:string -> environment:V1.Environment_selection.t
   -> kind:string -> target:string -> string list -> Dune_adapter.Invocation.t

val workloads
  : Config.t -> root:string -> environment:V1.Environment_selection.t
  -> Asic_workloads.Query.t -> Dune_adapter.Invocation.t

val run_prepared
  :  Config.t
  -> root:string
  -> environment:V1.Environment_selection.t
  -> prepared:Asic.Fresh.Prepared.t
  -> workspace:string
  -> Dune_adapter.Invocation.t

val inspect
  :  Config.t
  -> root:string
  -> environment:V1.Environment_selection.t
  -> Asic.Reference.t
  -> Dune_adapter.Invocation.t

val updates
  :  Config.t
  -> root:string
  -> environment:V1.Environment_selection.t
  -> Asic.Reference.t
  -> after:int
  -> Dune_adapter.Invocation.t

val report
  :  Config.t
  -> root:string
  -> environment:V1.Environment_selection.t
  -> string
  -> Dune_adapter.Invocation.t

val inspect_finalization
  :  Config.t
  -> root:string
  -> environment:V1.Environment_selection.t
  -> string
  -> Dune_adapter.Invocation.t

(** Public read-only rich inspection. [detail] carries row ID and expected INDEX digest.
    Without detail, [expected_analysis_digest] pins supplementary timing evidence. *)
val inspection
  :  ?expected_analysis_digest:string
  -> Config.t
  -> root:string
  -> environment:V1.Environment_selection.t
  -> execution_file:string
  -> domain:string
  -> stage:string
  -> detail:(string * string) option
  -> Dune_adapter.Invocation.t

(** Explicit inputs only. The configured results root owns the finalizations store; no
    current selection, configured support-tools default, or collateral is guessed. *)
val finalize
  :  Config.t
  -> root:string
  -> environment:V1.Environment_selection.t
  -> execution_file:string
  -> acceptance:Asic.Acceptance.t option
  -> Dune_adapter.Invocation.t
