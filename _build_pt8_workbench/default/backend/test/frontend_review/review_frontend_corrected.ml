(* Independent B rerun. Preserve every original assertion. Only original fixture
   corrections: construct C under the explicitly unpinned query it describes; make
   Exact an actual selected/result case before testing select_case Exact. Original
   review_frontend.ml is retained unchanged and is not imported/executed here. *)
open! Core
open! Async
open Hardcaml_workbench_protocol
module T = Terminal_presentation
module V = T.Workloads_view
module W = Asic_workloads
module S = Simulation
module Backend = Hardcaml_workbench_backend.Simulation_service

let checks = ref 0
let findings = ref []
let expect ?finding label good =
  incr checks;
  if good then Core.printf "PASS %s\n%!" label
  else (
    let id = Option.value finding ~default:"CONTROL-FAILURE" in
    findings := (id,label):: !findings;
    Core.printf "FINDING %s: %s\n%!" id label)
;;
let d c = String.make 64 c
let document digest result marker = Yojson.Safe.to_string (`Assoc
  ["contract",`String "hardcaml-asic.workload-inspection";"schema_version",`Int 1;
   "source_digest",`String digest;
   "binding",`Assoc ["bundle_identity",`String (d 'b');"hardware_variant_identity",`String (d 'c');
     "workload_identity",`String (d 'd');"simulation_sha256",`String (d 'e');
     "simulation_attempt_id",`String marker;"rtl_mode",`String "implementation"];
   "controls",`Assoc [];"provenance",`Assoc ["sources",`List [`Assoc ["path",`String result]]];
   "outcome",`Assoc ["status",`String "completed";"functional",`String "pass";"performance",`String "available"];
   "metrics",`List []])
let snapshot query digest marker =
  let key=V.key query in
  let descriptor : W.Descriptor.t =
    {key;query;digest=Some digest;provider_identity=Some (d 'f');freshness=Validated;error=None} in
  let result=match query with W.Query.Inspect q -> q.result | Compare _ -> failwith "Inspection fixture required" in
  let json=document digest result marker in
  ignore (Hardcaml_workbench_backend.Asic_workloads_service.validate_response query json : W.Response.t);
  let s : W.Snapshot.t =
    {entries=[descriptor];selected=Some {key;digest;json};cache_error=None} in
  Some {T.Fs0_fixture.snapshot with workloads=Some s}
let loaded ?expected_digest ?(digest=d 'a') path marker =
  let t,_=V.inspect V.empty path expected_digest ~refresh:false in
  let asic=snapshot (Option.value_exn t.query) digest marker in
  V.reconcile t asic, asic
let body t = Option.value_map t.V.document ~default:"" ~f:Yojson.Raw.to_string
let no_intent (_, op) = Option.is_none op

let digest_and_selection_review () =
  let a,asic_a=loaded ~expected_digest:(d 'a') "/retained/a.json" "A" in
  let a=V.capture a ~left:true ~bundle:"/bundles/a" in
  let b,_=V.inspect a "/retained/b.json" (Some (d 'b')) ~refresh:false in
  let b=V.reconcile b (snapshot (Option.value_exn b.query) (d 'b') "B") in
  let b=V.capture b ~left:false ~bundle:"/bundles/b" in
  let paired,op=V.compare b ~refresh:false in
  (match Option.value_exn op with
   | Load {query=Compare q;_} ->
     expect "first pair pins A inspection digest in workload field only"
       (Option.equal String.equal q.expected_left_workload_digest (Some (d 'a'))
        && Option.is_none q.expected_left_digest);
     expect "first pair pins B inspection digest without confusing bundle identity"
       (Option.equal String.equal q.expected_right_workload_digest (Some (d 'b'))
        && W.Target.equal q.right (Bundle "/bundles/b"))
   | _ -> failwith "Expected comparison query");
  let old=paired.generation in
  let swapped,swap_op=V.input paired ~asic:None ~filter:"" Swap in
  (match Option.value_exn swap_op with
   | Load {query=Compare q;_} ->
     expect "swap keeps digest with its original workload and bundle"
       (Option.equal String.equal q.left_workload (Some "/retained/b.json")
        && W.Target.equal q.left (Bundle "/bundles/b")
        && Option.equal String.equal q.expected_left_workload_digest (Some (d 'b')))
   | _ -> failwith "Expected swapped comparison");
  let axis,axis_op=V.input swapped ~asic:None ~filter:"" (Axis "hardware") in
  expect "axis query clears old comparison JSON and changes key"
    (Option.is_none axis.document && not (String.equal
      (W.Operation.key (Option.value_exn axis_op)) (W.Operation.key (Option.value_exn swap_op))));
  expect "late pair receipt cannot fail a newer axis"
    (Option.is_none (V.receipt axis ~generation:old ~floor:99 (Error "old pair")).error);
  let comparison_key=V.key (Option.value_exn paired.query) in
  let side target result workload_digest source_digest = `Assoc
    ["kind",`String "bundle";"target",`String target;"source_digest",`String source_digest;
     "identities",`Assoc [];"outcomes",`Assoc [];
     "workload",Yojson.Safe.from_string (document workload_digest result "simulation")] in
  let pair_json=Yojson.Safe.to_string (`Assoc
    ["contract",`String "hardcaml-asic.variant-comparison";"schema_version",`Int 1;
     "comparison_digest",`String (d 'e');"policy",`String "bounded-pair-v1";"axis",`String "resource_policy";
     "left",side "/bundles/a" "/retained/a.json" (d 'a') (d 'c');
     "right",side "/bundles/b" "/retained/b.json" (d 'b') (d 'd');
     "differences",`List [];"metrics",`List [];"workload",`Assoc [];"truncated",`Bool false]) in
  expect "comparison fixture passes production backend workload digest admission"
    (Result.is_ok (Or_error.try_with (fun () ->
       Hardcaml_workbench_backend.Asic_workloads_service.validate_response
         (Option.value_exn paired.query) pair_json)));
  let descriptor : W.Descriptor.t={key=comparison_key;query=Option.value_exn paired.query;
    digest=Some (d 'e');provider_identity=Some (d 'f');freshness=Validated;error=None} in
  let pair_snapshot=Some {T.Fs0_fixture.snapshot with workloads=Some
    {entries=[descriptor];selected=Some {key=comparison_key;digest=d 'e';json=pair_json};cache_error=None}} in
  let compared=V.reconcile paired pair_snapshot in
  let _,refresh=V.input compared ~asic:pair_snapshot ~filter:"" Refresh in
  expect ~finding:"F4" "refresh of a verified comparison pins both captured target-side digests"
    (match refresh with
     | Some (Load {query=Compare q;_}) ->
       Option.equal String.equal q.expected_left_digest (Some (d 'c'))
       && Option.equal String.equal q.expected_right_digest (Some (d 'd'))
     | _ -> false);
  let pinned,asic=loaded ~expected_digest:(d 'a') "/retained/shared.json" "PINNED-A" in
  let results,_=V.input pinned ~asic ~filter:"" Back in
  let reopened,reopen=V.input results ~asic ~filter:"" Open in
  expect ~finding:"F2" "Enter reopening an exact result-reference keeps its captured digest"
    (match reopen with Some (Load {query=Inspect q;_}) ->
       Option.equal String.equal q.expected_digest (Some (d 'a')) | _ -> false);
  (* Correct precondition: this is another, unpinned backend cache entry. It must
     not be constructed under the now-correctly-preserved pinned query. *)
  let new_asic=snapshot (Inspect {result="/retained/shared.json";expected_digest=None}) (d 'c') "NEWER-UNPINNED-C" in
  let shown=V.reconcile reopened new_asic in
  expect ~finding:"F2" "Enter cannot silently replace pinned A with a cached unpinned generation C"
    (not (String.is_substring (body shown) ~substring:"NEWER-UNPINNED-C"));
  let a,asic=loaded "/retained/a.json" "A" in
  let results,_=V.input a ~asic ~filter:"" Back in
  let base=Option.value_exn asic in
  let extra=Option.value_exn (snapshot (Inspect {result="/retained/b.json";expected_digest=None}) (d 'b') "B") in
  let s=Option.value_exn base.workloads and other=Option.value_exn extra.workloads in
  let all=Some {base with workloads=Some {s with entries=s.entries @ other.entries}} in
  let moved,_=V.input results ~asic:all ~filter:"" (Move 1) in
  let moved,_=V.input moved ~asic:all ~filter:"" (Move 1) in
  expect "adversarial list scenario selected B" (Option.equal String.equal moved.selected (Some "/retained/b.json"));
  let captured,_=V.input moved ~asic:all ~filter:""
    (Capture (true,"/bundles/b",V.capture_token moved)) in
  expect ~finding:"F3" "capture from selected B cannot bind old A result to B bundle"
    (match captured.left with None -> true | Some c -> String.equal c.result "/retained/b.json");
  (* Capturing is permitted only after validation, not merely restoring sidecar data. *)
  let restored=V.restore (V.remember pinned) in
  expect "restored source alone cannot grant a fresh capture"
    (Option.is_none (V.capture restored ~left:true ~bundle:"/bundle").left);
  let warm=V.reconcile restored asic_a in
  expect "unrelated cached source cannot hydrate restored query" (Option.is_none warm.document)
;;

let attempt id : S.Attempt.t =
  {id;job=Job_id.of_string "job-review";project_root="/review";created_at="review";parent=None;
   captured={selection={suite="pt8-memory-workloads";cases=["flops256";"exact256"];seed="34097";parameters=[];asic_inputs=[]};
     discovery_digest=d 'd';provider_executable="/review/provider";provider_args=[];environment=V1.Environment_selection.Inherit_daemon};
   lifecycle=Finished;outcome=Passed;exit_code=Some 0;diagnostic=None;progress=None;
   cases=[{case_id="flops256";status=Passed;message=None;progress=None};
          {case_id="exact256";status=Passed;message=None;progress=None}];artifacts=[];
   next_sequence=0;recent_events=[];execution_timing=None}
let sim_snapshot detail : S.Snapshot.t =
  {configured=true;discovery=None;discovery_digest=None;discovery_job=None;discovery_error=None;
   attempts=[];next_before=None;detail=Some detail;byte_page=None;history_error=None}
let testing detail =
  let view={T.Simulation_view.empty with snapshot=Some (sim_snapshot detail);
    attempt=Some detail.S.Attempt.id;case_id=Some "flops256"} in
  T.Testing_workspace.set_view T.Testing_workspace.empty view

let production_artifact_review () =
  (* Obtain the real backend-generated artifact identity, rather than assuming a
     provider declaration's ID is the public RPC ID. No provider/daemon is spawned. *)
  let root=Core_unix.mkdtemp "/tmp/opencode/pt8-frontend-review-" in
  let service=Backend.create ~state_dir:(Filename.concat root "state") in
  let project=Backend.project service root in
  let dir=Filename.concat project.dir "review-entry" in
  let source=Filename.concat dir "work/artifacts" in
  Core_unix.mkdir_p source;
  let bytes=sprintf {|{"contract":"hardcaml-workbench.pt8-result-reference","schema_version":1,"result":"/retained/result.json","source_digest":"%s"}|} (d 'a') in
  Out_channel.write_all (Filename.concat source "reference.json") ~data:bytes;
  let attempt=attempt "sim-review" in
  let record : Backend.Record.t={schema_version=1;submission_key="review";payload="";attempt} in
  let entry : Backend.entry={record;dir} in
  Hashtbl.set project.entries ~key:attempt.id ~data:entry;
  let artifact=Backend.capture_artifact project entry
    {id="flops256-result-reference";case_id=Some "flops256";label="Result reference";
     kind="pt8-result-reference";media_type="application/json";path="reference.json"} in
  expect "real FS2 capture produced an available immutable reference artifact"
    (S.Artifact.Availability.equal artifact.availability Available
     && String.equal artifact.id "sim-review-flops256-result-reference");
  let detail={attempt with artifacts=[artifact]} in
  let state=testing detail in
  expect ~finding:"F1" "Testing discovers a real backend-prefixed PT8 reference artifact"
    (Option.is_some (T.Testing_workspace.workload_artifact state));
  let explicitly=T.Testing_workspace.select_artifact state artifact.id in
  expect ~finding:"F1" "explicit artifact selection also enables the PT8 result handoff"
    (Option.is_some (T.Testing_workspace.workload_artifact explicitly));
  expect "other case cannot borrow the captured reference"
    (Option.is_none (T.Testing_workspace.workload_artifact (T.Testing_workspace.select_case state "exact256")));
  expect "running attempt does not expose a completed handoff"
    (Option.is_none (T.Testing_workspace.workload_artifact (testing {detail with lifecycle=Running})));
  let sha256=Option.value_exn artifact.sha256 in
  let page : S.Byte_page.t={attempt_id=attempt.id;artifact_id=artifact.id;sha256;offset=0;
    next_offset=String.length bytes;total_size=String.length bytes;eof=true;
    bytes_hex=Cryptokit.transform_string (Cryptokit.Hexa.encode ()) bytes} in
  expect "production FS2 byte validator accepts the retained reference"
    (Result.is_ok (T.Simulation_export.validate artifact ~offset:0 page));
  List.iter ["attempt",{page with attempt_id="other"};"artifact",{page with artifact_id="other"};
    "digest",{page with sha256=d 'e'};"span",{page with next_offset=page.next_offset-1};
    "truncated hex",{page with bytes_hex=String.drop_suffix page.bytes_hex 1};
    "invalid hex",{page with bytes_hex="gg"};"EOF",{page with eof=false}]
    ~f:(fun (label,page) -> expect ("FS2 byte control rejects " ^ label)
      (Result.is_error (T.Simulation_export.validate artifact ~offset:0 page)));
  expect "reference retains the public inspection digest rather than artifact digest"
    (match V.reference bytes with Ok (path,source_digest) -> String.equal path "/retained/result.json"
       && String.equal source_digest (d 'a') && not (String.equal source_digest sha256) | Error _ -> false);
  let duplicate=sprintf
    {|{"contract":"hardcaml-workbench.pt8-result-reference","schema_version":1,"result":"/first","result":"/second","source_digest":"%s"}|} (d 'a') in
  expect "duplicate result fields reject even with a valid digest" (Result.is_error (V.reference duplicate));
  let wrong_digest=String.substr_replace_all bytes ~pattern:(d 'a') ~with_:(d 'A') in
  expect "uppercase public digest is not accepted as the frozen SHA token" (Result.is_error (V.reference wrong_digest));
  List.iter ["relative","relative.json";"NUL","/retained/\000result";"newline","/retained/\nresult"]
    ~f:(fun (label,path) ->
      let j=Yojson.Safe.from_string bytes in
      let bad=match j with `Assoc xs -> Yojson.Safe.to_string (`Assoc (("result",`String path)::List.Assoc.remove xs "result" ~equal:String.equal)) | _ -> assert false in
      expect ("reference rejects " ^ label) (Result.is_error (V.reference bad)))
