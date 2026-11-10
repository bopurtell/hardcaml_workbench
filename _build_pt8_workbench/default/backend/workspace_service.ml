(** Daemon-authoritative workspace registry. One [t] per daemon/state directory. The
    caller validates RPC instance/project and supplies a canonical, stable key
    incorporating project root AND execution environment (never daemon/project ID). This
    module has no dependency on [Service] or provider persistence.

    [create] does no IO. [handle] serializes per project; blocking file operations run in
    the Async thread pool. Only successful atomic saves enter the cache. The state
    directory is single-writer: sharing it between daemons is unsupported. *)
open! Core

open! Async
open Hardcaml_workbench_protocol

module Stored = struct
  type t =
    { schema_version : int
    ; project_key : string
    ; snapshot : Workspace.Snapshot.t
    }
  [@@deriving sexp]
end

type entry =
  { mutable tail : unit Deferred.t
  ; mutable snapshot : Workspace.Snapshot.t option
  }

type t =
  { state_dir : string
  ; projects : entry String.Table.t
  }

let create ~state_dir = { state_dir; projects = String.Table.create () }

let digest value =
  Cryptokit.hash_string (Cryptokit.Hash.sha256 ()) value
  |> Cryptokit.transform_string (Cryptokit.Hexa.encode ())
;;

(** Public for diagnostics; opaque project keys never become path components. *)
let snapshot_path t ~project_key =
  Filename.concat t.state_dir ("workspace-" ^ digest project_key ^ ".sexp")
;;

let error kind message = Error (V1.Error.create kind message)

let read_snapshot t ~project_key =
  let path = snapshot_path t ~project_key in
  match Sys_unix.file_exists path with
  | `Unknown -> error Internal_failure ("Cannot inspect workspace snapshot: " ^ path)
  | `No -> Ok None
  | `Yes ->
    (try
       let stored = Sexp.of_string (In_channel.read_all path) |> Stored.t_of_sexp in
       if stored.schema_version <> Workspace.schema_version
       then error Invalid_request "Unsupported workspace storage schema"
       else if not (String.equal stored.project_key project_key)
       then error Conflict "Workspace snapshot belongs to a different project/environment"
       else
         Result.map (Workspace.validate stored.snapshot) ~f:(fun () ->
           Some stored.snapshot)
     with
     | exn ->
       error Invalid_request ("Cannot decode workspace snapshot: " ^ Exn.to_string exn))
;;

let save_snapshot t ~project_key snapshot =
  (* Includes embedded resolved definitions and provenance: never serialize a partially
     valid composition, even through a direct persistence caller. *)
  (match Workspace.validate snapshot with
   | Ok () -> ()
   | Error error -> raise_s [%message "Invalid workspace snapshot" (error : V1.Error.t)]);
  Core_unix.mkdir_p t.state_dir ~perm:0o700;
  let path = snapshot_path t ~project_key in
  (* A temp file in the same directory guarantees rename stays on one filesystem. *)
  let temp = Filename_unix.temp_file ~in_dir:t.state_dir ".workspace-" ".tmp" in
  Exn.protect
    ~finally:(fun () ->
      match Sys_unix.file_exists temp with
      | `Yes -> Core_unix.unlink temp
      | `No | `Unknown -> ())
    ~f:(fun () ->
      let stored : Stored.t =
        { schema_version = Workspace.schema_version; project_key; snapshot }
      in
      Out_channel.write_all
        temp
        ~data:(Sexp.to_string_hum (Stored.sexp_of_t stored) ^ "\n");
      let fd = Core_unix.openfile temp ~mode:[ O_RDONLY ] in
      Exn.protect
        ~finally:(fun () -> Core_unix.close fd)
        ~f:(fun () -> Core_unix.fsync fd);
      Core_unix.rename ~src:temp ~dst:path)
;;

let bootstrap t ~project_key =
  (* The temporary filename supplies a unique session identity, without deriving it from a
     transient daemon ID. It is removed immediately and never stores data. *)
  Core_unix.mkdir_p t.state_dir ~perm:0o700;
  let seed = Filename_unix.temp_file ~in_dir:t.state_dir ".session-" "" in
  Core_unix.unlink seed;
  let session_id =
    Workspace.Session_id.of_string
      (digest (project_key ^ seed ^ Time_float.to_string (Time_float.now ())))
  in
  Workspace.initial ~session_id
;;

let handle t ~project_key operation : Workspace.Response.t Deferred.t =
  if String.is_empty project_key
  then
    return (error Invalid_request "Workspace project key must include root/environment")
  else (
    let entry =
      Hashtbl.find_or_add t.projects project_key ~default:(fun () ->
        { tail = Deferred.unit; snapshot = None })
    in
    let previous = entry.tail in
    let finished = Ivar.create () in
    entry.tail <- Ivar.read finished;
    Monitor.protect
      ~finally:(fun () ->
        Ivar.fill_exn finished ();
        Deferred.unit)
      (fun () ->
        let%bind () = previous in
        Monitor.try_with (fun () ->
          let%bind loaded =
            match entry.snapshot with
            | Some snapshot -> return (Ok (Some snapshot))
            | None -> In_thread.run (fun () -> read_snapshot t ~project_key)
          in
          match loaded with
          | Error error -> return (Error error)
          | Ok loaded ->
            let%bind snapshot =
              match loaded with
              | Some snapshot -> return snapshot
              | None -> In_thread.run (fun () -> bootstrap t ~project_key)
            in
            (match Workspace.apply snapshot operation with
             | Error error -> return (Error error)
             | Ok next ->
               let needs_save =
                 Option.is_none loaded || next.revision <> snapshot.revision
               in
               let%map () =
                 if needs_save
                 then In_thread.run (fun () -> save_snapshot t ~project_key next)
                 else Deferred.unit
               in
               entry.snapshot <- Some next;
               Ok next))
        >>| function
        | Ok result -> result
        | Error exn ->
          error Internal_failure ("Workspace persistence failed: " ^ Exn.to_string exn)))
;;
