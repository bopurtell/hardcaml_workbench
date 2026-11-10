(** Compatibility names for callers of the original compiled catalog. *)
let definition = Definition.of_spec (Stock.find "overview")

let height key = Core.Option.value_exn (Definition.leaf_min_height definition.layout ~key)
let session_height = height "live-status"
let selector_height = height "run-selector"
let checklist_height = height "stage-checklist"
let planned_run_height = height "planned-run"
