open! Core

(** Whether any directory entry exists at [path], including a dangling symlink. *)
val exists : string -> bool

(** The standard refusal message for an occupied destination. *)
val existing_error : string -> string

(** Publish [contents] at [path] (inside [directory]) using a fully written, fsynced
    same-directory temporary file and an atomic no-replace hard link. Any existing entry,
    including a symlink or one created concurrently, is refused and left untouched. The
    temporary file is always removed. *)
val publish
  :  directory:string
  -> path:string
  -> temporary_prefix:string
  -> contents:string
  -> (unit, string) Result.t
