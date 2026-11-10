open! Core
open Hardcaml_workbench_protocol
module V = Resources_view
module R = Asic_resources

let row id : R.Row.t =
  { id
  ; contract = "memory 256x16"
  ; requirement = "required"
  ; policy = "technology"
  ; implementation = "stock macro"
  ; reason = "exact_mapping (technology)"
  ; role = "synthesis"
  ; instances = [ "hc_resource_7_" ^ id ]
  ; synthesis = "matched"
  ; final = "unavailable"
  ; measurements = []
  ; sections = [ { id = "timing"; count = 0; status = "unavailable" } ]
  }
;;

let source target : R.Source.t =
  { id = "source-a"
  ; target
  ; kind = "coarse_run"
  ; path = "/exact/capture"
  ; label = "retained source"
  ; provider_identity = "provider-bytes"
  ; freshness = Cached_unverified
  ; error = None
  }
;;

let index : R.Index.t =
  { source_id = "source-a"
  ; digest = "digest-a"
  ; provenance = "original identities"
  ; rows = [ row "program"; row "data" ]
  ; measurements = []
  ; artifact_count = 76
  ; diagnostics = [ "Sampled timing; electrical_compliance=not_assessed" ]
  ; truncated = false
  ; verdict = "fail"
  ; inventory_status = Available
  ; inventory_reason = None
  }
;;

let asic ?(details = []) ?(artifacts = []) ?(bytes = []) ?(index = index) source =
  Some
    { Fs0_fixture.snapshot with
      resources =
        Some
          { R.Snapshot.sources = [ source ]
          ; indexes = [ index ]
          ; details
          ; artifacts
          ; bytes
          }
    }
;;

let imported () =
  let target = R.Target.Coarse_run "/exact/capture" in
  let snapshot = asic (source target) in
  let view = V.select_target V.empty (Some target) in
  V.reconcile view ~run:(Some Fs0_fixture.run_a) ~filter:"" snapshot, snapshot
;;

let text view snapshot =
  V.contents view ~filter:"" ~asic:snapshot
  |> List.map ~f:Evidence_style.text
  |> String.concat ~sep:"\n"
;;

let%test_unit "retry admission and receipt floors reject previous-key failures before \
               and after acknowledgement"
  =
  let view, snapshot = imported () in
  let snapshot = Option.value_exn snapshot in
  let target = Option.value_exn view.target in
  let key = R.Operation.key (Load { target; refresh = true }) in
  let operation state error : Asic.Pending.t =
    { key; kind = "resources"; state; run = None; error; activity = Evidence_read }
  in
  let old =
    Some
      { snapshot with
        operations = [ operation "failed" (Some "PREVIOUS_ATTEMPT_FAILURE") ]
      }
  in
  let requested, _ = V.input view ~filter:"" ~asic:old Refresh in
  let generation = requested.generation in
  let requested = V.admit requested ~generation ~request_floor:22 in
  let polled = V.reconcile ~revision:23 requested ~run:None ~filter:"" old in
  assert (Option.is_some polled.pending && Option.is_none polled.error);
  let acknowledged = V.receipt ~floor:25 polled ~generation (Ok ()) in
  let late_old_poll = V.reconcile ~revision:24 acknowledged ~run:None ~filter:"" old in
  assert (Option.is_some late_old_poll.pending && Option.is_none late_old_poll.error);
  let success = Some { snapshot with operations = [ operation "completed" None ] } in
  let succeeded = V.reconcile ~revision:25 late_old_poll ~run:None ~filter:"" success in
  assert (Option.is_none succeeded.pending && Option.is_none succeeded.error);
  let retry, _ = V.input succeeded ~filter:"" ~asic:success Refresh in
  let retry = V.admit retry ~generation:retry.generation ~request_floor:26 in
  let ignored = V.receipt ~floor:27 retry ~generation (Error "late previous receipt") in
  assert (Option.is_none ignored.error && Option.is_some ignored.pending);
  let acknowledged = V.receipt ~floor:28 ignored ~generation:retry.generation (Ok ()) in
  let actual_failure =
    Some
      { snapshot with operations = [ operation "failed" (Some "NEW_ATTEMPT_FAILURE") ] }
  in
  let failed =
    V.reconcile ~revision:28 acknowledged ~run:None ~filter:"" actual_failure
  in
  assert (Option.equal String.equal failed.error (Some "NEW_ATTEMPT_FAILURE"));
  (* New normalized facts arriving during Load do not discard its acknowledgement fence. *)
  let pending, _ = V.input failed ~filter:"" ~asic:actual_failure Refresh in
  let pending = V.admit pending ~generation:pending.generation ~request_floor:29 in
  let resources = Option.value_exn snapshot.resources in
  let updated =
    Some
      { snapshot with
        operations = [ operation "completed" None ]
      ; resources =
          Some { resources with indexes = [ { index with digest = String.make 64 'f' } ] }
      }
  in
  let observed = V.reconcile ~revision:30 pending ~run:None ~filter:"" updated in
  assert (observed.generation = pending.generation && Option.is_some observed.pending);
  let observed = V.receipt ~floor:32 observed ~generation:pending.generation (Ok ()) in
  assert (
    Option.is_some
      (V.reconcile ~revision:31 observed ~run:None ~filter:"" updated).pending);
  let finished = V.reconcile ~revision:32 observed ~run:None ~filter:"" updated in
  assert (Option.is_none finished.pending && Option.is_none finished.error)
