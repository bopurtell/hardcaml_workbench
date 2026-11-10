(** Identifies one opened project within a daemon session. *)

include Id.Make (struct
    let module_name = "Hardcaml_workbench_protocol.Project_id"
  end)
