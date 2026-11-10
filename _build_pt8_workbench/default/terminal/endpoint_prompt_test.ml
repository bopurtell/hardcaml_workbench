open! Core
open Hardcaml_workbench_protocol
open Terminal_presentation
module H = Workspace_host

let () =
  let flows, catalog_default =
    Hardcaml_workbench_backend.Asic_public.flow_catalog
      (Yojson.Safe.from_file (Sys.get_argv ()).(1))
  in
  let snapshot = { Fs0_fixture.snapshot with flows; catalog_default } in
  let query ?remembered ?(snapshot = snapshot) flow profile =
    Launch_preferences.endpoint_query ~remembered ~asic:(Some snapshot) ~flow ~profile
  in
  let selection : Asic.Selection.t =
    { flow = "standard"; profile = "balanced"; endpoint = "synthesis"; assignments = [] }
  in
  assert (String.equal (query "standard" "balanced") "synthesis");
  assert (
    Asic.Selection.equal
      (Result.ok_or_failwith
         (Preparation_view.selection ~remembered:None ~asic:(Some snapshot)))
      selection);
  let remembered = { selection with endpoint = "routing"; assignments = [ "WIDTH=8" ] } in
  assert (String.equal (query ~remembered "standard" "balanced") "routing WIDTH=8");
  assert (String.equal (query ~remembered "standard" "synth_delay") "synthesis");
  assert (String.is_empty (query "missing" "balanced"));
  assert (String.is_empty (query "standard" "missing"));
  assert (
    String.is_empty
      (Launch_preferences.endpoint_query
         ~remembered:None
         ~asic:None
         ~flow:"standard"
         ~profile:"balanced"));
  List.iter [ []; [ "routing" ] ] ~f:(fun endpoints ->
    let snapshot =
      { snapshot with
        flows =
          List.map flows ~f:(fun flow -> { flow with fresh_stage_endpoints = endpoints })
      }
    in
    assert (
      String.equal
        (query ~snapshot "standard" "balanced")
        (Option.value (List.hd endpoints) ~default:"")));
  let host, _, find =
    Host_view.refinement_fixture Hardcaml_workbench_workspaces.Overview.definition
  in
  let capture = H.capture host |> Option.value_exn in
  let enter argument query =
    H.input
      { host with
        palette =
          Some { capture; commands = []; query; index = 0; argument = Some argument }
      }
      Enter
      ~commands:[]
  in
  let arguments =
    [ H.Plan_endpoint ("standard", "balanced")
    ; H.Preparation_inputs ("standard", "balanced")
    ]
  in
  let corpus =
    [ ""
    ; "SYNTH_STRATEGY=DELAY 1"
    ; "SYNTH_ABC_BUFFERING=false"
    ; " leading and trailing "
    ; "QUOTE=one'and\"two"
    ; "PATH=C:\\literal\\path"
    ; "LITERAL=$(touch /never);`command`|*&~$HOME"
    ; "UNICODE=界"
    ]
  in
  List.iter corpus ~f:(fun first ->
    List.iter corpus ~f:(fun second ->
      let remembered = { selection with assignments = [ first; second; first ] } in
      let encoded = query ~remembered "standard" "balanced" in
      assert (
        List.equal
          String.equal
          (Or_error.ok_exn (Launch_preferences.Prompt.decode encoded))
          (remembered.endpoint :: remembered.assignments));
      List.iter arguments ~f:(fun argument ->
        match snd (enter argument encoded) with
        | Execute (_, (Asic (Plan actual) | Select_preparation actual)) ->
          assert (Asic.Selection.equal actual remembered)
        | _ -> assert false)));
  List.iter
    [ "synthesis SYNTH_STRATEGY='DELAY 1'", [ "SYNTH_STRATEGY=DELAY 1" ]
    ; "synthesis SYNTH_STRATEGY=\"DELAY 1\"", [ "SYNTH_STRATEGY=DELAY 1" ]
    ; "  synthesis  A=1 A=2  ", [ "A=1"; "A=2" ]
    ; "synthesis PATH=C:\\literal\\path", [ "PATH=C:\\literal\\path" ]
    ; "synthesis LITERAL=$HOME;$(whoami)", [ "LITERAL=$HOME;$(whoami)" ]
    ]
    ~f:(fun (text, assignments) ->
      let actual =
        Launch_preferences.Prompt.selection
          text
          ~flow:selection.flow
          ~profile:selection.profile
        |> Or_error.ok_exn
      in
      assert (Asic.Selection.equal actual { selection with assignments }));
  List.iter
    [ "synthesis 'unclosed", "Unclosed quote"
    ; "synthesis \"unclosed", "Unclosed quote"
    ; "synthesis \"bad\\q\"", "only quote and backslash"
    ; "synthesis A=1\nB=2", "one line"
    ; "synthesis A=1\rB=2", "one line"
    ; "synthesis A=1\tB=2", "one line"
    ; "synthesis A=\000", "control characters"
    ; "synthesis A=\127", "control characters"
    ; "\"\" A=1", "nonempty endpoint"
    ]
    ~f:(fun (text, diagnostic) ->
      List.iter arguments ~f:(fun argument ->
        let rejected, effect = enter argument text in
        assert (
          match effect with
          | No_effect -> true
          | _ -> false);
        assert (String.is_substring rejected.notice ~substring:diagnostic);
        assert (
          Option.value_map rejected.palette ~default:false ~f:(fun p ->
            String.equal p.query text))));
  List.iter
    [ H.Plan_endpoint ("standard", "balanced")
    ; H.Preparation_inputs ("standard", "balanced")
    ]
    ~f:(fun argument ->
      let host =
        { host with
          palette =
            Some
              { capture
              ; commands = []
              ; query = query "standard" "balanced"
              ; index = 0
              ; argument = Some argument
              }
        }
      in
      let text =
        Host_view.render_palette
          host
          { width = 120; height = 40 }
          (Bonsai_term.View.text "")
        |> Host_view.plain_text
      in
      assert (String.is_substring text ~substring:"synthesis");
      match snd (H.input host Enter ~commands:[]) with
      | Execute (_, (Asic (Plan actual) | Select_preparation actual)) ->
        assert (Asic.Selection.equal actual selection)
      | _ -> assert false);
  let diagnostic = "source input unavailable: exact-diagnostic-123" in
  List.iter [ false; true ] ~f:(fun fresh ->
    let planned_run, ticket =
      if fresh
      then Planned_run.begin_fresh host.planned_run ~elaboration_only:false selection
      else Planned_run.begin_plan host.planned_run selection
    in
    let planned_run =
      if fresh
      then Planned_run.fresh_receipt planned_run ticket ~floor:1 (Error diagnostic)
      else Planned_run.receipt planned_run ticket ~floor:1 (Error diagnostic)
    in
    List.iter [ false; true ] ~f:(fun detail ->
      let tile = find "planned-run" in
      let host =
        { host with planned_run; planned_preparation = false; stage_preparation = None }
      in
      let local = H.local host tile.id in
      let host = H.set_local host tile.id { local with utility_detail = detail } in
      let rows = Host_view.planned_source_rows host tile in
      assert (
        List.exists rows ~f:(fun row ->
          Planned_run.equal_role row.role Error
          && String.is_substring row.text ~substring:diagnostic))));
  print_endline "catalog endpoint prompts and plan diagnostics: ok"
;;
