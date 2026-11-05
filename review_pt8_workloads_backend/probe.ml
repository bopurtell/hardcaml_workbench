open! Core
open! Async
open Hardcaml_workbench_protocol
module W = Asic_workloads
module S = Hardcaml_workbench_backend.Asic_workloads_service
module Service = Hardcaml_workbench_backend.Asic_service
module Config = Hardcaml_workbench_project_integration.Asic_config

let a = String.make 64 'a'
let b = String.make 64 'b'
let c = String.make 64 'c'
let provider = String.make 64 'd'
let obj xs = `Assoc xs
let str s = `String s
let raw = Yojson.Safe.to_string

let field k = function
  | `Assoc xs -> List.Assoc.find xs k ~equal:String.equal |> Option.value ~default:`Null
  | _ -> `Null
;;

let replace j k value =
  match j with
  | `Assoc xs -> obj ((k, value) :: List.Assoc.remove xs k ~equal:String.equal)
  | _ -> failwith "object required"
;;

let inspect ?expected_digest result = W.Query.Inspect { result; expected_digest }

let metric =
  obj
    [ "metric_id", str "workload/cycles"
    ; "name", str "cycles"
    ; "quantity", str "integer"
    ; "classification", str "derived"
    ; "unit", str "cycles"
    ; "stage", str "functional_simulation"
    ; "definition", str "independent-probe"
    ; "value", `Intlit "9007199254740993"
    ]
;;

let inspection path =
  obj
    [ "contract", str "hardcaml-asic.workload-inspection"
    ; "schema_version", `Int 1
    ; "source_digest", str a
    ; ( "binding"
      , obj
          [ "bundle_identity", str b
          ; "hardware_variant_identity", str b
          ; "workload_identity", str b
          ; "simulation_sha256", str b
          ; "simulation_attempt_id", str "independent-simulation"
          ] )
    ; "controls", obj []
    ; "provenance", obj [ "sources", `List [ obj [ "path", str path ] ] ]
    ; ( "outcome"
      , obj
          [ "status", str "completed"
          ; "functional", str "pass"
          ; "performance", str "available"
          ] )
    ; "metrics", `List [ metric ]
    ]
;;

let compare
  ?(expected_left_digest = None)
  ?(expected_right_digest = None)
  ?(expected_left_workload_digest = None)
  ?(expected_right_workload_digest = None)
  left
  right
  lw
  rw
  =
  W.Query.Compare
    { left = Bundle left
    ; right = Bundle right
    ; axis = Resource_policy
    ; left_workload = Some lw
    ; right_workload = Some rw
    ; expected_left_digest
    ; expected_right_digest
    ; expected_left_workload_digest
    ; expected_right_workload_digest
    }
;;

let comparison left right lw rw =
  let side target result digest =
    obj
      [ "kind", str "bundle"
      ; "target", str target
      ; "source_digest", str digest
      ; "identities", obj []
      ; "outcomes", obj []
      ; "workload", inspection result
      ]
  in
  obj
    [ "contract", str "hardcaml-asic.variant-comparison"
    ; "schema_version", `Int 1
    ; "comparison_digest", str c
    ; "policy", str "bounded-pair-v1"
    ; "axis", str "resource_policy"
    ; "left", side left lw b
    ; "right", side right rw c
    ; "differences", `List []
    ; ( "metrics"
      , `List
          [ obj
              [ "metric_id", str "workload/cycles"
              ; "left", metric
              ; "right", metric
              ; "comparison", str "comparable"
              ; "reasons", `List []
              ; "right_minus_left", `Int 0
              ; ( "right_minus_left_ratio"
                , obj [ "numerator", `Int 0; "denominator", `Int 1 ] )
              ]
          ] )
    ; "workload", obj []
    ; "truncated", `Bool false
    ]
;;

let observations = ref []

let record name actual =
  observations := obj [ "name", str name; "observed", actual ] :: !observations;
  printf "%s: %s\n%!" name (raw actual)
;;

let check name ok =
  record name (`Bool ok);
  if not ok then failwith ("Control failed: " ^ name)
;;

let rejects f =
  match Or_error.try_with f with
  | Ok _ -> false
  | Error _ -> true
;;

let mkdir p = Core_unix.mkdir_p p ~perm:0o700
let write p s = Out_channel.write_all p ~data:s
let exists p = Poly.equal (Sys_unix.file_exists p) `Yes
let read p = In_channel.read_all p

let digest text =
  Cryptokit.hash_string (Cryptokit.Hash.sha256 ()) text
  |> Cryptokit.transform_string (Cryptokit.Hexa.encode ())
;;

let pure () =
  let result = "/explicit/result.json" in
  let j = inspection result in
  check
    "inspection exact digest accepts"
    (not
       (rejects (fun () ->
          S.validate_response (inspect ~expected_digest:a result) (raw j))));
  check
    "inspection expected digest rejects changed source"
    (rejects (fun () -> S.validate_response (inspect ~expected_digest:b result) (raw j)));
  let pair = comparison "/left" "/right" "/lw" "/rw" in
  let q =
    compare
      ~expected_left_digest:(Some b)
      ~expected_right_digest:(Some c)
      ~expected_left_workload_digest:(Some a)
      ~expected_right_workload_digest:(Some a)
      "/left"
      "/right"
      "/lw"
      "/rw"
  in
  check
    "distinct combined-side and workload digests accepted"
    (not (rejects (fun () -> S.validate_response q (raw pair))));
  let wrong = compare ~expected_left_digest:(Some a) "/left" "/right" "/lw" "/rw" in
  check
    "standalone digest cannot substitute for combined side digest"
    (rejects (fun () -> S.validate_response wrong (raw pair)));
  let wrong =
    compare ~expected_right_workload_digest:(Some c) "/left" "/right" "/lw" "/rw"
  in
  check
    "nested right workload expectation rejects changed source"
    (rejects (fun () -> S.validate_response wrong (raw pair)));
  List.iter
    [ "contract", str "wrong"; "schema_version", `Int 2; "unknown", `Bool true ]
    ~f:(fun (key, value) ->
      check
        ("strict outer envelope " ^ key)
        (rejects (fun () ->
           S.validate_response (inspect result) (raw (replace j key value)))));
  let duplicate =
    String.chop_suffix_exn (raw j) ~suffix:"}" ^ ",\"source_\\u0064igest\":\"" ^ a ^ "\"}"
  in
  check
    "escaped duplicate envelope key rejects"
    (rejects (fun () -> S.validate_response (inspect result) duplicate));
  check
    "unexpected comparison attachment rejects"
    (rejects (fun () ->
       S.validate_response
         (W.Query.Compare
            { left = Bundle "/left"
            ; right = Bundle "/right"
            ; axis = Resource_policy
            ; left_workload = None
            ; right_workload = None
            ; expected_left_digest = None
            ; expected_right_digest = None
            ; expected_left_workload_digest = None
            ; expected_right_workload_digest = None
            })
         (raw pair)));
  List.iter [ "[0,]"; "(0,1)"; "NaN"; "Infinity"; "1e9999" ] ~f:(fun token ->
    let text =
      String.substr_replace_all (raw j) ~pattern:"9007199254740993" ~with_:token
    in
    record
      ("numeric syntax " ^ token ^ " rejected")
      (`Bool (rejects (fun () -> S.validate_response (inspect result) text))));
  let metadata cap =
    obj
      [ ( "cli_contract"
        , obj
            [ "version", `Int 4
            ; ( "capabilities"
              , obj [ "namedflow1", `Bool true; "workload_inspection1", cap ] )
            ] )
      ]
  in
  List.iter
    [ `Bool false
    ; obj [ "schema_version", `Int 1; "read_only", `Bool false ]
    ; obj [ "schema_version", `Int 2; "read_only", `Bool true ]
    ; `Null
    ]
    ~f:(fun cap ->
      check
        ("capability refusal " ^ raw cap)
        (rejects (fun () -> S.check_capabilities (inspect result) (metadata cap))));
  check
    "exact numeric raw bytes retained"
    (String.equal (S.validate_response (inspect result) (raw j)).json (raw j))
;;

type fixture =
  { root : string
  ; state : string
  ; result : string
  ; service : Service.t
  }

let make base name ~provider_source ?state () =
  let home = Filename.concat base name in
  mkdir home;
  let root = Filename.concat home "project" in
  mkdir root;
  let retained = Filename.concat home "retained" in
  mkdir retained;
  let result = Filename.concat retained "result.json" in
  write result "{}";
  let state = Option.value state ~default:(Filename.concat home "state") in
  let executable = Filename.concat root "reader" in
  write executable provider_source;
  Core_unix.chmod executable ~perm:0o700;
  List.iter [ "workload-inspect"; "compare" ] ~f:(fun command ->
    write
      (Filename.concat root ("hardcaml-asic-experimental-" ^ command))
      "independent-helper");
  let config : Config.t =
    { schema_version = 1
    ; project_executable = executable
    ; provider_executable = executable
    ; results_root = Filename.concat home "results"
    ; toolchain = Filename.concat home "tools"
    ; python = None
    ; support_tools = None
    ; pdk_root = None
    ; stage_timeout_seconds = None
    }
  in
  write
    (Filename.concat root Config.filename)
    (Sexp.to_string_mach (Config.sexp_of_t config));
  write (Filename.concat root "response.json") (raw (inspection result));
  { root; state; result; service = Service.create ~state_dir:state }
;;

let handle f operation =
  Service.handle
    f.service
    ~root:f.root
    ~environment:V1.Environment_selection.Inherit_daemon
    operation
  >>| function
  | Ok s -> s
  | Error e -> failwith e.V1.Error.message
;;

let load f q refresh = handle f (Workloads (Load { query = q; refresh }))

let settled f =
  let%bind () = Service.completion f.service in
  handle f Get
;;

let workloads s = Option.value_exn s.Asic.Snapshot.workloads
let descriptor s = List.hd_exn (workloads s).entries

let calls f =
  let p = Filename.concat f.root "calls.jsonl" in
  if exists p then In_channel.read_lines p |> List.map ~f:Yojson.Safe.from_string else []
;;

let readers f =
  List.count (calls f) ~f:(fun j ->
    match field "argv" j with
    | `List (`String ("workload-inspect" | "compare") :: _) -> true
    | _ -> false)
;;

let wait_file p =
  let deadline = Time_ns.add (Time_ns.now ()) (Time_ns.Span.of_sec 10.) in
  let rec loop () =
    if exists p
    then Deferred.unit
    else if Time_ns.(now () > deadline)
    then failwith ("Timeout waiting for " ^ p)
    else (
      let%bind () = Clock.after (Time_float.Span.of_ms 5.) in
      loop ())
  in
  loop ()
;;

let refresh f q =
  let%bind _ = load f q true in
  settled f
;;

let integrated base provider_source =
  let f = make base "service" ~provider_source () in
  let q = inspect ~expected_digest:a f.result in
  let%bind _ = handle f Get in
  check "Get no provider" (List.is_empty (calls f));
  let%bind s = refresh f q in
  check
    "foreground reader publishes validated"
    (W.Freshness.equal (descriptor s).freshness Validated);
  let initial = (workloads s).selected in
  let%bind () =
    Deferred.List.iter
      [ "oversized-record"; "oversized-lines"; "boundary"; "stderr-pressure" ]
      ~how:`Sequential
      ~f:(fun mode ->
        write (Filename.concat f.root "mode") mode;
        let%map s = refresh f q in
        let failed =
          match (descriptor s).freshness with
          | Refresh_failed _ -> true
          | _ -> false
        in
        check
          ("stream " ^ mode)
          (Bool.equal failed (String.is_prefix mode ~prefix:"oversized"));
        if failed
        then
          check
            ("stream failure retains payload " ^ mode)
            (Option.equal W.Response.equal initial (workloads s).selected))
  in
  Core_unix.unlink (Filename.concat f.root "mode");
  let%bind _ = refresh f q in
  write
    (Filename.concat f.root "response.json")
    (raw (replace (inspection f.result) "source_digest" (str b)));
  let%bind s = refresh f q in
  check
    "captured refresh cannot silently adopt new source"
    (match (descriptor s).freshness with
     | Refresh_failed _ -> Option.equal W.Response.equal initial (workloads s).selected
     | _ -> false);
  write (Filename.concat f.root "response.json") (raw (inspection f.result));
  write
    (Filename.concat f.root "caps.json")
    {|{"workload_inspection1":{"schema_version":1,"read_only":false}}|};
  let n = readers f in
  let%bind s = refresh f q in
  check
    "capability authorization refuses before reader process"
    (readers f = n
     &&
     match (descriptor s).freshness with
     | Refresh_failed _ -> true
     | _ -> false);
  Core_unix.unlink (Filename.concat f.root "caps.json");
  write (Filename.concat f.root "metadata-oversize") "oversize";
  let n = readers f in
  let%bind s = refresh f q in
  check
    "metadata drain capped at 1MiB before reader"
    (readers f = n
     &&
     match (descriptor s).freshness with
     | Refresh_failed _ -> true
     | _ -> false);
  Core_unix.unlink (Filename.concat f.root "metadata-oversize");
  let left = Filename.concat (Filename.dirname f.result) "left-bundle"
  and right = Filename.concat (Filename.dirname f.result) "right-bundle" in
  mkdir left;
  mkdir right;
  let rw = Filename.concat (Filename.dirname f.result) "right-result.json" in
  write rw "{}";
  let pair = comparison left right f.result rw in
  let cq =
    compare
      ~expected_left_digest:(Some b)
      ~expected_right_digest:(Some c)
      ~expected_left_workload_digest:(Some a)
      ~expected_right_workload_digest:(Some a)
      left
      right
      f.result
      rw
  in
  write (Filename.concat f.root "response.json") (raw pair);
  let%bind cs = refresh f cq in
  check
    "combined and nested expectations through live process"
    (W.Freshness.equal (descriptor cs).freshness Validated);
  let previous = (workloads cs).selected in
  let changed_target =
    replace pair "left" (replace (field "left" pair) "target" (str "/other-target"))
  in
  write (Filename.concat f.root "response.json") (raw changed_target);
  let%bind cs = refresh f cq in
  check
    "live comparison wrong target retains old pair with failure"
    (Option.equal W.Response.equal previous (workloads cs).selected
     &&
     match (descriptor cs).freshness with
     | Refresh_failed _ -> true
     | _ -> false);
  let changed_workload =
    replace
      pair
      "right"
      (replace
         (field "right" pair)
         "workload"
         (replace (inspection rw) "source_digest" (str b)))
  in
  write (Filename.concat f.root "response.json") (raw changed_workload);
  let%bind cs = refresh f cq in
  check
    "live nested digest fence retains captured pair"
    (Option.equal W.Response.equal previous (workloads cs).selected
     &&
     match (descriptor cs).freshness with
     | Refresh_failed _ -> true
     | _ -> false);
  write (Filename.concat f.root "response.json") (raw (inspection f.result));
  let%bind _ = refresh f q in
  write (Filename.concat f.root "gate") "hold";
  let before = readers f in
  let%bind _ = load f q true in
  let%bind () = wait_file (Filename.concat f.root "entered") in
  let%bind _ = load f q true in
  let%bind _ =
    load f (inspect (Filename.concat (Filename.dirname f.result) "other.json")) true
  in
  Core_unix.unlink (Filename.concat f.root "gate");
  let%bind s = settled f in
  check "same-key refresh coalesces once plus distinct query" (readers f = before + 2);
  check
    "late old query cannot steal new selection"
    (Option.is_none (workloads s).selected);
  (* Restart after a failed refresh: record whether that diagnostic is durable. *)
  let%bind _ = load f q false in
  let%bind _ = settled f in
  write (Filename.concat f.root "exit-code") "2";
  let%bind s = refresh f q in
  check
    "failed refresh keeps old selected and marks failure"
    (match (descriptor s).freshness with
     | Refresh_failed _ -> Option.is_some (workloads s).selected
     | _ -> false);
  let%bind () = Service.shutdown f.service in
  let restarted = { f with service = Service.create ~state_dir:f.state } in
  let n = List.length (calls f) in
  let%bind s = handle restarted Get in
  record
    "restart preserves selected-query refresh diagnostic"
    (`Bool
      (List.exists (workloads s).entries ~f:(fun d ->
         String.equal d.key (W.Operation.key (Load { query = q; refresh = false }))
         && Option.is_some d.error)));
  check
    "restart cached unverified no provider"
    (List.length (calls f) = n
     && List.for_all (workloads s).entries ~f:(fun d ->
       W.Freshness.equal d.freshness Cached_unverified));
  Service.shutdown restarted.service
;;

let generation_controls base provider_source =
  let%bind () =
    Deferred.List.iter
      [ "helper-bytes"; "launcher-bytes"; "launcher-alias"; "source-alias" ]
      ~how:`Sequential
      ~f:(fun name ->
        let f = make base name ~provider_source () in
        let rootfile p = Filename.concat f.root p in
        let q =
          if String.equal name "source-alias"
          then (
            let link = rootfile "source-link" in
            Core_unix.symlink ~target:(Filename.dirname f.result) ~link_name:link;
            inspect (Filename.concat link "result.json"))
          else inspect f.result
        in
        let%bind _ = refresh f q in
        let n = readers f in
        write (rootfile "gate") "hold";
        let%bind _ = load f q true in
        let%bind () = wait_file (rootfile "entered") in
        (match name with
         | "helper-bytes" ->
           write
             (rootfile "hardcaml-asic-experimental-workload-inspect")
             "changed helper generation"
         | "launcher-bytes" ->
           write (rootfile "reader") (provider_source ^ "\n# changed bytes\n")
         | "launcher-alias" ->
           let replacement = rootfile "reader-copy" in
           write replacement provider_source;
           Core_unix.chmod replacement ~perm:0o700;
           Core_unix.unlink (rootfile "reader");
           Core_unix.symlink ~target:replacement ~link_name:(rootfile "reader")
         | "source-alias" ->
           let other = rootfile "other-source" in
           mkdir other;
           write (Filename.concat other "result.json") "{}";
           Core_unix.unlink (rootfile "source-link");
           Core_unix.symlink ~target:other ~link_name:(rootfile "source-link")
         | _ -> assert false);
        Core_unix.unlink (rootfile "gate");
        let%bind s = settled f in
        check
          ("post-read generation rejects " ^ name)
          (match (descriptor s).freshness with
           | Refresh_failed _ ->
             Option.is_some (workloads s).selected && readers f = n + 1
           | _ -> false);
        let errors = Option.to_list (descriptor s).error |> List.map ~f:str in
        record ("post-read reason " ^ name) (`List errors);
        let last_pid = calls f |> List.last_exn |> field "pid" in
        check
          ("owned process reaped " ^ name)
          (match last_pid with
           | `Int pid -> not (exists ("/proc/" ^ Int.to_string pid))
           | _ -> false);
        Service.shutdown f.service)
  in
  Deferred.unit
;;

let cancellation base provider_source =
  let f = make base "cancellation" ~provider_source () in
  let q = inspect f.result in
  let%bind s = refresh f q in
  let previous = (workloads s).selected in
  write (Filename.concat f.root "gate") "hold";
  let%bind _ = load f q true in
  let%bind () = wait_file (Filename.concat f.root "entered") in
  let%bind _ = handle f (Cancel (W.Operation.key (Load { query = q; refresh = true }))) in
  let%bind s = settled f in
  check
    "cancelled held refresh preserves old data marked failure"
    (Option.equal W.Response.equal previous (workloads s).selected
     &&
     match (descriptor s).freshness with
     | Refresh_failed _ -> true
     | _ -> false);
  let pid = Int.of_string (read (Filename.concat f.root "entered")) in
  check "cancelled owned child reaped" (not (exists ("/proc/" ^ Int.to_string pid)));
  Service.shutdown f.service
;;

let alias_and_config base provider_source =
  let f = make base "config-change" ~provider_source () in
  let q = inspect f.result in
  let%bind _ = refresh f q in
  let config_path = Filename.concat f.root Config.filename in
  let config = Config.parse_string (read config_path) |> Or_error.ok_exn in
  write
    config_path
    (Sexp.to_string_mach
       (Config.sexp_of_t
          { config with provider_executable = "/nonexistent/review-changed-provider" }));
  let n = readers f in
  let%bind s = refresh f q in
  record
    "changed config still executes old provider and validates"
    (`Bool (readers f = n + 1 && W.Freshness.equal (descriptor s).freshness Validated));
  let%bind () = Service.shutdown f.service in
  let home = Filename.concat base "state-alias" in
  mkdir home;
  let good = Filename.concat home "outside" in
  mkdir good;
  let state = Filename.concat home "state-link" in
  Core_unix.symlink ~target:good ~link_name:state;
  let f = make base "state-alias" ~provider_source ~state () in
  write (Filename.concat f.root "gate") "hold";
  let%bind _ = load f (inspect f.result) true in
  let%bind () = wait_file (Filename.concat f.root "entered") in
  Core_unix.unlink state;
  Core_unix.symlink ~target:(Filename.dirname f.result) ~link_name:state;
  Core_unix.unlink (Filename.concat f.root "gate");
  let%bind s = settled f in
  let written =
    Sys_unix.ls_dir (Filename.dirname f.result)
    |> List.filter ~f:(fun p -> String.is_prefix p ~prefix:"asic-workloads-")
  in
  record
    "state alias retarget writes cache into evidence root"
    (obj
       [ "files", `List (List.map written ~f:str)
       ; "validated", `Bool (W.Freshness.equal (descriptor s).freshness Validated)
       ]);
  Service.shutdown f.service
;;

let cache_probe base =
  let state = Filename.concat base "cache-forgery" in
  mkdir state;
  let query = inspect "/original/result.json" in
  let cache = S.create ~state_dir:state ~identity:"independent-context" in
  S.select cache query;
  let%bind () =
    S.publish
      cache
      query
      ~provider_identity:provider
      (raw (inspection "/original/result.json"))
  in
  let file = Filename.concat state (List.hd_exn (Sys_unix.ls_dir state)) in
  write (Filename.concat state "original-cache.sexp") (read file);
  let stored = Sexp.of_string (read file) in
  let fields =
    match stored with
    | Sexp.List xs -> xs
    | _ -> failwith "stored record"
  in
  let lookup k =
    List.find_map_exn fields ~f:(function
      | Sexp.List [ Atom key; v ] when String.equal key k -> Some v
      | _ -> None)
  in
  let items = lookup "items" in
  let rec replace_atom old replacement = function
    | Sexp.Atom s when String.equal s old -> Sexp.Atom replacement
    | List xs -> List (List.map xs ~f:(replace_atom old replacement))
    | x -> x
  in
  let wrong_query = inspect "/different/result.json" in
  let wrong_key = W.Operation.key (Load { query = wrong_query; refresh = false }) in
  let items =
    replace_atom "/original/result.json" "/different/result.json" items
    |> replace_atom (W.Operation.key (Load { query; refresh = false })) wrong_key
  in
  (* Update Response.key too, but leave its admitted JSON bound to original result. *)
  let checksum = digest (Sexp.to_string_mach items) in
  let rewritten =
    List.map fields ~f:(function
      | Sexp.List [ Atom "items"; _ ] -> Sexp.List [ Atom "items"; items ]
      | Sexp.List [ Atom "checksum"; _ ] -> Sexp.List [ Atom "checksum"; Atom checksum ]
      | x -> x)
    |> fun xs -> Sexp.List xs
  in
  write file (Sexp.to_string_mach rewritten);
  write (Filename.concat state "rebound-cache.sexp") (read file);
  let cache = S.create ~state_dir:state ~identity:"independent-context" in
  S.select cache wrong_query;
  let snap = S.snapshot cache in
  record
    "coherent cache query rebind accepted with original raw target"
    (obj
       [ "selected", `Bool (Option.is_some snap.selected)
       ; "cache_error", Option.value_map snap.cache_error ~default:`Null ~f:str
       ]);
  check
    "same rebound payload rejected by live target binding"
    (rejects (fun () ->
       S.check_targets
         wrong_query
         ~paths:[ "/different/result.json" ]
         (Option.value_exn snap.selected).json));
  let other_filename =
    Filename.concat state ("asic-workloads-" ^ digest "other-provider-context" ^ ".sexp")
  in
  write other_filename (read file);
  let other = S.create ~state_dir:state ~identity:"other-provider-context" in
  check
    "cache copied into another configuration context rejects"
    (List.is_empty (S.snapshot other).entries
     && Option.is_some (S.snapshot other).cache_error);
  let invalid_items =
    replace_atom
      (raw (inspection "/original/result.json"))
      (raw (replace (inspection "/original/result.json") "contract" (str "bad")))
      items
  in
  let invalid_checksum = digest (Sexp.to_string_mach invalid_items) in
  let invalid =
    List.map fields ~f:(function
      | Sexp.List [ Atom "items"; _ ] -> Sexp.List [ Atom "items"; invalid_items ]
      | Sexp.List [ Atom "checksum"; _ ] ->
        Sexp.List [ Atom "checksum"; Atom invalid_checksum ]
      | x -> x)
    |> fun xs -> Sexp.List xs
  in
  write file (Sexp.to_string_mach invalid);
  let invalid = S.create ~state_dir:state ~identity:"independent-context" in
  check
    "coherently checksummed malformed cache envelope rejects"
    (List.is_empty (S.snapshot invalid).entries
     && Option.is_some (S.snapshot invalid).cache_error);
  Deferred.unit
;;

let main () =
  let base = Core_unix.mkdtemp "/tmp/opencode/pt8-backend-review-" in
  let source = In_channel.read_all (Sys.get_argv ()).(1) in
  printf "Evidence: %s\n%!" base;
  let sources =
    List.map
      [ "backend/asic_workloads_service.ml"
      ; "backend/asic_service.ml"
      ; "backend/asic_process.ml"
      ; "adapters/asic_adapter.ml"
      ; "protocol/asic_workloads.ml"
      ; "review_pt8_workloads_backend/probe.ml"
      ; "review_pt8_workloads_backend/provider.py"
      ]
      ~f:(fun path -> path, str (digest (read path)))
  in
  let%bind result =
    Monitor.try_with (fun () ->
      pure ();
      let%bind () = integrated base source in
      let%bind () = generation_controls base source in
      let%bind () = cancellation base source in
      let%bind () = alias_and_config base source in
      cache_probe base)
  in
  let receipt =
    obj
      [ "source_sha256", obj sources
      ; "probe_executable_sha256", str (digest (read (Sys.get_argv ()).(0)))
      ; "observations", `List (List.rev !observations)
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
  don't_wait_for (main ());
  never_returns (Scheduler.go ())
;;
