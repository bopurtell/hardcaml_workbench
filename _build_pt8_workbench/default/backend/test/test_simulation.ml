open! Core
open! Async
open Hardcaml_workbench_protocol
open Simulation
module Service = Hardcaml_workbench_backend.Service
module Files = Hardcaml_workbench_backend.Simulation_files
module Store = Hardcaml_workbench_backend.Simulation_service
module Reducer = Hardcaml_workbench_backend.Simulation_reducer
module Config = Hardcaml_workbench_project_integration.Simulation_config
module Codec = Hardcaml_workbench_project_integration.Simulation_protocol

let require condition message = if not condition then failwith message

let ok = function
  | Ok x -> x
  | Error (error : V1.Error.t) -> raise_s [%sexp (error : V1.Error.t)]
;;

let expect_error result kind =
  match result with
  | Error (error : V1.Error.t) ->
    require (V1.Error.Kind.equal error.kind kind) error.message
  | Ok _ -> failwith "Expected typed RPC error"
;;

let codecs () =
  require
    (Result.is_error (Config.parse_string "((schema_version 2))"))
    "Invalid config accepted";
  require
    (Result.is_error
       (Codec.parse_discovery (String.make (Limits.discovery_bytes + 1) 'x')))
    "Oversized discovery accepted";
  require
    (Result.is_error
       (Codec.parse_event_line
          "((protocol_version 2)(attempt_id a)(sequence 0)(payload Started))"))
    "Event version accepted";
  require
    (Result.is_error
       (Codec.parse_event_line
          "((protocol_version 1)(attempt_id a)(sequence 0)(payload (Finished Unknown)))"))
    "Unknown completion accepted";
  let discovery =
    Codec.parse_discovery
      "((protocol_version 1)(suites (((id s)(label S)(cases (((id c)(label \
       C))))(parameters ())(default_seed 0)))))"
    |> Or_error.ok_exn
  in
  let selection : Selection.t =
    { suite = "s"
    ; cases = [ "c" ]
    ; seed = "18446744073709551615"
    ; parameters = []
    ; asic_inputs = []
    }
  in
  require
    (Result.is_ok (Codec.validate_selection discovery selection))
    "uint64 seed rejected";
  List.iter [ "18446744073709551616"; "01"; "-1"; "" ] ~f:(fun seed ->
    require
      (Result.is_error (Codec.validate_selection discovery { selection with seed }))
      "Invalid seed accepted");
  require
    (Result.is_error
       (Codec.validate_selection discovery { selection with cases = [ "c"; "c" ] }))
    "Duplicate case accepted"
;;

