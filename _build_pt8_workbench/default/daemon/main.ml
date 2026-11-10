open! Core
open! Async
open Hardcaml_workbench_protocol
module Rpc_server = Hardcaml_workbench_rpc_server.Rpc_server
module Service = Hardcaml_workbench_backend.Service

let application_version = "0.1.0"

let instance_id () =
  Random.self_init ();
  sprintf
    "%d-%d-%08x"
    (Core_unix.getpid () |> Pid.to_int)
    (Time_ns.now () |> Time_ns.to_int_ns_since_epoch)
    (Random.bits ())
  |> V1.Daemon_instance_id.of_string
;;

let run
  ~port
  ~discovery_dir
  ~state_dir
  ~inspection_detail_cache_entries
  ~inspection_detail_cache_bytes
  ()
  =
  Hardcaml_workbench_backend.Inspection_detail_cache.validate_limits
    ~entries:inspection_detail_cache_entries
    ~bytes:inspection_detail_cache_bytes;
  let instance_id = instance_id () in
  let state_dir =
    Option.value_or_thunk state_dir ~default:(fun () ->
      match discovery_dir with
      | Some directory -> Filename.concat directory "state"
      | None ->
        let home =
          Sys.getenv "XDG_STATE_HOME"
          |> Option.filter ~f:(Fn.non String.is_empty)
          |> Option.value
               ~default:(Filename.concat (Sys_unix.home_directory ()) ".local/state")
        in
        Filename.concat home "hardcaml-workbench/state")
  in
  if not (Filename.is_absolute state_dir) then failwith "--state-dir must be absolute";
  let state_paths =
    Hardcaml_workbench_native_http.Runtime.paths ~directory:state_dir ()
  in
  let%bind () = Hardcaml_workbench_native_http.Runtime.ensure_directory state_paths in
  let%bind state_lock =
    Hardcaml_workbench_native_http.Runtime.acquire_lifetime_lock state_paths
  in
  let state_lock = Or_error.ok_exn state_lock in
  let log_dir = Filename_unix.temp_dir "hardcaml-workbench-" "-logs" ~perm:0o700 in
  let%bind service =
    Service.create
      ~instance_id
      ~log_dir
      ~state_dir
      ~inspection_detail_cache_entries
      ~inspection_detail_cache_bytes
      ()
  in
  let service = Or_error.ok_exn service in
  let rpc = Rpc_server.create ~application_version ~instance_id ~service in
  let paths = Hardcaml_workbench_native_http.Runtime.paths ?directory:discovery_dir () in
  let%bind lifetime_lock =
    match discovery_dir with
    | None -> return (Ok None)
    | Some _ ->
      let%map lock = Hardcaml_workbench_native_http.Runtime.acquire_lifetime_lock paths in
      Or_error.map lock ~f:Option.some
  in
  let lifetime_lock = Or_error.ok_exn lifetime_lock in
  let%bind server = Rpc_server.start rpc ~port in
  let port = Cohttp_async.Server.listening_on server in
  let endpoint = sprintf "http://127.0.0.1:%d" port in
  let%bind () =
    match discovery_dir with
    | None -> return ()
    | Some _ ->
      let metadata : Hardcaml_workbench_native_http.Runtime.Metadata.t =
        { endpoint
        ; instance_id = V1.Daemon_instance_id.to_string instance_id
        ; pid = Core_unix.getpid () |> Pid.to_int
        }
      in
      let client = Hardcaml_workbench_native_http.Client.create endpoint in
      let%bind hello = Hardcaml_workbench_native_http.Client.hello client in
      let hello = Or_error.ok_exn hello in
      if not (V1.Daemon_instance_id.equal hello.instance_id instance_id)
      then raise_s [%message "daemon readiness probe returned the wrong instance"];
      Hardcaml_workbench_native_http.Runtime.publish_metadata paths metadata
  in
  printf "hardcaml-workbench-daemon listening on %s\n%!" endpoint;
  Shutdown.at_shutdown ~here:[%here] (fun () ->
    let%bind () = Service.shutdown service in
    let%bind () = Cohttp_async.Server.close server in
    Unix.funlock state_lock;
    let%bind () = Unix.close state_lock in
    match lifetime_lock with
    | None -> return ()
    | Some fd ->
      Unix.funlock fd;
      Unix.close fd);
  Signal.handle [ Signal.int; Signal.term ] ~f:(fun signal ->
    Shutdown.shutdown_with_signal_exn
      ~force:(Clock.after (Time_float.Span.of_sec 12.))
      signal);
  Deferred.never ()
;;

let command =
  Command.async
    ~summary:"Run the loopback-only Hardcaml Workbench daemon"
    (let%map_open.Command port =
       flag "--port" (optional_with_default 0 int) ~doc:"PORT listen port"
     and discovery_dir =
       flag
         "--discovery-dir"
         (optional string)
         ~doc:"DIR publish automatic-daemon discovery metadata"
     and state_dir =
       flag
         "--state-dir"
         (optional string)
         ~doc:"DIR absolute persistent workspace/result cache directory"
     and inspection_detail_cache_entries =
       flag
         "--inspection-detail-cache-entries"
         (optional_with_default 64 int)
         ~doc:
           "N per-project reusable detail entries (default 64; 0 disables; maximum 4096)"
     and inspection_detail_cache_bytes =
       flag
         "--inspection-detail-cache-bytes"
         (optional_with_default 4194304 int)
         ~doc:
           "N per-project serialized detail payload bytes, excluding heap overhead \
            (default 4194304; 0 disables; maximum 268435456)"
     in
     run
       ~port
       ~discovery_dir
       ~state_dir
       ~inspection_detail_cache_entries
       ~inspection_detail_cache_bytes)
;;

let () = Command_unix.run command
