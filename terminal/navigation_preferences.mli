open! Core

type member =
  { tile : string
  ; kind : string
  }

type artifact =
  { id : string
  ; sha256 : string option
  ; size : int option
  }

type testing =
  { attempt : string option
  ; case_id : string option
  ; artifact : artifact option
  }

type timing =
  { stage : string
  ; filter : string
  ; row_id : string option
  ; run : string option
  ; source_digest : string option
  ; analysis : Hardcaml_workbench_protocol.Asic_inspection.Analysis_target.t option
  }

(** [run] is the serialized stable run reference and [source_digest] identifies the
    evidence used for the row selection. Both are additive optional schema-1 fields:
    historical files decode with [None]. A row without matching run and source identity
    must not be trusted by the restoration caller. *)

type workspace =
  { id : string
  ; members : member list
  ; focus : string option
  ; testing : testing option
  ; timing : timing option
  }

type t =
  { schema_version : int
  ; project_key : string
  ; session : string
  ; active : string option
  ; workspaces : workspace list
  ; workloads : (string * Workloads_view.saved) list
  }

(** All operations raise on invalid data, following the other preference sidecars. IDs are
    opaque stable strings. Limits: 256 KiB encoded, 4096 bytes per string, 256 workspaces
    and 1024 total members. Optional IDs, when present, are nonempty; the timing filter
    may be empty. Focus and active must name saved members and workspaces; tile IDs are
    unique across workspaces. Case requires attempt, artifact requires attempt (case is
    optional), and artifact sizes must be nonnegative. *)
val create
  :  project_key:string
  -> session:string
  -> active:string option
  -> workspaces:workspace list
  -> t

val with_workloads : t -> (string * Workloads_view.saved) list -> t
val encode : t -> string
val decode : project_key:string -> string -> t

(** Absent files return [None]. Corrupt, oversized or identity-mismatched files raise and
    are left untouched. *)
val load : state_directory:string -> project_key:string -> t option

(** Validate before writing; publish by same-directory atomic rename. An invalid existing
    sidecar raises and is preserved rather than silently overwritten. I/O belongs on the
    caller's worker, as with waveform preferences. *)
val save : state_directory:string -> t -> unit
