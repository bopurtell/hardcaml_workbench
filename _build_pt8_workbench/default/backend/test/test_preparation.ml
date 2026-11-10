open! Core
open! Async
open Hardcaml_workbench_protocol
module Service = Hardcaml_workbench_backend.Service
module Receipt = Hardcaml_workbench_backend.Preparation_receipt
module Config = Hardcaml_workbench_project_integration.Preparation_config
module Adapter = Hardcaml_workbench_adapters.Preparation_adapter
module Dune = Hardcaml_workbench_adapters.Dune_adapter

let require condition message = if not condition then failwith message

let ok = function
  | Ok x -> x
  | Error e -> failwith (Sexp.to_string_hum (V1.Error.sexp_of_t e))
;;

let instance_id = V1.Daemon_instance_id.of_string "preparation-test"

let selection : Preparation.Selection.t =
  { flow = "tiny-flow"
  ; profile = "fast"
  ; endpoint = "synthesis"
  ; assignments = [ "SYNTH_STRATEGY=AREA 0"; "SYNTH_HIERARCHICAL=true" ]
  }
;;

let shell ~root script : Dune.Invocation.t =
  { executable = "/bin/sh"
  ; argv = [ "/bin/sh"; "-c"; script ]
  ; cwd = root
  ; environment = Inherit_daemon
  }
;;

let fixture ?(selection = selection) ?(input = "let design = tiny\n") config ~root =
  let configuration =
    `Assoc
      [ "CLOCK_PERIOD", `Float 20.
      ; "DESIGN_NAME", `String "tiny"
      ; "VERILOG_FILES", `List [ `String "dir::tiny.v" ]
      ]
  in
  let config_bytes = Yojson.Safe.pretty_to_string configuration ^ "\n" in
  let rtl = "module tiny(input clk); endmodule\n" in
  let files =
    [ "constraints/top.sdc", "create_clock -name clk -period 20 [get_ports {clk}]\n"
    ; "info.yaml", "project:\n  top_module: tiny\n"
    ; "inputs/design.ml", input
    ; "simulation/tiny.v", rtl
    ; "src/config.json", config_bytes
    ; "src/tiny.v", rtl
    ]
  in
  let manifest_payload =
    `Assoc
      [ "schema_version", `Int 1
      ; "project", `String "tiny"
      ; "top_module", `String "tiny"
      ; "source_revision", `String (String.make 40 'a')
      ; ( "source_inputs"
        , `List
            [ `Assoc
                [ "path", `String "design.ml"
                ; "copy", `String "inputs/design.ml"
                ; "sha256", `String (Receipt.sha256 input)
                ; "git_status", `String " M design.ml"
                ]
            ] )
      ; ( "files"
        , `List
            (List.map files ~f:(fun (path, bytes) ->
               `Assoc [ "path", `String path; "sha256", `String (Receipt.sha256 bytes) ]))
        )
      ; "synthesis_sources", `List [ `String "src/tiny.v" ]
      ; "simulation_sources", `List [ `String "simulation/tiny.v" ]
      ; "resources", `List []
      ; "simulation_resources", `List []
      ; ( "target"
        , `Assoc
            [ "harness", `String "Tiny_tapeout"
            ; "technology", `String "cmos5l"
            ; "tiles", `String "1x1"
            ; "corner", `String "nom"
            ; "external_references", `List []
            ] )
      ; "adapter", `String "LibreLane"
      ; "operation", `String "Synthesis"
      ; "resolved_settings", `List []
      ; "flow_configuration", configuration
      ; "generated_settings", `Assoc [ "VERILOG_FILES", `List [ `String "dir::tiny.v" ] ]
      ; ( "requested_tools"
        , `Assoc [ "librelane", `String "3.1.0.dev3"; "python", `String "3.11" ] )
      ]
  in
  let bundle_identity = Receipt.sha256 (Yojson.Safe.to_string manifest_payload) in
  let manifest =
    match manifest_payload with
    | `Assoc fields -> `Assoc (("identity", `String bundle_identity) :: fields)
    | _ -> assert false
  in
  let manifest_bytes = Yojson.Safe.pretty_to_string manifest ^ "\n" in
  let snapshot =
    `Assoc
      [ "contract", `String "hardcaml-asic.flow-snapshot"
      ; "schema_version", `Int 1
      ; "declaration", `Assoc []
      ; "definition", `Assoc []
      ; "profile", `Assoc []
      ; ( "selected"
        , `Assoc [ "flow", `String selection.flow; "profile", `String selection.profile ]
        )
      ; "endpoint", `String selection.endpoint
      ; ( "stages"
        , `List
            (List.take_while
               [ "synthesis"
               ; "floorplan"
               ; "placement"
               ; "cts"
               ; "routing"
               ; "timing"
               ; "signoff"
               ]
               ~f:(fun stage -> not (String.equal stage selection.endpoint))
             @ [ selection.endpoint ]
             |> List.map ~f:(fun s -> `String s)) )
      ; "request", Receipt.assignments selection
      ; "parameters", `List []
      ]
  in
  let methodology =
    `Assoc
      [ "snapshot", snapshot
      ; "project_assignments", `List []
      ; "effective_parameters", `List []
      ; "translation", `Assoc []
      ; ( "recipe"
        , `Assoc
            [ "schema_version", `Int 4
            ; "stages", Receipt.field snapshot "stages"
            ; "initial_boundary", `Null
            ] )
      ]
  in
  let plan_payload =
    `Assoc
      [ "contract", `String "hardcaml-asic.methodology-plan"
      ; "schema_version", `Int 1
      ; "methodology", methodology
      ; ( "methodology_hash"
        , `String (Receipt.identity "hardcaml-asic.methodology-hash" methodology) )
      ; "project_name", `String "tiny"
      ; "bundle_identity", `String bundle_identity
      ; "bundle_manifest", `String (Yojson.Safe.to_string manifest)
      ; "configuration_bytes", `String config_bytes
      ]
  in
  let plan_identity = Receipt.identity "hardcaml-asic.plan-identity" plan_payload in
  let plan =
    match plan_payload with
    | `Assoc fields -> `Assoc (fields @ [ "plan_identity", `String plan_identity ])
    | _ -> assert false
  in
  let bundles = Filename.concat config.Config.results_root "bundles" in
  Core_unix.mkdir_p config.results_root;
  Core_unix.mkdir_p bundles;
  let output_dir = Filename.concat bundles bundle_identity in
  let objects = Filename.concat bundles ".objects" in
  Core_unix.mkdir_p objects;
  let object_name = bundle_identity ^ ".123.00000001" in
  let object_dir = Filename.concat objects object_name in
  Core_unix.mkdir object_dir;
  let rec mkdir path =
    if Poly.equal (Sys_unix.file_exists path) `No
    then (
      mkdir (Filename.dirname path);
      Core_unix.mkdir path)
  in
  List.iter (("manifest.json", manifest_bytes) :: files) ~f:(fun (path, data) ->
    let path = Filename.concat object_dir path in
    mkdir (Filename.dirname path);
    Out_channel.write_all path ~data);
  Core_unix.symlink ~target:(Filename.concat ".objects" object_name) ~link_name:output_dir;
  let receipt =
    `Assoc
      [ "schema_version", `Int 1
      ; "kind", `String "bundle_emission"
      ; "bundle_identity", `String bundle_identity
      ; "plan_identity", `String plan_identity
      ; "output_dir", `String output_dir
      ; "reused", `Bool false
      ; "plan", plan
      ]
  in
  Out_channel.write_all
    (Filename.concat root "receipt.json")
    ~data:(Yojson.Safe.to_string receipt);
  plan_identity, receipt, output_dir
;;

let terminal (a : Preparation.Attempt.t) =
  match a.outcome with
  | Building | Emitting -> false
  | _ -> true
;;

let call service project operation =
  Service.preparation service { instance_id; project; operation }
;;

let get service project = call service project Get >>| ok
let latest snapshot = Option.value_exn snapshot.Preparation.Snapshot.latest

let wait_for service project predicate =
  let rec loop () =
    let%bind snapshot = get service project in
    if predicate snapshot
    then return snapshot
    else (
      let%bind () = Clock.after (Time_float.Span.of_ms 10.) in
      loop ())
  in
  let%map result = Clock.with_timeout (Time_float.Span.of_sec 5.) (loop ()) in
  match result with
  | `Result result -> result
  | `Timeout -> failwith "Preparation timed out"
;;

let with_service ?(selected = selection) f =
  let directory = Filename_unix.temp_dir "wb004-test-" "" in
  let root = Filename.concat directory "project" in
  Core_unix.mkdir root;
  Out_channel.write_all
    (Filename.concat root "dune-project")
    ~data:"(lang dune 3.22)\n(name preparation_test)\n";
  Out_channel.write_all (Filename.concat root "dune") ~data:"";
  let config : Config.t =
    { schema_version = 1
    ; build_target = "bin/project.exe"
    ; results_root = Filename.concat directory "results"
    ; timeout_seconds = 10
    }
  in
  let write_config () =
    Out_channel.write_all
      (Filename.concat root Config.filename)
      ~data:(Sexp.to_string_hum (Config.sexp_of_t config))
  in
  let plan_identity, receipt, output_dir = fixture ~selection:selected config ~root in
  let build_script = ref "printf build-log; sleep 0.1" in
  let emit_script = ref "printf emission-log >&2; cat receipt.json" in
  let builds = ref 0
  and emissions = ref 0 in
  let build c ~root ~environment =
    incr builds;
    if String.equal !build_script "raise-invocation"
    then failwith "Build invocation failed";
    let invocation = Adapter.build c ~root ~environment in
    require
      (List.equal
         String.equal
         invocation.argv
         [ "dune"
         ; "build"
         ; "-j6"
         ; "--root"
         ; root
         ; "--build-dir"
         ; Filename.concat root "_build"
         ; "--"
         ; c.build_target
         ])
      "Source target/build directory/concurrency changed";
    shell ~root !build_script
  in
  let emit c ~root ~environment ~selection:actual ~expected_plan_identity =
    incr emissions;
    require (Preparation.Selection.equal selected actual) "Selected parameters changed";
    Option.iter expected_plan_identity ~f:(fun id ->
      require (Receipt.valid_identity id) "Invalid expected plan identity");
    let invocation =
      Adapter.emit c ~root ~environment ~selection:actual ~expected_plan_identity
    in
    require
      (String.equal invocation.executable (Config.source_executable c ~root))
      "Pinned executable used";
    require
      (List.equal
         String.equal
         invocation.argv
         ([ Config.source_executable c ~root
          ; "flow"
          ; "emit"
          ; "--flow"
          ; "tiny-flow"
          ; "--profile"
          ; "fast"
          ; "--endpoint"
          ; selected.endpoint
          ; "--source-root"
          ; root
          ; "--json"
          ; "--set"
          ; "SYNTH_STRATEGY=AREA 0"
          ; "--set"
          ; "SYNTH_HIERARCHICAL=true"
          ; "--results-root"
          ; c.results_root
          ]
          @ Option.value_map expected_plan_identity ~default:[] ~f:(fun id ->
            [ "--expected-plan-identity"; id ])))
      "Emission argv changed";
    shell ~root !emit_script
  in
  let%bind created =
    Service.create
      ~instance_id
      ~log_dir:(Filename.concat directory "logs")
      ~kill_after:(Time_float.Span.of_ms 20.)
      ~preparation_build_invocation:build
      ~preparation_emit_invocation:emit
      ~action_invocation:(fun ~root ~environment:_ _ ->
        shell ~root "printf 'generic\\n' >> source-order")
      ()
  in
  let service = Or_error.ok_exn created in
  Monitor.protect
    ~finally:(fun () ->
      let%bind () = Service.shutdown service in
      In_thread.run (fun () -> Service.remove_tree_sync directory))
    (fun () ->
      let%bind opened =
        Service.open_project service { instance_id; root; environment = Inherit_daemon }
      in
      let project = (ok opened).project.id in
      let poison = Filename.concat root "provider" in
      Out_channel.write_all
        poison
        ~data:"#!/bin/sh\ntouch provider-was-invoked\nexit 99\n";
      Core_unix.chmod poison ~perm:0o700;
      Out_channel.write_all
        (Filename.concat root "hardcaml-workbench-asic.sexp")
        ~data:
          (sprintf
             "((schema_version 1)(project_executable %s)(provider_executable \
              %s)(results_root %s)(toolchain %s)(python ())(support_tools ())(pdk_root \
              ())(stage_timeout_seconds ()))"
             poison
             poison
             config.results_root
             root);
      let%bind () =
        f
          ~service
          ~project
          ~root
          ~config
          ~write_config
          ~plan_identity
          ~receipt
          ~output_dir
          ~build_script
          ~emit_script
          ~builds
          ~emissions
      in
      require
        (Poly.equal
           (Sys_unix.file_exists (Filename.concat root "provider-was-invoked"))
           `No)
        "Provider was invoked";
      return ())
