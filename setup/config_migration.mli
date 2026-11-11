open! Core

(** Byte-preserving copies only; legacy files are never removed or rewritten. *)
type t

val prepare : root:string -> (t, string) Result.t
val preview : t -> string
val publish : t -> (unit, string) Result.t

(** Shared common-directory support for new configuration writers. *)
val require_absent : root:string -> filename:string -> (unit, string) Result.t

val ensure_common_directory : root:string -> (string, string) Result.t
