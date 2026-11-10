open! Core
open Hardcaml_workbench_protocol

(** Fresh endpoints do not imply an occurrence in the selected historical execution. *)
type intent =
  | Physical_stage of Asic.Stage.t
  | Fresh_endpoint of string

val endpoint : intent -> string
val advertised_selection : intent -> Asic.Selection.t option

val resolve_intent
  :  intent:intent
  -> remembered:Asic.Selection.t option
  -> observed:Asic.Selection.t option
  -> snapshot:Asic.Snapshot.t option
  -> (Asic.Selection.t, string) Result.t

(** Explicit provider actions take priority. Otherwise replace only the endpoint of
    captured remembered/observed inputs, or use the declared catalog default pair. No
    status-based endpoint guesses, effects, or fallback from stale selections. *)
val resolve
  :  stage:Asic.Stage.t
  -> remembered:Asic.Selection.t option
  -> observed:Asic.Selection.t option
  -> snapshot:Asic.Snapshot.t option
  -> (Asic.Selection.t, string) Result.t