;;

let state_and_layout_review () =
  let loaded,asic=loaded "/retained/a.json" "A" in
  let generation=loaded.generation in
  let other,op=V.inspect loaded "/retained/b.json" None ~refresh:false in
  let other=V.admit other ~generation:other.generation ~request_floor:10 in
  let other=V.reconcile ~revision:11 other asic in
  expect "held old-source snapshot cannot supply B JSON" (Option.is_none other.document);
  expect "held old-source error cannot release B pending request"
    (Option.is_some (V.receipt other ~generation ~floor:20 (Error "late A")).pending);
  let query=Option.value_exn other.query in
  let fresh=snapshot query (d 'b') "B" in
  let other=V.receipt other ~generation:other.generation ~floor:20 (Ok ()) in
  let opkey=W.Operation.key (Option.value_exn op) in
  let failed : Asic.Pending.t={key=opkey;kind="workloads";state="failed";run=None;error=Some "old failure";activity=Evidence_read} in
  let early=Some {(Option.value_exn fresh) with operations=[failed]} in
  expect "same-key pre-receipt failure cannot acknowledge the new request"
    (Option.is_some (V.reconcile ~revision:19 other early).pending);
  let failed=V.reconcile ~revision:20 other early in
  expect "post-receipt failure keeps retained facts and diagnostic"
    (Option.is_some failed.document && Option.is_some failed.error && Option.is_none failed.pending);
  let disconnected=V.reconnect failed in
  expect "reconnect fences held receipt and revokes validated descriptor status"
    ((V.receipt disconnected ~generation:failed.generation ~floor:30 (Error "old transport")).generation=disconnected.generation
     && Option.value_map disconnected.descriptor ~default:false ~f:(fun d -> W.Freshness.equal d.freshness Cached_unverified));
  let module H=T.Workspace_host in
  let host,data,find=T.Host_view.refinement_fixture
    (Hardcaml_workbench_workspaces.Presets.find "workloads" |> Option.value_exn) in
  let tile=find "workloads" in
  let local=H.local host tile.id in
  let host=H.set_local host tile.id {local with workloads=loaded} in
  let replaced=H.reconnect host ~replacement:true in
  expect "project/daemon replacement drops tile-local document and captures"
    (Option.is_none (H.local replaced tile.id).workloads.document && Option.is_none replaced.registry);
  let registry=Option.value_exn host.registry in
  let custom={registry with tiles=List.map registry.tiles ~f:(fun t -> if Workspace.Tile_id.equal t.id tile.id then {t with hidden=true} else t)} in
  let preserved=H.receive host custom in
  expect "hidden custom layout is preserved while Workloads state remains tile-local"
    (Workspace.Snapshot.equal custom (Option.value_exn preserved.registry)
     && V.equal_saved (V.remember (H.local preserved tile.id).workloads) (V.remember loaded));
  List.iter [0,0;1,1;20,8;80,24;200,70] ~f:(fun (width,height) ->
    ignore (T.Host_view.tile_view host {data with asic} tile ~width ~height));
  List.iter [V.Show_provenance;Scroll 10;Scroll (-100);Back;Move 1] ~f:(fun input ->
    expect "paint/navigation event emits no provider intent" (no_intent (V.input loaded ~asic ~filter:"not found" input)));
  expect "painting did not mutate the active query/generation"
    ((H.local host tile.id).workloads.generation=generation)
