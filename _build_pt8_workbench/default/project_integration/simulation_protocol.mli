open! Core
open Hardcaml_workbench_protocol.Simulation

(** Bounded whole-stdout discovery decode and structural validation. *)
val parse_discovery : string -> Discovery.t Or_error.t

(** Validates explicit inputs and returns cases in catalog order and parameters in key
    order. ASIC evidence resolution is the backend's responsibility. *)
val validate_selection : Discovery.t -> Selection.t -> Selection.t Or_error.t

(** Decode one complete event line, excluding its LF. This validates field bounds and
    payload shape; identity, ordering and transitions need the stateful reducer. *)
val parse_event_line : string -> Provider.Event.t Or_error.t