;;

let%test_unit "captured comparison requires provider and complete normalized index \
               identity, not just evidence digest"
  =
  let view, snapshot = imported () in
  let snapshot = Option.value_exn snapshot in
  let resources = Option.value_exn snapshot.resources in
  let original_source =
    { (List.hd_exn resources.sources) with
      R.Source.provider_identity = "provider-A"
    ; freshness = Validated
    }
  in
  let original =
    Some
      { snapshot with resources = Some { resources with sources = [ original_source ] } }
  in
  let view = V.reconcile view ~run:None ~filter:"" original in
  let captured, _ = V.input view ~filter:"" ~asic:original Capture_left in
  let validate source index =
    let current =
      Some
        { snapshot with
          resources = Some { resources with sources = [ source ]; indexes = [ index ] }
        }
    in
    V.comparison_validation captured current
    |> List.map ~f:Evidence_style.text
    |> String.concat ~sep:"\n"
  in
  let changed_index = { index with rows = [ row "changed-projection" ] } in
  List.iter
    [ { original_source with provider_identity = "provider-B" }, index
    ; original_source, changed_index
    ; { original_source with provider_identity = "provider-B" }, changed_index
    ]
    ~f:(fun (source, index) ->
      let text = validate source index in
      assert (String.is_substring text ~substring:"not revalidated");
      assert (
        not (String.is_substring text ~substring:"A current source: Validated source")));
  assert (
    String.is_substring
      (validate original_source index)
      ~substring:"A current source: Validated source");
  let detail = { view with V.mode = Detail } in
  let replaced =
    V.reconcile
      detail
      ~run:None
      ~filter:""
      (Some
         { snapshot with
           resources =
             Some
               { resources with
                 sources = [ original_source ]
               ; indexes = [ changed_index ]
               }
         })
  in
  assert (V.equal_mode replaced.mode Table && replaced.generation > detail.generation)
;;

