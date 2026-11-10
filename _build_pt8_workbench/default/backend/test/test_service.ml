open! Core
open! Async
open Hardcaml_workbench_protocol
module Adapter = Hardcaml_workbench_adapters.Dune_adapter
module Service = Hardcaml_workbench_backend.Service
module Integration = Hardcaml_workbench_project_integration

let instance_id = V1.Daemon_instance_id.of_string "service-test"
let short_timeout = Time_float.Span.of_sec 4.
let fail message = raise_s [%message message]
let require condition message = if not condition then fail message

let ok = function
  | Ok value -> value
  | Error error -> raise_s [%message "service error" (error : V1.Error.t)]
;;

let shell root script : Adapter.Invocation.t =
  { executable = "/bin/sh"
  ; argv = [ "/bin/sh"; "-c"; script ]
  ; cwd = root
  ; environment = Inherit_daemon
  }
;;

let missing root : Adapter.Invocation.t =
  { executable = Filename.concat root "does-not-exist"
  ; argv = [ "does-not-exist" ]
  ; cwd = root
  ; environment = Inherit_daemon
  }
;;

let rec remove_tree path =
  match Sys_unix.file_exists ~follow_symlinks:false path with
  | `No | `Unknown -> ()
  | `Yes ->
    if Sys_unix.is_directory_exn ~follow_symlinks:false path
    then (
      Sys_unix.ls_dir path
      |> List.iter ~f:(fun name -> remove_tree (Filename.concat path name));
      Core_unix.rmdir path)
    else Core_unix.unlink path
;;

let with_temp_tree f =
  let directory = Filename_unix.temp_dir "hardcaml-workbench-service-test-" "" in
  let root = Filename.concat directory "project" in
  let log_dir = Filename.concat directory "logs" in
  Core_unix.mkdir root;
  Core_unix.mkdir log_dir;
  Out_channel.write_all
    (Filename.concat root "dune-project")
    ~data:"(lang dune 3.22)\n(name supervisor_test)\n";
  Out_channel.write_all (Filename.concat root "dune") ~data:"";
  Monitor.protect
    ~finally:(fun () -> In_thread.run (fun () -> remove_tree directory))
    (fun () -> f ~root ~log_dir)
;;

let with_service ?(events = ref []) ~root ~log_dir action_invocation f =
  let%bind service =
    Service.create
      ~kill_after:(Time_float.Span.of_ms 100.)
      ~action_invocation
      ~instance_id
      ~log_dir
      ()
  in
  let service = Or_error.ok_exn service in
  Service.set_event_sink service (fun event -> events := event :: !events);
  Monitor.protect
    ~finally:(fun () -> Service.shutdown service)
    (fun () ->
      let%bind opened =
        Service.open_project
          service
          { instance_id; root; environment = V1.Environment_selection.Inherit_daemon }
      in
      let project = (ok opened).project in
      f service project)
;;

let submit service project action submission_key =
  Service.submit_job
    service
    { instance_id; project = project.Project.id; action; submission_key }
  >>| ok
;;

let snapshot service : V1.Snapshot.Payload.t =
  Service.snapshot service { instance_id } |> ok
;;

let job service id =
  snapshot service
  |> fun snapshot ->
  List.find_exn snapshot.V1.Snapshot.Payload.jobs ~f:(fun job ->
    Job_id.equal job.Job.id id)
;;

let with_deadline ?(timeout = short_timeout) message deferred =
  Clock.with_timeout timeout deferred
  >>| function
  | `Result result -> result
  | `Timeout -> fail message
;;

let rec wait_for_job service id predicate =
  let current = job service id in
  if predicate current
  then return current
  else (
    let%bind () = Clock.after (Time_float.Span.of_ms 10.) in
    wait_for_job service id predicate)
;;

let wait_for_job service id predicate =
  with_deadline "timed out waiting for job state" (wait_for_job service id predicate)
;;

let wait_terminal service id = wait_for_job service id Job.is_terminal

let read_log
  ?(offset = 0)
  ?(max_records = V1.max_log_records)
  ?(max_bytes = V1.max_log_bytes)
  service
  job
  =
  Service.read_log service { instance_id; job; offset; max_records; max_bytes }
;;

let log_text payload =
  payload.V1.Read_log.Payload.records
  |> List.map ~f:(fun record -> record.V1.Read_log.Record.data)
  |> String.concat
;;

let require_error_kind result kind message =
  require
    (match result with
     | Error (error : V1.Error.t) -> V1.Error.Kind.equal error.kind kind
     | Ok _ -> false)
    message
;;

let test_project_opening ~root ~log_dir =
  let%bind service = Service.create ~instance_id ~log_dir () in
  let service = Or_error.ok_exn service in
  Monitor.protect
    ~finally:(fun () -> Service.shutdown service)
    (fun () ->
      let open_root requested_root =
        Service.open_project
          service
          { instance_id
          ; root = requested_root
          ; environment = V1.Environment_selection.Inherit_daemon
          }
      in
      let%bind first = open_root root in
      let first = ok first in
      let%bind repeated = open_root (Filename.concat root ".") in
      let repeated = ok repeated in
      require
        (Project_id.equal first.project.id repeated.project.id)
        "repeat-open did not reuse the canonical project session";
      require
        (String.equal
           (Project_root.to_absolute_path repeated.project.root)
           (Filename_unix.realpath root))
        "project root was not canonicalized";
      let%bind missing = open_root (Filename.concat root "missing") in
      require_error_kind missing Invalid_request "missing project root was accepted";
      let no_project = Filename.concat root "no-dune-project" in
      Core_unix.mkdir no_project;
      let%map invalid = open_root no_project in
      require_error_kind
        invalid
        Invalid_request
        "directory without dune-project was accepted")
;;

let test_initialize_after_open ~root ~log_dir =
  let module Initialization = Hardcaml_workbench_setup.Initialization in
  let%bind created = Service.create ~instance_id ~log_dir () in
  let service = Or_error.ok_exn created in
  Monitor.protect
    ~finally:(fun () -> Service.shutdown service)
    (fun () ->
      let request : V1.Open_project.Request.t =
        { instance_id; root; environment = Inherit_daemon }
      in
      let%bind opened = Service.open_project_with_discovery service request in
      let project = (ok opened).project in
      require
        (Project_integration.Level.equal project.integration.level Generic_dune)
        "fixture did not open generically";
      let plan =
        Initialization.prepare
          ~root
          ~project_name:"initialized-after-open"
          ~build_alias:"@controlled-build"
          ~test_alias:"@controlled-test"
          ()
        |> Result.ok_or_failwith
      in
      Initialization.publish plan |> Result.ok_or_failwith;
      require
        (Result.is_error (Initialization.publish plan))
        "initialization clobbered an existing manifest";
      let%bind repeated = Service.open_project_with_discovery service request in
      require
        (Project_integration.Level.equal
           (ok repeated).project.integration.level
           Generic_dune)
        "repeat-open implicitly reloaded integration";
      let%bind refreshed =
        Service.refresh_integration service { instance_id; project = project.id }
      in
      require (Option.is_none (ok refreshed).job) "manifest-only reload created a job";
      let session = Hashtbl.find_exn service.projects project.id in
      require
        (String.equal session.project.name "initialized-after-open"
         && String.equal session.build_alias "@controlled-build"
         && String.equal session.test_alias "@controlled-test")
        "reload did not apply the initialized name and aliases";
      require
        (Project_integration.Level.equal session.project.integration.level Manifest
         && List.is_empty (snapshot service).jobs)
        "manifest-only reload performed tool work";
      let%bind fresh_created =
        Service.create ~instance_id ~log_dir:(log_dir ^ "-fresh") ()
      in
      let fresh = Or_error.ok_exn fresh_created in
      Monitor.protect
        ~finally:(fun () -> Service.shutdown fresh)
        (fun () ->
          let%map opened = Service.open_project_with_discovery fresh request in
          require
            (String.equal (ok opened).project.name "initialized-after-open"
             && List.is_empty (snapshot fresh).jobs)
            "initialized root did not open without driver jobs"))
;;

let test_live_output_and_events ~root ~log_dir =
  let events = ref [] in
  let invocation ~root ~environment:_ _ =
    shell
      root
      "printf stdout-live; printf stderr-live >&2; sleep 0.25; printf stdout-done"
  in
  with_service ~events ~root ~log_dir invocation (fun service project ->
    let%bind submitted = submit service project Build "live" in
    let id = submitted.job.id in
    let%bind running =
      wait_for_job service id (fun job -> Job.State.equal job.state Running)
    in
    require (not (Job.is_terminal running)) "live-output job completed too early";
    let rec wait_for_live_log () =
      let%bind read = read_log service id in
      let payload = ok read in
      if List.length payload.records >= 2
      then return payload
      else (
        let%bind () = Clock.after (Time_float.Span.of_ms 10.) in
        wait_for_live_log ())
    in
    let%bind live =
      with_deadline "live output was not observable" (wait_for_live_log ())
    in
    require (not live.eof) "running log was reported at EOF";
    require
      (List.exists live.records ~f:(fun record ->
         V1.Read_log.Stream.equal record.stream Stdout
         && String.is_substring record.data ~substring:"stdout-live"))
      "stdout was not tagged";
    require
      (List.exists live.records ~f:(fun record ->
         V1.Read_log.Stream.equal record.stream Stderr
         && String.is_substring record.data ~substring:"stderr-live"))
      "stderr was not tagged";
    let%bind finished = wait_terminal service id in
    require (Job.State.equal finished.state Complete) "successful job did not complete";
    let final = snapshot service in
    let sequenced = List.rev !events in
    require
      (List.for_alli sequenced ~f:(fun index event -> event.V1.Event.sequence = index + 1))
      "event sequences were not contiguous";
    require
      (final.cursor.sequence = List.length sequenced)
      "snapshot cursor did not match emitted events";
    let last_project =
      List.filter_map sequenced ~f:(fun event ->
        match event.event with
        | Project_upsert project -> Some project
        | _ -> None)
      |> List.last_exn
    in
    let last_job =
      List.filter_map sequenced ~f:(fun event ->
        match event.event with
        | Job_upsert job when Job_id.equal job.id id -> Some job
        | _ -> None)
      |> List.last_exn
    in
    require
      (Project.equal last_project (List.hd_exn final.projects))
      "snapshot project disagreed with events";
    require
      (Job.equal last_job (List.hd_exn final.jobs))
      "snapshot job disagreed with events";
    return ())
;;

let test_failure_modes ~root ~log_dir =
  let invocation ~root ~environment:_ = function
    | V1.Dune_action.Build -> shell root "exit 7"
    | Test -> shell root "kill -TERM $$"
  in
  let%bind () =
    with_service ~root ~log_dir invocation (fun service project ->
      let%bind nonzero = submit service project Build "nonzero" in
      let%bind nonzero = wait_terminal service nonzero.job.id in
      require
        (Job.State.equal nonzero.state Failed
         && Option.value_map nonzero.exit_status ~default:false ~f:(function
           | Exited 7 -> true
           | _ -> false))
        "nonzero exit was not preserved";
      let%bind signaled = submit service project Test "signaled" in
      let%bind signaled = wait_terminal service signaled.job.id in
      require
        (Job.State.equal signaled.state Failed
         && Option.value_map signaled.exit_status ~default:false ~f:(function
           | Signaled _ -> true
           | _ -> false))
        "signal termination was not preserved";
      return ())
  in
  let launch_log_dir = log_dir ^ "-launch" in
  with_service
    ~root
    ~log_dir:launch_log_dir
    (fun ~root ~environment:_ _ -> missing root)
    (fun service project ->
      let%bind launched = submit service project Build "launch" in
      let%map launched = wait_terminal service launched.job.id in
      require
        (Job.State.equal launched.state Failed
         && Option.value_map launched.exit_status ~default:false ~f:(function
           | Launch_failed _ -> true
           | _ -> false)
         && Option.is_some launched.failure)
        "launch failure was not classified")
;;

let pid_is_alive pid =
  try
    let stat = In_channel.read_all (sprintf "/proc/%d/stat" pid) in
    match String.split stat ~on:' ' with
    | _pid :: _comm :: state :: _ -> not (String.equal state "Z")
    | _ -> fail "could not parse descendant process state"
  with
  | Sys_error _ ->
    (try
       match Signal_unix.send Signal.zero (`Pid (Pid.of_int pid)) with
       | `Ok -> true
       | `No_such_process -> false
     with
     | _ -> false)
