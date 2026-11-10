open! Core
open! Async
open Hardcaml_workbench_protocol
open Simulation
module Files = Simulation_files
module Reducer = Simulation_reducer
module Config = Hardcaml_workbench_project_integration.Simulation_config
module Codec = Hardcaml_workbench_project_integration.Simulation_protocol
module Adapter = Hardcaml_workbench_adapters.Simulation_adapter

module Record = struct
  type t =
    { schema_version : int
    ; submission_key : string
    ; payload : string
    ; attempt : Attempt.t
    }
  [@@deriving sexp]
end

type entry =
  { mutable record : Record.t
  ; dir : string
  }

type project =
  { root : string
  ; dir : string
  ; entries : (string, entry) Hashtbl.t
  ; mutable discovery : Discovery.t option
  ; mutable discovery_digest : string option
  ; mutable discovery_config : string option
  ; mutable discovery_environment : V1.Environment_selection.t option
  ; mutable discovery_job : Job_id.t option
  ; mutable discovering : bool
  ; mutable discovery_error : string option
  ; mutable history_error : string option
  }

type t =
  { state_dir : string
  ; projects : (string, project) Hashtbl.t
  ; tails : (string, unit Deferred.t) Hashtbl.t
  }

type schedule =
  name:string
  -> reservation:(string * string) option
  -> prepare:(Job_id.t -> Simulation_task.t)
  -> Job_id.t Deferred.t

exception Rpc_error of V1.Error.t

let rpc_error kind message = raise (Rpc_error (V1.Error.create kind message))
let require = Files.require

let create ~state_dir =
  { state_dir = Filename.concat state_dir "simulation-v1"
  ; projects = Hashtbl.create (module String)
  ; tails = Hashtbl.create (module String)
  }
;;

let serialize t ~root f =
  let previous = Hashtbl.find t.tails root |> Option.value ~default:(return ()) in
  let done_ = Ivar.create () in
  let next = Ivar.read done_ in
  Hashtbl.set t.tails ~key:root ~data:next;
  let%bind () = previous in
  Monitor.protect
    ~finally:(fun () ->
      Ivar.fill_exn done_ ();
      if Option.exists (Hashtbl.find t.tails root) ~f:(phys_equal next)
      then Hashtbl.remove t.tails root;
      return ())
    f
;;

let ordered p =
  Hashtbl.data p.entries
  |> List.sort ~compare:(fun a b ->
    match String.compare b.record.attempt.created_at a.record.attempt.created_at with
    | 0 -> String.compare b.record.attempt.id a.record.attempt.id
    | n -> n)
;;

let record_text entry = Sexp.to_string_mach (Record.sexp_of_t entry.record)
let record_path (entry : entry) = Filename.concat entry.dir "record.sexp"

let artifact_bytes entry =
  List.sum (module Int) entry.record.attempt.artifacts ~f:(fun a ->
    Option.value a.Artifact.size ~default:0)
;;

let prune ?protected ?(artifact_reserve = 0) p ~reserve =
  let rec loop () =
    let entries = Hashtbl.data p.entries in
    let bytes =
      List.sum (module Int) entries ~f:(fun e -> String.length (record_text e))
    in
    let artifacts = List.sum (module Int) entries ~f:artifact_bytes in
    if List.length entries + reserve > Limits.history_attempts
       || bytes > Limits.history_bytes
       || artifacts + artifact_reserve > Limits.history_artifact_bytes
    then (
      match
        List.rev (ordered p)
        |> List.find ~f:(fun e ->
          (not (Files.is_active e.record.attempt))
          && not (Option.equal String.equal protected (Some e.record.attempt.id)))
      with
      | None ->
        rpc_error
          Conflict
          "Simulation durable history budget exhausted by active attempts"
      | Some entry ->
        Files.remove entry.dir;
        Hashtbl.remove p.entries entry.record.attempt.id;
        loop ())
  in
  loop ()
;;

let save p entry =
  prune p ~protected:entry.record.attempt.id ~reserve:0;
  Files.atomic (record_path entry) (record_text entry)
;;

