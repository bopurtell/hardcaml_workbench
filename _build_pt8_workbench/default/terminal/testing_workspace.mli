open! Core
open Hardcaml_workbench_protocol

(** Cooperative kinds selected by the cluster plan. The legacy [simulation] pane is
    deliberately independent and is not recognized by [is_pane]. *)
type pane =
  | Catalog
  | Attempts
  | Cases
  | Detail
  | Artifacts
  | Logs

val pane : string -> pane option
val is_pane : string -> bool
val pane_kind : pane -> string

(** One state per client/project/workspace, with host-owned identity/lifetime fences. No
    Workspace_host dependency. Reconnect invalidates pending tickets. *)
type t

val empty : t
val view : t -> Simulation_view.t
val set_view : t -> Simulation_view.t -> t
val catalog : t -> Simulation_catalog.t
val set_catalog : t -> Simulation_catalog.t -> t
val update_catalog : t -> (Simulation_catalog.t -> Simulation_catalog.t) -> t
val selected_artifact : t -> string option
val artifact : t -> Simulation.Artifact.t option
val workload_artifact : t -> Simulation.Artifact.t option
val waveform_artifact : t -> Simulation.Artifact.t option
val waveform_unavailable : t -> string option
val waveform_eligible : t -> Simulation.Artifact.t -> bool
val artifact_metadata : t -> Simulation.Artifact.t option

type artifact_identity =
  { id : string
  ; sha256 : string option
  ; size : int option
  }

(** Call once after establishing project scope, before Get/Observe. Selects the exact
    attempt even outside the history page. Subsequent detail validates saved evidence;
    polling retains unavailable intent, and explicit selection overrides it. [metadata] is
    the original observed artifact, persisted separately from the legacy three-field
    identity. Its attempt/case/kind/media and byte identity must still match. Legacy
    waveform cursors cannot authorize fallback from an ineligible saved artifact; typed
    PT8 JSON references keep their separate same-case waveform handoff. *)
val restore_selection
  :  ?metadata:Simulation.Artifact.t
  -> t
  -> attempt:string
  -> case_id:string option
  -> artifact:artifact_identity option
  -> t

(** Includes pending/unavailable saved identity so persistence never replaces it with an
    empty intermediate hydration state. *)
val artifact_identity : t -> artifact_identity option

val selection_unavailable : t -> string option
val select_attempt : t -> string -> t
val select_case : t -> string -> t
val select_artifact : t -> string -> t
val move_case : t -> int -> t
val move_artifact : t -> int -> t
val reconnect : t -> t
val begin_request : t -> t

val receive
  :  t
  -> ticket:int
  -> selected:string option
  -> Simulation.Operation.t
  -> (Simulation.Snapshot.t, string) Result.t
  -> t

(** Typed, sanitized rows. [Simulation_view.row.selected] marks only the first physical
    line of the pane's cursor for viewport following. Indicators derive from protocol
    facts only. Artifacts lists all cases in protocol order, with label/case/availability;
    Detail carries the selected artifact's identity, digest and provenance, using the
    effective compression choice (full mode reveals exact values). [identifier_width]
    reserves a stable list-local ordinal for long attempt tokens that cannot fit.
    Selection/export helpers always use exact source IDs. *)
val rows
  :  ?now:Time_ns.t
  -> ?string_compression:bool
  -> ?identifier_width:int
  -> t
  -> pane
  -> log_lines:(Job_id.t -> string list)
  -> Simulation_view.row list