;;

let rec wait_pid_dead pid =
  if not (pid_is_alive pid)
  then return ()
  else (
    let%bind () = Clock.after (Time_float.Span.of_ms 20.) in
    wait_pid_dead pid)
;;

let running_child_script =
  "/bin/sh -c 'trap \"\" TERM; while :; do sleep 1; done' & echo $!; wait"
;;

let wait_for_child_pid service id =
  let rec loop () =
    let%bind read = read_log service id in
    match Int.of_string_opt (String.strip (log_text (ok read))) with
    | Some pid -> return pid
    | None ->
      let%bind () = Clock.after (Time_float.Span.of_ms 10.) in
      loop ()
  in
  with_deadline "child pid was not logged" (loop ())
;;

let test_cancellation_and_descendants ~root ~log_dir =
  with_service
    ~root
    ~log_dir
    (fun ~root ~environment:_ _ -> shell root running_child_script)
    (fun service project ->
      let%bind submitted = submit service project Build "cancel" in
      let id = submitted.job.id in
      let%bind pid = wait_for_child_pid service id in
      require (pid_is_alive pid) "descendant was not running";
      let%bind cancelled = Service.cancel_job service { instance_id; job = id } in
      let cancelled = (ok cancelled).job in
      require (Job.State.equal cancelled.state Cancelled) "job was not cancelled";
      let%map () = with_deadline "descendant survived cancellation" (wait_pid_dead pid) in
      ())