let validate_record (record : Record.t) =
  let a = record.attempt in
  require
    (String.length record.submission_key <= Limits.key_bytes
     && Hardcaml_workbench_project_integration.Driver_protocol.valid_key
          record.submission_key)
    "Invalid durable submission key";
  require
    (List.length a.cases <= Limits.cases
     && List.length a.artifacts <= Limits.artifacts
     && List.length a.recent_events <= Limits.retained_events
     && a.next_sequence >= 0
     && a.next_sequence <= Limits.events)
    "Oversized simulation history";
  let selection = a.captured.selection in
  let sort selection =
    { selection with
      Selection.cases = List.sort selection.Selection.cases ~compare:String.compare
    ; parameters =
        List.sort selection.parameters ~compare:(fun (a, _) (b, _) -> String.compare a b)
    }
  in
  (match Operation.t_of_sexp (Sexp.of_string record.payload) with
   | Launch request ->
     require
       (String.equal request.submission_key record.submission_key
        && String.equal request.discovery_digest a.captured.discovery_digest
        && Selection.equal (sort request.selection) (sort selection)
        && Option.is_none a.parent)
       "Corrupt launch reservation"
   | Rerun request ->
     require
       (String.equal request.submission_key record.submission_key
        && List.equal
             String.equal
             (List.sort request.cases ~compare:String.compare)
             (List.sort selection.cases ~compare:String.compare)
        && Option.exists a.parent ~f:(fun parent ->
          String.equal parent.attempt_id request.attempt_id
          && not (String.equal parent.attempt_id a.id)))
       "Corrupt rerun reservation"
   | _ -> failwith "Invalid durable simulation reservation");
  let suite : Suite.t =
    { id = selection.suite
    ; label = selection.suite
    ; cases = List.map selection.cases ~f:(fun id -> { Case.id; label = id })
    ; parameters =
        List.map selection.parameters ~f:(fun (key, default) ->
          { Parameter.key; label = key; default; choices = [] })
    ; default_seed = selection.seed
    }
  in
  let discovery : Discovery.t = { protocol_version = 1; suites = [ suite ] } in
  ignore
    (Codec.parse_discovery (Sexp.to_string_mach (Discovery.sexp_of_t discovery))
     |> Or_error.ok_exn
     : Discovery.t);
  ignore (Codec.validate_selection discovery selection |> Or_error.ok_exn : Selection.t);
  require
    (List.equal
       String.equal
       selection.cases
       (List.map a.cases ~f:(fun c -> c.Case_result.case_id)))
    "History case ownership mismatch";
  let terminal_cases =
    List.for_all a.cases ~f:(fun c ->
      match c.status with
      | Passed | Failed | Skipped -> true
      | _ -> false)
  in
  let has_failure = List.exists a.cases ~f:(fun c -> Case_status.equal c.status Failed) in
  (match a.outcome with
   | Passed | Failed ->
     require
       (Lifecycle.equal a.lifecycle Finished
        && Option.equal Int.equal a.exit_code (Some 0)
        && Option.is_none a.diagnostic
        && terminal_cases
        && Bool.equal has_failure (Outcome.equal a.outcome Failed))
       "Corrupt successful/failed simulation history";
     let last = List.last_exn a.recent_events in
     require
       (match last.payload with
        | Finished outcome -> Outcome.equal outcome a.outcome
        | _ -> false)
       "History lacks accepted final event"
   | Unknown -> require (Files.is_active a) "Terminal history has unknown outcome"
   | Incomplete ->
     require (not (Files.is_active a)) "Active history has terminal outcome";
     require
       (List.for_all a.cases ~f:(fun c ->
          match c.status with
          | Pending | Running -> false
          | _ -> true))
       "Terminal history has unfinished cases");
  let count = List.length a.recent_events in
  List.iteri a.recent_events ~f:(fun index event ->
    require
      (event.protocol_version = version
       && String.equal event.attempt_id a.id
       && event.sequence = a.next_sequence - count + index)
      "Corrupt retained event identity/order");
  let seen = Hash_set.create (module String) in
  List.iter a.artifacts ~f:(fun artifact ->
    require
      (String.equal artifact.Artifact.attempt_id a.id
       && not (Hash_set.mem seen artifact.id))
      "History artifact ownership mismatch";
    Hash_set.add seen artifact.id;
    Option.iter artifact.case_id ~f:(fun id ->
      require
        (List.mem selection.cases id ~equal:String.equal)
        "History artifact has unknown case");
    Option.iter artifact.size ~f:(fun size ->
      require (size >= 0 && size <= Limits.artifact_bytes) "History artifact size invalid");
    if Artifact.Availability.equal artifact.availability Available
    then
      require
        (Option.is_some artifact.size && Option.is_some artifact.sha256)
        "Available artifact lacks verified metadata")
;;