let%test_unit "truncation is explicit in compact, table, context and comparison captures" =
  let view, snapshot = imported () in
  let view = { view with V.index = Some { index with truncated = true } } in
  let compact =
    V.summary view |> List.map ~f:Evidence_style.text |> String.concat ~sep:"\n"
  in
  assert (String.is_substring compact ~substring:"TRUNCATED");
  let captured, _ = V.input view ~filter:"" ~asic:snapshot Capture_left in
  let compared =
    V.compare_lines captured |> List.map ~f:Evidence_style.text |> String.concat ~sep:"\n"
  in
  assert (String.is_substring compared ~substring:"A coverage: TRUNCATED");
  List.iter [ V.Table; Context ] ~f:(fun mode ->
    let text =
      V.rows { view with mode } ~filter:"" ~asic:snapshot ~width:120 ~height:40
      |> List.map ~f:Evidence_style.text
      |> String.concat ~sep:"\n"
    in
    assert (String.is_substring text ~substring:"TRUNCATED"))
;;

let%test_unit "explicit source survives Main and filter changes; run-follow never \
               borrows imported/latest evidence"
  =
  let view, snapshot = imported () in
  let view, op = V.input view ~filter:"" ~asic:snapshot (Move 1) in
  assert (Option.is_none op);
  assert (Option.equal String.equal view.selected (Some "data"));
  let filtered =
    V.reconcile view ~run:(Some Fs0_fixture.run_b) ~filter:"program" snapshot
  in
  assert (Option.equal String.equal filtered.selected (Some "data"));
  assert (Option.equal R.Target.equal view.target filtered.target);
  let following =
    V.select_target filtered None
    |> fun t -> V.reconcile t ~run:(Some Fs0_fixture.run_b) ~filter:"" snapshot
  in
  assert (Option.is_none following.index);
  assert (Option.equal R.Target.equal following.target (Some (Run Fs0_fixture.run_b)))
;;

let%test_unit "detail uses exact resource/section/digest and changing digest invalidates \
               navigation and replies"
  =
  let view, snapshot = imported () in
  let view, op = V.input view ~filter:"program" ~asic:snapshot (Section "timing") in
  (match op with
   | Some (Detail { source_id; expected_digest; resource_id; section; offset; limit }) ->
     assert (String.equal source_id "source-a" && String.equal expected_digest "digest-a");
     assert (
       String.equal resource_id "program"
       && String.equal section "timing"
       && offset = 0
       && limit = 8)
   | _ -> assert false);
  let old = view.generation in
  let changed =
    V.reconcile
      view
      ~run:None
      ~filter:""
      (asic
         ~index:{ index with digest = "replacement" }
         (source (Coarse_run "/exact/capture")))
  in
  assert (V.equal_mode changed.mode Table && changed.generation > old);
  let received = V.receipt changed ~generation:old (Error "late failure") in
  assert (Option.is_none received.error);
  let closed, _ = V.input view ~filter:"" ~asic:snapshot Back in
  assert (
    (V.receipt closed ~generation:old (Error "closed request")).generation
    = closed.generation);
  assert (Option.is_none (V.receipt closed ~generation:old (Error "closed request")).error)
;;

let catalog offset next total : R.Artifacts.t =
  { source_id = "source-a"
  ; digest = "digest-a"
  ; offset
  ; next_offset = next
  ; total
  ; entries =
      List.init (next - offset) ~f:(fun n ->
        { R.Artifact.id = "opaque-" ^ Int.to_string (offset + n)
        ; label = "source"
        ; sha256 = "hash"
        ; format = "text"
        })
  }
;;

