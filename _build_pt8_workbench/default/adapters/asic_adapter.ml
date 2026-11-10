open! Core
open Hardcaml_workbench_protocol
module Config = Hardcaml_workbench_project_integration.Asic_config

let invocation ~root ~environment executable args : Dune_adapter.Invocation.t =
  let argv = Dune_adapter.command_prefix environment @ (executable :: args) in
  { executable = List.hd_exn argv; argv; cwd = root; environment }
;;

let project config ~root ~environment args =
  invocation ~root ~environment config.Config.project_executable ("flow" :: args)
;;

let provider config ~root ~environment args =
  invocation ~root ~environment config.Config.provider_executable args
;;

let discover config ~root ~environment =
  project config ~root ~environment [ "list"; "--json" ]
;;

let describe config ~root ~environment flow =
  project config ~root ~environment [ "describe"; "--flow"; flow; "--json" ]
;;

let selection_args ~root (s : Asic.Selection.t) =
  [ "--flow"
  ; s.flow
  ; "--profile"
  ; s.profile
  ; "--endpoint"
  ; s.endpoint
  ; "--source-root"
  ; root
  ; "--json"
  ]
  @ List.concat_map s.assignments ~f:(fun value -> [ "--set"; value ])
;;

let plan config ~root ~environment selection =
  project config ~root ~environment ("plan" :: selection_args ~root selection)
;;

let metadata config ~root ~environment =
  provider config ~root ~environment [ "--version"; "--json" ]
;;

let resources config ~root ~environment ~kind ~target args =
  provider config ~root ~environment
    ([ "resource-inspect"; target; "--kind"; kind; "--json" ] @ args)
;;

let workloads config ~root ~environment (query : Asic_workloads.Query.t) =
  let target = function
    | Asic_workloads.Target.Bundle path -> "bundle", path
    | Coarse_run path -> "coarse_run", path
    | Execution path -> "execution", path
  in
  let args =
    match query with
    | Inspect { result; _ } -> [ "workload-inspect"; result; "--json" ]
    | Compare q ->
      let lk, lp = target q.left and rk, rp = target q.right in
      let axis = match q.axis with
        | Hardware -> "hardware" | Resource_policy -> "resource_policy"
        | Flow_configuration -> "flow_configuration" | Descriptive -> "descriptive"
      in
      [ "compare"; "--left-kind"; lk; "--left"; lp; "--right-kind"; rk
      ; "--right"; rp; "--axis"; axis; "--json" ]
      @ Option.value_map q.left_workload ~default:[] ~f:(fun p -> ["--left-workload";p])
      @ Option.value_map q.right_workload ~default:[] ~f:(fun p -> ["--right-workload";p])
  in
  provider config ~root ~environment args
;;

let run_prepared config ~root ~environment ~(prepared : Asic.Fresh.Prepared.t) ~workspace =
  let resolved value suffix =
    Option.value value ~default:(Filename.concat config.Config.toolchain suffix)
  in
  provider
    config
    ~root
    ~environment
    ([ "stages"
     ; prepared.bundle_directory
     ; "--methodology-plan"
     ; prepared.methodology_plan_path
     ; "--expected-plan-identity"
     ; prepared.plan_identity
     ; "--workspace"
     ; workspace
     ; "--checkpoint-store"
     ; Filename.concat workspace "checkpoints"
     ; "--support-tools"
     ; resolved config.support_tools "tt"
     ; "--pdk-root"
     ; resolved config.pdk_root "pdk"
     ; "--python"
     ; resolved config.python ".venv/bin/python"
     ; "--json"
     ]
     @ Option.value_map config.stage_timeout_seconds ~default:[] ~f:(fun n ->
       [ "--timeout"; Int.to_string n ]))
;;

let inspect config ~root ~environment (r : Asic.Reference.t) =
  provider config ~root ~environment [ "observation"; "inspect"; r.attempt; "--json" ]
;;

let updates config ~root ~environment (r : Asic.Reference.t) ~after =
  provider
    config
    ~root
    ~environment
    [ "observation"
    ; "read-updates"
    ; r.attempt
    ; "--stream-id"
    ; r.stream_id
    ; "--after"
    ; Int.to_string after
    ; "--json"
    ]
;;

let report config ~root ~environment execution_file =
  provider config ~root ~environment [ "report"; execution_file; "--json" ]
;;

let inspection
  ?expected_analysis_digest
  config
  ~root
  ~environment
  ~execution_file
  ~domain
  ~stage
  ~detail
  =
  provider
    config
    ~root
    ~environment
    ([ "inspect"; execution_file; "--domain"; domain; "--stage"; stage; "--json" ]
     @ (if Option.is_some detail
        then []
        else
          Option.value_map expected_analysis_digest ~default:[] ~f:(fun digest ->
            [ "--expected-digest"; digest ]))
     @ Option.value_map detail ~default:[] ~f:(fun (row_id, digest) ->
       [ "--row-id"; row_id; "--expected-digest"; digest ]))
;;

let inspect_finalization config ~root ~environment attempt =
  provider config ~root ~environment [ "finalization-inspect"; attempt; "--json" ]
;;

let finalize config ~root ~environment ~execution_file ~acceptance =
  provider
    config
    ~root
    ~environment
    ([ "finalize"
     ; execution_file
     ; "--operation-store"
     ; Filename.concat config.Config.results_root "finalizations"
     ; "--json"
     ]
     @ Option.value_map acceptance ~default:[] ~f:(fun (a : Asic.Acceptance.t) ->
       [ "--accept"
       ; "--support-tools"
       ; a.support_tools
       ; "--precheck-python"
       ; a.precheck_python
       ; "--testbench"
       ; a.testbench
       ; "--testbench-top"
       ; a.testbench_top
       ; "--replay-trace"
       ; a.replay_trace
       ]))
;;
