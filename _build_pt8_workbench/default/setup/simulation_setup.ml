open! Core
open Hardcaml_workbench_protocol
module Config = Hardcaml_workbench_project_integration.Simulation_config
module Codec = Hardcaml_workbench_project_integration.Simulation_protocol
module Adapter = Hardcaml_workbench_adapters.Simulation_adapter
module Limits = Simulation.Limits

let default_discovery_timeout_seconds = 10
let default_run_timeout_seconds = 300
let stderr_tail_bytes = 16 * 1024

let prerequisites =
  "Provider prerequisites (project-owned):\n\
  \  - Build or install the provider executable yourself, for example with the\n\
  \    project's own dune build/install step. Workbench never builds, installs or\n\
  \    searches PATH for it; configure its absolute path.\n\
  \  - Discovery runs EXEC [PROVIDER_ARGS...] discover --protocol-version 1 from the\n\
  \    project root in the selected environment (opam exec prefix for opam:SWITCH)\n\
  \    and must print one catalog S-expression and exit 0.\n\
  \  - Rebuilding the provider after setup is the project's responsibility; Workbench\n\
  \    requires explicit Catalog discovery again after the configuration changes.\n"
;;

let filesystem_result f =
  match Or_error.try_with f with
  | Ok result -> result
  | Error error -> Error (Error.to_string_hum error)
;;

let shell_word arg =
  if (not (String.is_empty arg))
     && String.for_all arg ~f:(fun c -> Char.is_alphanum c || String.mem "-_./=:,+@%" c)
  then arg
  else Filename.quote arg
;;

let command_line argv = String.concat ~sep:" " (List.map argv ~f:shell_word)

type t =
  { root : string
  ; path : string
  ; config : Config.t
  ; contents : string
  }

let root t = t.root
let path t = t.path
let config t = t.config
let contents t = t.contents

