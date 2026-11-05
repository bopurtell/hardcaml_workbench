open! Core
type t
val physical : string -> string
val create : string -> t
val canonical : t -> string
val check : t -> unit
val read : t -> name:string -> max_bytes:int -> string option
(** All file writes are descriptor-bound. [before_write] checks separation before
    directory creation, file creation and replacement; alias/generation checks
    additionally reject changed cache locations. Calls are serialized by the owner. *)
val write : t -> name:string -> data:string -> before_write:(unit -> unit) -> unit
