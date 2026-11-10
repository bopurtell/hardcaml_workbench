(* Independent installed-library consumer: preparation only; never execute. *)
[@@@alert "-unsafe_multidomain"]
open Hardcaml_asic_execution
let () =
  let a = Sys.argv in
  let plan = match Execution_plan.Stage_plan.through Execution_plan.Stage.Synthesis with
    | Ok p -> Execution_plan.of_stages p | Error e -> failwith e in
  let manifest = Yojson.Safe.from_file (a.(1) ^ "/manifest.json") in
  (match Hardcaml_asic.Bundle.verify_manifest_identity manifest with
   | Ok () -> () | Error e -> failwith (Core.Error.to_string_hum e));
  let result = Stage_preparation.prepare ~bundle:a.(1) ~support_tools:a.(2)
    ~pdk_root:a.(3) ~python:a.(4) ~docker:a.(5) ~git:a.(6) ~resources:a.(7)
    ~workspace:a.(8) ~checkpoint_store:(a.(8) ^ "/checkpoints")
    ~evidence_root:a.(9) ~environment:(Array.to_list (Unix.environment ()))
    ~probe_timeout:60. ~plan () in
  match result with
  | Ok prepared -> print_endline prepared.preflight_path
  | Error e -> prerr_endline e.cause.message; exit e.cause.exit_code
