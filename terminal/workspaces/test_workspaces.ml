open! Core
open Hardcaml_workbench_protocol
open Hardcaml_workbench_workspaces

let kinds d = List.map d.Definition.tiles ~f:(fun t -> t.Common.kind)

let%test_unit "Workloads builtin coexists with a retained custom workloads name" =
  let module W = Workspace in
  let template : Workspace_template.t =
    { version = 1
    ; name = "Personal workloads"
    ; preset = None
    ; views =
        [ { kind = "logs"
          ; hidden = false
          ; geometry = { x = 3; y = 4; width = 57; height = 19 }
          }
        ]
    }
  in
  let definition =
    Workspace_config.definition_of_template ~key:"workloads" template |> Or_error.ok_exn
  in
  let config : Workspace_config.t =
    { version = 1
    ; id = "custom-workloads"
    ; definitions = [ definition ]
    ; windows =
        [ { key = "main"
          ; name = "Main"
          ; workspaces =
              [ { key = "mine"; name = "Mine"; definition = Custom "workloads" } ]
          }
        ]
    }
  in
  let resolved =
    Workspace_config.encode config
    |> Or_error.ok_exn
    |> Presets.decode
    |> Or_error.ok_exn
    |> Presets.resolve
    |> Or_error.ok_exn
  in
  let initial =
    W.apply
      (W.initial ~session_id:(W.Session_id.of_string "custom-workloads"))
      (Initialize_config resolved)
    |> Result.ok
    |> Option.value_exn
  in
  let snapshot =
    W.Snapshot.sexp_of_t initial
    |> Sexp.to_string_mach
    |> Sexp.of_string
    |> W.Snapshot.t_of_sexp
  in
  let builtin = Presets.builtins "workloads" |> Or_error.ok_exn in
  let created =
    W.apply
      snapshot
      (Mutate
         { expected_revision = snapshot.revision
         ; mutation =
             Instantiate_template
               { window = (List.hd_exn snapshot.windows).id; template = builtin.template }
         })
    |> Result.ok
    |> Option.value_exn
  in
  List.iter snapshot.tiles ~f:(fun tile ->
    assert (W.Tile.equal tile (W.tile created tile.id)));
  List.iter snapshot.workspaces ~f:(fun workspace ->
    assert (W.Arrangement.equal workspace (W.workspace created workspace.id)));
  assert (List.exists created.tiles ~f:(fun tile -> String.equal tile.kind "workloads"));
  assert (
    List.equal
      W.Config_workspace.equal
      snapshot.config_workspaces
      created.config_workspaces)
;;

