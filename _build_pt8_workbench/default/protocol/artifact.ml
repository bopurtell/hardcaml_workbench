(** A generated output, treated as a typed artifact rather than a file on disk.

    The backend stores each artifact's filesystem location privately. Nothing in this type
    is a path or a handle: a client receives the identifier, the kind, the availability,
    and the metadata, and retrieves content from the daemon by identifier. That is what
    lets the browser client work at all, and it keeps the terminal client from reaching
    around the daemon because it happens to be native.

    Artifact kinds are open. A closed variant would force a protocol revision for every
    backend: the FPGA vocabulary is one namespace, and an ASIC flow adds GDS, LEF/DEF,
    SDC, netlists, build manifests, and physical-verification reports. The UI selects a
    viewer from the kind, and an unrecognized kind stays retrievable. *)

open! Core

module Role = struct
  (** What the artifact is for, independently of its format. The UI groups by role, so a
      backend that introduces a new kind still lands somewhere sensible. *)
  type t =
    | Source
    | Report
    | Log
    | Collateral
    | Deliverable
  [@@deriving bin_io, compare, equal, enumerate, hash, sexp]

  let to_string t = Sexp.to_string (sexp_of_t t)
end

module Kind = struct
  type t =
    { namespace : string (** [hardcaml], [vivado], [librelane], [tt], ... *)
    ; name : string (** [verilog], [gds], [lef], [def], [sdc], [netlist], ... *)
    ; role : Role.t
    ; media : string option (** the concrete format, where it is known *)
    }
  [@@deriving bin_io, compare, equal, hash, sexp]

  let to_string t = t.namespace ^ "." ^ t.name
end

module Availability = struct
  (** Whether the artifact's content can still be retrieved.

      An artifact is registered when its generating job reports it, and its content can
      disappear afterwards — a cleaned build directory, a removed scratch area. A client
      must show [Unavailable] as such rather than as an empty artifact. *)
  type t =
    | Available
    | Unavailable of { reason : string }
  [@@deriving bin_io, compare, equal, sexp]
end

module Metadata = struct
  (** Public description of an artifact. Deliberately carries no filesystem path: a
      daemon-local path is not a portable protocol value and must not become one. *)
  type t =
    { display_name : string
    ; description : string option
    ; size_in_bytes : int option
    ; provenance : Provenance.t
    }
  [@@deriving bin_io, compare, equal, sexp]
end

type t =
  { id : Artifact_id.t
  ; kind : Kind.t
  ; project : Project_id.t
  ; target : Target_id.t option (** absent for artifacts of generic project actions *)
  ; configuration : Configuration_id.t option
  ; generating_job : Job_id.t
  ; build : Build_ref.t option
  ; run : Run_ref.t option
  ; availability : Availability.t
  ; metadata : Metadata.t
  }
[@@deriving bin_io, compare, equal, sexp]

let is_available t =
  match t.availability with
  | Available -> true
  | Unavailable _ -> false
;;
