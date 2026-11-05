open! Core
open Hardcaml_workbench_protocol
module H = Workspace_host
module P = Hardcaml_workbench_workspaces

let%test_unit "WB-065 late inspection receipts cannot retarget selection or reconnect \
               notices"
  =
  let host, _, find = Host_view.refinement_fixture P.Timing.definition in
  let paths = find "timing-paths" in
  let host = H.set_local host paths.id (H.local host paths.id) in
  let host =
    H.set_timing
      host
      paths
      (Timing_workspace.create ~generation:7 ~run:Fs0_fixture.run_a ~stage:"signoff")
  in
  let original = Option.value_exn (H.inspection host paths.id) in
  let identity = (H.local host paths.id).identity in
  let ticket = Inspection_view.capture original (Inspection_view.operation original) in
  let receipt host ticket response =
    Evidence_activity.inspection_receipt
      host
      ~tile_id:paths.id
      ~identity
      ~ticket
      ~publish_notice:true
      response
  in
  let select host run =
    let registry = Option.value_exn host.H.registry in
    let workspace = Workspace.workspace registry paths.workspace in
    let context = Workspace.context registry workspace.context in
    let registry =
      Workspace.apply_mutation
        registry
        (Select_run
           { workspace = workspace.id
           ; context = context.id
           ; expected_selection_revision = context.selection_revision
           ; run = Some run
           })
    in
    H.receive host registry
  in
  let changed = select host Fs0_fixture.run_b in
  let changed =
    H.set_timing
      changed
      paths
      (Timing_workspace.create ~generation:8 ~run:Fs0_fixture.run_b ~stage:"signoff")
  in
  let assert_ignored host ticket =
    let host = { host with H.notice = "newer selection notice" } in
    let before = Option.value_exn (H.inspection host paths.id) in
    List.iter [ Ok (); Error "obsolete inspection failed" ] ~f:(fun response ->
      let after = receipt host ticket response in
      assert (String.equal after.notice host.notice);
      let view = Option.value_exn (H.inspection after paths.id) in
      assert (view.generation = before.generation);
      assert (Run_ref.equal view.run before.run);
      assert (Option.equal String.equal view.error before.error);
      assert (Option.equal String.equal view.selected before.selected);
      assert (Option.equal String.equal view.operation_key before.operation_key);
      assert (Option.equal [%equal: string * string] view.requested before.requested))
  in
  assert_ignored changed ticket;
  (* Return to the same run/stage before the old response arrives. The workspace epoch,
     not just equal-looking selection labels, must distinguish this new intention. *)
  let returned = select changed Fs0_fixture.run_a in
  let returned = H.set_timing returned paths { original with generation = 9 } in
  assert_ignored returned ticket;
  let current = Option.value_exn (H.inspection returned paths.id) in
  let before_reconnect =
    Inspection_view.capture current (Inspection_view.operation current)
  in
  let reconnected = H.reconnect returned ~replacement:false in
  assert_ignored reconnected before_reconnect;
  let current = Option.value_exn (H.inspection reconnected paths.id) in
  assert (Option.is_none current.requested && Option.is_none current.operation_key);
  (* Positive control: the reconnect's own receipt still reaches both the view and global
     notice; fencing obsolete callbacks must not suppress current failures. *)
  let fresh = Inspection_view.capture current (Inspection_view.operation current) in
  let failed = receipt reconnected fresh (Error "current reconnect read failed") in
  assert (String.equal failed.notice "ASIC: current reconnect read failed");
  assert (
    Option.equal
      String.equal
      (Option.value_exn (H.inspection failed paths.id)).error
      (Some "current reconnect read failed"));
  assert_ignored failed before_reconnect
;;

