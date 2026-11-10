open! Core
module Service = Hardcaml_workbench_backend.Asic_service.For_testing

let replace j key value =
  match j with
  | `Assoc fields ->
    `Assoc ((key, value) :: List.Assoc.remove fields key ~equal:String.equal)
  | _ -> failwith "Expected object"
;;

let envelope =
  `Assoc
    [ "schema_version", `Int 1
    ; "profile", `String "synthesis-total-tasks-v1"
    ; "total_container_tasks", `Int 6
    ; "configured_executor_max_workers", `Int 6
    ; "reduced_usable_executor_concurrency", `Bool true
    ]
;;

let capability =
  `Assoc
    [ "schema_version", `Int 1
    ; "profile", `String "synthesis-total-tasks-v1"
    ; "total_container_tasks", `Int 6
    ; "fresh_only", `Bool true
    ; "acceptance", `Bool false
    ; "opt_in", `String "HARDCAML_ASIC_SYNTHESIS_TASK_LIMIT=6"
    ]
;;

let metadata ?(capability = capability) ?(envelope = envelope) () =
  `Assoc
    [ ( "cli_contract"
      , `Assoc [ "capabilities", `Assoc [ "synthesis_collection1", capability ] ] )
    ; "execution_envelope", envelope
    ]
;;

let execution stages =
  let publications =
    List.map stages ~f:(fun stage ->
      `Assoc
        [ "path", `String ("/checkpoint/" ^ stage)
        ; "identity", `String stage
        ; "boundary", `String stage
        ])
  in
  `Assoc
    [ "attempt_id", `String "stream"
    ; "status", `String "completed"
    ; "exit_code", `Int 0
    ; ( "plan"
      , `Assoc
          [ "schema_version", `Int 4
          ; "initial_boundary", `Null
          ; "stages", `List (List.map stages ~f:(fun s -> `String s))
          ] )
    ; "artifacts", `List publications
    ; ( "occurrences"
      , `List
          (List.map stages ~f:(fun stage ->
             `Assoc
               [ "action_key", `String ("implementation." ^ stage)
               ; "occurrence_id", `String ("stream/implementation." ^ stage)
               ; "status", `String "completed"
               ; "exit_code", `Int 0
               ])) )
    ]
;;

let field key j = Hardcaml_workbench_backend.Asic_public.field key j

