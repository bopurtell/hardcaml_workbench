open! Core
open Hardcaml_workbench_protocol
module Public = Hardcaml_workbench_backend.Asic_public
module Service = Hardcaml_workbench_backend.Asic_service

let require ok message = if not ok then failwith message
let set j key value =
  match j with
  | `Assoc fields -> `Assoc ((key, value) :: List.Assoc.remove fields key ~equal:String.equal)
  | _ -> failwith "fixture object required"
;;

let () =
  let selection : Asic.Selection.t =
    { flow = "stock"; profile = "exact"; endpoint = "timing"; assignments = [] }
  in
  let scope = Public.decode (In_channel.read_all "sram_scope.json") in
  let metadata ?(scope = scope) supported =
    `Assoc [ "cli_contract", `Assoc
      [ "version", `Int 4; "capabilities", `Assoc
        [ "namedflow1", `Bool true; "sram_segmented1", supported
        ; "sram_segmented1_scope", scope ] ] ]
  in
  let macro = `Assoc
    [ "module", `String "RM_IHPSG13_1P_256x16_c2_bm_bist"
    ; "physical_intent", `Assoc [ "orientation", `String "R0" ] ]
  in
  let contract = `Assoc
    [ "schema_version", `Int 2; "execution", `String "fresh_full"
    ; "macros", `List [ macro ] ]
  in
  let manifest = `Assoc
    [ "macro_contract", contract; "operation", `String "Hardening" ]
  in
  let plan manifest = `Assoc [ "bundle_manifest", `String (Yojson.Safe.to_string manifest) ] in
  let admit ?(metadata = metadata (`Bool true)) ?(selection = selection) manifest =
    Public.validate_sram_selection ~metadata selection (plan manifest)
  in
  let reject f = require (Result.is_error (Or_error.try_with f)) "Unsupported macro request admitted" in
  List.iter (List.take Public.canonical_stages 6) ~f:(fun endpoint ->
    admit ~selection:{ selection with endpoint } manifest);
  List.iter [ `Null; `Bool false; `String "true" ] ~f:(fun value ->
    reject (fun () -> admit ~metadata:(metadata value) manifest));
  List.iter [ `Null; `Bool true; `String "stock256x16_r0_through_timing_v1"; `Assoc [] ]
    ~f:(fun scope -> reject (fun () -> admit ~metadata:(metadata ~scope (`Bool true)) manifest));
  List.iter (match scope with `Assoc fields -> fields | _ -> assert false)
    ~f:(fun (key, _) ->
      List.iter [ `Null; `String "incompatible" ] ~f:(fun value ->
        reject (fun () -> admit ~metadata:(metadata ~scope:(set scope key value) (`Bool true)) manifest)));
  reject (fun () -> admit ~selection:{ selection with endpoint = "signoff" } manifest);
  reject (fun () -> admit (set manifest "operation" (`String "Synthesis")));
  List.iter
    [ set contract "schema_version" (`Int 1)
    ; set contract "macros" (`List [ macro; macro ])
    ; set contract "macros" (`List [ set macro "module" (`String "other") ])
    ; set contract "macros" (`List [ set macro "physical_intent" (`Assoc [ "orientation", `String "R90" ]) ])
    ] ~f:(fun contract -> reject (fun () -> admit (set manifest "macro_contract" contract)));
  List.iter [ "timing_intent"; "timing_native_coverage"; "timing_physical_qualification" ]
    ~f:(fun key ->
      reject (fun () -> admit (set manifest key (`Assoc [])));
      admit (set manifest key `Null));
  reject (fun () -> admit (set manifest "macro_contract" `Null));
  reject (fun () -> admit (`Assoc [ "flow_configuration", `Assoc [ "MACROS", `Assoc [ "undeclared", `Assoc [] ] ] ]));
  reject (fun () ->
    Public.validate_sram_selection ~metadata:(metadata (`Bool true)) selection
      (set
         (plan (`Assoc [ "flow_configuration", `Assoc [ "MACROS", `Assoc [ "undeclared", `Assoc [] ] ] ]))
         "configuration_bytes" (`String "{}")));
  reject (fun () ->
    Public.validate_sram_selection ~metadata:(metadata (`Bool true)) selection
      (`Assoc [ "configuration_bytes", `String "{\"MACROS\":{\"undeclared\":{}}}" ]));
  (* Old providers still support their macro-free plans, including Signoff. *)
  admit ~metadata:(metadata `Null) ~selection:{ selection with endpoint = "signoff" } (`Assoc []);
  let config : Hardcaml_workbench_project_integration.Asic_config.t =
    { schema_version = 1; project_executable = "/fixture/project"
    ; provider_executable = "/fixture/provider"; results_root = "/fixture/results"
    ; toolchain = "/fixture/tools"; python = None; support_tools = None; pdk_root = None
    ; stage_timeout_seconds = Some 3600 }
  in
  let budget config endpoint =
    Service.For_testing.execution_budget_seconds config { selection with endpoint }
  in
  require (Float.equal (budget config "synthesis") 8370.) "Execution/publication synthesis budgets truncated";
  require (Float.equal (budget config "timing") 45270.) "Execution/publication Timing prefix budgets truncated";
  (* Literal expectations cover every prefix, both accepted timeout boundaries,
     the provider default, and the largest multiplication (legacy Signoff). *)
  List.iter
    [ None, [ 2370.; 3750.; 5130.; 6510.; 7890.; 9270.; 10650. ]
    ; Some 1, [ 1172.; 1354.; 1536.; 1718.; 1900.; 2082.; 2264. ]
    ; Some 86400, [ 173970.; 346950.; 519930.; 692910.; 865890.; 1038870.; 1211850. ]
    ]
    ~f:(fun (stage_timeout_seconds, expected) ->
      List.iter2_exn Public.canonical_stages expected ~f:(fun endpoint expected ->
        let actual = budget { config with stage_timeout_seconds } endpoint in
        require (Float.is_finite actual && Float.equal actual expected)
          ("Incorrect execution/publication deadline for " ^ endpoint)));
  List.iter [ 0; -1; 86401; Int.max_value; Int.min_value ] ~f:(fun seconds ->
    reject (fun () -> ignore (budget { config with stage_timeout_seconds = Some seconds } "timing" : float)));
  reject (fun () -> ignore (budget config "unknown" : float));
  print_endline "SRAM admission and whole-prefix budgets: ok"
;;
