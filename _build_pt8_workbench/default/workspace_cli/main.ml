(** Operates only on an already-open project's registry. No project discovery, provider
    requests, job submission or automatic conflict retries. *)
open! Core

open! Async
open Hardcaml_workbench_protocol
module Client = Hardcaml_workbench_native_http.Client
module W = Workspace
module T = Workspace_template
module C = Workspace_config
module Presets = Hardcaml_workbench_workspaces.Presets

let protocol_ok = function
  | Ok value -> value
  | Error (error : V1.Error.t) -> raise_s [%sexp (error : V1.Error.t)]
;;

let connection =
  let open Command.Let_syntax in
  let%map_open endpoint = flag "-endpoint" (required string) ~doc:"URL Running daemon URL"
  and project = flag "-project" (required string) ~doc:"ID Already-open project ID" in
  Client.create endpoint, Project_id.of_string project
;;

let connect (client, project) =
  let%bind hello = Client.hello client >>| Or_error.ok_exn in
  let request operation =
    Client.workspace
      client
      { W.Request.instance_id = hello.instance_id; project; operation }
    >>| Or_error.ok_exn
    >>| protocol_ok
  in
  let%map snapshot = request Get in
  snapshot, request
;;

let emit template =
  let text = T.encode template |> Or_error.ok_exn in
  Writer.write (Lazy.force Writer.stdout) text
;;

let list =
  Command.async
    ~summary:"List window and workspace IDs and names for an already-open project"
    (let open Command.Let_syntax in
     let%map_open connection in
     fun () ->
       let open Deferred.Let_syntax in
       let%map snapshot, _ = connect connection in
       List.iter snapshot.windows ~f:(fun window ->
         printf "window\t%s\t%S\n" (W.Window_id.to_string window.id) window.name;
         List.iter snapshot.workspaces ~f:(fun workspace ->
           if W.Window_id.equal workspace.window window.id
           then
             printf
               "  workspace\t%s\t%S\n"
               (W.Workspace_id.to_string workspace.id)
               workspace.name)))
;;

let export =
  Command.async
    ~summary:"Export a workspace's portable layout to stdout"
    (let open Command.Let_syntax in
     let%map_open connection
     and source = anon ("WORKSPACE-ID" %: string) in
     fun () ->
       let open Deferred.Let_syntax in
       let%map snapshot, _ = connect connection in
       W.export_template snapshot (W.Workspace_id.of_string source) |> protocol_ok |> emit)
;;

let instantiate
  (snapshot : W.Snapshot.t)
  (request : W.Operation.t -> W.Snapshot.t Deferred.t)
  ~window
  ~name
  template
  =
  let template =
    match name with
    | None -> template
    | Some name -> { template with T.name }
  in
  T.validate template |> Or_error.ok_exn;
  let%map next =
    request
      (W.Operation.Mutate
         { expected_revision = snapshot.W.Snapshot.revision
         ; mutation =
             Instantiate_template { window = W.Window_id.of_string window; template }
         })
  in
  let created =
    List.find_exn next.workspaces ~f:(fun w ->
      not
        (List.exists snapshot.workspaces ~f:(fun old -> W.Workspace_id.equal old.id w.id)))
  in
  printf "%s\n" (W.Workspace_id.to_string created.id)
;;

let destination =
  let open Command.Let_syntax in
  let%map_open window = flag "-window" (required string) ~doc:"ID Destination window ID"
  and name =
    flag "-name" (optional string) ~doc:"NAME Override template workspace name"
  in
  window, name
;;

(** Read at most one byte beyond the accepted size, including for growing files or
    streams. [with_file] closes the descriptor on both success and size rejection. *)
let read_bounded_file ~max_bytes ~description file =
  Reader.with_file file ~f:(fun reader ->
    let buffer = Bytes.create (max_bytes + 1) in
    let%map result = Reader.really_read reader buffer in
    match result with
    | `Ok ->
      let limit =
        if max_bytes mod (1024 * 1024) = 0
        then Int.to_string (max_bytes / (1024 * 1024)) ^ " MiB"
        else Int.to_string max_bytes ^ " bytes"
      in
      failwith (description ^ " exceeds " ^ limit)
    | `Eof length -> Bytes.sub buffer ~pos:0 ~len:length |> Bytes.to_string)
;;

let read_template_file =
  read_bounded_file ~max_bytes:T.max_encoded_bytes ~description:"Workspace template"
;;

let config_result ~context = function
  | Ok value -> value
  | Error error -> failwith (context ^ ": " ^ Error.to_string_hum error)
;;

(** The complete file is decoded and all built-ins are resolved before opening a daemon
    connection. Checking encoded size also bounds catalog expansion. *)
let load_config file =
  let%map text =
    read_bounded_file
      ~max_bytes:C.max_encoded_bytes
      ~description:"Workspace configuration"
      file
  in
  let config =
    Presets.decode text |> config_result ~context:("Invalid configuration " ^ file)
  in
  let resolved =
    Presets.resolve config
    |> config_result ~context:("Cannot resolve configuration " ^ file)
  in
  C.Resolved.encode resolved |> config_result ~context:"Resolved configuration" |> ignore;
  resolved
;;