let%test_unit "all76 sources reachable through exact digest-bound pagination; byte \
               reader uses only catalog IDs"
  =
  let view, _ = imported () in
  let root = source (Coarse_run "/exact/capture") in
  let rec visit view offset seen =
    let finish = Int.min 76 (offset + 16) in
    let snapshot = asic ~artifacts:[ catalog offset finish 76 ] root in
    let view = { view with V.mode = Sources; catalog_offset = offset } in
    let page = V.current_catalog view snapshot |> Option.value_exn in
    let seen = seen + List.length page.entries in
    if finish = 76
    then view, snapshot, seen
    else (
      let view, op = V.input view ~filter:"" ~asic:snapshot Next_page in
      (match op with
       | Some (Artifacts { offset; expected_digest; _ }) ->
         assert (offset = finish && String.equal expected_digest "digest-a")
       | _ -> assert false);
      visit view finish seen)
  in
  let view, snapshot, seen = visit view 0 0 in
  assert (seen = 76);
  let view, _ = V.input view ~filter:"" ~asic:snapshot (Move 1) in
  let last =
    List.init 10 ~f:Fn.id
    |> List.fold ~init:view ~f:(fun view _ ->
      fst (V.input view ~filter:"" ~asic:snapshot (Move 1)))
  in
  let rendered =
    V.rows last ~filter:"" ~asic:snapshot ~width:80 ~height:24
    |> List.map ~f:Evidence_style.text
    |> String.concat ~sep:"\n"
  in
  assert (String.is_substring rendered ~substring:"opaque-75");
  let _, op = V.input view ~filter:"" ~asic:snapshot Open in
  (match op with
   | Some (Read_artifact { artifact_id; offset; limit; _ }) ->
     assert (String.equal artifact_id "opaque-65" && offset = 0 && limit = 4096)
   | _ -> assert false);
  let _, op = V.input view ~filter:"" ~asic:snapshot Previous_page in
  match op with
  | Some (Artifacts { offset; _ }) -> assert (offset = 48)
  | _ -> assert false
;;

let%test_unit "wrong source/digest/detail-row pages never appear; failed verdict and \
               freshness are independent"
  =
  let view, _ = imported () in
  let page : R.Detail.t =
    { source_id = "source-a"
    ; digest = "stale"
    ; resource_id = "program"
    ; section = "timing"
    ; offset = 0
    ; next_offset = 1
    ; total = 1
    ; items = [ { id = "bad"; title = "MUST_NOT_APPEAR"; fields = [] } ]
    }
  in
  let snapshot = asic ~details:[ page ] (source (Coarse_run "/exact/capture")) in
  let view = { view with V.mode = Detail; section = "timing" } in
  assert (Option.is_none (V.current_detail view snapshot));
  let rendered = text view snapshot in
  assert (not (String.is_substring rendered ~substring:"MUST_NOT_APPEAR"));
  List.iter
    [ "CACHED UNVERIFIED"
    ; "Resource verdict: fail"
    ; "Sampled timing"
    ; "not_assessed"
    ; "Actual role"
    ; "Selection reason"
    ]
    ~f:(fun s -> assert (String.is_substring rendered ~substring:s));
  let snapshot =
    asic
      { (source (Coarse_run "/exact/capture")) with
        freshness = Refresh_failed "changed source"
      }
  in
  let view = V.reconcile view ~run:None ~filter:"" snapshot in
  assert (
    String.is_substring (text view snapshot) ~substring:"Refresh failed: changed source")
;;

let measurement
  ?(stage = "final_physical")
  ?(scope = "macro footprint")
  ?(definition = "physical footprint")
  ?(unit_ = "um^2")
  value
  : R.Measurement.t
  =
  { name = "area"
  ; value
  ; stage
  ; scope
  ; definition
  ; unit_
  ; reason = None
  ; classification = Observed
  }
;;

let%test_unit "comparison needs matching stage/unit/definition/scope and finite supplied \
               measurements; estimates have no delta"
  =
  let render a b =
    V.compare_measurements [ a ] [ b ]
    |> List.map ~f:Evidence_style.text
    |> String.concat ~sep:"\n"
  in
  let a = measurement (Some 2.)
  and b = measurement (Some 5.) in
  assert (String.is_substring (render a b) ~substring:"Δ(B−A)=3");
  assert (String.is_substring (render b a) ~substring:"Δ(B−A)=-3");
  assert (
    not
      (String.is_substring
         (render { a with value = Some (-1e308) } { b with value = Some 1e308 })
         ~substring:"Δ(B−A)="));
  List.iter
    [ { b with stage = "placement" }
    ; { b with scope = "whole design" }
    ; { b with unit_ = "mm^2" }
    ; { b with definition = "Liberty estimate" }
    ; { b with value = None }
    ; { b with value = Some Float.nan }
    ]
    ~f:(fun b -> assert (not (String.is_substring (render a b) ~substring:"Δ(B−A)=")));
  let a =
    { a with
      stage = "synthesis"
    ; definition = "library estimate"
    ; classification = Estimate
    }
  in
  assert (
    not (String.is_substring (render a { a with value = Some 5. }) ~substring:"Δ(B−A)="))
