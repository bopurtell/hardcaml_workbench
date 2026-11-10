open! Core
open! Async
open Hardcaml_workbench_protocol
module Rpc = Hardcaml_workbench_rpc_server.Rpc_server
module Service = Hardcaml_workbench_backend.Service

let require condition message = if not condition then raise_s [%message message]

let response_status deferred =
  let%map response, _body = deferred in
  Cohttp.Response.status response
;;

let request ?(headers = []) ?(meth = `GET) path =
  Cohttp.Request.make
    ~meth
    ~headers:(Cohttp.Header.of_list (("host", "127.0.0.1:8080") :: headers))
    (Uri.of_string path)
;;

let post_headers =
  [ "content-type", V1.content_type; String.lowercase V1.protocol_header, "1" ]
;;

let call rpc ?(headers = []) ?(meth = `GET) ?(body = "") path =
  let%bind response, body =
    Rpc.callback
      rpc
      ~body:(Cohttp_async.Body.of_string body)
      ()
      (request ~meth ~headers path)
  in
  let%map body = Cohttp_async.Body.to_string body in
  response, body
;;

let post rpc path sexp =
  let%map response, body =
    call rpc ~meth:`POST ~headers:post_headers ~body:(Sexp.to_string_mach sexp) path
  in
  require
    (Cohttp.Code.code_of_status (Cohttp.Response.status response) = 200)
    ("POST failed: " ^ path);
  body
;;

let decode_exn decoder body =
  match V1.Codec.decode decoder body with
  | Ok value -> value
  | Error error -> raise_s [%message "could not decode RPC response" (error : V1.Error.t)]
;;

let ok = function
  | Ok value -> value
  | Error error -> raise_s [%message "RPC operation failed" (error : V1.Error.t)]
;;

let require_instance_changed result message =
  require
    (match result with
     | Error error -> V1.Error.Kind.equal error.V1.Error.kind Instance_changed
     | Ok _ -> false)
    message
;;

module Legacy_asic_request = struct
  type t =
    { instance_id : V1.Daemon_instance_id.t
    ; project : Project_id.t
    ; operation : Asic.Operation.t
    }
  [@@deriving sexp]
end

let test_legacy_asic_server () =
  let received = ref false in
  let%bind server =
    Cohttp_async.Server.create
      ~on_handler_error:`Raise
      (Tcp.Where_to_listen.bind_to
         Tcp.Bind_to_address.Localhost
         Tcp.Bind_to_port.On_port_chosen_by_os)
      (fun ~body _peer request ->
         require
           (String.equal (Uri.path (Cohttp.Request.uri request)) "/api/v1/asic")
           "ASIC client used the wrong endpoint";
         require
           (Poly.equal (Cohttp.Request.meth request) `POST)
           "ASIC client did not POST";
         let headers = Cohttp.Request.headers request in
         require
           (Option.equal
              String.equal
              (Cohttp.Header.get headers Execution_timing.header)
              (Some "1"))
           "ASIC client omitted independent execution timing opt-in";
         require
           (Option.equal
              String.equal
              (Cohttp.Header.get headers Asic.Evidence_metadata.timing_analysis_header)
              (Some "2"))
           "ASIC client omitted independent supplementary timing opt-in";
         require
           (Option.equal
              String.equal
              (Cohttp.Header.get headers "X-Workbench-Asic-Evidence-Metadata")
              (Some "1"))
           "ASIC client omitted the evidence metadata opt-in";
         require
           (Option.equal
              String.equal
              (Cohttp.Header.get headers V1.protocol_header)
              (Some "1"))
           "ASIC client changed the overall protocol version";
         let%bind body = Cohttp_async.Body.to_string body in
         let decoded = decode_exn Legacy_asic_request.t_of_sexp body in
         require
           (String.equal decoded.instance_id "legacy-instance"
            && Project_id.equal decoded.project (Project_id.of_string "legacy-project")
            && Asic.Operation.equal decoded.operation Get)
           "legacy server could not decode the unchanged request body";
         received := true;
         (* Frozen old response: the old server ignores the optional request header. *)
         Cohttp_async.Server.respond_string
           ~status:`OK
           ~headers:(Cohttp.Header.init_with "content-type" V1.content_type)
           "(Ok ((configured false) (flows ()) (description_json ()) (preview ()) (runs \
            ()) (operations (((key inspect) (kind inspection) (state complete) (run ()) \
            (error ())))) (summaries ()) (inspections (((run ((backend asic) (id run:1) \
            (build ()) (label ()))) (execution_file /public/execution.json) \
            (execution_sha256 hash) (domain timing) (stage routing) (source_digest \
            digest) (rows ()) (diagnostics ()) (truncated false) (cached_unverified \
            true)))) (cache_error ())))")
  in
  Monitor.protect
    ~finally:(fun () -> Cohttp_async.Server.close server)
    (fun () ->
      let client =
        Hardcaml_workbench_native_http.Client.create
          (sprintf "http://127.0.0.1:%d" (Cohttp_async.Server.listening_on server))
      in
      let%map response =
        Hardcaml_workbench_native_http.Client.asic
          client
          { instance_id = "legacy-instance"
          ; project = Project_id.of_string "legacy-project"
          ; operation = Get
          }
      in
      let snapshot = Or_error.ok_exn response |> ok in
      require !received "legacy server did not receive the request";
      require
        (Asic.Pending.Activity.equal
           (List.hd_exn snapshot.operations).activity
           Unreported)
        "old server response did not default activity";
      require
        (Evidence_time.Index.equal
           (List.hd_exn snapshot.inspections).times
           Evidence_time.Index.empty)
        "old server response did not default evidence times")
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

let test_legacy_simulation_server () =
  let%bind server =
    Cohttp_async.Server.create
      ~on_handler_error:`Raise
      (Tcp.Where_to_listen.bind_to
         Tcp.Bind_to_address.Localhost
         Tcp.Bind_to_port.On_port_chosen_by_os)
      (fun ~body _peer request ->
         let headers = Cohttp.Request.headers request in
         require
           (String.equal (Uri.path (Cohttp.Request.uri request)) Simulation.rpc_path)
           "Simulation client used wrong endpoint";
         require
           (Option.equal
              String.equal
              (Cohttp.Header.get headers Execution_timing.header)
              (Some "1"))
           "Simulation client omitted execution timing opt-in";
         let%bind body = Cohttp_async.Body.to_string body in
         let request = decode_exn Simulation.Request.t_of_sexp body in
         require
           (Simulation.Operation.equal request.operation Get)
           "Simulation request body changed";
         Cohttp_async.Server.respond_string
           ~status:`OK
           ~headers:(Cohttp.Header.init_with "content-type" V1.content_type)
           "(Ok ((configured true) (discovery ()) (discovery_digest ()) (discovery_job \
            ()) (discovery_error ()) (attempts (((id old) (job job) (suite suite) (seed \
            42) (created_at old) (parent ()) (lifecycle Finished) (outcome Passed)))) \
            (next_before ()) (detail ()) (byte_page ()) (history_error ())))")
  in
  Monitor.protect
    ~finally:(fun () -> Cohttp_async.Server.close server)
    (fun () ->
      let client =
        Hardcaml_workbench_native_http.Client.create
          (sprintf "http://127.0.0.1:%d" (Cohttp_async.Server.listening_on server))
      in
      let%map response =
        Hardcaml_workbench_native_http.Client.simulation
          client
          { instance_id = "legacy-instance"
          ; project = Project_id.of_string "legacy-project"
          ; operation = Get
          }
      in
      let snapshot = Or_error.ok_exn response |> ok in
      require
        (Option.is_none (List.hd_exn snapshot.attempts).execution_timing)
        "Legacy simulation response invented timing")