let report ?(physical = "synthesis") execution =
  `Assoc
    [ "execution", execution
    ; "completion", `Assoc [ "physical", `String physical ]
    ; ( "checkpoints"
      , `List
          (List.map
             (Hardcaml_workbench_backend.Asic_public.list (field "artifacts" execution))
             ~f:(fun reference -> `Assoc [ "reference", reference ])) )
    ]
;;

let () =
  let validate
    ?(acceptance_requested = false)
    ?(metadata = metadata ())
    ?report:provided
    execution
    =
    Service.validate_finalization_execution
      ~stream_id:"stream"
      ~acceptance_requested
      ~metadata
      ~report:(Option.value provided ~default:(report execution))
      execution
  in
  let rejected label f =
    if Result.is_ok (Or_error.try_with f) then failwith ("Unexpected admission: " ^ label)
  in
  let synthesis = execution [ "synthesis" ] in
  validate synthesis;
  rejected "synthesis acceptance" (fun () ->
    validate ~acceptance_requested:true synthesis);
  rejected "absent capability" (fun () ->
    validate ~metadata:(metadata ~capability:`Null ()) synthesis);
  rejected "inactive opt-in" (fun () ->
    validate ~metadata:(metadata ~envelope:`Null ()) synthesis);
  List.iter
    [ "schema_version", `Int 2
    ; "profile", `String "future"
    ; "total_container_tasks", `Int 20
    ; "fresh_only", `Bool false
    ; "acceptance", `Bool true
    ; "opt_in", `String "implicit"
    ]
    ~f:(fun (key, value) ->
      rejected ("capability " ^ key) (fun () ->
        validate
          ~metadata:(metadata ~capability:(replace capability key value) ())
          synthesis));
  List.iter
    [ "schema_version", `Int 2
    ; "profile", `String "future"
    ; "total_container_tasks", `Int 20
    ; "configured_executor_max_workers", `Int 20
    ; "reduced_usable_executor_concurrency", `Bool false
    ]
    ~f:(fun (key, value) ->
      rejected ("envelope " ^ key) (fun () ->
        validate ~metadata:(metadata ~envelope:(replace envelope key value) ()) synthesis));
  List.iter [ "failed"; "interrupted"; "running" ] ~f:(fun status ->
    rejected status (fun () -> validate (replace synthesis "status" (`String status))));
  rejected "nonzero exit" (fun () -> validate (replace synthesis "exit_code" (`Int 1)));
  rejected "wrong attempt" (fun () ->
    validate (replace synthesis "attempt_id" (`String "other")));
  let plan = field "plan" synthesis in
  List.iter
    [ "resume", replace plan "initial_boundary" (`String "synthesis")
    ; ( "missing freshness"
      , match plan with
        | `Assoc xs ->
          `Assoc (List.Assoc.remove xs "initial_boundary" ~equal:String.equal)
        | _ -> assert false )
    ; "legacy recipe", replace plan "schema_version" (`Int 3)
    ; ( "partial physical prefix"
      , replace plan "stages" (`List [ `String "synthesis"; `String "floorplan" ]) )
    ]
    ~f:(fun (label, plan) ->
      rejected label (fun () -> validate (replace synthesis "plan" plan)));
  List.iter [ "occurrences"; "artifacts" ] ~f:(fun key ->
    rejected ("missing " ^ key) (fun () -> validate (replace synthesis key (`List []))));
  let occurrence =
    List.hd_exn
      (Hardcaml_workbench_backend.Asic_public.list (field "occurrences" synthesis))
  in
  List.iter
    [ "status", `String "failed"
    ; "exit_code", `Int 1
    ; "occurrence_id", `String "other/implementation.synthesis"
    ]
    ~f:(fun (key, value) ->
      rejected ("occurrence " ^ key) (fun () ->
        validate
          (replace synthesis "occurrences" (`List [ replace occurrence key value ]))));
  rejected "partial report" (fun () ->
    validate ~report:(report ~physical:"partial" synthesis) synthesis);
  rejected "report/execution mismatch" (fun () ->
    validate ~report:(report (replace synthesis "exit_code" (`Int 1))) synthesis);
  rejected "missing checkpoint" (fun () ->
    validate ~report:(replace (report synthesis) "checkpoints" (`List [])) synthesis);
  rejected "checkpoint mismatch" (fun () ->
    validate
      ~report:
        (replace
           (report synthesis)
           "checkpoints"
           (`List
             [ `Assoc
                 [ ( "reference"
                   , `Assoc
                       [ "path", `String "/other"
                       ; "identity", `String "synthesis"
                       ; "boundary", `String "synthesis"
                       ] )
                 ]
             ]))
      synthesis);
  let stages =
    [ "synthesis"; "floorplan"; "placement"; "cts"; "routing"; "timing"; "signoff" ]
  in
  List.iter [ true; false ] ~f:(fun acceptance_requested ->
    let physical = execution stages in
    validate
      ~acceptance_requested
      ~metadata:`Null
      ~report:(report ~physical:"full" physical)
      physical;
    let legacy =
      execution (List.filter stages ~f:(fun s -> not (String.equal s "timing")))
    in
    let legacy =
      replace legacy "plan" (replace (field "plan" legacy) "schema_version" (`Int 3))
    in
    validate
      ~acceptance_requested
      ~metadata:`Null
      ~report:(report ~physical:"full" legacy)
      legacy);
  Stdio.print_endline
    "Finalization eligibility: supported synthesis collect, strict negatives and \
     unchanged physical admission passed"
;;
