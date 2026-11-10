open! Core
open Hardcaml_workbench_protocol

type pane =
  | Paths
  | Detail
  | Context
[@@deriving equal]

type t = Inspection_view.t

val attach_retained : t -> Asic.Snapshot.t -> t

type path_item =
  { row : Asic_inspection.Row.t
  ; selected : bool
  ; label : string
  }

val path_items : ?presentation:Tile_presentation.t -> t -> path_item list
val empty_paths_message : t -> string

type selection =
  { run : Run_ref.t
  ; domain : string
  ; stage : string
  ; source_digest : string
  ; row_id : string
  }

val pane : string -> pane option
val create : generation:int -> run:Run_ref.t -> stage:string -> t
val with_analysis : t -> Asic_inspection.Analysis_target.t option -> t
val selection : t -> selection option

type line_role =
  | Selected
  | Metric
  | Metadata
  | Pending
  | Failure
  | Success
  | Source

(** Width-bounded four-line Detail summary, or complete Context provenance. Provider text
    follows the Detail prefix in [rows] and must remain neutrally styled. Context lists
    labelled evidence times; [now] (default: the current time) only computes their ages. *)
val semantic_prefix
  :  ?presentation:Tile_presentation.t
  -> ?now:Time_ns.t
  -> pane:pane
  -> width:int
  -> t
  -> (line_role * string) list

val input
  :  ?presentation:Tile_presentation.t
  -> pane:pane
  -> scroll:int
  -> width:int
  -> height:int
  -> t
  -> Inspection_view.input
  -> t * int * Asic.Operation.t option

val rows
  :  ?presentation:Tile_presentation.t
  -> ?now:Time_ns.t
  -> pane:pane
  -> scroll:int
  -> width:int
  -> height:int
  -> t
  -> string list
