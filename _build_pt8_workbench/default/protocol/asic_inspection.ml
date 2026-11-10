open! Core

module Analysis_target = struct
  (** Captured from one analysis observation. Never resolve this against newest evidence.
      The run travels on the operation; these fields fence its exact source. Legacy
      targets default to Signoff and use the registered main execution path. Timing
      targets name their exact source, which may be an immutable prefix rather than the
      main execution hashed by an inspection envelope. *)
  type t =
    { attempt_id : string
    ; occurrence_id : string
    ; analysis_id : string
    ; source_digest : string
    ; execution_sha256 : string
    ; stage : string [@sexp.default "signoff"] [@sexp_drop_default.equal]
    ; execution_file : string option [@sexp.default None] [@sexp_drop_default.equal]
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Row = struct
  type t =
    { id : string
    ; category : string
    ; producer : string
    ; corner : string option
    ; group : string option
    ; name : string
    ; value : float option
    ; unit_ : string option
    ; status : string
    ; source : string
    ; fields : (string * string) list
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Index = struct
  type t =
    { run : Run_ref.t
    ; execution_file : string
    ; execution_sha256 : string
    ; domain : string
    ; stage : string
    ; source_digest : string
    ; rows : Row.t list
    ; diagnostics : string list
    ; truncated : bool
    ; cached_unverified : bool
    ; analysis : Analysis_target.t option [@sexp.default None] [@sexp_drop_default.equal]
    ; times : Evidence_time.Index.t
         [@sexp.default Evidence_time.Index.empty] [@sexp_drop_default.equal]
    (** Typed production/observation times. Freshness stays in [cached_unverified]: a
        displayed time never implies validation. Omitted from sexp when empty, so derived
        caches written before timestamps keep their content digests. *)
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Detail = struct
  type t =
    { run : Run_ref.t
    ; domain : string
    ; stage : string
    ; source_digest : string
    ; row_id : string
    ; text : string
    ; error : string option
    }
  [@@deriving bin_io, compare, equal, sexp]
end

(** Canonical sexp identities avoid collisions from punctuation in run/row IDs. All
    consumers use these same keys for scheduling and completion waits. *)
let index_key ~run ~domain ~stage =
  "inspection:"
  ^ Sexp.to_string_mach [%sexp (run : Run_ref.t), (domain : string), (stage : string)]
;;

let detail_key ~run ~domain ~stage ~source_digest ~row_id =
  "inspection-detail:"
  ^ Sexp.to_string_mach
      [%sexp
        (run : Run_ref.t)
        , (domain : string)
        , (stage : string)
        , (source_digest : string)
        , (row_id : string)]
;;

let analysis_index_key ~run ~target =
  "analysis:"
  ^ Sexp.to_string_mach [%sexp (run : Run_ref.t), (target : Analysis_target.t)]
;;

let analysis_detail_key ~run ~target ~source_digest ~row_id =
  "analysis-detail:"
  ^ Sexp.to_string_mach
      [%sexp
        (run : Run_ref.t)
        , (target : Analysis_target.t)
        , (source_digest : string)
        , (row_id : string)]
;;