;;

let test_shutdown_cleanup ~root ~log_dir =
  let%bind service =
    Service.create
      ~kill_after:(Time_float.Span.of_ms 100.)
      ~action_invocation:(fun ~root ~environment:_ _ -> shell root running_child_script)
      ~instance_id
      ~log_dir
      ()
  in
  let service = Or_error.ok_exn service in
  Monitor.protect
    ~finally:(fun () -> Service.shutdown service)
    (fun () ->
      let%bind opened =
        Service.open_project
          service
          { instance_id; root; environment = V1.Environment_selection.Inherit_daemon }
      in
      let project = (ok opened).project in
      let%bind submitted = submit service project Build "shutdown" in
      let id = submitted.job.id in
      let%bind pid = wait_for_child_pid service id in
      let%bind () =
        with_deadline "service shutdown timed out" (Service.shutdown service)
      in
      let stopped = job service id in
      require (Job.State.equal stopped.state Cancelled) "shutdown did not cancel job";
      let%map () = with_deadline "descendant survived shutdown" (wait_pid_dead pid) in
      ())
;;

let test_fifo_and_submission_keys ~root ~log_dir =
  let release = Filename.concat root "release-first" in
  let invocation_count = ref 0 in
  let invocation ~root ~environment:_ action =
    Int.incr invocation_count;
    match !invocation_count, action with
    | 1, V1.Dune_action.Build ->
      shell root (sprintf "echo first; while [ ! -e %s ]; do sleep 0.02; done" release)
    | _, _ -> shell root "echo second"
  in
  with_service ~root ~log_dir invocation (fun service project ->
    let%bind first = submit service project Build "first" in
    let%bind (_ : Job.t) =
      wait_for_job service first.job.id (fun job -> Job.State.equal job.state Running)
    in
    let%bind second = submit service project Test "second" in
    require
      (Job.State.equal (job service second.job.id).state Queued)
      "same-project job did not remain queued";
    require (!invocation_count = 1) "queued action was invoked before its turn";
    let%bind duplicate = submit service project Build "first" in
    require
      (Job_id.equal duplicate.job.id first.job.id)
      "same submission key did not deduplicate";
    let%bind conflict =
      Service.submit_job
        service
        { instance_id
        ; project = project.id
        ; action = V1.Dune_action.Test
        ; submission_key = "first"
        }
    in
    require_error_kind conflict Conflict "conflicting submission key was accepted";
    Out_channel.write_all release ~data:"release\n";
    let%bind first_done = wait_terminal service first.job.id in
    let%bind second_done = wait_terminal service second.job.id in
    require (Job.State.equal first_done.state Complete) "first FIFO job failed";
    require (Job.State.equal second_done.state Complete) "second FIFO job failed";
    require
      (Timestamp.compare
         (Option.value_exn first_done.finished_at)
         (Option.value_exn second_done.started_at)
       <= 0)
      "second FIFO job started before first finished";
    return ())
;;

let test_log_paging ~root ~log_dir =
  let line = String.make 120 'x' in
  let script =
    sprintf "i=0; while [ $i -lt 3000 ]; do printf '%%s\\n' %s; i=$((i+1)); done" line
  in
  with_service
    ~root
    ~log_dir
    (fun ~root ~environment:_ _ -> shell root script)
    (fun service project ->
      let%bind submitted = submit service project Build "large-log" in
      let id = submitted.job.id in
      let%bind finished = wait_terminal service id in
      require (Job.State.equal finished.state Complete) "large-output job failed";
      let rec pages offset total records =
        let%bind page = read_log ~offset ~max_records:2 service id in
        let page = ok page in
        List.iteri page.records ~f:(fun index record ->
          require
            (record.offset = offset + index)
            "log record offsets were not contiguous");
        let total = total + String.length (log_text page) in
        let records = records + List.length page.records in
        if page.eof
        then return (page.next_offset, total, records)
        else (
          require (page.next_offset > offset) "log paging made no progress";
          pages page.next_offset total records)
      in
      let%bind final_offset, total_bytes, total_records = pages 0 0 0 in
      require (total_bytes > V1.max_log_bytes) "log did not exceed one in-memory page";
      require (total_records > 2) "large log was not split into records";
      let%bind eof = read_log ~offset:final_offset service id in
      let eof = ok eof in
      require (eof.eof && List.is_empty eof.records) "EOF read was inconsistent";
      let%bind negative = read_log ~offset:(-1) service id in
      require_error_kind negative Invalid_request "negative log offset was accepted";
      let%bind future = read_log ~offset:(final_offset + 1) service id in
      require_error_kind future Invalid_request "future log offset was accepted";
      let%bind zero_records = read_log ~max_records:0 service id in
      require_error_kind zero_records Invalid_request "zero max_records was accepted";
      let%bind too_many_records =
        read_log ~max_records:(V1.max_log_records + 1) service id
      in
      require_error_kind
        too_many_records
        Invalid_request
        "oversized max_records was accepted";
      let%bind zero_bytes = read_log ~max_bytes:0 service id in
      require_error_kind zero_bytes Invalid_request "zero max_bytes was accepted";
      let%bind too_many_bytes = read_log ~max_bytes:(V1.max_log_bytes + 1) service id in
      require_error_kind too_many_bytes Invalid_request "oversized max_bytes was accepted";
      let files = Sys_unix.ls_dir log_dir in
      require (List.length files = 1) "expected one file-backed job log";
      let size = (Core_unix.stat (Filename.concat log_dir (List.hd_exn files))).st_size in
      require (Int64.to_int_exn size = total_bytes) "log file size disagreed with paging";
      return ())
;;

let driver_response
  ?(version = 1)
  ?(capabilities = [ "describe"; "generate-rtl"; "future-capability" ])
  key
  =
  let target : Integration.Driver_protocol.Target.t =
    { key
    ; name = "Counter " ^ key
    ; top = "counter"
    ; backend = "simulation"
    ; clocks = []
    ; facts = []
    }
  in
  let configuration : Integration.Driver_protocol.Configuration.t =
    { key = "default"
    ; target = key
    ; name = "Default"
    ; description = Some "test configuration"
    }
  in
  { Integration.Driver_protocol.Describe_response.protocol_version = version
  ; capabilities
  ; targets = [ target ]
  ; configurations = [ configuration ]
  }
  |> Integration.Driver_protocol.Describe_response.sexp_of_t
  |> Sexp.to_string_mach
;;

