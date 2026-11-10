open! Core
open! Async

module Metadata = struct
  type t =
    { endpoint : string
    ; instance_id : string
    ; pid : int
    }
  [@@deriving sexp]
end

type paths =
  { directory : string
  ; metadata : string
  ; startup_lock : string
  ; lifetime_lock : string
  ; log : string
  }

let paths ?directory () =
  let nonempty_env name =
    Sys.getenv name
    |> Option.bind ~f:(fun value -> if String.is_empty value then None else Some value)
  in
  let directory =
    match directory with
    | Some directory -> directory
    | None ->
      (match nonempty_env "XDG_RUNTIME_DIR" with
       | Some root -> Filename.concat root "hardcaml-workbench"
       | None ->
         let state_home =
           nonempty_env "XDG_STATE_HOME"
           |> Option.value_or_thunk ~default:(fun () ->
             Filename.concat (Sys_unix.home_directory ()) ".local/state")
         in
         Filename.concat state_home "hardcaml-workbench")
  in
  { directory
  ; metadata = Filename.concat directory "daemon.sexp"
  ; startup_lock = Filename.concat directory "startup.lock"
  ; lifetime_lock = Filename.concat directory "lifetime.lock"
  ; log = Filename.concat directory "daemon.log"
  }
;;

let ensure_directory paths =
  let%bind () = Unix.mkdir ~p:() ~perm:0o700 paths.directory in
  Unix.chmod paths.directory ~perm:0o700
;;

let open_lock path =
  let%bind fd = Unix.openfile path ~mode:[ `Rdwr; `Creat ] ~perm:0o600 in
  let%map () = Unix.fchmod fd ~perm:0o600 in
  fd
;;

let with_startup_lock paths ~f =
  let%bind fd = open_lock paths.startup_lock in
  let%bind () = Unix.flock fd Unix.Lock_mode.Exclusive in
  Monitor.protect f ~finally:(fun () ->
    Unix.funlock fd;
    Unix.close fd)
;;

let acquire_lifetime_lock paths =
  let%bind fd = open_lock paths.lifetime_lock in
  if Unix.try_flock fd Unix.Lock_mode.Exclusive
  then return (Ok fd)
  else (
    let%map () = Unix.close fd in
    Or_error.error_string "default daemon lifetime lock is already held")
;;

let lifetime_lock_is_held paths =
  let%bind fd = open_lock paths.lifetime_lock in
  let held = not (Unix.try_flock fd Unix.Lock_mode.Exclusive) in
  if not held then Unix.funlock fd;
  let%map () = Unix.close fd in
  held
;;

let read_metadata paths =
  Monitor.try_with_or_error (fun () -> Reader.file_contents paths.metadata)
  >>| Or_error.bind ~f:(fun body ->
    Or_error.try_with (fun () -> Metadata.t_of_sexp (Sexp.of_string body)))
;;

let publish_metadata paths metadata =
  Writer.save
    paths.metadata
    ~perm:0o600
    ~fsync:true
    ~contents:(Sexp.to_string_mach (Metadata.sexp_of_t metadata))
;;

let probe metadata =
  let client = Client.create metadata.Metadata.endpoint in
  Monitor.try_with_or_error (fun () ->
    Clock.with_timeout (Time_float.Span.of_sec 1.) (Client.hello client))
  >>| function
  | Error error -> Error error
  | Ok `Timeout -> Or_error.error_string "daemon hello timed out"
  | Ok (`Result (Error error)) -> Error error
  | Ok (`Result (Ok hello)) ->
    if String.equal hello.instance_id metadata.instance_id
    then Ok (client, hello)
    else Or_error.error_string "discovery metadata names a different daemon instance"
;;

let discovered paths =
  let%bind metadata = read_metadata paths in
  match metadata with
  | Error error -> return (Error error)
  | Ok metadata -> probe metadata
;;

let daemon_path () =
  match Sys.getenv "HARDCAML_WORKBENCH_DAEMON" with
  | Some path -> path
  | None ->
    Filename.concat
      (Filename.dirname (Filename_unix.realpath Sys_unix.executable_name))
      "hardcaml-workbench-daemon"
;;

let spawn paths =
  let daemon = daemon_path () in
  let argv = [ daemon; "--port"; "0"; "--discovery-dir"; paths.directory ] in
  let pid =
    Core_unix.fork_exec
      ~prog:daemon
      ~argv
      ~use_path:false
      ~preexec:
        [ Setsid ()
        ; Fd_open
            { fd = Core_unix.stdin
            ; filename = "/dev/null"
            ; flags = [ O_RDONLY ]
            ; perm = 0
            }
        ; Fd_open
            { fd = Core_unix.stdout
            ; filename = paths.log
            ; flags = [ O_WRONLY; O_CREAT; O_APPEND ]
            ; perm = 0o600
            }
        ; Fd_open
            { fd = Core_unix.stderr
            ; filename = paths.log
            ; flags = [ O_WRONLY; O_CREAT; O_APPEND ]
            ; perm = 0o600
            }
        ]
      ()
  in
  don't_wait_for (Unix.waitpid pid >>| fun _ -> ());
  return ()
;;

let rec wait_until_ready paths deadline =
  let%bind result = discovered paths in
  match result with
  | Ok result -> return (Ok result)
  | Error _ when Time_ns.(now () >= deadline) ->
    return (Or_error.error_string "daemon did not become ready within 10 seconds")
  | Error _ ->
    let%bind () = Clock.after (Time_float.Span.of_ms 100.) in
    wait_until_ready paths deadline
;;

let connect_or_start ?directory () =
  let paths = paths ?directory () in
  let%bind () = ensure_directory paths in
  with_startup_lock paths ~f:(fun () ->
    let%bind existing = discovered paths in
    match existing with
    | Ok result -> return (Ok result)
    | Error _ ->
      let%bind held = lifetime_lock_is_held paths in
      if held
      then
        return
          (Or_error.error_string
             "default daemon holds its lifetime lock but failed readiness checks")
      else (
        let%bind () = spawn paths in
        wait_until_ready paths (Time_ns.add (Time_ns.now ()) (Time_ns.Span.of_sec 10.))))
;;
