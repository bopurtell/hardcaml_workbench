open! Core
module Project_discovery = Hardcaml_workbench_setup.Project_discovery
module Simulation_setup = Hardcaml_workbench_setup.Simulation_setup

let program = "hardcaml-workbench-simulation-setup"

let report_error message =
  eprintf "%s: %s\n%!" program message;
  exit 1
;;

let root_param =
  let%map_open.Command root =
    flag
      "--root"
      (optional string)
      ~doc:"DIR explicit project root (must directly contain dune-project)"
  and discover_project =
    flag
      "--discover-project"
      no_arg
      ~doc:" use the nearest enclosing Dune project of the current directory"
  in
  fun () ->
    match
      Project_discovery.resolve
        ~explicit:root
        ~discover:discover_project
        ~explicit_flag:"--root"
        ~discover_flag:"--discover-project"
    with
    | Error message -> report_error message
    | Ok (None, _) ->
      report_error "choose the project root with --root DIR or --discover-project"
    | Ok (Some root, note) ->
      Option.iter note ~f:(eprintf "%s: %s\n%!" program);
      (match Project_discovery.explicit_root root with
       | Ok root -> root
       | Error message -> report_error message)
;;

let seconds_arg =
  Command.Arg_type.create (fun text ->
    match Int.of_string_opt text with
    | Some value -> value
    | None -> failwithf "expected an integer number of seconds, got %S" text ())
;;

let init_command =
  Command.basic
    ~summary:"Generate hardcaml-workbench-simulation.sexp from explicit provider inputs"
    ~readme:(fun () ->
      sprintf
        "Validates the inputs, previews the destination and every rendered field, then\n\
         publishes the file atomically. An existing file, directory or symlink at the\n\
         destination is always refused and left untouched; there is no overwrite flag.\n\
         --dry-run prints the same preview and writes nothing. Neither mode runs the\n\
         provider, a build tool or any test; use the check subcommand afterwards.\n\
         Repeat --provider-arg for each prefix argument, in order. Defaults: discovery\n\
         timeout %d s (1..60), run timeout %d s (1..86400).\n\n\
         %s"
        Simulation_setup.default_discovery_timeout_seconds
        Simulation_setup.default_run_timeout_seconds
        Simulation_setup.prerequisites)
    (let%map_open.Command root = root_param
     and provider_executable =
       flag
         "--provider-executable"
         (required string)
         ~doc:"/ABSOLUTE/PATH provider executable (built and installed by the project)"
     and provider_args =
       flag
         "--provider-arg"
         (listed string)
         ~doc:"ARG prefix argument placed before the protocol subcommand (repeatable)"
     and discovery_timeout_seconds =
       flag
         "--discovery-timeout-seconds"
         (optional seconds_arg)
         ~doc:"SECONDS discovery timeout, 1..60"
     and run_timeout_seconds =
       flag
         "--run-timeout-seconds"
         (optional seconds_arg)
         ~doc:"SECONDS run timeout, 1..86400"
     and dry_run =
       flag "--dry-run" no_arg ~doc:" print the preview without writing anything"
     in
     fun () ->
       let root = root () in
       match
         Simulation_setup.prepare
           ~root
           ~provider_executable
           ~provider_args
           ?discovery_timeout_seconds
           ?run_timeout_seconds
           ()
       with
       | Error message -> report_error message
       | Ok plan ->
         print_string (Simulation_setup.preview plan);
         if dry_run
         then
           print_string
             "Dry run: nothing was written; no provider, build tool or test was run.\n"
         else (
           match Simulation_setup.publish plan with
           | Error message -> report_error message
           | Ok () ->
             printf
               "Created %s\n\
                Next: build or install the provider if needed, then verify discovery with\n\
               \  %s check --root %s\n\
                No provider or test was run.\n"
               (Simulation_setup.path plan)
               program
               (Filename.quote (Simulation_setup.root plan))))
;;

let check_command =
  Command.basic
    ~summary:"Check simulation setup by running provider discovery once (no tests)"
    ~readme:(fun () ->
      "Reads hardcaml-workbench-simulation.sexp with the daemon's strict parser and runs\n\
       exactly EXEC [PROVIDER_ARGS...] discover --protocol-version 1 from the project\n\
       root, bounded by the configured discovery timeout. Reports one of: not\n\
       configured, invalid configuration, discovery failure (with the provider's\n\
       stderr), configured with zero suites, or the discovered suite/case catalog.\n\
       Exit status is 0 only when discovery produced a valid catalog (possibly empty).\n\
       No test is launched, nothing is written, and the daemon's cached catalog is not\n\
       changed.\n\n"
      ^ Simulation_setup.prerequisites)
    (let%map_open.Command root = root_param
     and environment =
       flag
         "--environment"
         (optional_with_default "inherited" string)
         ~doc:
           "inherited|opam:SWITCH provider command environment (default: inherited, i.e. \
            this process's environment)"
     in
     fun () ->
       let environment =
         match Simulation_setup.parse_environment environment with
         | Ok environment -> environment
         | Error message -> report_error message
       in
       let root = root () in
       let outcome = Simulation_setup.check ~root ~environment in
       print_string (Simulation_setup.Outcome.render outcome);
       Out_channel.flush stdout;
       if not (Simulation_setup.Outcome.ok outcome) then exit 1)
;;

let command =
  Command.group
    ~summary:"Set up FS2 simulation provider integration for an existing Dune project"
    ~readme:(fun () ->
      "init writes the provider configuration (preview first, never overwrites);\n\
       check runs provider discovery once and reports the catalog. Neither launches\n\
       tests.\n\n"
      ^ Simulation_setup.prerequisites)
    [ "init", init_command; "check", check_command ]
;;

let () = Command_unix.run command