let%test_unit "WB-065 reused tile and request counters cannot accept an old receipt" =
  let host, _, find = Host_view.refinement_fixture P.Timing.definition in
  let paths = find "timing-paths" in
  let host = H.set_local host paths.id (H.local host paths.id) in
  let host =
    H.set_timing
      host
      paths
      (Timing_workspace.create ~generation:1 ~run:Fs0_fixture.run_a ~stage:"signoff")
  in
  let original = Option.value_exn (H.inspection host paths.id) in
  let identity = (H.local host paths.id).identity in
  let ticket = Inspection_view.capture original (Inspection_view.operation original) in
  let registry = Option.value_exn host.registry in
  let removed =
    H.receive host { registry with revision = registry.revision + 1; tiles = [] }
  in
  let reopened = H.receive removed { registry with revision = registry.revision + 2 } in
  let reopened = H.set_local reopened paths.id (H.local reopened paths.id) in
  (* Recreate the same numeric generation and exact operation. Only the local lifetime
     token distinguishes this pane from the one closed while the read was in flight. *)
  let reopened = H.set_timing reopened paths original in
  let reopened = { reopened with notice = "new pane notice" } in
  let current = Option.value_exn (H.inspection reopened paths.id) in
  let current_identity = (H.local reopened paths.id).identity in
  assert (not (phys_equal identity current_identity));
  assert (current.generation = ticket.generation);
  List.iter [ Ok (); Error "closed pane failed" ] ~f:(fun response ->
    let after =
      Evidence_activity.inspection_receipt
        reopened
        ~tile_id:paths.id
        ~identity
        ~ticket
        ~publish_notice:true
        response
    in
    assert (phys_equal after reopened);
    assert (String.equal after.notice "new pane notice"));
  let failed =
    Evidence_activity.inspection_receipt
      reopened
      ~tile_id:paths.id
      ~identity:current_identity
      ~ticket
      ~publish_notice:true
      (Error "new pane failed")
  in
  assert (String.equal failed.notice "ASIC: new pane failed")
;;

(* WB-003 through the actual Session tile renderer: an inspector's active read appears on
   the Session line of the workspace that shows it, with its static text in every icon
   mode, and disappears once the read reaches a terminal state. *)
let%test_unit "Session line projects scoped evidence reads through the real renderer" =
  let host, data, find = Host_view.refinement_fixture P.Timing.definition in
  let paths = find "timing-paths"
  and session = find "live-status" in
  let view =
    Timing_workspace.create ~generation:1 ~run:Fs0_fixture.run_a ~stage:"signoff"
  in
  let host = H.set_timing host paths view in
  let key =
    Asic_inspection.index_key ~run:Fs0_fixture.run_a ~domain:"timing" ~stage:"signoff"
  in
  let operation state activity : Asic.Pending.t =
    { key
    ; kind = "inspection"
    ; state
    ; run = Some Fs0_fixture.run_a
    ; error = None
    ; activity
    }
  in
  let with_operations operations =
    { data with
      Host_view.asic =
        Option.map data.Host_view.asic ~f:(fun snapshot -> { snapshot with operations })
    }
  in
  let session_text ?(icons = Appearance.Icons.Unicode) data =
    let host = { host with appearance = { host.appearance with icons } } in
    Host_view.tile_view host data session ~width:60 ~height:7 |> Host_view.plain_text
  in
  let has text substring = String.is_substring text ~substring in
  List.iter Appearance.Icons.all ~f:(fun icons ->
    let reading =
      session_text ~icons (with_operations [ operation "executing" Evidence_read ])
    in
    assert (has reading "updating evidence · timing/signoff");
    assert (not (has reading "Evidence: idle")));
  let lookup =
    session_text (with_operations [ operation "executing" Evidence_cache_lookup ])
  in
  assert (has lookup "Evidence: cache lookup");
  assert (not (has lookup "updating evidence"));
  let finished = session_text (with_operations [ operation "completed" Evidence_read ]) in
  assert (has finished "Evidence: idle");
  (* A read for a stage no inspector shows does not reach the Session line. *)
  let other =
    { (operation "executing" Evidence_read) with
      key =
        Asic_inspection.index_key ~run:Fs0_fixture.run_a ~domain:"timing" ~stage:"routing"
    }
  in
  assert (has (session_text (with_operations [ other ])) "Evidence: idle")
;;