let project t root =
  Hashtbl.find_or_add t.projects root ~default:(fun () ->
    let dir = Filename.concat t.state_dir (Files.digest root) in
    Files.mkdir dir;
    let dir = Filename_unix.realpath dir in
    let p =
      { root
      ; dir
      ; entries = Hashtbl.create (module String)
      ; discovery = None
      ; discovery_digest = None
      ; discovery_config = None
      ; discovery_environment = None
      ; discovery_job = None
      ; discovering = false
      ; discovery_error = None
      ; history_error = None
      }
    in
    let names, truncated = Files.directory_entries dir ~limit:1024 in
    if truncated
    then p.history_error <- Some "Simulation history directory exceeds scan limit";
    List.iter (List.take names 1024) ~f:(fun name ->
      if String.is_prefix name ~prefix:"sim-"
      then (
        match
          Or_error.try_with (fun () ->
            require
              (Hardcaml_workbench_project_integration.Driver_protocol.valid_key name)
              "Invalid history directory";
            let dir = Filename.concat dir name in
            let record =
              Files.read
                (Filename.concat dir "record.sexp")
                ~max_bytes:Limits.history_bytes
              |> Sexp.of_string
              |> Record.t_of_sexp
            in
            require
              (record.schema_version = 1
               && String.equal record.attempt.id name
               && String.equal record.attempt.project_root root)
              "Simulation record identity mismatch";
            validate_record record;
            require
              (not
                 (List.exists (Hashtbl.data p.entries) ~f:(fun entry ->
                    String.equal entry.record.submission_key record.submission_key)))
              "Duplicate durable simulation reservation";
            let attempt = record.attempt in
            let record =
              if Files.is_active attempt
              then
                { record with
                  attempt =
                    { attempt with
                      lifecycle = Interrupted
                    ; execution_timing = Execution_timing.stopped attempt.execution_timing
                    ; outcome = Incomplete
                    ; diagnostic = Some "Daemon restarted; producer was not replayed"
                    ; cases =
                        List.map attempt.cases ~f:(fun c ->
                          match c.status with
                          | Pending | Running -> { c with status = Incomplete }
                          | _ -> c)
                    }
                }
              else record
            in
            let entry = { record; dir } in
            Hashtbl.set p.entries ~key:name ~data:entry;
            if not (Attempt.equal attempt record.attempt) then save p entry;
            Files.remove (Filename.concat dir "work");
            let owned =
              String.Set.of_list
                (List.map record.attempt.artifacts ~f:(fun artifact ->
                   Filename.basename (Files.artifact_path dir artifact.id)))
            in
            List.iter (Sys_unix.ls_dir dir) ~f:(fun name ->
              if (String.is_suffix name ~suffix:".bytes" && not (Set.mem owned name))
                 || String.is_substring name ~substring:".tmp-"
              then Files.remove (Filename.concat dir name)))
        with
        | Ok () -> ()
        | Error error ->
          p.history_error
          <- Some (String.prefix (Error.to_string_hum error) Limits.string_bytes)));
    prune p ~reserve:0;
    p)
;;

let load_config p =
  let path = Filename.concat p.root Config.filename in
  match Sys_unix.file_exists path with
  | `No -> None
  | `Unknown -> failwith "Cannot inspect simulation config"
  | `Yes ->
    Some
      (Files.read path ~max_bytes:Limits.config_bytes
       |> Config.parse_string
       |> Or_error.ok_exn)
;;

let config_digest config = Files.digest (Sexp.to_string_mach (Config.sexp_of_t config))

let summary (a : Attempt.t) : Summary.t =
  { id = a.id
  ; job = a.job
  ; suite = a.captured.selection.suite
  ; seed = a.captured.selection.seed
  ; created_at = a.created_at
  ; parent = a.parent
  ; lifecycle = a.lifecycle
  ; outcome = a.outcome
  ; execution_timing = a.execution_timing
  }
;;

let snapshot p ~configured ?detail ?byte_page ?before ?(limit = Limits.history_page) () =
  let entries = ordered p in
  let entries =
    match before with
    | None -> entries
    | Some cursor ->
      if not (List.exists entries ~f:(fun e -> String.equal e.record.attempt.id cursor))
      then rpc_error Invalid_request "Invalid simulation history cursor";
      List.drop
        (List.drop_while entries ~f:(fun e ->
           not (String.equal e.record.attempt.id cursor)))
        1
  in
  let page = List.take entries limit in
  { Snapshot.configured
  ; discovery = p.discovery
  ; discovery_digest = p.discovery_digest
  ; discovery_job = (if p.discovering then p.discovery_job else None)
  ; discovery_error = p.discovery_error
  ; attempts = List.map page ~f:(fun e -> summary e.record.attempt)
  ; next_before =
      (if List.length entries > limit
       then List.last page |> Option.map ~f:(fun e -> e.record.attempt.id)
       else None)
  ; detail
  ; byte_page
  ; history_error = p.history_error
  }
;;

let find p id =
  match Hashtbl.find p.entries id with
  | Some entry -> entry
  | None -> rpc_error Not_found "Simulation attempt not found"
;;

let inspect_artifacts p entry =
  let changed = ref false in
  let artifacts =
    List.map entry.record.attempt.artifacts ~f:(fun artifact ->
      match artifact.Artifact.size, artifact.sha256 with
      | Some size, Some _ ->
        let availability =
          match
            Or_error.try_with (fun () ->
              let path = Files.artifact_path entry.dir artifact.id in
              let stat = Core_unix.lstat path in
              if Poly.equal stat.st_kind S_REG
                 && Int64.equal stat.st_size (Int64.of_int size)
              then artifact.availability
              else Artifact.Availability.Changed)
          with
          | Ok availability -> availability
          | Error _ -> Artifact.Availability.Missing
        in
        if not (Artifact.Availability.equal availability artifact.availability)
        then changed := true;
        { artifact with availability }
      | _ -> artifact)
  in
  if !changed
  then (
    entry.record
    <- { entry.record with attempt = { entry.record.attempt with artifacts } };
    save p entry);
  entry.record.attempt
;;

let capture_artifact p entry (declaration : Provider.Artifact.t) =
  let id = entry.record.attempt.id ^ "-" ^ declaration.id in
  let artifact : Artifact.t =
    { id
    ; attempt_id = entry.record.attempt.id
    ; case_id = declaration.case_id
    ; label = declaration.label
    ; kind = declaration.kind
    ; media_type = declaration.media_type
    ; size = None
    ; sha256 = None
    ; availability = Missing
    }
  in
  match
    Or_error.try_with (fun () ->
      let entries = Hashtbl.data p.entries in
      let used = List.sum (module Int) entries ~f:artifact_bytes in
      let reclaimable =
        List.sum (module Int) entries ~f:(fun other ->
          if Files.is_active other.record.attempt then 0 else artifact_bytes other)
      in
      let max_bytes =
        Int.min
          Limits.artifact_bytes
          (Int.min
             (Limits.attempt_artifact_bytes - artifact_bytes entry)
             (Int.max 0 (Limits.history_artifact_bytes - used + reclaimable)))
      in
      let bytes =
        Files.read
          (Filename.concat (Filename.concat entry.dir "work/artifacts") declaration.path)
          ~max_bytes
      in
      require
        (artifact_bytes entry + String.length bytes <= Limits.attempt_artifact_bytes)
        "Attempt artifact budget exceeded";
      prune p ~reserve:0 ~artifact_reserve:(String.length bytes);
      let path = Files.artifact_path entry.dir id in
      Files.atomic path bytes;
      { artifact with
        size = Some (String.length bytes)
      ; sha256 = Some (Files.digest bytes)
      ; availability = Available
      })
  with
  | Ok artifact -> artifact
  | Error error ->
    ignore
      (Or_error.try_with (fun () -> Files.remove (Files.artifact_path entry.dir id))
       : unit Or_error.t);
    let path =
      Filename.concat (Filename.concat entry.dir "work/artifacts") declaration.path
    in
    { artifact with
      availability =
        (match Sys_unix.file_exists ~follow_symlinks:false path with
         | `No -> Missing
         | `Yes | `Unknown ->
           Rejected (String.prefix (Error.to_string_hum error) Limits.string_bytes))
    }
