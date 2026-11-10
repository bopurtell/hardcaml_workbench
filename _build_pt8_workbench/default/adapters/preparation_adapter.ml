open! Core
open Hardcaml_workbench_protocol
module Config = Hardcaml_workbench_project_integration.Preparation_config

let build config ~root ~environment =
  Dune_adapter.invocation
    ~root
    environment
    [ "build"
    ; "-j6"
    ; "--root"
    ; root
    ; "--build-dir"
    ; Filename.concat root "_build"
    ; "--"
    ; config.Config.build_target
    ]
;;

let emit config ~root ~environment ~selection ~expected_plan_identity =
  let executable = Config.source_executable config ~root in
  let args =
    [ "flow"; "emit" ]
    @ Asic_adapter.selection_args ~root selection
    @ [ "--results-root"; config.Config.results_root ]
    @ Option.value_map expected_plan_identity ~default:[] ~f:(fun identity ->
      [ "--expected-plan-identity"; identity ])
  in
  Asic_adapter.invocation ~root ~environment executable args
;;