;;

let metadata_and_locator_review () =
  let path="/retained/locator/result.json" and bundle="/verified/bundles/exact" in
  let t,asic=loaded ~expected_digest:(d 'a') path "locator-simulation" in
  let base=Option.value_exn asic in
  let cached=Option.value_exn base.workloads in
  let response=Option.value_exn cached.selected in
  let add_locator json locator = match Yojson.Safe.from_string json with
    | `Assoc fields ->
      let binding=List.Assoc.find_exn fields "binding" ~equal:String.equal in
      let binding=match binding with `Assoc xs -> `Assoc (("bundle",locator)::xs) | _ -> assert false in
      Yojson.Safe.to_string (`Assoc (("binding",binding)::List.Assoc.remove fields "binding" ~equal:String.equal))
    | _ -> assert false in
  let json=add_locator response.json (`String bundle) in
  ignore (Hardcaml_workbench_backend.Asic_workloads_service.validate_response
    (Option.value_exn t.query) json : W.Response.t);
  let with_locator=Some {base with workloads=Some {cached with selected=Some {response with json}}} in
  (* Model a fresh view so the locator payload is parsed, rather than changing raw
     content underneath an unchanged cached digest/provider identity. *)
  let fresh,_=V.inspect V.empty path (Some (d 'a')) ~refresh:false in
  let valid=V.reconcile fresh with_locator in
  expect "verified locator is supplied directly from the admitted binding"
    (Option.equal String.equal (V.verified_bundle valid) (Some bundle));
  let auto,operation=V.input valid ~asic:with_locator ~filter:""
    (Capture (true,Option.value_exn (V.verified_bundle valid),V.capture_token valid)) in
  expect "locator capture emits no provider operation or manual-path requirement" (Option.is_none operation);
  expect "locator capture keeps exact result source digest bundle and reader identity"
    (match auto.left with Some c -> String.equal c.result path && String.equal c.bundle bundle
      && String.equal c.source_digest (d 'a') && String.equal c.provider (d 'f') | None -> false);
  let wrong=V.capture valid ~left:true ~bundle:"/unrelated/bundle" in
  expect "manual path cannot override a verified locator"
    (Option.is_none wrong.left && Option.is_some wrong.error);
  expect "legacy projection has no invented locator" (Option.is_none (V.verified_bundle t));
  expect "legacy validated projection still permits explicit bundle capture"
    (Option.is_some (V.capture t ~left:true ~bundle).left);
  let descriptor=Option.value_exn valid.descriptor in
  List.iter
    ["descriptor key",{descriptor with key="wrong-key"};
     "descriptor query",{descriptor with query=Inspect {result="/unrelated/result.json";expected_digest=None}};
     "unverified freshness",{descriptor with freshness=Cached_unverified};
     "missing provider",{descriptor with provider_identity=None};
     "missing digest",{descriptor with digest=None}]
    ~f:(fun (label,descriptor) ->
      let inconsistent={valid with descriptor=Some descriptor} in
      expect ("capture metadata guard rejects " ^ label)
        (Option.is_none (V.verified_bundle inconsistent)
         && Option.is_none (V.capture inconsistent ~left:true ~bundle).left));
  List.iter [`String "relative";`Null;`String "/bad\000locator"] ~f:(fun locator ->
    expect "invalid additive locator fails backend admission"
      (Result.is_error (Or_error.try_with (fun () ->
        Hardcaml_workbench_backend.Asic_workloads_service.validate_response
          (Option.value_exn valid.query) (add_locator response.json locator)))));
  let result_state,_=V.input valid ~asic:with_locator ~filter:"" Back in
  expect "results-list mode cannot auto-capture a formerly loaded locator"
    (Option.is_none (V.verified_bundle result_state));
  let pinned=Option.value_exn valid.query in
  let mismatched={descriptor with digest=Some (d 'c')} in
  let impossible=Some {base with workloads=Some
    {cached with entries=[mismatched];selected=Some {key=V.key pinned;digest=d 'c';json=document (d 'c') path "wrong-C"}}} in
  let clean,_=V.inspect V.empty path (Some (d 'a')) ~refresh:false in
  expect "defensive receipt metadata cannot smuggle C under pinned A's key"
    (Option.is_none (V.reconcile clean impossible).document)
