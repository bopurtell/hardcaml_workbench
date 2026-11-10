open! Core
open Hardcaml_workbench_protocol

module Mode : sig
  type t =
    | Summary
    | Cells
    | Details
    | Metrics
    | Evidence
  [@@deriving equal, sexp]
end

module State : sig
  type t

  val empty : t
  val mode : t -> Mode.t
  val sort : t -> Synthesis.Sort.t
  val selected : t -> string option

  (** Reconcile against the exact cached run/digest. A replacement or missing summary
      invalidates selection and leaves Details; the next row is selected only on a
      subsequent reconciliation/navigation. Filter lives in the caller. The first summary
      selects its first matching row. Call before handling navigation and persist the
      returned state. Projection and filtered/sorted rows are cached persistently by
      run/digest, cell data, filter, and sort; metadata-only updates reuse them, while
      same-digest cell updates invalidate. *)
  val reconcile : t -> summary:Asic.Summary.t option -> filter:string -> t

  val move : t -> summary:Asic.Summary.t option -> filter:string -> delta:int -> t
  val set_mode : t -> Mode.t -> t
  val back : t -> t
  val set_sort : t -> Synthesis.Sort.t -> t
  val cycle_sort : t -> t

  (** Clamp both the current and resulting offsets to the actual wrapped-page bound. *)
  val scroll : t -> delta:int -> max_offset:int -> t
end

(** Synthesis-only diagnostic counters. No physical verification or signoff verdict is
    inferred from these counts; source references remain in Evidence. *)
val checks_lines : Asic.Summary.t -> string list

(** Cell-aware wrapping shared by the pure evidence views. *)
val wrap : width:int -> string -> string list

(** Pure, cell-width-bounded strings, at most [height] rows. No host dependency, provider
    effects, JSON parsing, or inferred cell semantics. Rendering also reconciles
    defensively, but does not persist that reconciled state. *)
val rows
  :  State.t
  -> summary:Asic.Summary.t option
  -> filter:string
  -> width:int
  -> height:int
  -> string list

(** Same viewport and plain text as [rows]. Summary freshness and Metrics acceptance carry
    typed roles; arbitrary cell labels, producer text and evidence remain plain. *)
val semantic_rows
  :  State.t
  -> summary:Asic.Summary.t option
  -> filter:string
  -> width:int
  -> height:int
  -> Evidence_style.row list

(** Navigate a wrapped page using its actual viewport, including after resize. *)
val scroll
  :  State.t
  -> summary:Asic.Summary.t option
  -> filter:string
  -> width:int
  -> height:int
  -> delta:int
  -> State.t
