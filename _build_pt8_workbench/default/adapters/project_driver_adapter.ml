open! Core
open Hardcaml_workbench_protocol
module Driver_protocol = Hardcaml_workbench_project_integration.Driver_protocol

let describe_invocation ~root ~environment ~driver =
  Dune_adapter.invocation
    ~root
    environment
    [ "exec"
    ; "-j20"
    ; "--root"
    ; root
    ; "--no-buffer"
    ; driver
    ; "--"
    ; "describe"
    ; "--protocol-version"
    ; Int.to_string Driver_protocol.version
    ]
;;

let generate_rtl_invocation ~root ~environment ~driver ~target ~configuration ~output_dir =
  Dune_adapter.invocation
    ~root
    environment
    [ "exec"
    ; "-j20"
    ; "--root"
    ; root
    ; "--no-buffer"
    ; driver
    ; "--"
    ; "generate-rtl"
    ; "--protocol-version"
    ; Int.to_string Driver_protocol.version
    ; "--target"
    ; target
    ; "--configuration"
    ; configuration
    ; "--output-dir"
    ; output_dir
    ]
;;

let target_id project key =
  Target_id.of_string (Project_id.to_string project ^ "/target/" ^ key)
;;

let configuration_id project key =
  Configuration_id.of_string (Project_id.to_string project ^ "/configuration/" ^ key)
;;

let map_describe ~project (response : Driver_protocol.Describe_response.t) =
  let targets =
    List.map response.targets ~f:(fun target ->
      { Target.id = target_id project target.key
      ; name = target.name
      ; top = target.top
      ; backend = Backend_id.of_string target.backend
      ; clocks =
          List.map target.clocks ~f:(fun clock ->
            { Target.Clock_constraint.name = clock.name
            ; period_ns = clock.period_ns
            ; description = clock.description
            })
      ; facts =
          List.map target.facts ~f:(fun fact ->
            { Target_fact.namespace = fact.namespace
            ; name = fact.name
            ; value = Target_fact.Value.String fact.value
            ; display = fact.display
            })
      })
  in
  let configurations =
    List.map response.configurations ~f:(fun config ->
      { Configuration.id = configuration_id project config.key
      ; target = target_id project config.target
      ; name = config.name
      ; description = config.description
      })
  in
  targets, configurations
;;

let map_build_ref (reference : Driver_protocol.Backend_ref.t) : Build_ref.t =
  { backend = Backend_id.of_string reference.backend
  ; id = reference.id
  ; label = reference.label
  }
;;

let map_run_ref (reference : Driver_protocol.Run_ref.t) : Run_ref.t =
  { backend = Backend_id.of_string reference.backend
  ; id = reference.id
  ; build = Option.map reference.build ~f:map_build_ref
  ; label = reference.label
  }
;;
