open! Core

type location =
  | Common
  | Legacy
[@@deriving compare, equal, sexp]

type resolved =
  { path : string
  ; contents : string
  ; location : location
  }

val preferred_path : root:string -> filename:string -> string
val legacy_path : root:string -> filename:string -> string

(* Shared ceiling for every configuration read, including schema-independent migration.
   Schema-specific callers may impose a smaller limit. *)
val max_config_bytes : int

(** Read a schema's unchanged basename from [.workbench/] or the project root.
    Both may exist only when their bytes are identical; the common path wins.
    Missing files return [Ok None]. Unsafe entries, inspection/read failures and
    conflicts return [Error], never legacy fallback. Files and path components
    must not be symlinks. The caller parses [contents] using its own schema.
    The effective limit is the smaller of [max_bytes] and [max_config_bytes].
    Descriptor/path device, inode and change metadata are checked before/after reading;
    both candidate path observations (including absence) are revalidated before return.
    These bounded checks detect observed races, not an atomic filesystem snapshot.
    This does not change the base for paths contained in the configuration. *)
val resolve
  :  root:string
  -> filename:string
  -> max_bytes:int
  -> resolved option Or_error.t

module For_testing : sig
  type event =
    | Opened of string
    | Read of string
    | Loaded_pair

  (** Deterministic mutation points for testing the production resolution fences. *)
  val resolve
    :  root:string
    -> filename:string
    -> max_bytes:int
    -> on_event:(event -> unit)
    -> resolved option Or_error.t
end
