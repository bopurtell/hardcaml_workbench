open! Core
open Hardcaml_workbench_protocol
module H = Workspace_host
module P = Hardcaml_workbench_workspaces

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

let%test_unit "Session context markers preserve labels and typed refresh owns one animation" =
  let host, data, find = Host_view.refinement_fixture P.Timing.definition in
  let paths = find "timing-paths"
  and session = find "live-status" in
  let host =
    H.set_timing host paths
      (Timing_workspace.create ~generation:1 ~run:Fs0_fixture.run_a ~stage:"signoff")
  in
  let registry = Option.value_exn host.registry in
  let active = Option.value_exn host.active in
  let independent =
    H.receive host (Workspace.apply_mutation registry (Make_independent active))
  in
  let independent =
    H.set_timing independent paths
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
          String.is_substring reading
            ~substring:(animation ^ "updating evidence · timing/signoff"));
        assert (not (String.is_substring reading ~substring:"A A "));
        assert (
          Bool.equal
            (not (String.equal reading (text Evidence_read "B")))
            (not (Appearance.Icons.equal icons None_)));
        assert (
          String.equal (text Evidence_cache_lookup "A") (text Evidence_cache_lookup "B"));
        List.iter [ 0, 0; 1, 1; 24, 7; 80, 7 ] ~f:(fun (width, height) ->
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
