open! Core
open Hardcaml_workbench_protocol

(** A finite, selected-first Timing intention. Dropping it stops future issuance; it never
    cancels daemon tasks. Call only from input/async scheduling edges. *)
type t

type request =
  { ticket : int
  ; operation : Asic.Operation.t
  ; selected : bool
  }

val create : neighbors:int -> Inspection_view.t -> t

(** Explicit reopen/retry resets the finite budget, retaining held/active reads. An
    acknowledged read whose task and publication are both absent from a post-receipt
    snapshot is released for explicit retry only; polls never retry it. *)
val restart : t -> view:Inspection_view.t -> t

(** Ignore obsolete tickets. [floor] requires a snapshot from a request issued after the
    receipt, rather than an already-held equal poll. *)
val receipt : ?floor:int -> t -> ticket:int -> (unit, 'error) Result.t -> t

(** None stops an obsolete source/context intention. At most one request is returned;
    completion is observed through receipts and exact snapshots. *)
val step
  :  ?revision:int
  -> t
  -> view:Inspection_view.t
  -> Asic.Snapshot.t
  -> t option * Inspection_view.t * request option