;;

let run_task p (entry : entry) config ~environment =
  let work = Filename.concat entry.dir "work" in
  let request_file = Filename.concat work "request.sexp" in
  let events_file = Filename.concat work "events.sexp" in
  let artifact_dir = Filename.concat work "artifacts" in
  Files.mkdir artifact_dir;
  Files.atomic
    request_file
    (Sexp.to_string_mach
       (Provider.Request.sexp_of_t
          { protocol_version = version
          ; attempt_id = entry.record.attempt.id
          ; selection = entry.record.attempt.captured.selection
          }));
  Files.atomic events_file "";
  let reducer = Reducer.create entry.record.attempt in
  let position = ref 0 in
  let pending = ref "" in
  let identity = Core_unix.lstat events_file in
  let persist () =
    let previous = entry.record in
    reducer.attempt
    <- { reducer.attempt with
         artifacts =
           List.map reducer.attempt.artifacts ~f:(fun artifact ->
             match
               List.find previous.attempt.artifacts ~f:(fun old ->
                 String.equal old.Artifact.id artifact.Artifact.id)
             with
             | None -> artifact
             | Some published -> { artifact with availability = published.availability })
       };
    entry.record <- { previous with attempt = reducer.attempt };
    match Or_error.try_with (fun () -> save p entry) with
    | Ok () -> ()
    | Error error ->
      List.iter reducer.attempt.artifacts ~f:(fun artifact ->
        if not
             (List.exists previous.attempt.artifacts ~f:(fun old ->
                String.equal old.Artifact.id artifact.Artifact.id))
        then Files.remove (Files.artifact_path entry.dir artifact.id));
      let target = reducer.attempt in
      reducer.attempt <- { previous.attempt with recent_events = [] };
      Reducer.fail
        reducer
        ("Durable simulation update failed: " ^ Error.to_string_hum error);
      if not (Files.is_active target)
      then
        reducer.attempt
        <- { reducer.attempt with
             lifecycle = target.lifecycle
           ; outcome = Incomplete
           ; exit_code = target.exit_code
           ; cases =
               List.map reducer.attempt.cases ~f:(fun c ->
                 match c.status with
                 | Pending | Running -> { c with status = Incomplete }
                 | _ -> c)
           };
      entry.record <- { previous with attempt = reducer.attempt };
      save p entry
  in
  let poll () =
    if Option.is_none reducer.attempt.diagnostic
    then (
      match
        Or_error.try_with (fun () ->
          let stat = Core_unix.lstat events_file in
          require
            (Poly.equal stat.st_kind S_REG
             && Poly.equal stat.st_ino identity.st_ino
             && Poly.equal stat.st_dev identity.st_dev)
            "Events file replaced";
          require
            Int64.(
              stat.st_size >= of_int !position
              && stat.st_size <= of_int Limits.stream_bytes)
            "Events file truncated or stream exceeds 16 MiB";
          let fd =
            Core_unix.openfile events_file ~mode:[ O_RDONLY; O_NONBLOCK; O_CLOEXEC ]
          in
          Exn.protect
            ~finally:(fun () -> Core_unix.close fd)
            ~f:(fun () ->
              let opened = Core_unix.fstat fd in
              require
                (Poly.equal opened.st_ino stat.st_ino
                 && Poly.equal opened.st_dev stat.st_dev)
                "Events descriptor changed";
              ignore (Core_unix.lseek fd (Int64.of_int !position) ~mode:SEEK_SET : int64);
              let buffer = Bytes.create Limits.event_bytes in
              let rec drain remaining =
                if remaining > 0
                then (
                  let n =
                    Core_unix.read fd ~buf:buffer ~pos:0 ~len:(Bytes.length buffer)
                  in
                  if n > 0
                  then (
                    position := !position + n;
                    require
                      (!position <= Limits.stream_bytes)
                      "Event stream byte limit exceeded";
                    let text = !pending ^ Bytes.To_string.sub buffer ~pos:0 ~len:n in
                    let lines = String.split text ~on:'\n' in
                    pending := List.last_exn lines;
                    List.iter (List.drop_last_exn lines) ~f:(fun line ->
                      if Option.is_none reducer.attempt.diagnostic
                      then
                        Reducer.line reducer line ~artifact:(fun declaration ->
                          persist ();
                          require
                            (Option.is_none reducer.attempt.diagnostic)
                            "Artifact capture after persistence failure";
                          capture_artifact p entry declaration));
                    require
                      (String.length !pending < Limits.event_bytes)
                      "Pending event exceeds line limit";
                    if Option.is_none reducer.attempt.diagnostic then drain (remaining - n)))
              in
              drain Limits.event_bytes))
      with
      | Ok () -> ()
      | Error error -> Reducer.fail reducer (Error.to_string_hum error));
    if not (Attempt.equal entry.record.attempt reducer.attempt) then persist ();
    Option.is_none reducer.attempt.diagnostic
  in
  { Simulation_task.invocation =
      Adapter.run
        config
        ~root:p.root
        ~environment
        ~request_file
        ~events_file
        ~artifact_dir
  ; timeout_seconds = config.Config.run_timeout_seconds
  ; preflight = (fun () -> return ())
  ; start =
      (fun () ->
        reducer.attempt
        <- { reducer.attempt with
             lifecycle = Running
           ; execution_timing =
               Execution_timing.make
                 ~started_at:(Timestamp.of_time_ns (Time_ns.now ()))
                 ~running:true
                 ()
           };
        persist ())
  ; stdout = (fun _ -> ())
  ; poll
  ; drain =
      (fun () ->
        let rec loop () =
          let before = !position in
          if poll () && !position > before
          then (
            let%bind () = Clock.after (Time_float.Span.of_ms 0.) in
            loop ())
          else return ()
        in
        loop ())
  ; fail = (fun reason -> Reducer.fail reducer reason)
  ; finish =
      (fun ~cancelled status ->
        let rec final_drain () =
          let before = !position in
          if poll () && !position > before then final_drain ()
        in
        (match Or_error.try_with final_drain with
         | Ok () -> ()
         | Error error ->
           Reducer.fail reducer ("Final event drain failed: " ^ Error.to_string_hum error));
        if not (String.is_empty !pending)
        then Reducer.fail reducer "Unterminated final simulation event";
        ignore (Reducer.finish reducer ~cancelled status : string option);
        let started_at =
          Option.bind reducer.attempt.execution_timing ~f:(fun timing ->
            timing.started_at)
        in
        let measured_seconds =
          Option.map started_at ~f:(fun start ->
            Time_ns.Span.to_sec
              (Time_ns.diff (Time_ns.now ()) (Timestamp.to_time_ns start)))
        in
        reducer.attempt
        <- { reducer.attempt with
             execution_timing =
               Execution_timing.make ?started_at ?measured_seconds ~running:false ()
           };
        (match Or_error.try_with persist with
         | Ok () -> ()
         | Error error ->
           Reducer.fail
             reducer
             ("Terminal record persistence failed: " ^ Error.to_string_hum error);
           ignore (Reducer.finish reducer ~cancelled status : string option);
           entry.record <- { entry.record with attempt = reducer.attempt };
           p.history_error
           <- Some (String.prefix (Error.to_string_hum error) Limits.string_bytes));
        (match Or_error.try_with (fun () -> Files.remove work) with
         | Ok () -> ()
         | Error error ->
           p.history_error
           <- Some (String.prefix (Error.to_string_hum error) Limits.string_bytes));
        reducer.attempt.diagnostic)
  }
