(** Names the backend that realizes a target: [fpga], [asic], [simulation], and whatever a
    later backend introduces. Backends are named rather than enumerated so that adding one
    does not revise the protocol schema. *)

include Id.Make (struct
    let module_name = "Hardcaml_workbench_protocol.Backend_id"
  end)