;;

let%test_unit "typed inventory availability distinguishes unavailable, unknown, and \
               verified empty on every surface"
  =
  let view, snapshot = imported () in
  let render index mode =
    V.rows
      { view with V.index = Some index; mode; selected = None }
      ~filter:""
      ~asic:snapshot
      ~width:160
      ~height:60
    |> List.map ~f:Evidence_style.text
    |> String.concat ~sep:"\n"
  in
  let compact index =
    V.summary { view with V.index = Some index }
    |> List.map ~f:Evidence_style.text
    |> String.concat ~sep:"\n"
  in
  let absent =
    { index with
      rows = []
    ; inventory_status = Unavailable
    ; inventory_reason = Some "exact historic bundle association missing"
    }
  in
  let unknown =
    { index with rows = []; inventory_status = Unknown; inventory_reason = None }
  in
  let empty =
    { index with rows = []; inventory_status = Available; inventory_reason = None }
  in
  List.iter
    [ absent, "inventory unavailable"; unknown, "inventory unknown" ]
    ~f:(fun (index, qualification) ->
      List.iter
        [ compact index; render index Table; render index Context ]
        ~f:(fun text ->
          assert (String.is_substring text ~substring:qualification);
          assert (not (String.is_substring text ~substring:"0 resources"))));
  assert (
    String.is_substring
      (compact absent)
      ~substring:"exact historic bundle association missing");
  assert (
    String.is_substring
      (compact empty)
      ~substring:"0 resources (verified empty inventory)");
  let legacy =
    match R.Index.sexp_of_t empty with
    | Sexp.List fields ->
      Sexp.List
        (List.filter fields ~f:(function
          | Sexp.List (Sexp.Atom ("inventory_status" | "inventory_reason") :: _) -> false
          | _ -> true))
    | _ -> assert false
  in
  let legacy = R.Index.t_of_sexp legacy in
  assert (R.Inventory_status.equal legacy.inventory_status Unknown);
  assert (String.is_substring (compact legacy) ~substring:"inventory unknown")
;;

let%test_unit "measurement classification gates deltas independently of stage and \
               absence always shows its reason"
  =
  let text a b =
    V.compare_measurements [ a ] [ b ]
    |> List.map ~f:Evidence_style.text
    |> String.concat ~sep:"\n"
  in
  let estimate =
    { (measurement (Some 2.)) with R.Measurement.classification = Estimate }
  in
  List.iter [ "final_physical"; "synthesis" ] ~f:(fun stage ->
    let a = { estimate with stage } in
    let compared = text a { a with value = Some 5. } in
    assert (String.is_substring compared ~substring:"estimate");
    assert (not (String.is_substring compared ~substring:"Δ(B−A)=")));
  let missing =
    { estimate with
      stage = "synthesis"
    ; value = None
    ; reason = Some "bound Liberty absent"
    }
  in
  let compared = text missing missing in
  assert (String.is_substring compared ~substring:"unavailable — bound Liberty absent");
  assert (not (String.is_substring compared ~substring:"compatible supplied values"));
  assert (not (String.is_substring compared ~substring:"Δ(B−A)="));
  let derived = { estimate with classification = Derived; stage = "floorplan" } in
  let compared = text derived { derived with value = Some 5. } in
  assert (String.is_substring compared ~substring:"Δ(B−A)=3");
  assert (String.is_substring compared ~substring:"derived (source-qualified)");
  let unknown = { derived with classification = Unknown } in
  assert (
    not
      (String.is_substring
         (text unknown { unknown with value = Some 5. })
         ~substring:"Δ(B−A)="));
  assert (
    not
      (String.is_substring
         (text derived { derived with classification = Observed; value = Some 5. })
         ~substring:"Δ(B−A)="));
  let legacy =
    match R.Measurement.sexp_of_t derived with
    | Sexp.List fields ->
      Sexp.List
        (List.filter fields ~f:(function
          | Sexp.List (Sexp.Atom "classification" :: _) -> false
          | _ -> true))
    | _ -> assert false
  in
  let legacy = R.Measurement.t_of_sexp legacy in
  assert (R.Measurement.Classification.equal legacy.classification Unknown)
