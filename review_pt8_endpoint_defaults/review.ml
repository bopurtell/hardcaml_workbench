open! Core
open Hardcaml_workbench_protocol
open Terminal_presentation
module H = Workspace_host

let checks = ref 0
let check label condition =
  if not condition then failwith ("Independent endpoint review: " ^ label);
  incr checks
;;

let flow id endpoints : Asic.Flow.t =
  { id; profiles = [ "one"; "two" ]; default_profile = "one"; fresh_stage_endpoints = endpoints }
;;

let snapshot flows : Asic.Snapshot.t =
  { Fs0_fixture.snapshot with
    flows
  ; catalog_default = Some { flow = "chosen"; profile = "one" }
  }
;;

let query ?remembered asic flow profile =
  Launch_preferences.endpoint_query ~remembered ~asic ~flow ~profile
;;

let selection : Asic.Selection.t =
  { flow = "chosen"; profile = "one"; endpoint = "routing"; assignments = [ "Z=last"; "A=first"; "Z=again" ] }
;;

let accept host argument query =
  let capture = H.capture host |> Option.value_exn in
  let host =
    { host with palette = Some { capture; commands = []; query; index = 0; argument = Some argument } }
  in
  snd (H.input host Enter ~commands:[])
;;

let () =
  let host, _, find =
    Host_view.refinement_fixture Hardcaml_workbench_workspaces.Overview.definition
  in
  let endpoints = [ "signoff"; "timing"; "routing"; "cts"; "placement"; "floorplan"; "synthesis" ] in
  for mask = 0 to 127 do
    let chosen = List.filteri endpoints ~f:(fun i _ -> mask land (1 lsl i) <> 0) in
    List.iter [ chosen; List.rev chosen ] ~f:(fun chosen ->
      let f = flow "chosen" chosen in
      let s = snapshot [ flow "decoy" [ "synthesis" ]; f ] in
      let actual = Launch_preferences.default_endpoint f in
      check "a newly selected endpoint must be advertised by the selected flow"
        (Option.value_map actual ~default:(List.is_empty chosen) ~f:(fun e -> List.mem chosen e ~equal:String.equal));
      check "empty endpoints never synthesize a default" (not (List.is_empty chosen) || Option.is_none actual);
      check "synthesis preference applies only if advertised"
        (not (List.mem chosen "synthesis" ~equal:String.equal) || Option.equal String.equal actual (Some "synthesis"));
      check "non-synthesis catalog order, not a global stage ordering, seeds the prompt"
        (List.mem chosen "synthesis" ~equal:String.equal || Option.equal String.equal actual (List.hd chosen));
      check "another flow's synthesis does not leak into this flow"
        (String.equal (query (Some s) "chosen" "one") (Option.value actual ~default:""));
      check "different advertised profile uses its catalog default, without remembered assignments"
        (String.equal (query ~remembered:selection (Some s) "chosen" "two") (Option.value actual ~default:""));
      check "different advertised flow uses its own catalog, without remembered assignments"
        (String.equal (query ~remembered:selection (Some s) "decoy" "one") "synthesis");
      check "same flow/profile retains explicit endpoint even if no longer advertised"
        (String.equal (query ~remembered:selection (Some s) "chosen" "one") "routing Z=last A=first Z=again");
      check "unknown profile gets no catalog endpoint" (String.is_empty (query (Some s) "chosen" "missing"));
      check "unknown flow gets no catalog endpoint" (String.is_empty (query (Some s) "missing" "one"));
      match Preparation_view.selection ~remembered:None ~asic:(Some s), actual with
      | Error _, None -> incr checks
      | Ok selected, Some endpoint ->
        check "preparation uses exact catalog flow/profile/advertised endpoint and no overrides"
          (Asic.Selection.equal selected { selection with endpoint; assignments = [] })
      | _ -> failwith "preparation default disagrees with endpoint helper")
  done;
  List.iter [ None; Some (snapshot []); Some (snapshot [ flow "chosen" [] ]) ] ~f:(fun asic ->
    check "no implicit synthesis when catalog absent/empty" (String.is_empty (query asic "chosen" "one"));
    check "explicit same-profile remembered inputs survive absent/changed catalogs"
      (String.equal (query ~remembered:selection asic "chosen" "one") "routing Z=last A=first Z=again");
    check "remembered profile does not leak overrides to another profile"
      (String.is_empty (query ~remembered:selection asic "chosen" "two"));
    check "remembered flow does not leak overrides to another flow"
      (String.is_empty (query ~remembered:selection asic "another" "one"));
    check "preparation preserves explicit exact selection without catalog"
      (Result.equal Asic.Selection.equal String.equal
         (Preparation_view.selection ~remembered:(Some selection) ~asic) (Ok selection)));
  let no_default = { (snapshot [ flow "chosen" [ "cts" ] ]) with catalog_default = None } in
  check "preparation cannot infer any selection before a catalog arrives"
    (Result.is_error (Preparation_view.selection ~remembered:None ~asic:None));
  check "preparation does not invent a flow/profile without catalog default"
    (Result.is_error (Preparation_view.selection ~remembered:None ~asic:(Some no_default)));
  List.iter [ H.Plan_endpoint ("chosen", "one"); H.Preparation_inputs ("chosen", "one") ] ~f:(fun argument ->
    (match accept host argument (query ~remembered:selection None "chosen" "one") with
     | Execute (_, (Asic (Plan actual) | Select_preparation actual)) ->
       check "actual Enter captures exact flow/profile/endpoint/assignment order and duplicate tokens"
         (Asic.Selection.equal actual selection)
     | _ -> failwith "Enter did not capture exact remembered inputs");
    match accept host argument "" with
    | No_effect -> incr checks
    | _ -> failwith "empty missing-catalog query dispatched a selection");
  List.iter [ false; true ] ~f:(fun fresh ->
    let model, ticket = if fresh then Planned_run.begin_fresh host.planned_run ~elaboration_only:false selection
      else Planned_run.begin_plan host.planned_run selection in
    let diagnostic = "source /private/example/asic/project.ml unavailable: distinctive-review-error" in
    let planned_run = if fresh then Planned_run.fresh_receipt model ticket ~floor:1 (Error diagnostic)
      else Planned_run.receipt model ticket ~floor:1 (Error diagnostic) in
    List.iter [ false; true ] ~f:(fun detail ->
      let tile = find "planned-run" in
      let host = { host with planned_run; planned_preparation = false; stage_preparation = None } in
      let local = H.local host tile.id in
      let host = H.set_local host tile.id { local with utility_detail = detail } in
      check "failed Plan/Fresh diagnostics remain present in compact and detail rows"
        (List.exists (Host_view.planned_source_rows host tile) ~f:(fun row ->
           Planned_run.equal_role row.role Error && String.is_substring row.text ~substring:diagnostic))));
  printf "PASS: %d independent catalog/remembered/capture/error checks\n%!" !checks;
  if Array.mem (Sys.get_argv ()) "--spaced-assignment" ~equal:String.equal then (
    let remembered = { selection with assignments = [ "SYNTH_STRATEGY=DELAY 1"; "SYNTH_ABC_BUFFERING=false" ] } in
    let query = query ~remembered None "chosen" "one" in
    match accept host (H.Plan_endpoint ("chosen", "one")) query with
    | Execute (_, Asic (Plan actual)) ->
      printf "Expected remembered: %s\nCaptured on Enter: %s\n%!"
        (Sexp.to_string_hum (Asic.Selection.sexp_of_t remembered))
        (Sexp.to_string_hum (Asic.Selection.sexp_of_t actual));
      check "space-containing advertised assignment must round-trip unchanged" (Asic.Selection.equal actual remembered)
    | _ -> failwith "space-containing remembered selection rejected before capture")
;;
