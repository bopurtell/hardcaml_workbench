(** Identifies one build configuration a project offers for a target. *)

include Id.Make (struct
    let module_name = "Hardcaml_workbench_protocol.Configuration_id"
  end)
