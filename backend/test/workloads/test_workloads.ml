open! Core
open! Async
open Hardcaml_workbench_protocol
module W = Asic_workloads
module S = Hardcaml_workbench_backend.Asic_workloads_service
module Service = Hardcaml_workbench_backend.Asic_service
let checks = ref 0
let check b message = incr checks; if not b then failwith message
let rejects f = check (Result.is_error (Or_error.try_with f)) "Expected rejection"
let str s = `String s
let obj xs = `Assoc xs
let d = String.make 64 'a'
let e = String.make 64 'b'
let replace j k v = match j with
  | `Assoc xs -> obj ((k,v)::List.Assoc.remove xs k ~equal:String.equal)
  | _ -> assert false
let metric = obj ["metric_id",str "workload/throughput";"name",str "throughput";
  "quantity",str "real";"classification",str "derived";"unit",str "operation/cycle";
  "stage",str "functional_simulation";"definition",str "memory-1rw-window-v1.throughput";
  "value",`Float 0.5;"numerator",`Intlit "9007199254740993";"denominator",`Intlit "18014398509481986"]
let inspection = obj ["contract",str "hardcaml-asic.workload-inspection";"schema_version",`Int 1;
  "source_digest",str d;"binding",obj ["bundle_identity",str d;"hardware_variant_identity",str d;
    "workload_identity",str d;"simulation_sha256",str d;"simulation_attempt_id",str "sim-test"];
  "controls",obj [];"provenance",obj [];
  "outcome",obj ["status",str "completed";"functional",str "fail";"performance",str "unavailable"];
  "metrics",`List [replace metric "value" `Null]]
let inspect ?expected_digest result = W.Query.Inspect {result;expected_digest}
let compare ?left_workload ?right_workload ?expected_left_digest ?expected_right_digest
    ?expected_left_workload_digest ?expected_right_workload_digest left right =
  W.Query.Compare {left;right;axis=Resource_policy;left_workload;right_workload;
    expected_left_digest;expected_right_digest;expected_left_workload_digest;expected_right_workload_digest}
let comparison left right =
  let side p = obj ["kind",str "bundle";"target",str p;"source_digest",str d;
    "identities",obj [];"outcomes",obj [];"workload",inspection] in
  obj ["contract",str "hardcaml-asic.variant-comparison";"schema_version",`Int 1;
    "comparison_digest",str e;"policy",str "bounded-pair-v1";"axis",str "resource_policy";
    "left",side left;"right",side right;"differences",`List [];
    "metrics",`List [obj ["metric_id",str "workload/throughput";"left",metric;"right",metric;
      "comparison",str "comparable";"reasons",`List [];"right_minus_left",`Float 0.;
      "right_minus_left_ratio",obj ["numerator",`Intlit "0";"denominator",`Intlit "1"]]];
    "workload",obj [];"truncated",`Bool false]
let raw = Yojson.Safe.to_string
let bound_inspection result = replace inspection "provenance"
  (obj ["sources",`List [obj ["path",str result]]])
