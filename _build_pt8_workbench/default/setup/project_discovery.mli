open! Core

(** Project-root resolution shared by the terminal opener and the setup commands.

    A project root is a directory directly containing a {e regular file} named
    [dune-project] (a symlink to a regular file counts, matching the daemon's opener). A
    directory containing only [dune], or a VCS root, is not a project root.

    Upward discovery first canonicalizes the starting directory with [realpath], then
    inspects that directory and each physical ancestor in turn up to [/], selecting the
    nearest one with the marker. Because symlinks are resolved before walking, a symlinked
    directory is searched from its target's ancestors, not from the ancestors of the
    logical (shell [$PWD]) path that contained the link. The resolved root is therefore
    already canonical and is the same session identity as passing it explicitly.

    Discovery only reads filesystem metadata: it never writes configuration, opens a
    project, or runs builds, drivers or providers. *)

(** The marker file name, [dune-project]. *)
val marker : string

module Discovered : sig
  type t =
    { start : string (** Canonical starting directory. *)
    ; root : string (** Nearest canonical ancestor (or [start]) with the marker. *)
    ; enclosing : string option
    (** The next enclosing project root above [root], if any; never selected. *)
    }
  [@@deriving sexp_of]
end

(** Search upward from [start] (default: the current directory). The walk stops at the
    first match, at [/], or at the first ancestor whose marker cannot be inspected (for
    example a directory without search permission): an unreadable ancestor is reported
    rather than skipped, so a farther root is never chosen past one that might be nearer.
    [explicit_flag] names the entrypoint's explicit-root flag for diagnostics. *)
val discover
  :  ?start:string
  -> explicit_flag:string
  -> unit
  -> (Discovered.t, string) Result.t

(** One-line human report of the selected root, including any enclosing project that
    nearest-wins selection passed over. *)
val describe : Discovered.t -> explicit_flag:string -> string

(** Validate an explicitly named root without any ancestor search: [realpath], must be a
    directory, and must directly contain a regular [dune-project]. Returns the canonical
    root. Error strings match the initializer's established messages. *)
val explicit_root : string -> (string, string) Result.t

(** Entry-point helper. An explicit root wins and is returned unchanged, so the caller
    keeps its existing validation; [discover = true] runs {!discover} from the current
    directory and also returns the {!describe} report; neither returns [None]. Both is an
    error. *)
val resolve
  :  explicit:string option
  -> discover:bool
  -> explicit_flag:string
  -> discover_flag:string
  -> (string option * string option, string) Result.t