let config_action action () =
  let%bind result = Monitor.try_with action in
  match result with
  | Ok () -> Deferred.unit
  | Error exn ->
    let message = Exn.to_string exn in
    (* Parser errors can include offending input. Keep the diagnostic bounded too. *)
    let message =
      if String.length message > 4096 then String.prefix message 4096 ^ "..." else message
    in
    eprintf "workspace config: %s\n" message;
    Shutdown.exit 1
;;

let apply_config (snapshot : W.Snapshot.t) request config =
  request
    (W.Operation.Mutate
       { expected_revision = snapshot.revision
       ; mutation = W.Mutation.Apply_config config
       })
;;

(** Both exports originate in the catalog's embedded canonical S-expression files. Stock
    output retains the complete reserved catalog, including uninstantiated definitions.
    [Presets.decode] checks their identity when reading it back. *)
let config_commands =
  let validate =
    Command.async
      ~summary:"Validate a composition and resolve built-ins (offline)"
      (let open Command.Let_syntax in
       let%map_open file = anon ("CONFIG.sexp" %: string) in
       config_action (fun () ->
         let open Deferred.Let_syntax in
         let%map config = load_config file in
         let workspaces =
           List.sum (module Int) config.windows ~f:(fun w -> List.length w.workspaces)
         in
         printf
           "Valid configuration %s: %d windows, %d workspaces, %d resolved definitions\n"
           config.id
           (List.length config.windows)
           workspaces
           (List.length config.definitions)))
  in
  let export =
    Command.async
      ~summary:
        "Write the complete stock or canonical custom example composition (offline)"
      (let open Command.Let_syntax in
       let%map_open kind = anon (maybe_with_default "stock" ("KIND" %: string))
       and id =
         flag "-id" (optional string) ~doc:"KEY Override stable configuration ID"
       in
       config_action (fun () ->
         let config, encode =
           (match kind with
            | "stock" ->
              Or_error.bind (Presets.export_config ()) ~f:(fun text ->
                Or_error.map (C.Resolved.decode text) ~f:(fun config ->
                  config, C.Resolved.encode))
            | "example" ->
              Or_error.map (Presets.custom_example ()) ~f:(fun config -> config, C.encode)
            | _ -> Or_error.error_string "Expected stock or example")
           |> config_result ~context:"Cannot export configuration"
         in
         let config =
           match id with
           | None -> config
           | Some id -> { config with C.id }
         in
         let text =
           encode config |> config_result ~context:"Cannot encode configuration"
         in
         (* Ensure the exported authoring file is independently usable. *)
         Presets.decode text
         |> Or_error.bind ~f:Presets.resolve
         |> config_result ~context:"Cannot resolve exported configuration"
         |> C.Resolved.encode
         |> config_result ~context:"Resolved exported configuration"
         |> ignore;
         Writer.write (Lazy.force Writer.stdout) text;
         Deferred.unit))
  in
  let apply_command =
    Command.async
      ~summary:
        "Atomically add missing keyed windows/workspaces to an already-open project"
      (let open Command.Let_syntax in
       let%map_open connection
       and file = anon ("CONFIG.sexp" %: string) in
       config_action (fun () ->
         let open Deferred.Let_syntax in
         let%bind config = load_config file in
         let%bind snapshot, request = connect connection in
         let%map (next : W.Snapshot.t) = apply_config snapshot request config in
         printf "Applied configuration %s at revision %d\n" config.id next.revision))
  in
  Command.group
    ~summary:
      "Versioned window/workspace compositions; offline authoring and explicit additive \
       apply"
    [ "validate", validate; "export", export; "apply", apply_command ]
;;

let import =
  Command.async
    ~summary:"Instantiate a template file atomically; print the new workspace ID"
    (let open Command.Let_syntax in
     let%map_open connection
     and destination
     and file = anon ("TEMPLATE.sexp" %: string) in
     fun () ->
       let open Deferred.Let_syntax in
       let%bind text = read_template_file file in
       let template = T.decode text |> Or_error.ok_exn in
       let%bind snapshot, request = connect connection in
       let window, name = destination in
       instantiate snapshot request ~window ~name template)
;;

let clone =
  Command.async
    ~summary:"Clone a workspace layout into a new Main-linked workspace"
    (let open Command.Let_syntax in
     let%map_open connection
     and destination
     and source = anon ("WORKSPACE-ID" %: string) in
     fun () ->
       let open Deferred.Let_syntax in
       let%bind snapshot, request = connect connection in
       let window, name = destination in
       let template =
         W.export_template ?name snapshot (W.Workspace_id.of_string source) |> protocol_ok
       in
       instantiate snapshot request ~window ~name template)
;;

let starter =
  Command.async
    ~summary:"Write a generic, asic or built-in portable starter (offline)"
    (let open Command.Let_syntax in
     let%map_open kind = anon ("PRESET" %: string) in
     fun () ->
       emit
         (match kind with
           | "generic" -> T.generic
           | "asic" -> T.asic
           | id -> (Presets.builtins id |> Or_error.ok_exn).template);
       Deferred.unit)
;;

let () =
  Command_unix.run
    (Command.group
       ~summary:"Portable, versioned workspace layouts"
       [ "list", list
       ; "export", export
       ; "import", import
       ; "clone", clone
       ; "starter", starter
       ; "config", config_commands
       ])
;;
