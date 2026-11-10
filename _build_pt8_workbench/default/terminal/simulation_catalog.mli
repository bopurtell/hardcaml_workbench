open! Core
open Hardcaml_workbench_protocol

(** Pure project catalog. Browsing never launches or changes an investigation. *)
type t

val empty : t
val update : t -> Simulation.Snapshot.t -> t
val invalidate : t -> t
val begin_discovery : t -> t
val discovery_failed : t -> string -> t
val suites : t -> Simulation.Suite.t list
val suite : t -> Simulation.Suite.t option
val suite_id : t -> string option
val case_id : t -> string option
val selected_cases : t -> string list
val filter : t -> string
val set_filter : t -> string -> t
val visible_cases : t -> Simulation.Case.t list
val select_suite : t -> string -> t
val move_suite : t -> int -> t
val select_case : t -> string -> t
val move_case : t -> int -> t
val toggle_case : t -> string -> t
val toggle_current : t -> t
val select_all : t -> t

(** Explicitly accept current discovery/defaults, preserving the exact subset. Removed
    selected cases must first be toggled off; no automatic retargeting. *)
val accept : t -> t

val disabled_reason : t -> string option

(** Captures exact suite, subset, declared defaults and digest for Form.create. *)
val launch : t -> (Simulation.Suite.t * Simulation.Selection.t * string) Or_error.t

val rows : ?string_compression:bool -> t -> Simulation_view.row list
