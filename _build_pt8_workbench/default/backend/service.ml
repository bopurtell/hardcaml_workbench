open! Core
open! Async
open Hardcaml_workbench_protocol
module Adapter = Hardcaml_workbench_adapters.Dune_adapter
module Driver_adapter = Hardcaml_workbench_adapters.Project_driver_adapter
module Integration = Hardcaml_workbench_project_integration
open Project_integration.Component_status
open Project_integration.Level

type event_sink = V1.Event.sequenced -> unit

type log_record =
  { stream : V1.Read_log.Stream.t
  ; position : int
  ; length : int
  }

type git_state =
  { commit : string option
  ; dirty : bool option
  ; reason : string option
  }

type source_capture =
  { hash : string option
  ; git : git_state
  }

type artifact_entry =
  { mutable artifact : Artifact.t
  ; path : string
  }

type hierarchy_entry = { hierarchy : Hierarchy.t }

type project_session =
  { key : string
  ; root : string
  ; dune_name : string
  ; environment : V1.Environment_selection.t
  ; mutable project : Project.t
  ; mutable summary : V1.Environment_summary.t
  ; mutable workspace : V1.Dune_workspace.Inspection.t
  ; mutable manifest : Integration.Manifest.t option
  ; mutable build_alias : string
  ; mutable test_alias : string
  ; mutable driver : string option
  ; mutable driver_description : Integration.Driver_protocol.Describe_response.t option
  }

and job_entry =
  { mutable operation : job_operation
  ; session : project_session
  ; mutable job : Job.t
  ; log_path : string
  ; log_writer : Writer.t
  ; log_records : (int, log_record) Hashtbl.t
  ; mutable log_position : int
  ; mutable next_log_offset : int
  ; mutable log_tail : unit Deferred.t
  ; mutable stdout_parts : string list
  ; mutable stdout_bytes : int
  ; mutable stdout_overflow : bool
  ; mutable process : Process.t option
  ; mutable cancel_requested : bool
  ; mutable escalation_started : bool
  ; escalation_finished : unit Ivar.t
  ; finished : unit Ivar.t
  ; mutable source_start : source_capture option
  }

and job_operation =
  | Dune_action of V1.Dune_action.t
  | Simulation_task of Simulation_task.t
  | Driver_describe
  | Driver_generate_rtl of
      { target : Target_id.t
      ; configuration : Configuration_id.t
      ; target_key : string
      ; configuration_key : string
      ; hierarchy_capable : bool
      ; driver : string
      ; output_dir : string
      }

type submission_operation =
  | Submit_dune of V1.Dune_action.t
  | Submit_simulation of string
  | Submit_generate_rtl of
      { target : Target_id.t
      ; configuration : Configuration_id.t
      }
[@@deriving equal]

type submission =
  { project : Project_id.t
  ; operation : submission_operation
  ; ready : (job_entry, V1.Error.t) Result.t Ivar.t
  }

type t =
  { instance_id : V1.Daemon_instance_id.t
  ; log_dir : string
  ; artifact_dir : string
  ; output_dir : string
  ; workspace_service : Workspace_service.t
  ; asic_service : Asic_service.t
  ; simulation_service : Simulation_service.t
  ; preparation_service : Preparation_service.t
  ; projects_by_key : (string, project_session) Hashtbl.t
  ; projects : (Project_id.t, project_session) Hashtbl.t
  ; root_queues : (string, job_entry Queue.t) Hashtbl.t
  ; running_roots : String.Hash_set.t
  ; preparation_waiters : String.Hash_set.t
  ; jobs : (Job_id.t, job_entry) Hashtbl.t
  ; artifacts : (Artifact_id.t, artifact_entry) Hashtbl.t
  ; hierarchies : (Artifact_id.t, hierarchy_entry) Hashtbl.t
  ; submissions : (string, submission) Hashtbl.t
  ; mutable event_sink : event_sink
  ; mutable sequence : int
  ; mutable next_project_id : int
  ; mutable next_job_id : int
  ; mutable next_artifact_id : int
  ; mutable shutting_down : bool
  ; kill_after : Time_float.Span.t
  ; action_invocation :
      (root:string
       -> environment:V1.Environment_selection.t
       -> V1.Dune_action.t
       -> Adapter.Invocation.t)
        option
  ; driver_invocation :
      root:string
      -> environment:V1.Environment_selection.t
      -> driver:string
      -> Adapter.Invocation.t
  ; generate_rtl_invocation :
      root:string
      -> environment:V1.Environment_selection.t
      -> driver:string
      -> target:string
      -> configuration:string
      -> output_dir:string
      -> Adapter.Invocation.t
  }

let error kind message = Error (V1.Error.create kind message)

let check_instance t instance_id =
  if V1.Daemon_instance_id.equal instance_id t.instance_id
  then Ok ()
  else error V1.Error.Kind.Instance_changed "daemon instance has changed"
;;

