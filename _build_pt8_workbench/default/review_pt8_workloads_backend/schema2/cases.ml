module Storage = Hardcaml_workbench_backend.Asic_workloads_storage

let key query = W.Operation.key (Load { query; refresh = false })
let fd_count () = List.length (Sys_unix.ls_dir "/proc/self/fd")
let link target name = Core_unix.symlink ~target ~link_name:name

let retarget name target =
  Core_unix.unlink name;
  link target name
;;

let cache_name identity = "asic-workloads-" ^ digest identity ^ ".sexp"

let temp_files path =
  Sys_unix.ls_dir path
  |> List.filter ~f:(fun n -> String.is_prefix n ~prefix:".workloads-")
;;

let held_cache_root base provider_source =
  let home = Filename.concat base "held-root" in
  mkdir home;
  let outside = Filename.concat home "outside" in
  mkdir outside;
  let alias = Filename.concat home "state-link" in
  link outside alias;
  let f = make base "held-root" ~provider_source ~state:alias () in
  Monitor.protect
    ~finally:(fun () -> Service.shutdown f.service)
    (fun () ->
      let q = inspect f.result in
      let%bind before = refresh f q in
      let old = Option.value_exn (workloads before).selected in
      let saved =
        Sys_unix.ls_dir outside
        |> List.map ~f:(fun name -> name, read (Filename.concat outside name))
      in
      write (Filename.concat f.root "gate") "hold";
      write
        (Filename.concat f.root "response.json")
        (raw (replace (inspection f.result) "source_digest" (str b)));
      let%bind _ = load f q true in
      let%bind () = wait_file (Filename.concat f.root "entered") in
      let evidence_before = Sys_unix.ls_dir (Filename.dirname f.result) in
      retarget alias (Filename.dirname f.result);
      Core_unix.unlink (Filename.concat f.root "gate");
      let%bind after = settled f in
      check
        "R1 held retarget leaves evidence directory membership unchanged"
        (List.equal
           String.equal
           evidence_before
           (Sys_unix.ls_dir (Filename.dirname f.result)));
      check
        "R1 held retarget retains original persisted bytes"
        (List.for_all saved ~f:(fun (name, bytes) ->
           String.equal bytes (read (Filename.concat outside name))));
      check
        "R1 held retarget retains prior in-memory response"
        (Option.exists (workloads after).selected ~f:(W.Response.equal old));
      check
        "R1 failed persistence marks old response Refresh_failed"
        (match (descriptor after).freshness with
         | Refresh_failed _ -> true
         | _ -> false);
      check
        "R1 failed persistence has a cache diagnostic"
        (Option.is_some (workloads after).cache_error);
      check
        "R1 held retarget leaves no temporary files in either directory"
        (List.is_empty (temp_files outside)
         && List.is_empty (temp_files (Filename.dirname f.result)));
      record
        "R1 held retarget rejection reason"
        (Option.value_map (descriptor after).error ~default:`Null ~f:str);
      retarget alias outside;
      let%map repaired = refresh f q in
      check
        "R1 repaired original alias can publish the new generation"
        (W.Freshness.equal (descriptor repaired).freshness Validated
         && Option.equal String.equal (descriptor repaired).digest (Some b));
      check
        "R1 successful repair clears storage diagnostic"
        (Option.is_none (workloads repaired).cache_error))
;;

let descriptor_failures base =
  List.iter [ 1; 2; 3 ] ~f:(fun phase ->
    let root = Filename.concat base ("descriptor-alias-" ^ Int.to_string phase) in
    mkdir root;
    let outside = Filename.concat root "outside"
    and evidence = Filename.concat root "evidence" in
    mkdir outside;
    mkdir evidence;
    write (Filename.concat outside "old.sexp") "prior-cache";
    let alias = Filename.concat root "state" in
    link outside alias;
    let storage = Storage.create alias in
    let count = ref 0 in
    check
      ("descriptor alias phase " ^ Int.to_string phase ^ " rejects")
      (rejects (fun () ->
         Storage.write
           storage
           ~name:"old.sexp"
           ~data:"replacement"
           ~before_write:(fun () ->
             incr count;
             if !count = phase then retarget alias evidence)));
    check ("descriptor alias phase " ^ Int.to_string phase ^ " reached") (!count = phase);
    check
      ("descriptor alias phase " ^ Int.to_string phase ^ " no evidence writes")
      (List.is_empty (Sys_unix.ls_dir evidence));
    check
      ("descriptor alias phase " ^ Int.to_string phase ^ " old bytes and cleanup")
      (String.equal (read (Filename.concat outside "old.sexp")) "prior-cache"
       && List.is_empty (temp_files outside)));
  List.iter [ 2; 3 ] ~f:(fun phase ->
    let root = Filename.concat base ("ancestor-" ^ Int.to_string phase) in
    mkdir root;
    let ancestor = Filename.concat root "ancestor"
    and evidence = Filename.concat root "evidence" in
    mkdir ancestor;
    mkdir evidence;
    let path = Filename.concat ancestor "state" in
    mkdir path;
    let storage = Storage.create path
    and calls = ref 0 in
    check
      ("descriptor ancestor replacement phase " ^ Int.to_string phase ^ " rejects")
      (rejects (fun () ->
         Storage.write storage ~name:"cache.sexp" ~data:"new" ~before_write:(fun () ->
           incr calls;
           if !calls = phase
           then (
             Core_unix.rename ~src:ancestor ~dst:(Filename.concat root "old-ancestor");
             link evidence ancestor))));
    check
      ("descriptor ancestor phase " ^ Int.to_string phase ^ " descriptor-relative cleanup")
      (List.is_empty (Sys_unix.ls_dir evidence)
       && List.is_empty (temp_files (Filename.concat root "old-ancestor/state"))));
  let root = Filename.concat base "descriptor-fd-failures" in
  mkdir root;
  let storage = Storage.create root in
  mkdir (Filename.concat root "blocked");
  let fail_write () =
    Storage.write storage ~name:"blocked" ~data:"new-cache" ~before_write:(fun () -> ())
  in
  check "descriptor final rename failure exercised" (rejects fail_write);
  let before = fd_count () in
  for _ = 1 to 256 do
    if not (rejects fail_write) then failwith "rename failure unexpectedly succeeded"
  done;
  let after = fd_count () in
  check "256 descriptor rename failures leak zero descriptors" (before = after);
  check
    "256 descriptor rename failures leave zero temporary files"
    (List.is_empty (temp_files root));
  record
    "descriptor failure FD counts"
    (obj [ "before", `Int before; "after", `Int after; "iterations", `Int 256 ]);
  let id = "malformed-storage" in
  write (Filename.concat root (cache_name id)) "not valid sexp)";
  let restore () = S.create ~state_dir:root ~identity:id |> S.snapshot in
  check
    "malformed storage read failure exercised"
    (Option.is_some (restore ()).cache_error);
  let before = fd_count () in
  for _ = 1 to 256 do
    if Option.is_none (restore ()).cache_error then failwith "malformed cache restored"
  done;
  let after = fd_count () in
  check "256 malformed cache restores leak zero descriptors" (before = after);
  record
    "restore failure FD counts"
    (obj [ "before", `Int before; "after", `Int after; "iterations", `Int 256 ])
;;

let sexp_fields = function
  | Sexp.List fields -> fields
  | _ -> failwith "Expected stored record"
;;

let sexp_field fields name =
  List.find_map_exn fields ~f:(function
    | Sexp.List [ Atom k; v ] when String.equal k name -> Some v
    | _ -> None)
;;

let with_items stored items =
  let checksum = digest (Sexp.to_string_mach items) in
  Sexp.List
    (List.map (sexp_fields stored) ~f:(function
      | Sexp.List [ Atom "items"; _ ] -> Sexp.List [ Atom "items"; items ]
      | List [ Atom "checksum"; _ ] -> Sexp.List [ Atom "checksum"; Atom checksum ]
      | x -> x))
;;

let rec rewrite_atoms replacements = function
  | Sexp.Atom atom ->
    Sexp.Atom
      (List.Assoc.find replacements atom ~equal:String.equal |> Option.value ~default:atom)
  | List xs -> List (List.map xs ~f:(rewrite_atoms replacements))
;;

let get_response original =
  let fields = sexp_fields original in
  match sexp_field fields "items" with
  | Sexp.List [ item ] ->
    (match sexp_field (sexp_fields item) "response" with
     | Sexp.List [ response ] -> W.Response.t_of_sexp response
     | _ -> failwith "Expected one response")
  | _ -> failwith "Expected one stored item"
;;

let verify_rejection
  root
  state
  identity
  original
  ~old_query
  ~new_query
  ~replacements
  label
  =
  let file = Filename.concat state (cache_name identity) in
  let fields = sexp_fields original in
  check
    (label ^ " original cache is schema2")
    (Sexp.equal (sexp_field fields "version") (Sexp.Atom "2"));
  let response = get_response original in
  check
    (label ^ " unchanged public envelope passes new query structural/digest admission")
    (not (rejects (fun () -> S.validate_response new_query response.json)));
  let items =
    sexp_field fields "items"
    |> rewrite_atoms ((key old_query, key new_query) :: replacements)
  in
  let forged = with_items original items in
  write file (Sexp.to_string_mach forged);
  write (Filename.concat root (label ^ "-rebound.sexp")) (Sexp.to_string_mach forged);
  let restored = S.create ~state_dir:state ~identity in
  S.select restored new_query;
  let snapshot = S.snapshot restored in
  check
    (label ^ " coherent query/key/bindings/checksum rebind rejects")
    (Option.is_none snapshot.selected
     && List.is_empty snapshot.entries
     && Option.is_some snapshot.cache_error);
  record
    (label ^ " restore reason")
    (Option.value_map snapshot.cache_error ~default:`Null ~f:str);
  write file (Sexp.to_string_mach original);
  let restored = S.create ~state_dir:state ~identity in
  S.select restored old_query;
  check
    (label ^ " original snapshot remains restorable")
    (Option.is_some (S.snapshot restored).selected
     && Option.is_none (S.snapshot restored).cache_error)
;;

let schema2_rebinding base =
  let root = Filename.concat base "schema2-bindings" in
  mkdir root;
  let state = Filename.concat root "state" in
  let retained = Filename.concat root "retained" in
  mkdir retained;
  let source = Filename.concat retained "result.json" in
  write source "{}";
  let alias = Filename.concat root "source-alias" in
  link retained alias;
  let selected = Filename.concat alias "result.json" in
  let q = inspect ~expected_digest:a selected in
  let identity = "schema2-inspection" in
  let cache = S.create ~state_dir:state ~identity in
  S.select cache q;
  let%bind () =
    S.publish
      ~paths:[ source ]
      cache
      q
      ~provider_identity:provider
      (raw (inspection source))
  in
  let file = Filename.concat state (cache_name identity) in
  let original = Sexp.of_string (read file) in
  write (Filename.concat root "inspection-original.sexp") (read file);
  let wrong = Filename.concat root "wrong/result.json" in
  let wrong_q = inspect ~expected_digest:a wrong in
  verify_rejection
    root
    state
    identity
    original
    ~old_query:q
    ~new_query:wrong_q
    ~replacements:[ selected, wrong; source, wrong ]
    "inspection";
  (* The checksum is coherent even when only the document's source path is wrong. *)
  let wrong_raw =
    raw
      (replace
         (inspection source)
         "provenance"
         (obj [ "sources", `List [ obj [ "path", str wrong ] ] ]))
  in
  check
    "wrong-source raw envelope is structurally valid"
    (not (rejects (fun () -> S.validate_response q wrong_raw)));
  let items =
    sexp_field (sexp_fields original) "items"
    |> rewrite_atoms [ raw (inspection source), wrong_raw ]
  in
  write file (Sexp.to_string_mach (with_items original items));
  let restored = S.create ~state_dir:state ~identity in
  S.select restored q;
  check
    "unchanged query and coherent wrong-source raw envelope reject"
    (Option.is_none (S.snapshot restored).selected
     && Option.is_some (S.snapshot restored).cache_error);
  write file (Sexp.to_string_mach original);
  Core_unix.unlink selected;
  Core_unix.unlink alias;
  Core_unix.rmdir retained;
  let restored = S.create ~state_dir:state ~identity in
  S.select restored q;
  check
    "historical binding reopens with source and alias absent"
    (Option.is_some (S.snapshot restored).selected
     && Option.is_none (S.snapshot restored).cache_error);
  check
    "historical missing-source cache remains Cached_unverified"
    (List.for_all (S.snapshot restored).entries ~f:(fun d ->
       W.Freshness.equal d.W.Descriptor.freshness Cached_unverified));
  let legacy =
    Sexp.List
      (List.map (sexp_fields original) ~f:(function
        | Sexp.List [ Atom "version"; _ ] -> Sexp.List [ Atom "version"; Atom "1" ]
        | x -> x))
  in
  write file (Sexp.to_string_mach legacy);
  let restored = S.create ~state_dir:state ~identity in
  check
    "derived version1 rejects explicitly instead of restoring unbound data"
    (List.is_empty (S.snapshot restored).entries
     && Option.is_some (S.snapshot restored).cache_error);
  write file (Sexp.to_string_mach original);
  let left = Filename.concat root "left"
  and right = Filename.concat root "right"
  and lw = Filename.concat root "lw/result.json"
  and rw = Filename.concat root "rw/result.json" in
  let cq =
    compare
      ~expected_left_digest:(Some b)
      ~expected_right_digest:(Some c)
      ~expected_left_workload_digest:(Some a)
      ~expected_right_workload_digest:(Some a)
      left
      right
      lw
      rw
  in
  let identity = "schema2-comparison" in
  let cache = S.create ~state_dir:state ~identity in
  S.select cache cq;
  let%bind () =
    S.publish cache cq ~provider_identity:provider (raw (comparison left right lw rw))
  in
  let file = Filename.concat state (cache_name identity) in
  let original = Sexp.of_string (read file) in
  write (Filename.concat root "comparison-original.sexp") (read file);
  let wrong_right = Filename.concat root "wrong-right"
  and wrong_rw = Filename.concat root "wrong-rw/result.json" in
  let new_q =
    compare
      ~expected_left_digest:(Some b)
      ~expected_right_digest:(Some c)
      ~expected_left_workload_digest:(Some a)
      ~expected_right_workload_digest:(Some a)
      left
      wrong_right
      lw
      rw
  in
  verify_rejection
    root
    state
    identity
    original
    ~old_query:cq
    ~new_query:new_q
    ~replacements:[ right, wrong_right ]
    "comparison-target";
  let new_q =
    compare
      ~expected_left_digest:(Some b)
      ~expected_right_digest:(Some c)
      ~expected_left_workload_digest:(Some a)
      ~expected_right_workload_digest:(Some a)
      left
      right
      lw
      wrong_rw
  in
  verify_rejection
    root
    state
    identity
    original
    ~old_query:cq
    ~new_query:new_q
    ~replacements:[ rw, wrong_rw ]
    "nested-workload";
  Deferred.unit
;;

let locator_and_separation base =
  let root = Filename.concat base "locator" in
  mkdir root;
  let result = Filename.concat root "source/result.json" in
  let q = inspect result in
  let doc = inspection result in
  let with_bundle value =
    raw (replace doc "binding" (replace (field "binding" doc) "bundle" value))
  in
  check
    "legacy inspection without locator remains admitted"
    (not (rejects (fun () -> S.validate_response q (raw doc))));
  check
    "additive absolute verified locator admitted"
    (not
       (rejects (fun () ->
          S.validate_response q (with_bundle (str (Filename.concat root "bundle"))))));
  List.iter
    [ "null", `Null
    ; "relative", str "relative"
    ; "NUL", str "/invalid\000bundle"
    ; "boolean", `Bool true
    ; "over-budget", str ("/" ^ String.make 4096 'x')
    ]
    ~f:(fun (name, value) ->
      check
        ("invalid bundle locator " ^ name ^ " rejects")
        (rejects (fun () -> S.validate_response q (with_bundle value))));
  let bundle = Filename.concat root "uncreated-evidence-bundle" in
  let state = Filename.concat bundle "cache" in
  let cache = S.create ~state_dir:state ~identity:"locator-overlap" in
  let%map result =
    Monitor.try_with (fun () ->
      S.publish cache q ~provider_identity:provider (with_bundle (str bundle)))
  in
  check
    "bundle locator separation rejects publication before creating evidence"
    (Result.is_error result && not (exists bundle));
  check "rejected locator separation admits no response" (not (S.cached cache q))
;;

let recheck_main () =
  let base = Core_unix.mkdtemp "/tmp/opencode/pt8-backend-corrections-review-" in
  printf "Correction evidence: %s\n%!" base;
  let sources =
    List.map
      [ "backend/asic_workloads_service.ml"
      ; "backend/asic_workloads_service.mli"
      ; "backend/asic_workloads_storage.ml"
      ; "backend/asic_workloads_storage.mli"
      ; "backend/asic_service.ml"
      ; "review_pt8_workloads_backend/probe.ml"
      ; "review_pt8_workloads_backend/provider.py"
      ; "review_pt8_workloads_backend/schema2/generate.py"
      ; "review_pt8_workloads_backend/schema2/cases.ml"
      ]
      ~f:(fun path -> path, str (digest (read path)))
  in
  let provider_source = read (Sys.get_argv ()).(1) in
  let%bind result =
    Monitor.try_with (fun () ->
      let%bind () = held_cache_root base provider_source in
      descriptor_failures base;
      let%bind () = schema2_rebinding base in
      locator_and_separation base)
  in
  let receipt =
    obj
      [ "source_sha256", obj sources
      ; "executable_sha256", str (digest (read (Sys.get_argv ()).(0)))
      ; "observations", `List (List.rev !observations)
      ; "count", `Int (List.length !observations)
      ; ( "error"
        , match result with
          | Ok () -> `Null
          | Error exn -> str (Exn.to_string exn) )
      ]
  in
  write (Filename.concat base "receipt.json") (Yojson.Safe.pretty_to_string receipt);
  match result with
  | Ok () -> Shutdown.exit 0
  | Error exn ->
    eprintf "%s\n%!" (Exn.to_string exn);
    Shutdown.exit 1
;;

let () =
  don't_wait_for (recheck_main ());
  never_returns (Scheduler.go ())
;;