let reducers () =
  let initial : Attempt.t =
    { id = "sim-test"
    ; job = Job_id.of_string "job"
    ; project_root = "/test"
    ; created_at = "0"
    ; parent = None
    ; captured =
        { selection =
            { suite = "s"
            ; cases = [ "c" ]
            ; seed = "0"
            ; parameters = []
            ; asic_inputs = []
            }
        ; discovery_digest = "digest"
        ; provider_executable = "/provider"
        ; provider_args = []
        ; environment = Inherit_daemon
        }
    ; lifecycle = Running
    ; outcome = Unknown
    ; exit_code = None
    ; diagnostic = None
    ; progress = None
    ; cases = [ { case_id = "c"; status = Pending; message = None; progress = None } ]
    ; artifacts = []
    ; next_sequence = 0
    ; recent_events = []
    ; execution_timing = None
    }
  in
  let event ?(attempt_id = "sim-test") sequence payload : Provider.Event.t =
    { protocol_version = 1; attempt_id; sequence; payload }
  in
  let run ?(exit = 0) events =
    let r = Reducer.create initial in
    List.iter events ~f:(fun e ->
      Reducer.line
        r
        (Sexp.to_string_mach (Provider.Event.sexp_of_t e))
        ~artifact:(fun _ -> failwith "Unexpected artifact"));
    ignore (Reducer.finish r ~cancelled:false (Some (Exited exit)) : string option);
    r.attempt
  in
  let start = event 0 Started in
  let case_start = event 1 (Case_started "c") in
  let pass = event 2 (Case_finished { case_id = "c"; status = Passed; message = None }) in
  let finish = event 3 (Finished Passed) in
  let passed = run [ start; case_start; pass; finish ] in
  require (Outcome.equal passed.outcome Passed) "Valid reducer stream failed";
  let payload =
    Sexp.to_string_mach
      (Operation.sexp_of_t
         (Launch
            { submission_key = "key"
            ; discovery_digest = passed.captured.discovery_digest
            ; selection = passed.captured.selection
            }))
  in
  let record : Store.Record.t =
    { schema_version = 1; submission_key = "key"; payload; attempt = passed }
  in
  Store.validate_record record;
  require
    (Result.is_error
       (Or_error.try_with (fun () ->
          Store.validate_record
            { record with
              attempt =
                { passed with
                  cases = List.map passed.cases ~f:(fun c -> { c with status = Running })
                }
            })))
    "Corrupt historical success accepted";
  List.iter
    [ [ case_start ]
    ; [ start; start ]
    ; [ start; event 2 (Case_started "c") ]
    ; [ start; event ~attempt_id:"wrong" 1 (Case_started "c") ]
    ; [ start; event 1 (Case_started "unknown") ]
    ; [ start; case_start ]
    ; [ start; case_start; event 2 (Finished Passed) ]
    ; [ start; case_start; pass; event 3 (Finished Failed) ]
    ; [ start; case_start; pass; finish; event 4 Started ]
    ]
    ~f:(fun stream ->
      require
        (Outcome.equal (run stream).outcome Incomplete)
        "Invalid stream manufactured success");
  require
    (Outcome.equal (run ~exit:7 [ start; case_start; pass; finish ]).outcome Incomplete)
    "Nonzero exit trusted semantic pass";
  let progress sequence completed total unit_ =
    event sequence (Progress { case_id = Some "c"; completed; total; unit_ })
  in
  List.iter
    [ [ progress 2 2 None "cycles"; progress 3 1 None "cycles" ]
    ; [ progress 2 1 (Some 3) "cycles"; progress 3 2 None "cycles" ]
    ; [ progress 2 1 None "cycles"; progress 3 2 None "ticks" ]
    ]
    ~f:(fun invalid ->
      require
        (Outcome.equal (run ([ start; case_start ] @ invalid)).outcome Incomplete)
        "Invalid progress accepted");
  let r = Reducer.create initial in
  let feed e =
    Reducer.line
      r
      (Sexp.to_string_mach (Provider.Event.sexp_of_t e))
      ~artifact:(fun _ -> failwith "artifact")
  in
  feed start;
  feed case_start;
  for n = 2 to 301 do
    feed (progress n n None "cycles")
  done;
  require
    (List.length r.attempt.recent_events = Limits.retained_events
     && r.attempt.next_sequence = 302)
    "Live detail not bounded";
  require
    (Option.is_none (Option.value_exn (List.hd_exn r.attempt.cases).progress).total)
    "Unknown total invented";
  require
    (Result.is_error
       (Codec.parse_event_line
          "#; ignored ((protocol_version 1)(attempt_id a)(sequence 0)(payload Started))"))
    "Comment framing accepted"
;;

let rec wait f predicate =
  let%bind value = f () in
  if predicate value
  then return value
  else (
    let%bind () = Clock.after (Time_float.Span.of_ms 20.) in
    wait f predicate)
;;

let bounded deferred =
  Clock.with_timeout (Time_float.Span.of_sec 12.) deferred
  >>| function
  | `Result value -> value
  | `Timeout -> failwith "Simulation test timed out"
;;

(* Review regressions: synthetic scheduling tests the reservation boundary without
   invoking opam, building fixtures, or creating a second process scheduler. *)
