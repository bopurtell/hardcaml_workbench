open! Core

(** Bounded retained VCD data. Timestamps are exact nonnegative int64 ticks; physical time
    is [ticks * timescale.magnitude] in [timescale.unit_], never float. Parsing does not
    verify artifact provenance/digests; the caller must do that. *)
type time_unit =
  | S
  | Ms
  | Us
  | Ns
  | Ps
  | Fs

type timescale =
  { magnitude : int
  ; unit_ : time_unit
  }

type signal =
  { index : int
  ; identifier : string
  ; scope : string list
  ; reference : string
  ; range : string option
  ; name : string
  ; width : int
  ; kind : string
  }

type change =
  { time : int64
  ; value : string
  }

type limits =
  { max_bytes : int
  ; max_signals : int
  ; max_width : int
  ; max_changes : int
  ; max_value_bytes : int
  }

type t

val default_limits : limits

(** Scalar/vector 0/1/X/Z, hierarchy and identifier aliases are supported. Other value
    kinds, missing timescale, malformed data and exhausted budgets fail. Additional fixed
    bounds: hierarchy depth 128, full signal path 1024 bytes, directive length 8192
    tokens, token length max(8192, max_width + 1). *)
val parse : ?limits:limits -> string -> t Or_error.t

val signals : t -> signal array
val timescale : t -> timescale
val timescale_to_string : timescale -> string
val time_bounds : t -> int64 * int64
val change_count : t -> int

(** Alias declarations share one history. Returned arrays are copies. *)
val changes : t -> signal -> change array

(** Last assignment at or before [time], including last assignment at equal time. None
    means uninitialized. Before zero this returns None; beyond the end it holds the last
    value. Foreign signal handles raise Invalid_argument. *)
val value_at : t -> signal -> time:int64 -> string option

val values_at : t -> time:int64 -> (signal * string option) array

type projected_lane =
  { signal : signal
  ; samples : string option array
  ; transitions : int array (** Saturated at two: two means dense/hidden ordering. *)
  ; reason : string option
  }

(** Bounded original-event projection. Cells must be ordered inclusive intervals;
    overlapping cells are allowed only for repeated expanded single ticks. At most 16
    lanes,4096 cells,100000 unique-history inspected events and16MiB aggregate
    inspected/sample payload. Aliases share projection storage/budget. *)
val project_window
  :  t
  -> signals:signal list
  -> cells:(int64 * int64) array
  -> projected_lane list Or_error.t

(** Exact inspection, at most 64 signals,100000 values and16MiB returned payload. *)
val signal_samples
  :  t
  -> signals:signal list
  -> times:int64 array
  -> (signal * string option array) list Or_error.t

(** Bounded view heuristic: one unambiguous clk/clock scalar, at least four equal rising
    intervals with alternating binary edges. Scans <=4096 events. *)
val infer_clock : t -> (signal * int64) option

(** Per-lane non-binary/uninitialized reasons for this exact inclusive window. Uses the
    same aggregate conversion event/value budgets, including marked lanes; aliases count
    once. Does not allocate or fabricate two-state values. *)
val classify_window
  :  t
  -> signals:signal list
  -> start:int64
  -> stop:int64
  -> (signal * string option) list Or_error.t

(** Exact window conversion, with one renderer cycle per VCD tick, rebased to [start].
    [stop] is inclusive. At most 64 signals and 1,000,000 ticks; no sampling/coarsening.
    X/Z or uninitialized data anywhere in the selected window returns Unsupported.
    Conversion is also bounded to 100,000 unique identifier events and 16 MiB expanded
    value bytes; aliases share storage. Original absolute ticks/units stay in [t], so
    renderer cycle labels must be presented as relative ticks by the caller. Use
    [Hardcaml_waveterm.Waveform.to_string] on the result. *)
val to_waveterm
  :  t
  -> signals:signal list
  -> start:int64
  -> stop:int64
  -> Hardcaml.Wave_data.t Or_error.t
