open! Core
open Hardcaml_workbench_protocol

(** Client-local intent fences over the daemon's single project preview. No effects. *)
type t

type ticket

type status =
  | Empty
  | Pending
  | Failed
  | Stale
  | Ready
[@@deriving equal, sexp]

type model =
  { status : status
  ; selection : Asic.Selection.t option
  ; preview : Asic.Preview.t option
  ; requested : Asic.Selection.t option
  ; operation_key : string option
  ; message : string
  ; launch : launch
  ; launch_preview : Asic.Preview.t option
  }

and launch =
  { key : string option
  ; run_id : string option
  ; state : launch_status
  ; message : string
  }

and launch_status =
  | Submitting
  | Allocated
  | Running
  | Completed
  | Launch_failed
  | Cancelled
  | Detached
  | Unavailable
[@@deriving equal, sexp]

type role =
  | Fact
  | Muted
  | Warning
  | Error
  | Success
[@@deriving equal, sexp]

type row =
  { role : role
  ; text : string
  }

val empty : t
val reset : t -> scope:string -> t
val begin_plan : t -> Asic.Selection.t -> t * ticket
val begin_fresh : t -> elaboration_only:bool -> Asic.Selection.t -> t * ticket
val fresh_intent : t -> Asic.Fresh.Intent.t option
val workflow : t -> Asic.Fresh.Workflow.t option
val workflow_active : Asic.Fresh.Workflow.t -> bool
val fresh_launchable : t -> Asic.Fresh.Intent.t -> bool
val current_ticket : t -> ticket -> bool
val same_generation : t -> ticket -> bool

(** Receipt failures remain explicit, even when a newer poll won snapshot ordering.
    [floor] is the first snapshot request revision allowed to acknowledge this intent. Use
    a request issued after the receipt: an earlier-issued Get can contain the previous
    same-selection completion even if its response arrives after the receipt. *)
val receipt : t -> ticket -> floor:int -> (unit, string) Result.t -> t

(** Retain the exact successful Stage_fresh receipt. Matching selection alone never
    authorizes adoption of a replacement intent. *)
val fresh_receipt
  :  t
  -> ticket
  -> floor:int
  -> (Asic.Fresh.Intent.t, string) Result.t
  -> t

type launch_ticket

val begin_fresh_launch : t -> key:string -> Asic.Fresh.Intent.t -> t * launch_ticket

(** A separate local launch fence, unaffected by replanning. An unconfirmed transport
    outcome blocks another launch until exact authoritative evidence reconciles it. *)
val begin_launch : t -> key:string -> Asic.Preview.t -> t * launch_ticket

val launch_receipt : t -> launch_ticket -> floor:int -> (unit, string) Result.t -> t
val receive : t -> revision:int -> Asic.Snapshot.t -> t
val model : t -> model
val launchable : t -> Asic.Preview.t -> bool
val rows : model -> detail:bool -> row list
val launch_label : model -> string
val max_scroll : model -> detail:bool -> int
