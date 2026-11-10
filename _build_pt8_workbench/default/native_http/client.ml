open! Core
open! Async
module Runtime_error = Error
open Hardcaml_workbench_protocol

type t =
  { endpoint : Uri.t
  ; timeout : Time_float.Span.t
  }

let create ?(timeout = Time_float.Span.of_sec 35.) endpoint =
  { endpoint = Uri.of_string endpoint; timeout }
;;

let endpoint t = Uri.to_string t.endpoint
let uri t path = Uri.with_path t.endpoint path

let read_body response body =
  let pipe = Cohttp_async.Body.to_pipe body in
  let rec loop chunks bytes =
    match%bind Pipe.read pipe with
    | `Eof -> return (String.concat (List.rev chunks))
    | `Ok chunk ->
      let bytes = bytes + String.length chunk in
      if bytes > 32 * 1024 * 1024
      then (
        Pipe.close_read pipe;
        failwith "Workbench response exceeded 32 MiB");
      loop (chunk :: chunks) bytes
  in
  let%map body = loop [] 0 in
  Cohttp.Response.status response, body
;;

let bounded t f =
  let interrupt = Clock.after t.timeout in
  Clock.with_timeout t.timeout (Monitor.try_with_or_error (fun () -> f interrupt))
  >>| function
  | `Timeout -> Or_error.error_string "Workbench HTTP request timed out"
  | `Result result -> Or_error.join result
;;

let request_error status body =
  Or_error.error_s
    [%message
      "Workbench HTTP request failed"
        (Cohttp.Code.code_of_status status : int)
        (body : string)]
;;

let hello t =
  bounded t (fun interrupt ->
    let%bind response, body = Cohttp_async.Client.get ~interrupt (uri t "/api/hello") in
    let%map status, body = read_body response body in
    if Cohttp.Code.code_of_status status = 200
    then
      V1.Codec.decode V1.Hello.Response.t_of_sexp body
      |> Result.map_error ~f:(fun error ->
        Runtime_error.create_s [%message error.message])
    else request_error status body)
;;

let post ?(extra_headers = []) t ~path ~sexp_of_request ~response_of_sexp request =
  bounded t (fun interrupt ->
    let headers =
      Cohttp.Header.of_list
        ([ "content-type", V1.content_type
         ; String.lowercase V1.protocol_header, Int.to_string V1.version
         ]
         @ extra_headers)
    in
    let body = V1.Codec.encode sexp_of_request request |> Cohttp_async.Body.of_string in
    let%bind response, body =
      Cohttp_async.Client.post ~interrupt ~headers ~body (uri t path)
    in
    let%map status, body = read_body response body in
    if Cohttp.Code.code_of_status status = 200
    then
      V1.Codec.decode response_of_sexp body
      |> Result.map_error ~f:(fun error ->
        Runtime_error.create_s [%message error.message])
    else request_error status body)
;;

let snapshot t request =
  post
    t
    ~path:"/api/v1/snapshot"
    ~sexp_of_request:V1.Snapshot.Request.sexp_of_t
    ~response_of_sexp:V1.Snapshot.Response.t_of_sexp
    request
;;

let updates t request =
  post
    t
    ~path:"/api/v1/updates"
    ~sexp_of_request:V1.Updates.Request.sexp_of_t
    ~response_of_sexp:V1.Updates.Response.t_of_sexp
    request
;;

let open_project t request =
  post
    t
    ~path:"/api/v1/open-project"
    ~sexp_of_request:V1.Open_project.Request.sexp_of_t
    ~response_of_sexp:V1.Open_project.Response.t_of_sexp
    request
;;

let submit_job t request =
  post
    t
    ~path:"/api/v1/submit-job"
    ~sexp_of_request:V1.Submit_job.Request.sexp_of_t
    ~response_of_sexp:V1.Submit_job.Response.t_of_sexp
    request
;;

let refresh_integration t request =
  post
    t
    ~path:"/api/v1/refresh-integration"
    ~sexp_of_request:V1.Refresh_integration.Request.sexp_of_t
    ~response_of_sexp:V1.Refresh_integration.Response.t_of_sexp
    request
;;

let generate_rtl t request =
  post
    t
    ~path:"/api/v1/generate-rtl"
    ~sexp_of_request:V1.Generate_rtl.Request.sexp_of_t
    ~response_of_sexp:V1.Generate_rtl.Response.t_of_sexp
    request
;;

let cancel_job t request =
  post
    t
    ~path:"/api/v1/cancel-job"
    ~sexp_of_request:V1.Cancel_job.Request.sexp_of_t
    ~response_of_sexp:V1.Cancel_job.Response.t_of_sexp
    request
;;

let read_log t request =
  post
    t
    ~path:"/api/v1/read-log"
    ~sexp_of_request:V1.Read_log.Request.sexp_of_t
    ~response_of_sexp:V1.Read_log.Response.t_of_sexp
    request
;;

let read_artifact t request =
  post
    t
    ~path:"/api/v1/read-artifact"
    ~sexp_of_request:V1.Read_artifact.Request.sexp_of_t
    ~response_of_sexp:V1.Read_artifact.Response.t_of_sexp
    request
;;

let read_hierarchy t request =
  post
    t
    ~path:"/api/v1/read-hierarchy"
    ~sexp_of_request:V1.Read_hierarchy.Request.sexp_of_t
    ~response_of_sexp:V1.Read_hierarchy.Response.t_of_sexp
    request
;;

let workspace t request =
  post
    t
    ~path:"/api/v1/workspace"
    ~sexp_of_request:Workspace.Request.sexp_of_t
    ~response_of_sexp:Workspace.Response.t_of_sexp
    request
;;

let asic t request =
  post
    ~extra_headers:
      [ Asic.Evidence_metadata.header, Asic.Evidence_metadata.version
      ; ( Asic.Evidence_metadata.timing_analysis_header
        , Asic.Evidence_metadata.timing_analysis_version )
      ; Execution_timing.header, Execution_timing.version
      ]
    t
    ~path:"/api/v1/asic"
    ~sexp_of_request:Asic.Request.sexp_of_t
    ~response_of_sexp:Asic.Response.t_of_sexp
    request
;;

let simulation t request =
  post
    ~extra_headers:[ Execution_timing.header, Execution_timing.version ]
    t
    ~path:Simulation.rpc_path
    ~sexp_of_request:Simulation.Request.sexp_of_t
    ~response_of_sexp:Simulation.Response.t_of_sexp
    request
;;

let preparation t request =
  post
    t
    ~path:Preparation.rpc_path
    ~sexp_of_request:Preparation.Request.sexp_of_t
    ~response_of_sexp:Preparation.Response.t_of_sexp
    request
;;
