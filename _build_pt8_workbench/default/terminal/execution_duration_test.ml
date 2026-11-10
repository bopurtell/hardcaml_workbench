open! Core
open Hardcaml_workbench_protocol
open Bonsai_term
module V = Host_view

let measured n = Execution_timing.make ~measured_seconds:n ~running:false ()

let column line text =
  let bytes = String.substr_index_exn line ~pattern:text in
  Overview_tiles.cell_width (String.prefix line bytes)
;;

let%test_unit "actual Runs columns survive filtering, selection, scrolling and icon modes"
  =
  let host, data, find =
    V.refinement_fixture Hardcaml_workbench_workspaces.Overview.definition
  in
  let tile = find "run-selector" in
  let snapshot = Option.value_exn data.asic in
  let template = List.hd_exn snapshot.runs in
  let cases =
    [ "completed", measured 3723., "1h 02m 03s"
    ; ( "running"
      , Execution_timing.make
          ~started_at:(Timestamp.of_time_ns Time_ns.epoch)
          ~running:true
          ()
      , "14s" )
    ; "failed", None, "unknown"
    ; "queued", measured 0., "0s"
    ; "interrupted", measured 127., "2m 07s"
    ; "completed", measured 7., "7s"
    ]
  in
  let runs =
    List.mapi cases ~f:(fun i (status, execution_timing, _) ->
      { template with
        run = { template.run with id = sprintf "keep-界é-%d" i; label = None }
      ; status
      ; execution_timing
      })
  in
  let excluded =
    { template with
      run = { template.run with id = "excluded"; label = None }
    ; status = String.make 60 'x'
    }
  in
  let data =
    { data with
      asic = Some { snapshot with runs = excluded :: runs }
    ; runs = List.map (excluded :: runs) ~f:(fun r -> r.Asic.Run.run, r.status)
    }
  in
  let now = Time_ns.add Time_ns.epoch (Time_ns.Span.of_sec 14.) in
  List.iter Appearance.Icons.all ~f:(fun icons ->
    let host = { host with appearance = { host.appearance with icons } } in
    List.iter [ 0; 1; 8; 22; 40; 70 ] ~f:(fun width ->
      let starts = ref [] in
      List.iteri runs ~f:(fun i r ->
        let local = Workspace_host.local host tile.id in
        let host =
          Workspace_host.set_local
            host
            tile.id
            { local with filter = "keep-"; cursor = Some (V.run_label r.run); scroll = i }
        in
        let view = V.tile_view ~now host data tile ~width ~height:5 in
        assert (View.width view = width && View.height view = 5);
        let text = V.plain_text view in
        List.iter [ "Time:"; "Elapsed:"; "elapsed"; "excluded" ] ~f:(fun substring ->
          assert (not (String.is_substring text ~substring)));
        if width >= 40
        then (
          let _, _, duration = List.nth_exn cases i in
          let line =
            String.split_lines text
            |> List.find_exn ~f:(fun line ->
              String.is_substring line ~substring:r.status
              && String.is_substring line ~substring:duration)
          in
          starts
          := ( column line r.status
             , column line duration + Overview_tiles.cell_width duration )
             :: !starts)
        else
          List.iter [ "1h 02m 03s"; "unknown"; "2m 07s" ] ~f:(fun substring ->
            assert (not (String.is_substring text ~substring))));
      match !starts with
      | [] -> ()
      | first :: rest -> assert (List.for_all rest ~f:(fun x -> Poly.equal first x))))
;;

let%test_unit "checklist shares status and right duration columns across the full scroll \
               set"
  =
  let open Overview_tiles in
  let cases =
    [ Status.Completed, "1h 02m 03s"
    ; Running, "14s"
    ; Unknown, "unknown"
    ; Not_requested, "0s"
    ; Failed, "2m 07s"
    ]
  in
  List.iter Appearance.Icons.all ~f:(fun icons ->
    let appearance = { Appearance.default with icons; density = Compact } in
    List.iter [ 0; 1; 8; 22; 40; 70 ] ~f:(fun width ->
      let positions = ref [] in
      List.iteri cases ~f:(fun selected _ ->
        let rows =
          List.mapi cases ~f:(fun i (status, time) ->
            row
              ~status
              ~active:(i = selected)
              ~time
              (if i = 0 then "very long 界é synthesis label" else "界é stage")
              (Status.label status))
        in
        let view =
          render
            ~candidate_rows:rows
            ~appearance
            ~attrs:(fun _ -> [])
            ~width
            ~height:1
            (List.drop rows selected)
        in
        assert (View.width view = width && View.height view = 1);
        let line = List.hd (plain_lines view) |> Option.value ~default:"" in
        assert (Stdlib.String.is_valid_utf_8 line);
        let status, time = List.nth_exn cases selected in
        if width >= 40
        then (
          assert (String.is_substring line ~substring:time);
          positions
          := (column line (Status.label status), column line time + cell_width time)
             :: !positions)
        else assert (not (String.is_substring line ~substring:time)));
      match !positions with
      | [] -> ()
      | first :: rest -> assert (List.for_all rest ~f:(fun x -> Poly.equal first x))))
