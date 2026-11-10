open! Core
open! Async
open Hardcaml_workbench_protocol

(** Bounded derived cache, independent of physical run registration. Descriptor/index
    persistence is Workbench-owned; restored evidence is always unverified. *)
type t

val create : state_dir:string -> identity:string -> t
val snapshot : t -> Asic_resources.Snapshot.t
val cache_error : t -> string option
val source : t -> string -> Asic_resources.Source.t
val cached : t -> Asic_resources.Target.t -> bool
val invalidate_run : t -> Run_ref.t -> unit
val fail : t -> Asic_resources.Target.t -> string -> unit

val parse_index : Asic_resources.Source.t -> Yojson.Safe.t -> Asic_resources.Index.t

(** Check the native CLI's status and verdict together, for indexes and all page
    kinds. Exit 0 permits pass/not_evaluated; exit 1 permits only fail. *)
val parse_process_result : Asic_process.Output.t -> Yojson.Safe.t

(** Callers serialize publication and coalesce operations. [check] fences the captured
    target immediately before publication. [query] is a bounded read-only provider call;
    process-backed callers must use [run_with_status] and [parse_process_result] before
    returning its JSON. A successful load clears an active cache diagnostic only after
    its atomic cache replacement completes. *)
val load
  : t -> target:Asic_resources.Target.t -> kind:string -> path:string
  -> provider_identity:string -> check:(unit -> unit)
  -> query:(string list -> Yojson.Safe.t Deferred.t) -> unit Deferred.t

val page
  : t -> Asic_resources.Operation.t -> check:(unit -> unit)
  -> query:(string list -> Yojson.Safe.t Deferred.t) -> unit Deferred.t
