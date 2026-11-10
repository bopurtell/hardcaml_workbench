let () =
  let module P = Hardcaml_workbench_workspaces.Presets in
  match Array.to_list Sys.argv with
  | [ _; "--workspace-config" ] ->
    (match P.export_config () with
     | Ok text -> print_string text
     | Error error -> failwith (Core.Error.to_string_hum error))
  | [ _ ] -> print_endline (Sexplib0.Sexp.to_string_hum (P.export_sexp ()))
  | _ -> failwith "Usage: export_presets [--workspace-config]"
;;