;;

let%test_unit "Overview actual five-row tiles show exact selected and pinned execution \
               scopes"
  =
  let host, data, find =
    V.refinement_fixture Hardcaml_workbench_workspaces.Overview.definition
  in
  let now = Time_ns.epoch in
  let snapshot = Option.value_exn data.asic in
  let snapshot =
    { snapshot with
      runs =
        List.map snapshot.runs ~f:(fun r ->
          let seconds = if Run_ref.equal r.run Fs0_fixture.run_a then 127. else 14. in
          { r with
            execution_timing = measured seconds
          ; stages =
              List.map r.stages ~f:(fun s ->
                let seconds =
                  if not (Run_ref.equal r.run Fs0_fixture.run_a)
                  then 29.
                  else (
                    match s.id with
                    | "synthesis" -> 127.
                    | "placement" -> 14.
                    | "routing" -> 61.
                    | _ -> 9.)
                in
                { s with execution_timing = measured seconds })
          })
    ; finalizations =
        [ { Asic.Finalization.key = "receipt"
          ; run = Fs0_fixture.run_a
          ; execution_file = "execution"
          ; acceptance_requested = false
          ; attempt = Some "final"
          ; state = "completed"
          ; phase = None
          ; operation_status = Some "completed"
          ; acceptance = None
          ; error = None
          ; owned = false
          ; execution_timing = measured 3723.
          }
        ]
    }
  in
  let data = { data with asic = Some snapshot } in
  let text ?(host = host) ?(height = 5) ?(width = 60) tile =
    V.tile_view ~now host data tile ~width ~height |> V.plain_text
  in
  let pin_host (tile : Workspace.Tile.t) =
    { host with
      registry =
        Option.map host.registry ~f:(fun r ->
          { r with
            tiles =
              List.map r.tiles ~f:(fun t ->
                if Workspace.Tile_id.equal t.id tile.id then tile else t)
          })
    }
  in
  List.iter
    [ "synthesis", "2m 07s"; "placement", "14s"; "routing", "1m 01s" ]
    ~f:(fun (kind, expected) ->
      let tile = find kind in
      assert (String.is_substring (text tile) ~substring:("Time: " ^ expected));
      let pin = { tile with binding = Pin_run Fs0_fixture.run_b } in
      let pinned = text ~host:(pin_host pin) pin in
      assert (String.is_substring pinned ~substring:"Time: 29s");
      assert (not (String.is_substring pinned ~substring:("Time: " ^ expected))));
  List.iter [ "timing"; "checks" ] ~f:(fun kind ->
    let rendered = text (find kind) in
    assert (
      String.is_substring
        rendered
        ~substring:
          (if String.equal kind "timing"
           then "not reported"
           else "Time: unknown (stage " ^ kind ^ ")"));
    assert (not (String.is_substring rendered ~substring:"2m 07s")));
  assert (String.is_substring (text (find "finalization")) ~substring:"Time: 1h 02m 03s");
  assert (String.is_substring (text ~height:10 (find "run-selector")) ~substring:"2m 07s");
  let checklist = find "stage-checklist" in
  assert (String.is_substring (text ~height:10 checklist) ~substring:"2m 07s");
  let pinned = { checklist with binding = Pin_run Fs0_fixture.run_b } in
  assert (
    String.is_substring (text ~host:(pin_host pinned) ~height:10 pinned) ~substring:"29s");
  let stages = Overview_tiles.observed_stages ~asic:data.asic ~run:Fs0_fixture.run_a in
  let model =
    Overview_tiles.Stage_strip.model
      ~now
      ~appearance:host.appearance
      ~width:60
      ~run:Fs0_fixture.run_a
      ~selected_id:(Some "placement")
      stages
  in
  assert (String.equal (Option.value_exn model.selected).stage.id "placement");
  assert (
    Option.equal String.equal (Option.value_exn model.selected).row.time (Some "14s"));
  let view =
    Overview_tiles.Stage_strip.render
      ~appearance:host.appearance
      ~attrs:(fun _ -> [])
      ~width:60
      ~height:5
      model
  in
  assert (String.is_substring (V.plain_text view) ~substring:"2m 07s");
  List.iter [ 0; 1; 8; 22; 40; 60 ] ~f:(fun width ->
    let view = V.tile_view ~now host data checklist ~width ~height:5 in
    assert (View.width view = width && View.height view = 5));
  List.iter
    [ 120, 40; 240, 80 ]
    ~f:(fun (width, height) ->
      let _, _, layout = V.tile_layout host { Dimensions.width; height } in
      List.iter layout ~f:(fun (tile, g) ->
        if Overview_summary.supports tile.kind
           || String.equal tile.kind "run-selector"
           || String.equal tile.kind "stage-checklist"
        then (
          let rendered = text ~width:g.width ~height:g.height tile in
          if Overview_summary.supports tile.kind
          then
            assert (
              String.is_substring
                rendered
                ~substring:
                  (if String.equal tile.kind "timing" then "unknown" else "Time: "))
          else (
            assert (String.is_substring rendered ~substring:" | ");
            assert (not (String.is_substring rendered ~substring:"Time:"))))))
