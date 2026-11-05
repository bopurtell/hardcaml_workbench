open! Core

module Target = struct
  type t = Bundle of string | Coarse_run of string | Execution of string
  [@@deriving bin_io, compare, equal, sexp]
end

module Axis = struct
  type t = Hardware | Resource_policy | Flow_configuration | Descriptive
  [@@deriving bin_io, compare, equal, sexp]
end

module Query = struct
  type t =
    | Inspect of { result : string; expected_digest : string option }
    | Compare of
        { left : Target.t
        ; right : Target.t
        ; axis : Axis.t
        ; left_workload : string option
        ; right_workload : string option
        ; expected_left_digest : string option
        ; expected_right_digest : string option
        ; expected_left_workload_digest : string option
        ; expected_right_workload_digest : string option
        }
  [@@deriving bin_io, compare, equal, sexp]
end

module Operation = struct
  type t = Load of { query : Query.t; refresh : bool }
  [@@deriving bin_io, compare, equal, sexp]

  let key (Load { query; refresh = _ }) =
    "workloads:" ^ Sexp.to_string_mach (Query.sexp_of_t query)
  ;;
end

module Freshness = struct
  type t = Validated | Cached_unverified | Refresh_failed of string
  [@@deriving bin_io, compare, equal, sexp]
end

module Descriptor = struct
  type t =
    { key : string
    ; query : Query.t
    ; digest : string option
    ; provider_identity : string option
    ; freshness : Freshness.t
    ; error : string option
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Response = struct
  type t = { key : string; digest : string; json : string }
  [@@deriving bin_io, compare, equal, sexp]
end

module Snapshot = struct
  type t =
    { entries : Descriptor.t list
    ; selected : Response.t option
    ; cache_error : string option
    }
  [@@deriving bin_io, compare, equal, sexp]

  let empty = { entries = []; selected = None; cache_error = None }
end