let%test_unit "Session context markers preserve labels and typed refresh owns one \
               animation"
  =
  let host, data, find = Host_view.refinement_fixture P.Timing.definition in
  let paths = find "timing-paths"
  and session = find "live-status" in
  let host =
    H.set_timing
      host
      paths
      (Timing_workspace.create ~generation:1 ~run:Fs0_fixture.run_a ~stage:"signoff")
  in
  let registry = Option.value_exn host.registry in
  let active = Option.value_exn host.active in
  let independent =
    H.receive host (Workspace.apply_mutation registry (Make_independent active))
  in
  let independent =
    H.set_timing
      independent
      paths
      (Timing_workspace.create ~generation:2 ~run:Fs0_fixture.run_a ~stage:"signoff")
  in
  let operation activity : Asic.Pending.t =
    { key =
        Asic_inspection.index_key ~run:Fs0_fixture.run_a ~domain:"timing" ~stage:"signoff"
    ; kind = "inspection"
    ; state = "executing"
    ; run = Some Fs0_fixture.run_a
    ; error = None
    ; activity
    }
  in
  List.iter Appearance.Icons.all ~f:(fun icons ->
    List.iter
      [ host, Indicator.Linked, "linked to Main"; independent, Independent, "own " ]
      ~f:(fun (host, kind, label) ->
        let host = { host with appearance = { host.appearance with icons } } in
        let glyph = Indicator.text icons kind in
        let prefix = if String.is_empty glyph then "" else glyph ^ " " in
        let render activity frame width height =
          let data =
            { data with
              Host_view.asic =
                Option.map data.asic ~f:(fun snapshot ->
                  { snapshot with operations = [ operation activity ] })
            }
          in
          let indicator_frames : Indicator.frames =
            { dot = Bonsai_term.View.text frame; line = Bonsai_term.View.text frame }
          in
          Host_view.tile_view ~indicator_frames host data session ~width ~height
        in
        let text activity frame = render activity frame 80 7 |> Host_view.plain_text in
        let reading = text Evidence_read "A" in
        assert (String.is_substring reading ~substring:(prefix ^ "Context: " ^ label));
        let animation = if Appearance.Icons.equal icons None_ then "" else "A " in
        assert (
          String.is_substring
            reading
            ~substring:(animation ^ "updating evidence · timing/signoff"));
        assert (not (String.is_substring reading ~substring:"A A "));
        assert (
          Bool.equal
            (not (String.equal reading (text Evidence_read "B")))
            (not (Appearance.Icons.equal icons None_)));
        assert (
          String.equal (text Evidence_cache_lookup "A") (text Evidence_cache_lookup "B"));
        List.iter
          [ 0, 0; 1, 1; 24, 7; 80, 7 ]
          ~f:(fun (width, height) ->
            let view = render Evidence_read "A" width height in
            assert (Bonsai_term.View.width view = width);
            assert (Bonsai_term.View.height view = height))))
;;

let%expect_test "Session line wording at the preset Session width" =
  let host, data, find = Host_view.refinement_fixture P.Timing.definition in
  let paths = find "timing-paths"
  and session = find "live-status" in
  let view =
    Timing_workspace.create ~generation:1 ~run:Fs0_fixture.run_a ~stage:"signoff"
  in
  let host = H.set_timing host paths view in
  let key stage =
    Asic_inspection.index_key ~run:Fs0_fixture.run_a ~domain:"timing" ~stage
  in
  let operation ?error ?(stage = "signoff") state : Asic.Pending.t =
    { key = key stage
    ; kind = "inspection"
    ; state
    ; run = Some Fs0_fixture.run_a
    ; error
    ; activity = Evidence_read
    }
  in
  let show ?(host = host) operations =
    let data =
      { data with
        Host_view.asic =
          Option.map data.Host_view.asic ~f:(fun snapshot -> { snapshot with operations })
      }
    in
    Host_view.tile_view host data session ~width:30 ~height:7
    |> Host_view.plain_text
    |> print_endline
  in
  show [ operation "executing" ];
  show [ operation ~error:"provider timed out" "failed" ];
  let routing =
    Inspection_view.create
      ~generation:1
      ~run:Fs0_fixture.run_a
      ~domain:"timing"
      ~stage:"routing"
      ()
  in
  let inspector = find "timing-detail" in
  let both =
    H.set_local
      host
      inspector.id
      { (H.local host inspector.id) with inspection = Some routing }
  in
  show ~host:both [ operation "executing"; operation ~stage:"routing" "executing" ];
  show [];
  [%expect
    {|
    ╭ session ───────────────────╮
    │ Connection: connected      │
    │ Project: none open         │
    │ ↔ Context: linked to Main  │
    │ Run: fixture-A             │
    │ ⣷ updating evidence · timi │
    ╰────────────────────────────╯
    ╭ session ───────────────────╮
    │ Connection: connected      │
    │ Project: none open         │
    │ ↔ Context: linked to Main  │
    │ Run: fixture-A             │
    │ Evidence: not updated: pro │
    ╰────────────────────────────╯
    ╭ session ───────────────────╮
    │ Connection: connected      │
    │ Project: none open         │
    │ ↔ Context: linked to Main  │
    │ Run: fixture-A             │
    │ ⣷ updating evidence (2)    │
    ╰────────────────────────────╯
    ╭ session ───────────────────╮
    │ Connection: connected      │
    │ Project: none open         │
    │ ↔ Context: linked to Main  │
    │ Run: fixture-A             │
    │ Evidence: idle             │
    ╰────────────────────────────╯
    |}]
;;