;;

let%test_unit "horizontal checklist truncates Unicode labels before raw durations and \
               hides time listwise"
  =
  List.iter Appearance.Icons.all ~f:(fun icons ->
    let appearance = { Appearance.default with icons; density = Compact } in
    let stages =
      List.mapi
        [ Asic.Stage.Status.Completed, measured 3723.
        ; Running, None
        ; Not_requested, measured 0.
        ]
        ~f:(fun i (status, execution_timing) ->
          { Asic.Stage.id = Int.to_string i
          ; name = String.concat (List.init 10 ~f:(fun _ -> "界é stage "))
          ; status
          ; requested = true
          ; reason = None
          ; action = None
          ; execution_timing
          })
    in
    List.iter [ 0; 1; 8; 22; 40; 70 ] ~f:(fun width ->
      let model =
        Overview_tiles.Stage_strip.model
          ~now:Time_ns.epoch
          ~appearance
          ~width
          ~run:Fs0_fixture.run_a
          ~selected_id:(Some "1")
          stages
      in
      let items = List.concat model.lines in
      let show_time = Option.is_some (List.hd_exn items).row.time in
      assert (
        List.for_all items ~f:(fun item ->
          Bool.equal show_time (Option.is_some item.Overview_tiles.Stage_strip.row.time)));
      let view =
        Overview_tiles.Stage_strip.render
          ~appearance
          ~attrs:(fun _ -> [])
          ~width
          ~height:5
          model
      in
      assert (View.width view = width && View.height view = 5);
      let text = V.plain_text view in
      assert (Stdlib.String.is_valid_utf_8 text);
      List.iter [ "Time:"; "Elapsed:"; "elapsed" ] ~f:(fun substring ->
        assert (not (String.is_substring text ~substring)));
      if width >= 40
      then (
        assert show_time;
        List.iter [ "1h 02m 03s"; "unknown"; "0s" ] ~f:(fun substring ->
          assert (String.is_substring text ~substring)))
      else assert (not show_time)))
;;

