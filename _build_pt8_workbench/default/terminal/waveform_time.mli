open! Core

(** Exact installed-Waveterm raster: code -1 is one cell/tick, code < -1 is [-code]
    ticks/cell, and code >= 0 is [2 * (code + 1)] cells/tick. *)
type scale =
  | Cells_per_tick of int
  | Ticks_per_cell of int
  | Window_cells of { compressed : bool }
  (** Variable original-tick intervals: use [cell_bounds], not an integer raster code. *)

type cursor =
  | Left
  | Right
  | Column of int
[@@deriving equal, sexp_of]

type t

val scale_of_code : int -> scale
val capacity : code:int -> columns:int -> int

(** Nonnegative timestamps, 1..4096 columns and bounded raster codes. Invalid arguments
    raise Invalid_argument. [stop] is clipped to the raster capacity; the caller supplies
    the real retained trace/window end, never extrapolation. *)
val create : code:int -> columns:int -> start:int64 -> stop:int64 -> t

(** Inclusive requested bounds, unchanged by raster width. No allocation per tick.
    Supports [0,Int64.max_value], including a one-column viewport. *)
val create_window : columns:int -> start:int64 -> stop:int64 -> t

val columns : t -> int
val start : t -> int64
val stop : t -> int64
val scale : t -> scale
val cursor : t -> int64 -> cursor

(** Inclusive real tick interval represented by a cell. None past the retained end.
    Expanded cells share a tick; a compressed final cell may be partial. *)
val cell_bounds : t -> column:int -> (int64 * int64) option

(** Exact absolute physical time in the VCD's declared unit. The supported VCD magnitudes
    1/10/100 are applied as decimal digits, including above int64. *)
val format_time : Waveform_data.timescale -> int64 -> string

(** Exact decimal unit compaction, no rounding or float conversion. *)
val format_compact : Waveform_data.timescale -> int64 -> string

type label =
  { tick : int64
  ; column : int
  ; text_column : int
  ; text : string
  }

type ruler =
  { labels : label list
  ; major_columns : int list
  ; minor_columns : int list
  }

(** Complete, non-overlapping labels (at least two cells apart), and marks only within
    real trace data. Compressed anchors name the cell's first real tick. All column
    coordinates are relative to the FIRST INTERIOR waveform cell. *)
val ruler : t -> timescale:Waveform_data.timescale -> ruler