let review_store ~root ~state_dir ~config ~catalog =
  let scan = Filename.concat state_dir "scan" in
  Files.mkdir scan;
  for n = 1 to 12 do
    Files.mkdir (Filename.concat scan (Int.to_string n))
  done;
  let names, truncated = Files.directory_entries scan ~limit:3 in
  require (List.length names = 3 && truncated) "Corrupt-directory scan was not bounded";
  let store = Store.create ~state_dir in
  let p = Store.project store root in
  p.discovery <- catalog.Snapshot.discovery;
  p.discovery_digest <- catalog.discovery_digest;
  p.discovery_config <- Some (Store.config_digest config);
  p.discovery_environment <- Some V1.Environment_selection.Inherit_daemon;
  let operation : Operation.t =
    Launch
      { submission_key = "review-reservation"
      ; discovery_digest = Option.value_exn catalog.discovery_digest
      ; selection =
          { suite = "demo"
          ; cases = [ "one" ]
          ; seed = "42"
          ; parameters = [ "mode", "pass" ]
          ; asic_inputs = []
          }
      }
  in
  let handle ?(environment = V1.Environment_selection.Inherit_daemon) schedule operation =
    Store.handle
      store
      ~root
      ~environment
      ~schedule
      ~cancel:(fun _ -> return ())
      ~verify_asic:(fun _ -> return ())
      operation
  in
  let unexpected ~name:_ ~reservation:_ ~prepare:_ =
    failwith "Unexpected provider scheduling"
  in
  (* Read-only hydration reuses the retained catalog, including when the old job has
     finished or disappeared from the scheduler. No provider is scheduled. *)
  let check_get expected_job =
    let%map result = handle unexpected Get in
    let snapshot = ok result in
    require
      (Option.equal Discovery.equal snapshot.discovery catalog.discovery
       && Option.equal String.equal snapshot.discovery_digest catalog.discovery_digest)
      "Get lost retained discovery";
    require
      (Option.equal Job_id.equal snapshot.discovery_job expected_job)
      "Get reported inactive discovery as in flight"
  in
  p.discovery_job <- Some (Job_id.of_string "finished-or-pruned-discovery");
  let%bind () = check_get None in
  p.discovery_job <- None;
  let%bind () = check_get None in
  p.discovering <- true;
  p.discovery_job <- Some (Job_id.of_string "active-discovery");
  let%bind () = check_get p.discovery_job in
  p.discovering <- false;
  p.discovery_error <- Some "retained discovery failure";
  let%bind failed_discovery = handle unexpected Get in
  require
    (Option.equal String.equal (ok failed_discovery).discovery_error p.discovery_error)
    "Get lost discovery failure";
  p.discovery_error <- None;
  p.discovery_job <- None;
  let%bind mismatch =
    handle ~environment:(Opam_switch "different-context") unexpected operation
  in
  expect_error mismatch Conflict;
  let config_path = Filename.concat root Config.filename in
  let schedule_changed ~name:_ ~reservation:_ ~prepare =
    Files.atomic
      config_path
      (Sexp.to_string_mach (Config.sexp_of_t { config with run_timeout_seconds = 3 }));
    ignore
      (prepare (Job_id.of_string "changed-before-reservation")
       : Hardcaml_workbench_backend.Simulation_task.t);
    failwith "Changed config was accepted"
  in
  let%bind changed = handle schedule_changed operation in
  expect_error changed Conflict;
  require
    (Hashtbl.is_empty p.entries)
    "Pre-reservation conflict left an accepted reservation";
  Files.atomic config_path (Sexp.to_string_mach (Config.sexp_of_t config));
  let schedule_full ~name:_ ~reservation:_ ~prepare =
    List.iter (Sys_unix.ls_dir p.dir) ~f:(fun name ->
      Files.mkdir (Filename.concat (Filename.concat p.dir name) "record.sexp"));
    ignore
      (prepare (Job_id.of_string "write-failure")
       : Hardcaml_workbench_backend.Simulation_task.t);
    failwith "Reservation storage failure was accepted"
  in
  let%bind failed = handle schedule_full operation in
  expect_error failed Internal_failure;
  require
    (Hashtbl.is_empty p.entries)
    "Failed first durable write retained a fake idempotent result";
  (* Get/Cancel must not queue behind a slow export or an allocation awaiting I/O. *)
  let release = Ivar.create () in
  let held = Store.serialize store ~root (fun () -> Ivar.read release) in
  let%bind get =
    Clock.with_timeout (Time_float.Span.of_ms 100.) (handle unexpected Get)
  in
  require
    (match get with
     | `Result (Ok _) -> true
     | _ -> false)
    "Get blocked behind mutation/export gate";
  Ivar.fill_exn release ();
  let%bind () = held in
  let schedule_drain ~name:_ ~reservation:_ ~prepare =
    let job = Job_id.of_string "review-drain" in
    let task : Hardcaml_workbench_backend.Simulation_task.t = prepare job in
    let entry =
      List.find_exn (Hashtbl.data p.entries) ~f:(fun e ->
        Job_id.equal e.Store.record.attempt.job job)
    in
    let id = entry.record.attempt.id in
    let event sequence payload : Provider.Event.t =
      { protocol_version = 1; attempt_id = id; sequence; payload }
    in
    let events =
      [ event 0 Started; event 1 (Case_started "one") ]
      @ List.init 600 ~f:(fun n ->
        event
          (n + 2)
          (Progress
             { case_id = Some "one"; completed = n; total = None; unit_ = "cycles" }))
      @ [ event 602 (Case_finished { case_id = "one"; status = Passed; message = None })
        ; event 603 (Finished Passed)
        ]
    in
    task.start ();
    Out_channel.write_all
      (Filename.concat entry.dir "work/events.sexp")
      ~data:
        (String.concat
           (List.map events ~f:(fun e ->
              Sexp.to_string_mach (Provider.Event.sexp_of_t e) ^ "\n")));
    let yielded = ref false in
    let wake = Clock.after (Time_float.Span.of_ms 0.) >>| fun () -> yielded := true in
    let%bind () = task.drain () in
    require !yielded "Final event drain monopolized the event loop";
    require
      (entry.record.attempt.next_sequence = 604)
      "Final drain dropped a multi-chunk backlog";
    ignore (task.finish ~cancelled:true (Some (Exited 0)) : string option);
    require
      (Lifecycle.equal entry.record.attempt.lifecycle Cancelled
       && Outcome.equal entry.record.attempt.outcome Incomplete
       && Case_status.equal (List.hd_exn entry.record.attempt.cases).status Passed)
      "Cancelled drain lost completed case or trusted provisional Finished";
    let%map () = wake in
    job
  in
  let%bind accepted = handle schedule_drain operation in
  let accepted = ok accepted in
  let id = (Option.value_exn accepted.detail).id in
  let%bind retry = handle unexpected operation in
  require
    (String.equal (Option.value_exn (ok retry).detail).id id)
    "Retry after rejected storage attempt did not preserve accepted capture";
  let failing_operation : Operation.t =
    match operation with
    | Launch request -> Launch { request with submission_key = "terminal-write-failure" }
    | _ -> assert false
  in
  let terminal_failure ~name:_ ~reservation:_ ~prepare =
    let job = Job_id.of_string "terminal-write-failure" in
    let task : Hardcaml_workbench_backend.Simulation_task.t = prepare job in
    let entry =
      List.find_exn (Hashtbl.data p.entries) ~f:(fun e ->
        Job_id.equal e.Store.record.attempt.job job)
    in
    Files.remove (Store.record_path entry);
    Files.mkdir (Store.record_path entry);
    let diagnostic = task.finish ~cancelled:true None in
    require
      (Option.is_some diagnostic
       && (not (Files.is_active entry.record.attempt))
       && Lifecycle.equal entry.record.attempt.lifecycle Cancelled
       && Outcome.equal entry.record.attempt.outcome Incomplete)
      "Terminal persistence failure left a live or successful attempt";
    return job
  in
  let%map failed = handle terminal_failure failing_operation in
  require
    (Option.is_some (ok failed).history_error)
    "Terminal persistence failure concealed store error"
;;

let tests fixture =
  codecs ();
  reducers ();
  let tree = Filename_unix.temp_dir "fs2-backend-" "" in
  let root = Filename.concat tree "project" in
  let state_dir = Filename.concat tree "state" in
  Files.mkdir root;
  Out_channel.write_all
    (Filename.concat root "dune-project")
    ~data:"(lang dune 3.22)\n(name fs2_backend_test)\n";
  Out_channel.write_all (Filename.concat root "dune") ~data:"";
  let config : Config.t =
    { schema_version = 1
    ; provider_executable = "/usr/bin/python3"
    ; provider_args = [ fixture ]
    ; discovery_timeout_seconds = 5
    ; run_timeout_seconds = 2
    }
  in
  Files.atomic
    (Filename.concat root Config.filename)
    (Sexp.to_string_mach (Config.sexp_of_t config));
  let create label =
    let instance_id = V1.Daemon_instance_id.of_string label in
    let%bind service =
      Service.create
        ~instance_id
        ~state_dir
        ~log_dir:(Filename.concat tree label)
        ~kill_after:(Time_float.Span.of_ms 50.)
        ~action_invocation:(fun ~root ~environment _ ->
          { executable = "/bin/sh"
          ; argv = [ "/bin/sh"; "-c"; "sleep 0.2" ]
          ; cwd = root
          ; environment
          })
        ()
      >>| Or_error.ok_exn
    in
    let%map project =
      Service.open_project service { instance_id; root; environment = Inherit_daemon }
      >>| ok
    in
    service, instance_id, project.project.id
  in
  Monitor.protect
    ~finally:(fun () ->
      Files.remove tree;
      return ())
    (fun () ->
      let%bind service, instance_id, project = create "first" in
      let rpc operation =
        Service.simulation service { instance_id; project; operation }
      in
      let get operation = rpc operation >>| ok in
      let discovery () =
        let%bind (_ : Snapshot.t) = get Discover in
        bounded
          (wait
             (fun () -> get Get)
             (fun snapshot ->
               Option.is_some snapshot.discovery
               && Option.is_none snapshot.discovery_error))
      in
      let%bind catalog = discovery () in
      let digest = Option.value_exn catalog.discovery_digest in
      let selection ?(cases = [ "one"; "two" ]) mode =
        { Selection.suite = "demo"
        ; cases
        ; seed = "42"
        ; parameters = [ "mode", mode ]
        ; asic_inputs = []
        }
      in
      let launch ?cases key mode : Operation.t =
        Launch
          { submission_key = key
          ; discovery_digest = digest
          ; selection = selection ?cases mode
          }
      in
      let observe id =
        get (Observe id) >>| fun snapshot -> Option.value_exn snapshot.detail
      in
      let terminal attempt =
        bounded
          (wait (fun () -> observe attempt.Attempt.id) (fun a -> not (Files.is_active a)))
      in
      let detail snapshot = Option.value_exn snapshot.Snapshot.detail in
      let%bind first, retry =
        Deferred.both (get (launch "same" "pass")) (get (launch "same" "pass"))
      in
      let first = detail first in
      require (String.equal first.id (detail retry).id) "Concurrent retry launched twice";
      let%bind conflict = rpc (launch "same" "fail") in
      expect_error conflict Conflict;
      let%bind first = terminal first in
      let first_timing = Option.value_exn first.execution_timing in
      require
        (Option.is_some first_timing.started_at
         && Option.is_some first_timing.measured_seconds
         && not first_timing.running)
        "Terminal simulation duration missing";
      let%bind frozen = observe first.id in
      require
        (Option.equal
           Execution_timing.equal
           first.execution_timing
           frozen.execution_timing)
        "Terminal simulation duration changed on observation";
      require
        (Outcome.equal first.outcome Passed)
        (Option.value first.diagnostic ~default:"Expected pass");
      require (List.length first.artifacts = 2) "Artifact capture failed";
      let artifact = List.hd_exn first.artifacts in
      let read offset limit sha256 =
        get
          (Read_artifact_bytes
             { attempt_id = first.id; artifact_id = artifact.id; sha256; offset; limit })
      in
      let hash = Option.value_exn artifact.sha256 in
      let%bind page = read 0 3 hash in
      require
        (String.equal (Option.value_exn page.byte_page).bytes_hex "00ff0d")
        "Raw byte transfer changed bytes";
      let%bind page = read 3 Limits.byte_page hash in
      require
        (String.equal (Option.value_exn page.byte_page).bytes_hex "0a56434480")
        "Raw byte page suffix changed";
      let%bind page = read 8 1 hash in
      require (Option.value_exn page.byte_page).eof "EOF page failed";
      let%bind logs =
        Service.read_log
          service
          { instance_id
          ; job = first.job
          ; offset = 0
          ; max_records = 256
          ; max_bytes = 256 * 1024
          }
        >>| ok
      in
      require
        (List.exists logs.records ~f:(fun r ->
           String.is_substring r.data ~substring:"human stdout"))
        "Human logs unavailable";
      let%bind rerun =
        get (Rerun { submission_key = "rerun"; attempt_id = first.id; cases = [ "two" ] })
      in
      let rerun = detail rerun in
      require
        (Option.value_exn rerun.parent
         |> fun p ->
         String.equal p.Parent.attempt_id first.id && Job_id.equal p.job first.job)
        "Rerun parent identity lost";
      require
        (String.equal rerun.captured.selection.seed "42"
         && List.equal String.equal rerun.captured.selection.cases [ "two" ])
        "Rerun capture changed";
      let%bind (_ : Attempt.t) = terminal rerun in
      let%bind reordered =
        get
          (Launch
             { submission_key = "same"
             ; discovery_digest = digest
             ; selection = selection ~cases:[ "two"; "one" ] "pass"
             })
      in
      require
        (String.equal (detail reordered).id first.id)
        "Equivalent reordered retry conflicted";
      let%bind stale =
        rpc
          (Launch
             { submission_key = "stale"
             ; discovery_digest = "wrong"
             ; selection = selection "pass"
             })
      in
      expect_error stale Conflict;
      let%bind () =
        Deferred.List.iter
          [ "fail"
          ; "bad"
          ; "gap"
          ; "duplicate"
          ; "truncated"
          ; "nonzero"
          ; "symlink"
          ; "oversized"
          ; "stream-overflow"
          ]
          ~how:`Sequential
          ~f:(fun mode ->
            let%bind attempt = get (launch mode mode) >>| detail in
            let%map attempt = terminal attempt in
            let expected =
              match mode with
              | "fail" -> Outcome.Failed
              | "symlink" -> Passed
              | _ -> Incomplete
            in
            require (Outcome.equal attempt.outcome expected) ("Wrong outcome for " ^ mode);
            if String.equal mode "symlink"
            then
              require
                (List.for_all attempt.artifacts ~f:(fun a ->
                   not (Artifact.Availability.equal a.availability Available)))
                "Symlink artifact admitted")
      in
      let refresh () =
        let%bind started = get Discover in
        let discovery_job = Option.value_exn started.discovery_job in
        let%bind (_ : Job.t) =
          bounded
            (wait
               (fun () ->
                 let jobs = (ok (Service.snapshot service { instance_id })).jobs in
                 return
                   (List.find_exn jobs ~f:(fun job -> Job_id.equal job.id discovery_job)))
               Job.is_terminal)
        in
        get Get
      in
      let%bind () =
        Deferred.List.iter [ "bad"; "version" ] ~how:`Sequential ~f:(fun mode ->
          Files.atomic (Filename.concat root "discovery-mode") mode;
          let%bind failed = refresh () in
          require
            (Option.is_some failed.discovery_error
             && Option.equal String.equal failed.discovery_digest (Some digest))
            "Failed refresh discarded catalog or concealed error";
          let%map blocked = rpc (launch ("blocked-" ^ mode) "pass") in
          expect_error blocked Conflict)
      in
      Files.remove (Filename.concat root "discovery-mode");
      let%bind refreshed = refresh () in
      require
        (Option.is_none refreshed.discovery_error)
        "Successful rediscovery did not recover";
      Files.atomic
        (Filename.concat root Config.filename)
        (Sexp.to_string_mach (Config.sexp_of_t { config with run_timeout_seconds = 3 }));
      let%bind config_fence = rpc (launch "changed-config" "pass") in
      expect_error config_fence Conflict;
      Files.atomic
        (Filename.concat root Config.filename)
        (Sexp.to_string_mach (Config.sexp_of_t config));
      let%bind () =
        review_store
          ~root
          ~state_dir:(Filename.concat tree "review-state")
          ~config
          ~catalog:refreshed
      in
      let%bind timeout = get (launch ~cases:[ "one" ] "timeout" "hang") >>| detail in
      let%bind timeout = terminal timeout in
      require
        (Outcome.equal timeout.outcome Incomplete && Option.is_some timeout.diagnostic)
        "Timeout manufactured success";
      let%bind hanging = get (launch "cancel" "hang") >>| detail in
      let%bind (_ : Attempt.t) =
        bounded
          (wait
             (fun () -> observe hanging.id)
             (fun a -> Lifecycle.equal a.lifecycle Running))
      in
      let%bind cancelled = get (Cancel hanging.id) >>| detail in
      require
        (Lifecycle.equal cancelled.lifecycle Cancelled
         && Outcome.equal cancelled.outcome Incomplete)
        "Cancellation lost partial state";
      let%bind provisional = get (launch "provisional" "post-finish-hang") >>| detail in
      let%bind provisional =
        bounded
          (wait
             (fun () -> observe provisional.id)
             (fun a ->
               List.for_all a.cases ~f:(fun c -> Case_status.equal c.status Passed)))
      in
      require
        (Outcome.equal provisional.outcome Unknown)
        "Finished event committed before process exit";
      let%bind provisional = get (Cancel provisional.id) >>| detail in
      require
        (Lifecycle.equal provisional.lifecycle Cancelled
         && Outcome.equal provisional.outcome Incomplete)
        "Cancellation trusted provisional completion";
      let%bind generic =
        Service.submit_job
          service
          { instance_id; project; action = Build; submission_key = "generic" }
        >>| ok
      in
      let%bind queued = get (launch "queued" "pass") >>| detail in
      require
        (Lifecycle.equal queued.lifecycle Queued)
        "Simulation bypassed per-root supervisor queue";
      let%bind queued = get (Cancel queued.id) >>| detail in
      require (Lifecycle.equal queued.lifecycle Cancelled) "Queued cancellation failed";
      let%bind (_ : Job.t) =
        bounded
          (wait
             (fun () ->
               let jobs = (ok (Service.snapshot service { instance_id })).jobs in
               return
                 (List.find_exn jobs ~f:(fun job -> Job_id.equal job.id generic.job.id)))
             Job.is_terminal)
      in
      let%bind bad_asic =
        rpc
          (Launch
             { submission_key = "unadopted"
             ; discovery_digest = digest
             ; selection =
                 { (selection "pass") with
                   asic_inputs =
                     [ { run =
                           { backend = Backend_id.of_string "asic"
                           ; id = "missing"
                           ; build = None
                           ; label = None
                           }
                       ; attempt = "/missing"
                       ; artifact_id = "missing"
                       ; sha256 = String.make 64 '0'
                       }
                     ]
                 }
             })
      in
      expect_error bad_asic Conflict;
      (* Store paths are server-generated; clients never supply them. *)
      let p = Store.project service.simulation_service root in
      let entry = Store.find p first.id in
      let bytes_path = Files.artifact_path entry.dir artifact.id in
      Files.atomic bytes_path "changed";
      let%bind changed =
        rpc
          (Read_artifact_bytes
             { attempt_id = first.id
             ; artifact_id = artifact.id
             ; sha256 = hash
             ; offset = 0
             ; limit = 1
             })
      in
      expect_error changed Conflict;
      Files.remove bytes_path;
      Core_unix.symlink ~target:"/etc/hosts" ~link_name:bytes_path;
      let%bind symlink_read =
        rpc
          (Read_artifact_bytes
             { attempt_id = first.id
             ; artifact_id = artifact.id
             ; sha256 = hash
             ; offset = 0
             ; limit = 1
             })
      in
      expect_error symlink_read Conflict;
      Files.remove bytes_path;
      let%bind missing =
        rpc
          (Read_artifact_bytes
             { attempt_id = first.id
             ; artifact_id = artifact.id
             ; sha256 = hash
             ; offset = 0
             ; limit = 1
             })
      in
      expect_error missing Not_found;
      let source = Hashtbl.find_exn service.jobs first.job in
      require
        (match source.operation with
         | Service.Simulation_task task ->
           phys_equal task Hardcaml_workbench_backend.Simulation_task.released
         | _ -> false)
        "Terminal job retained its reducer/artifact callbacks";
      for index = 1 to 120 do
        let id = Job_id.of_string ("retention-" ^ Int.to_string index) in
        Hashtbl.set
          service.jobs
          ~key:id
          ~data:
            { source with
              job = { source.job with id }
            ; log_path = Filename.concat tree ("retention-" ^ Int.to_string index ^ ".log")
            ; log_records = Hashtbl.create (module Int)
            }
      done;
      Service.prune_simulation_jobs service root;
      require
        (List.count (Hashtbl.data service.jobs) ~f:(fun entry ->
           String.equal entry.Service.job.kind.namespace "simulation"
           && Job.is_terminal entry.job)
         <= Limits.history_attempts)
        "Completed simulation supervisor jobs grew without bound";
      let%bind () = Service.shutdown service in
      (* Emulate a record surviving abrupt death, not graceful cancellation. *)
      entry.record
      <- { entry.record with
           attempt =
             { entry.record.attempt with
               lifecycle = Running
             ; outcome = Unknown
             ; execution_timing =
                 Execution_timing.make
                   ?started_at:first_timing.started_at
                   ~running:true
                   ()
             ; cases =
                 List.map entry.record.attempt.cases ~f:(fun c ->
                   { c with status = Running })
             }
         };
      Files.atomic (Store.record_path entry) (Store.record_text entry);
      let%bind restarted, new_instance, new_project = create "second" in
      let%bind history =
        Service.simulation
          restarted
          { instance_id = new_instance
          ; project = new_project
          ; operation = Observe first.id
          }
        >>| ok
      in
      let historical = detail history in
      let interrupted_timing = Option.value_exn historical.execution_timing in
      require
        ((not interrupted_timing.running)
         && Option.is_none interrupted_timing.measured_seconds
         && Option.equal
              Timestamp.equal
              interrupted_timing.started_at
              first_timing.started_at)
        "Restart invented an actual end or kept a live estimate";
      require
        (Lifecycle.equal historical.lifecycle Interrupted
         && Outcome.equal historical.outcome Incomplete)
        "Restart replayed or trusted unfinished record";
      require
        (List.is_empty
           (ok (Service.snapshot restarted { instance_id = new_instance })).jobs)
        "History inspection started jobs";
      let%bind retry =
        Service.simulation
          restarted
          { instance_id = new_instance
          ; project = new_project
          ; operation = launch "same" "pass"
          }
        >>| ok
      in
      require
        (String.equal (detail retry).id first.id)
        "Durable reservation lost on restart";
      let%bind () = Service.shutdown restarted in
      (* Pure store pressure: retain active entries and evict oldest terminal entry. *)
      let store = Store.create ~state_dir:(Filename.concat tree "bounded") in
      let bounded_project = Store.project store root in
      for index = 0 to Limits.history_attempts - 1 do
        let id = "sim-bound-" ^ Int.to_string index in
        let dir = Filename.concat bounded_project.dir id in
        Files.mkdir dir;
        let attempt =
          { historical with
            id
          ; created_at = sprintf "%05d" index
          ; lifecycle = (if index = 0 then Running else Finished)
          ; artifacts = []
          ; recent_events = []
          ; execution_timing = None
          }
        in
        let record : Store.Record.t =
          { schema_version = 1; submission_key = id; payload = "Get"; attempt }
        in
        Hashtbl.set bounded_project.entries ~key:id ~data:{ record; dir }
      done;
      Store.prune bounded_project ~reserve:1;
      require
        (Hashtbl.length bounded_project.entries = 99
         && Hashtbl.mem bounded_project.entries "sim-bound-0"
         && not (Hashtbl.mem bounded_project.entries "sim-bound-1"))
        "History eviction removed active or wrong oldest attempt";
      let page = Store.snapshot bounded_project ~configured:false ~limit:2 () in
      require
        (List.length page.attempts = 2 && Option.is_some page.next_before)
        "History pagination not bounded";
      let next =
        Store.snapshot
          bounded_project
          ~configured:false
          ~limit:2
          ~before:(Option.value_exn page.next_before)
          ()
      in
      require
        (not
           (List.exists next.attempts ~f:(fun a ->
              List.exists page.attempts ~f:(fun b ->
                String.equal a.Summary.id b.Summary.id))))
        "History cursor duplicated rows";
      Hashtbl.iter bounded_project.entries ~f:(fun entry ->
        entry.record
        <- { entry.record with
             attempt = { entry.record.attempt with lifecycle = Running }
           });
      require
        (Result.is_error
           (Or_error.try_with (fun () -> Store.prune bounded_project ~reserve:2)))
        "Active history budget overflow accepted";
      require
        (Hashtbl.length bounded_project.entries = 99)
        "Active history was evicted under pressure";
      let corrupt =
        Filename.concat state_dir ("simulation-v1/" ^ Files.digest root ^ "/sim-corrupt")
      in
      Files.mkdir corrupt;
      Files.atomic (Filename.concat corrupt "record.sexp") "broken";
      let reopened = Store.project (Store.create ~state_dir) root in
      require
        (Option.is_some reopened.history_error
         && not (Hashtbl.mem reopened.entries "sim-corrupt"))
        "Corrupt history trusted";
      printf "FS2 backend simulation tests passed\n%!";
      return ())
;;

let () =
  Command_unix.run
    (Command.async
       ~summary:"FS2 supervisor/reducer/store tests"
       (let%map_open.Command fixture = anon ("FIXTURE" %: string) in
        fun () -> tests (Filename_unix.realpath fixture)))
;;