;;

let%test_unit "comparison captures stay exact across explicit source changes and Main \
               switches"
  =
  let view, snapshot = imported () in
  let view, _ = V.input view ~filter:"" ~asic:snapshot Capture_left in
  let view =
    V.select_target view (Some (Bundle "/new/bundle"))
    |> fun t -> V.reconcile t ~run:None ~filter:"" snapshot
  in
  assert (String.equal (Option.value_exn view.left).index.digest "digest-a");
  let view, _ = V.input view ~filter:"" ~asic:snapshot Show_compare in
  assert (
    String.is_substring
      (text view snapshot)
      ~substring:"Imported coarse evidence /exact/capture");
  assert (String.is_substring (text view snapshot) ~substring:"B: not captured")
;;

let%test_unit "resource render bounded at narrow widths and text content sanitized, no \
               operations on reconcile"
  =
  let view, snapshot = imported () in
  List.iter [ V.Table; Detail; Context; Sources; Text; Compare ] ~f:(fun mode ->
    List.iter
      [ 0, 0; 1, 1; 12, 4; 80, 24; 120, 40 ]
      ~f:(fun (width, height) ->
        let rows = V.rows { view with mode } ~filter:"" ~asic:snapshot ~width ~height in
        assert (List.length rows <= height);
        List.iter rows ~f:(fun row ->
          assert (
            Bonsai_term.View.width (Bonsai_term.View.text (Evidence_style.text row))
            <= width))))
;;

let%test_unit "source text preserves lines/hash/span and reconnect invalidates receipts \
               and validation"
  =
  let view, _ = imported () in
  let raw = "first\nsecond\027[31m\n" in
  let page : R.Bytes.t =
    { source_id = "source-a"
    ; digest = "digest-a"
    ; artifact_id = "authorized"
    ; sha256 = "exact-source-hash"
    ; offset = 0
    ; next_offset = String.length raw
    ; total = String.length raw
    ; bytes_hex = Cryptokit.transform_string (Cryptokit.Hexa.encode ()) raw
    }
  in
  let snapshot = asic ~bytes:[ page ] (source (Coarse_run "/exact/capture")) in
  let view = { view with V.mode = Text; artifact = Some "authorized" } in
  let rendered = text view snapshot in
  assert (String.is_substring rendered ~substring:"first\nsecond?[31m");
  assert (String.is_substring rendered ~substring:"exact-source-hash");
  assert (not (String.contains rendered '\027'));
  let old = view.generation in
  let view = V.reconnect view in
  assert (view.generation > old);
  assert (R.Freshness.equal (Option.value_exn view.source).freshness Cached_unverified);
  assert (Option.is_none (V.receipt view ~generation:old (Error "old connection")).error)
;;

