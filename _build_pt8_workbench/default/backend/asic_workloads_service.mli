open! Core
open! Async
open Hardcaml_workbench_protocol

type t
val create : state_dir:string -> identity:string -> t
val validate_query : Asic_workloads.Query.t -> unit
val validate_response : Asic_workloads.Query.t -> string -> Asic_workloads.Response.t
val select : t -> Asic_workloads.Query.t -> unit
val cached : t -> Asic_workloads.Query.t -> bool
val snapshot : t -> Asic_workloads.Snapshot.t
val publish : ?paths:string list -> ?check:(unit -> unit)
  -> t -> Asic_workloads.Query.t -> provider_identity:string -> string -> unit Deferred.t
val fail : t -> Asic_workloads.Query.t -> string -> unit
val check_capabilities : Asic_workloads.Query.t -> Yojson.Safe.t -> unit
val provider_identity : executable:string -> Asic_workloads.Query.t -> string
val check_separation : state_dir:string -> Asic_workloads.Query.t -> unit

(** Resolve only explicitly selected roots, never workload-relative members. Capture
    before and after the public read; validate the returned target/source binding. *)
val capture_targets : Asic_workloads.Query.t -> string list
val check_targets : Asic_workloads.Query.t -> paths:string list -> string -> unit
