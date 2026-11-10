open! Core
open! Async
open Hardcaml_workbench_protocol
module S = Hardcaml_workbench_backend.Asic_resources_service
module W = Asic_resources
module P = Hardcaml_workbench_backend.Asic_public
let checks = ref 0
let require b message = incr checks; if not b then failwith message
let rejects f = require (Result.is_error (Or_error.try_with f)) "Expected resource rejection"
let str x = `String x
let obj x = `Assoc x
let replace j k v = match j with `Assoc xs -> obj ((k,v)::List.Assoc.remove xs k ~equal:String.equal) | _ -> assert false
let remove j k = match j with `Assoc xs -> obj (List.Assoc.remove xs k ~equal:String.equal) | _ -> assert false
let digest = String.make 64 'a'
let measurement = obj ["name",str "area";"value",`Float 28127.104;"unit",str "um^2";
  "stage",str "final_physical";"scope",str "macro rectangle";"definition",str "observed footprint";"reason",`Null;
  "classification",str "derived"]
let row = obj ["id",str "program";"contract",str "256x16";"requirement",str "exact";
  "policy",str "instance";"implementation",str "SRAM";"reason",str "exact_mapping";"role",str "selected_implementation";
  "instances",`List [str "hc_resource_7_program"];"synthesis",str "matched";"final",str "missing";
  "measurements",`List [measurement];"sections",`List [obj ["id",str "timing";"count",`Int 186;"status",str "available"]]]
let source target : W.Source.t =
  {id="source";target;kind="coarse_run";path="/retained/root";label="root";
   provider_identity="provider";freshness=Validated;error=None}
