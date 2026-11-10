type t =
  | Running
  | Pending
  | Completed
  | Failed
  | Cancelled
  | Skipped
  | Not_requested
  | Unknown
  | Ready
  | Stale
  | Pin
  | Artifact
  | Log
  | Seed
  | Report
  | Trace
  | Info
  | Cached
  | Linked
  | Independent
  | Expanded
  | Collapsed
  | Leaf
  | Top
  | Unavailable

type frames =
  { dot : Bonsai_term.View.t
  ; line : Bonsai_term.View.t
  }

(** A single display-cell glyph without padding; empty when icons are Off.
    [Cached] denotes retained evidence, [Linked]/[Independent] navigation coupling,
    [Expanded]/[Collapsed] expandable branches, [Leaf] a childless node, [Top] the
    hierarchy top, and [Unavailable] missing context (not a failed verdict).
    These semantic kinds are static and never use animation frames. *)
val text : Appearance.Icons.t -> t -> string

(** Running uses the supplied native Dot (Unicode) or Line (ASCII) frame. Without frames,
    rendering is deterministic. Off always produces an empty view. *)
val view : ?frames:frames -> Appearance.Icons.t -> t -> Bonsai_term.View.t
