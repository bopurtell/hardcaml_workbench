open! Core
open! Async
open Hardcaml_workbench_protocol
module Service = Hardcaml_workbench_backend.Service
module Execution = Hardcaml_workbench_backend.Execution_module

type t =
  { hello : V1.Hello.Response.t
  ; service : Service.t
  ; mutable sequence : int
  ; mutable oldest_sequence : int
  ; mutable events : V1.Event.sequenced list
  ; mutable event_available : unit Ivar.t
  }

let cursor t = { V1.Cursor.instance_id = t.hello.instance_id; sequence = t.sequence }

let publish_event t event =
  t.sequence <- t.sequence + 1;
  t.events <- t.events @ [ { V1.Event.sequence = t.sequence; event } ];
  if List.length t.events > 4096 then t.events <- List.drop t.events 1;
  t.oldest_sequence
  <- (match List.hd t.events with
      | None -> t.sequence
      | Some event -> event.sequence - 1);
  Ivar.fill_if_empty t.event_available ();
  t.event_available <- Ivar.create ()
;;

let create ~application_version ~instance_id ~service =
  let t =
    { hello =
        { application_version
        ; protocol_versions = [ V1.version ]
        ; instance_id
        ; capabilities =
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
            ]
        }
    ; service
    ; sequence = 0
    ; oldest_sequence = 0
    ; events = []
    ; event_available = Ivar.create ()
    }
  in
  Service.set_event_sink t.service (fun sequenced -> publish_event t sequenced.event);
  t
;;

let check_instance t instance_id =
  if V1.Daemon_instance_id.equal instance_id t.hello.instance_id
  then Ok ()
  else Error (V1.Error.create Instance_changed "daemon instance has changed")
;;

let snapshot t ({ instance_id } : V1.Snapshot.Request.t) =
  match check_instance t instance_id with
  | Error error -> Error error
  | Ok () ->
    Result.map
      (Service.snapshot t.service { instance_id })
      ~f:(fun snapshot -> { snapshot with cursor = cursor t })
;;

let rec updates
  t
  ({ instance_id; cursor = requested; max_events; timeout_ms } : V1.Updates.Request.t)
  =
  match check_instance t instance_id with
  | Error error -> return (Error error)
  | Ok () when not (V1.Daemon_instance_id.equal requested.instance_id t.hello.instance_id)
    ->
    return (Error (V1.Error.create Instance_changed "cursor belongs to another daemon"))
  | Ok () when max_events <= 0 || max_events > V1.max_update_events ->
    return
      (Error
         (V1.Error.create
            Invalid_request
            (sprintf "max_events must be between 1 and %d" V1.max_update_events)))
  | Ok () when timeout_ms < 0 || timeout_ms > V1.max_poll_timeout_ms ->
    return
      (Error
         (V1.Error.create
            Invalid_request
            (sprintf "timeout_ms must be between 0 and %d" V1.max_poll_timeout_ms)))
  | Ok () when requested.sequence > t.sequence ->
    return (Error (V1.Error.create Invalid_request "cursor is in the future"))
  | Ok () when requested.sequence < t.oldest_sequence ->
    return (Error (V1.Error.create Resync_required "cursor predates retained events"))
  | Ok () ->
    let available =
      List.filter t.events ~f:(fun event -> event.sequence > requested.sequence)
      |> Fn.flip List.take max_events
    in
    if not (List.is_empty available)
    then (
      let sequence = (List.last_exn available).sequence in
      return
        (Ok
           { V1.Updates.Payload.events = available
           ; next_cursor = { requested with sequence }
           ; heartbeat = false
           }))
    else (
      let event_available = Ivar.read t.event_available >>| fun () -> `Event in
      let timeout =
        Clock.after (Time_float.Span.of_ms (Float.of_int timeout_ms))
        >>| fun () -> `Timeout
      in
      let%bind result = Deferred.any [ event_available; timeout ] in
      match result with
      | `Event ->
        updates t { instance_id; cursor = requested; max_events; timeout_ms = 0 }
      | `Timeout ->
        return
          (Ok
             { V1.Updates.Payload.events = []; next_cursor = requested; heartbeat = true }))
;;

