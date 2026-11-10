(** One measured value read out of a tool report.

    Results are not a fixed resource record. A LUT/FF/DSP record cannot describe an ASIC
    run, and a bare number cannot be compared across tools or runs, so every metric
    carries the unit and the analysis context that make it comparable: the tool that
    produced it, the stage it came from, the corner or mode it applies to, and the report
    it was read from.

    A missing, unsupported, or unparseable metric is {!Value.Unavailable} with a recorded
    reason. It is never zero and never a pass — those are measurements, and an absent
    measurement must not be displayed as one.

    Timing is not a single number. Setup and hold are separate metrics, and a flow that
    analyses more than one corner reports one metric per corner; a single worst slack
    cannot represent a multi-corner run. *)

open! Core

module Value = struct
  type t =
    | Int of int
    | Float of float
    | Bool of bool
    | String of string
    | Unavailable of { reason : string }
  [@@deriving bin_io, compare, equal, sexp]

  let is_available = function
    | Int _ | Float _ | Bool _ | String _ -> true
    | Unavailable _ -> false
  ;;
end

type t =
  { name : string
  ; value : Value.t
  ; unit : string option (** [ns], [mW], [um^2], ...; [None] for dimensionless counts *)
  ; tool : Tool_version.t
  ; stage : string (** the stage that produced it *)
  ; corner : string option (** corner or mode, where the flow analyses more than one *)
  ; source : Artifact_id.t option
  (** the report it was read from; [None] only when the metric is unavailable because no
      report was produced *)
  }
[@@deriving bin_io, compare, equal, sexp]
