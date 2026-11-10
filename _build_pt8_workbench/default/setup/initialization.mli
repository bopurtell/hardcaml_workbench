open! Core

(** A validated initialization plan. Preparing one only reads filesystem metadata. *)
type t

(** [root] must explicitly name an existing directory directly containing a regular
    [dune-project] file, matching the project opener. Relative roots are resolved against
    the current directory; [prepare] performs no ancestor search (callers may resolve a
    root first with {!Project_discovery.discover}). The default project name is the root's
    basename. Options use the existing manifest parser's validation rules. Any existing
    entry at the manifest path, including a dangling symlink, is an error. *)
val prepare
  :  root:string
  -> ?project_name:string
  -> ?driver:string
  -> ?build_alias:string
  -> ?test_alias:string
  -> unit
  -> (t, string) Result.t

val root : t -> string
val path : t -> string
val contents : t -> string

(** Publish a fully written file using a same-directory temporary file and an atomic
    no-replace hard link. A concurrent creator always wins without being overwritten. No
    build, driver, provider or git command is invoked. *)
val publish : t -> (unit, string) Result.t