;;

let wait_for_terminal_snapshot rpc instance_id job_id =
  let rec loop () =
    let%bind body =
      post rpc "/api/v1/snapshot" (V1.Snapshot.Request.sexp_of_t { instance_id })
    in
    let snapshot = decode_exn V1.Snapshot.Response.t_of_sexp body |> ok in
    match
      List.find snapshot.jobs ~f:(fun (job : Job.t) -> Job_id.equal job.id job_id)
    with
    | Some job when Job.is_terminal job -> return snapshot
    | Some _ | None ->
      let%bind () = Clock.after (Time_float.Span.of_ms 10.) in
      loop ()
  in
  Clock.with_timeout (Time_float.Span.of_sec 10.) (loop ())
  >>| function
  | `Result snapshot -> snapshot
  | `Timeout -> failwith "timed out waiting for RPC job"
;;

let run () =
  let%bind () = test_legacy_asic_server () in
  let%bind () = test_legacy_simulation_server () in
  let instance_id = V1.Daemon_instance_id.of_string "instance-1" in
  let directory = Filename_unix.temp_dir "hardcaml-workbench-rpc-test-" "" in
  let project_root = Filename.concat directory "project" in
  let log_dir = Filename.concat directory "logs" in
  Core_unix.mkdir project_root;
  Out_channel.write_all
    (Filename.concat project_root "dune-project")
    ~data:"(lang dune 3.22)\n(name rpc_transport_test)\n";
  Out_channel.write_all
    (Filename.concat project_root "dune")
    ~data:
      "(rule\n\
      \ (alias all)\n\
      \ (action (progn (echo rpc-log-marker) (echo rpc-log-tail))))\n";
  let%bind service = Service.create ~instance_id ~log_dir ~state_dir:directory () in
  let service = Or_error.ok_exn service in
  let rpc = Rpc.create ~application_version:"test" ~instance_id ~service in
  Monitor.protect
    ~finally:(fun () ->
      let%bind () = Service.shutdown service in
      In_thread.run (fun () -> remove_tree directory))
    (fun () ->
      let%bind hello_response, hello_body = call rpc "/api/hello" in
      require
        (Cohttp.Code.code_of_status (Cohttp.Response.status hello_response) = 200)
        "hello failed";
      let hello = decode_exn V1.Hello.Response.t_of_sexp hello_body in
      require
        (List.equal
           String.equal
           hello.capabilities
           [ "snapshot"
           ; "updates"
           ; "open-project"
           ; "submit-job"
           ; "refresh-integration"
           ; "generate-rtl"
           ; "cancel-job"
           ; "read-log"
           ; "read-artifact"
           ; "read-hierarchy"
           ; "workspace"
           ; "asic"
           ; "simulation"
           ; Preparation.capability
           ])
        "hello did not advertise the complete V1 capability set";
      let snapshot = Rpc.snapshot rpc { instance_id } in
      require (Result.is_ok snapshot) "empty snapshot failed";
      let changed = Rpc.snapshot rpc { instance_id = "other" } in
      require
        (match changed with
         | Error error -> V1.Error.Kind.equal error.kind Instance_changed
         | Ok _ -> false)
        "instance mismatch was accepted";
      let cursor = Rpc.cursor rpc in
      let%bind future =
        Rpc.updates
          rpc
          { instance_id
          ; cursor = { cursor with sequence = 1 }
          ; max_events = 1
          ; timeout_ms = 0
          }
      in
      require
        (match future with
         | Error error -> V1.Error.Kind.equal error.kind Invalid_request
         | Ok _ -> false)
        "future cursor was accepted";
      rpc.oldest_sequence <- 1;
      let%bind stale =
        Rpc.updates rpc { instance_id; cursor; max_events = 1; timeout_ms = 0 }
      in
      require
        (match stale with
         | Error error -> V1.Error.Kind.equal error.kind Resync_required
         | Ok _ -> false)
        "stale cursor did not require resync";
      rpc.oldest_sequence <- 0;
      let waiting =
        Rpc.updates rpc { instance_id; cursor; max_events = 1; timeout_ms = 1_000 }
      in
      let%bind () = Clock.after (Time_float.Span.of_ms 10.) in
      Rpc.publish_event rpc (Project_removed (Project_id.of_string "project-1"));
      let%bind published = waiting in
      require
        (match published with
         | Ok
             { events = [ { sequence = 1; event = Project_removed _ } ]
             ; heartbeat = false
             ; _
             } -> true
         | _ -> false)
        "waiting poll did not wake for a published event";
      let cursor = Rpc.cursor rpc in
      let started = Time_ns.now () in
      let%bind heartbeat =
        Rpc.updates rpc { instance_id; cursor; max_events = 1; timeout_ms = 20 }
      in
      require
        (match heartbeat with
         | Ok payload -> payload.heartbeat && List.is_empty payload.events
         | Error _ -> false)
        "poll did not return an empty heartbeat";
      require
        Time_ns.Span.(Time_ns.diff (Time_ns.now ()) started >= of_int_ms 15)
        "poll returned before its timeout";
      let%bind bad_host =
        Rpc.callback
          rpc
          ~body:(Cohttp_async.Body.of_string "")
          ()
          (Cohttp.Request.make
             ~headers:(Cohttp.Header.init_with "host" "example.com")
             (Uri.of_string "/api/hello"))
        |> response_status
      in
      require (Cohttp.Code.code_of_status bad_host = 400) "arbitrary Host was accepted";
      let%bind bad_origin =
        Rpc.callback
          rpc
          ~body:(Cohttp_async.Body.of_string "")
          ()
          (request ~headers:[ "origin", "http://evil.example:8080" ] "/api/hello")
        |> response_status
      in
      require
        (Cohttp.Code.code_of_status bad_origin = 400)
        "cross-origin request was accepted";
      let%bind missing_headers =
        Rpc.callback
          rpc
          ~body:(Cohttp_async.Body.of_string "()")
          ()
          (request ~meth:`POST "/api/v1/snapshot")
        |> response_status
      in
      require
        (Cohttp.Code.code_of_status missing_headers = 400)
        "POST headers were optional";
      let%bind malformed =
        Rpc.callback
          rpc
          ~body:(Cohttp_async.Body.of_string "(malformed)")
          ()
          (request ~meth:`POST ~headers:post_headers "/api/v1/snapshot")
        |> response_status
      in
      require (Cohttp.Code.code_of_status malformed = 400) "malformed body was accepted";
      let%bind oversized =
        Rpc.callback
          rpc
          ~body:(Cohttp_async.Body.of_string "")
          ()
          (request
             ~meth:`POST
             ~headers:
               (("content-length", Int.to_string (V1.max_request_body_bytes + 1))
                :: post_headers)
             "/api/v1/snapshot")
        |> response_status
      in
      require (Cohttp.Code.code_of_status oversized = 413) "oversized body was accepted";
      let%bind streamed_oversized =
        Rpc.callback
          rpc
          ~body:
            (Cohttp_async.Body.of_string
               (String.make (V1.max_request_body_bytes + 1) 'x'))
          ()
          (request ~meth:`POST ~headers:post_headers "/api/v1/snapshot")
        |> response_status
      in
      require
        (Cohttp.Code.code_of_status streamed_oversized = 413)
        "oversized body without Content-Length was accepted";
      let new_routes =
        [ "/api/v1/open-project"
        ; "/api/v1/submit-job"
        ; "/api/v1/refresh-integration"
        ; "/api/v1/generate-rtl"
        ; "/api/v1/cancel-job"
        ; "/api/v1/read-log"
        ; "/api/v1/read-artifact"
        ; "/api/v1/read-hierarchy"
        ]
      in
      let%bind () =
        Deferred.List.iter new_routes ~how:`Sequential ~f:(fun path ->
          let%map response, _body =
            call rpc ~meth:`POST ~headers:post_headers ~body:"(malformed)" path
          in
          require
            (Cohttp.Code.code_of_status (Cohttp.Response.status response) = 400)
            ("malformed operation body was accepted: " ^ path))
      in
      let other = V1.Daemon_instance_id.of_string "other" in
      let missing_project = Project_id.of_string "missing-project" in
      let missing_job = Job_id.of_string "missing-job" in
      let missing_artifact = Artifact_id.of_string "missing-artifact" in
      let%bind wrong_open_body =
        post
          rpc
          "/api/v1/open-project"
          (V1.Open_project.Request.sexp_of_t
             { instance_id = other
             ; root = project_root
             ; environment = V1.Environment_selection.Inherit_daemon
             })
      in
      require_instance_changed
        (decode_exn V1.Open_project.Response.t_of_sexp wrong_open_body)
        "open-project accepted another daemon instance";
      let%bind wrong_submit_body =
        post
          rpc
          "/api/v1/submit-job"
          (V1.Submit_job.Request.sexp_of_t
             { instance_id = other
             ; project = missing_project
             ; action = Build
             ; submission_key = "wrong-instance"
             })
      in
      require_instance_changed
        (decode_exn V1.Submit_job.Response.t_of_sexp wrong_submit_body)
        "submit-job accepted another daemon instance";
      let%bind wrong_refresh_body =
        post
          rpc
          "/api/v1/refresh-integration"
          (V1.Refresh_integration.Request.sexp_of_t
             { instance_id = other; project = missing_project })
      in
      require_instance_changed
        (decode_exn V1.Refresh_integration.Response.t_of_sexp wrong_refresh_body)
        "refresh-integration accepted another daemon instance";
      let%bind wrong_generate_body =
        post
          rpc
          "/api/v1/generate-rtl"
          (V1.Generate_rtl.Request.sexp_of_t
             { instance_id = other
             ; project = missing_project
             ; target = Target_id.of_string "missing-target"
             ; configuration = Configuration_id.of_string "missing-configuration"
             ; submission_key = "wrong-generate-instance"
             })
      in
      require_instance_changed
        (decode_exn V1.Generate_rtl.Response.t_of_sexp wrong_generate_body)
        "generate-rtl accepted another daemon instance";
      let%bind wrong_cancel_body =
        post
          rpc
          "/api/v1/cancel-job"
          (V1.Cancel_job.Request.sexp_of_t { instance_id = other; job = missing_job })
      in
      require_instance_changed
        (decode_exn V1.Cancel_job.Response.t_of_sexp wrong_cancel_body)
        "cancel-job accepted another daemon instance";
      let%bind wrong_read_body =
        post
          rpc
          "/api/v1/read-log"
          (V1.Read_log.Request.sexp_of_t
             { instance_id = other
             ; job = missing_job
             ; offset = 0
             ; max_records = 1
             ; max_bytes = 1
             })
      in
      require_instance_changed
        (decode_exn V1.Read_log.Response.t_of_sexp wrong_read_body)
        "read-log accepted another daemon instance";
      let%bind wrong_artifact_body =
        post
          rpc
          "/api/v1/read-artifact"
          (V1.Read_artifact.Request.sexp_of_t
             { instance_id = other
             ; artifact = missing_artifact
             ; offset = 0
             ; max_bytes = 1
             })
      in
      require_instance_changed
        (decode_exn V1.Read_artifact.Response.t_of_sexp wrong_artifact_body)
        "read-artifact accepted another daemon instance";
      let%bind missing_artifact_body =
        post
          rpc
          "/api/v1/read-artifact"
          (V1.Read_artifact.Request.sexp_of_t
             { instance_id; artifact = missing_artifact; offset = 0; max_bytes = 1 })
      in
      require
        (match decode_exn V1.Read_artifact.Response.t_of_sexp missing_artifact_body with
         | Error error -> V1.Error.Kind.equal error.kind Not_found
         | Ok _ -> false)
        "unknown artifact did not return not-found";
      let%bind wrong_hierarchy_body =
        post
          rpc
          "/api/v1/read-hierarchy"
          (V1.Read_hierarchy.Request.sexp_of_t
             { instance_id = other; artifact = missing_artifact })
      in
      require_instance_changed
        (decode_exn V1.Read_hierarchy.Response.t_of_sexp wrong_hierarchy_body)
        "read-hierarchy accepted another daemon instance";
      let%bind missing_hierarchy_body =
        post
          rpc
          "/api/v1/read-hierarchy"
          (V1.Read_hierarchy.Request.sexp_of_t
             { instance_id; artifact = missing_artifact })
      in
      require
        (match decode_exn V1.Read_hierarchy.Response.t_of_sexp missing_hierarchy_body with
         | Error error -> V1.Error.Kind.equal error.kind Not_found
         | Ok _ -> false)
        "unknown hierarchy did not return not-found";
      let initial_cursor = { (Rpc.cursor rpc) with sequence = 0 } in
      let%bind opened_body =
        post
          rpc
          "/api/v1/open-project"
          (V1.Open_project.Request.sexp_of_t
             { instance_id
             ; root = project_root
             ; environment = V1.Environment_selection.Inherit_daemon
             })
      in
      let opened = decode_exn V1.Open_project.Response.t_of_sexp opened_body |> ok in
      let preparation_request : Preparation.Request.t =
        { instance_id; project = opened.project.id; operation = Get }
      in
      let%bind preparation_body =
        post rpc Preparation.rpc_path (Preparation.Request.sexp_of_t preparation_request)
      in
      let preparation =
        decode_exn Preparation.Response.t_of_sexp preparation_body |> ok
      in
      require
        (Preparation.Availability.equal
           preparation.availability
           (Unavailable Not_configured)
         && preparation.session_only
         && List.is_empty preparation.history)
        "Preparation availability/history did not round-trip";
      let%bind wrong_preparation =
        post
          rpc
          Preparation.rpc_path
          (Preparation.Request.sexp_of_t
             { preparation_request with instance_id = "other" })
      in
      require_instance_changed
        (decode_exn Preparation.Response.t_of_sexp wrong_preparation)
        "Preparation accepted a stale daemon instance";
      let%bind server = Rpc.start rpc ~port:0 in
      let%bind () =
        Monitor.protect
          ~finally:(fun () -> Cohttp_async.Server.close server)
          (fun () ->
            let client =
              Hardcaml_workbench_native_http.Client.create
                (sprintf "http://127.0.0.1:%d" (Cohttp_async.Server.listening_on server))
            in
            let%map result =
              Hardcaml_workbench_native_http.Client.preparation client preparation_request
            in
            let received = Or_error.ok_exn result |> ok in
            require
              (Preparation.Snapshot.equal received preparation)
              "Native preparation client used the wrong contract")
      in
      let asic_request : Asic.Request.t =
        { instance_id; project = opened.project.id; operation = Get }
      in
      let timing = Execution_timing.make ~measured_seconds:12.5 ~running:false () in
      let runs =
        [ { Asic.Run.run =
              { backend = Backend_id.of_string "asic"
              ; id = "r"
              ; build = None
              ; label = None
              }
          ; reference = { attempt = "/public/attempt"; stream_id = "r" }
          ; selection = None
          ; cursor = 1
          ; status = "completed"
          ; execution_file = None
          ; error = None
          ; execution_timing = timing
          ; stages =
              [ { id = "synthesis"
                ; name = "Synthesis"
                ; status = Completed
                ; requested = true
                ; reason = None
                ; action = None
                ; execution_timing = timing
                }
              ]
          }
        ]
      in
      let identity =
        Sexp.to_string_mach
          (Sexp.List
             [ Atom project_root
             ; V1.Environment_selection.sexp_of_t Inherit_daemon
             ; List []
             ])
      in
      let timing_analysis : Asic.Timing_analysis.t =
        Hardcaml_workbench_backend.Asic_timing_analysis.parse_for_attempt
          ~attempt_id:"r"
          ~execution_file:"/public/execution.json"
          ~execution_sha256:(String.make 64 'b')
          (`Assoc
            [ "execution", `Assoc [ "status", `String "failed" ]
            ; ( "timing_analysis"
              , `Assoc
                  [ "contract", `String "hardcaml-asic.timing-analysis"
                  ; "schema_version", `Int 1
                  ; "attempt_id", `String "r"
                  ; "occurrence_id", `String "r/implementation.signoff"
                  ; "analysis_id", `String "r/post-pnr-sta"
                  ; "source_digest", `String (String.make 64 'a')
                  ; "execution_sha256", `String (String.make 64 'b')
                  ; "execution_file", `String "/public/execution.json"
                  ; "stage", `String "signoff"
                  ; "evidence_scope", `String "terminal_supplementary_not_checkpoint"
                  ; "enclosing_status", `String "failed"
                  ; "status", `String "unavailable"
                  ; "reason", `String "STA unreached"
                  ; "duration", `Null
                  ; "producer", `Null
                  ; "metrics", `List []
                  ; "corners", `List []
                  ; "inventory", `List []
                  ; "timing_goal", `String "unknown"
                  ] )
            ])
        |> Option.value_exn
      in
      let summary : Asic.Summary.t =
        { run = (List.hd_exn runs).run
        ; source_digest = "timing-http-fixture"
        ; execution_file = "/public/execution.json"
        ; plan_identity = None
        ; cell_count = None
        ; cells = []
        ; metrics = []
        ; terminal = None
        ; timing_analysis = Some timing_analysis
        ; timing = []
        ; completion = "failed"
        ; acceptance = "not_evaluated"
        ; producer = "no synthesis checkpoint"
        ; observed_at = "fixture"
        ; freshness = Validated
        }
      in
      let normalized_digest =
        Hardcaml_workbench_backend.Asic_public.digest
          (Sexp.to_string_mach (Asic.Summary.sexp_of_t summary))
      in
      let summary_blob =
        Sexp.List
          [ [%sexp "version", (5 : int)]
          ; [%sexp "normalized_digest", (normalized_digest : string)]
          ; [%sexp "summary", (summary : Asic.Summary.t)]
          ]
      in
      Out_channel.write_all
        (Filename.concat
           directory
           ("asic-"
            ^ Hardcaml_workbench_backend.Asic_public.digest identity
            ^ "-summary-v1-"
            ^ Hardcaml_workbench_backend.Asic_public.digest summary.source_digest
            ^ ".summary.sexp"))
        ~data:(Sexp.to_string_mach summary_blob);
      let registry =
        Sexp.List
          [ [%sexp "version", (1 : int)]
          ; [%sexp "identity", (identity : string)]
          ; [%sexp "runs", (runs : Asic.Run.t list)]
          ; [%sexp "submissions", ([] : (string * Asic.Preview.t * string option) list)]
          ; [%sexp "index", ([ "r", summary.source_digest ] : (string * string) list)]
          ]
      in
      Out_channel.write_all
        (Filename.concat
           directory
           ("asic-" ^ Hardcaml_workbench_backend.Asic_public.digest identity ^ ".sexp"))
        ~data:(Sexp.to_string_mach registry);
      let%bind (_ : string) =
        post
          rpc
          "/api/v1/asic"
          (Asic.Request.sexp_of_t
             { asic_request with operation = Load_summary summary.run })
      in
      let rec wait_summary remaining =
        let%bind body = post rpc "/api/v1/asic" (Asic.Request.sexp_of_t asic_request) in
        let snapshot = decode_exn Asic.Response.t_of_sexp body |> ok in
        if not (List.is_empty snapshot.summaries)
        then Deferred.unit
        else (
          require (remaining > 0) "Cached HTTP timing summary did not hydrate";
          let%bind () = Clock.after (Time_float.Span.of_sec 0.01) in
          wait_summary (remaining - 1))
      in
      let%bind () = wait_summary 100 in
      let%bind () =
        Deferred.List.iter
          ~how:`Sequential
          [ None; Some ""; Some "0"; Some "2"; Some "1" ]
          ~f:(fun version ->
            let headers =
              post_headers
              @ Option.value_map version ~default:[] ~f:(fun v ->
                [ Asic.Evidence_metadata.timing_analysis_header, v ])
            in
            let%map _, body =
              call
                rpc
                ~meth:`POST
                ~headers
                ~body:(Sexp.to_string_mach (Asic.Request.sexp_of_t asic_request))
                "/api/v1/asic"
            in
            let snapshot = decode_exn Asic.Response.t_of_sexp body |> ok in
            let actual = (List.hd_exn snapshot.summaries).timing_analysis in
            require
              (Bool.equal
                 (Option.is_some actual)
                 (List.mem
                    [ Some "1"; Some "2" ]
                    version
                    ~equal:(Option.equal String.equal)))
              "Populated timing analysis was not independently negotiated";
            if Option.is_none actual
            then
              require
                (not (String.is_substring body ~substring:"timing_analysis"))
                "Legacy HTTP response retained the new field")
      in
      let%bind () =
        Deferred.List.iter
          ~how:`Sequential
          [ [], false
          ; [ Asic.Evidence_metadata.header, "1" ], false
          ; [ Execution_timing.header, "2" ], false
          ; [ Execution_timing.header, "1" ], true
          ; [ Asic.Evidence_metadata.header, "1"; Execution_timing.header, "1" ], true
          ]
          ~f:(fun (extra, expected) ->
            let%map _, body =
              call
                rpc
                ~meth:`POST
                ~headers:(post_headers @ extra)
                ~body:(Sexp.to_string_mach (Asic.Request.sexp_of_t asic_request))
                "/api/v1/asic"
            in
            let snapshot = decode_exn Asic.Response.t_of_sexp body |> ok in
            let run = List.hd_exn snapshot.runs in
            require
              (Bool.equal (Option.is_some run.execution_timing) expected
               && Bool.equal
                    (Option.is_some (List.hd_exn run.stages).execution_timing)
                    expected)
              "Execution timing was not independently negotiated")
      in
      let%bind simulation_body =
        post
          rpc
          Simulation.rpc_path
          (Simulation.Request.sexp_of_t
             { instance_id; project = opened.project.id; operation = Get })
      in
      let simulation = decode_exn Simulation.Response.t_of_sexp simulation_body |> ok in
      require
        ((not simulation.configured) && List.is_empty simulation.attempts)
        "Unconfigured simulation snapshot failed";
      let%bind simulation_changed =
        post
          rpc
          Simulation.rpc_path
          (Simulation.Request.sexp_of_t
             { instance_id = "other"; project = opened.project.id; operation = Get })
      in
      require_instance_changed
        (decode_exn Simulation.Response.t_of_sexp simulation_changed)
        "Simulation omitted instance fence";
      let%bind simulation_discover =
        post
          rpc
          Simulation.rpc_path
          (Simulation.Request.sexp_of_t
             { instance_id; project = opened.project.id; operation = Discover })
      in
      require
        (match decode_exn Simulation.Response.t_of_sexp simulation_discover with
         | Error error -> V1.Error.Kind.equal error.kind Unsupported_operation
         | Ok _ -> false)
        "Simulation discovery invented a provider";
      require
        (V1.Environment_selection.equal opened.environment.selection Inherit_daemon)
        "open-project did not preserve inherited environment selection";
      require
        (not (List.is_empty opened.workspace.contexts))
        "Dune workspace had no contexts";
      let%bind submitted_body =
        post
          rpc
          "/api/v1/submit-job"
          (V1.Submit_job.Request.sexp_of_t
             { instance_id
             ; project = opened.project.id
             ; action = Build
             ; submission_key = "rpc-build"
             })
      in
      let submitted = decode_exn V1.Submit_job.Response.t_of_sexp submitted_body |> ok in
      let%bind final_snapshot =
        wait_for_terminal_snapshot rpc instance_id submitted.job.id
      in
      let final_job =
        List.find_exn final_snapshot.jobs ~f:(fun (job : Job.t) ->
          Job_id.equal job.id submitted.job.id)
      in
      require
        (Job.State.equal final_job.state Complete)
        "transport build did not complete";
      let%bind read_body =
        post
          rpc
          "/api/v1/read-log"
          (V1.Read_log.Request.sexp_of_t
             { instance_id
             ; job = submitted.job.id
             ; offset = 0
             ; max_records = V1.max_log_records
             ; max_bytes = V1.max_log_bytes
             })
      in
      let log = decode_exn V1.Read_log.Response.t_of_sexp read_body |> ok in
      let log_text =
        log.records
        |> List.map ~f:(fun record -> record.V1.Read_log.Record.data)
        |> String.concat
      in
      require log.eof "completed job log was not at EOF";
      require
        (String.is_substring log_text ~substring:"rpc-log-marker")
        "read-log route did not return Dune action output";
      let%bind cancelled_body =
        post
          rpc
          "/api/v1/cancel-job"
          (V1.Cancel_job.Request.sexp_of_t { instance_id; job = submitted.job.id })
      in
      let cancelled = decode_exn V1.Cancel_job.Response.t_of_sexp cancelled_body |> ok in
      require
        (Job.equal cancelled.job final_job)
        "cancel-job did not return the current terminal job";
      let%bind updates_body =
        post
          rpc
          "/api/v1/updates"
          (V1.Updates.Request.sexp_of_t
             { instance_id
             ; cursor = initial_cursor
             ; max_events = V1.max_update_events
             ; timeout_ms = 0
             })
      in
      let updates = decode_exn V1.Updates.Response.t_of_sexp updates_body |> ok in
      let last_project =
        List.filter_map updates.events ~f:(fun event ->
          match event.V1.Event.event with
          | Project_upsert project -> Some project
          | _ -> None)
        |> List.last_exn
      in
      let last_job =
        List.filter_map updates.events ~f:(fun event ->
          match event.V1.Event.event with
          | Job_upsert job when Job_id.equal job.id submitted.job.id -> Some job
          | _ -> None)
        |> List.last_exn
      in
      require
        (Project.equal last_project (List.hd_exn final_snapshot.projects))
        "populated snapshot project disagreed with transport events";
      require
        (Job.equal last_job final_job)
        "populated snapshot job disagreed with transport events";
      require
        (V1.Cursor.equal updates.next_cursor final_snapshot.cursor)
        "populated snapshot cursor disagreed with transport events";
      require
        (not
           (String.is_substring
              (Sexp.to_string (V1.Snapshot.Payload.sexp_of_t final_snapshot))
              ~substring:"rpc-log-marker"))
        "snapshot exposed log bytes";
      let%map unknown =
        Rpc.callback
          rpc
          ~body:(Cohttp_async.Body.of_string "")
          ()
          (request "/api/v2/snapshot")
        |> response_status
      in
      require
        (Cohttp.Code.code_of_status unknown = 404)
        "unknown version was not rejected")
;;

let command = Command.async ~summary:"Test V1 RPC behavior" (Command.Param.return run)
let () = Command_unix.run command