let hierarchy_contents ~target ~configuration ~width =
  let port name width : Hierarchy.Port.t = { name; width } in
  let child instance_name : Hierarchy.Node.t =
    { key = Integration.Driver_protocol.hierarchy_key ~parent:"/" instance_name
    ; parent = Some "/"
    ; instance_name = Some instance_name
    ; circuit_name = "counter"
    ; input_ports = [ port "clock_i" 1; port "clear_i" 1 ]
    ; output_ports = [ port "count_o" width ]
    ; metadata = []
    }
  in
  { Integration.Driver_protocol.Hierarchy_response.protocol_version = 1
  ; target
  ; configuration
  ; root = "/"
  ; nodes =
      [ { key = "/"
        ; parent = None
        ; instance_name = None
        ; circuit_name = "counter_top"
        ; input_ports = [ port "clock_i" 1; port "clear_i" 1 ]
        ; output_ports = [ port "count_o" width; port "mirror_count_o" width ]
        ; metadata = []
        }
      ; child "u_counter_0"
      ; child "u_counter_1"
      ]
  }
  |> Integration.Driver_protocol.Hierarchy_response.sexp_of_t
  |> Sexp.to_string_mach
;;

let generation_response ?hierarchy_path ~target ~configuration ~path () =
  let outputs =
    [ { Integration.Driver_protocol.Output.path
      ; namespace = "hardcaml"
      ; name = "verilog"
      ; role = Artifact.Role.Deliverable
      ; media = Some "text/x-verilog"
      ; display_name = path
      ; description = Some "generated test RTL"
      }
    ]
    @ Option.value_map hierarchy_path ~default:[] ~f:(fun path ->
      [ { Integration.Driver_protocol.Output.path
        ; namespace = Integration.Driver_protocol.hierarchy_namespace
        ; name = Integration.Driver_protocol.hierarchy_name
        ; role = Artifact.Role.Report
        ; media = Some Integration.Driver_protocol.hierarchy_media
        ; display_name = "Elaborated hierarchy"
        ; description = Some "structured test hierarchy"
        }
      ])
  in
  { Integration.Driver_protocol.Generate_rtl_response.protocol_version = 1
  ; target
  ; configuration
  ; outputs
  ; tools =
      [ { Integration.Driver_protocol.Tool.name = "ocaml"; version = Some "test" }
      ; { name = "hardcaml"; version = None }
      ]
  ; build = None
  ; run = None
  }
  |> Integration.Driver_protocol.Generate_rtl_response.sexp_of_t
  |> Sexp.to_string_mach
;;