;;

let full_fs2_binding_review () =
  let root=Core_unix.mkdtemp "/tmp/opencode/pt8-frontend-binding-" in
  let service=Backend.create ~state_dir:(Filename.concat root "state") in
  let project=Backend.project service root in
  let dir=Filename.concat project.dir "entry" in
  let source=Filename.concat dir "work/artifacts" in
  Core_unix.mkdir_p source;
  Out_channel.write_all (Filename.concat source "reference.json") ~data:"{}";
  let detail=attempt "sim-review-binding" in
  let entry : Backend.entry={dir;record={schema_version=1;submission_key="binding";payload="";attempt=detail}} in
  Hashtbl.set project.entries ~key:detail.id ~data:entry;
  let capture case_id=Backend.capture_artifact project entry
    {id=case_id^"-result-reference";case_id=Some case_id;label="Result";kind="pt8-result-reference";
     media_type="application/json";path="reference.json"} in
  let flops=capture "flops256" and exact=capture "exact256" in
  let detail={detail with artifacts=[flops;exact]} in
  let state=testing detail in
  expect "both positive cases have actual backend-prefixed public artifact IDs"
    (String.equal flops.id (detail.id^"-flops256-result-reference")
     && String.equal exact.id (detail.id^"-exact256-result-reference")
     && S.Artifact.Availability.equal exact.availability Available);
  expect "Flops selects its own actual reference when both cases exist"
    (Option.equal S.Artifact.equal (T.Testing_workspace.workload_artifact state) (Some flops));
  let other=T.Testing_workspace.select_case state "exact256" in
  expect "other-case control really navigated to a selected Exact case"
    (Option.equal String.equal (T.Testing_workspace.view other).case_id (Some "exact256"));
  expect "Exact selects its own actual reference instead of borrowing Flops"
    (Option.equal S.Artifact.equal (T.Testing_workspace.workload_artifact other) (Some exact));
  expect "explicit Exact artifact selection uses the same public identity"
    (Option.equal S.Artifact.equal
      (T.Testing_workspace.workload_artifact (T.Testing_workspace.select_artifact state exact.id)) (Some exact));
  List.iter
    ["foreign attempt metadata",{flops with attempt_id="sim-other"};
     "foreign attempt prefix",{flops with id="sim-other-flops256-result-reference"};
     "suffix-only impostor",{flops with id="junk-"^flops.id};
     "bare provider ID",{flops with id="flops256-result-reference"};
     "wrong case metadata",{flops with case_id=Some "exact256"};
     "suite metadata",{flops with case_id=None};
     "wrong media type",{flops with media_type="application/octet-stream"};
     "changed bytes",{flops with availability=Changed}]
    ~f:(fun (label,artifact) ->
      expect ("actual artifact binding rejects " ^ label)
        (Option.is_none (T.Testing_workspace.workload_artifact (testing {detail with artifacts=[artifact]}))));
  let not_selected={detail with captured={detail.captured with selection={detail.captured.selection with cases=["exact256"]}}} in
  expect "case must belong to the captured producer selection"
    (Option.is_none (T.Testing_workspace.workload_artifact (testing not_selected)));
  let missing_case={detail with cases=List.filter detail.cases ~f:(fun c -> String.equal c.case_id "exact256")} in
  expect "case must also exist in the retained case result list"
    (Option.is_none (T.Testing_workspace.workload_artifact (testing missing_case)));
  let unrelated=T.Testing_workspace.set_view state {(T.Testing_workspace.view state) with attempt=Some "sim-other"} in
  expect "selected attempt cannot borrow another snapshot's detail"
    (Option.is_none (T.Testing_workspace.workload_artifact unrelated));
  let restored=T.Testing_workspace.restore_selection state ~attempt:detail.id ~case_id:(Some "flops256")
    ~artifact:(Some {id=flops.id;sha256=Some (d 'e');size=flops.size}) in
  let restored=T.Testing_workspace.set_view restored (T.Testing_workspace.view state) in
  expect "restored artifact hash mismatch cannot fall back to another case reference"
    (Option.is_none (T.Testing_workspace.workload_artifact restored))
;;

let () =
  digest_and_selection_review ();
  production_artifact_review ();
  state_and_layout_review ();
  metadata_and_locator_review ();
  full_fs2_binding_review ();
  Core.printf "\nIndependent corrected frontend review: %d checks; %d contract failures\n%!" !checks (List.length !findings);
  if not (List.is_empty !findings) then Stdlib.exit 1
