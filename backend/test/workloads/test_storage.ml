open! Core
open! Async
open Hardcaml_workbench_protocol
module S = Hardcaml_workbench_backend.Asic_workloads_service
module Storage = Hardcaml_workbench_backend.Asic_workloads_storage
module Service = Hardcaml_workbench_backend.Asic_service
module W = Asic_workloads
let checks=ref 0
let check b message = incr checks; if not b then failwith message
let d=String.make 64 'a'
let e=String.make 64 'b'
let query result=W.Query.Inspect {result;expected_digest=None}
let key q=W.Operation.key (Load {query=q;refresh=false})
let raw result = sprintf
  {|{"contract":"hardcaml-asic.workload-inspection","schema_version":1,"source_digest":"%s","binding":{"bundle_identity":"%s","hardware_variant_identity":"%s","workload_identity":"%s","simulation_sha256":"%s","simulation_attempt_id":"sim"},"controls":{},"provenance":{"sources":[{"path":%s}]},"outcome":{"status":"completed","functional":"pass","performance":"available"},"metrics":[]}|}
  d d d d d (Yojson.Safe.to_string (`String result))
let temporary ()=Core_unix.mkdtemp "/tmp/opencode/pt8-storage-fix-" |> Filename_unix.realpath
let mkdir p=Core_unix.mkdir_p p ~perm:0o700
let symlink src dst=Core_unix.symlink ~target:src ~link_name:dst
let set_link link target=Core_unix.unlink link;symlink target link
let exists p=Poly.equal (Sys_unix.file_exists p) `Yes
let rejects f=check (Result.is_error (Or_error.try_with f)) "Expected storage rejection"

let descriptor_races () =
  List.iter [2;3] ~f:(fun barrier ->
    let root=temporary () in
    let outside=Filename.concat root "outside" and evidence=Filename.concat root "evidence" in
    mkdir outside;mkdir evidence;
    let alias=Filename.concat root "state" in symlink outside alias;
    let storage=Storage.create alias in
    let calls=ref 0 in
    rejects (fun () -> Storage.write storage ~name:"cache.sexp" ~data:"new"
      ~before_write:(fun () -> incr calls; if !calls=barrier then set_link alias evidence));
    check (!calls=barrier) "Deterministic descriptor barrier was not reached";
    check (List.is_empty (Sys_unix.ls_dir evidence)) "Cache alias retarget wrote into evidence";
    check (List.is_empty (Sys_unix.ls_dir outside)) "Failed descriptor publication left a temporary file");
  let root=temporary () in
  let ancestor=Filename.concat root "ancestor" and evidence=Filename.concat root "evidence" in
  mkdir ancestor;mkdir evidence;
  let state=Filename.concat ancestor "state" in mkdir state;
  let storage=Storage.create state in
  let calls=ref 0 in
  rejects (fun () -> Storage.write storage ~name:"cache.sexp" ~data:"new"
    ~before_write:(fun () -> incr calls; if !calls=2 then (
      Core_unix.rename ~src:ancestor ~dst:(Filename.concat root "old-ancestor");
      symlink evidence ancestor)));
  check (List.is_empty (Sys_unix.ls_dir evidence)) "Canonical ancestor retarget wrote into evidence";
  check (List.is_empty (Sys_unix.ls_dir (Filename.concat root "old-ancestor/state")))
    "Canonical ancestor failure left temporary files"
;;
let rewrite_cache ?old_key ?new_key file original wrong =
  let old_key=Option.value old_key ~default:(key (query original))
  and new_key=Option.value new_key ~default:(key (query wrong)) in
  let fields=match Sexp.of_string (In_channel.read_all file) with Sexp.List xs -> xs | _ -> assert false in
  let items=List.find_map_exn fields ~f:(function Sexp.List [Atom "items";v] -> Some v | _ -> None) in
  let rec rewrite = function
    | Sexp.Atom s when String.equal s original -> Sexp.Atom wrong
    | Atom s when String.equal s old_key -> Atom new_key
    | List xs -> List (List.map xs ~f:rewrite) | s -> s in
  let items=rewrite items in
  let checksum=Hardcaml_workbench_backend.Asic_public.digest (Sexp.to_string_mach items) in
  Sexp.List (List.map fields ~f:(function
    | Sexp.List [Atom "items";_] -> Sexp.List [Atom "items";items]
    | List [Atom "checksum";_] -> Sexp.List [Atom "checksum";Atom checksum] | x -> x))
  |> Sexp.to_string_mach |> fun data -> Out_channel.write_all file ~data
;;
let restore_binding () =
  let root=temporary () in
  let state=Filename.concat root "state" in
  let result=Filename.concat root "source/result.json" in
  let q=query result in
  let cache=S.create ~state_dir:state ~identity:"binding" in
  let%bind ()=S.publish cache q ~provider_identity:d (raw result) in
  let file=Filename.concat state (List.hd_exn (Sys_unix.ls_dir state)) in
  let original=In_channel.read_all file in
  let wrong=Filename.concat root "different/result.json" in
  rewrite_cache file result wrong;
  let restored=S.create ~state_dir:state ~identity:"binding" in S.select restored (query wrong);
  check (Option.is_some (S.snapshot restored).cache_error && Option.is_none (S.snapshot restored).selected)
    "Coherent query/key/checksum restore forgery was admitted";
  Out_channel.write_all file ~data:original;
  let restored=S.create ~state_dir:state ~identity:"binding" in S.select restored q;
  check (Option.is_none (S.snapshot restored).cache_error && Option.is_some (S.snapshot restored).selected)
    "Missing original source blocked cache-only restoration";
  let retained=Filename.concat root "retained" in mkdir retained;
  let alias=Filename.concat root "source-alias" in symlink retained alias;
  let selected=Filename.concat alias "result.json" and canonical=Filename.concat retained "result.json" in
  let q=query selected in
  let%bind ()=S.publish ~paths:[canonical] cache q ~provider_identity:d (raw canonical) in
  Core_unix.unlink alias;Core_unix.rmdir retained;
  let restored=S.create ~state_dir:state ~identity:"binding" in S.select restored q;
  check (Option.is_some (S.snapshot restored).selected && Option.is_none (S.snapshot restored).cache_error)
    "Historical alias binding depended on the current filesystem";
  check (List.for_all (S.snapshot restored).entries ~f:(fun d -> W.Freshness.equal d.W.Descriptor.freshness Cached_unverified))
    "Restoration claimed live validation";
  let bad=query (Filename.concat root "other/result.json") in
  let%bind result=Monitor.try_with (fun () -> S.publish cache bad ~provider_identity:d (raw canonical)) in
  check (Result.is_error result && not (S.cached cache bad)) "Direct publication skipped query/document binding";
  let inside=S.create ~state_dir:(Filename.concat root "source/cache") ~identity:"separation" in
  let%bind result=Monitor.try_with (fun () -> S.publish inside (query (Filename.concat root "source/result.json"))
    ~provider_identity:d (raw (Filename.concat root "source/result.json"))) in
  check (Result.is_error result && not (exists (Filename.concat root "source"))) "Publication separation created evidence directories";
  let nested_state=Filename.concat root "source/cache" in mkdir nested_state;
  Out_channel.write_all (Filename.concat nested_state (Filename.basename file)) ~data:original;
  let misplaced=S.create ~state_dir:nested_state ~identity:"binding" in
  check (Option.is_some (S.snapshot misplaced).cache_error && List.is_empty (S.snapshot misplaced).entries)
    "Cache restore skipped canonical cache/evidence separation";
  Deferred.unit
;;
let bundle_locator () =
  let q=query "/retained/result.json" in
  let j=Yojson.Safe.from_string (raw "/retained/result.json") in
  let with_bundle value=match j with `Assoc xs ->
    let binding=List.Assoc.find_exn xs "binding" ~equal:String.equal in
    let binding=match binding with `Assoc fields -> `Assoc (("bundle",value)::fields) | _ -> assert false in
    Yojson.Safe.to_string (`Assoc (("binding",binding)::List.Assoc.remove xs "binding" ~equal:String.equal)) | _ -> assert false in
  ignore (S.validate_response q (with_bundle (`String "/bundles/exact")) : W.Response.t);
  check true "Additive absolute bundle locator rejected";
  List.iter [`String "relative";`String "/bad\000path";`Null;`Int 1;`String ("/"^String.make 4096 'x')]
    ~f:(fun value -> rejects (fun () -> S.validate_response q (with_bundle value)));
  ignore (S.validate_response q (raw "/retained/result.json") : W.Response.t)
;;
let comparison_restore () =
  let root=temporary () in
  let state=Filename.concat root "cache" in
  let left=Filename.concat root "left" and right=Filename.concat root "right"
  and lw=Filename.concat root "lw/result.json" and rw=Filename.concat root "rw/result.json" in
  let q=W.Query.Compare {left=Bundle left;right=Bundle right;axis=Resource_policy;
    left_workload=Some lw;right_workload=Some rw;expected_left_digest=None;expected_right_digest=None;
    expected_left_workload_digest=Some d;expected_right_workload_digest=Some d} in
  let side path workload=`Assoc ["kind",`String "bundle";"target",`String path;"source_digest",`String d;
    "identities",`Assoc [];"outcomes",`Assoc [];"workload",Yojson.Safe.from_string (raw workload)] in
  let json=Yojson.Safe.to_string (`Assoc ["contract",`String "hardcaml-asic.variant-comparison";
    "schema_version",`Int 1;"comparison_digest",`String e;"policy",`String "bounded-pair-v1";
    "axis",`String "resource_policy";"left",side left lw;"right",side right rw;
    "metrics",`List [];"differences",`List [];"workload",`Assoc [];"truncated",`Bool false]) in
  let cache=S.create ~state_dir:state ~identity:"comparison" in
  let%map ()=S.publish cache q ~provider_identity:d json in
  let file=Filename.concat state (List.hd_exn (Sys_unix.ls_dir state)) in
  let original=In_channel.read_all file in
  List.iter [right,Filename.concat root "wrong-right",false;rw,Filename.concat root "wrong-rw/result.json",true]
    ~f:(fun (old_path,new_path,workload) ->
      Out_channel.write_all file ~data:original;
      let wrong=match q with W.Query.Compare q ->
        if workload then W.Query.Compare {q with right_workload=Some new_path}
        else W.Query.Compare {q with right=Bundle new_path}
        | Inspect _ -> assert false in
      rewrite_cache ~old_key:(key q) ~new_key:(key wrong) file old_path new_path;
      let restored=S.create ~state_dir:state ~identity:"comparison" in
      S.select restored wrong;
      check (Option.is_some (S.snapshot restored).cache_error && Option.is_none (S.snapshot restored).selected)
        "Coherent comparison target/workload rebind restored another document")
;;
let service_race () =
  let module C=Hardcaml_workbench_project_integration.Asic_config in
  let root=temporary () in
  let project=Filename.concat root "project" and outside=Filename.concat root "outside" and retained=Filename.concat root "retained" in
  mkdir project;mkdir outside;mkdir retained;
  let alias=Filename.concat root "state-link" in symlink outside alias;
  let file=Filename.concat project in
  let executable=file "provider" in
  Out_channel.write_all executable ~data:(In_channel.read_all "provider.py");Core_unix.chmod executable ~perm:0o700;
  Out_channel.write_all (file "hardcaml-asic-experimental-workload-inspect") ~data:"helper";
  let config : C.t={schema_version=1;project_executable=executable;provider_executable=executable;
    results_root=Filename.concat root "results";toolchain=file "tools";python=None;support_tools=None;pdk_root=None;stage_timeout_seconds=None} in
  Out_channel.write_all (file C.filename) ~data:(Sexp.to_string_mach (C.sexp_of_t config));
  let result=Filename.concat retained "result.json" in
  Out_channel.write_all (file "response.json") ~data:(raw result);
  let service=Service.create ~state_dir:alias in
  let handle operation=Service.handle service ~root:project ~environment:V1.Environment_selection.Inherit_daemon operation
    >>| function Ok s -> Option.value_exn s.Asic.Snapshot.workloads | Error e -> failwith e.V1.Error.message in
  let load=Asic.Operation.Workloads (Load {query=query result;refresh=true}) in
  let%bind _=handle load in let%bind ()=Service.completion service in let%bind before=handle Get in
  let old=Option.value_exn before.selected in
  let files=List.map (Sys_unix.ls_dir outside) ~f:(fun n -> n,In_channel.read_all (Filename.concat outside n)) in
  Out_channel.write_all (file "hold") ~data:"hold";
  let changed=String.substr_replace_all (raw result) ~pattern:("\"source_digest\":\""^d) ~with_:("\"source_digest\":\""^e) in
  Out_channel.write_all (file "response.json") ~data:changed;
  let%bind _=handle load in
  let rec entered remaining =
    if exists (file "entered") then Deferred.unit
    else if remaining=0 then failwith "Provider barrier not reached"
    else let%bind ()=Clock.after (Time_float.Span.of_ms 5.) in entered (remaining-1) in
  let%bind ()=entered 1000 in
  set_link alias retained;
  Core_unix.unlink (file "hold");
  let%bind ()=Service.completion service in
  let%bind after=handle Get in
  check (List.is_empty (Sys_unix.ls_dir retained)) "Held-read cache alias retarget wrote evidence";
  check (List.for_all files ~f:(fun (n,bytes) -> String.equal bytes (In_channel.read_all (Filename.concat outside n))))
    "Rejected refresh replaced the prior persisted evidence";
  check (Option.exists after.selected ~f:(W.Response.equal old)) "Rejected async publication lost old payload";
  check (List.exists after.entries ~f:(fun d -> match d.W.Descriptor.freshness with Refresh_failed _ -> true | _ -> false))
    "Rejected async publication left a Validated descriptor";
  Service.shutdown service
;;
let main () =
  descriptor_races ();bundle_locator ();
  let%bind ()=restore_binding () in
  let%bind ()=comparison_restore () in
  let%map ()=service_race () in
  printf "PT8 storage corrections: %d checks passed\n%!" !checks
let () =
  don't_wait_for (Monitor.try_with main >>= function
    | Ok () -> Shutdown.exit 0
    | Error exn -> eprintf "%s\n%!" (Exn.to_string exn);Shutdown.exit 1);
  never_returns (Scheduler.go ())
