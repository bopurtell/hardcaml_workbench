(** A structural hierarchy exported by one project-side elaboration.

    This is an instance tree with minimal port metadata, not the Phase 3 signal/operator
    graph. Structural keys are meaningful only within one hierarchy artifact. *)

open! Core

module Port = struct
  type t =
    { name : string
    ; width : int
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Metadata = struct
  type t =
    { name : string
    ; value : string
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Node = struct
  type t =
    { key : string
    ; parent : string option
    ; instance_name : string option
    ; circuit_name : string
    ; input_ports : Port.t list
    ; output_ports : Port.t list
    ; metadata : Metadata.t list
    }
  [@@deriving bin_io, compare, equal, sexp]
end

type t =
  { artifact : Artifact_id.t
  ; project : Project_id.t
  ; target : Target_id.t
  ; configuration : Configuration_id.t
  ; generating_job : Job_id.t
  ; rtl_artifacts : Artifact_id.t list
  ; provenance : Provenance.t
  ; root : string
  ; nodes : Node.t list
  }
[@@deriving bin_io, compare, equal, sexp]
