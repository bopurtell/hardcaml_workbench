open! Core
module Config = Hardcaml_workbench_project_integration.Simulation_config

let invocation (config : Config.t) ~root ~environment args : Dune_adapter.Invocation.t =
  let argv =
    Dune_adapter.command_prefix environment
    @ (config.provider_executable :: config.provider_args)
    @ args
  in
  { executable = List.hd_exn argv; argv; cwd = root; environment }
;;

let discover config ~root ~environment =
  invocation config ~root ~environment [ "discover"; "--protocol-version"; "1" ]
;;

let run config ~root ~environment ~request_file ~events_file ~artifact_dir =
  invocation
    config
    ~root
    ~environment
    [ "run"
    ; "--protocol-version"
    ; "1"
    ; "--request"
    ; request_file
    ; "--events"
    ; events_file
    ; "--artifact-dir"
    ; artifact_dir
    ]
;;
