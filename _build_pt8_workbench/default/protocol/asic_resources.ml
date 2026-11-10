open! Core

module Target = struct
  type t =
    | Workflow_bundle of string
    | Run of Run_ref.t
    | Finalization of { run : Run_ref.t; attempt : string }
    | Coarse_run of string
    | Bundle of string
  [@@deriving bin_io, compare, equal, sexp]
end

module Freshness = struct
  type t =
    | Validated
    | Cached_unverified
    | Missing_source of string
    | Stale of string
    | Refresh_failed of string
    | Unsupported of string
  [@@deriving bin_io, compare, equal, sexp]
end

module Source = struct
  type t =
    { id : string
    ; target : Target.t
    ; kind : string
    ; path : string
    ; label : string
    ; provider_identity : string
    ; freshness : Freshness.t
    ; error : string option
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Measurement = struct
  module Classification = struct
    type t = Observed | Derived | Estimate | Unknown
    [@@deriving bin_io, compare, equal, sexp]
  end

  type t =
    { name : string
    ; value : float option
    ; unit_ : string
    ; stage : string
    ; definition : string
    ; scope : string
    ; reason : string option
    ; classification : Classification.t [@sexp.default Classification.Unknown]
        [@sexp_drop_default.equal]
    }
  [@@deriving bin_io, compare, equal, sexp]

  let compatible a b =
    String.equal a.name b.name
    && String.equal a.unit_ b.unit_
    && String.equal a.stage b.stage
    && String.equal a.definition b.definition
    && String.equal a.scope b.scope
    && Classification.equal a.classification b.classification
  ;;

  let is_measured t =
    match t.classification with
    | Classification.Observed | Derived -> true
    | Estimate | Unknown -> false
  ;;
end

module Section = struct
  type t = { id : string; count : int; status : string }
  [@@deriving bin_io, compare, equal, sexp]
end

module Row = struct
  type t =
    { id : string
    ; contract : string
    ; requirement : string
    ; policy : string
    ; implementation : string
    ; reason : string
    ; role : string
    ; instances : string list
    ; synthesis : string
    ; final : string
    ; measurements : Measurement.t list
    ; sections : Section.t list
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Inventory_status = struct
  type t = Available | Unavailable | Unknown
  [@@deriving bin_io, compare, equal, sexp]
end

module Index = struct
  type t =
    { source_id : string
    ; digest : string
    ; provenance : string
    ; rows : Row.t list
    ; measurements : Measurement.t list
    ; artifact_count : int
    ; diagnostics : string list
    ; truncated : bool
    ; verdict : string
    ; inventory_status : Inventory_status.t [@sexp.default Inventory_status.Unknown]
        [@sexp_drop_default.equal]
    ; inventory_reason : string option [@sexp.default None] [@sexp_drop_default.equal]
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Item = struct
  type t = { id : string; title : string; fields : (string * string) list }
  [@@deriving bin_io, compare, equal, sexp]
end

module Detail = struct
  type t =
    { source_id : string
    ; digest : string
    ; resource_id : string
    ; section : string
    ; offset : int
    ; next_offset : int
    ; total : int
    ; items : Item.t list
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Artifact = struct
  type t = { id : string; label : string; sha256 : string; format : string }
  [@@deriving bin_io, compare, equal, sexp]
end

module Artifacts = struct
  type t =
    { source_id : string
    ; digest : string
    ; offset : int
    ; next_offset : int
    ; total : int
    ; entries : Artifact.t list
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Bytes = struct
  type t =
    { source_id : string
    ; digest : string
    ; artifact_id : string
    ; sha256 : string
    ; offset : int
    ; next_offset : int
    ; total : int
    ; bytes_hex : string
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Operation = struct
  type t =
    | Load of { target : Target.t; refresh : bool }
    | Detail of
        { source_id : string; expected_digest : string; resource_id : string
        ; section : string; offset : int; limit : int }
    | Artifacts of
        { source_id : string; expected_digest : string; offset : int; limit : int }
    | Read_artifact of
        { source_id : string; expected_digest : string; artifact_id : string
        ; offset : int; limit : int }
  [@@deriving bin_io, compare, equal, sexp]

  let key t =
    let t = match t with Load { target; _ } -> Load { target; refresh = false } | t -> t in
    "resources:" ^ Sexp.to_string_mach (sexp_of_t t)
end

module Snapshot = struct
  type t =
    { sources : Source.t list
    ; indexes : Index.t list
    ; details : Detail.t list
    ; artifacts : Artifacts.t list
    ; bytes : Bytes.t list
    }
  [@@deriving bin_io, compare, equal, sexp]

  let empty = { sources = []; indexes = []; details = []; artifacts = []; bytes = [] }
end
