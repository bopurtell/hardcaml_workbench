open! Core
open Hardcaml_workbench_protocol

(** Successful detail LRU. Limits are per project, independent of snapshot publications.
    Bytes count canonical serialized Detail payloads, excluding heap/key overhead. Either
    zero limit disables reuse. *)
type t

val validate_limits : entries:int -> bytes:int -> unit
val create : entries:int -> bytes:int -> t
val retain : t -> f:(identity:string -> Asic_inspection.Detail.t -> bool) -> unit
val find : t -> string -> Asic_inspection.Detail.t option
val add : t -> identity:string -> Asic_inspection.Detail.t -> unit