let pure () =
  let q=inspect "/result.json" in
  let r=S.validate_response q (raw inspection) in
  check (String.equal r.digest d && String.equal r.json (raw inspection)) "Inspection bytes changed";
  check (String.is_substring r.json ~substring:"9007199254740993") "Exact integer lost";
  check (String.equal (W.Operation.key (Load {query=q;refresh=false}))
    (W.Operation.key (Load {query=q;refresh=true}))) "Refresh changed operation key";
  rejects (fun () -> S.validate_response (inspect ~expected_digest:e "/result.json") (raw inspection));
  rejects (fun () -> S.validate_query (inspect "relative"));
  rejects (fun () -> S.validate_query (inspect ~expected_digest:"bad" "/result.json"));
  rejects (fun () -> S.validate_query (compare ~expected_left_workload_digest:d (Bundle "/l") (Bundle "/r")));
  rejects (fun () -> S.validate_response q (raw (replace inspection "schema_version" (`Int 2))));
  rejects (fun () -> S.validate_response q (raw (replace inspection "metrics" (`List (List.init 257 ~f:(fun _ -> metric))))));
  rejects (fun () -> S.validate_response q ("{\"contract\":0," ^ String.drop_prefix (raw inspection) 1));
  rejects (fun () -> S.validate_response q (raw (replace inspection "extra" `Null)));
  rejects (fun () -> S.validate_response q (raw (replace inspection "metrics" (`List [replace metric "value" (`Float Float.nan)]))));
  rejects (fun () -> S.validate_response q (String.make (1024*1024+1) ' '));
  let historical=replace metric "quantity" (str "integer") |> fun m -> replace m "value" (`Float 2.)
    |> fun m -> replace m "unit" `Null in
  ignore (S.validate_response q (raw (replace inspection "metrics" (`List [historical]))) : W.Response.t);
  check true "Nullable historical metric descriptions retained";
  rejects (fun () -> S.validate_response q (raw (replace inspection "metrics"
    (`List [replace historical "value" (`Float 2.5)]))));
  rejects (fun () -> S.validate_response q (raw (replace inspection "metrics" (`List [metric;metric]))));
  let deep=List.fold (List.init 65 ~f:Fn.id) ~init:`Null ~f:(fun j _ -> `List [j]) in
  rejects (fun () -> S.validate_response q (raw (replace inspection "provenance" (obj ["deep",deep]))));
  S.check_targets q ~paths:["/result.json"]
    (raw (replace inspection "provenance" (obj ["sources",`List [obj ["path",str "/result.json"]]])));
  rejects (fun () -> S.check_targets q ~paths:["/different.json"]
    (raw (replace inspection "provenance" (obj ["sources",`List [obj ["path",str "/result.json"]]]))));
  let q=compare ~left_workload:"/lw" ~right_workload:"/rw"
    ~expected_left_digest:d ~expected_right_digest:d
    ~expected_left_workload_digest:d ~expected_right_workload_digest:d (Bundle "/l") (Bundle "/r") in
  let j=comparison "/l" "/r" in
  let r=S.validate_response q (raw j) in
  check (String.equal r.digest e && String.equal r.json (raw j)) "Comparison rational JSON changed";
  rejects (fun () -> S.validate_response q (raw (replace j "axis" (str "hardware"))));
  rejects (fun () -> S.validate_response q (raw (replace j "truncated" (`Bool true))));
  let bad=replace j "left" (replace (Hardcaml_workbench_backend.Asic_public.field "left" j) "source_digest" (str e)) in
  rejects (fun () -> S.validate_response q (raw bad));
  let bad=replace j "right" (replace (Hardcaml_workbench_backend.Asic_public.field "right" j) "workload" (replace inspection "source_digest" (str e))) in
  rejects (fun () -> S.validate_response q (raw bad));
  let wrong=compare (Bundle "/l") (Bundle "/r") in
  rejects (fun () -> S.validate_response wrong (raw j));
  rejects (fun () -> S.check_targets wrong ~paths:["/other";"/r"] (raw j));
  let row=List.hd_exn (Hardcaml_workbench_backend.Asic_public.list
    (Hardcaml_workbench_backend.Asic_public.field "metrics" j)) in
  rejects (fun () -> S.validate_response q (raw (replace j "metrics"
    (`List [replace row "right_minus_left_ratio" (obj ["numerator",`Int 0;"denominator",`Int 0])]))));
  rejects (fun () -> S.validate_response q (raw (replace j "metrics"
    (`List [replace row "comparison" (str "confounded")]))));
  let swapped=compare ~left_workload:"/rw" ~right_workload:"/lw" (Bundle "/r") (Bundle "/l") in
  check (not (String.equal (W.Operation.key (Load {query=q;refresh=false}))
    (W.Operation.key (Load {query=swapped;refresh=false})))) "Pair order not keyed"
;;
let cache () =
  let root=Core_unix.mkdtemp "/tmp/workbench-workload-cache-" in
  let state=Filename.concat root "state" in
  let cache=S.create ~state_dir:state ~identity:"test" in
  let result=Filename.concat root "retained/result.json" in
  let q=inspect result and q2=inspect (Filename.concat root "retained/other.json") in
  let publish cache query = match query with
    | W.Query.Inspect q -> S.publish cache query ~provider_identity:d (raw (bound_inspection q.result))
    | Compare _ -> assert false in
  S.select cache q;
  let%bind ()=publish cache q in
  S.select cache q2;
  let%bind ()=publish cache q in
  check (Option.is_none (S.snapshot cache).selected) "Old completion stole selection";
  S.select cache q;
  S.fail cache q "source changed";
  let snap=S.snapshot cache in
  check (Option.is_some snap.selected && match (List.hd_exn snap.entries).freshness with Refresh_failed _ -> true | _ -> false)
    "Failure lost payload or freshness";
  let restarted=S.create ~state_dir:state ~identity:"test" in
  check (S.cached restarted q && W.Freshness.equal (List.hd_exn (S.snapshot restarted).entries).freshness Cached_unverified)
    "Restart lost derived cache or asserted validation";
  let%bind ()=Deferred.List.iter (List.init 10 ~f:(fun n -> inspect (Filename.concat root ("retained/result-" ^ Int.to_string n))))
    ~how:`Sequential ~f:(publish cache) in
  check (List.length (S.snapshot cache).entries=8 && not (S.cached cache q)) "Cache LRU entry bound failed";
  let restarted=S.create ~state_dir:state ~identity:"test" in
  check (List.length (S.snapshot restarted).entries=8) "Bounded cache did not persist";
  let files=Sys_unix.ls_dir state in
  let file=Filename.concat state (List.find_exn files ~f:(fun n -> String.is_suffix n ~suffix:".sexp")) in
  Out_channel.write_all file ~data:"corrupt";
  let corrupt=S.create ~state_dir:state ~identity:"test" in
  check (Option.is_some (S.snapshot corrupt).cache_error && List.is_empty (S.snapshot corrupt).entries) "Corrupt cache was trusted";
  S.select corrupt q;
  let%map ()=publish corrupt q in
  check (Option.is_none (S.snapshot corrupt).cache_error) "Successful cache replacement did not repair error"
;;
let integration () =
  let module C=Hardcaml_workbench_project_integration.Asic_config in
  let root=Core_unix.mkdtemp "/tmp/workbench-workload-service-" |> Filename_unix.realpath in
  let file=Filename.concat root in
  let script=In_channel.read_all "provider.py" in
  let executable=file "provider" in
  Out_channel.write_all executable ~data:script; Core_unix.chmod executable ~perm:0o700;
  List.iter ["workload-inspect";"compare"] ~f:(fun helper ->
    Out_channel.write_all (file ("hardcaml-asic-experimental-"^helper)) ~data:"reader");
  let state_dir=file "state" and retained=file "retained" in
  Core_unix.mkdir_p retained;
  let config : C.t = {schema_version=1;project_executable=executable;provider_executable=executable;
    results_root=file "results";toolchain=file "tools";python=None;support_tools=None;pdk_root=None;stage_timeout_seconds=None} in
  Out_channel.write_all (file C.filename) ~data:(Sexp.to_string_mach (C.sexp_of_t config));
  Out_channel.write_all (file "response.json") ~data:(raw inspection);
  let service=Service.create ~state_dir in
  let handle service op=Service.handle service ~root ~environment:V1.Environment_selection.Inherit_daemon op
    >>| function Ok s -> s | Error e -> failwith e.V1.Error.message in
  let q=inspect (Filename.concat retained "result.json") in
  let op refresh=W.Operation.Load {query=q;refresh} in
  let calls ()=if Poly.equal (Sys_unix.file_exists (file "calls")) `Yes then In_channel.read_lines (file "calls") else [] in
  let reads ()=List.count (calls ()) ~f:(fun line -> not (String.is_substring line ~substring:"--version")) in
  let wait service operation =
    let%bind ()=Service.completion service in
    let%map s=handle service Get in
    let k=W.Operation.key operation in
    check (List.exists s.operations ~f:(fun p -> String.equal p.Asic.Pending.key k
      && List.mem ["completed";"failed"] p.state ~equal:String.equal)) "Operation did not finish";
    Option.value_exn s.workloads in
  let%bind _=handle service Get in check (List.is_empty (calls ())) "Get contacted provider";
  Out_channel.write_all (file "hold") ~data:"hold";
  let%bind _=handle service (Workloads (op false)) in
  let%bind _=handle service (Workloads (op true)) in
  Core_unix.unlink (file "hold");
  let%bind s=wait service (op false) in
  check (reads ()=1 && Option.is_some s.selected && List.length s.entries=1) "Load/refresh failed to coalesce";
  let original=(List.hd_exn s.entries).provider_identity in
  let%bind _=handle service (Workloads (op false)) in
  let%bind _=wait service (op false) in check (reads ()=1) "Warm load called provider";
  let left=file "left-bundle" and right=file "right-bundle" in
  Core_unix.mkdir_p left; Core_unix.mkdir_p right;
  let pair=compare ~left_workload:(Filename.concat retained "left.json")
    ~right_workload:(Filename.concat retained "right.json")
    ~expected_left_digest:d ~expected_right_digest:d
    ~expected_left_workload_digest:d ~expected_right_workload_digest:d (Bundle left) (Bundle right) in
  let pair_op refresh=W.Operation.Load {query=pair;refresh} in
  let j=comparison left right in
  Out_channel.write_all (file "response.json") ~data:(raw j);
  let%bind _=handle service (Workloads (pair_op false)) in
  let%bind s=wait service (pair_op false) in
  check (Option.exists s.selected ~f:(fun r -> String.equal r.W.Response.digest e)
    && Option.is_none (List.hd_exn s.entries).error) "Public comparison invocation failed";
  let changed=replace j "left"
    (replace (Hardcaml_workbench_backend.Asic_public.field "left" j) "source_digest" (str e)) in
  Out_channel.write_all (file "response.json") ~data:(raw changed);
  let%bind _=handle service (Workloads (pair_op true)) in
  let%bind s=wait service (pair_op true) in
  check (Option.exists s.selected ~f:(fun r -> String.equal r.W.Response.digest e)
    && Option.exists (List.hd_exn s.entries).error ~f:(fun e -> String.is_substring e ~substring:"digest changed"))
    "Captured pair silently refreshed changed target evidence";
  Out_channel.write_all (file "response.json") ~data:(raw inspection);
  let%bind _=handle service (Workloads (op false)) in
  let%bind _=wait service (op false) in
  let refresh ()=let%bind _=handle service (Workloads (op true)) in wait service (op true) in
  Out_channel.write_all (file "fail") ~data:"fail";
  let%bind s=refresh () in
  check (Option.is_some s.selected && Option.is_some (List.hd_exn s.entries).error) "Refresh failure lost evidence";
  Core_unix.unlink (file "fail");
  Out_channel.write_all (file "mutate-helper") ~data:"mutate";
  let%bind s=refresh () in
  check (Option.exists (List.hd_exn s.entries).error ~f:(fun e -> String.is_substring e ~substring:"provider changed")) "Helper mutation not fenced";
  Core_unix.unlink (file "mutate-helper");
  let%bind s=refresh () in
  check (Option.is_none (List.hd_exn s.entries).error
    && not (Option.equal String.equal original (List.hd_exn s.entries).provider_identity)) "Changed helper generation not captured";
  Out_channel.write_all (file "mutate-launcher") ~data:"mutate";
  let%bind s=refresh () in
  check (Option.exists (List.hd_exn s.entries).error ~f:(fun e -> String.is_substring e ~substring:"provider changed")) "Launcher mutation not fenced";
  Core_unix.unlink (file "mutate-launcher");
  Out_channel.write_all (file "oversize") ~data:"oversize";
  let%bind s=refresh () in
  check (Option.exists (List.hd_exn s.entries).error ~f:(fun e -> String.is_substring e ~substring:"budget" || String.is_substring e ~substring:"too large")) "Output drain budget not enforced";
  Core_unix.unlink (file "oversize");
  Out_channel.write_all (file "unsupported") ~data:"unsupported";
  let n=reads () in
  let%bind s=refresh () in
  check (reads ()=n && Option.exists (List.hd_exn s.entries).error ~f:(fun e -> String.is_substring e ~substring:"workload_inspection1")) "Unsupported capability executed reader";
  Core_unix.unlink (file "unsupported");
  let%bind _=refresh () in
  let%bind ()=Service.shutdown service in
  let restarted=Service.create ~state_dir in
  let n=List.length (calls ()) in
  let%bind s=handle restarted Get in
  let s=Option.value_exn s.workloads in
  check (List.length (calls ())=n && Option.is_none s.selected
    && W.Freshness.equal (List.hd_exn s.entries).freshness Cached_unverified) "Restart queried provider or claimed validation";
  let%bind _=handle restarted (Workloads (op false)) in
  let%bind s=wait restarted (op false) in
  check (List.length (calls ())=n && Option.is_some s.selected) "Restart cache-only reopen failed";
  let overlap=W.Operation.Load {query=inspect (file "result.json");refresh=true} in
  let%bind _=handle restarted (Workloads overlap) in
  let%bind s=wait restarted overlap in
  check (List.exists s.entries ~f:(fun d -> Option.exists d.W.Descriptor.error ~f:(fun e -> String.is_substring e ~substring:"outside selected evidence"))) "Cache/evidence overlap accepted";
  Service.shutdown restarted
;;
let retained_payloads () =
  Option.iter (Sys.getenv "PT8_WORKLOAD_INSPECTION_JSON") ~f:(fun filename ->
    let bytes=In_channel.read_all filename in
    let response=S.validate_response (inspect "/explicit/retained-result.json") bytes in
    check (String.equal response.json bytes) "Actual retained inspection bytes changed");
  Option.iter (Sys.getenv "PT8_WORKLOAD_COMPARISON_JSON") ~f:(fun filename ->
    let bytes=In_channel.read_all filename in
    let j=Yojson.Safe.from_string bytes in
    let module P=Hardcaml_workbench_backend.Asic_public in
    let side name =
      let s=P.field name j in
      let p=P.text (P.field "target" s) in
      let target=match P.text (P.field "kind" s) with
        | "bundle" -> W.Target.Bundle p | "coarse_run" -> Coarse_run p
        | "execution" -> Execution p | _ -> failwith "Unknown retained target kind" in
      let workload=if Poly.equal (P.field "workload" s) `Null then None else Some "/explicit/workload.json" in
      target,workload in
    let left,left_workload=side "left" and right,right_workload=side "right" in
    let axis=match P.text (P.field "axis" j) with
      | "hardware" -> W.Axis.Hardware | "resource_policy" -> Resource_policy
      | "flow_configuration" -> Flow_configuration | "descriptive" -> Descriptive
      | _ -> failwith "Unknown retained axis" in
    let query=W.Query.Compare {left;right;axis;left_workload;right_workload;
      expected_left_digest=None;expected_right_digest=None;
      expected_left_workload_digest=None;expected_right_workload_digest=None} in
    let response=S.validate_response query bytes in
    check (String.equal response.json bytes) "Actual retained comparison bytes changed")
;;
let main () =
  pure ();
  retained_payloads ();
  let%bind ()=cache () in
  let%map ()=integration () in
  printf "PT8 workload backend: %d checks passed\n%!" !checks
let () =
  don't_wait_for (Monitor.try_with main >>= function
    | Ok () -> Shutdown.exit 0
    | Error exn -> eprintf "%s\n%!" (Exn.to_string exn); Shutdown.exit 1);
  never_returns (Scheduler.go ())