let%test_unit "live Overview duration uses supplied clock; terminal run freezes; \
               statuses retain semantics"
  =
  let host, data, find =
    V.refinement_fixture Hardcaml_workbench_workspaces.Overview.definition
  in
  let snapshot = Option.value_exn data.asic in
  let live =
    Execution_timing.make
      ~started_at:(Timestamp.of_time_ns Time_ns.epoch)
      ~running:true
      ()
  in
  let snapshot =
    { snapshot with
      runs =
        List.map snapshot.runs ~f:(fun r ->
          { r with
            status = "running"
          ; execution_timing = live
          ; stages =
              List.map r.stages ~f:(fun s ->
                { s with execution_timing = live; status = Running })
          })
    }
  in
  let data =
    { data with
      asic = Some snapshot
    ; runs = List.map data.runs ~f:(fun (r, _) -> r, "running")
    }
  in
  let tile = find "synthesis" in
  let image now = V.tile_view ~now host data tile ~width:60 ~height:5 |> V.plain_text in
  assert (String.is_substring (image Time_ns.epoch) ~substring:"Time: 0s elapsed");
  assert (
    String.is_substring
      (image (Time_ns.add Time_ns.epoch (Time_ns.Span.of_sec 127.)))
      ~substring:"Time: 2m 07s elapsed");
  let _, _, layout = V.tile_layout host { Dimensions.width = 120; height = 40 } in
  let checklist, checklist_geometry =
    List.find_exn layout ~f:(fun (t, _) -> String.equal t.kind "stage-checklist")
  in
  let checklist_text =
    V.tile_view
      ~now:(Time_ns.add Time_ns.epoch (Time_ns.Span.of_sec 127.))
      host
      data
      checklist
      ~width:checklist_geometry.width
      ~height:checklist_geometry.height
    |> V.plain_text
  in
  assert (String.is_substring checklist_text ~substring:"2m 07s");
  assert (not (String.is_substring checklist_text ~substring:"Elapsed:"));
  let selector, geometry =
    List.find_exn layout ~f:(fun (t, _) -> String.equal t.kind "run-selector")
  in
  List.iter
    [ 127., "2m 07s"; 3723., "1h 02m 03s" ]
    ~f:(fun (seconds, substring) ->
      let now = Time_ns.add Time_ns.epoch (Time_ns.Span.of_sec seconds) in
      let text =
        V.tile_view ~now host data selector ~width:geometry.width ~height:geometry.height
        |> V.plain_text
      in
      assert (String.is_substring text ~substring));
  assert (Poly.equal (V.run_indicator "running") Indicator.Running);
  let row =
    V.run_selector_view
      ~time:"2m 07s"
      host.appearance
      ~width:60
      ~status_width:7
      ~cursor:false
      ~active:false
      Fs0_fixture.run_a
      "running"
  in
  assert (String.is_substring (V.plain_text row) ~substring:"running | 2m 07s")
;;

let%test_unit "Testing attempts paint duration on the list and advance with the render \
               clock"
  =
  let host, data, find =
    V.refinement_fixture Hardcaml_workbench_workspaces.Testing.definition
  in
  let tile = find "simulation-attempts" in
  let now = Time_ns.epoch in
  let attempt : Simulation.Summary.t =
    { id = "exact-attempt"
    ; job = Job_id.of_string "exact-job"
    ; suite = "suite"
    ; seed = "7"
    ; created_at = "unrelated evidence time"
    ; parent = None
    ; lifecycle = Running
    ; outcome = Unknown
    ; execution_timing =
        Execution_timing.make ~started_at:(Timestamp.of_time_ns now) ~running:true ()
    }
  in
  let snapshot : Simulation.Snapshot.t =
    { configured = true
    ; discovery = None
    ; discovery_digest = None
    ; discovery_job = None
    ; discovery_error = None
    ; attempts = [ attempt ]
    ; next_before = None
    ; detail = None
    ; byte_page = None
    ; history_error = None
    }
  in
  let host =
    Workspace_host.set_simulation
      host
      tile.id
      { Simulation_view.empty with snapshot = Some snapshot; attempt = Some attempt.id }
  in
  let paint now width = V.tile_view ~now host data tile ~width ~height:8 in
  let before = paint now 60 |> V.plain_text in
  let later = Time_ns.add now (Time_ns.Span.of_sec 127.) in
  let after = paint later 60 |> V.plain_text in
  assert (String.is_substring before ~substring:"Time: 0s elapsed");
  assert (String.is_substring after ~substring:"Time: 2m 07s elapsed");
  List.iter [ 8; 22; 40; 60 ] ~f:(fun width ->
    let view = paint later width in
    assert (View.width view = width && View.height view = 8));
  let frozen = { attempt with lifecycle = Finished; execution_timing = measured 0. } in
  let host =
    Workspace_host.set_simulation
      host
      tile.id
      { Simulation_view.empty with
        snapshot = Some { snapshot with attempts = [ frozen ] }
      }
  in
  let paint now = V.tile_view ~now host data tile ~width:60 ~height:8 |> V.plain_text in
  assert (String.equal (paint now) (paint later));
  assert (String.is_substring (paint later) ~substring:"Time: 0s")
;;
