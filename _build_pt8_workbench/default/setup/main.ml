open! Core
module Initialization = Hardcaml_workbench_setup.Initialization
module Project_discovery = Hardcaml_workbench_setup.Project_discovery

let report_error message =
  eprintf "hardcaml-workbench-init: %s\n%!" message;
  exit 1
;;

let command =
  Command.basic
    ~summary:"Initialize Hardcaml Workbench in an existing Dune directory"
    ~readme:(fun () ->
      "Creates only hardcaml-workbench.sexp, without replacing existing files.\n\
       Choose the root with exactly one of --root or --discover-project.\n\
       --root ROOT must directly contain dune-project; relative roots use the current\n\
       directory and no ancestor search is performed. --discover-project instead selects\n\
       the nearest ancestor of the current directory (symlinks resolved first) that\n\
       contains a regular dune-project file, and reports the selected root on stderr.\n\
       The project name defaults to the root's directory name. No build, git, driver or\n\
       provider execution is performed. Driver and aliases are saved references; their\n\
       targets do not need to exist yet.")
    (let%map_open.Command root =
       flag "--root" (optional string) ~doc:"DIR explicit existing Dune directory"
     and discover_project =
       flag
         "--discover-project"
         no_arg
         ~doc:" use the nearest enclosing Dune project of the current directory"
     and project_name =
       flag "--project-name" (optional string) ~doc:"NAME project display name"
     and driver =
       flag "--driver" (optional string) ~doc:"./PATH optional Dune driver executable"
     and build_alias =
       flag "--build-alias" (optional string) ~doc:"ALIAS Dune build alias (default @all)"
     and test_alias =
       flag
         "--test-alias"
         (optional string)
         ~doc:"ALIAS Dune test alias (default @runtest)"
     and dry_run =
       flag
         "--dry-run"
         no_arg
         ~doc:" validate and print the manifest without writing files"
     in
     fun () ->
       let root =
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
           Option.iter note ~f:(eprintf "hardcaml-workbench-init: %s\n%!");
           root
       in
       match
         Initialization.prepare ~root ?project_name ?driver ?build_alias ?test_alias ()
       with
       | Error message -> report_error message
       | Ok plan ->
         if dry_run
         then printf "%s%!" (Initialization.contents plan)
         else (
           match Initialization.publish plan with
           | Error message -> report_error message
           | Ok () -> printf "Created %s\n%!" (Initialization.path plan)))
;;

let () = Command_unix.run command