let create
  ?state_dir
  ?inspection_detail_cache_entries
  ?inspection_detail_cache_bytes
  ?(kill_after = Time_float.Span.of_sec 2.)
  ?action_invocation
  ?(driver_invocation = Driver_adapter.describe_invocation)
  ?(generate_rtl_invocation = Driver_adapter.generate_rtl_invocation)
  ?preparation_build_invocation
  ?preparation_emit_invocation
  ~instance_id
  ~log_dir
  ()
  =
  let artifact_dir = log_dir ^ "-artifacts" in
  let output_dir = Filename.concat artifact_dir "job-output" in
  let state_dir = Option.value state_dir ~default:(log_dir ^ "-state") in
  let%map result =
    Monitor.try_with_or_error (fun () ->
      Inspection_detail_cache.validate_limits
        ~entries:(Option.value inspection_detail_cache_entries ~default:64)
        ~bytes:(Option.value inspection_detail_cache_bytes ~default:4194304);
      In_thread.run (fun () ->
        (match Sys_unix.file_exists log_dir with
         | `Yes ->
           if not (Sys_unix.is_directory_exn log_dir)
           then failwithf "log path is not a directory: %s" log_dir ()
         | `No | `Unknown -> Core_unix.mkdir log_dir ~perm:0o700);
        Core_unix.mkdir artifact_dir ~perm:0o700;
        Core_unix.mkdir output_dir ~perm:0o700))
  in
  Result.map result ~f:(fun () ->
    { instance_id
    ; log_dir
    ; artifact_dir
    ; output_dir
    ; workspace_service = Workspace_service.create ~state_dir
    ; asic_service =
        Asic_service.create_with_detail_cache
          ?inspection_detail_cache_entries
          ?inspection_detail_cache_bytes
          ~state_dir
          ()
    ; simulation_service = Simulation_service.create ~state_dir
    ; preparation_service =
        Preparation_service.create
          ?build:preparation_build_invocation
          ?emit:preparation_emit_invocation
          ()
    ; projects_by_key = Hashtbl.create (module String)
    ; projects = Project_id.Table.create ()
    ; root_queues = Hashtbl.create (module String)
    ; running_roots = Hash_set.create (module String)
    ; preparation_waiters = Hash_set.create (module String)
    ; jobs = Job_id.Table.create ()
    ; artifacts = Artifact_id.Table.create ()
    ; hierarchies = Artifact_id.Table.create ()
    ; submissions = Hashtbl.create (module String)
    ; event_sink = ignore
    ; sequence = 0
    ; next_project_id = 0
    ; next_job_id = 0
    ; next_artifact_id = 0
    ; shutting_down = false
    ; kill_after
    ; action_invocation
    ; driver_invocation
    ; generate_rtl_invocation
    })
;;

let set_event_sink t sink = t.event_sink <- sink

let emit t event =
  t.sequence <- t.sequence + 1;
  try t.event_sink { V1.Event.sequence = t.sequence; event } with
  | _ -> ()
;;

let snapshot t ({ instance_id } : V1.Snapshot.Request.t) =
  match check_instance t instance_id with
  | Error _ as error -> error
  | Ok () ->
    let projects =
      Hashtbl.data t.projects
      |> List.map ~f:(fun session -> session.project)
      |> List.sort ~compare:(fun (a : Project.t) b -> Project_id.compare a.id b.id)
    in
    let jobs =
      Hashtbl.data t.jobs
      |> List.map ~f:(fun entry -> entry.job)
      |> List.sort ~compare:(fun (a : Job.t) b -> Job_id.compare a.id b.id)
    in
    let artifacts =
      Hashtbl.data t.artifacts
      |> List.map ~f:(fun entry -> entry.artifact)
      |> List.sort ~compare:(fun (a : Artifact.t) b -> Artifact_id.compare a.id b.id)
    in
    Ok
      { V1.Snapshot.Payload.projects
      ; jobs
      ; artifacts
      ; cursor = { instance_id = t.instance_id; sequence = t.sequence }
      }
;;

let command_output invocation =
  let args = List.tl invocation.Adapter.Invocation.argv |> Option.value ~default:[] in
  let argv0 = List.hd invocation.argv in
  let%bind process =
    Process.create ?argv0 ~working_dir:invocation.cwd ~prog:invocation.executable ~args ()
  in
  match process with
  | Error error -> return (Error (Error.to_string_hum error))
  | Ok process ->
    let%map output = Process.collect_output_and_wait process in
    (match output.exit_status with
     | Ok () -> Ok output.stdout
     | Error _ ->
       Error
         (sprintf
            "%s\n%s"
            (Unix.Exit_or_signal.to_string_hum output.exit_status)
            (String.prefix output.stderr 4096)))
;;

let hash_project_tree root =
  Or_error.try_with (fun () ->
    let hash = Cryptokit.Hash.sha256 () in
    let add value = hash#add_string (sprintf "%d:%s" (String.length value) value) in
    let rec visit relative =
      let path =
        if String.is_empty relative then root else Filename.concat root relative
      in
      let names = Sys_unix.ls_dir path |> List.sort ~compare:String.compare in
      List.iter names ~f:(fun name ->
        if not (String.equal name ".git" || String.equal name "_build")
        then (
          let child_relative =
            if String.is_empty relative then name else Filename.concat relative name
          in
          let child = Filename.concat root child_relative in
          let stat = Core_unix.lstat child in
          match stat.st_kind with
          | S_DIR ->
            add "directory";
            add child_relative;
            visit child_relative
          | S_REG ->
            add "file";
            add child_relative;
            add (if stat.st_perm land 0o111 = 0 then "regular" else "executable");
            let channel = Stdlib.open_in_bin child in
            Exn.protect
              ~f:(fun () ->
                let buffer = Bytes.create (64 * 1024) in
                let rec copy () =
                  let count = Stdlib.input channel buffer 0 (Bytes.length buffer) in
                  if count > 0
                  then (
                    hash#add_substring buffer 0 count;
                    copy ())
                in
                copy ())
              ~finally:(fun () -> Stdlib.close_in_noerr channel)
          | S_LNK ->
            add "symlink";
            add child_relative;
            add (Core_unix.readlink child)
          | S_CHR | S_BLK | S_FIFO | S_SOCK ->
            add "special";
            add child_relative))
    in
    visit "";
    "sha256:" ^ Cryptokit.transform_string (Cryptokit.Hexa.encode ()) hash#result)
;;

let git_output root arguments =
  command_output
    { Adapter.Invocation.executable = "git"
    ; argv = "git" :: arguments
    ; cwd = root
    ; environment = Inherit_daemon
    }
;;

let capture_git root =
  let%bind inside = git_output root [ "rev-parse"; "--is-inside-work-tree" ] in
  match inside with
  | Error reason ->
    return { commit = None; dirty = None; reason = Some (String.strip reason) }
  | Ok output when not (String.equal (String.strip output) "true") ->
    return
      { commit = None; dirty = None; reason = Some "project root is not a Git work tree" }
  | Ok _ ->
    let%bind commit = git_output root [ "rev-parse"; "--verify"; "HEAD" ]
    and status =
      git_output root [ "status"; "--porcelain=v1"; "--untracked-files=normal" ]
    in
    let commit = Result.ok commit |> Option.map ~f:String.strip in
    (match status with
     | Ok status ->
       return { commit; dirty = Some (not (String.is_empty status)); reason = None }
     | Error reason ->
       return { commit; dirty = None; reason = Some (String.strip reason) })
;;

let capture_source root =
  let%bind hash = In_thread.run (fun () -> hash_project_tree root)
  and git = capture_git root in
  return { hash = Result.ok hash; git }
;;

let source_identity start finish =
  let hash_observation =
    match start.hash, finish.hash with
    | Some start, Some finish when String.equal start finish -> `Equal start
    | Some _, Some _ -> `Changed
    | None, _ | _, None -> `Unavailable
  in
  let design_hash =
    match hash_observation with
    | `Equal hash -> Some hash
    | `Changed | `Unavailable -> None
  in
  let same_commit = Option.equal String.equal start.git.commit finish.git.commit in
  let git_commit = if same_commit then start.git.commit else None in
  let working_tree =
    match hash_observation with
    | `Changed ->
      Provenance.Working_tree.Unknown
        { reason = "project files changed between generation start and completion" }
    | `Unavailable ->
      Unknown { reason = "source hash was unavailable at a generation boundary" }
    | `Equal _ ->
      if not same_commit
      then Unknown { reason = "Git commit changed while generation was running" }
      else (
        match start.git.dirty, finish.git.dirty with
        | Some false, Some false -> Clean
        | Some _, Some _ -> Dirty
        | _ ->
          let reason =
            Option.first_some finish.git.reason start.git.reason
            |> Option.value ~default:"Git working-tree state was unavailable"
          in
          Unknown { reason })
  in
  { Provenance.Source_identity.git_commit
  ; working_tree
  ; design_hash
  ; preserved_inputs = []
  }
;;

let canonical_project_root root =
  Monitor.try_with (fun () ->
    In_thread.run (fun () ->
      let root = Filename_unix.realpath root in
      if not (Sys_unix.is_directory_exn root)
      then failwith "project root is not a directory";
      let dune_project = Filename.concat root "dune-project" in
      (match Sys_unix.file_exists dune_project with
       | `Yes -> ()
       | `No | `Unknown -> failwith "project root must directly contain dune-project");
      (match (Core_unix.stat dune_project).st_kind with
       | S_REG -> ()
       | _ -> failwith "dune-project is not a regular file");
      root))
  >>| Result.map_error ~f:(fun exn -> Exn.to_string exn)
;;

let project_name root =
  Monitor.try_with (fun () ->
    In_thread.run (fun () ->
      let sexps = Sexp.load_sexps (Filename.concat root "dune-project") in
      List.find_map sexps ~f:(function
        | Sexp.List [ Atom "name"; Atom name ] -> Some name
        | Atom _ | List _ -> None)))
  >>| function
  | Ok (Some name) -> name
  | Ok None | Error _ -> Filename.basename root
;;

type manifest_load =
  | Manifest_absent
  | Manifest_valid of Integration.Manifest.t
  | Manifest_invalid of string

let load_manifest root =
  Monitor.try_with (fun () ->
    In_thread.run (fun () ->
      let path = Filename.concat root Integration.Manifest.filename in
      match Sys_unix.file_exists path with
      | `No | `Unknown -> Manifest_absent
      | `Yes ->
        (match (Core_unix.stat path).st_kind with
         | S_REG ->
           (match Integration.Manifest.parse_string (In_channel.read_all path) with
            | Ok manifest -> Manifest_valid manifest
            | Error message ->
              Manifest_invalid (sprintf "%s: %s" Integration.Manifest.filename message))
         | _ -> Manifest_invalid (Integration.Manifest.filename ^ ": not a regular file"))))
  >>| function
  | Ok result -> result
  | Error exn ->
    Manifest_invalid (sprintf "%s: %s" Integration.Manifest.filename (Exn.to_string exn))
;;

let environment_key environment =
  Sexp.to_string_mach (V1.Environment_selection.sexp_of_t environment)
;;

let mint_project_id t =
  t.next_project_id <- t.next_project_id + 1;
  Project_id.of_string
    (sprintf
       "%s-project-%d"
       (V1.Daemon_instance_id.to_string t.instance_id)
       t.next_project_id)
;;

let open_project t ({ instance_id; root; environment } : V1.Open_project.Request.t) =
  match check_instance t instance_id with
  | Error _ as error -> return error
  | Ok () when t.shutting_down -> return (error Conflict "daemon is shutting down")
  | Ok () ->
    let%bind canonical = canonical_project_root root in
    (match canonical with
     | Error message -> return (error Invalid_request message)
     | Ok root ->
       let key = root ^ "\000" ^ environment_key environment in
       (match Hashtbl.find t.projects_by_key key with
        | Some session ->
          return
            (Ok
               { V1.Open_project.Payload.project = session.project
               ; environment = session.summary
               ; workspace = session.workspace
               })
        | None ->
          let%bind probe = command_output (Adapter.probe_invocation ~root environment) in
          (match probe |> Result.bind ~f:Adapter.parse_probe_output with
           | Error message -> return (error Unsupported_operation message)
           | Ok dune_version ->
             let%bind inspection =
               command_output (Adapter.inspect_invocation ~root environment)
             in
             (match inspection |> Result.bind ~f:Adapter.parse_workspace with
              | Error message -> return (error Internal_failure message)
              | Ok workspace ->
                let%bind dune_name = project_name root in
                let%map manifest_load = load_manifest root in
                let name, manifest, build_alias, test_alias, driver, integration =
                  match manifest_load with
                  | Manifest_absent ->
                    ( dune_name
                    , None
                    , Integration.Manifest.default_build_alias
                    , Integration.Manifest.default_test_alias
                    , None
                    , Project_integration.generic_dune )
                  | Manifest_invalid reason ->
                    ( dune_name
                    , None
                    , Integration.Manifest.default_build_alias
                    , Integration.Manifest.default_test_alias
                    , None
                    , { Project_integration.level = Generic_dune
                      ; manifest = Unusable { reason }
                      ; driver = Absent
                      } )
                  | Manifest_valid manifest ->
                    let driver_status =
                      Option.value_map manifest.driver ~default:Absent ~f:(fun _ ->
                        Unusable { reason = "driver discovery has not started" })
                    in
                    ( manifest.project_name
                    , Some manifest
                    , manifest.build_alias
                    , manifest.test_alias
                    , manifest.driver
                    , { Project_integration.level = Manifest
                      ; manifest =
                          Available { version = Some Integration.Manifest.version }
                      ; driver = driver_status
                      } )
                in
                let summary = Adapter.environment_summary environment ~dune_version in
                let project : Project.t =
                  { id = mint_project_id t
                  ; root = Project_root.of_absolute_path root
                  ; name
                  ; integration
                  ; targets = []
                  ; configurations = []
                  }
                in
                let session =
                  { key
                  ; root
                  ; dune_name
                  ; environment
                  ; project
                  ; summary
                  ; workspace
                  ; manifest
                  ; build_alias
                  ; test_alias
                  ; driver
                  ; driver_description = None
                  }
                in
                Hashtbl.set t.projects_by_key ~key ~data:session;
                Hashtbl.set t.projects ~key:project.id ~data:session;
                emit t (Project_upsert session.project);
                Ok
                  { V1.Open_project.Payload.project = session.project
                  ; environment = session.summary
                  ; workspace = session.workspace
                  }))))
;;

let update_job t entry job =
  entry.job <- job;
  emit t (Job_upsert job)
;;

let append_log t (entry : job_entry) stream data =
  (match entry.operation, stream with
   | Simulation_task task, V1.Read_log.Stream.Stdout -> task.stdout data
   | (Driver_describe | Driver_generate_rtl _), V1.Read_log.Stream.Stdout ->
     let remaining = Integration.Driver_protocol.max_stdout_bytes - entry.stdout_bytes in
     if remaining <= 0
     then entry.stdout_overflow <- true
     else (
       let kept = String.prefix data remaining in
       entry.stdout_parts <- kept :: entry.stdout_parts;
       entry.stdout_bytes <- entry.stdout_bytes + String.length kept;
       if String.length kept < String.length data then entry.stdout_overflow <- true)
   | (Dune_action _ | Simulation_task _), _
   | (Driver_describe | Driver_generate_rtl _), Stderr -> ());
  let pieces = String.to_list data |> List.chunks_of ~length:(16 * 1024) in
  List.iter pieces ~f:(fun chars ->
    let data = String.of_char_list chars in
    let offset = entry.next_log_offset in
    let record = { stream; position = entry.log_position; length = String.length data } in
    entry.next_log_offset <- offset + 1;
    entry.log_position <- entry.log_position + record.length;
    Hashtbl.set entry.log_records ~key:offset ~data:record;
    let previous = entry.log_tail in
    entry.log_tail
    <- (let%bind () = previous in
        Writer.write entry.log_writer data;
        let%map () = Writer.flushed entry.log_writer in
        emit t (Log_available { job = entry.job.id; next_offset = offset + 1 })));
  entry.log_tail
;;

let drain t entry stream reader =
  let%map (_ : unit Reader.read_one_chunk_at_a_time_result) =
    Reader.read_one_chunk_at_a_time reader ~handle_chunk:(fun buffer ~pos ~len ->
      let data = Bigstring.To_string.sub buffer ~pos ~len in
      let%map () = append_log t entry stream data in
      `Continue)
  in
  ()
;;

let exit_status = function
  | Ok () -> Job.Exit_status.Exited 0
  | Error (`Exit_non_zero code) -> Exited code
  | Error (`Signal signal) -> Signaled { signal = Signal.to_string signal }
;;

let signal_group process signal = Signal_unix.send_i signal (`Group (Process.pid process))

let begin_escalation t entry process =
  if not entry.escalation_started
  then (
    entry.escalation_started <- true;
    signal_group process Signal.term;
    don't_wait_for
      (let%bind () = Clock.after t.kill_after in
       signal_group process Signal.kill;
       Ivar.fill_if_empty entry.escalation_finished ();
       return ()))
;;

let prune_simulation_jobs t root =
  Option.iter (Hashtbl.find t.root_queues root) ~f:(fun queue ->
    Queue.filter_inplace queue ~f:(fun entry -> not (Job.is_terminal entry.job)));
  let terminal =
    Hashtbl.data t.jobs
    |> List.filter ~f:(fun entry ->
      String.equal entry.session.root root
      && String.equal entry.job.kind.namespace "simulation"
      && Job.is_terminal entry.job)
    |> List.sort ~compare:(fun a b -> Timestamp.compare b.job.created_at a.job.created_at)
  in
  let discovery =
    Option.bind (Hashtbl.find t.simulation_service.projects root) ~f:(fun project ->
      project.discovery_job)
  in
  let pinned entry = Option.exists discovery ~f:(Job_id.equal entry.job.id) in
  let budget = Simulation.Limits.history_attempts - List.count terminal ~f:pinned in
  List.iter
    (List.drop (List.filter terminal ~f:(fun entry -> not (pinned entry))) budget)
    ~f:(fun entry ->
      Hashtbl.remove t.jobs entry.job.id;
      Hashtbl.clear entry.log_records;
      emit t (Job_removed entry.job.id);
      don't_wait_for
        (Monitor.try_with (fun () ->
           In_thread.run (fun () -> Core_unix.unlink entry.log_path))
         >>| ignore))
;;

let finish_entry t (entry : job_entry) state status failure =
  let state, failure =
    match entry.operation with
    | Simulation_task task ->
      (match
         Or_error.try_with (fun () ->
           task.finish ~cancelled:(Job.State.equal state Cancelled) status)
       with
       | Ok None -> state, failure
       | Ok (Some message) ->
         ( (if Job.State.equal state Cancelled then state else Job.State.Failed)
         , Some message )
       | Error error -> Job.State.Failed, Some (Error.to_string_hum error))
    | _ -> state, failure
  in
  (match entry.operation with
   | Simulation_task _ -> entry.operation <- Simulation_task Simulation_task.released
   | _ -> ());
  let now = Timestamp.of_time_ns (Time_ns.now ()) in
  update_job
    t
    entry
    { entry.job with
      state
    ; phase = None
    ; exit_status = status
    ; failure
    ; finished_at = Some now
    };
  Ivar.fill_if_empty entry.finished ();
  match entry.operation with
  | Simulation_task _ when String.equal entry.job.kind.namespace "simulation" ->
    prune_simulation_jobs t entry.session.root
  | _ -> ()
;;

let publish_driver_state t entry status targets configurations =
  let session = entry.session in
  let manifest = session.project.integration.manifest in
  session.project
  <- { session.project with
       integration =
         { Project_integration.level =
             Project_integration.level_of_components ~manifest ~driver:status
         ; manifest
         ; driver = status
         }
     ; targets
     ; configurations
     };
  emit t (Project_upsert session.project)
;;

let complete_driver_discovery t entry process_status =
  match process_status with
  | Job.Exit_status.Exited 0 when not entry.stdout_overflow ->
    let output = String.concat (List.rev entry.stdout_parts) in
    (match Integration.Driver_protocol.parse output with
     | Error reason ->
       entry.session.driver_description <- None;
       publish_driver_state t entry (Unusable { reason }) [] [];
       Error reason
     | Ok response ->
       let targets, configurations =
         Driver_adapter.map_describe ~project:entry.session.project.id response
       in
       entry.session.driver_description <- Some response;
       publish_driver_state
         t
         entry
         (Available { version = Some response.protocol_version })
         targets
         configurations;
       Ok ())
  | Exited 0 ->
    let reason =
      sprintf
        "driver stdout exceeded %d bytes"
        Integration.Driver_protocol.max_stdout_bytes
    in
    entry.session.driver_description <- None;
    publish_driver_state t entry (Unusable { reason }) [] [];
    Error reason
  | Exited code ->
    let reason =
      sprintf
        "driver exited with code %d; inspect job %s diagnostics"
        code
        (Job_id.to_string entry.job.id)
    in
    entry.session.driver_description <- None;
    publish_driver_state t entry (Unusable { reason }) [] [];
    Error reason
  | Signaled { signal } ->
    let reason =
      sprintf
        "driver terminated by signal %s; inspect job %s diagnostics"
        signal
        (Job_id.to_string entry.job.id)
    in
    entry.session.driver_description <- None;
    publish_driver_state t entry (Unusable { reason }) [] [];
    Error reason
  | Launch_failed { reason } ->
    entry.session.driver_description <- None;
    publish_driver_state
      t
      entry
      (Unusable { reason = "driver launch failed: " ^ reason })
      []
      [];
    Error reason
;;

type generation_selection_error =
  | Generation_unsupported of string
  | Generation_invalid of string

let generation_selection session target configuration =
  let open Integration.Driver_protocol in
  match session.driver_description with
  | None ->
    Generation_unsupported "project driver discovery is not currently available" |> Error
  | Some description
    when not
           (List.mem description.capabilities generate_rtl_capability ~equal:String.equal)
    -> Generation_unsupported "project driver does not advertise generate-rtl" |> Error
  | Some description ->
    let target_description =
      List.find description.targets ~f:(fun candidate ->
        Target_id.equal (Driver_adapter.target_id session.project.id candidate.key) target)
    in
    let configuration_description =
      List.find description.configurations ~f:(fun candidate ->
        Configuration_id.equal
          (Driver_adapter.configuration_id session.project.id candidate.key)
          configuration)
    in
    (match target_description, configuration_description with
     | None, _ ->
       Generation_invalid "target is stale or does not belong to this project session"
       |> Error
     | _, None ->
       Generation_invalid
         "configuration is stale or does not belong to this project session"
       |> Error
     | Some target_description, Some configuration_description ->
       if String.equal configuration_description.target target_description.key
       then
         Ok
           ( target_description.key
           , configuration_description.key
           , List.mem
               description.capabilities
               generate_rtl_hierarchy_capability
               ~equal:String.equal )
       else
         Generation_invalid "configuration does not belong to the selected target"
         |> Error)
;;

let remove_tree_sync path =
  let rec remove path =
    match Sys_unix.file_exists ~follow_symlinks:false path with
    | `No | `Unknown -> ()
    | `Yes ->
      if Sys_unix.is_directory_exn ~follow_symlinks:false path
      then (
        Sys_unix.ls_dir path
        |> List.iter ~f:(fun name -> remove (Filename.concat path name));
        Core_unix.rmdir path)
      else Core_unix.unlink path
  in
  remove path
;;

let cleanup_path path = In_thread.run (fun () -> remove_tree_sync path)

let mint_artifact_id t =
  t.next_artifact_id <- t.next_artifact_id + 1;
  Artifact_id.of_string
    (sprintf
       "%s-artifact-%d"
       (V1.Daemon_instance_id.to_string t.instance_id)
       t.next_artifact_id)
;;

let copy_output_file ~output_dir ~source ~destination ~max_bytes =
  let result =
    Or_error.try_with (fun () ->
      let source_stat = Core_unix.lstat source in
      if not (Poly.equal source_stat.st_kind S_REG)
      then failwith "declared output is not a regular file";
      Option.iter max_bytes ~f:(fun max_bytes ->
        if Int64.(source_stat.st_size > of_int max_bytes)
        then failwithf "declared output exceeded %d bytes" max_bytes ());
      let resolved = Filename_unix.realpath source in
      let output_root = Filename_unix.realpath output_dir in
      if not (String.is_prefix resolved ~prefix:(output_root ^ Filename.dir_sep))
      then failwith "declared output resolves outside its job output directory";
      let input = Stdlib.open_in_bin source in
      let output = Stdlib.open_out_bin destination in
      Exn.protect
        ~f:(fun () ->
          let buffer = Bytes.create (64 * 1024) in
          let rec copy bytes =
            let count = Stdlib.input input buffer 0 (Bytes.length buffer) in
            if count > 0
            then (
              let bytes = bytes + count in
              Option.iter max_bytes ~f:(fun max_bytes ->
                if bytes > max_bytes
                then failwithf "declared output exceeded %d bytes" max_bytes ());
              Stdlib.output output buffer 0 count;
              copy bytes)
          in
          copy 0;
          Stdlib.flush output)
        ~finally:(fun () ->
          Stdlib.close_in_noerr input;
          Stdlib.close_out_noerr output);
      Core_unix.chmod destination ~perm:0o600;
      let stat = Core_unix.lstat destination in
      Int64.to_int_exn stat.st_size)
  in
  if Result.is_error result
  then
    ignore
      (Or_error.try_with (fun () ->
         match Sys_unix.file_exists ~follow_symlinks:false destination with
         | `Yes -> Core_unix.unlink destination
         | `No | `Unknown -> ())
       : unit Or_error.t);
  result
;;

let read_hierarchy_file path size_in_bytes ~target ~configuration =
  if size_in_bytes > V1.max_hierarchy_bytes
  then Error (sprintf "hierarchy sidecar exceeded %d bytes" V1.max_hierarchy_bytes)
  else
    Or_error.try_with (fun () -> In_channel.read_all path)
    |> Result.map_error ~f:Error.to_string_hum
    |> Result.bind ~f:(Integration.Driver_protocol.parse_hierarchy ~target ~configuration)
;;

let generation_failure entry status =
  match status with
  | Job.Exit_status.Exited 0 when entry.stdout_overflow ->
    Some
      (sprintf
         "driver stdout exceeded %d bytes"
         Integration.Driver_protocol.max_stdout_bytes)
  | Exited 0 -> None
  | Exited code ->
    Some
      (sprintf
         "driver exited with code %d; inspect job %s diagnostics"
         code
         (Job_id.to_string entry.job.id))
  | Signaled { signal } ->
    Some
      (sprintf
         "driver terminated by signal %s; inspect job %s diagnostics"
         signal
         (Job_id.to_string entry.job.id))
  | Launch_failed { reason } -> Some ("driver launch failed: " ^ reason)
;;

let complete_generate_rtl
  t
  entry
  target_key
  configuration_key
  output_dir
  ~hierarchy_capable
  status
  =
  match generation_failure entry status with
  | Some reason -> return (Error reason)
  | None ->
    let output = String.concat (List.rev entry.stdout_parts) in
    (match
       Integration.Driver_protocol.parse_generate
         ~target:target_key
         ~configuration:configuration_key
         output
     with
     | Error reason -> return (Error reason)
     | Ok response ->
       let hierarchy_outputs =
         List.filter response.outputs ~f:Integration.Driver_protocol.hierarchy_output
       in
       if hierarchy_capable && List.length hierarchy_outputs <> 1
       then
         return
           (Error
              "hierarchy-capable driver must declare exactly one elaboration hierarchy \
               output")
       else (
         let%bind source_finish = capture_source entry.session.root in
         let source =
           match entry.source_start with
           | Some source_start -> source_identity source_start source_finish
           | None ->
             Provenance.Source_identity.unknown ~reason:"source start was not captured"
         in
         let build = Option.map response.build ~f:Driver_adapter.map_build_ref in
         let run = Option.map response.run ~f:Driver_adapter.map_run_ref in
         let created_at = Timestamp.of_time_ns (Time_ns.now ()) in
         let requested_tools =
           [ { Tool_version.tool = "project-driver-protocol"
             ; version = Some (Int.to_string Integration.Driver_protocol.version)
             }
           ]
         in
         let actual_tools =
           { Tool_version.tool = "dune"
           ; version = Some entry.session.summary.dune_version
           }
           :: { tool = "project-driver-protocol"
              ; version = Some (Int.to_string response.protocol_version)
              }
           :: List.map response.tools ~f:(fun tool ->
             { Tool_version.tool = tool.name; version = tool.version })
         in
         let environment =
           [ { Environment_identity.component = "project-environment"
             ; identity = Some entry.session.summary.provenance
             }
           ]
         in
         let copied = ref [] in
         let%bind imported =
           Deferred.List.map response.outputs ~how:`Sequential ~f:(fun output ->
             let id = mint_artifact_id t in
             let destination =
               Filename.concat
                 t.artifact_dir
                 (sprintf "artifact-%d.content" t.next_artifact_id)
             in
             let source_path = Filename.concat output_dir output.path in
             let%map copied_file =
               In_thread.run (fun () ->
                 copy_output_file
                   ~output_dir
                   ~source:source_path
                   ~destination
                   ~max_bytes:
                     (if Integration.Driver_protocol.hierarchy_output output
                      then Some V1.max_hierarchy_bytes
                      else None))
             in
             match copied_file with
             | Error error -> Error (Error.to_string_hum error)
             | Ok size_in_bytes ->
               copied := destination :: !copied;
               let provenance : Provenance.t =
                 { project_root = entry.session.project.root
                 ; target = entry.job.target
                 ; configuration = entry.job.configuration
                 ; build
                 ; run
                 ; generating_job = entry.job.id
                 ; requested_tools
                 ; actual_tools
                 ; environment
                 ; source
                 ; created_at
                 }
               in
               let artifact : Artifact.t =
                 { id
                 ; kind =
                     { namespace = output.namespace
                     ; name = output.name
                     ; role = output.role
                     ; media = output.media
                     }
                 ; project = entry.job.project
                 ; target = entry.job.target
                 ; configuration = entry.job.configuration
                 ; generating_job = entry.job.id
                 ; build
                 ; run
                 ; availability = Available
                 ; metadata =
                     { display_name = output.display_name
                     ; description = output.description
                     ; size_in_bytes = Some size_in_bytes
                     ; provenance
                     }
                 }
               in
               Ok (output, { artifact; path = destination }))
         in
         match Result.all imported with
         | Error reason ->
           let%map () =
             Deferred.List.iter !copied ~how:`Sequential ~f:(fun path ->
               cleanup_path path)
           in
           Error ("artifact import failed: " ^ reason)
         | Ok artifacts when entry.cancel_requested || t.shutting_down ->
           let%map () =
             Deferred.List.iter artifacts ~how:`Sequential ~f:(fun (_, artifact) ->
               cleanup_path artifact.path)
           in
           Error "RTL generation was cancelled during artifact import"
         | Ok artifacts ->
           let hierarchy =
             if not hierarchy_capable
             then Ok None
             else (
               let _, artifact =
                 List.find_exn artifacts ~f:(fun (output, _) ->
                   Integration.Driver_protocol.hierarchy_output output)
               in
               read_hierarchy_file
                 artifact.path
                 (Option.value_exn artifact.artifact.metadata.size_in_bytes)
                 ~target:target_key
                 ~configuration:configuration_key
               |> Result.map ~f:(fun hierarchy ->
                 let rtl_artifacts =
                   List.filter_map artifacts ~f:(fun (_, candidate) ->
                     if String.equal candidate.artifact.kind.namespace "hardcaml"
                        && String.equal candidate.artifact.kind.name "verilog"
                     then Some candidate.artifact.id
                     else None)
                 in
                 Some
                   ( artifact.artifact.id
                   , { Hierarchy.artifact = artifact.artifact.id
                     ; project = entry.job.project
                     ; target = Option.value_exn entry.job.target
                     ; configuration = Option.value_exn entry.job.configuration
                     ; generating_job = entry.job.id
                     ; rtl_artifacts
                     ; provenance = artifact.artifact.metadata.provenance
                     ; root = hierarchy.root
                     ; nodes = hierarchy.nodes
                     } )))
           in
           (match hierarchy with
            | Error reason ->
              let%map () =
                Deferred.List.iter artifacts ~how:`Sequential ~f:(fun (_, artifact) ->
                  cleanup_path artifact.path)
              in
              Error ("hierarchy import failed: " ^ reason)
            | Ok hierarchy ->
              Option.iter hierarchy ~f:(fun (id, hierarchy) ->
                Hashtbl.set t.hierarchies ~key:id ~data:{ hierarchy });
              List.iter artifacts ~f:(fun (_, artifact) ->
                Hashtbl.set t.artifacts ~key:artifact.artifact.id ~data:artifact;
                emit t (Artifact_upsert artifact.artifact));
              let artifact_ids =
                List.map artifacts ~f:(fun (_, entry) -> entry.artifact.id)
              in
              update_job
                t
                entry
                { entry.job with
                  artifacts = artifact_ids
                ; build
                ; run
                ; phase = Some "registered"
                };
              return (Ok ()))))
;;

let rec run_next t root =
  let queue = Hashtbl.find_or_add t.root_queues root ~default:Queue.create in
  let leased = Preparation_service.source_leased t.preparation_service root in
  let next =
    if not leased
    then Queue.dequeue queue
    else (
      (* A preparation is one source transaction across two supervised jobs. Leave other
         source-mutating jobs queued until its emission has finished. *)
      let before, remaining =
        List.split_while (Queue.to_list queue) ~f:(fun entry ->
          not (String.equal entry.job.kind.namespace "preparation"))
      in
      match remaining with
      | [] -> None
      | entry :: rest ->
        Queue.clear queue;
        List.iter (before @ rest) ~f:(Queue.enqueue queue);
        Some entry)
  in
  match next with
  | None ->
    if leased
    then Hash_set.add t.preparation_waiters root
    else Hash_set.remove t.running_roots root
  | Some entry when Job.is_terminal entry.job -> run_next t root
  | Some entry ->
    don't_wait_for
      (let started_at = Timestamp.of_time_ns (Time_ns.now ()) in
       update_job
         t
         entry
         { entry.job with
           state = Starting
         ; phase = Some "starting"
         ; started_at = Some started_at
         };
       let session = entry.session in
       let preflight =
         match entry.operation with
         | Dune_action _ | Driver_describe | Simulation_task _ -> Ok ()
         | Driver_generate_rtl
             { target
             ; configuration
             ; target_key
             ; configuration_key
             ; hierarchy_capable
             ; driver
             ; _
             } ->
           (match generation_selection session target configuration with
            | Ok (current_target, current_configuration, current_hierarchy_capable)
              when String.equal current_target target_key
                   && String.equal current_configuration configuration_key
                   && Bool.equal current_hierarchy_capable hierarchy_capable
                   && Option.equal String.equal session.driver (Some driver) -> Ok ()
            | Ok _ -> Error "driver declaration changed before RTL generation started"
            | Error (Generation_unsupported reason | Generation_invalid reason) ->
              Error reason)
       in
       let%bind preflight =
         match entry.operation with
         | Simulation_task task ->
           let%map result = Monitor.try_with_or_error task.preflight in
           Result.map_error result ~f:Error.to_string_hum
         | _ -> return preflight
       in
       let preflight =
         if entry.cancel_requested || t.shutting_down
         then Error "Job cancelled before launch"
         else preflight
       in
       match preflight with
       | Error reason ->
         if entry.cancel_requested || t.shutting_down
         then finish_entry t entry Cancelled None None
         else finish_entry t entry Failed None (Some reason);
         let%bind () = Writer.close entry.log_writer in
         let%bind () =
           match entry.operation with
           | Driver_generate_rtl { output_dir; _ } -> cleanup_path output_dir
           | Dune_action _ | Driver_describe | Simulation_task _ -> return ()
         in
         run_next t root;
         return ()
       | Ok () ->
         let%bind () =
           match entry.operation with
           | Driver_generate_rtl _ ->
             update_job t entry { entry.job with phase = Some "capturing source" };
             let%map source = capture_source session.root in
             entry.source_start <- Some source
           | Dune_action _ | Driver_describe | Simulation_task _ -> return ()
         in
         let invocation =
           match entry.operation with
           | Simulation_task task -> task.invocation
           | Dune_action action ->
             (match t.action_invocation with
              | None ->
                Adapter.action_invocation
                  ~build_alias:session.build_alias
                  ~test_alias:session.test_alias
                  ~root:session.root
                  ~environment:session.environment
                  action
              | Some invocation ->
                invocation ~root:session.root ~environment:session.environment action)
           | Driver_describe ->
             t.driver_invocation
               ~root:session.root
               ~environment:session.environment
               ~driver:(Option.value_exn session.driver)
           | Driver_generate_rtl { target_key; configuration_key; driver; output_dir; _ }
             ->
             t.generate_rtl_invocation
               ~root:session.root
               ~environment:session.environment
               ~driver
               ~target:target_key
               ~configuration:configuration_key
               ~output_dir
         in
         let args = List.tl invocation.argv |> Option.value ~default:[] in
         let argv0 = List.hd invocation.argv in
         let%bind created =
           Process.create
             ?argv0
             ~working_dir:invocation.cwd
             ~setpgid:Core_unix.Pgid.new_process_group
             ~prog:invocation.executable
             ~args
             ()
         in
         (match created with
          | Error launch_error ->
            let reason = Error.to_string_hum launch_error in
            (match entry.operation with
             | Driver_describe ->
               entry.session.driver_description <- None;
               publish_driver_state
                 t
                 entry
                 (Unusable { reason = "driver launch failed: " ^ reason })
                 []
                 []
             | Dune_action _ | Driver_generate_rtl _ | Simulation_task _ -> ());
            if entry.cancel_requested || t.shutting_down
            then finish_entry t entry Cancelled (Some (Launch_failed { reason })) None
            else
              finish_entry t entry Failed (Some (Launch_failed { reason })) (Some reason);
            let%bind () = Writer.close entry.log_writer in
            let%bind () =
              match entry.operation with
              | Driver_generate_rtl { output_dir; _ } -> cleanup_path output_dir
              | Dune_action _ | Driver_describe | Simulation_task _ -> return ()
            in
            run_next t root;
            return ()
          | Ok process ->
            entry.process <- Some process;
            let polling = ref true in
            don't_wait_for (Writer.close (Process.stdin process));
            update_job t entry { entry.job with state = Running; phase = Some "running" };
            (match entry.operation with
             | Simulation_task task ->
               (match Or_error.try_with task.start with
                | Ok () -> ()
                | Error error ->
                  task.fail (Error.to_string_hum error);
                  begin_escalation t entry process);
               don't_wait_for
                 (let rec poll () =
                    match entry.process with
                    | None -> return ()
                    | Some _ when not !polling -> return ()
                    | Some _ ->
                      let healthy =
                        match Or_error.try_with task.poll with
                        | Ok healthy -> healthy
                        | Error error ->
                          task.fail (Error.to_string_hum error);
                          false
                      in
                      if not healthy then begin_escalation t entry process;
                      let%bind () = Clock.after (Time_float.Span.of_ms 50.) in
                      poll ()
                  in
                  poll ());
               don't_wait_for
                 (let%map result =
                    Clock.with_timeout
                      (Time_float.Span.of_sec (Float.of_int task.timeout_seconds))
                      (Ivar.read entry.finished)
                  in
                  if Poly.equal result `Timeout && not (Ivar.is_full entry.finished)
                  then (
                    task.fail
                      (if String.equal entry.job.kind.namespace "preparation"
                       then "Preparation process timeout"
                       else "Simulation provider timeout");
                    begin_escalation t entry process))
             | _ -> ());
            if entry.cancel_requested || t.shutting_down
            then begin_escalation t entry process;
            let stdout = drain t entry Stdout (Process.stdout process) in
            let stderr = drain t entry Stderr (Process.stderr process) in
            let%bind status = Process.wait process in
            let%bind () = Deferred.all_unit [ stdout; stderr; entry.log_tail ] in
            if String.equal entry.job.kind.namespace "preparation"
            then
              update_job
                t
                entry
                { entry.job with exit_status = Some (exit_status status) };
            polling := false;
            let%bind () =
              match entry.operation with
              | Simulation_task task ->
                let%map drained = Monitor.try_with_or_error task.drain in
                (match drained with
                 | Ok () -> ()
                 | Error error -> task.fail (Error.to_string_hum error))
              | _ -> return ()
            in
            entry.process <- None;
            let%bind () = Writer.close entry.log_writer in
            let status = exit_status status in
            let%bind () =
              if entry.cancel_requested || t.shutting_down
              then (
                (match entry.operation with
                 | Driver_describe ->
                   entry.session.driver_description <- None;
                   publish_driver_state
                     t
                     entry
                     (Unusable { reason = "driver discovery was cancelled" })
                     []
                     []
                 | Dune_action _ | Driver_generate_rtl _ | Simulation_task _ -> ());
                let%bind () =
                  match entry.operation with
                  | Driver_generate_rtl { output_dir; _ } -> cleanup_path output_dir
                  | Dune_action _ | Driver_describe | Simulation_task _ -> return ()
                in
                finish_entry t entry Cancelled (Some status) None;
                return ())
              else (
                match entry.operation with
                | Dune_action _ | Simulation_task _ ->
                  (match status with
                   | Exited 0 -> finish_entry t entry Complete (Some status) None
                   | Exited _ | Signaled _ ->
                     finish_entry t entry Failed (Some status) None
                   | Launch_failed _ -> assert false);
                  return ()
                | Driver_describe ->
                  (match complete_driver_discovery t entry status with
                   | Ok () -> finish_entry t entry Complete (Some status) None
                   | Error reason ->
                     finish_entry t entry Failed (Some status) (Some reason));
                  return ()
                | Driver_generate_rtl
                    { target_key; configuration_key; hierarchy_capable; output_dir; _ } ->
                  let%bind completed =
                    complete_generate_rtl
                      t
                      entry
                      target_key
                      configuration_key
                      output_dir
                      ~hierarchy_capable
                      status
                  in
                  don't_wait_for (cleanup_path output_dir);
                  (match completed with
                   | Ok () -> finish_entry t entry Complete (Some status) None
                   | Error _ when entry.cancel_requested || t.shutting_down ->
                     finish_entry t entry Cancelled (Some status) None
                   | Error reason ->
                     finish_entry t entry Failed (Some status) (Some reason));
                  return ())
            in
            run_next t root;
            return ()))
;;

let action_kind = function
  | V1.Dune_action.Build -> { Job.Kind.namespace = "dune"; name = "build" }
  | Test -> { namespace = "dune"; name = "test" }
;;

let mint_job_id t =
  t.next_job_id <- t.next_job_id + 1;
  Job_id.of_string
    (sprintf "%s-job-%d" (V1.Daemon_instance_id.to_string t.instance_id) t.next_job_id)
;;

let submit_job
  t
  ({ instance_id; project; action; submission_key } : V1.Submit_job.Request.t)
  =
  match check_instance t instance_id with
  | Error _ as error -> return error
  | Ok () when t.shutting_down -> return (error Conflict "daemon is shutting down")
  | Ok () when String.is_empty submission_key ->
    return (error Invalid_request "submission_key must not be empty")
  | Ok () ->
    (match Hashtbl.find t.submissions submission_key with
     | Some submission ->
       if Project_id.equal project submission.project
          && equal_submission_operation submission.operation (Submit_dune action)
       then (
         let%map ready = Ivar.read submission.ready in
         Result.map ready ~f:(fun entry -> { V1.Submit_job.Payload.job = entry.job }))
       else return (error Conflict "submission_key was already used for another request")
     | None ->
       (match Hashtbl.find t.projects project with
        | None -> return (error Not_found "project is not open")
        | Some session ->
          let id = mint_job_id t in
          let submission =
            { project; operation = Submit_dune action; ready = Ivar.create () }
          in
          Hashtbl.set t.submissions ~key:submission_key ~data:submission;
          let job =
            Job.create
              ~id
              ~kind:(action_kind action)
              ~project
              ~created_at:(Timestamp.of_time_ns (Time_ns.now ()))
          in
          let log_path =
            Filename.concat
              t.log_dir
              (sprintf "job-%d-%d.log" (Pid.to_int (Core_unix.getpid ())) t.next_job_id)
          in
          let%map opened =
            Monitor.try_with_or_error (fun () ->
              Writer.open_file ~append:true ~perm:0o600 log_path)
          in
          (match opened with
           | Error open_error ->
             let failure =
               V1.Error.create
                 Internal_failure
                 ("could not open job log: " ^ Error.to_string_hum open_error)
             in
             Ivar.fill_exn submission.ready (Error failure);
             Error failure
           | Ok log_writer ->
             let entry =
               { operation = Dune_action action
               ; session
               ; job
               ; log_path
               ; log_writer
               ; log_records = Hashtbl.create (module Int)
               ; log_position = 0
               ; next_log_offset = 0
               ; log_tail = return ()
               ; stdout_parts = []
               ; stdout_bytes = 0
               ; stdout_overflow = false
               ; process = None
               ; cancel_requested = false
               ; escalation_started = false
               ; escalation_finished = Ivar.create ()
               ; finished = Ivar.create ()
               ; source_start = None
               }
             in
             Hashtbl.set t.jobs ~key:id ~data:entry;
             Ivar.fill_exn submission.ready (Ok entry);
             let queue =
               Hashtbl.find_or_add t.root_queues session.root ~default:Queue.create
             in
             Queue.enqueue queue entry;
             emit t (Job_upsert job);
             if not (Hash_set.mem t.running_roots session.root)
             then (
               Hash_set.add t.running_roots session.root;
               run_next t session.root);
             Ok { V1.Submit_job.Payload.job })))
;;

let generate_rtl
  t
  ({ instance_id; project; target; configuration; submission_key } :
    V1.Generate_rtl.Request.t)
  =
  match check_instance t instance_id with
  | Error _ as error -> return error
  | Ok () when t.shutting_down -> return (error Conflict "daemon is shutting down")
  | Ok () when String.is_empty submission_key ->
    return (error Invalid_request "submission_key must not be empty")
  | Ok () ->
    let requested = Submit_generate_rtl { target; configuration } in
    (match Hashtbl.find t.submissions submission_key with
     | Some submission ->
       if Project_id.equal project submission.project
          && equal_submission_operation submission.operation requested
       then (
         let%map ready = Ivar.read submission.ready in
         Result.map ready ~f:(fun entry -> { V1.Generate_rtl.Payload.job = entry.job }))
       else return (error Conflict "submission_key was already used for another request")
     | None ->
       (match Hashtbl.find t.projects project with
        | None -> return (error Not_found "project is not open")
        | Some session ->
          (match generation_selection session target configuration with
           | Error (Generation_unsupported reason) ->
             return (error Unsupported_operation reason)
           | Error (Generation_invalid reason) -> return (error Invalid_request reason)
           | Ok (target_key, configuration_key, hierarchy_capable) ->
             let id = mint_job_id t in
             let submission =
               { project; operation = requested; ready = Ivar.create () }
             in
             Hashtbl.set t.submissions ~key:submission_key ~data:submission;
             let created_at = Timestamp.of_time_ns (Time_ns.now ()) in
             let job =
               { (Job.create
                    ~id
                    ~kind:{ namespace = "project-driver"; name = "generate-rtl" }
                    ~project
                    ~created_at)
                 with
                 target = Some target
               ; configuration = Some configuration
               }
             in
             let log_path =
               Filename.concat
                 t.log_dir
                 (sprintf
                    "job-%d-%d.log"
                    (Pid.to_int (Core_unix.getpid ()))
                    t.next_job_id)
             in
             let output_dir =
               Filename.concat t.output_dir (sprintf "job-%d" t.next_job_id)
             in
             let%map opened =
               Monitor.try_with_or_error (fun () ->
                 let%bind () =
                   In_thread.run (fun () -> Core_unix.mkdir output_dir ~perm:0o700)
                 in
                 Writer.open_file ~append:true ~perm:0o600 log_path)
             in
             (match opened with
              | Error open_error ->
                let failure =
                  V1.Error.create
                    Internal_failure
                    ("could not create generation job storage: "
                     ^ Error.to_string_hum open_error)
                in
                Ivar.fill_exn submission.ready (Error failure);
                don't_wait_for (cleanup_path output_dir);
                Error failure
              | Ok log_writer ->
                let entry =
                  { operation =
                      Driver_generate_rtl
                        { target
                        ; configuration
                        ; target_key
                        ; configuration_key
                        ; hierarchy_capable
                        ; driver = Option.value_exn session.driver
                        ; output_dir
                        }
                  ; session
                  ; job
                  ; log_path
                  ; log_writer
                  ; log_records = Hashtbl.create (module Int)
                  ; log_position = 0
                  ; next_log_offset = 0
                  ; log_tail = return ()
                  ; stdout_parts = []
                  ; stdout_bytes = 0
                  ; stdout_overflow = false
                  ; process = None
                  ; cancel_requested = false
                  ; escalation_started = false
                  ; escalation_finished = Ivar.create ()
                  ; finished = Ivar.create ()
                  ; source_start = None
                  }
                in
                Hashtbl.set t.jobs ~key:id ~data:entry;
                Ivar.fill_exn submission.ready (Ok entry);
                let queue =
                  Hashtbl.find_or_add t.root_queues session.root ~default:Queue.create
                in
                Queue.enqueue queue entry;
                emit t (Job_upsert job);
                if not (Hash_set.mem t.running_roots session.root)
                then (
                  Hash_set.add t.running_roots session.root;
                  run_next t session.root);
                Ok { V1.Generate_rtl.Payload.job }))))
;;

let active_driver_job t session =
  Hashtbl.data t.jobs
  |> List.find ~f:(fun entry ->
    phys_equal entry.session session
    &&
    match entry.operation with
    | Driver_describe -> not (Job.is_terminal entry.job)
    | Dune_action _ | Driver_generate_rtl _ | Simulation_task _ -> false)
;;

let apply_manifest_load t session manifest_load =
  session.driver_description <- None;
  (match manifest_load with
   | Manifest_absent ->
     session.manifest <- None;
     session.build_alias <- Integration.Manifest.default_build_alias;
     session.test_alias <- Integration.Manifest.default_test_alias;
     session.driver <- None;
     session.project
     <- { session.project with
          name = session.dune_name
        ; integration = Project_integration.generic_dune
        ; targets = []
        ; configurations = []
        }
   | Manifest_invalid reason ->
     session.manifest <- None;
     session.build_alias <- Integration.Manifest.default_build_alias;
     session.test_alias <- Integration.Manifest.default_test_alias;
     session.driver <- None;
     session.project
     <- { session.project with
          name = session.dune_name
        ; integration =
            { Project_integration.level = Generic_dune
            ; manifest = Unusable { reason }
            ; driver = Absent
            }
        ; targets = []
        ; configurations = []
        }
   | Manifest_valid manifest ->
     session.manifest <- Some manifest;
     session.build_alias <- manifest.build_alias;
     session.test_alias <- manifest.test_alias;
     session.driver <- manifest.driver;
     let driver =
       Option.value_map manifest.driver ~default:Absent ~f:(fun _ ->
         Unusable { reason = "driver discovery has not started" })
     in
     session.project
     <- { session.project with
          name = manifest.project_name
        ; integration =
            { Project_integration.level = Manifest
            ; manifest = Available { version = Some Integration.Manifest.version }
            ; driver
            }
        ; targets = []
        ; configurations = []
        });
  emit t (Project_upsert session.project)
;;

let refresh_integration t ({ instance_id; project } : V1.Refresh_integration.Request.t) =
  match check_instance t instance_id with
  | Error _ as error -> return error
  | Ok () when t.shutting_down -> return (error Conflict "daemon is shutting down")
  | Ok () ->
    (match Hashtbl.find t.projects project with
     | None -> return (error Not_found "project is not open")
     | Some session ->
       (match active_driver_job t session with
        | Some _ ->
          return (error Conflict "driver discovery is already queued or running")
        | None ->
          let%bind manifest_load = load_manifest session.root in
          apply_manifest_load t session manifest_load;
          (match session.manifest, session.driver with
           | None, _ ->
             return
               (error Unsupported_operation "project has no valid Workbench manifest")
           | Some _, None -> return (Ok { V1.Refresh_integration.Payload.job = None })
           | Some _, Some _ ->
             let id = mint_job_id t in
             let job =
               Job.create
                 ~id
                 ~kind:{ namespace = "project-driver"; name = "describe" }
                 ~project
                 ~created_at:(Timestamp.of_time_ns (Time_ns.now ()))
             in
             let log_path =
               Filename.concat
                 t.log_dir
                 (sprintf
                    "job-%d-%d.log"
                    (Pid.to_int (Core_unix.getpid ()))
                    t.next_job_id)
             in
             let%map opened =
               Monitor.try_with_or_error (fun () ->
                 Writer.open_file ~append:true ~perm:0o600 log_path)
             in
             (match opened with
              | Error open_error ->
                error
                  Internal_failure
                  ("could not open discovery log: " ^ Error.to_string_hum open_error)
              | Ok log_writer ->
                let entry =
                  { operation = Driver_describe
                  ; session
                  ; job
                  ; log_path
                  ; log_writer
                  ; log_records = Hashtbl.create (module Int)
                  ; log_position = 0
                  ; next_log_offset = 0
                  ; log_tail = return ()
                  ; stdout_parts = []
                  ; stdout_bytes = 0
                  ; stdout_overflow = false
                  ; process = None
                  ; cancel_requested = false
                  ; escalation_started = false
                  ; escalation_finished = Ivar.create ()
                  ; finished = Ivar.create ()
                  ; source_start = None
                  }
                in
                Hashtbl.set t.jobs ~key:id ~data:entry;
                publish_driver_state
                  t
                  entry
                  (Unusable
                     { reason = "driver discovery pending in job " ^ Job_id.to_string id })
                  []
                  [];
                let queue =
                  Hashtbl.find_or_add t.root_queues session.root ~default:Queue.create
                in
                Queue.enqueue queue entry;
                emit t (Job_upsert job);
                if not (Hash_set.mem t.running_roots session.root)
                then (
                  Hash_set.add t.running_roots session.root;
                  run_next t session.root);
                Ok { V1.Refresh_integration.Payload.job = Some job }))))
;;

let open_project_with_discovery t request =
  let%bind opened = open_project t request in
  match opened with
  | Error _ -> return opened
  | Ok payload ->
    (match Hashtbl.find t.projects payload.project.id with
     | None -> return opened
     | Some session ->
       let should_start =
         Option.is_some session.driver
         && List.is_empty session.project.targets
         && Option.is_none (active_driver_job t session)
         &&
         match session.project.integration.driver with
         | Unusable { reason } -> String.equal reason "driver discovery has not started"
         | Absent | Available _ -> false
       in
       if not should_start
       then return opened
       else (
         let%map (_ : (V1.Refresh_integration.Payload.t, V1.Error.t) Result.t) =
           refresh_integration
             t
             { instance_id = request.instance_id; project = payload.project.id }
         in
         Ok { payload with project = session.project }))
;;

let cancel_entry t entry =
  if Job.is_terminal entry.job
  then return ()
  else (
    entry.cancel_requested <- true;
    match entry.process with
    | Some process ->
      begin_escalation t entry process;
      Deferred.all_unit [ Ivar.read entry.finished; Ivar.read entry.escalation_finished ]
    | None when Job.State.equal entry.job.state Queued ->
      (match entry.operation with
       | Driver_describe ->
         entry.session.driver_description <- None;
         publish_driver_state
           t
           entry
           (Unusable { reason = "driver discovery was cancelled" })
           []
           []
       | Dune_action _ | Driver_generate_rtl _ | Simulation_task _ -> ());
      finish_entry t entry Cancelled None None;
      let%bind () = Writer.close entry.log_writer in
      let%bind () =
        match entry.operation with
        | Driver_generate_rtl { output_dir; _ } -> cleanup_path output_dir
        | Dune_action _ | Driver_describe | Simulation_task _ -> return ()
      in
      return ()
    | None -> Ivar.read entry.finished)
;;

let cancel_job t ({ instance_id; job } : V1.Cancel_job.Request.t) =
  match check_instance t instance_id with
  | Error _ as error -> return error
  | Ok () ->
    (match Hashtbl.find t.jobs job with
     | None -> return (error Not_found "job was not found")
     | Some entry ->
       let%map () = cancel_entry t entry in
       Ok { V1.Cancel_job.Payload.job = entry.job })
;;

let read_exact reader ~position ~length =
  let buffer = Bytes.create length in
  let%bind (_ : int64) = Reader.lseek reader (Int64.of_int position) ~mode:`Set in
  let rec loop offset =
    if offset = length
    then return (Ok (Bytes.to_string buffer))
    else (
      let%bind read = Reader.read reader ~pos:offset ~len:(length - offset) buffer in
      match read with
      | `Eof -> return (Error "unexpected end of log file")
      | `Ok count -> loop (offset + count))
  in
  loop 0
;;

let rec flush_current_log_tail entry =
  let tail = entry.log_tail in
  let%bind () = tail in
  if phys_equal tail entry.log_tail then return () else flush_current_log_tail entry
;;

let read_log
  t
  ({ instance_id; job; offset; max_records; max_bytes } : V1.Read_log.Request.t)
  =
  match check_instance t instance_id with
  | Error _ as error -> return error
  | Ok ()
    when max_records <= 0
         || max_records > V1.max_log_records
         || max_bytes <= 0
         || max_bytes > V1.max_log_bytes ->
    return (error Invalid_request "invalid log read bounds")
  | Ok () ->
    (match Hashtbl.find t.jobs job with
     | None -> return (error Not_found "job was not found")
     | Some entry when offset < 0 || offset > entry.next_log_offset ->
       return (error Invalid_request "log offset is outside the available range")
     | Some entry ->
       let%bind () = flush_current_log_tail entry in
       let rec select index count bytes records =
         if count = max_records || index = entry.next_log_offset
         then List.rev records, index
         else (
           let record = Hashtbl.find_exn entry.log_records index in
           if bytes + record.length > max_bytes
           then List.rev records, index
           else select (index + 1) (count + 1) (bytes + record.length) (record :: records))
       in
       let metadata, next_offset = select offset 0 0 [] in
       let%bind records =
         match metadata with
         | [] -> return (Ok [])
         | _ ->
           Monitor.try_with (fun () ->
             let%bind reader = Reader.open_file entry.log_path in
             Monitor.protect
               ~finally:(fun () -> Reader.close reader)
               (fun () ->
                 Deferred.List.mapi metadata ~how:`Sequential ~f:(fun index record ->
                   let%map data =
                     read_exact reader ~position:record.position ~length:record.length
                     >>| Result.ok_or_failwith
                   in
                   { V1.Read_log.Record.offset = offset + index
                   ; stream = record.stream
                   ; data
                   })))
           >>| Result.map_error ~f:Exn.to_string
       in
       (match records with
        | Error message -> return (error Internal_failure message)
        | Ok records ->
          return
            (Ok
               { V1.Read_log.Payload.records
               ; next_offset
               ; eof = Job.is_terminal entry.job && next_offset = entry.next_log_offset
               })))
;;

let mark_artifact_unavailable t entry reason =
  let artifact = { entry.artifact with availability = Unavailable { reason } } in
  entry.artifact <- artifact;
  emit t (Artifact_upsert artifact)
;;

let read_artifact
  t
  ({ instance_id; artifact; offset; max_bytes } : V1.Read_artifact.Request.t)
  =
  match check_instance t instance_id with
  | Error _ as error -> return error
  | Ok () when max_bytes <= 0 || max_bytes > V1.max_artifact_bytes ->
    return (error Invalid_request "invalid artifact read bound")
  | Ok () ->
    (match Hashtbl.find t.artifacts artifact with
     | None -> return (error Not_found "artifact was not found")
     | Some entry ->
       let%bind stat =
         Monitor.try_with (fun () -> In_thread.run (fun () -> Core_unix.lstat entry.path))
       in
       (match stat with
        | Error _ ->
          let reason = "artifact content is missing" in
          mark_artifact_unavailable t entry reason;
          return (error Not_found reason)
        | Ok stat when not (Poly.equal stat.st_kind S_REG) ->
          let reason = "artifact content is not a regular file" in
          mark_artifact_unavailable t entry reason;
          return (error Not_found reason)
        | Ok stat ->
          let total_size = Int64.to_int_exn stat.st_size in
          if offset < 0 || offset > total_size
          then
            return
              (error Invalid_request "artifact offset is outside the available range")
          else (
            let length = Int.min max_bytes (total_size - offset) in
            let%bind contents =
              Monitor.try_with (fun () ->
                let%bind reader = Reader.open_file entry.path in
                Monitor.protect
                  ~finally:(fun () -> Reader.close reader)
                  (fun () ->
                    read_exact reader ~position:offset ~length >>| Result.ok_or_failwith))
            in
            match contents with
            | Error exn ->
              let reason = "artifact content could not be read: " ^ Exn.to_string exn in
              mark_artifact_unavailable t entry reason;
              return (error Not_found reason)
            | Ok data ->
              let next_offset = offset + String.length data in
              return
                (Ok
                   { V1.Read_artifact.Payload.data
                   ; next_offset
                   ; total_size
                   ; eof = next_offset = total_size
                   }))))
;;

let read_hierarchy t ({ instance_id; artifact } : V1.Read_hierarchy.Request.t) =
  match check_instance t instance_id with
  | Error _ as error -> return error
  | Ok () ->
    (match Hashtbl.find t.artifacts artifact with
     | None -> return (error Not_found "hierarchy artifact was not found")
     | Some entry
       when not
              (String.equal
                 entry.artifact.kind.namespace
                 Integration.Driver_protocol.hierarchy_namespace
               && String.equal
                    entry.artifact.kind.name
                    Integration.Driver_protocol.hierarchy_name
               && Artifact.Role.equal entry.artifact.kind.role Report
               && Option.equal
                    String.equal
                    entry.artifact.kind.media
                    (Some Integration.Driver_protocol.hierarchy_media)) ->
       return (error Invalid_request "artifact is not an elaboration hierarchy")
     | Some _ ->
       (match Hashtbl.find t.hierarchies artifact with
        | None ->
          return
            (error
               Unsupported_operation
               "this artifact is not a registered structured hierarchy result")
        | Some entry ->
          return (Ok { V1.Read_hierarchy.Payload.hierarchy = entry.hierarchy })))
;;

let workspace t (request : Workspace.Request.t) =
  match check_instance t request.instance_id with
  | Error error -> return (Error error)
  | Ok () ->
    (match Hashtbl.find t.projects request.project with
     | None -> return (error Not_found "Unknown project")
     | Some session ->
       Workspace_service.handle
         t.workspace_service
         ~project_key:session.key
         request.operation)
;;

let asic_without_preparation t (request : Asic.Request.t) =
  match check_instance t request.instance_id with
  | Error error -> return (Error error)
  | Ok () ->
    if t.shutting_down
    then return (error Conflict "Daemon is shutting down")
    else (
      match Hashtbl.find t.projects request.project with
      | None -> return (error Not_found "Unknown project")
      | Some session ->
        Asic_service.handle
          t.asic_service
          ~root:session.root
          ~environment:session.environment
          request.operation)
;;

let simulation t (request : Simulation.Request.t) =
  match check_instance t request.instance_id with
  | Error error -> return (Error error)
  | Ok () when t.shutting_down -> return (error Conflict "Daemon is shutting down")
  | Ok () ->
    (match Hashtbl.find t.projects request.project with
     | None -> return (error Not_found "Unknown project")
     | Some session ->
       let verified_asic = ref [] in
       let catalog_matches snapshot (input : Simulation.Asic_input.t) =
         List.exists snapshot.Asic.Snapshot.summaries ~f:(fun summary ->
           Run_ref.equal summary.Asic.Summary.run input.run
           && Asic.Summary.Freshness.equal summary.freshness Validated
           && Option.exists summary.terminal ~f:(fun terminal ->
             String.equal terminal.Asic.Terminal_result.attempt input.attempt))
         && List.exists snapshot.artifacts ~f:(fun reference ->
           Run_ref.equal reference.Asic_artifact.Reference.run input.run
           && String.equal reference.terminal_attempt input.attempt
           && String.equal reference.id input.artifact_id
           && String.equal reference.sha256 input.sha256)
       in
       let schedule ~name ~reservation ~prepare =
         let reservation =
           Option.map reservation ~f:(fun (key, payload) ->
             let key = "simulation:" ^ session.root ^ ":" ^ key in
             if Hashtbl.mem t.submissions key
             then
               Simulation_service.rpc_error
                 Conflict
                 "Simulation submission is already reserved";
             let submission =
               { project = request.project
               ; operation = Submit_simulation payload
               ; ready = Ivar.create ()
               }
             in
             Hashtbl.set t.submissions ~key ~data:submission;
             key, submission)
         in
         let id = mint_job_id t in
         let job =
           Job.create
             ~id
             ~kind:{ namespace = "simulation"; name }
             ~project:request.project
             ~created_at:(Timestamp.of_time_ns (Time_ns.now ()))
         in
         let log_path = Filename.concat t.log_dir (Job_id.to_string id ^ ".log") in
         let%bind opened =
           Monitor.try_with_or_error (fun () ->
             Writer.open_file ~append:true ~perm:0o600 log_path)
         in
         let release error =
           Option.iter reservation ~f:(fun (key, submission) ->
             Ivar.fill_if_empty
               submission.ready
               (Error (V1.Error.create Internal_failure (Error.to_string_hum error)));
             Hashtbl.remove t.submissions key)
         in
         let log_writer =
           match opened with
           | Ok writer -> writer
           | Error error ->
             release error;
             raise (Error.to_exn error)
         in
         match
           Result.try_with (fun () ->
             if not (List.is_empty !verified_asic)
             then (
               let current =
                 Asic_service.peek_snapshot
                   t.asic_service
                   ~root:session.root
                   ~environment:session.environment
               in
               if not
                    (Option.exists current ~f:(fun snapshot ->
                       List.for_all !verified_asic ~f:(catalog_matches snapshot)))
               then
                 Simulation_service.rpc_error
                   Conflict
                   "ASIC adoption changed before simulation reservation");
             prepare id)
         with
         | Error failure ->
           release (Error.of_exn failure);
           let%bind () = Writer.close log_writer in
           raise failure
         | Ok (task : Simulation_task.t) ->
           let task =
             { task with
               finish =
                 (fun ~cancelled status ->
                   Exn.protect
                     ~f:(fun () -> task.finish ~cancelled status)
                     ~finally:(fun () ->
                       Option.iter reservation ~f:(fun (key, _) ->
                         Hashtbl.remove t.submissions key)))
             }
           in
           let entry =
             { operation = Simulation_task task
             ; session
             ; job
             ; log_path
             ; log_writer
             ; log_records = Hashtbl.create (module Int)
             ; log_position = 0
             ; next_log_offset = 0
             ; log_tail = return ()
             ; stdout_parts = []
             ; stdout_bytes = 0
             ; stdout_overflow = false
             ; process = None
             ; cancel_requested = false
             ; escalation_started = false
             ; escalation_finished = Ivar.create ()
             ; finished = Ivar.create ()
             ; source_start = None
             }
           in
           Hashtbl.set t.jobs ~key:id ~data:entry;
           Option.iter reservation ~f:(fun (_, submission) ->
             Ivar.fill_exn submission.ready (Ok entry));
           let queue =
             Hashtbl.find_or_add t.root_queues session.root ~default:Queue.create
           in
           Queue.enqueue queue entry;
           emit t (Job_upsert job);
           if not (Hash_set.mem t.running_roots session.root)
           then (
             Hash_set.add t.running_roots session.root;
             run_next t session.root);
           return id
       in
       let cancel job =
         match Hashtbl.find t.jobs job with
         | None -> return ()
         | Some entry -> cancel_entry t entry
       in
       let verify_asic inputs =
         if List.is_empty inputs
         then return ()
         else (
           let%bind result =
             Asic_service.handle
               t.asic_service
               ~root:session.root
               ~environment:session.environment
               Asic.Operation.Get
           in
           let snapshot =
             match result with
             | Ok snapshot -> snapshot
             | Error error -> raise (Simulation_service.Rpc_error error)
           in
           let adopted snapshot (input : Simulation.Asic_input.t) =
             List.exists snapshot.Asic.Snapshot.summaries ~f:(fun summary ->
               Run_ref.equal summary.Asic.Summary.run input.run
               && Asic.Summary.Freshness.equal summary.freshness Validated
               && Option.exists summary.terminal ~f:(fun terminal ->
                 String.equal terminal.Asic.Terminal_result.attempt input.attempt))
           in
           let%map () =
             Deferred.List.iter
               inputs
               ~how:`Sequential
               ~f:(fun (input : Simulation.Asic_input.t) ->
                 if not (adopted snapshot input)
                 then
                   Simulation_service.rpc_error
                     Conflict
                     "ASIC input requires the currently adopted validated terminal \
                      attempt";
                 let reference =
                   List.find snapshot.artifacts ~f:(fun reference ->
                     Run_ref.equal reference.Asic_artifact.Reference.run input.run
                     && String.equal reference.terminal_attempt input.attempt
                     && String.equal reference.id input.artifact_id
                     && String.equal reference.sha256 input.sha256)
                 in
                 match reference with
                 | None ->
                   Simulation_service.rpc_error
                     Conflict
                     "ASIC input is not in the adopted artifact catalog"
                 | Some reference ->
                   let%bind page =
                     In_thread.run (fun () ->
                       Asic_artifacts.read_bytes ~reference ~offset:0 ~limit:1)
                   in
                   Option.iter page.error ~f:(fun message ->
                     Simulation_service.rpc_error Conflict message);
                   let%map current =
                     Asic_service.handle
                       t.asic_service
                       ~root:session.root
                       ~environment:session.environment
                       Asic.Operation.Get
                   in
                   let current =
                     match current with
                     | Ok snapshot -> snapshot
                     | Error error -> raise (Simulation_service.Rpc_error error)
                   in
                   if not
                        (adopted current input
                         && List.exists
                              current.artifacts
                              ~f:(Asic_artifact.Reference.equal reference))
                   then
                     Simulation_service.rpc_error
                       Conflict
                       "ASIC catalog changed while validating simulation inputs")
           in
           verified_asic := inputs)
       in
       Simulation_service.handle
         t.simulation_service
         ~root:session.root
         ~environment:session.environment
         ~schedule
         ~cancel
         ~verify_asic
         request.operation)
;;

let preparation_internal
  ?(unique = false)
  ?is_cancelled
  t
  (request : Preparation.Request.t)
  =
  match check_instance t request.instance_id with
  | Error error -> return (Error error)
  | Ok () when t.shutting_down -> return (error Conflict "Daemon is shutting down")
  | Ok () ->
    (match Hashtbl.find t.projects request.project with
     | None -> return (error Not_found "Unknown project")
     | Some session ->
       let schedule ~name ~cancelled (task : Simulation_task.t) =
         let id = mint_job_id t in
         let job =
           Job.create
             ~id
             ~kind:{ namespace = "preparation"; name }
             ~project:request.project
             ~created_at:(Timestamp.of_time_ns (Time_ns.now ()))
         in
         let log_path = Filename.concat t.log_dir (Job_id.to_string id ^ ".log") in
         let%map log_writer = Writer.open_file ~append:true ~perm:0o600 log_path in
         let task =
           { task with
             drain =
               (fun () ->
                 let entry = Hashtbl.find_exn t.jobs id in
                 match entry.job.exit_status with
                 | Some (Job.Exit_status.Exited 0)
                   when (not entry.cancel_requested) && not t.shutting_down ->
                   task.drain ()
                 | _ -> return ())
           }
         in
         let entry =
           { operation = Simulation_task task
           ; session
           ; job
           ; log_path
           ; log_writer
           ; log_records = Hashtbl.create (module Int)
           ; log_position = 0
           ; next_log_offset = 0
           ; log_tail = return ()
           ; stdout_parts = []
           ; stdout_bytes = 0
           ; stdout_overflow = false
           ; process = None
           ; cancel_requested = false
           ; escalation_started = false
           ; escalation_finished = Ivar.create ()
           ; finished = Ivar.create ()
           ; source_start = None
           }
         in
         Hashtbl.set t.jobs ~key:id ~data:entry;
         emit t (Job_upsert job);
         if cancelled () || t.shutting_down
         then (
           finish_entry t entry Cancelled None None;
           don't_wait_for (Writer.close log_writer))
         else (
           let queue =
             Hashtbl.find_or_add t.root_queues session.root ~default:Queue.create
           in
           Queue.enqueue queue entry;
           if Hash_set.mem t.preparation_waiters session.root
           then (
             Hash_set.remove t.preparation_waiters session.root;
             run_next t session.root)
           else if not (Hash_set.mem t.running_roots session.root)
           then (
             Hash_set.add t.running_roots session.root;
             run_next t session.root));
         entry.job
       in
       let import ~job ~valid ~output_dir ~files =
         let entry = Hashtbl.find_exn t.jobs job in
         let copied = ref [] in
         let%bind result =
           Monitor.try_with_or_error (fun () ->
             Deferred.List.map files ~how:`Sequential ~f:(fun (file, expected_hash) ->
               let id = mint_artifact_id t in
               let destination =
                 Filename.concat t.artifact_dir (Artifact_id.to_string id ^ ".content")
               in
               let%bind copied_file =
                 In_thread.run (fun () ->
                   copy_output_file
                     ~output_dir
                     ~source:(Filename.concat output_dir file)
                     ~destination
                     ~max_bytes:(Some (16 * 1024 * 1024)))
               in
               let size = Or_error.ok_exn copied_file in
               copied := destination :: !copied;
               let%map () =
                 In_thread.run (fun () ->
                   if not
                        (String.equal
                           expected_hash
                           (Preparation_receipt.sha256 (In_channel.read_all destination)))
                   then failwith "Bundle bytes changed during artifact import")
               in
               let created_at = Timestamp.of_time_ns (Time_ns.now ()) in
               let provenance : Provenance.t =
                 { project_root = session.project.root
                 ; target = None
                 ; configuration = None
                 ; build = None
                 ; run = None
                 ; generating_job = job
                 ; requested_tools = []
                 ; actual_tools =
                     [ { tool = "dune"; version = Some session.summary.dune_version } ]
                 ; environment =
                     [ { component = "project-environment"
                       ; identity = Some session.summary.provenance
                       }
                     ]
                 ; source =
                     Provenance.Source_identity.unknown
                       ~reason:"Exact source evidence is in the bundle manifest"
                 ; created_at
                 }
               in
               let artifact : Artifact.t =
                 { id
                 ; kind =
                     { namespace = "preparation"
                     ; name = "bundle-file"
                     ; role = Report
                     ; media = None
                     }
                 ; project = request.project
                 ; target = None
                 ; configuration = None
                 ; generating_job = job
                 ; build = None
                 ; run = None
                 ; availability = Available
                 ; metadata =
                     { display_name = file
                     ; description =
                         Some "Emitted bundle input (not physical execution evidence)"
                     ; size_in_bytes = Some size
                     ; provenance
                     }
                 }
               in
               { artifact; path = destination }))
         in
         match result with
         | Error error ->
           let%map () = Deferred.List.iter !copied ~how:`Sequential ~f:cleanup_path in
           Error error
         | Ok _ when entry.cancel_requested || t.shutting_down || not (valid ()) ->
           let%map () = Deferred.List.iter !copied ~how:`Sequential ~f:cleanup_path in
           Or_error.error_string "Preparation cancelled or failed during import"
         | Ok artifacts ->
           List.iter artifacts ~f:(fun artifact ->
             Hashtbl.set t.artifacts ~key:artifact.artifact.id ~data:artifact;
             emit t (Artifact_upsert artifact.artifact));
           let ids = List.map artifacts ~f:(fun a -> a.artifact.id) in
           update_job t entry { entry.job with artifacts = ids };
           return (Ok ids)
       in
       Preparation_service.handle
         ~unique
         ?is_cancelled
         ~on_release:(fun () ->
           if Hash_set.mem t.preparation_waiters session.root
           then (
             Hash_set.remove t.preparation_waiters session.root;
             run_next t session.root))
         t.preparation_service
         ~root:session.root
         ~project_key:session.key
         ~environment:session.environment
         ~schedule
         ~import
         ~get_job:(fun id -> Option.map (Hashtbl.find t.jobs id) ~f:(fun e -> e.job))
         ~wait:(fun id ->
           let entry = Hashtbl.find_exn t.jobs id in
           let%map () = Ivar.read entry.finished in
           entry.job)
         ~cancel:(fun id ->
           match Hashtbl.find t.jobs id with
           | None -> return ()
           | Some e -> cancel_entry t e)
         request.operation)
;;

let preparation t request = preparation_internal t request

let asic t request =
  Asic_service.set_preparation_runner
    t.asic_service
    (fun ~root ~environment ~unique ~cancelled operation ->
       match
         Hashtbl.data t.projects
         |> List.find ~f:(fun session ->
           String.equal session.root root
           && V1.Environment_selection.equal session.environment environment)
       with
       | None -> return (error Not_found "Preparation project session unavailable")
       | Some session ->
         preparation_internal
           ~unique
           ~is_cancelled:cancelled
           t
           { Preparation.Request.instance_id = t.instance_id
           ; project = session.project.id
           ; operation
           });
  asic_without_preparation t request
;;

let shutdown t =
  t.shutting_down <- true;
  Preparation_service.stop t.preparation_service;
  let%bind () = Asic_service.shutdown t.asic_service in
  let%bind () =
    Hashtbl.data t.jobs |> Deferred.List.iter ~how:`Parallel ~f:(cancel_entry t)
  in
  let%bind () = Preparation_service.completion t.preparation_service in
  Monitor.try_with (fun () ->
    In_thread.run (fun () ->
      remove_tree_sync t.log_dir;
      remove_tree_sync t.artifact_dir))
  >>| ignore
;;