;;

let run_fixture () =
  with_service
    (fun
        ~service
        ~project
        ~root
        ~config
        ~write_config
        ~plan_identity
        ~receipt
        ~output_dir
        ~build_script
        ~emit_script
        ~builds
        ~emissions
      ->
       let prepare key =
         call
           service
           project
           (Prepare
              { submission_key = key
              ; selection
              ; expected_plan_identity = Some plan_identity
              })
         >>| ok
       in
       let%bind initial = get service project in
       require
         (Preparation.Availability.equal
            initial.availability
            (Unavailable Not_configured))
         "ASIC presence inferred preparation capability";
       Out_channel.write_all (Filename.concat root Config.filename) ~data:"broken";
       let%bind invalid = get service project in
       require
         (match invalid.availability with
          | Unavailable (Invalid_configuration _) -> true
          | _ -> false)
         "Invalid config not typed";
       write_config ();
       let%bind first, duplicate = Deferred.both (prepare "one") (prepare "one") in
       require
         (String.equal (latest first).id (latest duplicate).id)
         "Duplicate submissions allocated twice";
       let%bind coalesced = prepare "also-one" in
       require
         (String.equal (latest first).id (latest coalesced).id)
         "Active identical selection not coalesced";
       let%bind conflict =
         call
           service
           project
           (Prepare
              { submission_key = "one"
              ; selection = { selection with profile = "other" }
              ; expected_plan_identity = Some plan_identity
              })
       in
       require
         (match conflict with
          | Error e -> V1.Error.Kind.equal e.kind Conflict
          | _ -> false)
         "Conflicting duplicate accepted";
       let%bind completed = wait_for service project (fun s -> terminal (latest s)) in
       let a = latest completed in
       require
         (Preparation.Outcome.equal a.outcome Completed)
         (Option.value a.diagnostic ~default:"No completed preparation");
       require (!builds = 1 && !emissions = 1) "Duplicate work executed";
       let build = Option.value_exn a.build_job
       and emission = Option.value_exn a.emission_job in
       require
         ((not (Job_id.equal build.id emission.id))
          && Job.State.equal build.state Complete
          && Job.State.equal emission.state Complete)
         "Stage statuses conflated";
       let%bind build_log =
         Service.read_log
           service
           { instance_id
           ; job = build.id
           ; offset = 0
           ; max_records = 100
           ; max_bytes = 65536
           }
       in
       require
         (String.is_substring
            (String.concat
               (List.map (ok build_log).records ~f:(fun r -> r.V1.Read_log.Record.data)))
            ~substring:"build-log")
         "Build log not retained";
       let bundle = Option.value_exn a.bundle in
       require
         (List.length bundle.artifacts = 7
          && String.equal bundle.plan_identity plan_identity)
         "Bundle handles missing";
       let%bind artifact =
         Service.read_artifact
           service
           { instance_id
           ; artifact = List.hd_exn bundle.artifacts
           ; offset = 0
           ; max_bytes = 65536
           }
       in
       require
         (String.is_substring (ok artifact).data ~substring:"identity")
         "Imported manifest inaccessible";
       let%bind _ = prepare "one" in
       require (!builds = 1) "Terminal submission replay executed again";
       build_script := "printf failed-build >&2; exit 7";
       let%bind _ = prepare "build-failure" in
       let%bind failed = wait_for service project (fun s -> terminal (latest s)) in
       require
         (Preparation.Outcome.equal (latest failed).outcome Build_failed
          && Option.is_none (latest failed).emission_job
          && !emissions = 1)
         "Failed build emitted bundle";
       let%bind replay = prepare "one" in
       require
         (Option.equal String.equal replay.requested_attempt (Some a.id)
          && Preparation.Outcome.equal (latest replay).outcome Build_failed)
         "Replayed submission lost its exact attempt or reordered history";
       build_script := "exit 0";
       emit_script := "printf failed-emission >&2; exit 8";
       let%bind _ = prepare "emit-failure" in
       let%bind failed = wait_for service project (fun s -> terminal (latest s)) in
       require
         (Preparation.Outcome.equal (latest failed).outcome Emission_failed
          && Option.is_none (latest failed).bundle)
         "Emission failure accepted";
       emit_script := "printf '{bad-json'";
       let%bind _ = prepare "malformed" in
       let%bind malformed = wait_for service project (fun s -> terminal (latest s)) in
       require
         (Preparation.Outcome.equal (latest malformed).outcome Emission_failed
          && Job.State.equal
               (Option.value_exn (latest malformed).emission_job).state
               Failed)
         "Malformed receipt completed";
       (* A valid receipt on a nonzero exit is still an emission failure. *)
       emit_script := "cat receipt.json; exit 9";
       let%bind _ = prepare "receipt-nonzero" in
       let%bind failed = wait_for service project (fun s -> terminal (latest s)) in
       require
         (Option.is_none (latest failed).bundle
          && List.is_empty (Option.value_exn (latest failed).emission_job).artifacts)
         "Failed emission imported evidence";
       build_script := "sleep 10";
       let%bind started = prepare "cancel-build" in
       let count = !emissions in
       let%bind cancelled = call service project (Cancel (latest started).id) >>| ok in
       require
         (Preparation.Outcome.equal (latest cancelled).outcome Cancelled
          && !emissions = count)
         "Cancelled build emitted";
       build_script := "exit 0";
       emit_script := "sleep 10";
       let%bind _ = prepare "cancel-emit" in
       let%bind started =
         wait_for service project (fun s -> Option.is_some (latest s).emission_job)
       in
       let%bind cancelled = call service project (Cancel (latest started).id) >>| ok in
       require
         (Preparation.Outcome.equal (latest cancelled).outcome Cancelled
          && Option.is_none (latest cancelled).bundle)
         "Cancelled emission completed";
       require
         (List.length cancelled.history = 7
          && Preparation.Outcome.equal (latest cancelled).outcome Cancelled)
         "History did not retain newest failures/cancellation";
       require cancelled.session_only "Session evidence advertised as durable";
       (* Keep one root job running while configuration changes. New requests must not
          coalesce into the old configuration, and queued stale work must not launch. *)
       build_script := "touch blocker-started; sleep 10";
       let%bind blocker = prepare "config-blocker" in
       let blocker_id = (latest blocker).id in
       let%bind _ =
         wait_for service project (fun _ ->
           Poly.equal (Sys_unix.file_exists (Filename.concat root "blocker-started")) `Yes)
       in
       let changed = { config with timeout_seconds = 11 } in
       Out_channel.write_all
         (Filename.concat root Config.filename)
         ~data:(Sexp.to_string_hum (Config.sexp_of_t changed));
       build_script := "touch stale-build-launched";
       let%bind queued = prepare "config-queued" in
       let queued_id = (latest queued).id in
       require
         (not (String.equal blocker_id queued_id))
         "Changed configuration coalesced into old work";
       require
         (Option.is_none (latest queued).build_job)
         "Source-lease waiter enqueued a build ahead of the preceding emission";
       Out_channel.write_all
         (Filename.concat root Config.filename)
         ~data:
           (Sexp.to_string_hum (Config.sexp_of_t { config with timeout_seconds = 12 }));
       build_script := "touch cancelled-build-launched";
       let%bind queued_cancel = prepare "queued-cancel" in
       let%bind cancelled =
         call service project (Cancel (latest queued_cancel).id) >>| ok
       in
       require
         (Preparation.Outcome.equal (latest cancelled).outcome Cancelled)
         "Queued cancellation did not settle";
       write_config ();
       let%bind _ = call service project (Cancel blocker_id) >>| ok in
       let find_queued s =
         List.find_exn s.Preparation.Snapshot.history ~f:(fun a ->
           String.equal a.Preparation.Attempt.id queued_id)
       in
       let%bind failed = wait_for service project (fun s -> terminal (find_queued s)) in
       require
         (Preparation.Outcome.equal (find_queued failed).outcome Build_failed
          && Option.is_none (find_queued failed).emission_job
          && Poly.equal
               (Sys_unix.file_exists (Filename.concat root "stale-build-launched"))
               `No
          && Poly.equal
               (Sys_unix.file_exists (Filename.concat root "cancelled-build-launched"))
               `No)
         "Stale queued build launched after configuration drift";
       (* Drift during the build must also be checked before starting emission. *)
       build_script
       := "touch drift-build-started; while test ! -e release-drift-build; do sleep \
           0.01; done";
       emit_script := "touch stale-emission-launched; cat receipt.json";
       let%bind _ = prepare "config-emission" in
       let%bind _ =
         wait_for service project (fun _ ->
           Poly.equal
             (Sys_unix.file_exists (Filename.concat root "drift-build-started"))
             `Yes)
       in
       Out_channel.write_all
         (Filename.concat root Config.filename)
         ~data:(Sexp.to_string_hum (Config.sexp_of_t changed));
       Out_channel.write_all (Filename.concat root "release-drift-build") ~data:"";
       let%bind failed = wait_for service project (fun s -> terminal (latest s)) in
       require
         (Preparation.Outcome.equal (latest failed).outcome Emission_failed
          && Option.is_none (latest failed).bundle
          && Poly.equal
               (Sys_unix.file_exists (Filename.concat root "stale-emission-launched"))
               `No)
         "Stale emission launched after configuration drift during build";
       write_config ();
       build_script := "raise-invocation";
       let%bind failed, replay =
         Deferred.both (prepare "invocation-error") (prepare "invocation-error")
       in
       let%bind settled = wait_for service project (fun s -> terminal (latest s)) in
       require
         (Preparation.Outcome.equal (latest settled).outcome Build_failed
          && Option.equal String.equal failed.requested_attempt replay.requested_attempt)
         "Invocation failure left an active attempt or blocked duplicate replay";
       Out_channel.write_all
         (Filename.concat root Config.filename)
         ~data:(Sexp.to_string_hum (Config.sexp_of_t { config with timeout_seconds = 1 }));
       build_script := "exit 0";
       emit_script
       := "receipt=$(cat receipt.json); trap 'printf \"%s\" \"$receipt\"; exit 0' TERM; \
           while :; do sleep 0.01; done";
       let%bind _ = prepare "timeout-zero-exit" in
       let%bind failed = wait_for service project (fun s -> terminal (latest s)) in
       let emission = Option.value_exn (latest failed).emission_job in
       require
         (Preparation.Outcome.equal (latest failed).outcome Emission_failed
          && Option.is_none (latest failed).bundle
          && List.is_empty emission.artifacts)
         "Timed out emitter published artifacts after handling TERM";
       require
         (Option.equal Job.Exit_status.equal emission.exit_status (Some (Exited 0)))
         "Timeout fixture did not exercise zero-exit receipt handling";
       write_config ();
       let validate ?(selected = selection) value =
         Receipt.validate
           config
           ~selection:selected
           ~expected_plan_identity:(Some plan_identity)
           (Yojson.Safe.to_string value)
       in
       require
         (Result.is_ok (validate receipt))
         "Provider-shaped private-object publication rejected";
       let set value key data =
         match value with
         | `Assoc fields ->
           `Assoc
             (List.map fields ~f:(fun (k, v) -> k, if String.equal k key then data else v))
         | _ -> assert false
       in
       require
         (Result.is_ok (validate (set receipt "reused" (`Bool true))))
         "Reused publication rejected";
       require
         (Result.is_error
            (validate ~selected:{ selection with profile = "other" } receipt))
         "Wrong selected profile accepted";
       require
         (Result.is_error
            (validate ~selected:{ selection with assignments = [] } receipt))
         "Wrong assignments accepted";
       require
         (Result.is_error
            (Receipt.validate
               config
               ~selection
               ~expected_plan_identity:(Some (String.make 64 '0'))
               (Yojson.Safe.to_string receipt)))
         "Wrong expected plan identity accepted";
       let duplicate_fields =
         match receipt with
         | `Assoc fields -> `Assoc (("kind", `String "bundle_emission") :: fields)
         | _ -> assert false
       in
       require
         (Result.is_error (validate duplicate_fields))
         "Duplicate JSON result fields accepted";
       require
         (Result.is_error
            (Config.parse_string
               "((schema_version 1)(build_target ../pinned.exe)(results_root \
                /tmp/results)(timeout_seconds 10))"))
         "Escaping build target accepted";
       require
         (Result.is_error
            (Config.parse_string
               "((schema_version 1)(build_target bin/project.exe)(project_executable \
                /stale/pinned)(results_root /tmp/results)(timeout_seconds 10))"))
         "Pinned executable override accepted";
       let target = Core_unix.readlink output_dir in
       let object_dir = Filename_unix.realpath output_dir in
       (* Exact existing plain directories are also a supported Bundle.publish layout. *)
       Core_unix.unlink output_dir;
       Core_unix.rename ~src:object_dir ~dst:output_dir;
       require
         (Result.is_ok (validate receipt))
         "Plain identity-directory publication rejected";
       Core_unix.rename ~src:output_dir ~dst:object_dir;
       Core_unix.symlink ~target ~link_name:output_dir;
       let replace_link target =
         Core_unix.unlink output_dir;
         Core_unix.symlink ~target ~link_name:output_dir
       in
       let escaped = Filename.concat root "escaped-bundle" in
       Core_unix.rename ~src:object_dir ~dst:escaped;
       replace_link escaped;
       require (Result.is_error (validate receipt)) "External publication link accepted";
       replace_link target;
       Core_unix.symlink ~target:escaped ~link_name:object_dir;
       require
         (Result.is_error (validate receipt))
         "Private object symlink escape accepted";
       Core_unix.unlink object_dir;
       Core_unix.rename ~src:escaped ~dst:object_dir;
       replace_link object_dir;
       require
         (Result.is_error (validate receipt))
         "Absolute link outside supported publication layout accepted";
       replace_link ".objects/wrong-identity.123.00000001";
       require
         (Result.is_error (validate receipt))
         "Wrong identity private object accepted";
       replace_link target;
       let objects = Filename.dirname object_dir in
       let escaped_objects = Filename.concat root "escaped-objects" in
       Core_unix.rename ~src:objects ~dst:escaped_objects;
       Core_unix.symlink ~target:escaped_objects ~link_name:objects;
       require
         (Result.is_error (validate receipt))
         "Symlinked .objects parent escape accepted";
       Core_unix.unlink objects;
       Core_unix.rename ~src:escaped_objects ~dst:objects;
       let src = Filename.concat object_dir "src" in
       let escaped_src = Filename.concat root "escaped-src" in
       Core_unix.rename ~src ~dst:escaped_src;
       Core_unix.symlink ~target:escaped_src ~link_name:src;
       require (Result.is_error (validate receipt)) "Symlinked member directory accepted";
       Core_unix.unlink src;
       Core_unix.rename ~src:escaped_src ~dst:src;
       let changed_plan =
         set (Receipt.field receipt "plan") "configuration_bytes" (`String "wrong bytes")
       in
       let changed_identity =
         Receipt.identity
           "hardcaml-asic.plan-identity"
           (Receipt.without changed_plan "plan_identity")
       in
       let changed_plan = set changed_plan "plan_identity" (`String changed_identity) in
       let changed_receipt =
         set (set receipt "plan" changed_plan) "plan_identity" (`String changed_identity)
       in
       let mismatch =
         Receipt.validate
           config
           ~selection
           ~expected_plan_identity:(Some changed_identity)
           (Yojson.Safe.to_string changed_receipt)
       in
       require
         (match mismatch with
          | Error error ->
            String.is_substring
              (Error.to_string_hum error)
              ~substring:"Configuration bytes mismatch"
          | Ok _ -> false)
         "Plan/configuration mismatch accepted or masked";
       Out_channel.write_all
         (Filename.concat output_dir "src/config.json")
         ~data:"tampered";
       require (Result.is_error (validate receipt)) "Tampered manifest file accepted";
       let wrapped =
         Adapter.emit
           config
           ~root
           ~environment:(Opam_switch "test-switch")
           ~selection
           ~expected_plan_identity:None
       in
       require
         (String.equal wrapped.executable "opam"
          && List.mem wrapped.argv "--switch=test-switch" ~equal:String.equal)
         "Selected environment lost";
       return ())
