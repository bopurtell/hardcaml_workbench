open! Core
open Hardcaml_workbench_protocol
module Config = Hardcaml_workbench_project_integration.Simulation_config

val discover
  :  Config.t
  -> root:string
  -> environment:V1.Environment_selection.t
  -> Dune_adapter.Invocation.t

val run
  :  Config.t
  -> root:string
  -> environment:V1.Environment_selection.t
  -> request_file:string
  -> events_file:string
  -> artifact_dir:string
  -> Dune_adapter.Invocation.t
