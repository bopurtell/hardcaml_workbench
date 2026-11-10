open! Core
open Hardcaml_workbench_protocol
module V = Workloads_view
module W = Asic_workloads

let digest = String.make 64 'a'

let json =
  {|{"contract":"hardcaml-asic.workload-inspection","binding":{"bundle_identity":"bundle","simulation_attempt_id":"sim"},"outcome":{"status":"completed","functional":"fail","performance":"unavailable"},"metrics":[{"name":"large count","value":9007199254740993,"unit":"cycles"},{"name":"throughput","value":0.6021423106350421,"numerator":787,"denominator":1307,"unit":"operations/cycle"}]}|}
;;

let loaded () =
  let t, op = V.inspect V.empty "/retained/a/result.json" None ~refresh:false in
  let key = W.Operation.key (Option.value_exn op) in
  let descriptor : W.Descriptor.t =
    { key
    ; query = Option.value_exn t.query
    ; digest = Some digest
    ; provider_identity = Some "reader"
    ; freshness = Validated
    ; error = None
    }
  in
  let snapshot : W.Snapshot.t =
    { entries = [ descriptor ]
    ; selected = Some { key; digest; json }
    ; cache_error = None
    }
  in
  let asic = Some { Fs0_fixture.snapshot with workloads = Some snapshot } in
  V.reconcile t asic, asic
;;

let%test_unit "raw metric tokens and rational components survive presentation" =
  let t, asic = loaded () in
  let text =
    V.rows t ~asic ~filter:"" ~width:180 ~height:100
    |> List.map ~f:Evidence_style.text
    |> String.concat ~sep:"\n"
  in
  List.iter
    [ "9007199254740993"
    ; "0.6021423106350421"
    ; "numerator=787"
    ; "denominator=1307"
    ; "functional: fail"
    ; "performance: unavailable"
    ]
    ~f:(fun expected -> assert (String.is_substring text ~substring:expected));
  let compared =
    Yojson.Raw.from_string
      {|{"metrics":[{"metric_id":"workload/throughput","comparison":"comparable","left":{"value":0.6021423106350421,"numerator":787,"denominator":1307},"right":{"value":0.6021423106350421,"numerator":787,"denominator":1307},"right_minus_left":0,"right_minus_left_ratio":{"numerator":0,"denominator":1}}]}|}
  in
  let compared =
    V.comparison_rows compared
    |> List.map ~f:Evidence_style.text
    |> String.concat ~sep:"\n"
  in
  assert (String.is_substring compared ~substring:"0.6021423106350421 (787/1307)")
;;

let%test_unit "source change and reconnect reject old receipts and old selected payload" =
  let t, asic = loaded () in
  let old = t.generation in
  let changed, _ = V.inspect t "/retained/b/result.json" None ~refresh:false in
  let changed = V.reconcile changed asic in
  assert (Option.is_none changed.document);
  let received = V.receipt changed ~generation:old ~floor:10 (Error "obsolete") in
  assert (Option.is_none received.error);
  let reconnected = V.reconnect changed in
  assert (
    Option.is_none
      (V.receipt
         reconnected
         ~generation:changed.generation
         ~floor:10
         (Error "old daemon"))
        .error)
;;

let%test_unit "capture freezes digest; axis and swap bind ordered provider queries" =
  let t, _ = loaded () in
  let t = V.capture t ~left:true ~bundle:"/bundle/a" in
  let t = V.capture t ~left:false ~bundle:"/bundle/b" in
  let t, a = V.compare t ~refresh:false in
  let swapped, b = V.input t ~asic:None ~filter:"" Swap in
  let _, c = V.input swapped ~asic:None ~filter:"" (Axis "hardware") in
  let key op = W.Operation.key (Option.value_exn op) in
  assert (not (String.equal (key a) (key b)));
  assert (not (String.equal (key b) (key c)));
  (match Option.value_exn b with
   | Load { query = Compare q; _ } ->
     assert (Option.equal String.equal q.expected_left_workload_digest (Some digest));
     assert (W.Target.equal q.left (Bundle "/bundle/b"))
   | _ -> assert false);
  assert (Option.is_none swapped.document)
;;

