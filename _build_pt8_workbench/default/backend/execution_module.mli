open! Core
open! Async
open Hardcaml_workbench_protocol

(** FS0 generic Build/Test feature boundary over the existing supervisor. *)
type t

val of_service : Service.t -> t

(** Read one authoritative service snapshot and project its generic attempts and tests.
    Instance errors are preserved; an unopened project returns [Not_found]. *)
val snapshot
  :  t
  -> V1.Snapshot.Request.t
  -> project:Project_id.t
  -> (Execution.t, V1.Error.t) Result.t

val submit : t -> V1.Submit_job.Request.t -> V1.Submit_job.Response.t Deferred.t

(** Job-addressed operations retain the existing wire semantics for all supervised jobs,
    including driver jobs; they do not apply the generic snapshot filter. *)
val read_log : t -> V1.Read_log.Request.t -> V1.Read_log.Response.t Deferred.t

val cancel : t -> V1.Cancel_job.Request.t -> V1.Cancel_job.Response.t Deferred.t