let test_rtl_generation_and_artifacts ~root ~log_dir =
  Out_channel.write_all
    (Filename.concat root Integration.Manifest.filename)
    ~data:
      "(lang hardcaml-workbench 1)\n\
       (project (name generation-test))\n\
       (dune (driver ./driver.exe))\n";
  let target key : Integration.Driver_protocol.Target.t =
    { key
    ; name = String.capitalize key
    ; top = key
    ; backend = "simulation"
    ; clocks = []
    ; facts = []
    }
  in
  let configuration key target : Integration.Driver_protocol.Configuration.t =
    { key; target; name = String.capitalize key; description = None }
  in
  let description : Integration.Driver_protocol.Describe_response.t =
    { protocol_version = 1
    ; capabilities = [ "describe"; "generate-rtl"; "generate-rtl-hierarchy" ]
    ; targets = [ target "counter"; target "other" ]
    ; configurations =
        [ configuration "four-bit" "counter"
        ; configuration "eight-bit" "counter"
        ; configuration "other-config" "other"
        ]
    }
  in
  let description =
    description
    |> Integration.Driver_protocol.Describe_response.sexp_of_t
    |> Sexp.to_string_mach
  in
  let current_description = ref description in
  let mode = ref `Valid in
  let generate_rtl_invocation
    ~root
    ~environment:_
    ~driver:_
    ~target
    ~configuration
    ~output_dir
    =
    let width = if String.equal configuration "eight-bit" then 8 else 4 in
    let path = sprintf "counter-%d.v" width in
    let hierarchy_path = sprintf "counter-%d.hierarchy.sexp" width in
    let response = generation_response ~hierarchy_path ~target ~configuration ~path () in
    match !mode with
    | `Valid ->
      Out_channel.write_all
        (Filename.concat output_dir path)
        ~data:
          (sprintf "module counter(output logic [%d:0] count_o); endmodule\n" (width - 1));
      Out_channel.write_all
        (Filename.concat output_dir hierarchy_path)
        ~data:(hierarchy_contents ~target ~configuration ~width);
      shell root (sprintf "printf %%s %s" (Filename.quote response))
    | `Malformed -> shell root "printf not-a-result"
    | `Missing -> shell root (sprintf "printf %%s %s" (Filename.quote response))
    | `No_hierarchy_output ->
      Out_channel.write_all
        (Filename.concat output_dir path)
        ~data:"module counter; endmodule\n";
      let response = generation_response ~target ~configuration ~path () in
      shell root (sprintf "printf %%s %s" (Filename.quote response))
    | `Missing_hierarchy ->
      Out_channel.write_all
        (Filename.concat output_dir path)
        ~data:"module counter; endmodule\n";
      shell root (sprintf "printf %%s %s" (Filename.quote response))
    | `Nonzero -> shell root "echo generation-failed >&2; exit 19"
    | `Launch -> missing root
    | `Slow -> shell root "echo generation-started >&2; sleep 30"
    | `Refresh_race ->
      Out_channel.write_all
        (Filename.concat output_dir path)
        ~data:
          (sprintf "module counter(output logic [%d:0] count_o); endmodule\n" (width - 1));
      Out_channel.write_all
        (Filename.concat output_dir hierarchy_path)
        ~data:(hierarchy_contents ~target ~configuration ~width);
      let release = Filename.concat root "release-generation" |> Filename.quote in
      shell
        root
        (sprintf
           "while test ! -f %s; do sleep 0.05; done; printf %%s %s"
           release
           (Filename.quote response))
    | `Escape ->
      let response =
        generation_response ~hierarchy_path ~target ~configuration ~path:"../escape.v" ()
      in
      shell root (sprintf "printf %%s %s" (Filename.quote response))
    | `Bad_hierarchy ->
      Out_channel.write_all
        (Filename.concat output_dir path)
        ~data:"module counter; endmodule\n";
      Out_channel.write_all
        (Filename.concat output_dir hierarchy_path)
        ~data:"not-a-hierarchy";
      shell root (sprintf "printf %%s %s" (Filename.quote response))
    | `Oversized_hierarchy ->
      Out_channel.write_all
        (Filename.concat output_dir path)
        ~data:"module counter; endmodule\n";
      Out_channel.write_all
        (Filename.concat output_dir hierarchy_path)
        ~data:(String.make (V1.max_hierarchy_bytes + 1) 'x');
      shell root (sprintf "printf %%s %s" (Filename.quote response))
  in
  let events = ref [] in
  let%bind service =
    Service.create
      ~kill_after:(Time_float.Span.of_ms 100.)
      ~action_invocation:(fun ~root ~environment:_ _ -> shell root "echo generic-ok")
      ~driver_invocation:(fun ~root ~environment:_ ~driver:_ ->
        shell root (sprintf "printf %%s %s" (Filename.quote !current_description)))
      ~generate_rtl_invocation
      ~instance_id
      ~log_dir
      ()
  in
  let service = Or_error.ok_exn service in
  let cancel_on_next_registered = ref false in
  let registration_cancelled = Ivar.create () in
  Service.set_event_sink service (fun event ->
    events := event :: !events;
    match event.event with
    | Job_upsert job
      when !cancel_on_next_registered
           && Option.equal String.equal job.phase (Some "registered") ->
      cancel_on_next_registered := false;
      don't_wait_for
        (let%map result = Service.cancel_job service { instance_id; job = job.id } in
         Ivar.fill_if_empty registration_cancelled result)
    | _ -> ());
  Monitor.protect
    ~finally:(fun () -> Service.shutdown service)
    (fun () ->
      let%bind opened =
        Service.open_project_with_discovery
          service
          { instance_id; root; environment = Inherit_daemon }
      in
      let opened = ok opened in
      let discovery =
        (snapshot service).jobs
        |> List.find_exn ~f:(fun job -> String.equal job.kind.name "describe")
      in
      let%bind discovery = wait_terminal service discovery.id in
      require (Job.State.equal discovery.state Complete) "generation discovery failed";
      let project =
        (snapshot service).projects
        |> List.find_exn ~f:(fun project -> Project_id.equal project.id opened.project.id)
      in
      let find_target name =
        List.find_exn project.targets ~f:(fun value -> String.equal value.name name)
      in
      let find_configuration name =
        List.find_exn project.configurations ~f:(fun value ->
          String.equal value.name name)
      in
      let counter = find_target "Counter" in
      let other = find_target "Other" in
      let four = find_configuration "Four-bit" in
      let eight = find_configuration "Eight-bit" in
      let other_config = find_configuration "Other-config" in
      let submit_generation ?(target = counter.id) ?(configuration = four.id) key =
        Service.generate_rtl
          service
          { instance_id
          ; project = project.id
          ; target
          ; configuration
          ; submission_key = key
          }
      in
      let%bind first = submit_generation "four" in
      let first = ok first in
      let%bind first_done = wait_terminal service first.job.id in
      require (Job.State.equal first_done.state Complete) "four-bit generation failed";
      require
        (List.length first_done.artifacts = 2)
        "generation did not register RTL and hierarchy artifacts";
      let artifact_for_job job name =
        List.find_map_exn job.Job.artifacts ~f:(fun id ->
          List.find (snapshot service).artifacts ~f:(fun artifact ->
            Artifact_id.equal artifact.id id && String.equal artifact.kind.name name))
      in
      let first_artifact = (artifact_for_job first_done "verilog").id in
      let first_hierarchy = artifact_for_job first_done "elaboration-hierarchy" in
      let%bind first_page =
        Service.read_artifact
          service
          { instance_id; artifact = first_artifact; offset = 0; max_bytes = 7 }
      in
      let first_page = ok first_page in
      require
        (String.length first_page.data <= 7 && not first_page.eof)
        "artifact read was not bounded";
      let%bind remainder =
        Service.read_artifact
          service
          { instance_id
          ; artifact = first_artifact
          ; offset = first_page.next_offset
          ; max_bytes = V1.max_artifact_bytes
          }
      in
      let first_contents = first_page.data ^ (ok remainder).data in
      require
        (String.is_substring first_contents ~substring:"[3:0]")
        "four-bit configuration produced the wrong RTL";
      let artifact =
        (snapshot service).artifacts
        |> List.find_exn ~f:(fun artifact -> Artifact_id.equal artifact.id first_artifact)
      in
      require
        (Target_id.equal (Option.value_exn artifact.target) counter.id
         && Configuration_id.equal (Option.value_exn artifact.configuration) four.id
         && Job_id.equal artifact.generating_job first.job.id)
        "artifact identity was misattributed";
      require
        (Option.is_some artifact.metadata.provenance.source.design_hash
         &&
         match artifact.metadata.provenance.source.working_tree with
         | Unknown _ -> true
         | Clean | Dirty -> false)
        "non-Git provenance was not represented honestly";
      let%bind first_hierarchy_result =
        Service.read_hierarchy service { instance_id; artifact = first_hierarchy.id }
      in
      let first_hierarchy_result = (ok first_hierarchy_result).hierarchy in
      require
        (Job_id.equal first_hierarchy_result.generating_job first.job.id
         && Artifact_id.equal first_hierarchy_result.artifact first_hierarchy.id
         && List.equal
              Artifact_id.equal
              first_hierarchy_result.rtl_artifacts
              [ first_artifact ])
        "hierarchy and RTL result association was incorrect";
      let repeated_instances =
        List.filter first_hierarchy_result.nodes ~f:(fun node ->
          String.equal node.circuit_name "counter")
      in
      require
        (List.length repeated_instances = 2
         && not
              (String.equal
                 (List.nth_exn repeated_instances 0).key
                 (List.nth_exn repeated_instances 1).key))
        "repeated module instances did not have distinct structural keys";
      let%bind second = submit_generation ~configuration:eight.id "eight" in
      let second = ok second in
      let%bind second_done = wait_terminal service second.job.id in
      require (Job.State.equal second_done.state Complete) "eight-bit generation failed";
      let second_artifact = (artifact_for_job second_done "verilog").id in
      let second_hierarchy = artifact_for_job second_done "elaboration-hierarchy" in
      let%bind second_contents =
        Service.read_artifact
          service
          { instance_id
          ; artifact = second_artifact
          ; offset = 0
          ; max_bytes = V1.max_artifact_bytes
          }
      in
      require
        (String.is_substring (ok second_contents).data ~substring:"[7:0]")
        "eight-bit configuration produced the wrong RTL";
      let%bind second_hierarchy_result =
        Service.read_hierarchy service { instance_id; artifact = second_hierarchy.id }
      in
      require
        (List.exists (ok second_hierarchy_result).hierarchy.nodes ~f:(fun node ->
           List.exists node.output_ports ~f:(fun port ->
             String.equal port.name "count_o" && port.width = 8)))
        "eight-bit hierarchy did not carry configuration-specific port widths";
      let%bind repeated = submit_generation "four-repeat" in
      let repeated = ok repeated in
      let%bind repeated = wait_terminal service repeated.job.id in
      require (Job.State.equal repeated.state Complete) "repeated generation failed";
      require
        (List.length (snapshot service).artifacts = 6)
        "repeated generation overwrote an earlier artifact";
      let repeated_hierarchy = artifact_for_job repeated "elaboration-hierarchy" in
      let%bind repeated_hierarchy_result =
        Service.read_hierarchy service { instance_id; artifact = repeated_hierarchy.id }
      in
      require
        (List.equal
           String.equal
           (List.map first_hierarchy_result.nodes ~f:(fun node -> node.key))
           (List.map (ok repeated_hierarchy_result).hierarchy.nodes ~f:(fun node ->
              node.key)))
        "deterministic repeated elaboration changed structural keys";
      let jobs_before_reconnect = List.length (snapshot service).jobs in
      ignore (snapshot service : V1.Snapshot.Payload.t);
      require
        (List.length (snapshot service).jobs = jobs_before_reconnect)
        "same-daemon snapshot replayed generation";
      let stale_target = Target_id.of_string "stale-target" in
      let%bind stale = submit_generation ~target:stale_target "stale" in
      require_error_kind stale Invalid_request "stale target was accepted";
      let stale_configuration = Configuration_id.of_string "stale-configuration" in
      let%bind stale =
        submit_generation ~configuration:stale_configuration "stale-configuration"
      in
      require_error_kind stale Invalid_request "stale configuration was accepted";
      let%bind mismatch =
        submit_generation ~target:counter.id ~configuration:other_config.id "mismatch"
      in
      require_error_kind mismatch Invalid_request "mismatched configuration was accepted";
      let artifacts_before_failures = List.length (snapshot service).artifacts in
      let%bind () =
        Deferred.List.iter
          [ "malformed", `Malformed
          ; "missing", `Missing
          ; "no-hierarchy-output", `No_hierarchy_output
          ; "missing-hierarchy", `Missing_hierarchy
          ; "nonzero", `Nonzero
          ; "launch", `Launch
          ; "escape", `Escape
          ; "bad-hierarchy", `Bad_hierarchy
          ; "oversized-hierarchy", `Oversized_hierarchy
          ]
          ~how:`Sequential
          ~f:(fun (key, next_mode) ->
            mode := next_mode;
            let%bind submitted = submit_generation key in
            let submitted = ok submitted in
            let%map failed = wait_terminal service submitted.job.id in
            require
              (Job.State.equal failed.state Failed)
              "invalid generation did not fail";
            require
              (List.is_empty failed.artifacts)
              "failed generation advertised artifacts";
            require
              (List.length (snapshot service).artifacts = artifacts_before_failures)
              "failed generation registered partial output")
      in
      mode := `Slow;
      let%bind slow = submit_generation "cancel-generation" in
      let slow = ok slow in
      let%bind (_ : Job.t) =
        wait_for_job service slow.job.id (fun job -> Job.State.equal job.state Running)
      in
      let%bind cancelled =
        Service.cancel_job service { instance_id; job = slow.job.id }
      in
      require
        (Job.State.equal (ok cancelled).job.state Cancelled)
        "generation was not cancelled";
      require
        (List.length (snapshot service).artifacts = artifacts_before_failures)
        "cancelled generation registered an artifact";
      mode := `Valid;
      cancel_on_next_registered := true;
      let%bind committed = submit_generation "cancel-after-registration" in
      let committed = ok committed in
      let%bind registration_cancelled = Ivar.read registration_cancelled in
      ignore (ok registration_cancelled : V1.Cancel_job.Payload.t);
      let%bind committed = wait_terminal service committed.job.id in
      require
        (Job.State.equal committed.state Complete)
        "cancellation after artifact registration overrode the committed result";
      require
        (List.length committed.artifacts = 2)
        "committed generation lost its RTL or hierarchy artifact";
      let committed_hierarchy = artifact_for_job committed "elaboration-hierarchy" in
      let%bind committed_hierarchy =
        Service.read_hierarchy service { instance_id; artifact = committed_hierarchy.id }
      in
      require
        (Job_id.equal (ok committed_hierarchy).hierarchy.generating_job committed.id)
        "committed hierarchy was not retrievable after late cancellation";
      let%bind generic =
        submit service project Build "generic-after-generation-failures"
      in
      let%bind generic = wait_terminal service generic.job.id in
      require
        (Job.State.equal generic.state Complete)
        "generic Dune fallback stopped working";
      let rtl_only_description : Integration.Driver_protocol.Describe_response.t =
        { protocol_version = 1
        ; capabilities = [ "describe"; "generate-rtl" ]
        ; targets = [ target "counter"; target "other" ]
        ; configurations =
            [ configuration "four-bit" "counter"
            ; configuration "eight-bit" "counter"
            ; configuration "other-config" "other"
            ]
        }
      in
      let release_generation = Filename.concat root "release-generation" in
      mode := `Refresh_race;
      let%bind refresh_race = submit_generation "refresh-during-generation" in
      let refresh_race = ok refresh_race in
      let%bind (_ : Job.t) =
        wait_for_job service refresh_race.job.id (fun job ->
          Job.State.equal job.state Running)
      in
      current_description
      := rtl_only_description
         |> Integration.Driver_protocol.Describe_response.sexp_of_t
         |> Sexp.to_string_mach;
      let%bind refreshed =
        Service.refresh_integration service { instance_id; project = project.id }
      in
      let refreshed = Option.value_exn (ok refreshed).job in
      Out_channel.write_all release_generation ~data:"release\n";
      let%bind refresh_race = wait_terminal service refresh_race.job.id in
      require
        (Job.State.equal refresh_race.state Complete)
        "concurrent refresh invalidated an in-flight hierarchy generation";
      let refresh_race_hierarchy =
        artifact_for_job refresh_race "elaboration-hierarchy"
      in
      let%bind refresh_race_hierarchy =
        Service.read_hierarchy
          service
          { instance_id; artifact = refresh_race_hierarchy.id }
      in
      require
        (Job_id.equal
           (ok refresh_race_hierarchy).hierarchy.generating_job
           refresh_race.id)
        "in-flight generation lost its pinned hierarchy capability";
      let%bind refreshed = wait_terminal service refreshed.id in
      require (Job.State.equal refreshed.state Complete) "RTL-only driver refresh failed";
      mode := `Valid;
      let%bind rtl_only = submit_generation "rtl-only-hierarchy" in
      let rtl_only = ok rtl_only in
      let%bind rtl_only = wait_terminal service rtl_only.job.id in
      require
        (Job.State.equal rtl_only.state Complete)
        "RTL-only driver could not generate RTL";
      let opaque_hierarchy = artifact_for_job rtl_only "elaboration-hierarchy" in
      let%bind opaque_contents =
        Service.read_artifact
          service
          { instance_id
          ; artifact = opaque_hierarchy.id
          ; offset = 0
          ; max_bytes = V1.max_artifact_bytes
          }
      in
      require
        (String.is_substring (ok opaque_contents).data ~substring:"(root /)")
        "unadvertised hierarchy sidecar was not readable as a generic artifact";
      let%bind unsupported_hierarchy =
        Service.read_hierarchy service { instance_id; artifact = opaque_hierarchy.id }
      in
      require_error_kind
        unsupported_hierarchy
        Unsupported_operation
        "unadvertised hierarchy sidecar became a structured result";
      let terminal_index, _ =
        List.rev !events
        |> List.findi_exn ~f:(fun _ event ->
          match event.V1.Event.event with
          | Job_upsert job -> Job_id.equal job.id first.job.id && Job.is_terminal job
          | _ -> false)
      in
      let preceding = List.rev !events |> Fn.flip List.take terminal_index in
      require
        (List.exists preceding ~f:(fun event ->
           match event.event with
           | Artifact_upsert artifact -> Artifact_id.equal artifact.id first_artifact
           | _ -> false))
        "terminal generation event preceded its artifact event";
      ignore other;
      return ())
;;

let test_source_provenance ~root ~log_dir:_ =
  let unavailable_capture : Service.source_capture =
    { hash = None
    ; git = { commit = Some "clean-commit"; dirty = Some false; reason = None }
    }
  in
  let unavailable = Service.source_identity unavailable_capture unavailable_capture in
  require
    (Option.is_none unavailable.design_hash
     && (not (Provenance.Source_identity.identifies_inputs_exactly unavailable))
     &&
     match unavailable.working_tree with
     | Unknown _ -> true
     | Clean | Dirty -> false)
    "failed source hash captures were presented as exact";
  let%bind non_git_start = Service.capture_source root in
  let%bind non_git_finish = Service.capture_source root in
  let non_git = Service.source_identity non_git_start non_git_finish in
  require (Option.is_some non_git.design_hash) "non-Git source hash was unavailable";
  require
    (match non_git.working_tree with
     | Provenance.Working_tree.Unknown _ -> true
     | Clean | Dirty -> false)
    "non-Git source was not marked unknown";
  let git arguments =
    Process.run ~working_dir:root ~prog:"git" ~args:arguments ()
    >>| Or_error.ok_exn
    >>| ignore
  in
  let%bind () = git [ "init"; "-q" ] in
  let%bind () = git [ "config"; "user.name"; "Workbench Test" ] in
  let%bind () = git [ "config"; "user.email"; "workbench@example.invalid" ] in
  let%bind () = git [ "add"; "." ] in
  let%bind () = git [ "commit"; "-qm"; "fixture" ] in
  let%bind clean_start = Service.capture_source root in
  let%bind clean_finish = Service.capture_source root in
  let clean = Service.source_identity clean_start clean_finish in
  require
    (Provenance.Source_identity.identifies_inputs_exactly clean
     && Option.is_some clean.design_hash)
    "clean Git source was not exact";
  Out_channel.write_all
    (Filename.concat root "dirty-source.ml")
    ~data:"let dirty = true\n";
  let%bind dirty_start = Service.capture_source root in
  let%bind dirty_finish = Service.capture_source root in
  let dirty = Service.source_identity dirty_start dirty_finish in
  require
    (match dirty.working_tree with
     | Provenance.Working_tree.Dirty -> true
     | Clean | Unknown _ -> false)
    "dirty Git source was not marked dirty";
  require
    (Option.is_some dirty.git_commit
     && Option.is_some dirty.design_hash
     && not (Provenance.Source_identity.identifies_inputs_exactly dirty))
    "dirty Git provenance claimed an exact commit or lost its evidence";
  return ()
;;

let test_driver_discovery ~root ~log_dir =
  let module Initialization = Hardcaml_workbench_setup.Initialization in
  let plan =
    Initialization.prepare ~root ~project_name:"discovery-test" ~driver:"./driver.exe" ()
    |> Result.ok_or_failwith
  in
  Initialization.publish plan |> Result.ok_or_failwith;
  require
    (Poly.equal
       (Sys_unix.file_exists (Filename.concat root Integration.Manifest.filename))
       `Yes)
    "test manifest was not written";
  let%bind loaded_manifest = Service.load_manifest root in
  require
    (match loaded_manifest with
     | Service.Manifest_valid _ -> true
     | Manifest_absent | Manifest_invalid _ -> false)
    "service did not load the test manifest";
  let mode = ref `Valid in
  let observed_environment = ref None in
  let events = ref [] in
  let driver_invocation ~root ~environment ~driver =
    require (String.equal driver "./driver.exe") "initialized driver reference changed";
    observed_environment := Some environment;
    match !mode with
    | `Valid ->
      shell root (sprintf "printf %%s %s" (Filename.quote (driver_response "counter")))
    | `Malformed -> shell root "printf not-an-sexp"
    | `Version ->
      shell
        root
        (sprintf "printf %%s %s" (Filename.quote (driver_response ~version:2 "counter")))
    | `No_generate ->
      shell
        root
        (sprintf
           "printf %%s %s"
           (Filename.quote (driver_response ~capabilities:[ "describe" ] "counter")))
    | `Nonzero -> shell root "echo driver-failed >&2; exit 23"
    | `Missing -> missing root
    | `Slow -> shell root "echo discovery-started >&2; sleep 30"
  in
  let%bind service =
    Service.create
      ~kill_after:(Time_float.Span.of_ms 100.)
      ~action_invocation:(fun ~root ~environment:_ _ ->
        shell root "echo generic-still-works")
      ~driver_invocation
      ~instance_id
      ~log_dir
      ()
  in
  let service = Or_error.ok_exn service in
  Service.set_event_sink service (fun event -> events := event :: !events);
  Monitor.protect
    ~finally:(fun () -> Service.shutdown service)
    (fun () ->
      let request : V1.Open_project.Request.t =
        { instance_id; root; environment = Opam_switch "selected-project-switch" }
      in
      (* Bypass the real Dune environment probe while retaining the selected value in
         jobs. *)
      let request = { request with environment = Inherit_daemon } in
      let%bind opened = Service.open_project_with_discovery service request in
      let project = (ok opened).project in
      let require_project_result_before_terminal job_id =
        let events = List.rev !events in
        let index, _ =
          List.findi_exn events ~f:(fun _ event ->
            match event.V1.Event.event with
            | Job_upsert job -> Job_id.equal job.id job_id && Job.is_terminal job
            | _ -> false)
        in
        require (index > 0) "terminal driver event had no preceding project result";
        require
          (match (List.nth_exn events (index - 1)).event with
           | Project_upsert updated -> Project_id.equal updated.id project.id
           | _ -> false)
          "terminal driver event was published before its project result"
      in
      let describe =
        snapshot service
        |> fun (snapshot : V1.Snapshot.Payload.t) ->
        match
          List.find snapshot.jobs ~f:(fun job ->
            Project_id.equal job.project project.id
            && String.equal job.kind.namespace "project-driver")
        with
        | Some job -> job
        | None ->
          raise_s
            [%message
              "initial discovery job was not created"
                (project.integration : Project_integration.t)
                (snapshot.jobs : Job.t list)]
      in
      let%bind first = wait_terminal service describe.id in
      require (Job.State.equal first.state Complete) "initial discovery did not complete";
      require_project_result_before_terminal first.id;
      let discovered =
        snapshot service
        |> fun (snapshot : V1.Snapshot.Payload.t) ->
        List.find_exn snapshot.projects ~f:(fun value ->
          Project_id.equal value.id project.id)
      in
      require (List.length discovered.targets = 1) "target was not discovered";
      require
        (List.length discovered.configurations = 1)
        "configuration was not discovered";
      let target_id = (List.hd_exn discovered.targets).id in
      let config_id = (List.hd_exn discovered.configurations).id in
      let%bind repeated = Service.open_project_with_discovery service request in
      ignore (ok repeated : V1.Open_project.Payload.t);
      require
        (List.length (snapshot service).jobs = 1)
        "repeat-open unexpectedly repeated discovery";
      let refresh () =
        Service.refresh_integration service { instance_id; project = project.id }
        >>| fun result -> Option.value_exn (ok result).job
      in
      let%bind refreshed = refresh () in
      let%bind refreshed = wait_terminal service refreshed.id in
      require (Job.State.equal refreshed.state Complete) "valid refresh failed";
      require_project_result_before_terminal refreshed.id;
      let refreshed_project =
        snapshot service
        |> fun (snapshot : V1.Snapshot.Payload.t) ->
        List.find_exn snapshot.projects ~f:(fun value ->
          Project_id.equal value.id project.id)
      in
      require
        (Target_id.equal target_id (List.hd_exn refreshed_project.targets).id
         && Configuration_id.equal
              config_id
              (List.hd_exn refreshed_project.configurations).id)
        "discovery identities changed across refresh";
      mode := `No_generate;
      let%bind unsupported_refresh = refresh () in
      let%bind unsupported_refresh = wait_terminal service unsupported_refresh.id in
      require
        (Job.State.equal unsupported_refresh.state Complete)
        "describe without generation capability failed";
      let%bind unsupported_generation =
        Service.generate_rtl
          service
          { instance_id
          ; project = project.id
          ; target = target_id
          ; configuration = config_id
          ; submission_key = "unsupported-generation"
          }
      in
      require_error_kind
        unsupported_generation
        Unsupported_operation
        "missing generation capability was accepted";
      mode := `Valid;
      let%bind restored = refresh () in
      let%bind restored = wait_terminal service restored.id in
      require
        (Job.State.equal restored.state Complete)
        "generation capability did not restore";
      Out_channel.write_all
        (Filename.concat root Integration.Manifest.filename)
        ~data:
          "(lang hardcaml-workbench 99)\n\
           (project (name broken))\n\
           (dune (driver ./driver.exe))\n";
      let%bind invalid_manifest =
        Service.refresh_integration service { instance_id; project = project.id }
      in
      require_error_kind
        invalid_manifest
        Unsupported_operation
        "invalid manifest refresh was accepted";
      Out_channel.write_all
        (Filename.concat root Integration.Manifest.filename)
        ~data:
          "(lang hardcaml-workbench 1)\n\
           (project (name discovery-test))\n\
           (dune (driver ./driver.exe))\n";
      mode := `Valid;
      let%bind repaired = refresh () in
      let%bind repaired = wait_terminal service repaired.id in
      require
        (Job.State.equal repaired.state Complete)
        "repaired manifest did not recover";
      let%bind () =
        Deferred.List.iter
          [ `Malformed; `Version; `Nonzero; `Missing ]
          ~how:`Sequential
          ~f:(fun next_mode ->
            mode := next_mode;
            let%bind failed = refresh () in
            let%map failed = wait_terminal service failed.id in
            require (Job.State.equal failed.state Failed) "invalid discovery did not fail";
            require_project_result_before_terminal failed.id;
            let current =
              snapshot service
              |> fun (snapshot : V1.Snapshot.Payload.t) ->
              List.find_exn snapshot.projects ~f:(fun value ->
                Project_id.equal value.id project.id)
            in
            require
              (List.is_empty current.targets && List.is_empty current.configurations)
              "failed refresh retained stale discovery";
            require
              (match current.integration.driver with
               | Unusable { reason } -> not (String.is_empty reason)
               | Absent | Available _ -> false)
              "failed refresh lacked an actionable driver diagnostic")
      in
      mode := `Slow;
      let%bind slow = refresh () in
      let%bind (_ : Job.t) =
        wait_for_job service slow.id (fun job -> Job.State.equal job.state Running)
      in
      let%bind cancelled = Service.cancel_job service { instance_id; job = slow.id } in
      require
        (Job.State.equal (ok cancelled).job.state Cancelled)
        "driver discovery cancellation failed";
      let%bind generic = submit service project Build "generic-after-driver-failure" in
      let%map generic = wait_terminal service generic.job.id in
      require
        (Job.State.equal generic.state Complete)
        "optional integration failure disabled generic Dune actions";
      require
        (Option.equal
           V1.Environment_selection.equal
           !observed_environment
           (Some Inherit_daemon))
        "driver did not use the selected project environment")
;;

let run only () =
  let tests =
    [ "project opening and repeat identity", test_project_opening
    ; "initialize after open", test_initialize_after_open
    ; "live output and event consistency", test_live_output_and_events
    ; "failure modes", test_failure_modes
    ; "cancellation and descendant cleanup", test_cancellation_and_descendants
    ; "shutdown cleanup", test_shutdown_cleanup
    ; "FIFO and submission keys", test_fifo_and_submission_keys
    ; "file-backed log paging", test_log_paging
    ; "driver discovery, refresh, failures, and cancellation", test_driver_discovery
    ; ( "RTL generation, artifacts, provenance, and retrieval"
      , test_rtl_generation_and_artifacts )
    ; "clean, dirty, and non-Git source provenance", test_source_provenance
    ]
  in
  let tests =
    match only with
    | None -> tests
    | Some name ->
      [ List.find_exn tests ~f:(fun (candidate, _) -> String.equal name candidate) ]
  in
  Deferred.List.iter tests ~how:`Sequential ~f:(fun (name, test) ->
    with_temp_tree (fun ~root ~log_dir ->
      let test_log_dir =
        Filename.concat log_dir (String.tr name ~target:' ' ~replacement:'-')
      in
      printf "test: %s\n%!" name;
      test ~root ~log_dir:test_log_dir))
;;

let command =
  Command.async
    ~summary:"Test backend process supervision"
    (let%map_open.Command only =
       flag "--only" (optional string) ~doc:"NAME run one test"
     in
     run only)
;;

let () = Command_unix.run command
