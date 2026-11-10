open! Core
open Hardcaml_workbench_protocol

(** Compact presentation over existing typed evidence. No IO, parsing producer JSON,
    guessed stage attribution, derived acceptance, or implicit requests. *)
val supports : string -> bool

(** [stage_id] is an exact provider identity; omitted defaults to [kind]. Foreign-run
    summaries are ignored. Aggregate metrics are explicitly labelled as such. Rows keep
    full run/digest/producer/source provenance in [details] for inspection. [compact]
    defaults to false; true prioritizes facts/failures before redundant chrome.
    [freshness] defaults to true; false hides validated-only chrome, never stale or
    unavailable warnings. [decimal_places] defaults to 3 (bounded to 0..9) and truncates
    displayed Timing measurements towards zero; counts retain integer-style display.
    Numeric evidence and technical source text are unchanged. *)
val rows
  :  ?now:Time_ns.t
  -> ?finalizations:Asic.Finalization.t list
  -> ?compact:bool
  -> ?freshness:bool
  -> ?decimal_places:int
  -> ?stage_id:string
  -> kind:string
  -> run:Run_ref.t
  -> summary:Asic.Summary.t option
  -> stages:Asic.Stage.t list
  -> unit
  -> Overview_tiles.row list