(* One field per line, as in the FS2 contract's example. *)
let render config =
  match Config.sexp_of_t config with
  | List fields ->
    "(" ^ String.concat ~sep:"\n " (List.map fields ~f:Sexp.to_string_hum) ^ ")\n"
  | Atom _ as sexp -> Sexp.to_string_hum sexp ^ "\n"
;;

let prepare
  ~root
  ~provider_executable
  ~provider_args
  ?(discovery_timeout_seconds = default_discovery_timeout_seconds)
  ?(run_timeout_seconds = default_run_timeout_seconds)
  ()
  =
  let%bind.Result root = Project_discovery.explicit_root root in
  filesystem_result
  @@ fun () ->
  let path = Filename.concat root Config.filename in
  if not (Filename.is_absolute provider_executable)
  then
    Error
      (sprintf
         "provider executable must be an absolute path, got %S; Workbench does not \
          search PATH or resolve relative provider paths"
         provider_executable)
  else if No_clobber.exists path
  then Error (No_clobber.existing_error path)
  else (
    let config : Config.t =
      { schema_version = 1
      ; provider_executable
      ; provider_args
      ; discovery_timeout_seconds
      ; run_timeout_seconds
      }
    in
    match Config.validate config with
    | exception Failure message -> Error message
    | config ->
      let contents = render config in
      (match Config.parse_string contents with
       | Error error ->
         Error ("generated configuration was rejected: " ^ Error.to_string_hum error)
       | Ok parsed when not (Config.equal parsed config) ->
         Error "generated configuration did not round-trip through the parser"
       | Ok _ -> Ok { root; path; config; contents }))
;;

let executable_state path =
  match (Core_unix.stat path).st_kind with
  | S_REG ->
    (match Core_unix.access path [ `Exec ] with
     | Ok () -> "exists and is executable"
     | Error _ -> "WARNING: exists but is not executable by you")
  | _ -> "WARNING: exists but is not a regular file"
  | exception Core_unix.Unix_error (ENOENT, _, _) ->
    "WARNING: does not exist yet; build or install it before running check"
  | exception Core_unix.Unix_error (error, _, _) ->
    "WARNING: cannot inspect: " ^ Core_unix.Error.message error
;;

let preview t =
  let args =
    match t.config.provider_args with
    | [] -> "(none)"
    | args -> command_line args
  in
  String.concat
    [ sprintf "Project root:              %s\n" t.root
    ; sprintf
        "Destination:               %s (absent; will be created, never overwritten)\n"
        t.path
    ; sprintf "provider_executable:       %s\n" t.config.provider_executable
    ; sprintf
        "  state:                   %s\n"
        (executable_state t.config.provider_executable)
    ; sprintf "provider_args:             %s\n" args
    ; sprintf "discovery_timeout_seconds: %d\n" t.config.discovery_timeout_seconds
    ; sprintf "run_timeout_seconds:       %d\n" t.config.run_timeout_seconds
    ; "Rendered configuration:\n"
    ; t.contents
    ]
;;

let publish t =
  No_clobber.publish
    ~directory:t.root
    ~path:t.path
    ~temporary_prefix:".hardcaml-workbench-simulation-"
    ~contents:t.contents
;;

let parse_environment = function
  | "inherited" -> Ok V1.Environment_selection.Inherit_daemon
  | value ->
    (match String.chop_prefix value ~prefix:"opam:" with
     | Some switch when not (String.is_empty switch) -> Ok (Opam_switch switch)
     | _ -> Error "--environment must be inherited or opam:SWITCH")
;;

module Outcome = struct
  type discovery_run =
    { argv : string list
    ; cwd : string
    ; stderr : string
    }

  type t =
    | Not_configured of { path : string }
    | Invalid_configuration of
        { path : string
        ; error : string
        }
    | Discovery_failed of
        { run : discovery_run
        ; reason : string
        }
    | Configured_empty of { run : discovery_run }
    | Discovered of
        { run : discovery_run
        ; discovery : Simulation.Discovery.t
        }

  let ok = function
    | Configured_empty _ | Discovered _ -> true
    | Not_configured _ | Invalid_configuration _ | Discovery_failed _ -> false
  ;;

  let no_tests_run =
    "No tests were run: the setup check stops at discovery. Open the project in \
     Workbench to launch tests explicitly (the daemon runs its own Catalog discovery).\n"
  ;;

  let run_lines run =
    sprintf "Command: %s\nWorking directory: %s\n" (command_line run.argv) run.cwd
    ^
    if String.is_empty (String.strip run.stderr)
    then ""
    else (
      let stderr =
        if String.is_suffix run.stderr ~suffix:"\n" then run.stderr else run.stderr ^ "\n"
      in
      "Provider stderr:\n" ^ stderr)
  ;;

  let parameter (p : Simulation.Parameter.t) =
    let domain =
      match p.choices with
      | [] -> "any string"
      | choices -> "choices " ^ String.concat ~sep:", " choices
    in
    sprintf "    parameter %s - %s (default %s; %s)\n" p.key p.label p.default domain
  ;;

  let suite (s : Simulation.Suite.t) =
    String.concat
      ((sprintf
          "  suite %s - %s (%d case%s, default seed %s)\n"
          s.id
          s.label
          (List.length s.cases)
          (if List.length s.cases = 1 then "" else "s")
          s.default_seed
        :: List.map s.parameters ~f:parameter)
       @ List.map s.cases ~f:(fun (c : Simulation.Case.t) ->
         sprintf "    case %s - %s\n" c.id c.label))
  ;;

  let render = function
    | Not_configured { path } ->
      sprintf
        "Simulation is not configured: %s does not exist.\n\
         Create it with: hardcaml-workbench-simulation-setup init --root %s \
         --provider-executable /ABSOLUTE/PATH [--provider-arg ARG ...]\n"
        path
        (shell_word (Filename.dirname path))
    | Invalid_configuration { path; error } ->
      sprintf
        "Simulation configuration %s is invalid: %s\n\
         Setup never overwrites an existing configuration; edit or remove it explicitly.\n"
        path
        error
    | Discovery_failed { run; reason } ->
      sprintf
        "Discovery FAILED: %s\n\
         %sCheck that the provider executable is built or installed and that its \
         configured arguments are correct.\n\
         %s"
        reason
        (run_lines run)
        no_tests_run
    | Configured_empty { run } ->
      sprintf
        "Simulation is configured, and discovery succeeded, but the provider declared \
         zero suites: there are no tests to run yet.\n\
         %s%s"
        (run_lines run)
        no_tests_run
    | Discovered { run; discovery } ->
      let cases =
        List.sum (module Int) discovery.suites ~f:(fun s -> List.length s.cases)
      in
      let suites = List.length discovery.suites in
      String.concat
        ([ sprintf
             "Discovery succeeded: %d suite%s, %d case%s.\n"
             suites
             (if suites = 1 then "" else "s")
             cases
             (if cases = 1 then "" else "s")
         ; run_lines run
         ; "Catalog:\n"
         ]
         @ List.map discovery.suites ~f:suite
         @ [ no_tests_run ])
  ;;
end

let read_config path =
  match Core_unix.lstat path with
  | exception Core_unix.Unix_error (ENOENT, _, _) -> `Absent
  | exception Core_unix.Unix_error (error, _, _) ->
    `Invalid ("cannot inspect: " ^ Core_unix.Error.message error)
  | { st_kind = S_LNK; _ } ->
    `Invalid "it is a symlink, which the daemon refuses for simulation configuration"
  | { st_kind = S_REG; st_size; _ } ->
    if Int64.(st_size > of_int Limits.config_bytes)
    then `Invalid (sprintf "it exceeds %d bytes" Limits.config_bytes)
    else (
      match Or_error.try_with (fun () -> In_channel.read_all path) with
      | Error error -> `Invalid (Error.to_string_hum error)
      | Ok text ->
        (match Config.parse_string text with
         | Ok config -> `Config config
         | Error error -> `Invalid (Error.to_string_hum error)))
  | _ -> `Invalid "it is not a regular file"
;;

let append_bounded buffer bytes ~length ~limit =
  Buffer.add_subbytes buffer bytes ~pos:0 ~len:length;
  if Buffer.length buffer > limit
  then (
    let tail =
      Buffer.To_string.sub buffer ~pos:(Buffer.length buffer - limit) ~len:limit
    in
    Buffer.clear buffer;
    Buffer.add_string buffer tail)
;;

(* Run one discovery process. Returns stdout, a bounded stderr tail and a failure reason
   if the process did not complete validly. *)
let run_discovery
  ~(invocation : Hardcaml_workbench_adapters.Dune_adapter.Invocation.t)
  ~timeout_seconds
  =
  let stderr = Buffer.create 1024 in
  let null = Core_unix.openfile "/dev/null" ~mode:[ O_RDONLY; O_CLOEXEC ] in
  let spawned =
    Exn.protect
      ~finally:(fun () -> Core_unix.close null)
      ~f:(fun () ->
        match
          Core_unix.create_process_with_fds
            ~working_dir:invocation.cwd
            ~setpgid:Core_unix.Pgid.new_process_group
            ~prog:invocation.executable
            ~args:(List.tl_exn invocation.argv)
            ~stdin:(Use_this null)
            ~stdout:Generate
            ~stderr:Generate
            ()
        with
        | process -> Ok process
        | exception Core_unix.Unix_error (error, _, _) ->
          Error (Core_unix.Error.message error)
        | exception exn -> Error (Exn.to_string exn))
  in
  match spawned with
  | Error message ->
    "", "", Some (sprintf "could not start %s: %s" invocation.executable message)
  | Ok process ->
    let stdout = Buffer.create 4096 in
    let failure = ref None in
    let fail reason = if Option.is_none !failure then failure := Some reason in
    let chunk = Bytes.create 65536 in
    let deadline =
      Time_ns.add (Time_ns.now ()) (Time_ns.Span.of_int_sec timeout_seconds)
    in
    let open_fds = ref [ process.stdout; process.stderr ] in
    let status = ref None in
    let poll_status () =
      if Option.is_none !status
      then status := Option.map (Core_unix.wait_nohang (`Pid process.pid)) ~f:snd
    in
    let close fd =
      Core_unix.close fd;
      open_fds
      := List.filter !open_fds ~f:(fun other -> not (Core_unix.File_descr.equal fd other))
    in
    Exn.protect
      ~f:(fun () ->
        poll_status ();
        while
          (Option.is_none !status || not (List.is_empty !open_fds))
          && Option.is_none !failure
        do
          let remaining = Time_ns.diff deadline (Time_ns.now ()) in
          if Time_ns.Span.(remaining <= zero)
          then fail (sprintf "discovery timed out after %ds" timeout_seconds)
          else (
            (* EOF is independent of child exit, and descendants can retain the pipes
               after the child exits. Poll both conditions until both are complete. An
               empty fd set still sleeps, rather than spinning or blocking in waitpid. *)
            let ready =
              Core_unix.select
                ~restart:true
                ~read:!open_fds
                ~write:[]
                ~except:[]
                ~timeout:(`After (Time_ns.Span.min remaining (Time_ns.Span.of_ms 50.)))
                ()
            in
            List.iter ready.read ~f:(fun fd ->
              let length = Core_unix.read fd ~buf:chunk in
              if length = 0
              then close fd
              else if Core_unix.File_descr.equal fd process.stdout
              then
                if Buffer.length stdout + length > Limits.discovery_bytes
                then fail "discovery stdout exceeds 1 MiB"
                else Buffer.add_subbytes stdout chunk ~pos:0 ~len:length
              else append_bounded stderr chunk ~length ~limit:stderr_tail_bytes);
            poll_status ())
        done)
      ~finally:(fun () ->
        if Option.is_some !failure
           || Option.is_none !status
           || not (List.is_empty !open_fds)
        then
          ignore
            (Signal_unix.send Signal.kill (`Group process.pid)
             : [ `Ok | `No_such_process ]);
        List.iter !open_fds ~f:Core_unix.close;
        (* Only wait after killing an unfinished child, and never reap it twice. *)
        if Option.is_none !status then status := Some (Core_unix.waitpid process.pid));
    (match Option.value_exn !status with
     | Ok () -> ()
     | Error (`Exit_non_zero code) -> fail (sprintf "provider exited with status %d" code)
     | Error (`Signal signal) ->
       fail (sprintf "provider was killed by signal %s" (Signal.to_string signal)));
    Buffer.contents stdout, Buffer.contents stderr, !failure
;;

let check ~root ~environment : Outcome.t =
  let path = Filename.concat root Config.filename in
  match read_config path with
  | `Absent -> Not_configured { path }
  | `Invalid error -> Invalid_configuration { path; error }
  | `Config config ->
    let invocation = Adapter.discover config ~root ~environment in
    let stdout, stderr, failure =
      run_discovery ~invocation ~timeout_seconds:config.discovery_timeout_seconds
    in
    let run : Outcome.discovery_run = { argv = invocation.argv; cwd = root; stderr } in
    (match failure with
     | Some reason -> Discovery_failed { run; reason }
     | None ->
       (match Codec.parse_discovery stdout with
        | Error error ->
          Discovery_failed
            { run; reason = "invalid discovery output: " ^ Error.to_string_hum error }
        | Ok { suites = []; _ } -> Configured_empty { run }
        | Ok discovery -> Discovered { run; discovery }))
;;