let sexp_response ?(status = `OK) sexp =
  Cohttp_async.Server.respond_string
    ~status
    ~headers:(Cohttp.Header.init_with "content-type" V1.content_type)
    (Sexp.to_string_mach sexp)
;;

let boundary_error status kind message =
  sexp_response ~status (V1.Error.sexp_of_t (V1.Error.create kind message))
;;

let loopback_host host =
  let uri = Uri.of_string ("http://" ^ host) in
  match Uri.host uri with
  | Some host ->
    String.Caseless.equal host "localhost"
    || String.equal host "127.0.0.1"
    || String.equal host "::1"
  | None -> false
;;

let valid_origin headers host =
  match Cohttp.Header.get headers "origin" with
  | None -> true
  | Some origin ->
    let uri = Uri.of_string origin in
    let host_uri = Uri.of_string ("http://" ^ host) in
    (match Uri.scheme uri, Uri.host uri with
     | Some scheme, Some origin_host ->
       String.Caseless.equal scheme "http"
       && Option.value_map (Uri.host host_uri) ~default:false ~f:(fun expected_host ->
         String.Caseless.equal origin_host expected_host)
       && Option.equal Int.equal (Uri.port uri) (Uri.port host_uri)
     | _ -> false)
;;

let decode body of_sexp = V1.Codec.decode of_sexp body

let read_bounded_body body =
  let pipe = Cohttp_async.Body.to_pipe body in
  let rec read chunks length =
    let%bind next = Pipe.read pipe in
    match next with
    | `Eof -> return (Ok (String.concat (List.rev chunks)))
    | `Ok chunk ->
      let length = length + String.length chunk in
      if length > V1.max_request_body_bytes
      then (
        Pipe.close_read pipe;
        return (Error ()))
      else read (chunk :: chunks) length
  in
  read [] 0
;;

let operation_response response sexp_of_response =
  let%bind response in
  sexp_response (sexp_of_response response)
;;

let handle_post t ~path ~headers ~body =
  let content_type = Cohttp.Header.get headers "content-type" in
  let protocol = Cohttp.Header.get headers (String.lowercase V1.protocol_header) in
  match content_type, protocol with
  | Some content_type, Some protocol
    when String.Caseless.equal (String.strip content_type) V1.content_type
         && String.equal protocol (Int.to_string V1.version) ->
    let declared_too_large =
      Cohttp.Header.get headers "content-length"
      |> Option.bind ~f:Int.of_string_opt
      |> Option.value_map ~default:false ~f:(fun length ->
        length > V1.max_request_body_bytes)
    in
    if declared_too_large
    then boundary_error `Request_entity_too_large Invalid_request "request too large"
    else (
      let%bind body = read_bounded_body body in
      match body with
      | Error () ->
        boundary_error `Request_entity_too_large Invalid_request "request too large"
      | Ok body when String.equal path "/api/v1/snapshot" ->
        (match decode body V1.Snapshot.Request.t_of_sexp with
         | Error error ->
           boundary_error `Bad_request error.kind "malformed snapshot request"
         | Ok request ->
           sexp_response (V1.Snapshot.Response.sexp_of_t (snapshot t request)))
      | Ok body when String.equal path "/api/v1/updates" ->
        (match decode body V1.Updates.Request.t_of_sexp with
         | Error error ->
           boundary_error `Bad_request error.kind "malformed updates request"
         | Ok request ->
           operation_response (updates t request) V1.Updates.Response.sexp_of_t)
      | Ok body when String.equal path "/api/v1/open-project" ->
        (match decode body V1.Open_project.Request.t_of_sexp with
         | Error error ->
           boundary_error `Bad_request error.kind "malformed open-project request"
         | Ok request ->
           operation_response
             (Service.open_project_with_discovery t.service request)
             V1.Open_project.Response.sexp_of_t)
      | Ok body when String.equal path "/api/v1/submit-job" ->
        (match decode body V1.Submit_job.Request.t_of_sexp with
         | Error error ->
           boundary_error `Bad_request error.kind "malformed submit-job request"
         | Ok request ->
           operation_response
             (Execution.submit (Execution.of_service t.service) request)
             V1.Submit_job.Response.sexp_of_t)
      | Ok body when String.equal path "/api/v1/refresh-integration" ->
        (match decode body V1.Refresh_integration.Request.t_of_sexp with
         | Error error ->
           boundary_error `Bad_request error.kind "malformed refresh-integration request"
         | Ok request ->
           operation_response
             (Service.refresh_integration t.service request)
             V1.Refresh_integration.Response.sexp_of_t)
      | Ok body when String.equal path "/api/v1/generate-rtl" ->
        (match decode body V1.Generate_rtl.Request.t_of_sexp with
         | Error error ->
           boundary_error `Bad_request error.kind "malformed generate-rtl request"
         | Ok request ->
           operation_response
             (Service.generate_rtl t.service request)
             V1.Generate_rtl.Response.sexp_of_t)
      | Ok body when String.equal path "/api/v1/cancel-job" ->
        (match decode body V1.Cancel_job.Request.t_of_sexp with
         | Error error ->
           boundary_error `Bad_request error.kind "malformed cancel-job request"
         | Ok request ->
           operation_response
             (Execution.cancel (Execution.of_service t.service) request)
             V1.Cancel_job.Response.sexp_of_t)
      | Ok body when String.equal path "/api/v1/read-log" ->
        (match decode body V1.Read_log.Request.t_of_sexp with
         | Error error ->
           boundary_error `Bad_request error.kind "malformed read-log request"
         | Ok request ->
           operation_response
             (Execution.read_log (Execution.of_service t.service) request)
             V1.Read_log.Response.sexp_of_t)
      | Ok body when String.equal path "/api/v1/read-artifact" ->
        (match decode body V1.Read_artifact.Request.t_of_sexp with
         | Error error ->
           boundary_error `Bad_request error.kind "malformed read-artifact request"
         | Ok request ->
           operation_response
             (Service.read_artifact t.service request)
             V1.Read_artifact.Response.sexp_of_t)
      | Ok body when String.equal path "/api/v1/read-hierarchy" ->
        (match decode body V1.Read_hierarchy.Request.t_of_sexp with
         | Error error ->
           boundary_error `Bad_request error.kind "malformed read-hierarchy request"
         | Ok request ->
           operation_response
             (Service.read_hierarchy t.service request)
             V1.Read_hierarchy.Response.sexp_of_t)
      | Ok body when String.equal path "/api/v1/workspace" ->
        (match decode body Workspace.Request.t_of_sexp with
         | Error error ->
           boundary_error `Bad_request error.kind "malformed workspace request"
         | Ok request ->
           operation_response
             (Service.workspace t.service request)
             Workspace.Response.sexp_of_t)
      | Ok body when String.equal path "/api/v1/asic" ->
        (match decode body Asic.Request.t_of_sexp with
         | Error error -> boundary_error `Bad_request error.kind "malformed ASIC request"
         | Ok request ->
           operation_response
             (Service.asic t.service request)
             (Asic.Evidence_metadata.sexp_of_response
                ~timing_analysis_header_value:
                  (Cohttp.Header.get
                     headers
                     Asic.Evidence_metadata.timing_analysis_header)
                ~execution_timing_header_value:
                  (Cohttp.Header.get headers Execution_timing.header)
                ~header_value:(Cohttp.Header.get headers Asic.Evidence_metadata.header)))
      | Ok body when String.equal path Preparation.rpc_path ->
        (match decode body Preparation.Request.t_of_sexp with
         | Error error ->
           boundary_error `Bad_request error.kind "malformed preparation request"
         | Ok request ->
           operation_response
             (Service.preparation t.service request)
             Preparation.Response.sexp_of_t)
      | Ok body when String.equal path Simulation.rpc_path ->
        (match decode body Simulation.Request.t_of_sexp with
         | Error error ->
           boundary_error `Bad_request error.kind "malformed simulation request"
         | Ok request ->
           operation_response
             (Service.simulation t.service request)
             (Simulation.Response.sexp_of_negotiated
                ~execution_timing_header_value:
                  (Cohttp.Header.get headers Execution_timing.header)))
      | Ok _ -> boundary_error `Not_found Not_found "unknown operation")
  | _ ->
    boundary_error
      `Bad_request
      Invalid_request
      "POST requires application/sexp and X-Workbench-Protocol: 1"
;;

let callback t ~body _peer request =
  let headers = Cohttp.Request.headers request in
  let host = Cohttp.Header.get headers "host" in
  match host with
  | None -> boundary_error `Bad_request Invalid_request "missing Host header"
  | Some host when not (loopback_host host) ->
    boundary_error `Bad_request Invalid_request "Host must name a loopback address"
  | Some host when not (valid_origin headers host) ->
    boundary_error `Bad_request Invalid_request "Origin does not match Host"
  | Some _ ->
    let path = Uri.path (Cohttp.Request.uri request) in
    let meth = Cohttp.Request.meth request in
    (match meth, path with
     | `GET, "/api/hello" -> sexp_response (V1.Hello.Response.sexp_of_t t.hello)
     | ( `POST
       , ( "/api/v1/snapshot"
         | "/api/v1/updates"
         | "/api/v1/open-project"
         | "/api/v1/submit-job"
         | "/api/v1/refresh-integration"
         | "/api/v1/generate-rtl"
         | "/api/v1/cancel-job"
         | "/api/v1/read-log"
         | "/api/v1/read-artifact"
         | "/api/v1/read-hierarchy"
         | "/api/v1/workspace"
         | "/api/v1/asic"
         | "/api/v1/simulation"
         | "/api/v1/preparation" ) ) -> handle_post t ~path ~headers ~body
     | _ -> boundary_error `Not_found Not_found "unknown endpoint or protocol version")
;;

let start t ~port =
  let where =
    Tcp.Where_to_listen.bind_to
      Tcp.Bind_to_address.Localhost
      (if port = 0
       then Tcp.Bind_to_port.On_port_chosen_by_os
       else Tcp.Bind_to_port.On_port port)
  in
  Cohttp_async.Server.create
    ~on_handler_error:
      (`Call (fun _ exn -> eprintf "HTTP handler failed: %s\n%!" (Exn.to_string exn)))
    where
    (callback t)
;;