;;

let run_staging_fixture () =
  with_service
    (fun
        ~service
        ~project
        ~root
        ~config
        ~write_config
        ~plan_identity
        ~receipt:_
        ~output_dir:_
        ~build_script:_
        ~emit_script:_
        ~builds
        ~emissions
      ->
       let stage ?(selected = selection) () =
         call
           service
           project
           (Stage { selection = selected; expected_plan_identity = Some plan_identity })
       in
       let launch stage_id submission_key =
         call service project (Launch_staged { stage_id; submission_key })
       in
       let conflict result message =
         require
           (match result with
            | Error (error : V1.Error.t) -> V1.Error.Kind.equal error.kind Conflict
            | Ok _ -> false)
           message
       in
       let%bind absent = stage () in
       require (Result.is_error absent) "Unconfigured staging accepted";
       write_config ();
       let%bind invalid = stage ~selected:{ selection with flow = "" } () in
       require (Result.is_error invalid) "Invalid staged selection accepted";
       let%bind first = stage () >>| ok in
       let first_stage = Option.value_exn first.staged in
       require
         (Preparation.Selection.equal first_stage.selection selection
          && Option.equal
               String.equal
               first_stage.expected_plan_identity
               (Some plan_identity)
          && String.equal first_stage.source_root root
          && String.equal first_stage.build_target config.build_target
          && String.equal
               first_stage.source_executable
               (Config.source_executable config ~root)
          && String.equal first_stage.results_root config.results_root
          && first_stage.timeout_seconds = config.timeout_seconds
          && V1.Environment_selection.equal first_stage.environment Inherit_daemon
          && Option.is_none first.latest
          && List.is_empty first.history)
         "Stage did not capture input scope independently of attempts";
       (* Older sexp snapshots omit the additive field. *)
       let legacy =
         match Preparation.Snapshot.sexp_of_t first with
         | Sexp.List fields ->
           Sexp.List
             (List.filter fields ~f:(function
               | Sexp.List (Sexp.Atom "staged" :: _) -> false
               | _ -> true))
         | _ -> assert false
       in
       require
         (Option.is_none (Preparation.Snapshot.t_of_sexp legacy).staged)
         "Legacy snapshot sexp requires staged field";
       let%bind cancelled = call service project (Cancel first_stage.id) in
       require (Result.is_error cancelled) "Cancel treated staged input as an attempt";
       let%bind after_cancel = get service project in
       require
         (Option.equal Preparation.Staged.equal after_cancel.staged first.staged)
         "Cancel consumed staged input";
       let%bind second = stage ~selected:{ selection with profile = "other" } () >>| ok in
       let second_stage = Option.value_exn second.staged in
       let%bind stale = launch first_stage.id "old-token" in
       conflict stale "Superseded selection token launched";
       let changed = { config with timeout_seconds = config.timeout_seconds + 1 } in
       Out_channel.write_all
         (Filename.concat root Config.filename)
         ~data:(Sexp.to_string_hum (Config.sexp_of_t changed));
       let%bind drift = launch second_stage.id "drift-token" in
       conflict drift "Configuration drift silently launched";
       Out_channel.write_all (Filename.concat root Config.filename) ~data:"broken";
       let%bind invalid_config = launch second_stage.id "invalid-config" in
       conflict invalid_config "Invalid current configuration silently launched";
       write_config ();
       let%bind staged = stage () >>| ok in
       let staged = Option.value_exn staged.staged in
       let jobs = (ok (Service.snapshot service { instance_id })).jobs in
       require
         (!builds = 0
          && !emissions = 0
          && List.is_empty jobs
          && Hashtbl.is_empty service.jobs
          && Hashtbl.is_empty service.artifacts
          && List.is_empty (Sys_unix.ls_dir service.log_dir))
         "Stage/cancel/rejected launches created jobs, tools or logs";
       let%bind accepted, duplicate =
         Deferred.both (launch staged.id "launch") (launch staged.id "launch")
       in
       let accepted = ok accepted
       and duplicate = ok duplicate in
       require
         (Option.equal
            String.equal
            accepted.requested_attempt
            duplicate.requested_attempt)
         "Concurrent staged submission duplicated attempt";
       let%bind other_key = launch staged.id "another-launch" in
       conflict other_key "Same stage launched again under a new key";
       let%bind completed = wait_for service project (fun s -> terminal (latest s)) in
       require
         (Preparation.Outcome.equal (latest completed).outcome Completed
          && !builds = 1
          && !emissions = 1
          && Preparation.Selection.equal (latest completed).selection staged.selection
          && List.length completed.history = 1)
         "Staged launch did not run exact captured preparation once";
       let%bind _ = stage () >>| ok in
       let%bind stale = launch staged.id "after-supersession" in
       conflict stale "Launched superseded stage with new key";
       Out_channel.write_all (Filename.concat root Config.filename) ~data:"broken";
       let%bind replay = launch staged.id "launch" >>| ok in
       require
         (Option.equal String.equal replay.requested_attempt accepted.requested_attempt
          && !builds = 1
          && !emissions = 1)
         "Accepted staged replay after supersession/config drift launched again";
       let%bind crossed =
         call
           service
           project
           (Prepare
              { submission_key = "launch"
              ; selection
              ; expected_plan_identity = Some plan_identity
              })
       in
       conflict crossed "Immediate API reused staged submission key";
       return ())