let%test_unit "reference schema fences exact absolute source and digest" =
  let reference result =
    sprintf
      {|{"contract":"hardcaml-workbench.pt8-result-reference","schema_version":1,"result":%s,"source_digest":"%s"}|}
      (Yojson.Safe.to_string (`String result))
      digest
  in
  assert (Result.is_ok (V.reference (reference "/retained/result.json")));
  assert (Result.is_error (V.reference (reference "relative/result.json")));
  assert (
    Result.is_error
      (V.reference
         {|{"contract":"hardcaml-workbench.pt8-result-reference","schema_version":1,"result":"/a","result":"/b","source_digest":"x"}|}));
  assert (Result.is_error (V.reference (String.make 16385 'x')))
;;

let%test_unit "rendering filtering and narrow geometry are pure reads" =
  let t, asic = loaded () in
  let generation = t.generation in
  List.iter
    [ 0, 0; 1, 1; 40, 12; 80, 24; 180, 55 ]
    ~f:(fun (width, height) ->
      List.iter [ ""; "no match" ] ~f:(fun filter ->
        ignore (V.rows t ~asic ~filter ~width ~height : Evidence_style.row list)));
  assert (t.generation = generation);
  assert (Option.is_some t.pending)
;;

let%test_unit "receipt admission floors reject old same-key failure polls" =
  let t, asic = loaded () in
  let base = Option.value_exn asic in
  let t, op = V.input t ~asic ~filter:"" Refresh in
  let pending = W.Operation.key (Option.value_exn op) in
  let operation state error : Asic.Pending.t =
    { key = pending
    ; kind = "workloads"
    ; state
    ; run = None
    ; error
    ; activity = Evidence_read
    }
  in
  let failed =
    Some { base with operations = [ operation "failed" (Some "previous-key-error") ] }
  in
  let generation = t.generation in
  let t = V.admit t ~generation ~request_floor:22 in
  let t = V.reconcile ~revision:23 t failed in
  assert (Option.is_none t.error && Option.is_some t.pending);
  let t = V.receipt t ~generation ~floor:25 (Ok ()) in
  let t = V.reconcile ~revision:24 t failed in
  assert (Option.is_none t.error && Option.is_some t.pending);
  let t =
    V.reconcile
      ~revision:25
      t
      (Some { base with operations = [ operation "completed" None ] })
  in
  assert (Option.is_none t.pending && Option.is_none t.error)
;;

let%test_unit "production host keys import forms rendering and tile lifetimes" =
  let module H = Workspace_host in
  let module P = Hardcaml_workbench_workspaces in
  let definition = P.Presets.find "workloads" |> Option.value_exn in
  let host, data, find = Host_view.refinement_fixture definition in
  let tile = find "workloads" in
  let t, asic = loaded () in
  let local = H.local host tile.id in
  let host =
    H.set_local { host with focus = Some tile.id } tile.id { local with workloads = t }
  in
  List.iter
    [ H.Enter; Escape; Character 'r'; Character 'd'; Character 'c'; Character ']' ]
    ~f:(fun key ->
      match snd (H.input host key ~commands:[]) with
      | H.Execute (_, Workload_input _) -> ()
      | _ -> assert false);
  let text =
    Host_view.tile_view host { data with asic } tile ~width:180 ~height:55
    |> Host_view.plain_text
  in
  assert (String.is_substring text ~substring:"9007199254740993");
  List.iter
    [ 40, 12; 80, 24 ]
    ~f:(fun (width, height) ->
      ignore (Host_view.tile_view host { data with asic } tile ~width ~height));
  let capture = H.capture host |> Option.value_exn in
  let form =
    { host with
      palette =
        Some
          { capture
          ; commands = []
          ; query = "/retained/result with spaces.json"
          ; index = 0
          ; argument = Some Workload_path
          }
    }
  in
  (match snd (H.input form Enter ~commands:[]) with
   | H.Execute (_, Workload_result (path, None)) ->
     assert (String.equal path "/retained/result with spaces.json")
   | _ -> assert false);
  let registry = Option.value_exn host.registry in
  let removed =
    H.receive
      host
      { registry with
        tiles =
          List.filter registry.tiles ~f:(fun t ->
            not (Workspace.Tile_id.equal t.id tile.id))
      }
  in
  let replaced = H.receive removed registry in
  assert (not (phys_equal local.identity (H.local replaced tile.id).identity));
  assert (Option.is_none (H.local replaced tile.id).workloads.document);
  let reconnected = H.reconnect host ~replacement:false in
  assert ((H.local reconnected tile.id).workloads.generation > t.generation);
  assert (Option.is_none (H.reconnect host ~replacement:true).registry)
;;

let%test_unit "workload navigation roundtrips without granting validation or resetting \
               layout"
  =
  let module H = Workspace_host in
  let module P = Hardcaml_workbench_workspaces in
  let host, _, find =
    Host_view.refinement_fixture (P.Presets.find "workloads" |> Option.value_exn)
  in
  let tile = find "workloads" in
  let t, _ = loaded () in
  let t =
    V.capture t ~left:true ~bundle:"/bundle/a"
    |> fun t -> V.capture t ~left:false ~bundle:"/bundle/b"
  in
  let local = H.local host tile.id in
  let host = H.set_local host tile.id { local with workloads = t } in
  let saved =
    H.navigation_preferences ~project_key:"workload-project" host
    |> Option.value_exn
    |> Navigation_preferences.encode
    |> Navigation_preferences.decode ~project_key:"workload-project"
  in
  let restored =
    H.restore_navigation_selections
      saved
      (H.receive H.empty (Option.value_exn host.registry))
      ~scope:"workload-project"
  in
  let current = (H.local restored tile.id).workloads in
  assert (
    Option.equal V.equal_capture t.left current.left
    && Option.equal V.equal_capture t.right current.right);
  assert (Option.is_none current.document && Option.is_none current.descriptor);
  assert (
    Workspace.Snapshot.equal
      (Option.value_exn host.registry)
      (Option.value_exn restored.registry));
  let changed = { saved with session = "another-session" } in
  let rejected =
    H.restore_navigation_selections
      changed
      (H.receive H.empty (Option.value_exn host.registry))
      ~scope:"workload-project"
  in
  assert (Option.is_none (H.local rejected tile.id).workloads.left)
;;

let%test_unit "axis change and capture form generations cannot reuse another document" =
  let t, asic = loaded () in
  let changed, _ = V.input t ~asic ~filter:"" (Axis "hardware") in
  assert (Option.is_none changed.document && Option.is_none changed.query);
  let changed, _ =
    V.input
      t
      ~asic
      ~filter:""
      (Capture (true, "/bundle/a", (t.generation - 1, None, None)))
  in
  assert (Option.is_none changed.left && Option.is_some changed.error);
  let token = V.capture_token t in
  List.iter
    [ { (Option.value_exn t.descriptor) with digest = Some (String.make 64 'b') }
    ; { (Option.value_exn t.descriptor) with provider_identity = Some "another-reader" }
    ]
    ~f:(fun descriptor ->
      let changed, _ =
        V.input
          { t with descriptor = Some descriptor }
          ~asic
          ~filter:""
          (Capture (true, "/bundle/a", token))
      in
      assert (Option.is_none changed.left && Option.is_some changed.error))
;;

let published query digest json =
  let key = V.key query in
  let descriptor : W.Descriptor.t =
    { key
    ; query
    ; digest = Some digest
    ; provider_identity = Some "reader"
    ; freshness = Validated
    ; error = None
    }
  in
  Some
    { Fs0_fixture.snapshot with
      workloads =
        Some
          { entries = [ descriptor ]
          ; selected = Some { key; digest; json }
          ; cache_error = None
          }
    }
;;

let%test_unit "exact inspection survives list memory palette choice and cache collisions" =
  let path = "/retained/shared/result.json" in
  let pinned = W.Query.Inspect { result = path; expected_digest = Some digest } in
  let unpinned = W.Query.Inspect { result = path; expected_digest = None } in
  let t, _ = V.inspect V.empty path (Some digest) ~refresh:false in
  let asic = published pinned digest json in
  let t = V.reconcile t asic in
  let browsing, _ = V.input t ~asic ~filter:"" Back in
  let reopened, op = V.input browsing ~asic ~filter:"" Open in
  assert (W.Query.equal (Option.value_exn reopened.query) pinned);
  (match op with
   | Some (Load { query; _ }) -> assert (W.Query.equal query pinned)
   | _ -> assert false);
  let newer = String.substr_replace_all json ~pattern:"\"sim\"" ~with_:"\"NEW-C\"" in
  let shown = V.reconcile reopened (published unpinned (String.make 64 'c') newer) in
  assert (
    not
      (String.is_substring
         (Yojson.Raw.to_string (Option.value_exn shown.document))
         ~substring:"NEW-C"));
  let pinned_snapshot = V.snapshot asic
  and unpinned_snapshot = V.snapshot (published unpinned digest json) in
  List.iter
    [ pinned_snapshot.entries @ unpinned_snapshot.entries
    ; unpinned_snapshot.entries @ pinned_snapshot.entries
    ]
    ~f:(fun entries ->
      let snapshot = { pinned_snapshot with entries } in
      let chosen = V.inspection_query V.empty path snapshot |> Option.value_exn in
      assert (W.Query.equal chosen pinned));
  let other, _ = V.inspect t "/retained/other.json" None ~refresh:false in
  let restored = V.restore (V.remember other) in
  assert (
    Option.equal
      W.Query.equal
      (V.inspection_query restored path pinned_snapshot)
      (Some pinned))
;;

let%test_unit "highlighted unloaded result cannot capture prior detail or verified \
               locator"
  =
  let t, asic = loaded () in
  let asic = Option.value_exn asic in
  let original = Option.value_exn asic.workloads in
  let other =
    V.snapshot
      (published
         (Inspect { result = "/retained/b/result.json"; expected_digest = None })
         digest
         json)
  in
  let all =
    Some
      { asic with
        workloads = Some { original with entries = original.entries @ other.entries }
      }
  in
  let browsing, _ = V.input t ~asic:all ~filter:"" Back in
  let highlighted, _ = V.input browsing ~asic:all ~filter:"" (Move 1) in
  let highlighted, _ = V.input highlighted ~asic:all ~filter:"" (Move 1) in
  assert (Option.equal String.equal highlighted.selected (Some "/retained/b/result.json"));
  assert (Option.is_none highlighted.document && not (V.capture_ready highlighted));
  assert (Option.is_none (V.capture highlighted ~left:true ~bundle:"/bundle/b").left);
  assert (
    Option.is_none
      (V.capture
         { t with selected = Some "/retained/b/result.json" }
         ~left:true
         ~bundle:"/bundle/b")
        .left)
;;

let%test_unit "verified bundle locator enables automatic exact capture with legacy \
               fallback"
  =
  let t, _ = loaded () in
  assert (Option.is_none (V.verified_bundle t));
  let enriched =
    String.substr_replace_all
      json
      ~pattern:"\"bundle_identity\":"
      ~with_:"\"bundle\":\"/verified/bundle\",\"bundle_identity\":"
  in
  let t =
    V.reconcile
      { t with document = None }
      (published (Option.value_exn t.query) digest enriched)
  in
  assert (Option.equal String.equal (V.verified_bundle t) (Some "/verified/bundle"));
  assert (
    String.equal
      (Option.value_exn (V.capture t ~left:true ~bundle:"/verified/bundle").left).bundle
      "/verified/bundle");
  assert (Option.is_none (V.capture t ~left:true ~bundle:"/guessed/bundle").left);
  assert (Option.is_none (V.verified_bundle { t with mode = Results }))
;;

let%test_unit "comparison pins separate target generations and retains only valid domains"
  =
  let t, _ = loaded () in
  let t =
    V.capture t ~left:true ~bundle:"/bundle/a"
    |> fun t -> V.capture t ~left:false ~bundle:"/bundle/b"
  in
  let paired, _ = V.compare t ~refresh:false in
  let left_digest = String.make 64 'b'
  and right_digest = String.make 64 'c' in
  let document =
    sprintf
      {|{"left":{"source_digest":"%s"},"right":{"source_digest":"%s"},"metrics":[]}|}
      left_digest
      right_digest
  in
  let asic = published (Option.value_exn paired.query) (String.make 64 'd') document in
  let compared = V.reconcile paired asic in
  let verify (op : W.Operation.t option) left right =
    match op with
    | Some (Load { query = Compare q; _ }) ->
      assert (Option.equal String.equal q.expected_left_digest left);
      assert (Option.equal String.equal q.expected_right_digest right);
      assert (Option.equal String.equal q.expected_left_workload_digest (Some digest));
      assert (Option.equal String.equal q.expected_right_workload_digest (Some digest))
    | _ -> assert false
  in
  let _, refresh = V.input compared ~asic ~filter:"" Refresh in
  verify refresh (Some left_digest) (Some right_digest);
  let _, refresh = V.input { compared with mode = Provenance } ~asic ~filter:"" Refresh in
  verify refresh (Some left_digest) (Some right_digest);
  let _, swapped = V.input compared ~asic ~filter:"" Swap in
  verify swapped (Some right_digest) (Some left_digest);
  let _, axis = V.input compared ~asic ~filter:"" (Axis "hardware") in
  verify axis None None;
  let _, same_axis = V.input compared ~asic ~filter:"" (Axis "resource_policy") in
  verify same_axis (Some left_digest) (Some right_digest);
  let restored = V.restore (V.remember compared) in
  let _, refresh = V.input restored ~asic:None ~filter:"" Refresh in
  verify refresh (Some left_digest) (Some right_digest)
;;

let%test_unit "compact workload detail puts metrics ahead of large retained facts" =
  let t, _ = loaded () in
  let document = Yojson.Safe.from_string json in
  let document =
    match document with
    | `Assoc fields ->
      `Assoc
        (( "outcome"
         , `Assoc
             [ "status", `String "completed"
             ; "functional", `String "pass"
             ; "performance", `String "available"
             ; "large_retained_note", `String (String.make 12000 'x')
             ] )
         :: List.Assoc.remove fields "outcome" ~equal:String.equal)
    | _ -> assert false
  in
  let t =
    V.reconcile
      { t with document = None }
      (published (Option.value_exn t.query) digest (Yojson.Safe.to_string document))
  in
  let text =
    V.rows t ~asic:None ~filter:"" ~width:80 ~height:18
    |> List.map ~f:Evidence_style.text
    |> String.concat ~sep:"\n"
  in
  assert (String.is_substring text ~substring:"9007199254740993");
  assert (not (String.is_substring text ~substring:"large_retained_note"));
  assert (not (String.is_substring text ~substring:"bundle_identity"))
;;
