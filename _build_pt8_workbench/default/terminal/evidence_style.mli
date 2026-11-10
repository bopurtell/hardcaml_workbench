open! Core
open Hardcaml_workbench_protocol

module Role : sig
  type t =
    | Plain
    | Muted
    | Validated
    | Passed
    | Failed
    | Pending
    | Running
    | Stale
  [@@deriving equal, sexp]
end

module Field : sig
  type t =
    | Operation
    | Physical_completion
    | Verdict
    | Summary_completion
  [@@deriving equal, sexp]
end

module Status : sig
  type t =
    | Passed
    | Failed
    | Pending
    | Running
    | Unknown
  [@@deriving equal, sexp]
end

(** Exact field-specific protocol vocabulary, never substring matching. Unknown provider
    values stay visible and neutral. Completion is not acceptance. *)
val normalize : Field.t -> string -> Status.t

val status_role : Status.t -> Role.t
val freshness_role : Asic.Summary.Freshness.t -> Role.t
val stage_role : Asic.Stage.Status.t -> Role.t

type span =
  { text : string
  ; role : Role.t
  }
[@@deriving equal, sexp]

type row = span list [@@deriving equal, sexp]

val plain : string -> row
val text : row -> string
val fact : label:string -> Field.t -> string -> row
val freshness : Asic.Summary.Freshness.t -> row
val check : Asic.Check.t -> row

(** Cell-aware UTF-8 wrapping preserving roles across boundaries; controls become '?'.
    Non-positive width yields no rows. No arbitrary provider content is classified. *)
val wrap : width:int -> row -> row list

val clip : width:int -> row -> row
val page : width:int -> height:int -> offset:int -> row list -> row list
val render : attrs:(Role.t -> Bonsai_term.Attr.t list) -> row list -> Bonsai_term.View.t