let%test_unit "host resource keys and bounded import form dispatch typed actions without \
               launching"
  =
  let module H = Workspace_host in
  let module W = Workspace in
  let registry = W.initial ~session_id:(W.Session_id.of_string "resources-host") in
  let workspace = List.hd_exn registry.workspaces in
  let registry =
    W.apply
      registry
      (Mutate
         { expected_revision = registry.revision
         ; mutation =
             Create_tile
               { workspace = workspace.id
               ; kind = "resources"
               ; geometry = { x = 0; y = 0; width = 100; height = 30 }
               }
         })
    |> Result.ok
    |> Option.value_exn
  in
  let tile = List.find_exn registry.tiles ~f:(fun t -> String.equal t.kind "resources") in
  let host = { (H.receive H.empty registry) with focus = Some tile.id } in
  List.iter
    [ H.Enter, V.Open
    ; H.Character 'a', Show_sources
    ; H.Character 'g', Section "geometry"
    ; H.Character 't', Section "timing"
    ; H.Character 'e', Section "electrical"
    ; H.Character 'n', Next_page
    ; H.Escape, Back
    ]
    ~f:(fun (key, expected) ->
      let _, effect = H.input host key ~commands:[] in
      match effect with
      | H.Execute (_, Resource_input actual) -> assert (Poly.equal expected actual)
      | _ -> assert false);
  let capture = H.capture host |> Option.value_exn in
  let path = "/exact/source with spaces" in
  let host =
    { host with
      palette =
        Some
          { capture
          ; commands = []
          ; query = path
          ; index = 0
          ; argument = Some (Resource_path false)
          }
    }
  in
  let _, effect = H.input host Enter ~commands:[] in
  (match effect with
   | H.Execute (_, Resource_import_path (false, actual)) ->
     assert (String.equal actual path)
   | _ -> assert false);
  let host =
    { host with
      palette =
        Some
          { capture
          ; commands = []
          ; query = "/bad\npath"
          ; index = 0
          ; argument = Some (Resource_path true)
          }
    }
  in
  let host, effect = H.input host Enter ~commands:[] in
  assert (Option.is_some host.palette);
  match effect with
  | H.No_effect -> ()
  | _ -> assert false
;;

let%test_unit "resource host scopes invalidate A-B-A reads while explicit imports \
               survive selection revisions"
  =
  let module H = Workspace_host in
  let module W = Workspace in
  let registry = W.initial ~session_id:(W.Session_id.of_string "resources-binding") in
  let workspace = List.hd_exn registry.workspaces in
  let registry =
    W.apply
      registry
      (Mutate
         { expected_revision = registry.revision
         ; mutation =
             Create_tile
               { workspace = workspace.id
               ; kind = "resources"
               ; geometry = { x = 0; y = 0; width = 100; height = 30 }
               }
         })
    |> Result.ok
    |> Option.value_exn
  in
  let tile = List.find_exn registry.tiles ~f:(fun t -> String.equal t.kind "resources") in
  let select registry run =
    let context = W.context registry workspace.context in
    W.apply
      registry
      (Mutate
         { expected_revision = registry.revision
         ; mutation =
             Select_run
               { workspace = workspace.id
               ; context = context.id
               ; expected_selection_revision = context.selection_revision
               ; run = Some run
               }
         })
    |> Result.ok
    |> Option.value_exn
  in
  let registry = select registry Fs0_fixture.run_a in
  let resources_only = { registry with tiles = [ tile ] } in
  assert (List.is_empty (H.evidence_runs (H.receive H.empty resources_only)));
  let host = H.receive H.empty registry in
  let view = { V.empty with generation = 23; pending = Some "old read" } in
  let local = H.local host tile.id in
  let host = H.set_local host tile.id { local with resources = view } in
  let b = select registry Fs0_fixture.run_b in
  let host = H.receive host b in
  let host = H.receive host (select b Fs0_fixture.run_a) in
  let current = (H.local host tile.id).resources in
  assert (current.generation > 23 && Option.is_none current.pending);
  let imported, _ = imported () in
  let host =
    H.set_local host tile.id { (H.local host tile.id) with resources = imported }
  in
  let registry = Option.value_exn host.registry in
  let host = H.receive host (select registry Fs0_fixture.run_b) in
  assert (
    Option.equal
      R.Target.equal
      imported.explicit
      (H.local host tile.id).resources.explicit);
  assert ((H.local host tile.id).resources.generation = imported.generation)
;;