;;

let discover p config ~environment ~schedule =
  if p.discovering
  then return ()
  else (
    p.discovering <- true;
    p.discovery_error <- None;
    let output = Buffer.create 4096 in
    let failure = ref None in
    let fail reason = if Option.is_none !failure then failure := Some reason in
    let%map job =
      Monitor.try_with (fun () ->
        schedule ~name:"discover" ~reservation:None ~prepare:(fun _ ->
          { Simulation_task.invocation = Adapter.discover config ~root:p.root ~environment
          ; timeout_seconds = config.discovery_timeout_seconds
          ; preflight = (fun () -> return ())
          ; start = (fun () -> ())
          ; stdout =
              (fun text ->
                if Buffer.length output + String.length text > Limits.discovery_bytes
                then fail "Discovery stdout exceeds 1 MiB"
                else Buffer.add_string output text)
          ; poll = (fun () -> Option.is_none !failure)
          ; drain = (fun () -> return ())
          ; fail
          ; finish =
              (fun ~cancelled status ->
                p.discovering <- false;
                p.discovery_job <- None;
                if cancelled then fail "Discovery cancelled";
                (match status with
                 | Some (Job.Exit_status.Exited 0) -> ()
                 | _ -> fail "Discovery provider did not exit successfully");
                if Option.is_none !failure
                then (
                  match Codec.parse_discovery (Buffer.contents output) with
                  | Error error -> fail (Error.to_string_hum error)
                  | Ok discovery ->
                    p.discovery <- Some discovery;
                    p.discovery_digest
                    <- Some
                         (Files.digest
                            (Sexp.to_string_mach (Discovery.sexp_of_t discovery)));
                    p.discovery_config <- Some (config_digest config);
                    p.discovery_environment <- Some environment);
                p.discovery_error <- !failure;
                !failure)
          }))
    in
    match job with
    | Ok job -> p.discovery_job <- (if p.discovering then Some job else None)
    | Error exn ->
      p.discovering <- false;
      p.discovery_job <- None;
      p.discovery_error <- Some (Exn.to_string exn);
      raise exn)