let common query = ["contract",str "hardcaml-asic.resource-inspection";"schema_version",`Int 1;
  "kind",str "coarse_run";"target",str "/retained/root";"query",str query;
  "source_digest",str digest;"provenance",obj ["run_id",str "real-run"];
  "verdict",str "fail"]
let response = obj (common "index" @ ["rows",`List [row];"measurements",`List [measurement];
  "artifact_count",`Int 76;"diagnostics",`List [str "required resource missing"];"truncated",`Bool false;
  "inventory_status",str "available";"inventory_reason",`Null])
let real_provider () =
  match Sys.getenv "PT6_RESOURCE_PROVIDER",Sys.getenv "PT6_RETAINED_ROOT" with
  | Some executable,Some retained ->
    let retained=Filename_unix.realpath retained in
    let invocation : Hardcaml_workbench_adapters.Dune_adapter.Invocation.t =
      {executable;argv=[executable;"resource-inspect";retained;"--kind";"coarse_run";"--json"];
       cwd=Filename.dirname retained;environment=V1.Environment_selection.Inherit_daemon} in
    let%map output=Hardcaml_workbench_backend.Asic_process.run_with_status ~accept_evidence_failure:true
      ~max_stdout_bytes:(2*1024*1024) ~max_record_bytes:(2*1024*1024) ~seconds:30.
      ~cancel:(Deferred.never ()) ~on_process:ignore ~on_line:(fun _ -> Deferred.unit) invocation in
    let src={ (source (W.Target.Coarse_run retained)) with path=retained } in
    let index=S.parse_index src (S.parse_process_result output) in
    require (W.Inventory_status.equal index.inventory_status Available && Option.is_none index.inventory_reason) "Actual inventory availability lost";
    require (index.artifact_count=76 && List.length index.rows=1) "Actual provider index did not project";
    let row=List.hd_exn index.rows in
    require (List.exists row.measurements ~f:(fun m -> String.equal m.W.Measurement.stage "synthesis"
      && W.Measurement.Classification.equal m.classification Estimate && not (W.Measurement.is_measured m))) "Actual synthesis estimate promoted";
    require (List.exists row.measurements ~f:(fun m -> String.equal m.W.Measurement.stage "final_physical"
      && W.Measurement.Classification.equal m.classification Derived && W.Measurement.is_measured m)) "Actual footprint classification lost";
    require (String.equal row.id "program" && String.equal row.requirement "exact") "Actual provider resource identity/requirement lost";
    require (List.exists row.sections ~f:(fun s -> String.equal s.W.Section.id "timing" && s.count=186)) "Actual sampled path count lost";
    require (List.exists index.measurements ~f:(fun m -> String.equal m.W.Measurement.name "gross_core_area" && Option.exists m.value ~f:(fun n -> Float.(abs (n-.902417.2416)<0.0001)))) "Actual gross core area unavailable";
    require (List.exists index.measurements ~f:(fun m -> String.equal m.W.Measurement.name "nonspacer_component_area" && Option.exists m.value ~f:(fun n -> Float.(abs (n-.4793.6448)<0.0001)))) "Actual exact nonspacer area unavailable"
  | _ -> Deferred.unit
;;
let integration () =
  let module Service=Hardcaml_workbench_backend.Asic_service in
  let module Config=Hardcaml_workbench_project_integration.Asic_config in
  let root=Core_unix.mkdtemp "/tmp/workbench-resource-service-" |> Filename_unix.realpath in
  let file name=Filename.concat root name in
  let executable=file "provider" and companion=file "hardcaml-asic-experimental-resource-inspect" in
  let script=In_channel.read_all "provider.py" in
  Out_channel.write_all executable ~data:script; Core_unix.chmod executable ~perm:0o700;
  Out_channel.write_all companion ~data:script;
  let state_dir=file "state" and retained=file "retained" in
  Core_unix.mkdir_p state_dir; Core_unix.mkdir_p retained;
  let config : Config.t = {schema_version=1;project_executable=executable;provider_executable=executable;
    results_root=file "results";toolchain=file "tools";python=None;support_tools=None;pdk_root=None;stage_timeout_seconds=None} in
  Out_channel.write_all (file Config.filename) ~data:(Sexp.to_string_mach (Config.sexp_of_t config));
  Out_channel.write_all (file "response.json") ~data:(Yojson.Safe.to_string response);
  Out_channel.write_all (file "delay") ~data:"delay";
  let service=Service.create ~state_dir in
  let handle service operation=Service.handle service ~root ~environment:V1.Environment_selection.Inherit_daemon operation
    >>| function Ok s -> s | Error e -> failwith e.V1.Error.message in
  let calls ()=if Poly.equal (Sys_unix.file_exists (file "calls")) `Yes then In_channel.read_lines (file "calls") else [] in
  let index_calls ()=List.count (calls ()) ~f:(fun s -> String.is_substring s ~substring:"resource-inspect") in
  let target=W.Target.Coarse_run retained in
  let operation refresh=W.Operation.Load {target;refresh} in
  let wait service operation =
    let key=W.Operation.key operation in
    let rec loop ()=
      let%bind s=handle service Asic.Operation.Get in
      if List.exists s.operations ~f:(fun p -> String.equal p.Asic.Pending.key key && List.mem ["completed";"failed"] p.state ~equal:String.equal)
      then return s else let%bind ()=Clock.after (Time_float.Span.of_ms 10.) in loop () in
    Clock.with_timeout (Time_float.Span.of_sec 10.) (loop ()) >>| function
    | `Result s -> s | `Timeout -> failwith "Resource integration task timeout" in
  let%bind _=handle service Get in
  require (List.is_empty (calls ())) "Get contacted resource provider";
  let%bind _=handle service (Resources (operation false)) in
  let%bind _=handle service (Resources (operation true)) in
  let%bind loaded=wait service (operation false) in
  let resources=Option.value_exn loaded.resources in
  require (List.is_empty loaded.runs && List.length resources.sources=1 && List.length resources.indexes=1) "Coarse import fabricated run or lost index";
  require (index_calls ()=1) "Coalesced Load/Refresh duplicated provider read";
  let original_identity=(List.hd_exn resources.sources).provider_identity in
  let%bind _=handle service (Resources (operation false)) in
  let%bind _=wait service (operation false) in
  require (index_calls ()=1) "Warm reopen invoked provider";
  let%bind ()=Service.shutdown service in
  let restarted=Service.create ~state_dir in
  let%bind reopened=handle restarted Get in
  let resource=List.hd_exn (Option.value_exn reopened.resources).sources in
  require (W.Freshness.equal resource.freshness Cached_unverified && index_calls ()=1) "Restart performed resource read or claimed validation";
  Out_channel.write_all companion ~data:(script^"\n# new native companion generation\n");
  let%bind _=handle restarted (Resources (operation true)) in
  let%bind refreshed=wait restarted (operation true) in
  let resources=Option.value_exn refreshed.resources in
  require (not (String.equal original_identity (List.hd_exn resources.sources).provider_identity)) "Only dispatcher hash bound provider generation";
  require (String.equal (List.hd_exn resources.indexes).verdict "fail") "CLI1 failed evidence became transport failure";
  let refresh () =
    let%bind _=handle restarted (Resources (operation true)) in
    wait restarted (operation true) >>| fun s -> Option.value_exn s.resources in
  Out_channel.write_all (file "exit-code") ~data:"1";
  Out_channel.write_all (file "response.json") ~data:(Yojson.Safe.to_string (replace response "verdict" (str "pass")));
  let%bind disagreement=refresh () in
  require (String.equal (List.hd_exn disagreement.indexes).verdict "fail"
    && Option.exists (List.hd_exn disagreement.sources).error ~f:(fun e -> String.is_substring e ~substring:"exit/verdict disagreement"))
    "Asic_service admitted exit1/pass or replaced genuine failed evidence";
  Out_channel.write_all (file "exit-code") ~data:"0";
  Out_channel.write_all (file "response.json") ~data:(Yojson.Safe.to_string response);
  let%bind disagreement=refresh () in
  require (Option.exists (List.hd_exn disagreement.sources).error ~f:(fun e -> String.is_substring e ~substring:"exit/verdict disagreement"))
    "Asic_service admitted exit0/fail";
  Out_channel.write_all (file "response.json") ~data:(Yojson.Safe.to_string (replace response "verdict" (str "pass")));
  let%bind consistent=refresh () in
  require (String.equal (List.hd_exn consistent.indexes).verdict "pass" && Option.is_none (List.hd_exn consistent.sources).error)
    "Consistent exit0/pass could not recover after disagreement";
  Core_unix.unlink (file "exit-code");
  Out_channel.write_all (file "response.json") ~data:(Yojson.Safe.to_string response);
  let%bind consistent=refresh () in
  require (String.equal (List.hd_exn consistent.indexes).verdict "fail" && Option.is_none (List.hd_exn consistent.sources).error)
    "Consistent exit1/fail became unreadable after disagreement";
  Out_channel.write_all (file "fail") ~data:"fail";
  let%bind _=handle restarted (Resources (operation true)) in
  let%bind failed=wait restarted (operation true) in
  let resources=Option.value_exn failed.resources in
  require (List.length resources.indexes=1 && (match (List.hd_exn resources.sources).freshness with Refresh_failed _ -> true | _ -> false)) "Refresh failure lost stale evidence status";
  let count=index_calls () in
  let%bind _=handle restarted Get in
  require (index_calls ()=count) "Get retried failed resource read";
  Out_channel.write_all (file "unsupported") ~data:"unsupported";
  Core_unix.unlink companion;
  let%bind _=handle restarted (Resources (operation true)) in
  let%bind unsupported=wait restarted (operation true) in
  require ((match (List.hd_exn (Option.value_exn unsupported.resources).sources).freshness with Unsupported _ -> true | _ -> false)
    && index_calls ()=count) "Legacy provider was not distinguished from missing evidence";
  let overlap=W.Operation.Load {target=W.Target.Coarse_run root;refresh=true} in
  let%bind _=handle restarted (Resources overlap) in
  let%bind overlap=wait restarted overlap in
  require (List.exists overlap.operations ~f:(fun p -> String.equal p.Asic.Pending.state "failed"
    && Option.exists p.error ~f:(fun e -> String.is_substring e ~substring:"outside the selected evidence root")))
    "Evidence import allowed Workbench cache writes inside its source root";
  Service.shutdown restarted
;;
let main () =
  let target=W.Target.Coarse_run "/retained/root" in
  let src=source target in
  let parsed=S.parse_index src response in
  require (String.equal parsed.verdict "fail" && List.length parsed.rows=1) "Failed resource evidence discarded";
  require (W.Inventory_status.equal parsed.inventory_status Available) "Available inventory did not decode";
  let unavailable=replace (replace (replace (replace response "rows" (`List [])) "inventory_status" (str "unavailable"))
    "inventory_reason" (str "no recoverable historical inventory")) "verdict" (str "not_evaluated") in
  let unavailable_index=S.parse_index src unavailable in
  require (W.Inventory_status.equal unavailable_index.inventory_status Unavailable
    && Option.is_some unavailable_index.inventory_reason) "Unavailable historical inventory became empty available";
  let empty=S.parse_index src (replace response "rows" (`List [])) in
  require (W.Inventory_status.equal empty.inventory_status Available && List.is_empty empty.rows) "Verified empty inventory not available";
  List.iter [ replace response "inventory_status" (str "present")
    ; replace response "inventory_status" `Null
    ; replace response "inventory_reason" (str "not allowed for available")
    ; replace unavailable "inventory_reason" `Null
    ; replace unavailable "inventory_reason" (str "  ")
    ; replace unavailable "rows" (`List [row])
    ; replace unavailable "verdict" (str "pass")
    ; remove response "inventory_reason"
    ; remove response "inventory_status"
    ; replace response "measurements" (`List [replace measurement "classification" (str "measured")])
    ; replace response "measurements" (`List [replace measurement "classification" `Null])
    ; replace response "rows" (`List [replace row "measurements" (`List [replace measurement "classification" (str "arbitrary")])]) ]
    ~f:(fun j -> rejects (fun () -> S.parse_index src j));
  let legacy_measurement=remove measurement "classification" in
  let legacy_response=remove (remove (replace (replace response "measurements" (`List [legacy_measurement]))
    "rows" (`List [replace row "measurements" (`List [legacy_measurement])])) "inventory_status") "inventory_reason" in
  let legacy=S.parse_index src legacy_response in
  require (W.Inventory_status.equal legacy.inventory_status Unknown && Option.is_none legacy.inventory_reason
    && List.for_all (legacy.measurements @ List.concat_map legacy.rows ~f:(fun r -> r.measurements))
      ~f:(fun m -> W.Measurement.Classification.equal m.classification Unknown && not (W.Measurement.is_measured m)))
    "Missing legacy fields promoted inventory or measurements";
  List.iter ["contract",str "wrong";"kind",str "bundle";"target",str "/other";"source_digest",str "bad";
    "rows",`List [row;row];"artifact_count",`Int 1025;"rows",`List [replace row "measurements" (`List [replace measurement "value" (`Float Float.nan)])];
    "rows",`List (List.init 4097 ~f:(fun i -> replace row "id" (str (Int.to_string i))));
    "unexpected",`Bool true] ~f:(fun (k,v) -> rejects (fun () -> S.parse_index src (replace response k v)));
  let m=List.hd_exn parsed.measurements in
  require (W.Measurement.compatible m m) "Same measurement incompatible";
  require (not (W.Measurement.compatible m {m with scope="whole design"})) "Different scope compared";
  require (not (W.Measurement.compatible m {m with stage="synthesis"})) "Different stage compared";
  require (not (W.Measurement.compatible m {m with definition="Liberty estimate"})) "Different definition compared";
  List.iter [W.Measurement.Classification.Observed;Derived] ~f:(fun classification ->
    require (W.Measurement.is_measured {m with classification}) "Measured classification suppressed");
  List.iter [W.Measurement.Classification.Estimate;Unknown] ~f:(fun classification ->
    require (not (W.Measurement.is_measured {m with classification})) "Estimate/unknown accepted as measured");
  require (not (W.Measurement.compatible m {m with classification=Estimate})) "Estimate compatible with derived footprint";
  require (not (W.Measurement.compatible m {m with classification=Observed})) "Observed/derived classification mismatch ignored";
  let root=Core_unix.mkdtemp "/tmp/workbench-resources-test-" in
  let t=S.create ~state_dir:root ~identity:"project-A" in
  let calls=ref 0 in
  let query _ = incr calls; return response in
  let%bind ()=S.load t ~target ~kind:"coarse_run" ~path:src.path ~provider_identity:"provider-binaries-A" ~check:ignore ~query in
  require (!calls=1 && S.cached t target) "Cold load failed";
  let snapshot=S.snapshot t in
  let src=List.hd_exn snapshot.sources and index=List.hd_exn snapshot.indexes in
  require (String.equal src.id index.source_id && W.Freshness.equal src.freshness Validated) "Published source mismatch";
  require (not (S.cached t (W.Target.Bundle "/retained/root"))) "Source-kind cache collision";
  let restored=S.create ~state_dir:root ~identity:"project-A" in
  require (W.Freshness.equal (List.hd_exn (S.snapshot restored).sources).freshness Cached_unverified) "Restart silently validated source";
  let legacy_root=Core_unix.mkdtemp "/tmp/workbench-resource-legacy-cache-" in
  let unknown (m : W.Measurement.t) = {m with classification=Unknown} in
  let legacy_index={index with W.Index.inventory_status=Unknown;inventory_reason=None;
    measurements=List.map index.measurements ~f:unknown;
    rows=List.map index.rows ~f:(fun r -> {r with measurements=List.map r.measurements ~f:unknown})} in
  let old_sources=[src] and old_indexes=[legacy_index] in
  let old_content=Sexp.to_string_mach [%sexp (old_sources : W.Source.t list), (old_indexes : W.Index.t list)] in
  require (not (String.is_substring old_content ~substring:"inventory_status")
    && not (String.is_substring old_content ~substring:"classification")) "Legacy default fields changed cache digest encoding";
  let stored=Sexp.List [ [%sexp "version",(1:int)];[%sexp "identity",("project-A":string)];
    [%sexp "sources",(old_sources:W.Source.t list)];[%sexp "indexes",(old_indexes:W.Index.t list)];
    [%sexp "digest",(P.digest old_content:string)] ] in
  Out_channel.write_all (Filename.concat legacy_root ("asic-resources-" ^ P.digest "project-A" ^ ".sexp")) ~data:(Sexp.to_string_mach stored);
  let legacy_cache=S.create ~state_dir:legacy_root ~identity:"project-A" in
  require (Option.is_none (S.cache_error legacy_cache) && List.length (S.snapshot legacy_cache).indexes=1) "Old missing-field cache/digest rejected";
  require (W.Inventory_status.equal (List.hd_exn (S.snapshot legacy_cache).indexes).inventory_status Unknown
    && W.Freshness.equal (List.hd_exn (S.snapshot legacy_cache).sources).freshness Cached_unverified)
    "Legacy cache restored as available or validated";
  let empty_legacy={legacy_index with W.Index.rows=[]} in
  let old_indexes=[empty_legacy] in
  let old_content=Sexp.to_string_mach [%sexp (old_sources : W.Source.t list), (old_indexes : W.Index.t list)] in
  let cache_file=Filename.concat legacy_root ("asic-resources-" ^ P.digest "project-A" ^ ".sexp") in
  let cache_bytes indexes =
    let content=Sexp.to_string_mach [%sexp (old_sources : W.Source.t list), (indexes : W.Index.t list)] in
    Sexp.to_string_mach (Sexp.List [ [%sexp "version",(1:int)];[%sexp "identity",("project-A":string)];
      [%sexp "sources",(old_sources:W.Source.t list)];[%sexp "indexes",(indexes:W.Index.t list)];
      [%sexp "digest",(P.digest content:string)] ]) in
  ignore old_content;
  Out_channel.write_all cache_file ~data:(cache_bytes old_indexes);
  let empty_cache=S.create ~state_dir:legacy_root ~identity:"project-A" in
  require (Option.is_none (S.cache_error empty_cache)
    && W.Inventory_status.equal (List.hd_exn (S.snapshot empty_cache).indexes).inventory_status Unknown)
    "Old empty cache became available-zero";
  Out_channel.write_all cache_file ~data:(cache_bytes [empty_legacy;legacy_index]);
  let duplicates=S.create ~state_dir:legacy_root ~identity:"project-A" in
  require (Option.is_some (S.cache_error duplicates) && List.is_empty (S.snapshot duplicates).indexes)
    "Coherently rebound duplicate source indexes accepted";
  let legacy_live=S.create ~state_dir:legacy_root ~identity:"legacy-live" in
  let%bind ()=S.load legacy_live ~target ~kind:src.kind ~path:src.path ~provider_identity:"legacy-provider" ~check:ignore
    ~query:(fun _ -> return legacy_response) in
  require (W.Freshness.equal (List.hd_exn (S.snapshot legacy_live).sources).freshness Cached_unverified)
    "Older missing-field provider response became validated available";
  require (List.is_empty (S.snapshot (S.create ~state_dir:root ~identity:"project-B")).indexes) "Project cache collision";
  S.fail t target "refresh failed";
  require (List.length (S.snapshot t).indexes=1 && W.Freshness.equal (List.hd_exn (S.snapshot t).sources).freshness (Refresh_failed "refresh failed")) "Refresh failure erased or validated old evidence";
  let operation=W.Operation.Detail {source_id=src.id;expected_digest=digest;resource_id="program";section="timing";offset=0;limit=16} in
  let page_response=obj (common "detail" @ ["resource_id",str "program";"section",str "timing";
    "offset",`Int 0;"next_offset",`Int 1;"total",`Int 186;
    "items",`List [obj ["id",str "path-1";"title",str "slow setup";"fields",`List [`List [str "slack";str "11.246561 ns"]]]]]) in
  let page_calls=ref 0 in
  let page_query _=incr page_calls; return page_response in
  let%bind ()=S.page t operation ~check:ignore ~query:page_query in
  let%bind ()=S.page t operation ~check:ignore ~query:page_query in
  require (!page_calls=1 && List.length (S.snapshot t).details=1) "Detail LRU did not reuse exact source page";
  let bad_operation=W.Operation.Detail {source_id=src.id;expected_digest=String.make 64 'b';resource_id="program";section="timing";offset=0;limit=16} in
  let%bind rejected=Monitor.try_with (fun () -> S.page t bad_operation ~check:ignore ~query:page_query) in
  require (Result.is_error rejected && !page_calls=1) "Stale detail issued provider read";
  let operation=W.Operation.Artifacts {source_id=src.id;expected_digest=digest;offset=64;limit=32} in
  let artifact_id=String.make 64 'c' in
  let artifact=obj ["id",str artifact_id;"label",str "retained-report";"sha256",str digest;"format",str "text"] in
  let catalog=obj (common "artifacts" @ ["offset",`Int 64;"next_offset",`Int 76;"total",`Int 76;
    "entries",`List (List.init 12 ~f:(fun i -> replace artifact "id" (str (P.digest (Int.to_string i)))) )]) in
  let%bind ()=S.page t operation ~check:ignore ~query:(fun _ -> return catalog) in
  require ((List.hd_exn (S.snapshot t).artifacts).next_offset=76) "Artifact tail not reachable";
  let%bind rejected=Monitor.try_with (fun () -> S.page t operation ~check:ignore ~query:(fun _ -> return (replace catalog "next_offset" (`Int 75)))) in
  require (Result.is_error rejected) "Invalid page progress accepted";
  let read=W.Operation.Read_artifact {source_id=src.id;expected_digest=digest;artifact_id=P.digest "0";offset=0;limit=16} in
  let bytes=obj (common "bytes" @ ["artifact_id",str (P.digest "0");"sha256",str digest;
    "offset",`Int 0;"next_offset",`Int 2;"total",`Int 100;"bytes_hex",str "0aff"]) in
  let%bind ()=S.page t read ~check:ignore ~query:(fun _ -> return bytes) in
  require (String.equal (List.hd_exn (S.snapshot t).bytes).bytes_hex "0aff") "Authorized artifact bytes lost";
  let%bind rejected=Monitor.try_with (fun () -> S.page t read ~check:ignore ~query:(fun _ -> return (replace bytes "sha256" (str (String.make 64 'f'))))) in
  require (Result.is_error rejected) "Artifact source hash not fenced";
  let unknown=W.Operation.Read_artifact {source_id=src.id;expected_digest=digest;artifact_id=String.make 64 'f';offset=0;limit=16} in
  let invalid_calls=ref 0 in
  let%bind rejected=Monitor.try_with (fun () -> S.page t unknown ~check:ignore ~query:(fun _ -> incr invalid_calls; return bytes)) in
  require (Result.is_error rejected && !invalid_calls=0) "Unknown artifact capability accepted";
  let too_big=W.Operation.Read_artifact {source_id=src.id;expected_digest=digest;artifact_id=P.digest "0";offset=0;limit=16385} in
  let%bind rejected=Monitor.try_with (fun () -> S.page t too_big ~check:ignore ~query:(fun _ -> incr invalid_calls; return bytes)) in
  require (Result.is_error rejected && !invalid_calls=0) "Oversized artifact request accepted";
  let lru_calls=ref 0 in
  let%bind ()=Deferred.List.iter ~how:`Sequential (List.init 70 ~f:Fn.id) ~f:(fun offset ->
    let operation=W.Operation.Detail {source_id=src.id;expected_digest=digest;resource_id="program";section="timing";offset;limit=1} in
    S.page t operation ~check:ignore ~query:(fun _ -> incr lru_calls;
      return (replace (replace page_response "offset" (`Int offset)) "next_offset" (`Int (offset+1))))) in
  require (List.length (S.snapshot t).details<=8 && !lru_calls=70) "Published detail pages unbounded";
  let%bind ()=S.page t (W.Operation.Detail {source_id=src.id;expected_digest=digest;resource_id="program";section="timing";offset=0;limit=1})
    ~check:ignore ~query:(fun _ -> incr lru_calls; return page_response) in
  require (!lru_calls=71) "Detail cache exceeded its 64-entry capacity";
  let%bind rejected=Monitor.try_with (fun () -> S.load t ~target ~kind:src.kind ~path:src.path ~provider_identity:"B"
    ~check:(fun () -> failwith "context changed") ~query) in
  require (Result.is_error rejected && String.equal (List.hd_exn (S.snapshot t).sources).provider_identity "provider-binaries-A") "Late source response replaced original provider identity";
  let projection=replace response "measurements" (`List [replace measurement "classification" (str "estimate")]) in
  let%bind ()=S.load t ~target ~kind:src.kind ~path:src.path ~provider_identity:"provider-binaries-B"
    ~check:ignore ~query:(fun _ -> return projection) in
  let changed=S.snapshot t in
  let changed_index=List.hd_exn changed.indexes in
  require (String.equal index.digest changed_index.digest && not (W.Index.equal index changed_index)
    && String.equal (List.hd_exn changed.sources).provider_identity "provider-binaries-B")
    "Same evidence digest collapsed a different provider projection";
  require (List.is_empty changed.details && List.is_empty changed.artifacts && List.is_empty changed.bytes)
    "Changed projection retained old detail/artifact publications";
  let after_upgrade_calls=ref 0 in
  let%bind ()=S.page t (W.Operation.Detail {source_id=src.id;expected_digest=digest;resource_id="program";section="timing";offset=0;limit=1})
    ~check:ignore ~query:(fun _ -> incr after_upgrade_calls; return page_response) in
  require (!after_upgrade_calls=1) "Changed provider/projection reused old detail LRU";
  let filename=Filename.concat root ("asic-resources-" ^ P.digest "project-A" ^ ".sexp") in
  let saved=In_channel.read_all filename in
  let corrupt=String.substr_replace_first saved ~pattern:"program" ~with_:"changed" in
  Out_channel.write_all filename ~data:corrupt;
  let corrupt=S.create ~state_dir:root ~identity:"project-A" in
  require (Option.is_some (S.cache_error corrupt) && List.is_empty (S.snapshot corrupt).indexes) "Corrupt cache accepted";
  let%bind failed_repair=Monitor.try_with (fun () -> S.load corrupt ~target ~kind:src.kind ~path:src.path
    ~provider_identity:"repaired-provider" ~check:ignore ~query:(fun _ -> failwith "source unavailable")) in
  require (Result.is_error failed_repair && Option.is_some (S.cache_error corrupt)) "Failed read cleared active corruption diagnostic";
  let%bind failed_repair=Monitor.try_with (fun () -> S.load corrupt ~target ~kind:src.kind ~path:src.path
    ~provider_identity:"repaired-provider" ~check:ignore ~query:(fun _ -> return (replace response "contract" (str "invalid")))) in
  require (Result.is_error failed_repair && Option.is_some (S.cache_error corrupt)) "Rejected payload cleared active corruption diagnostic";
  Core_unix.unlink filename;
  Core_unix.mkdir filename;
  let%bind failed_repair=Monitor.try_with (fun () -> S.load corrupt ~target ~kind:src.kind ~path:src.path
    ~provider_identity:"repaired-provider" ~check:ignore ~query) in
  require (Result.is_error failed_repair && Option.is_some (S.cache_error corrupt)) "Failed atomic save cleared active corruption diagnostic";
  Core_unix.rmdir filename;
  let%bind ()=S.load corrupt ~target ~kind:src.kind ~path:src.path ~provider_identity:"repaired-provider" ~check:ignore ~query in
  require (Option.is_none (S.cache_error corrupt) && List.length (S.snapshot corrupt).indexes=1)
    "Successful explicit cache repair retained active corruption diagnostic";
  let repaired=S.create ~state_dir:root ~identity:"project-A" in
  require (Option.is_none (S.cache_error repaired) && List.length (S.snapshot repaired).indexes=1)
    "Repaired cache did not reopen cleanly";
  List.iter ["index";"detail";"artifacts";"bytes"] ~f:(fun query_name ->
    List.iter [0,"pass";0,"not_evaluated";1,"fail"] ~f:(fun (exit_code,verdict) ->
      let j=obj (common query_name) |> fun j -> replace j "verdict" (str verdict) in
      let parsed=S.parse_process_result {stdout=Yojson.Safe.to_string j;exit_code} in
      require (String.equal (P.text (P.field "verdict" parsed)) verdict) "Consistent resource process result rejected");
    List.iter [1,"pass";1,"not_evaluated";0,"fail";2,"fail";0,"unknown"] ~f:(fun (exit_code,verdict) ->
      rejects (fun () -> S.parse_process_result {stdout=Yojson.Safe.to_string (replace (obj (common query_name)) "verdict" (str verdict));exit_code})));
  let invocation : Hardcaml_workbench_adapters.Dune_adapter.Invocation.t =
    {executable="/bin/sh";argv=["/bin/sh";"-c";"printf '{\"verdict\":\"fail\"}'; exit 1"];cwd=root;environment=V1.Environment_selection.Inherit_daemon} in
  let run accept=Hardcaml_workbench_backend.Asic_process.run ~accept_evidence_failure:accept ~seconds:5.
    ~cancel:(Deferred.never ()) ~on_process:ignore ~on_line:(fun _ -> Deferred.unit) invocation in
  let%bind output=run true in
  require (String.equal output "{\"verdict\":\"fail\"}") "CLI1 usable JSON lost";
  let%bind with_status=Hardcaml_workbench_backend.Asic_process.run_with_status ~accept_evidence_failure:true ~seconds:5.
    ~cancel:(Deferred.never ()) ~on_process:ignore ~on_line:(fun _ -> Deferred.unit) invocation in
  require (with_status.exit_code=1 && String.equal with_status.stdout output) "Resource process erased accepted exit1 status";
  let%bind rejected=Monitor.try_with (fun () -> run false) in
  require (Result.is_error rejected) "Generic nonzero commands silently accepted";
  let noisy={invocation with argv=["/bin/sh";"-c";"printf '%05000d' 0"]} in
  let budget ~max_stdout_bytes ~max_record_bytes=Hardcaml_workbench_backend.Asic_process.run
    ~max_stdout_bytes ~max_record_bytes ~seconds:5. ~cancel:(Deferred.never ())
    ~on_process:ignore ~on_line:(fun _ -> Deferred.unit) noisy in
  let%bind rejected=Monitor.try_with (fun () -> budget ~max_stdout_bytes:4096 ~max_record_bytes:8192) in
  require (Result.is_error rejected) "Provider stdout was not bounded during drain";
  let%bind rejected=Monitor.try_with (fun () -> budget ~max_stdout_bytes:8192 ~max_record_bytes:1024) in
  require (Result.is_error rejected) "Provider record was not bounded during drain";
  let%bind ()=integration () in
  let%bind ()=real_provider () in
  printf "resource backend: %d checks passed\n%!" !checks;
  Deferred.unit
;;
let () =
  don't_wait_for (Monitor.try_with main >>= function Ok () -> Shutdown.exit 0 | Error e -> eprintf "%s\n%!" (Exn.to_string e); Shutdown.exit 1);
  never_returns (Scheduler.go ())
