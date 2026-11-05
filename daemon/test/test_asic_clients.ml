open! Core
open! Async
open Hardcaml_workbench_protocol
module Rpc = Hardcaml_workbench_rpc_server.Rpc_server
module Service = Hardcaml_workbench_backend.Service
module Client = Hardcaml_workbench_native_http.Client
module Config = Hardcaml_workbench_project_integration.Asic_config

let require condition message = if not condition then failwith message

let rpc_ok result =
  match Or_error.ok_exn result with
  | Ok value -> value
  | Error error -> raise_s [%message "RPC failed" (error : V1.Error.t)]
;;

let bounded label deferred =
  match%map Clock.with_timeout (Time_float.Span.of_sec 15.) deferred with
  | `Result result -> result
  | `Timeout -> failwith ("WB-065 barrier timed out: " ^ label)
;;

let rec remove_tree path =
  match Sys_unix.file_exists ~follow_symlinks:false path with
  | `No | `Unknown -> ()
  | `Yes ->
    if Sys_unix.is_directory_exn ~follow_symlinks:false path
    then (
      List.iter (Sys_unix.ls_dir path) ~f:(fun name ->
        remove_tree (Filename.concat path name));
      Core_unix.rmdir path)
    else Core_unix.unlink path
;;

(* The provider cannot cross these FIFO boundaries until explicitly released. Polling
   below only waits for daemon publication, never guesses when a process has started. *)
let gate root name =
  let prefix = Filename.concat root ("wb065-" ^ name) in
  let%map () =
    In_thread.run (fun () ->
      Core_unix.mkfifo (prefix ^ ".ready") ~perm:0o600;
      Core_unix.mkfifo (prefix ^ ".release") ~perm:0o600)
  in
  prefix
;;

let arrived prefix =
  In_thread.run (fun () ->
    Core_unix.with_file
      (prefix ^ ".ready")
      ~mode:[ O_RDWR; O_NONBLOCK; O_CLOEXEC ]
      ~f:(fun fd ->
        let ready =
          Core_unix.select
            ~restart:true
            ~read:[ fd ]
            ~write:[]
            ~except:[]
            ~timeout:(`After (Time_ns.Span.of_sec 15.))
            ()
        in
        require (not (List.is_empty ready.read)) ("FIFO arrival timed out: " ^ prefix);
        let bytes = Bytes.create 4096 in
        let n = Core_unix.read fd ~buf:bytes in
        require (n > 0 && n < 4096) "Invalid FIFO identity";
        Bytes.sub bytes ~pos:0 ~len:n |> Bytes.to_string))
;;

let release prefix =
  let deadline = Clock.after (Time_float.Span.of_sec 15.) in
  let rec loop () =
    require (not (Deferred.is_determined deadline)) "FIFO release timed out";
    let%bind result =
      In_thread.run (fun () ->
        try
          Core_unix.with_file
            (prefix ^ ".release")
            ~mode:[ O_WRONLY; O_NONBLOCK; O_CLOEXEC ]
            ~f:(fun fd ->
              require
                (Core_unix.write fd ~buf:(Bytes.of_string "go") = 2)
                "Incomplete FIFO release");
          true
        with
        | Core_unix.Unix_error (ENXIO, _, _) -> false)
    in
    if result
    then Deferred.unit
    else (
      let%bind () = Scheduler.yield () in
      loop ())
  in
  loop ()
;;

let write_json path json =
  In_thread.run (fun () -> Out_channel.write_all path ~data:(Yojson.Safe.to_string json))
;;

let finalization (snapshot : Asic.Snapshot.t) =
  List.find_exn snapshot.finalizations ~f:(fun f -> String.equal f.key "shared-key")
;;

let task (snapshot : Asic.Snapshot.t) key =
  List.find_exn snapshot.operations ~f:(fun op -> String.equal op.key key)
;;