;;

let run_fresh_fixture endpoint =
  let selected = { selection with endpoint } in
  with_service
    ~selected
    (fun
        ~service
        ~project
        ~root
        ~config
        ~write_config
        ~plan_identity
        ~receipt
        ~output_dir
        ~build_script
        ~emit_script
        ~builds
        ~emissions
      ->
       write_config ();
       let provider = Filename.concat root "fresh-provider.py" in
       Out_channel.write_all provider ~data:(In_channel.read_all "fresh_provider.py");
       Core_unix.chmod provider ~perm:0o700;
       let module Asic_config = Hardcaml_workbench_project_integration.Asic_config in
       let asic_config : Asic_config.t =
         { schema_version = 1
         ; project_executable = Filename.concat root "provider"
         ; provider_executable = provider
         ; results_root = Filename.concat root "physical-results"
         ; toolchain = root
         ; python = Some "/literal/python"
         ; support_tools = Some "/literal/tt"
         ; pdk_root = Some "/literal/pdk"
         ; stage_timeout_seconds = Some 11
         }
       in
       Out_channel.write_all
         (Filename.concat root Asic_config.filename)
         ~data:(Sexp.to_string (Asic_config.sexp_of_t asic_config));
       let asic operation =
         Service.asic service { instance_id; project; operation } >>| ok
       in
       let find snapshot key =
         List.find_exn snapshot.Asic.Snapshot.workflows ~f:(fun w ->
           String.equal w.Asic.Fresh.Workflow.key key)
       in
       let wait key predicate =
         let rec loop remaining =
           let%bind snapshot = asic Get in
           let w = find snapshot key in
           if predicate w
           then return w
           else if remaining = 0
           then raise_s [%message "Fresh workflow timed out" (w : Asic.Fresh.Workflow.t)]
           else (
             let%bind () = Clock.after (Time_float.Span.of_ms 20.) in
             loop (remaining - 1))
         in
         loop 500
       in
       let settled key =
         wait key (fun w ->
           match w.phase with
           | Completed | Failed | Cancelled | Interrupted -> true
           | _ -> false)
       in
       let stage ?(expected_plan_identity = None) ~elaboration_only () =
         let%map snapshot =
           asic
             (Stage_fresh
                { selection = selected; elaboration_only; expected_plan_identity })
         in
         Option.value_exn snapshot.fresh_intent
       in
       let launch key intent =
         asic (Launch_fresh { key; intent_id = intent.Asic.Fresh.Intent.id })
       in
       let physical_calls () =
         let path = Filename.concat root "physical-calls" in
         if Poly.equal (Sys_unix.file_exists path) `No
         then []
         else In_channel.read_lines path |> List.map ~f:Yojson.Safe.from_string
       in
       let stages () =
         List.filter (physical_calls ()) ~f:(function
           | `List (`String "stages" :: _) -> true
           | _ -> false)
       in
       let assert_completed w =
         if not (Asic.Fresh.Phase.equal w.Asic.Fresh.Workflow.phase Completed)
         then
           raise_s
             [%message "Expected completed fresh workflow" (w : Asic.Fresh.Workflow.t)]
       in
       (* Input staging does no build/emission/provider work. Elaboration-only uses the
          same durable workflow but never even probes a physical provider. *)
       let%bind elab = stage ~elaboration_only:true () in
       require
         (!builds = 0 && !emissions = 0 && List.is_empty (physical_calls ()))
         "Staging performed work";
       let%bind _ = launch "elab" elab in
       let%bind elaborated = settled "elab" in
       assert_completed elaborated;
       require
         (List.is_empty (physical_calls ())
          && Option.is_none elaborated.run
          && String.equal elaborated.elaboration_status "completed")
         "Elaboration-only executed physical work";
       let%bind _ = launch "elab" elab in
       require (!builds = 1 && !emissions = 1) "Submission replay reran elaboration";
       let%bind superseded = stage ~elaboration_only:true () in
       let%bind current = stage ~elaboration_only:true () in
       let%bind stale =
         Service.asic
           service
           { instance_id
           ; project
           ; operation = Launch_fresh { key = "superseded"; intent_id = superseded.id }
           }
       in
       require (Result.is_error stale && !builds = 1) "Superseded input intent launched";
       let%bind invalid =
         Service.asic
           service
           { instance_id
           ; project
           ; operation =
               Stage_fresh
                 { selection =
                     { selected with
                       assignments = [ "DUPLICATE=true"; "DUPLICATE=false" ]
                     }
                 ; elaboration_only = true
                 ; expected_plan_identity = None
                 }
           }
       in
       let%bind invalidated = asic Get in
       require
         (Result.is_error invalid
          && Option.is_none invalidated.fresh_intent
          && not (String.equal current.id superseded.id))
         "Failed staging retained a launchable old intent";
       let%bind physical = stage ~elaboration_only:false () in
       let%bind _ = launch "physical" physical in
       let%bind completed = settled "physical" in
       assert_completed completed;
       let prepared = Option.value_exn completed.prepared in
       require
         (String.equal prepared.bundle_directory output_dir
          && String.equal prepared.plan_identity plan_identity
          && String.equal
               prepared.bundle_identity
               (Receipt.text (Receipt.field receipt "bundle_identity"))
          && String.equal
               (Receipt.sha256 (In_channel.read_all prepared.methodology_plan_path))
               prepared.methodology_plan_digest
          && Option.is_some completed.reference
          && Option.is_some completed.run)
         "Exact bundle/plan/allocation lineage lost";
       let argv = List.hd_exn (stages ()) |> Receipt.array |> List.map ~f:Receipt.text in
       let option name =
         let index, _ = List.findi_exn argv ~f:(fun _ arg -> String.equal arg name) in
         List.nth_exn argv (index + 1)
       in
       require
         (String.equal (List.nth_exn argv 1) output_dir
          && String.equal (option "--methodology-plan") prepared.methodology_plan_path
          && String.equal (option "--expected-plan-identity") plan_identity
          && String.equal (option "--python") "/literal/python"
          && String.equal (option "--support-tools") "/literal/tt"
          && String.equal (option "--pdk-root") "/literal/pdk"
          && String.equal (option "--timeout") "11")
         "Provider exact-input/tool argv mismatch";
       require
         (!builds = 2 && !emissions = 2 && List.length (stages ()) = 1)
         "Fresh physical launch borrowed preparation";
       let%bind _ = launch "physical" physical in
       require
         (!builds = 2 && !emissions = 2 && List.length (stages ()) = 1)
         "Physical submission replay reran producer";
       let%bind conflict =
         Service.asic
           service
           { instance_id
           ; project
           ; operation = Launch_fresh { key = "physical"; intent_id = elab.id }
           }
       in
       require (Result.is_error conflict) "Conflicting workflow replay accepted";
       let%bind consumed =
         Service.asic
           service
           { instance_id
           ; project
           ; operation = Launch_fresh { key = "different-key"; intent_id = physical.id }
           }
       in
       require (Result.is_error consumed) "Consumed input intent launched twice";
       let reused_receipt =
         match receipt with
         | `Assoc fields ->
           `Assoc
             (("reused", `Bool true)
              :: List.Assoc.remove fields "reused" ~equal:String.equal)
         | _ -> assert false
       in
       Out_channel.write_all
         (Filename.concat root "receipt.json")
         ~data:(Yojson.Safe.to_string reused_receipt);
       let%bind next = stage ~elaboration_only:false () in
       let%bind _ = launch "physical-repeat" next in
       let%bind repeated = settled "physical-repeat" in
       assert_completed repeated;
       let%bind preparation = get service project in
       require
         (Option.value_exn (latest preparation).bundle).reused
         "Identical-publication reuse receipt was lost";
       require
         (!builds = 3
          && !emissions = 3
          && List.length (stages ()) = 2
          && (not (String.equal completed.id repeated.id))
          && not (Option.equal Run_ref.equal completed.run repeated.run))
         "Distinct fresh launch reused workflow";
       (* Build failure, failed emission and explicit mismatch gate physical work. *)
       build_script := "exit 9";
       let%bind input = stage ~elaboration_only:false () in
       let%bind _ = launch "build-failure" input in
       let%bind failed = settled "build-failure" in
       require
         (String.equal failed.elaboration_status "build_failed"
          && Option.is_none failed.run
          && !emissions = 3
          && List.length (stages ()) = 2)
         "Build failure admitted emission/physical";
       build_script := "exit 0";
       emit_script := "cat receipt.json; exit 7";
       let%bind input = stage ~elaboration_only:false () in
       let%bind _ = launch "emit-failure" input in
       let%bind failed = settled "emit-failure" in
       require
         (String.equal failed.elaboration_status "emission_failed"
          && Option.is_none failed.prepared
          && List.length (stages ()) = 2)
         "Failed emission admitted physical";
       emit_script := "cat receipt.json";
       let%bind input =
         stage
           ~elaboration_only:false
           ~expected_plan_identity:(Some (String.make 64 '0'))
           ()
       in
       let%bind _ = launch "identity-mismatch" input in
       let%bind mismatch = settled "identity-mismatch" in
       require
         (Asic.Fresh.Phase.equal mismatch.phase Failed
          && Option.is_none mismatch.prepared
          && List.length (stages ()) = 2)
         "Expected identity guard failed";
       (* Cancel actual supervised build and emission processes. *)
       build_script := "touch fresh-build-started; sleep 30";
       let%bind input = stage ~elaboration_only:false () in
       let%bind _ = launch "cancel-build" input in
       let%bind active =
         wait "cancel-build" (fun w ->
           Option.exists w.build_job ~f:(fun j -> Job.State.equal j.state Running))
       in
       let%bind _ = asic (Cancel_workflow active.id) in
       let%bind cancelled = settled "cancel-build" in
       require
         (Asic.Fresh.Phase.equal cancelled.phase Cancelled
          && Option.is_none cancelled.emission_job
          && List.length (stages ()) = 2)
         "Cancelled build advanced";
       build_script := "exit 0";
       emit_script := "sleep 30; cat receipt.json";
       let%bind input = stage ~elaboration_only:false () in
       let%bind _ = launch "cancel-emission" input in
       let%bind active =
         wait "cancel-emission" (fun w ->
           Option.exists w.emission_job ~f:(fun j -> Job.State.equal j.state Running))
       in
       let%bind _ = asic (Cancel_workflow active.id) in
       let%bind cancelled = settled "cancel-emission" in
       require
         (Asic.Fresh.Phase.equal cancelled.phase Cancelled
          && Option.is_none cancelled.prepared
          && List.length (stages ()) = 2)
         "Cancelled emission advanced";
       (* Source lease covers both steps, across standalone and workflow APIs. *)
       build_script
       := "printf 'build-start\\n' >> source-order; sleep 0.1; printf 'build-end\\n' >> \
           source-order";
       emit_script
       := "printf 'emit-start\\n' >> source-order; sleep 0.1; cat receipt.json; printf \
           'emit-end\\n' >> source-order";
       let%bind standalone =
         call
           service
           project
           (Prepare
              { submission_key = "standalone-lease"
              ; selection = selected
              ; expected_plan_identity = None
              })
         >>| ok
       in
       let%bind _ =
         wait_for service project (fun s ->
           Option.exists (latest s).build_job ~f:(fun job ->
             Job.State.equal job.state Running))
       in
       let%bind generic =
         Service.submit_job
           service
           { instance_id
           ; project
           ; action = Build
           ; submission_key = "generic-during-source-lease"
           }
         >>| ok
       in
       require
         (Job.State.equal generic.job.state Queued)
         "Generic source build bypassed preparation lease";
       let%bind input = stage ~elaboration_only:true () in
       let%bind _ = launch "workflow-lease" input in
       let%bind lease = settled "workflow-lease" in
       assert_completed lease;
       let%bind _ =
         wait_for service project (fun s ->
           List.exists s.history ~f:(fun a ->
             String.equal a.id (Option.value_exn standalone.requested_attempt)
             && terminal a))
       in
       require
         (List.equal
            String.equal
            (In_channel.read_lines (Filename.concat root "source-order"))
            [ "build-start"
            ; "build-end"
            ; "emit-start"
            ; "emit-end"
            ; "generic"
            ; "build-start"
            ; "build-end"
            ; "emit-start"
            ; "emit-end"
            ])
         "Source build-through-emission lease interleaved producers";
       (* One active physical owner keeps the second physical task queued. Cancellation of
          the queued workflow must never create its provider process. *)
       build_script := "exit 0";
       emit_script := "cat receipt.json";
       Out_channel.write_all (Filename.concat root "hold-physical") ~data:"";
       let%bind input = stage ~elaboration_only:false () in
       let%bind _ = launch "physical-owner" input in
       let%bind owner = wait "physical-owner" (fun w -> Option.is_some w.run) in
       let%bind input = stage ~elaboration_only:false () in
       let%bind _ = launch "physical-queued" input in
       let%bind queued =
         wait "physical-queued" (fun w -> Asic.Fresh.Phase.equal w.phase Physical)
       in
       let%bind _ = asic (Cancel_workflow queued.id) in
       let%bind _ = asic (Cancel_workflow owner.id) in
       let%bind queued = settled "physical-queued" in
       let%bind owner = settled "physical-owner" in
       require
         (Asic.Fresh.Phase.equal queued.phase Cancelled
          && Option.is_none queued.run
          && Asic.Fresh.Phase.equal owner.phase Cancelled
          && List.length (stages ()) = 3
          && Poly.equal
               (Sys_unix.file_exists (Filename.concat root "physical-stopped"))
               `Yes)
         "Queued cancellation launched a provider or owned physical cancellation failed";
       Core_unix.unlink (Filename.concat root "hold-physical");
       (* Missing configuration and drift fail before a workflow producer exists. *)
       let%bind input = stage ~elaboration_only:false () in
       Out_channel.write_all
         (Filename.concat root Config.filename)
         ~data:(Sexp.to_string (Config.sexp_of_t { config with timeout_seconds = 12 }));
       let before = !builds in
       let%bind drift =
         Service.asic
           service
           { instance_id
           ; project
           ; operation = Launch_fresh { key = "scope-drift"; intent_id = input.id }
           }
       in
       require
         (Result.is_error drift && !builds = before)
         "Scope drift started source work";
       write_config ();
       let%bind input = stage ~elaboration_only:false () in
       let provider_bytes = In_channel.read_all provider in
       Out_channel.write_all
         provider
         ~data:(provider_bytes ^ "\n# changed provider generation\n");
       let%bind provider_drift =
         Service.asic
           service
           { instance_id
           ; project
           ; operation = Launch_fresh { key = "provider-drift"; intent_id = input.id }
           }
       in
       require
         (Result.is_error provider_drift && !builds = before)
         "Provider generation drift started source work";
       Out_channel.write_all provider ~data:provider_bytes;
       (* New source bytes establish a new emitted identity without inheriting a pinned
          preview expectation. The earlier workflow keeps its own identity. *)
       let changed_plan, changed_receipt, changed_directory =
         fixture
           ~selection:selected
           ~input:"let design = changed_source_v2\n"
           config
           ~root
       in
       let%bind changed_input = stage ~elaboration_only:false () in
       let%bind _ = launch "changed-source" changed_input in
       let%bind changed = settled "changed-source" in
       assert_completed changed;
       let changed_prepared = Option.value_exn changed.prepared in
       require
         ((not (String.equal changed_plan plan_identity))
          && (not (String.equal changed_directory output_dir))
          && String.equal changed_prepared.plan_identity changed_plan
          && String.equal changed_prepared.bundle_directory changed_directory
          && Option.equal Asic.Fresh.Prepared.equal completed.prepared (Some prepared))
         "Source edit reused stale identity or relabelled earlier preparation";
       let legacy_preview : Asic.Preview.t =
         { selection = selected
         ; plan_identity = changed_plan
         ; plan_json = Yojson.Safe.to_string (Receipt.field changed_receipt "plan")
         }
       in
       let%bind _ = asic (Run { key = "legacy-run"; preview = legacy_preview }) in
       let%bind legacy = settled "legacy-run" in
       assert_completed legacy;
       require
         (Option.equal
            String.equal
            legacy.intent.expected_plan_identity
            (Some changed_plan)
          && List.length (stages ()) = 5)
         "Legacy Run bypassed source chain";
       let stale_preview : Asic.Preview.t =
         { selection = selected
         ; plan_identity
         ; plan_json = Yojson.Safe.to_string (Receipt.field receipt "plan")
         }
       in
       let%bind _ = asic (Run { key = "stale-legacy-run"; preview = stale_preview }) in
       let%bind stale = settled "stale-legacy-run" in
       require
         (Asic.Fresh.Phase.equal stale.phase Failed && List.length (stages ()) = 5)
         "Legacy explicit preview expectation silently replaced";
       (* Restart while another source producer is active. Reopening is historical
          evidence only and must neither replay nor acquire/cancel that producer. *)
       build_script := "sleep 30";
       let%bind unfinished_input = stage ~elaboration_only:true () in
       let%bind _ = launch "unfinished" unfinished_input in
       let%bind unfinished =
         wait "unfinished" (fun w ->
           Option.exists w.build_job ~f:(fun j -> Job.State.equal j.state Running))
       in
       let before_reopen = !builds in
       (* Restart the ASIC state owner without restarting the user's daemon. The direct
          service is a read-only reopen of this private fixture's registry. *)
       let state_dir = Filename.concat (Filename.dirname root) "logs-state" in
       let reopened = Hardcaml_workbench_backend.Asic_service.create ~state_dir in
       let%bind restored =
         Hardcaml_workbench_backend.Asic_service.handle
           reopened
           ~root
           ~environment:Inherit_daemon
           Get
         >>| ok
       in
       let old = find restored "physical" in
       require
         (Asic.Fresh.Phase.equal old.phase Completed
          && Option.is_some old.prepared
          && Option.equal Run_ref.equal old.run completed.run
          && Option.is_some old.elaboration_started_at
          && Option.is_some old.elaboration_finished_at
          && Option.is_none old.build_job
          && Option.is_none old.emission_job)
         "Restart lost durable lineage or retained live job handles";
       let interrupted = find restored "unfinished" in
       require
         (Asic.Fresh.Phase.equal interrupted.phase Interrupted
          && String.equal interrupted.elaboration_status "interrupted"
          && Option.is_some interrupted.elaboration_started_at)
         "Restart advertised unfinished preparation as owned/complete";
       let%bind replay =
         Hardcaml_workbench_backend.Asic_service.handle
           reopened
           ~root
           ~environment:Inherit_daemon
           (Launch_fresh { key = "physical"; intent_id = physical.id })
       in
       let%bind unfinished_replay =
         Hardcaml_workbench_backend.Asic_service.handle
           reopened
           ~root
           ~environment:Inherit_daemon
           (Launch_fresh { key = "unfinished"; intent_id = unfinished_input.id })
       in
       let%bind _ =
         Hardcaml_workbench_backend.Asic_service.handle
           reopened
           ~root
           ~environment:Inherit_daemon
           (Cancel_workflow interrupted.id)
       in
       require
         (Result.is_ok replay
          && Result.is_ok unfinished_replay
          && !builds = before_reopen
          && List.length (stages ()) = 5)
         "Restart replay reran a producer";
       let%bind () = Hardcaml_workbench_backend.Asic_service.shutdown reopened in
       let%bind still_owned = asic Get in
       require
         (Asic.Fresh.Phase.equal (find still_owned "unfinished").phase Building)
         "Historical cancellation signalled another owner";
       let%bind _ = asic (Cancel_workflow unfinished.id) in
       let%bind _ = settled "unfinished" in
       printf
         "Unified fresh %s: exact handoff, failure/cancel gates, source lease and \
          durable replay passed\n\
          %!"
         endpoint;
       return ())
;;

let run_fresh_probe_fixture ~shutdown =
  with_service
    (fun
        ~service
        ~project
        ~root
        ~config
        ~write_config
        ~plan_identity:_
        ~receipt:_
        ~output_dir:_
        ~build_script:_
        ~emit_script:_
        ~builds
        ~emissions
      ->
       write_config ();
       let provider = Filename.concat root "probe-provider.py" in
       Out_channel.write_all provider ~data:(In_channel.read_all "fresh_provider.py");
       Core_unix.chmod provider ~perm:0o700;
       let module C = Hardcaml_workbench_project_integration.Asic_config in
       let provider_config : C.t =
         { schema_version = 1
         ; project_executable = Filename.concat root "provider"
         ; provider_executable = provider
         ; results_root = config.results_root
         ; toolchain = root
         ; python = None
         ; support_tools = None
         ; pdk_root = None
         ; stage_timeout_seconds = None
         }
       in
       Out_channel.write_all
         (Filename.concat root C.filename)
         ~data:(Sexp.to_string (C.sexp_of_t provider_config));
       let marker name = Filename.concat root name in
       let touch name = Out_channel.write_all (marker name) ~data:"" in
       let asic operation =
         Service.asic service { instance_id; project; operation } >>| ok
       in
       let get key =
         let%map snapshot = asic Get in
         List.find_exn snapshot.workflows ~f:(fun w ->
           String.equal w.Asic.Fresh.Workflow.key key)
       in
       let bounded label f =
         let%map outcome = Clock.with_timeout (Time_float.Span.of_sec 3.) (f ()) in
         match outcome with
         | `Result value -> value
         | `Timeout -> failwith ("Timed out: " ^ label)
       in
       let wait label predicate =
         bounded label (fun () ->
           let rec loop () =
             let%bind result = predicate () in
             match result with
             | Some value -> return value
             | None ->
               let%bind () = Clock.after (Time_float.Span.of_ms 10.) in
               loop ()
           in
           loop ())
       in
       let launch key =
         let%bind snapshot =
           asic
             (Stage_fresh
                { selection; elaboration_only = false; expected_plan_identity = None })
         in
         let intent = Option.value_exn snapshot.fresh_intent in
         let%bind _ = asic (Launch_fresh { key; intent_id = intent.id }) in
         get key
       in
       let entered () =
         wait "owned metadata process enters gate" (fun () ->
           return
             (if Poly.equal (Sys_unix.file_exists (marker "probe-entered")) `Yes
              then Some (String.strip (In_channel.read_all (marker "probe-entered")))
              else None))
       in
       let terminal key =
         wait ("terminal workflow " ^ key) (fun () ->
           let%map w = get key in
           match w.phase with
           | Completed | Failed | Cancelled | Interrupted -> Some w
           | _ -> None)
       in
       let alive pid = Poly.equal (Sys_unix.file_exists ("/proc/" ^ pid)) `Yes in
       let assert_no_downstream () =
         require (!builds = 0 && !emissions = 0) "Capability probe admitted source work";
         require
           (not
              (List.exists
                 (In_channel.read_lines (marker "physical-calls"))
                 ~f:(fun line -> String.is_prefix line ~prefix:"[\"stages\"")))
           "Capability probe admitted physical work"
       in
       touch "hold-probe";
       Monitor.protect
         ~finally:(fun () ->
           touch "probe-release";
           return ())
         (fun () ->
           let%bind held = launch "held-probe" in
           let%bind pid = entered () in
           assert_no_downstream ();
           if shutdown
           then (
             let%bind () =
               bounded "shutdown joins and reaps owned capability probe" (fun () ->
                 Service.shutdown service)
             in
             require
               (not (alive pid))
               "Shutdown returned with capability process alive or unreaped";
             require
               (String.equal
                  (String.strip (In_channel.read_all (marker "probe-stopped")))
                  pid)
               "Shutdown did not signal its owned capability process";
             assert_no_downstream ();
             let reopened =
               Hardcaml_workbench_backend.Asic_service.create
                 ~state_dir:(Filename.concat (Filename.dirname root) "logs-state")
             in
             let%bind snapshot =
               Hardcaml_workbench_backend.Asic_service.handle
                 reopened
                 ~root
                 ~environment:Inherit_daemon
                 Get
               >>| ok
             in
             let restored =
               List.find_exn snapshot.workflows ~f:(fun w -> String.equal w.id held.id)
             in
             require
               (Asic.Fresh.Phase.equal restored.phase Cancelled
                && Option.is_none restored.preparation_id)
               "Shutdown failed to retain cancelled pre-preparation workflow";
             Hardcaml_workbench_backend.Asic_service.shutdown reopened)
           else (
             (* A second workflow owns a separate probe. Cancelling the first must not
                cancel/coalesce the second through the shared metadata cache. *)
             Core_unix.unlink (marker "probe-entered");
             let%bind _ = launch "independent-probe" in
             let%bind second_pid = entered () in
             require
               (not (String.equal pid second_pid))
               "Independent workflow borrowed an owned probe";
             let%bind _ = asic (Cancel_workflow held.id) in
             let%bind cancelled = terminal "held-probe" in
             require
               (Asic.Fresh.Phase.equal cancelled.phase Cancelled
                && Option.is_none cancelled.preparation_id
                && not (alive pid))
               "Cancellation did not join/reap capability process before completion";
             require
               (String.equal
                  (String.strip (In_channel.read_all (marker "probe-stopped")))
                  pid
                && alive second_pid)
               "Cancellation affected another workflow's probe";
             assert_no_downstream ();
             touch "probe-release";
             let%bind positive = terminal "independent-probe" in
             require
               (Asic.Fresh.Phase.equal positive.phase Completed
                && !builds = 1
                && !emissions = 1)
               "Uncancelled capability probe did not permit its exact source/physical \
                chain";
             touch "fail-probe";
             let%bind _ = launch "failed-probe" in
             let%bind failed = terminal "failed-probe" in
             require
               (Asic.Fresh.Phase.equal failed.phase Failed
                && Option.is_none failed.preparation_id
                && !builds = 1
                && !emissions = 1
                && Option.exists failed.error ~f:(fun e ->
                  String.is_substring e ~substring:"fixture capability probe failure"))
               "Failed fresh probe reused cached success or admitted downstream work";
             Core_unix.unlink (marker "fail-probe");
             let%bind _ = launch "recovered-probe" in
             let%bind recovered = terminal "recovered-probe" in
             require
               (Asic.Fresh.Phase.equal recovered.phase Completed
                && !builds = 2
                && !emissions = 2)
               "Failed/cancelled capability probe poisoned later fresh admission";
             return ())))
;;

let run_fresh_persistence_fixture () =
  with_service
    (fun
        ~service
        ~project
        ~root
        ~config:_
        ~write_config
        ~plan_identity:_
        ~receipt:_
        ~output_dir:_
        ~build_script:_
        ~emit_script:_
        ~builds
        ~emissions
      ->
       write_config ();
       let asic operation = Service.asic service { instance_id; project; operation } in
       let%bind staged =
         asic
           (Stage_fresh
              { selection; elaboration_only = true; expected_plan_identity = None })
         >>| ok
       in
       let intent = Option.value_exn staged.fresh_intent in
       let state_dir = Filename.concat (Filename.dirname root) "logs-state" in
       Out_channel.write_all state_dir ~data:"obstruct workflow reservation";
       let request =
         Asic.Operation.Launch_fresh
           { key = "durable-before-source"; intent_id = intent.id }
       in
       let%bind first, second = Deferred.both (asic request) (asic request) in
       require
         (Result.is_error first && Result.is_error second && !builds = 0 && !emissions = 0)
         "Failed durable reservation acknowledged or started preparation";
       let%bind failed = asic Get >>| ok in
       require
         (List.is_empty failed.workflows)
         "Failed durable reservation poisoned workflow key";
       Core_unix.unlink state_dir;
       let%bind first, second = Deferred.both (asic request) (asic request) in
       require
         (Result.is_ok first && Result.is_ok second)
         "Durable reservation failed to recover";
       let rec wait remaining =
         let%bind snapshot = asic Get >>| ok in
         let w = List.hd_exn snapshot.workflows in
         if Asic.Fresh.Phase.equal w.phase Completed
         then return ()
         else (
           require (remaining > 0) "Recovered workflow never completed";
           let%bind () = Clock.after (Time_float.Span.of_ms 20.) in
           wait (remaining - 1))
       in
       let%bind () = wait 200 in
       require
         (!builds = 1 && !emissions = 1)
         "Reservation retry started duplicate preparation";
       return ())
;;

(* Optional read-only acceptance check against a provider's real receipt and publication.
   Selection and store location are taken from that supplied receipt. *)
let validate_receipt_file path =
  let output = In_channel.read_all path in
  let receipt = Yojson.Safe.from_string output in
  let plan = Receipt.field receipt "plan" in
  let snapshot = Receipt.field (Receipt.field plan "methodology") "snapshot" in
  let selected = Receipt.field snapshot "selected" in
  let selection : Preparation.Selection.t =
    { flow = Receipt.text (Receipt.field selected "flow")
    ; profile = Receipt.text (Receipt.field selected "profile")
    ; endpoint = Receipt.text (Receipt.field snapshot "endpoint")
    ; assignments =
        Receipt.array (Receipt.field snapshot "request")
        |> List.map ~f:(fun a ->
          let value =
            match Receipt.field a "value" with
            | `String s -> s
            | `Bool true -> "true"
            | `Bool false -> "false"
            | _ -> failwith "Unsupported provider assignment"
          in
          Receipt.text (Receipt.field a "key") ^ "=" ^ value)
    }
  in
  let config : Config.t =
    { schema_version = 1
    ; build_target = "unused.exe"
    ; timeout_seconds = 10
    ; results_root =
        Filename.dirname
          (Filename.dirname (Receipt.text (Receipt.field receipt "output_dir")))
    }
  in
  let validated =
    Receipt.validate
      config
      ~selection
      ~expected_plan_identity:
        (Some (Receipt.text (Receipt.field receipt "plan_identity")))
      output
    |> Or_error.ok_exn
  in
  printf
    "Validated real receipt: %s (%d files)\n"
    validated.bundle.bundle_identity
    (List.length validated.files)
;;

let () =
  Command_unix.run
    (Command.async
       ~summary:"WB004 supervised preparation tests"
       (let%map_open.Command receipt =
          flag
            "-receipt"
            (optional string)
            ~doc:"PATH also validate an existing real provider receipt read-only"
        in
        fun () ->
          let%bind () = run_staging_fixture () in
          let%bind () = run_fixture () in
          let%bind () = run_fresh_persistence_fixture () in
          let%bind () = run_fresh_probe_fixture ~shutdown:false in
          let%bind () = run_fresh_probe_fixture ~shutdown:true in
          let%bind () = run_fresh_fixture "synthesis" in
          let%map () = run_fresh_fixture "cts" in
          Option.iter receipt ~f:validate_receipt_file))
;;
