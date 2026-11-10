(** Identifies one target a project declares: a hardware top level plus the backend that
    realizes it. Generic Dune projects have no targets, so a value of this type always
    originates from project integration rather than from workspace inspection. *)

include Id.Make (struct
    let module_name = "Hardcaml_workbench_protocol.Target_id"
  end)