let asic client instance_id project operation =
  Client.asic client { instance_id; project; operation } >>| rpc_ok
;;

let wait client instance_id project label predicate =
  let deadline = Clock.after (Time_float.Span.of_sec 15.) in
  let rec loop () =
    require
      (not (Deferred.is_determined deadline))
      ("WB-065 publication timed out: " ^ label);
    let%bind snapshot = asic client instance_id project Get in
    if predicate snapshot
    then return snapshot
    else (
      let%bind () = Scheduler.yield () in
      loop ())
  in
  loop ()
;;

let calls root =
  In_thread.run (fun () ->
    In_channel.read_lines (Filename.concat root "calls")
    |> List.map ~f:(fun line ->
      match Yojson.Safe.from_string line with
      | `List args -> List.map args ~f:Yojson.Safe.Util.to_string
      | _ -> failwith "Invalid provider call log"))
;;

let main () =
  let directory = Filename_unix.temp_dir "workbench-wb065-rpc-" "" in
  let root = Filename.concat directory "project" in
  let state_dir = Filename.concat directory "state" in
  let services = ref [] in
  let servers = ref [] in
  let sockets = ref [] in
  let response_accepted = Ivar.create () in
  let response_release = Ivar.create () in
  let create instance_id =
    let%bind service =
      Service.create
        ~instance_id
        ~state_dir
        ~log_dir:(Filename.concat directory ("logs-" ^ instance_id))
        ()
      >>| Or_error.ok_exn
    in
    services := service :: !services;
    let rpc = Rpc.create ~application_version:"wb065-test" ~instance_id ~service in
    let%map server =
      Cohttp_async.Server.create
        ~on_handler_error:`Ignore
        (Tcp.Where_to_listen.bind_to
           Tcp.Bind_to_address.Localhost
           Tcp.Bind_to_port.On_port_chosen_by_os)
        (fun ~body peer request ->
           let%bind response = Rpc.callback rpc ~body peer request in
           if Cohttp.Header.mem (Cohttp.Request.headers request) "x-wb065-detach"
           then (
             Ivar.fill_if_empty response_accepted ();
             let%map () = Ivar.read response_release in
             response)
           else return response)
    in
    servers := server :: !servers;
    service, server
  in
  let client server =
    Client.create
      ~timeout:(Time_float.Span.of_sec 15.)
      (sprintf "http://127.0.0.1:%d" (Cohttp_async.Server.listening_on server))
  in
  let open_project client instance_id =
    let%map opened =
      Client.open_project client { instance_id; root; environment = Inherit_daemon }
      >>| rpc_ok
    in
    opened.project.id
  in
  Monitor.protect
    ~finally:(fun () ->
      Ivar.fill_if_empty response_release ();
      let%bind () =
        Deferred.List.iter !sockets ~how:`Sequential ~f:(fun (reader, writer) ->
          let%bind () = Writer.close writer in
          Reader.close reader)
      in
      let%bind () = Deferred.List.iter !services ~how:`Sequential ~f:Service.shutdown in
      let%bind () =
        Deferred.List.iter !servers ~how:`Sequential ~f:(fun server ->
          Cohttp_async.Server.close server)
      in
      In_thread.run (fun () -> remove_tree directory))
    (fun () ->
      let%bind () =
        In_thread.run (fun () ->
          Core_unix.mkdir root;
          Out_channel.write_all
            (Filename.concat root "dune-project")
            ~data:"(lang dune 3.22)\n(name wb065_rpc_fixture)\n";
          let fixture = Filename.concat root "fixture.py" in
          Out_channel.write_all
            fixture
            ~data:(In_channel.read_all "../../backend/test/asic/fake_provider.py");
          Core_unix.chmod fixture ~perm:0o700;
          let config : Config.t =
            { schema_version = 1
            ; project_executable = fixture
            ; provider_executable = fixture
            ; results_root = Filename.concat root "results"
            ; toolchain = root
            ; python = None
            ; support_tools = None
            ; pdk_root = None
            ; stage_timeout_seconds = Some 15
            }
          in
          Out_channel.write_all
            (Filename.concat root Config.filename)
            ~data:(Sexp.to_string (Config.sexp_of_t config));
          let attempt = Filename.concat root "attempt-terminal" in
          Core_unix.mkdir attempt;
          Out_channel.write_all (Filename.concat attempt "done") ~data:"")
      in
      let owner_id = "wb065-owner" in
      let%bind _, owner_server = create owner_id in
      let first = client owner_server in
      let second = client owner_server in
      let%bind project = open_project first owner_id in
      let%bind registered =
        asic
          first
          owner_id
          project
          (Register
             { attempt = Filename.concat root "attempt-terminal"
             ; stream_id = "stream-terminal"
             })
      in
      let run = (List.hd_exn registered.runs).run in
      let%bind (_ : Asic.Snapshot.t) = asic first owner_id project (Load_summary run) in
      let%bind loaded =
        wait first owner_id project "terminal execution summary" (fun s ->
          List.exists s.summaries ~f:(fun summary -> Run_ref.equal summary.run run))
      in
      let execution_file = (List.hd_exn loaded.summaries).execution_file in
      let finalize =
        Asic.Operation.Finalize
          { key = "shared-key"; run; execution_file; acceptance = None }
      in
      let%bind producer_gate = gate root "rpc-producer" in
      let%bind owner_reader_gate = gate root "rpc-owner-reader" in
      let%bind () =
        write_json
          (Filename.concat root "wb065-finalize.json")
          (`Assoc
            [ "after_allocation", `String "rpc-producer"
            ; "initial_inspect_gate", `String "rpc-owner-reader"
            ])
      in
      (* Hold the first response AFTER dispatch. Close its real TCP socket without reading
         a response, while an independent HTTP client submits the exact key. *)
      let%bind _, reader, writer =
        Tcp.connect
          (Tcp.Where_to_connect.of_host_and_port
             { host = "127.0.0.1"; port = Cohttp_async.Server.listening_on owner_server })
      in
      sockets := (reader, writer) :: !sockets;
      let body =
        Sexp.to_string_mach
          (Asic.Request.sexp_of_t
             { instance_id = owner_id; project; operation = finalize })
      in
      Writer.write
        writer
        (sprintf
           "POST /api/v1/asic HTTP/1.1\r\n\
            Host: 127.0.0.1\r\n\
            Content-Type: %s\r\n\
            %s: 1\r\n\
            X-WB065-Detach: 1\r\n\
            Content-Length: %d\r\n\
            \r\n\
            %s"
           V1.content_type
           V1.protocol_header
           (String.length body)
           body);
      let concurrent = asic second owner_id project finalize in
      let%bind () =
        bounded "first accepted response held" (Ivar.read response_accepted)
      in
      let%bind (_ : Asic.Snapshot.t) = concurrent in
      let%bind () = Writer.close writer in
      let%bind () = Reader.close reader in
      sockets := [];
      Ivar.fill_exn response_release ();
      let%bind attempt = arrived producer_gate in
      let%bind reader_attempt = arrived owner_reader_gate in
      require
        (String.equal attempt reader_attempt)
        "Automatic reader retargeted allocation";
      let%bind allocated =
        wait second owner_id project "persisted allocation" (fun s ->
          Option.equal String.equal (finalization s).attempt (Some attempt))
      in
      let original = finalization allocated in
      require
        (original.owned
         && Run_ref.equal original.run run
         && String.equal original.execution_file execution_file
         && not original.acceptance_requested)
        "Client detach lost the exact owned reservation";
      let%bind operation_id =
        In_thread.run (fun () ->
          let receipt =
            In_channel.read_all (Filename.concat attempt "operation.json")
            |> Yojson.Safe.from_string
          in
          let open Yojson.Safe.Util in
          let operation_id = receipt |> member "attempt_id" |> to_string in
          require
            (String.equal operation_id (Filename.basename attempt)
             && String.equal
                  (receipt |> member "request" |> member "execution" |> to_string)
                  execution_file)
            "Allocated operation ID or exact execution changed";
          operation_id)
      in
      let%bind retry = asic (client owner_server) owner_id project finalize in
      require
        (Option.equal String.equal (finalization retry).attempt (Some attempt))
        "Reconnected same-key retry changed allocation";
      let%bind conflict =
        Client.asic
          second
          { instance_id = owner_id
          ; project
          ; operation =
              Finalize
                { key = "shared-key"
                ; run
                ; execution_file = execution_file ^ ".other"
                ; acceptance = None
                }
          }
      in
      require
        (Result.is_error (Or_error.ok_exn conflict))
        "RPC accepted conflicting inputs";
      (* A second daemon reads the persisted allocation without acquiring the live owner's
         process. A newer directory must never become its observation target. *)
      let%bind () =
        In_thread.run (fun () ->
          let decoy = Filename.concat (Filename.dirname attempt) "zzzz-newer-operation" in
          Core_unix.mkdir decoy;
          Out_channel.write_all (Filename.concat decoy "operation.json") ~data:"{}")
      in
      let observer_id = "wb065-reader" in
      let%bind observer_service, observer_server = create observer_id in
      let observer = client observer_server in
      let%bind observer_project = open_project observer observer_id in
      let%bind restored = asic observer observer_id observer_project Get in
      require
        ((not (finalization restored).owned)
         && String.equal (finalization restored).state "unknown"
         && Option.equal String.equal (finalization restored).attempt (Some attempt))
        "Read-only reconnect did not restore the exact unowned allocation";
      let%bind stale =
        Client.asic
          observer
          { instance_id = owner_id
          ; project = observer_project
          ; operation = Observe_finalization "shared-key"
          }
      in
      require
        (match Or_error.ok_exn stale with
         | Error error -> V1.Error.Kind.equal error.kind Instance_changed
         | Ok _ -> false)
        "New daemon accepted an obsolete instance identity";
      let%bind observer_gate = gate root "rpc-reconnected-reader" in
      let%bind () =
        write_json
          (Filename.concat attempt "wb065-inspect.json")
          (`Assoc [ "gate", `String "rpc-reconnected-reader" ])
      in
      let%bind (_ : Asic.Snapshot.t list) =
        Deferred.all
          [ asic observer observer_id observer_project (Observe_finalization "shared-key")
          ; asic
              (client observer_server)
              observer_id
              observer_project
              (Observe_finalization "shared-key")
          ]
      in
      let%bind observed_attempt = arrived observer_gate in
      require (String.equal observed_attempt attempt) "Reconnected reader changed attempt";
      let%bind before_shutdown = calls root in
      require
        (List.count before_shutdown ~f:(function
           | "finalize" :: _ -> true
           | _ -> false)
         = 1
         && List.count before_shutdown ~f:(function
              | "finalization-inspect" :: target :: _ -> String.equal target attempt
              | _ -> false)
            = 2)
        "Concurrent clients duplicated producer or exact-key reader";
      let%bind denied =
        Client.asic
          observer
          { instance_id = observer_id
          ; project = observer_project
          ; operation = Cancel "finalize:shared-key"
          }
      in
      require
        (Result.is_error (Or_error.ok_exn denied))
        "Reader acquired producer cancellation";
      let%bind () = bounded "reader-only shutdown" (Service.shutdown observer_service) in
      let%bind () =
        In_thread.run (fun () ->
          require
            (String.equal
               (In_channel.read_all (Filename.concat attempt "reader-terminated"))
               "rpc-reconnected-reader")
            "Reader shutdown did not reap the exact gated reader";
          require
            (Poly.equal (Sys_unix.file_exists (Filename.concat attempt "terminated")) `No)
            "Reader shutdown signalled historical producer")
      in
      let%bind still_owned = asic second owner_id project Get in
      require
        ((finalization still_owned).owned
         && Option.equal String.equal (finalization still_owned).attempt (Some attempt)
         && String.equal (task still_owned "finalize:shared-key").state "executing")
        "Reader shutdown falsely reported original producer termination";
      let%bind () = release owner_reader_gate in
      let%bind () = release producer_gate in
      let%bind completed =
        wait second owner_id project "original producer completion" (fun s ->
          String.equal (task s "finalize:shared-key").state "completed")
      in
      require
        (String.equal (finalization completed).state "completed"
         && Option.equal
              String.equal
              (finalization completed).operation_status
              (Some "completed")
         && Option.equal
              String.equal
              (finalization completed).acceptance
              (Some "not_evaluated")
         && Option.equal String.equal (finalization completed).attempt (Some attempt))
        "Completion confused collection, acceptance, or operation identity";
      let reconnect_id = "wb065-reconnect" in
      let%bind _, reconnect_server = create reconnect_id in
      let reconnect = client reconnect_server in
      let%bind reconnect_project = open_project reconnect reconnect_id in
      let%bind (_ : Asic.Snapshot.t) =
        asic reconnect reconnect_id reconnect_project (Observe_finalization "shared-key")
      in
      let%bind refreshed =
        wait
          reconnect
          reconnect_id
          reconnect_project
          "read-only terminal reconnect"
          (fun s ->
             List.exists s.operations ~f:(fun op ->
               String.equal op.key "finalize-observe:shared-key"
               && String.equal op.state "completed"))
      in
      require
        ((not (finalization refreshed).owned)
         && Option.equal String.equal (finalization refreshed).attempt (Some attempt)
         && Option.equal
              String.equal
              (finalization refreshed).operation_status
              (Some "completed")
         && Option.equal
              String.equal
              (finalization refreshed).acceptance
              (Some "not_evaluated"))
        "Read-only terminal reconnect changed identity, ownership, or verdict";
      let terminal =
        List.find_exn refreshed.summaries ~f:(fun summary ->
          Run_ref.equal summary.run run)
        |> fun (summary : Asic.Summary.t) -> Option.value_exn summary.terminal
      in
      require
        (String.equal terminal.attempt attempt)
        "Reconnect imported a different operation";
      require
        (String.equal terminal.results_file (Filename.concat attempt "results.json")
         && String.equal terminal.physical_completion "full"
         && String.equal terminal.operation_status "completed"
         && String.equal terminal.acceptance "not_evaluated")
        "Reconnected terminal summary lost exact results or independent outcomes";
      let%bind () =
        In_thread.run (fun () ->
          let results =
            In_channel.read_all terminal.results_file |> Yojson.Safe.from_string
          in
          require
            (String.equal
               (Yojson.Safe.Util.member "run_id" results |> Yojson.Safe.Util.to_string)
               operation_id)
            "Terminal results no longer name the originally allocated operation";
          require
            (Poly.equal (Sys_unix.file_exists (Filename.concat attempt "terminated")) `No)
            "Detached producer was signalled rather than completing naturally")
      in
      let%bind final_calls = calls root in
      require
        (List.count final_calls ~f:(function
           | "finalize" :: _ -> true
           | _ -> false)
         = 1
         && List.for_all final_calls ~f:(function
           | "finalization-inspect" :: target :: _ -> String.equal target attempt
           | "stages" :: _ | "flow" :: "run" :: _ -> false
           | _ -> true))
        "Detach/reconnect replayed execution or inspected a different operation";
      Deferred.unit)
;;

let () =
  Command.async
    ~summary:"WB-065 concurrent HTTP clients and read-only finalization reconnect"
    (Command.Param.return main)
  |> Command_unix.run
;;
