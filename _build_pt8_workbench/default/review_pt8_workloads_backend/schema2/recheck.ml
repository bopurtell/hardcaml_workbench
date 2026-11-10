(* Schema2 correction recheck; historical probe source is unchanged. *)
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