let%test_unit "version1 custom resources key survives serialized upgrade and builtin \
               creation without rewriting layout"
  =
  let module W = Workspace in
  let template : Workspace_template.t =
    { version = 1
    ; name = "My retained resources"
    ; preset = None
    ; views =
        [ { kind = "synthesis"
          ; hidden = false
          ; geometry = { x = 3; y = 4; width = 57; height = 19 }
          }
        ]
    }
  in
  let definition =
    Workspace_config.definition_of_template ~key:"resources" template |> Or_error.ok_exn
  in
  let config : Workspace_config.t =
    { version = 1
    ; id = "legacy-custom-resources"
    ; definitions = [ definition ]
    ; windows =
        [ { key = "main"
          ; name = "Main"
          ; workspaces =
              [ { key = "mine"
                ; name = "Personal resources"
                ; definition = Custom "resources"
                }
              ]
          }
        ]
    }
  in
  let text = Workspace_config.encode config |> Or_error.ok_exn in
  assert (Workspace_config.equal config (Presets.decode text |> Or_error.ok_exn));
  let resolved = Presets.resolve config |> Or_error.ok_exn in
  let snapshot =
    W.apply
      (W.initial ~session_id:(W.Session_id.of_string "legacy-custom-resources"))
      (Initialize_config resolved)
    |> Result.ok
    |> Option.value_exn
  in
  let tile = List.hd_exn snapshot.tiles in
  let mutate snapshot mutation =
    W.apply
      snapshot
      (Mutate { expected_revision = snapshot.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let snapshot =
    mutate
      snapshot
      (Set_tile_binding
         { tile = tile.id
         ; binding =
             Pin_run
               { backend = Backend_id.of_string "asic"
               ; id = "retained-run"
               ; build = None
               ; label = None
               }
         })
  in
  let snapshot =
    mutate snapshot (Set_zoom { workspace = tile.workspace; tile = Some tile.id })
  in
  let bytes = Sexp.to_string_mach (W.Snapshot.sexp_of_t snapshot) in
  let restored = W.Snapshot.t_of_sexp (Sexp.of_string bytes) in
  assert (Result.is_ok (W.validate restored));
  assert (W.Snapshot.equal snapshot restored);
  assert (String.equal bytes (Sexp.to_string_mach (W.Snapshot.sexp_of_t restored)));
  let origin = List.hd_exn restored.config_workspaces in
  assert (Workspace_config.Reference.equal origin.reference (Custom "resources"));
  assert (Workspace_config.Definition.equal origin.definition definition);
  let builtin = Presets.builtins "resources" |> Or_error.ok_exn in
  let created =
    mutate
      restored
      (Instantiate_template
         { window = (List.hd_exn restored.windows).id; template = builtin.template })
  in
  assert (W.Tile.equal (W.tile restored tile.id) (W.tile created tile.id));
  assert (
    W.Arrangement.equal
      (W.workspace restored tile.workspace)
      (W.workspace created tile.workspace));
  assert (
    List.equal
      W.Config_workspace.equal
      restored.config_workspaces
      created.config_workspaces);
  (* Exported configs containing other builtins must not discard the custom collision. *)
  let mixed =
    { resolved with
      definitions = definition :: [ Presets.builtins "overview" |> Or_error.ok_exn ]
    ; windows =
        [ { (List.hd_exn resolved.windows) with
            workspaces =
              (List.hd_exn resolved.windows).workspaces
              @ [ { key = "overview"; name = "Overview"; definition = Builtin "overview" }
                ]
          }
        ]
    }
  in
  let decoded =
    Workspace_config.Resolved.encode mixed
    |> Or_error.ok_exn
    |> Presets.decode
    |> Or_error.ok_exn
  in
  assert (
    List.exists decoded.definitions ~f:(Workspace_config.Definition.equal definition));
  assert (Result.is_ok (Presets.resolve decoded))
;;

let%test_unit "authored and exported stock Overview include visible Preparation defaults" =
  let exported =
    Presets.export_config ()
    |> Or_error.ok_exn
    |> Presets.decode
    |> Or_error.ok_exn
    |> Presets.resolve
    |> Or_error.ok_exn
  in
  List.iter [ Presets.stock_config; exported ] ~f:(fun (config : Workspace_config.t) ->
    let spec =
      List.find_exn config.definitions ~f:(fun d -> String.equal d.key "overview")
    in
    let view, tile =
      List.zip_exn spec.template.views spec.tiles
      |> List.find_exn ~f:(fun (view, _) -> String.equal view.kind "preparation")
    in
    assert (not view.hidden);
    assert (String.equal tile.key "preparation");
    assert (view.geometry.height = 7);
    let presentation = Option.value_exn tile.presentation in
    assert (Option.equal Bool.equal presentation.run_reference (Some false));
    assert (Option.equal Bool.equal presentation.hints (Some false));
    let definition = Definition.of_spec spec in
    assert (
      Option.equal
        Int.equal
        (Definition.leaf_min_height definition.layout ~key:tile.key)
        (Some 7));
    let initial =
      Workspace.initial ~session_id:(Workspace.Session_id.of_string "preparation-default")
    in
    let initialized =
      Workspace.apply
        initial
        (Presets.startup_operation ~selected:config initial |> Option.value_exn)
      |> Result.ok
      |> Option.value_exn
    in
    let overview = List.hd_exn initialized.workspaces in
    assert (
      List.exists initialized.tiles ~f:(fun t ->
        Workspace.Workspace_id.equal t.workspace overview.id
        && String.equal t.kind "preparation"
        && not t.hidden)))
;;

let%test_unit "fresh startup initializes the stock window spec before legacy bootstrap" =
  let module W = Workspace in
  let initial = W.initial ~session_id:(W.Session_id.of_string "stock-startup") in
  let operation = Presets.startup_operation initial |> Option.value_exn in
  (match operation with
   | Initialize_config config ->
     assert (Workspace_config.equal config Presets.stock_config)
   | _ -> assert false);
  let initialized = W.apply initial operation |> Result.ok |> Option.value_exn in
  let expected =
    List.concat_map Presets.stock_config.windows ~f:(fun w ->
      List.map w.Workspace_config.Window.workspaces ~f:(fun instance -> instance.name))
  in
  assert (
    List.equal
      String.equal
      expected
      (List.map initialized.workspaces ~f:(fun w -> w.name)));
  assert (
    List.length initialized.config_windows = List.length Presets.stock_config.windows);
  assert (Option.is_none (Presets.startup_operation initialized));
  let custom =
    Presets.custom_example () |> Or_error.ok_exn |> Presets.resolve |> Or_error.ok_exn
  in
  (match Presets.startup_operation ~selected:custom initial with
   | Some (Initialize_config config) -> assert (Workspace_config.equal config custom)
   | _ -> assert false);
  (* Supplying a different config at reconnect does not replay it. *)
  assert (Option.is_none (Presets.startup_operation ~selected:custom initialized));
  let edited_legacy = { initial with configuration_pending = false } in
  assert (
    Option.equal
      W.Operation.equal
      (Presets.startup_operation edited_legacy)
      (Some Presets.bootstrap))
;;

let%test_unit "complete stock spec roundtrips and is accepted as startup input" =
  let text = Presets.export_config () |> Or_error.ok_exn in
  let actual = Workspace_config.Resolved.decode text |> Or_error.ok_exn in
  assert (Workspace_config.equal actual Presets.stock_config);
  let resolved =
    Presets.decode text |> Or_error.ok_exn |> Presets.resolve |> Or_error.ok_exn
  in
  List.iter Workspace_config.builtin_ids ~f:(fun key ->
    let stock = Presets.builtins key |> Or_error.ok_exn in
    Workspace_config.validate_definition stock |> Or_error.ok_exn;
    let wrapper =
      List.find_exn Presets.all ~f:(fun d -> String.equal d.Definition.id key)
    in
    assert (Workspace_template.equal (Definition.template wrapper) stock.template);
    assert (List.length wrapper.tiles = List.length stock.tiles));
  assert (List.length resolved.windows = 1);
  assert (List.length (List.hd_exn resolved.windows).workspaces = 5);
  assert (Result.is_error (Presets.builtins "not-a-builtin"));
  (* An exported stock definition cannot be silently edited under a reserved ID. *)
  let changed =
    { actual with
      definitions =
        List.map actual.definitions ~f:(fun d ->
          { d with template = { d.template with name = "Shadow" } })
    }
  in
  let changed = Workspace_config.Resolved.encode changed |> Or_error.ok_exn in
  assert (Result.is_error (Presets.decode changed))
;;

let%test_unit "stock startup opens five ordered built-in workspaces" =
  assert (
    List.equal
      String.equal
      (List.map Presets.starters ~f:(fun d -> d.Definition.id))
      [ "overview"; "testing"; "waveforms"; "timing"; "resources" ]);
  let initial = Workspace.initial ~session_id:(Workspace.Session_id.of_string "merged") in
  let initialized =
    Workspace.apply initial (Presets.startup_operation initial |> Option.value_exn)
    |> Result.ok
    |> Option.value_exn
  in
  assert (
    List.equal
      String.equal
      (List.map initialized.workspaces ~f:(fun w -> w.name))
      [ "Overview"; "Testing"; "Waveforms"; "Timing"; "Resources" ]);
  (* Legacy bootstrap still targets only the two original placeholders. A catalog upgrade
     must not silently add Testing to a saved/edited legacy session. *)
  let legacy = { initial with configuration_pending = false } in
  let restored =
    Workspace.apply legacy Presets.bootstrap |> Result.ok |> Option.value_exn
  in
  assert (List.length restored.workspaces = 2);
  assert (Option.is_none (Presets.startup_operation restored));
  assert (
    Workspace.Snapshot.equal
      restored
      (Workspace.apply restored Presets.bootstrap |> Result.ok |> Option.value_exn))
;;

let%test_unit "Timing excludes simulation catalog while Testing retains it" =
  assert (
    not (List.mem (kinds Timing.definition) "simulation-catalog" ~equal:String.equal));
  assert (List.mem (kinds Testing.definition) "simulation-catalog" ~equal:String.equal);
  let builtin = Presets.builtins "timing" |> Or_error.ok_exn in
  assert (
    not
      (List.exists builtin.template.views ~f:(fun view ->
         String.equal view.kind "simulation-catalog")))
;;

let%test_unit "merged stock content and presentation survive the schema projection" =
  assert (
    List.equal
      String.equal
      (kinds Testing.definition)
      [ "workspace-tabs"
      ; "live-status"
      ; "project-tests"
      ; "execution"
      ; "simulation-catalog"
      ; "simulation-attempts"
      ; "simulation-cases"
      ; "simulation-detail"
      ; "simulation-artifacts"
      ; "simulation-logs"
      ]);
  List.iter Testing.definition.tiles ~f:(fun tile ->
    let p = tile.Common.presentation in
    assert (Option.equal String.equal p.binding_badge (Some "hidden"));
    assert (Option.equal Int.equal p.padding (Some 0));
    assert (Option.equal Bool.equal p.hints (Some false));
    if not (String.equal tile.kind "workspace-tabs")
    then (
      assert (Option.equal Bool.equal p.run_reference (Some false));
      assert (Option.equal Bool.equal p.compact_summary (Some true))));
  List.iter [ Overview.definition; Timing.definition ] ~f:(fun d ->
    let selector = Definition.presentation d ~kind:"run-selector" |> Option.value_exn in
    assert (Option.equal Int.equal selector.visible_rows (Some 4)));
  let checklist =
    Definition.presentation Overview.definition ~kind:"stage-checklist"
    |> Option.value_exn
  in
  assert (Option.equal Bool.equal checklist.horizontal_stages (Some false));
  List.iter Presets.all ~f:(fun d ->
    (* WB-007 explicitly ships as an opt-in tile, without changing preset membership. *)
    assert (not (List.mem (kinds d) "hierarchy" ~equal:String.equal)))
;;

let%test_unit "stock navigation follows layout subtrees even with shuffled Runs last" =
  let cases =
    [ ( Overview.definition
      , [ "workspace-tabs"
        ; "live-status"
        ; "run-selector"
        ; "resource-summary"
        ; "stage-checklist"
        ; "planned-run"
        ; "preparation"
        ; "synthesis"
        ; "timing"
        ; "placement"
        ; "routing"
        ; "checks"
        ; "finalization"
        ] )
    ; ( Testing.definition
      , [ "workspace-tabs"
        ; "live-status"
        ; "project-tests"
        ; "execution"
        ; "simulation-catalog"
        ; "simulation-attempts"
        ; "simulation-cases"
        ; "simulation-detail"
        ; "simulation-artifacts"
        ; "simulation-logs"
        ] )
    ; ( Waveforms.definition
      , [ "workspace-tabs"
        ; "waveform-session"
        ; "waveform-signals"
        ; "waveform-waves"
        ; "waveform-picker"
        ; "waveform-logs"
        ] )
    ; ( Timing.definition
      , [ "workspace-tabs"
        ; "live-status"
        ; "run-selector"
        ; "timing-paths"
        ; "timing-detail"
        ; "timing-context"
        ] )
    ]
  in
  List.iter cases ~f:(fun (definition, expected) ->
    let shuffled =
      List.rev (kinds definition)
      |> List.partition_tf ~f:(fun kind -> not (String.equal kind "run-selector"))
      |> fun (others, runs) -> others @ runs
    in
    List.iter
      [ kinds definition; shuffled ]
      ~f:(fun input ->
        let order = Layout.navigation_order definition ~kinds:input in
        assert (List.equal String.equal (List.map order ~f:(List.nth_exn input)) expected);
        assert (
          List.equal
            Int.equal
            (List.sort order ~compare:Int.compare)
            (List.range 0 (List.length input)))))
;;

let%test_unit "navigation skips missing leaves and appends duplicate and custom extras" =
  let input =
    [ "custom-first"
    ; "timing"
    ; "run-selector"
    ; "custom-last"
    ; "live-status"
    ; "run-selector"
    ; "planned-run"
    ]
  in
  assert (
    List.equal
      Int.equal
      (Layout.navigation_order Overview.definition ~kinds:input)
      [ 4; 2; 6; 1; 0; 3; 5 ]);
  assert (
    List.equal
      Int.equal
      (Layout.navigation_order Overview.definition ~kinds:[ "unknown"; "unknown" ])
      [ 0; 1 ])
;;

let%test_unit "nested navigation completes columns and treats Narrow as transparent" =
  let leaf kind : Common.tree =
    Leaf { kind; min_width = 24; min_height = 6; weight = 1 }
  in
  let definition =
    { Overview.definition with
      layout =
        Stack
          [ Columns
              [ Narrow (Stack [ leaf "b"; leaf "a" ])
              ; Weighted_columns
                  [ 3, leaf "missing"; 1, leaf "c"; 9, Stack [ leaf "a"; leaf "d" ] ]
              ]
          ; leaf "b"
          ; leaf "b"
          ]
    }
  in
  (* Repeated references consume distinct matching inputs, then disappear when exhausted.
     Column weights do not change traversal order. *)
  assert (
    List.equal
      Int.equal
      (Layout.navigation_order
         definition
         ~kinds:[ "extra"; "a"; "d"; "b"; "c"; "a"; "b"; "tail" ])
      [ 3; 1; 4; 5; 2; 6; 0; 7 ])
;;

let%test_unit "empty navigation trees retain every input as a stable extra" =
  List.iter
    [ Common.Stack []; Columns []; Weighted_columns []; Narrow (Stack []) ]
    ~f:(fun layout ->
      let definition = { Overview.definition with layout } in
      assert (List.is_empty (Layout.navigation_order definition ~kinds:[]));
      assert (
        List.equal
          Int.equal
          (Layout.navigation_order definition ~kinds:[ "b"; "a"; "b" ])
          [ 0; 1; 2 ]));
  List.iter Presets.all ~f:(fun definition ->
    assert (List.is_empty (Layout.navigation_order definition ~kinds:[])))
;;

let%test_unit "navigation leaves computed geometry associated with original input indices"
  =
  let definition = Overview.definition in
  let original = kinds definition in
  let shuffled =
    List.rev
      (List.filter original ~f:(fun kind -> not (String.equal kind "run-selector")))
    @ [ "run-selector" ]
  in
  let compute kinds =
    match Layout.compute definition ~width:180 ~height:80 ~kinds with
    | Compact -> assert false
    | Grid cells -> cells
  in
  let baseline = List.zip_exn original (compute original) in
  let before = compute shuffled in
  assert (
    not
      (List.equal
         Int.equal
         (Layout.navigation_order definition ~kinds:shuffled)
         (List.range 0 (List.length shuffled))));
  let after = compute shuffled in
  assert (List.equal Workspace.Geometry.equal before after);
  List.iter2_exn shuffled after ~f:(fun kind cell ->
    assert (
      Workspace.Geometry.equal
        cell
        (List.Assoc.find_exn baseline kind ~equal:String.equal)))
;;

let%test_unit "custom spec addresses duplicate kinds by keys and uses bounded fallback" =
  let config =
    Presets.custom_example () |> Or_error.ok_exn |> Presets.resolve |> Or_error.ok_exn
  in
  let spec = List.hd_exn config.definitions in
  let d = Definition.of_spec spec in
  let keys = List.map spec.tiles ~f:(fun t -> t.Workspace_config.Tile.key) in
  assert (List.equal String.equal (kinds d) [ "run-selector"; "synthesis"; "synthesis" ]);
  assert (List.equal Int.equal (Layout.navigation_order d ~kinds:keys) [ 0; 2; 1 ]);
  assert (
    List.equal
      Int.equal
      (Layout.navigation_order d ~kinds:[ "left"; "extra"; "right"; "choose" ])
      [ 3; 2; 0; 1 ]);
  assert (
    List.equal
      Int.equal
      (Layout.navigation_order d ~kinds:[ "left"; "extra"; "choose"; "left" ])
      [ 2; 0; 1; 3 ]);
  (match Layout.compute d ~width:100 ~height:30 ~kinds:keys with
   | Compact -> assert false
   | Grid cells ->
     (* Right is the second synthesis, deliberately placed before Left. *)
     assert ((List.nth_exn cells 2).x < (List.nth_exn cells 1).x));
  (match Layout.compute d ~width:10 ~height:3 ~kinds:keys with
   | Compact -> ()
   | Grid _ -> assert false);
  (match Layout.compute d ~width:100 ~height:45 ~kinds:[ "right"; "extra:tile" ] with
   | Compact -> assert false
   | Grid cells -> assert (List.length cells = 2));
  let left = List.nth_exn spec.tiles 1
  and right = List.nth_exn spec.tiles 2 in
  assert (Option.is_some left.presentation && Option.is_some right.presentation);
  assert (Option.is_none (Option.value_exn right.presentation).compact_summary)
;;

let%test_unit "Overview identity cannot override a supplied shared-spec tree" =
  let stock = Presets.builtins "overview" |> Or_error.ok_exn in
  let leaf tile : Workspace_config.Tree.t =
    Leaf { tile; min_width = 24; min_height = 6; weight = 1 }
  in
  let spec = { stock with layout = Some (Columns [ leaf "timing"; leaf "synthesis" ]) } in
  let definition = Definition.of_spec spec in
  let compute definition =
    Layout.compute definition ~width:100 ~height:20 ~kinds:[ "synthesis"; "timing" ]
  in
  match compute definition, compute { definition with id = "custom-overview" } with
  | Grid [ synthesis; timing ], Grid renamed ->
    assert (synthesis.x = 50 && synthesis.width = 50);
    assert (timing.x = 0 && timing.width = 50);
    assert (List.equal Workspace.Geometry.equal [ synthesis; timing ] renamed)
  | _ -> assert false
;;

let%test_unit "Waveforms identity cannot replace a user tree with a stock-only layout" =
  let stock = Presets.builtins "waveforms" |> Or_error.ok_exn in
  let leaf tile : Workspace_config.Tree.t =
    Leaf { tile; min_width = 24; min_height = 6; weight = 1 }
  in
  let spec =
    { stock with
      layout = Some (Columns [ leaf "waveform-waves"; leaf "waveform-signals" ])
    }
  in
  let definition = Definition.of_spec spec in
  let compute definition =
    Layout.compute
      definition
      ~width:100
      ~height:20
      ~kinds:[ "waveform-signals"; "waveform-waves" ]
  in
  match compute definition, compute { definition with id = "custom-waves" } with
  | Grid [ signals; waves ], Grid renamed ->
    assert (waves.x = 0 && waves.width = 50);
    assert (signals.x = 50 && signals.width = 50);
    assert (List.equal Workspace.Geometry.equal [ signals; waves ] renamed)
  | _ -> assert false
;;

let%test_unit "legacy Waveforms creation is atomic, durable and identified by preset" =
  let module F = Waveforms in
  let before =
    Workspace.initial ~session_id:(Workspace.Session_id.of_string "waveforms")
  in
  let apply snapshot operation =
    Workspace.apply snapshot operation |> Result.ok |> Option.value_exn
  in
  let initialized = apply before Presets.bootstrap in
  assert (Option.is_none (F.find initialized));
  assert (
    List.exists Presets.starters ~f:(fun d ->
      String.equal d.Definition.id F.definition.id));
  let after =
    apply
      initialized
      (Mutate
         { expected_revision = initialized.revision
         ; mutation = F.create ~window:(List.hd_exn initialized.windows).id
         })
  in
  let workspace = Option.value_exn (F.created ~before:initialized ~after) in
  assert (after.revision = initialized.revision + 1);
  assert (Option.is_none (F.created ~before:after ~after));
  assert (
    Option.is_none
      (F.created
         ~before
         ~after:{ after with session_id = Workspace.Session_id.of_string "other" }));
  let renamed =
    apply
      after
      (Mutate
         { expected_revision = after.revision
         ; mutation = Rename_workspace { workspace = workspace.id; name = "Pinned FIFO" }
         })
  in
  let restored = Workspace.Snapshot.t_of_sexp (Workspace.Snapshot.sexp_of_t renamed) in
  assert (
    Workspace.Workspace_id.equal (Option.value_exn (F.find restored)).id workspace.id);
  let actual =
    List.filter restored.tiles ~f:(fun tile ->
      Workspace.Workspace_id.equal tile.workspace workspace.id)
  in
  assert (
    List.equal
      String.equal
      (List.map actual ~f:(fun tile -> tile.kind))
      (kinds F.definition));
  assert (List.length (F.members restored workspace.id) = 4);
  Workspace.export_template restored workspace.id
  |> Result.ok
  |> Option.value_exn
  |> Workspace_template.validate
  |> Or_error.ok_exn
;;

let%test_unit "Waveforms Session stacks over Signals beside full-height Waves without \
               overlaps"
  =
  let d = Waveforms.definition in
  List.iter
    [ 80, 22; 120, 38; 230, 53 ]
    ~f:(fun (width, height) ->
      match Layout.compute d ~width ~height ~kinds:(kinds d) with
      | Compact -> assert false
      | Grid cells ->
        assert (List.length cells = 6);
        let navigation = List.hd_exn cells in
        assert (
          navigation.x = 0
          && navigation.y = 0
          && navigation.width = width
          && navigation.height = 1);
        let session = List.nth_exn cells 1 in
        assert (
          session.x = 0
          && session.y = 1
          && session.width = Int.max 24 (width / 5)
          && session.height = 4);
        let signals = List.nth_exn cells 2
        and waves = List.nth_exn cells 3 in
        assert (signals.x = session.x && signals.width = session.width);
        assert (waves.x = session.x + session.width && waves.y = session.y);
        assert (signals.y = session.y + session.height);
        assert (signals.width >= 24 && waves.width >= signals.width);
        assert (waves.width = width - session.width);
        assert (waves.height = session.height + signals.height);
        let picker = List.nth_exn cells 4
        and logs = List.nth_exn cells 5 in
        assert (picker.y >= signals.y + signals.height);
        assert (picker.y = waves.y + waves.height);
        assert (logs.y = picker.y && logs.x = picker.x + picker.width);
        assert (picker.height >= 6 && logs.height >= 6);
        assert (picker.width >= 24 && logs.width >= 24);
        List.iteri cells ~f:(fun i (a : Workspace.Geometry.t) ->
          assert (a.x >= 0 && a.y >= 0 && a.width >= 24 && a.height >= 1);
          assert (a.x + a.width <= width && a.y + a.height <= height);
          List.iter
            (List.drop cells (i + 1))
            ~f:(fun b ->
              assert (
                a.x + a.width <= b.x
                || b.x + b.width <= a.x
                || a.y + a.height <= b.y
                || b.y + b.height <= a.y))))
;;

let%test_unit "Waveforms Session upgrade is explicit additive and preserves custom \
               arrangement"
  =
  let module W = Workspace in
  let before = W.initial ~session_id:(W.Session_id.of_string "session-upgrade") in
  let apply snapshot mutation =
    W.apply
      snapshot
      (Mutate { expected_revision = snapshot.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let template = Definition.template Waveforms.definition in
  let template =
    { template with
      views =
        List.filter template.views ~f:(fun view ->
          not (String.equal view.kind (Waveforms.kind Session)))
    }
  in
  let legacy =
    apply
      before
      (Instantiate_template { window = (List.hd_exn before.windows).id; template })
  in
  let workspace = Option.value_exn (Waveforms.find legacy) in
  let signals =
    List.find_exn legacy.tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace workspace.id
      && String.equal tile.kind (Waveforms.kind Signals))
  in
  let legacy =
    apply
      legacy
      (Resize_tile
         { tile = signals.id; geometry = { x = 9; y = 7; width = 44; height = 15 } })
  in
  let legacy = apply legacy (Set_tile_hidden { tile = signals.id; hidden = true }) in
  let legacy =
    apply
      legacy
      (Create_tile
         { workspace = workspace.id
         ; kind = "custom-extra"
         ; geometry = signals.requested_geometry
         })
  in
  let legacy =
    apply
      legacy
      (Set_zoom { workspace = workspace.id; tile = Some (List.last_exn legacy.tiles).id })
  in
  let upgraded =
    apply legacy (Definition.apply Waveforms.definition ~workspace:workspace.id)
  in
  assert (List.length upgraded.tiles = List.length legacy.tiles + 1);
  List.iter legacy.tiles ~f:(fun tile ->
    assert (W.Tile.equal tile (W.tile upgraded tile.id)));
  assert (List.equal W.Context.equal legacy.contexts upgraded.contexts);
  assert (
    W.Arrangement.equal
      (W.workspace legacy workspace.id)
      (W.workspace upgraded workspace.id));
  assert (
    List.equal
      [%equal: string * string]
      (Waveforms.members legacy workspace.id)
      (Waveforms.members upgraded workspace.id));
  let session = List.last_exn upgraded.tiles in
  assert (String.equal session.kind (Waveforms.kind Session));
  assert (session.requested_geometry.height = 4 && not session.hidden);
  let restored =
    apply upgraded (Definition.restore Waveforms.definition ~workspace:workspace.id)
  in
  assert (Option.is_none (W.workspace restored workspace.id).zoomed_tile);
  assert (not (W.tile restored signals.id).hidden);
  assert (W.tile restored (List.last_exn legacy.tiles).id).hidden
;;

let%test_unit "Waveforms log provenance rejects another daemon instance" =
  let module F = Waveforms in
  let instance_id = V1.Daemon_instance_id.of_string "original" in
  let artifact : Simulation.Artifact.t =
    { id = "vcd"
    ; attempt_id = "attempt"
    ; case_id = Some "case"
    ; label = "trace"
    ; kind = "waveform"
    ; media_type = "text/x-vcd"
    ; size = Some 10
    ; sha256 = Some "digest"
    ; availability = Available
    }
  in
  let job = Job_id.of_string "job-1" in
  let pin : F.pin =
    { project_key = "/project/env"
    ; project = Project_id.of_string "project"
    ; artifact
    ; log = Job { instance_id; job }
    }
  in
  assert (Job_id.equal job (F.log_job pin ~instance_id |> Or_error.ok_exn));
  assert (
    Result.is_error
      (F.log_job pin ~instance_id:(V1.Daemon_instance_id.of_string "replacement")));
  assert (
    Result.is_error (F.log_job { pin with log = Unavailable "expired" } ~instance_id))
;;

let%test_unit "cooperative Testing is bounded, readable and project scoped" =
  let d = Testing.definition in
  assert (not (List.mem (kinds d) "run-selector" ~equal:String.equal));
  assert (not (List.mem (kinds d) "simulation" ~equal:String.equal));
  List.iter
    [ 120, 40; 180, 55; 80, 24 ]
    ~f:(fun (width, height) ->
      match Layout.compute d ~width ~height:(height - 2) ~kinds:(kinds d) with
      | Compact -> assert (width = 80)
      | Grid cells ->
        assert (List.length cells = List.length d.tiles);
        List.iteri cells ~f:(fun i a ->
          assert (a.Workspace.Geometry.x >= 0 && a.y >= 0);
          assert (a.width >= 24 && a.height >= 1);
          assert (a.x + a.width <= width && a.y + a.height <= height - 2);
          List.iter
            (List.drop cells (i + 1))
            ~f:(fun b ->
              assert (
                a.x + a.width <= b.x
                || b.x + b.width <= a.x
                || a.y + a.height <= b.y
                || b.y + b.height <= a.y)));
        if width >= 120
        then (
          let cell kind =
            List.nth_exn
              cells
              (List.findi_exn (kinds d) ~f:(fun _ k -> String.equal kind k) |> fst)
          in
          assert ((cell "live-status").width = width / 4);
          assert ((cell "simulation-catalog").width = (width * 5 / 8) - (width / 4));
          assert ((cell "simulation-detail").width = width - (width * 5 / 8));
          List.iter [ "simulation-catalog"; "simulation-detail" ] ~f:(fun kind ->
            let g = cell kind in
            assert (g.width >= 45 && g.height >= 12));
          List.iter
            [ "simulation-attempts"
            ; "simulation-cases"
            ; "simulation-artifacts"
            ; "simulation-logs"
            ]
            ~f:(fun kind -> assert ((cell kind).height >= 7))))
;;

let%test_unit "Timing thirds preserve investigation geometry" =
  List.iter [ Timing.definition ] ~f:(fun d ->
    List.iter
      [ 80, 24; 120, 40; 180, 55 ]
      ~f:(fun (width, terminal_height) ->
        let height = terminal_height - 2 in
        match Layout.compute d ~width ~height ~kinds:(kinds d) with
        | Compact -> assert false
        | Grid cells ->
          assert (List.length cells = List.length d.tiles);
          List.iteri cells ~f:(fun i (a : Workspace.Geometry.t) ->
            assert (a.x >= 0 && a.y >= 0 && a.width >= 24 && a.height >= 1);
            assert (a.x + a.width <= width && a.y + a.height <= height);
            List.iter
              (List.drop cells (i + 1))
              ~f:(fun b ->
                assert (
                  a.x + a.width <= b.x
                  || b.x + b.width <= a.x
                  || a.y + a.height <= b.y
                  || b.y + b.height <= a.y)));
          let cell kind =
            List.nth_exn
              cells
              (List.findi_exn (kinds d) ~f:(fun _ k -> String.equal kind k) |> fst)
          in
          if width = 80
          then List.iter cells ~f:(fun g -> assert (g.height >= 6))
          else (
            let session = cell "live-status"
            and selector = cell "run-selector" in
            assert ((cell "workspace-tabs").height = 1);
            assert (session.x = 0 && session.y = 1 && session.width = width / 3);
            assert (session.height = 7 && selector.height = 7);
            assert (selector.x = session.width && selector.width = width - session.width);
            assert (selector.y = session.y);
            let paths = cell "timing-paths"
            and detail = cell "timing-detail"
            and context = cell "timing-context" in
            assert (paths.x = 0 && paths.y = session.y + session.height);
            assert (paths.width >= 32 && paths.height >= 10);
            assert (detail.x = paths.width && detail.y = paths.y);
            assert (detail.width >= 48 && detail.height >= 10);
            assert (context.x = detail.x && context.width = detail.width);
            assert (context.y = detail.y + detail.height && context.height >= 8);
            assert (paths.height = detail.height + context.height);
            assert (context.y + context.height = height))))
;;

let%test_unit "Timing sparse membership retains duplicate and custom extras" =
  List.iter [ Timing.definition ] ~f:(fun d ->
    let ks =
      ("custom-provider"
       :: List.rev
            (List.filter (kinds d) ~f:(fun k ->
               not (List.mem [ "live-status"; "project-tests" ] k ~equal:String.equal))))
      @ [ "run-selector" ]
    in
    match Layout.compute d ~width:180 ~height:100 ~kinds:ks with
    | Compact -> assert false
    | Grid cells ->
      assert (List.length cells = List.length ks);
      let selector_index =
        List.findi_exn ks ~f:(fun _ k -> String.equal k "run-selector") |> fst
      in
      let selector = List.nth_exn cells selector_index
      and duplicate = List.last_exn cells
      and custom = List.hd_exn cells in
      assert (selector.height = 7 && selector.width = 180);
      assert (custom.width = 180 && duplicate.width = 180);
      assert (custom.y >= selector.y + selector.height);
      assert (duplicate.y >= custom.y + custom.height))
;;

let%test_unit "weighted widths and configurable gutters are full-rectangle partitions" =
  List.iter [ 0; 1 ] ~f:(fun gutter ->
    List.iter
      [ 120, 55; 180, 55 ]
      ~f:(fun (width, height) ->
        match
          Layout.compute
            ~gutter
            Overview.definition
            ~width
            ~height
            ~kinds:(kinds Overview.definition)
        with
        | Compact -> assert false
        | Grid cells ->
          let session = List.nth_exn cells 1 in
          let synthesis = List.nth_exn cells 4 in
          assert (Int.abs (session.width - ((width - gutter) / 3)) <= 1);
          assert (synthesis.x = session.width + gutter);
          assert (synthesis.x + synthesis.width = width)));
  let d = Overview.definition in
  let ks = kinds d in
  let selector required =
    match
      Layout.compute d ~width:120 ~height:38 ~kinds:ks ~min_height_for_index:(fun i ->
        if i = 2 then Some required else None)
    with
    | Compact -> assert false
    | Grid cells -> List.nth_exn cells 2
  in
  assert ((selector 12).height > (selector 7).height)
;;

let%test_unit "runtime minima change real selector geometry, including duplicate fallback"
  =
  let d = Overview.definition in
  let ks = kinds d in
  let selector_index =
    List.findi_exn ks ~f:(fun _ k -> String.equal k "run-selector") |> fst
  in
  let compute required =
    Layout.compute
      ~min_height_for_index:(fun i -> if i = selector_index then Some required else None)
      d
      ~width:120
      ~height:60
      ~kinds:ks
  in
  (match compute 14 with
   | Compact -> assert false
   | Grid cells -> assert ((List.nth_exn cells selector_index).height = 14));
  (match compute 80 with
   | Compact -> ()
   | Grid _ -> assert false);
  let ks = [ "custom"; "run-selector"; "run-selector" ] in
  match
    Layout.compute
      ~min_height_for_index:(fun i -> if i = 2 then Some 17 else None)
      d
      ~width:80
      ~height:60
      ~kinds:ks
  with
  | Compact -> assert false
  | Grid cells -> assert ((List.nth_exn cells 2).height >= 17)
;;

let%test_unit "actual terminal content bounds at80x24,120x40,large" =
  let d = Overview.definition in
  List.iter
    [ 80, 24; 120, 40; 240, 80 ]
    ~f:(fun (width, terminal_height) ->
      let height = terminal_height - 2 in
      match Layout.compute d ~width ~height ~kinds:(kinds d) with
      | Compact -> assert (width = 80)
      | Grid cells ->
        assert (List.length cells = 13);
        List.iteri cells ~f:(fun i (a : Workspace.Geometry.t) ->
          assert (a.x >= 0 && a.y >= 0 && a.width > 0 && a.height > 0);
          assert (a.x + a.width <= width && a.y + a.height <= height);
          List.iter
            (List.drop cells (i + 1))
            ~f:(fun b ->
              assert (
                a.x + a.width <= b.x
                || b.x + b.width <= a.x
                || a.y + a.height <= b.y
                || b.y + b.height <= a.y))))
;;

let%test_unit "one-third sidebar splits stages and plan above six full-width domains" =
  let d = Overview.definition in
  (* Reserve two rows for the host's global header/footer at 120x40. *)
  match Layout.compute d ~width:120 ~height:38 ~kinds:(kinds d) with
  | Compact -> assert false
  | Grid cells ->
    let cell kind =
      List.nth_exn
        cells
        (List.findi_exn (kinds d) ~f:(fun _ k -> String.equal kind k) |> fst)
    in
    let session = cell "live-status"
    and selector = cell "run-selector" in
    assert (session.width = 40 && session.height = Overview.session_height);
    assert (selector.x = session.x && selector.y = session.y + session.height);
    assert (selector.width = session.width && selector.height = Overview.selector_height);
    assert ((cell "resource-summary").y = selector.y + selector.height);
    assert ((cell "stage-checklist").y = (cell "resource-summary").y + 1);
    let stages = cell "stage-checklist"
    and plan = cell "planned-run" in
    assert (stages.x = 0 && stages.width = session.width);
    assert (plan.x = 0 && plan.width = session.width);
    assert (plan.y = stages.y + stages.height);
    assert (plan.y + plan.height = 38);
    assert (stages.height >= Overview.checklist_height);
    assert (plan.height >= Overview.planned_run_height);
    assert (Int.abs (stages.height - plan.height) <= 1);
    let bottom = ref session.y in
    List.iter
      [ "preparation"
      ; "synthesis"
      ; "timing"
      ; "placement"
      ; "routing"
      ; "checks"
      ; "finalization"
      ]
      ~f:(fun kind ->
        let g = cell kind in
        assert (g.x = 40 && g.width = 80 && g.height >= 5 && g.y = !bottom);
        bottom := g.y + g.height);
    assert (!bottom = 38);
    assert ((cell "workspace-tabs").height = 1)
;;

let%test_unit "six-row selector preserves readable stages and balanced plan at120x40" =
  let d = Overview.definition in
  List.iter [ 7; 9 ] ~f:(fun selector_height ->
    match
      Layout.compute
        d
        ~width:120
        ~height:38
        ~kinds:(kinds d)
        ~min_height_for_index:(fun i -> if i = 2 then Some selector_height else None)
    with
    | Compact -> assert false
    | Grid cells ->
      let selector = List.nth_exn cells 2
      and stages = List.nth_exn cells 3
      and plan = List.nth_exn cells 11 in
      assert (selector.height = selector_height);
      assert (stages.height >= 10 && plan.height >= 10);
      assert (Int.abs (stages.height - plan.height) <= 1);
      assert (stages.y = selector.y + selector.height + 1);
      assert (plan.y = stages.y + stages.height && plan.y + plan.height = 38))
;;

let%test_unit "shuffled membership keeps tile-to-cell association and duplicate extras" =
  let kinds =
    [ "timing"
    ; "workspace-tabs"
    ; "synthesis"
    ; "live-status"
    ; "run-selector"
    ; "stage-checklist"
    ; "checks"
    ; "run-selector"
    ; "custom"
    ]
  in
  match Layout.compute Overview.definition ~width:180 ~height:80 ~kinds with
  | Compact -> assert false
  | Grid cells ->
    assert (List.length cells = List.length kinds);
    let nav = List.nth_exn cells 1
    and session = List.nth_exn cells 3
    and selector = List.nth_exn cells 4
    and duplicate = List.nth_exn cells 7 in
    assert (nav.y = 0 && nav.height = 1);
    assert (session.x = 0 && session.height = 7);
    assert (
      selector.y = session.y + session.height && selector.x = 0 && selector.height = 7);
    assert (duplicate.y > (List.nth_exn cells 6).y)
;;

let%test_unit "all presets preserve extras and duplicates with bounded disjoint cells" =
  List.iter Presets.all ~f:(fun d ->
    List.iter
      [ 1, 1; 24, 3; 32, 8; 80, 24; 120, 40; 180, 60; 240, 100 ]
      ~f:(fun (width, height) ->
        List.iter (List.range 0 20) ~f:(fun count ->
          let ks =
            kinds d
            @ List.init count ~f:(fun i ->
              if i % 2 = 0 then "run-selector" else "custom-provider")
          in
          match Layout.compute d ~width ~height ~kinds:ks with
          | Compact -> ()
          | Grid cells ->
            assert (List.length cells = List.length ks);
            List.iteri cells ~f:(fun i (a : Workspace.Geometry.t) ->
              assert (a.width >= 24 && a.height >= 1 && a.x >= 0 && a.y >= 0);
              assert (a.x + a.width <= width && a.y + a.height <= height);
              List.iter
                (List.drop cells (i + 1))
                ~f:(fun b ->
                  assert (
                    a.x + a.width <= b.x
                    || b.x + b.width <= a.x
                    || a.y + a.height <= b.y
                    || b.y + b.height <= a.y))))));
  assert (
    match
      Layout.compute
        Overview.definition
        ~width:32
        ~height:8
        ~kinds:(kinds Overview.definition)
    with
    | Compact -> true
    | _ -> false)
;;

let%test_unit "stable identity selects definitions after rename" =
  let s = Workspace.initial ~session_id:(Workspace.Session_id.of_string "presets") in
  let w = List.hd_exn s.workspaces in
  let renamed = { w with name = "My debugging desk" } in
  assert (String.equal (Option.value_exn (Presets.for_arrangement renamed)).id "overview");
  let custom = { w with preset = None; name = "Timing" } in
  assert (Option.is_none (Presets.for_arrangement custom))
;;

let%test_unit "portable current starters come directly from the shared definitions" =
  List.iter Presets.all ~f:(fun d ->
    let template = Definition.template d in
    Workspace_template.validate template |> Or_error.ok_exn;
    assert (Option.equal String.equal template.preset (Some d.id));
    assert (
      List.equal String.equal (List.map template.views ~f:(fun v -> v.kind)) (kinds d));
    List.iter2_exn template.views d.tiles ~f:(fun view tile ->
      let g = view.geometry
      and h = tile.Common.geometry in
      assert (g.x = h.x && g.y = h.y && g.width = h.width && g.height = h.height)))
;;

let%test_unit "shared bootstrap completes after import and protects explicit user edits" =
  let ok = function
    | Ok s -> s
    | Error e -> raise_s [%sexp (e : V1.Error.t)]
  in
  let s = Workspace.initial ~session_id:(Workspace.Session_id.of_string "bootstrap") in
  let mutate (s : Workspace.Snapshot.t) mutation =
    Workspace.apply s (Mutate { expected_revision = s.revision; mutation }) |> ok
  in
  let first = List.hd_exn s.tiles in
  let geometry : Workspace.Geometry.t = { x = 3; y = 5; width = 33; height = 11 } in
  let s = mutate s (Resize_tile { tile = first.id; geometry }) in
  let s = mutate s (Set_tile_hidden { tile = first.id; hidden = true }) in
  let template =
    { (Definition.template Overview.definition) with
      name = "Sparse imported overview"
    ; views = []
    }
  in
  let s =
    mutate s (Instantiate_template { window = (List.hd_exn s.windows).id; template })
  in
  let imported = List.last_exn s.workspaces in
  let next = Workspace.apply s Presets.bootstrap |> ok in
  assert next.defaults_initialized;
  assert (Workspace.Tile.equal (Workspace.tile s first.id) (Workspace.tile next first.id));
  assert (
    Workspace_template.equal template (Workspace.export_template next imported.id |> ok));
  List.iter (List.take next.workspaces 2) ~f:(fun w ->
    let d = Presets.for_arrangement w |> Option.value_exn in
    let tiles =
      List.filter next.tiles ~f:(fun t -> Workspace.Workspace_id.equal t.workspace w.id)
    in
    assert (List.length tiles = List.length d.tiles);
    List.iter d.tiles ~f:(fun expected ->
      let tile =
        List.find_exn tiles ~f:(fun t -> String.equal t.kind expected.Common.kind)
      in
      if not (Workspace.Tile_id.equal tile.id first.id)
      then assert (Workspace.Geometry.equal tile.requested_geometry expected.geometry)));
  assert (Workspace.Snapshot.equal next (Workspace.apply next Presets.bootstrap |> ok))
;;

let%test_unit "unknown preset IDs never select a known definition by display name" =
  let s = Workspace.initial ~session_id:(Workspace.Session_id.of_string "unknown") in
  let w =
    { (List.hd_exn s.workspaces) with
      preset = Some "future-workspace"
    ; name = "Overview"
    }
  in
  assert (Option.is_none (Presets.for_arrangement w))
;;

let%test_unit "shared restore API repairs every preset in the captured renamed workspace" =
  let ok = function
    | Ok s -> s
    | Error e -> raise_s [%sexp (e : V1.Error.t)]
  in
  List.iter Presets.all ~f:(fun d ->
    let s =
      Workspace.initial ~session_id:(Workspace.Session_id.of_string "restore-api")
    in
    let w = List.hd_exn s.workspaces in
    let mutate (s : Workspace.Snapshot.t) mutation =
      Workspace.apply s (Mutate { expected_revision = s.revision; mutation }) |> ok
    in
    let first = List.hd_exn s.tiles in
    let s =
      mutate s (Rename_workspace { workspace = w.id; name = "Captured custom desk" })
    in
    let s = mutate s (Set_tile_hidden { tile = first.id; hidden = true }) in
    let s =
      mutate
        s
        (Create_tile
           { workspace = w.id
           ; kind = "custom-extra"
           ; geometry = first.requested_geometry
           })
    in
    let extra = List.last_exn s.tiles in
    let s = mutate s (Set_zoom { workspace = w.id; tile = Some extra.id }) in
    let mutation = Definition.restore d ~workspace:w.id in
    assert (
      Workspace.Mutation.equal
        mutation
        (Restore_default_layout
           { workspace = w.id; preset = d.id; tiles = Definition.specs d }));
    let next = mutate s mutation in
    assert (next.revision = s.revision + 1);
    assert (String.equal (Workspace.workspace next w.id).name "Captured custom desk");
    assert (Option.equal String.equal (Workspace.workspace next w.id).preset (Some d.id));
    assert (Option.is_none (Workspace.workspace next w.id).zoomed_tile);
    assert (List.equal Workspace.Context.equal s.contexts next.contexts);
    assert (
      Workspace.Tile.equal (Workspace.tile next extra.id) { extra with hidden = true });
    List.iter d.tiles ~f:(fun expected ->
      let actual =
        List.find_exn next.tiles ~f:(fun t ->
          Workspace.Workspace_id.equal t.workspace w.id
          && String.equal t.kind expected.Common.kind)
      in
      assert (not actual.hidden);
      assert (Workspace.Geometry.equal actual.requested_geometry expected.geometry));
    let visible =
      List.filter next.tiles ~f:(fun t ->
        Workspace.Workspace_id.equal t.workspace w.id && not t.hidden)
    in
    assert (List.length visible = List.length d.tiles);
    let repeated = mutate next mutation in
    assert (Workspace.Snapshot.equal { next with revision = repeated.revision } repeated))
;;

let%test_unit "explicit Overview restore adopts Preparation in saved legacy and config \
               layouts"
  =
  let module W = Workspace in
  let ok = function
    | Ok value -> value
    | Error error -> raise_s [%sexp (error : V1.Error.t)]
  in
  let mutate (s : W.Snapshot.t) mutation =
    W.apply s (Mutate { expected_revision = s.revision; mutation }) |> ok
  in
  (* Model a previously shipped stock catalog, with no Preparation membership. Its
     persisted definition must not shadow the current explicit Restore definition. *)
  let old_config =
    { Presets.stock_config with
      definitions =
        List.map Presets.stock_config.definitions ~f:(fun d ->
          if not (String.equal d.key "overview")
          then d
          else (
            let views, tiles =
              List.zip_exn d.template.views d.tiles
              |> List.filter ~f:(fun (view, _) ->
                not (String.equal view.kind "preparation"))
              |> List.unzip
            in
            { d with template = { d.template with views }; tiles; layout = None }))
    }
  in
  List.iter [ false; true ] ~f:(fun configured ->
    let initial = W.initial ~session_id:(W.Session_id.of_string "old-overview") in
    let saved = W.apply initial (Initialize_config old_config) |> ok in
    let saved =
      if configured
      then saved
      else { saved with config_windows = []; config_workspaces = [] }
    in
    let workspace = List.hd_exn saved.workspaces in
    let synthesis =
      List.find_exn saved.tiles ~f:(fun t ->
        W.Workspace_id.equal t.workspace workspace.id && String.equal t.kind "synthesis")
    in
    let run : Run_ref.t =
      { backend = Backend_id.of_string "saved-provider"
      ; id = "pinned-run"
      ; build = None
      ; label = Some "Keep this pin"
      }
    in
    let saved =
      mutate saved (Set_tile_binding { tile = synthesis.id; binding = Pin_run run })
    in
    let saved = mutate saved (Set_tile_hidden { tile = synthesis.id; hidden = true }) in
    let saved =
      mutate saved (Rename_workspace { workspace = workspace.id; name = "My Overview" })
    in
    let saved =
      mutate
        saved
        (Create_tile
           { workspace = workspace.id
           ; kind = "custom-extra"
           ; geometry = synthesis.requested_geometry
           })
    in
    let extra = List.last_exn saved.tiles in
    let saved =
      mutate saved (Set_tile_binding { tile = extra.id; binding = Pin_run run })
    in
    let saved =
      mutate saved (Set_zoom { workspace = workspace.id; tile = Some extra.id })
    in
    (* Rehydration/reconnect preserves user intent; adoption is an explicit command. *)
    let saved = W.Snapshot.t_of_sexp (W.Snapshot.sexp_of_t saved) in
    W.validate saved |> ok;
    assert (Option.is_none (Presets.startup_operation saved));
    assert (not (List.exists saved.tiles ~f:(fun t -> String.equal t.kind "preparation")));
    let restored =
      mutate saved (Definition.restore Overview.definition ~workspace:workspace.id)
    in
    assert (List.length restored.tiles = List.length saved.tiles + 1);
    assert (List.equal W.Context.equal saved.contexts restored.contexts);
    assert (String.equal (W.workspace restored workspace.id).name "My Overview");
    assert (Option.is_none (W.workspace restored workspace.id).zoomed_tile);
    List.iter saved.tiles ~f:(fun tile ->
      let actual = W.tile restored tile.id in
      assert (W.Binding.equal tile.binding actual.binding);
      assert (String.equal tile.kind actual.kind);
      assert (W.Workspace_id.equal tile.workspace actual.workspace);
      if not (W.Workspace_id.equal tile.workspace workspace.id)
      then assert (W.Tile.equal tile actual));
    assert (not (W.tile restored synthesis.id).hidden);
    assert (
      W.Tile.equal
        (W.tile restored extra.id)
        { (W.tile saved extra.id) with hidden = true });
    List.iter restored.config_workspaces ~f:(fun origin ->
      if W.Workspace_id.equal origin.workspace workspace.id
      then assert origin.policy_detached);
    let hydrated = W.Snapshot.t_of_sexp (W.Snapshot.sexp_of_t restored) in
    W.validate hydrated |> ok;
    assert (W.Snapshot.equal hydrated restored);
    let template = W.export_template hydrated workspace.id |> ok in
    let template =
      Workspace_template.encode template
      |> Or_error.ok_exn
      |> Workspace_template.decode
      |> Or_error.ok_exn
    in
    let preparation =
      List.find_exn template.views ~f:(fun v -> String.equal v.kind "preparation")
    in
    assert (not preparation.hidden);
    assert (preparation.geometry.height = 7);
    let visible =
      List.filter hydrated.tiles ~f:(fun t ->
        W.Workspace_id.equal t.workspace workspace.id && not t.hidden)
    in
    (* Restore appends the new tile, rather than changing IDs/order to match the authoring
       list. Fit must still put Preparation above Synthesis. *)
    List.iter
      [ 120, 40; 180, 55 ]
      ~f:(fun (width, terminal_height) ->
        let height = terminal_height - 2 in
        match
          Layout.compute
            Overview.definition
            ~width
            ~height
            ~kinds:(List.map visible ~f:(fun t -> t.kind))
        with
        | Compact -> assert false
        | Grid cells ->
          let cell kind =
            List.zip_exn visible cells
            |> List.find_exn ~f:(fun (tile, _) -> String.equal tile.kind kind)
            |> snd
          in
          let prep = cell "preparation" in
          assert (prep.x = width / 3 && prep.y = 1);
          assert (prep.width = width - (width / 3) && prep.height = 7);
          assert ((cell "synthesis").y = prep.y + prep.height);
          List.iteri cells ~f:(fun i (a : W.Geometry.t) ->
            assert (a.x >= 0 && a.y >= 0 && a.width > 0 && a.height > 0);
            assert (a.x + a.width <= width && a.y + a.height <= height);
            List.iter
              (List.drop cells (i + 1))
              ~f:(fun b ->
                assert (
                  a.x + a.width <= b.x
                  || b.x + b.width <= a.x
                  || a.y + a.height <= b.y
                  || b.y + b.height <= a.y))));
    let repeated =
      mutate hydrated (Definition.restore Overview.definition ~workspace:workspace.id)
    in
    assert (W.Snapshot.equal { hydrated with revision = repeated.revision } repeated))
;;

let%test_unit "sparse membership and resize thresholds never overflow or overlap" =
  let all = kinds Overview.definition in
  List.iter
    (List.range 0 (1 lsl List.length all))
    ~f:(fun mask ->
      let kinds = List.filteri all ~f:(fun i _ -> mask land (1 lsl i) <> 0) in
      List.iter
        [ 0, 0; 23, 5; 24, 6; 48, 16; 49, 16; 74, 23; 80, 22; 120, 31; 120, 32; 120, 38 ]
        ~f:(fun (width, height) ->
          match Layout.compute Overview.definition ~width ~height ~kinds with
          | Compact -> ()
          | Grid cells ->
            assert (List.length cells = List.length kinds);
            List.iteri cells ~f:(fun i (a : Workspace.Geometry.t) ->
              assert (a.width >= 24 && a.height > 0 && a.x >= 0 && a.y >= 0);
              assert (a.x + a.width <= width && a.y + a.height <= height);
              List.iter
                (List.drop cells (i + 1))
                ~f:(fun b ->
                  assert (
                    a.x + a.width <= b.x
                    || b.x + b.width <= a.x
                    || a.y + a.height <= b.y
                    || b.y + b.height <= a.y)))))
;;