;;

let read_artifact p entry ~artifact_id ~sha256 ~offset ~limit =
  if limit < 1 || limit > Limits.byte_page || offset < 0
  then rpc_error Invalid_request "Invalid simulation byte page bounds";
  let artifact =
    match
      List.find entry.record.attempt.artifacts ~f:(fun a ->
        String.equal a.Artifact.id artifact_id)
    with
    | Some a -> a
    | None -> rpc_error Not_found "Simulation artifact not found"
  in
  if not (Option.equal String.equal artifact.sha256 (Some sha256))
  then rpc_error Conflict "Artifact digest fence mismatch";
  let path = Files.artifact_path entry.dir artifact_id in
  let%bind availability, bytes =
    In_thread.run (fun () ->
      let result =
        Or_error.try_with (fun () -> Files.read path ~max_bytes:Limits.artifact_bytes)
      in
      match result with
      | Error _ ->
        ( (match Sys_unix.file_exists ~follow_symlinks:false path with
           | `Yes -> Artifact.Availability.Changed
           | `No | `Unknown -> Missing)
        , None )
      | Ok bytes
        when (not (Option.equal Int.equal artifact.size (Some (String.length bytes))))
             || not (String.equal (Files.digest bytes) sha256) -> Changed, None
      | Ok bytes -> Available, Some bytes)
  in
  if not
       (Option.exists
          (Hashtbl.find p.entries entry.record.attempt.id)
          ~f:(phys_equal entry))
  then rpc_error Not_found "Simulation attempt was evicted during artifact read";
  if not (Artifact.Availability.equal artifact.availability availability)
  then (
    let artifact = { artifact with availability } in
    entry.record
    <- { entry.record with
         attempt =
           { entry.record.attempt with
             artifacts =
               List.map entry.record.attempt.artifacts ~f:(fun old ->
                 if String.equal old.id artifact.id then artifact else old)
           }
       };
    save p entry);
  match bytes with
  | None ->
    rpc_error
      (match availability with
       | Changed -> Conflict
       | _ -> Not_found)
      "Simulation artifact missing, changed or unreadable"
  | Some bytes ->
    let total_size = String.length bytes in
    if offset > total_size then rpc_error Invalid_request "Artifact offset past EOF";
    let length = Int.min limit (total_size - offset) in
    return
      { Byte_page.attempt_id = entry.record.attempt.id
      ; artifact_id
      ; sha256
      ; offset
      ; next_offset = offset + length
      ; total_size
      ; eof = offset + length = total_size
      ; bytes_hex = Files.hex (String.sub bytes ~pos:offset ~len:length)
      }
;;

let handle t ~root ~environment ~schedule ~cancel ~verify_asic operation =
  let gate f =
    match operation with
    | Operation.Get | Observe _ | History _ | Cancel _ -> f ()
    | _ -> serialize t ~root f
  in
  gate (fun () ->
    let%map result =
      Monitor.try_with (fun () ->
        let p = project t root in
        let config_result = Or_error.try_with (fun () -> load_config p) in
        let configured =
          match config_result with
          | Ok None -> false
          | _ -> true
        in
        (match config_result with
         | Error error -> p.discovery_error <- Some (Error.to_string_hum error)
         | _ -> ());
        let config_exn () =
          match config_result with
          | Ok (Some config) -> config
          | Ok None ->
            rpc_error Unsupported_operation "Simulation provider is not configured"
          | Error error -> rpc_error Invalid_request (Error.to_string_hum error)
        in
        let snap ?detail ?byte_page ?before ?limit () =
          snapshot p ~configured ?detail ?byte_page ?before ?limit ()
        in
        match operation with
        | Operation.Get -> return (snap ())
        | History { before; limit } ->
          if limit < 1 || limit > Limits.history_page
          then rpc_error Invalid_request "History limit must be 1..25";
          return (snap ?before ~limit ())
        | Observe id -> return (snap ~detail:(inspect_artifacts p (find p id)) ())
        | Read_artifact_bytes { attempt_id; artifact_id; sha256; offset; limit } ->
          let entry = find p attempt_id in
          let%bind byte_page =
            read_artifact p entry ~artifact_id ~sha256 ~offset ~limit
          in
          return (snap ~detail:entry.record.attempt ~byte_page ())
        | Cancel id ->
          let entry = find p id in
          if not (Files.is_active entry.record.attempt)
          then return (snap ~detail:entry.record.attempt ())
          else (
            let%map () = cancel entry.record.attempt.job in
            snap ~detail:entry.record.attempt ())
        | Discover ->
          let%map () = discover p (config_exn ()) ~environment ~schedule in
          snap ()
        | (Launch _ | Rerun _) as operation ->
          let submission_key =
            match operation with
            | Launch r -> r.submission_key
            | Rerun r -> r.submission_key
            | _ -> assert false
          in
          if String.length submission_key > Limits.key_bytes
             || not
                  (Hardcaml_workbench_project_integration.Driver_protocol.valid_key
                     submission_key)
          then rpc_error Invalid_request "Invalid simulation submission key";
          (* Reservation lookup precedes all mutable catalog/config/evidence validation. *)
          let normalized : Operation.t =
            match operation with
            | Launch r ->
              Launch
                { r with
                  selection =
                    { r.selection with
                      cases = List.sort r.selection.cases ~compare:String.compare
                    ; parameters =
                        List.sort r.selection.parameters ~compare:(fun (a, _) (b, _) ->
                          String.compare a b)
                    }
                }
            | Rerun r ->
              Rerun { r with cases = List.sort r.cases ~compare:String.compare }
            | _ -> assert false
          in
          let payload = Sexp.to_string_mach (Operation.sexp_of_t normalized) in
          (match
             List.find (Hashtbl.data p.entries) ~f:(fun e ->
               String.equal e.record.submission_key submission_key)
           with
           | Some entry ->
             (* Launch lists are normalized below, so equivalent ordering is accepted. *)
             let equivalent =
               String.equal entry.record.payload payload
               ||
               match operation with
               | Launch r ->
                 let old = Operation.t_of_sexp (Sexp.of_string entry.record.payload) in
                 (match old with
                  | Launch old ->
                    let sort selection =
                      { selection with
                        Selection.cases =
                          List.sort selection.Selection.cases ~compare:String.compare
                      ; parameters =
                          List.sort selection.parameters ~compare:(fun (a, _) (b, _) ->
                            String.compare a b)
                      }
                    in
                    String.equal old.discovery_digest r.discovery_digest
                    && Selection.equal (sort old.selection) (sort r.selection)
                  | _ -> false)
               | _ -> false
             in
             if not equivalent
             then
               rpc_error
                 Conflict
                 "Submission key was used for different simulation inputs";
             return (snap ~detail:entry.record.attempt ())
           | None ->
             let config = config_exn () in
             if p.discovering
                || Option.is_some p.discovery_error
                || (not
                      (Option.equal
                         V1.Environment_selection.equal
                         p.discovery_environment
                         (Some environment)))
                || not
                     (Option.equal
                        String.equal
                        p.discovery_config
                        (Some (config_digest config)))
             then rpc_error Conflict "Current successful simulation discovery is required";
             let discovery =
               match p.discovery with
               | Some d -> d
               | None -> rpc_error Conflict "Discover simulation suites first"
             in
             let discovery_digest = Option.value_exn p.discovery_digest in
             let selection, parent =
               match operation with
               | Launch r ->
                 if not
                      (Option.equal
                         String.equal
                         p.discovery_digest
                         (Some r.discovery_digest))
                 then rpc_error Conflict "Stale simulation discovery digest";
                 r.selection, None
               | Rerun r ->
                 let original = (find p r.attempt_id).record.attempt in
                 if List.is_empty r.cases
                    || not
                         (List.for_all r.cases ~f:(fun id ->
                            List.mem
                              original.captured.selection.cases
                              id
                              ~equal:String.equal))
                 then
                   rpc_error
                     Invalid_request
                     "Rerun cases must be an explicit nonempty original subset";
                 ( { original.captured.selection with cases = r.cases }
                 , Some { Parent.attempt_id = original.id; job = original.job } )
               | _ -> assert false
             in
             let selection =
               match Codec.validate_selection discovery selection with
               | Ok s -> s
               | Error e -> rpc_error Invalid_request (Error.to_string_hum e)
             in
             let%bind () = verify_asic selection.asic_inputs in
             prune p ~reserve:1;
             let id =
               "sim-"
               ^ Files.digest
                   (root
                    ^ Time_ns.to_string (Time_ns.now ())
                    ^ Int.to_string (Random.int 1_000_000_000))
             in
             let dir = Filename.concat p.dir id in
             Files.mkdir dir;
             let entry_ref = ref None in
             let%map scheduled =
               Monitor.try_with (fun () ->
                 schedule
                   ~name:"run"
                   ~reservation:(Some (submission_key, payload))
                   ~prepare:(fun job ->
                     let config_unchanged =
                       match Or_error.try_with (fun () -> load_config p) with
                       | Ok (Some current) -> Config.equal current config
                       | Ok None | Error _ -> false
                     in
                     if (not config_unchanged)
                        || p.discovering
                        || Option.is_some p.discovery_error
                        || (not
                              (Option.equal
                                 String.equal
                                 p.discovery_config
                                 (Some (config_digest config))))
                        || (not
                              (Option.equal
                                 String.equal
                                 p.discovery_digest
                                 (Some discovery_digest)))
                        || not
                             (Option.equal
                                V1.Environment_selection.equal
                                p.discovery_environment
                                (Some environment))
                     then
                       rpc_error
                         Conflict
                         "Simulation configuration/discovery changed before reservation";
                     let attempt : Attempt.t =
                       { id
                       ; job
                       ; project_root = root
                       ; created_at = Time_ns.to_string (Time_ns.now ())
                       ; parent
                       ; captured =
                           { selection
                           ; discovery_digest
                           ; provider_executable = config.provider_executable
                           ; provider_args = config.provider_args
                           ; environment
                           }
                       ; lifecycle = Queued
                       ; outcome = Unknown
                       ; exit_code = None
                       ; diagnostic = None
                       ; progress = None
                       ; cases =
                           List.map selection.cases ~f:(fun case_id ->
                             { Case_result.case_id
                             ; status = Pending
                             ; message = None
                             ; progress = None
                             })
                       ; artifacts = []
                       ; next_sequence = 0
                       ; recent_events = []
                       ; execution_timing = None
                       }
                     in
                     let entry =
                       { record = { schema_version = 1; submission_key; payload; attempt }
                       ; dir
                       }
                     in
                     Hashtbl.set p.entries ~key:id ~data:entry;
                     entry_ref := Some entry;
                     let reserved = ref false in
                     try
                       save p entry;
                       reserved := true;
                       run_task p entry config ~environment
                     with
                     | exn ->
                       if not !reserved
                       then (
                         Hashtbl.remove p.entries id;
                         ignore
                           (Or_error.try_with (fun () -> Files.remove dir)
                            : unit Or_error.t);
                         raise exn);
                       entry.record
                       <- { entry.record with
                            attempt =
                              { attempt with
                                lifecycle = Finished
                              ; outcome = Incomplete
                              ; diagnostic =
                                  Some
                                    (String.prefix
                                       (Exn.to_string exn)
                                       Limits.string_bytes)
                              ; cases =
                                  List.map attempt.cases ~f:(fun c ->
                                    { c with status = Incomplete })
                              }
                          };
                       ignore
                         (Or_error.try_with (fun () -> save p entry) : unit Or_error.t);
                       raise exn))
             in
             (match scheduled with
              | Ok (_ : Job_id.t) -> ()
              | Error exn ->
                if Option.is_none !entry_ref
                then
                  ignore
                    (Or_error.try_with (fun () -> Files.remove dir) : unit Or_error.t);
                raise (Monitor.extract_exn exn));
             snap ~detail:(Option.value_exn !entry_ref).record.attempt ()))
    in
    match result with
    | Ok snapshot -> Ok snapshot
    | Error exn ->
      (match Monitor.extract_exn exn with
       | Rpc_error error -> Error error
       | exn ->
         Error
           (V1.Error.create
              Internal_failure
              (String.prefix (Exn.to_string exn) Limits.string_bytes))))
;;
