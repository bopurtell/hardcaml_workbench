(** Identifies one supervised job. A job is the Workbench's unit of supervision, not the
    unit of design identity; see {!Build_ref} and {!Run_ref}. *)

include Id.Make (struct
    let module_name = "Hardcaml_workbench_protocol.Job_id"
  end)
