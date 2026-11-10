open! Core
open! Async
open Hardcaml_workbench_protocol
module Inspection = Hardcaml_workbench_backend.Asic_inspection
module Public = Hardcaml_workbench_backend.Asic_public
module Service = Hardcaml_workbench_backend.Asic_service

let require condition message = if not condition then failwith message

let rejects f =
  require (Result.is_error (Or_error.try_with f)) "Expected inspection rejection"
;;

let str s = `String s
let json fields = `Assoc fields
let digest = String.make 64 'b'

let run : Run_ref.t =
  { backend = Backend_id.of_string "asic"; id = "run-1"; build = None; label = None }
;;

let environment = V1.Environment_selection.Inherit_daemon

let make_registered execution_file : Asic.Run.t =
  { run
  ; reference = { attempt = "/public/attempt"; stream_id = run.id }
  ; selection = None
  ; cursor = 1
  ; status = "completed"
  ; execution_file = Some execution_file
  ; error = None
  ; stages = []
  ; execution_timing = None
  }
;;

let row id value =
  json
    [ "id", str id
    ; "category", str "setup"
    ; "producer", str "opensta"
    ; "corner", `Null
    ; "group", str "clock"
    ; "name", str "endpoint"
    ; "value", value
    ; "unit", str "ns"
    ; "status", str "unavailable"
    ; "source", str "{\"path\":\"/public/report.json\"}"
    ; "fields", `List [ `List [ str "endpoint"; str "reg/Q" ] ]
    ]
;;

let replace j key value =
  match j with
  | `Assoc fields ->
    json ((key, value) :: List.Assoc.remove fields key ~equal:String.equal)
  | _ -> assert false
;;

let fixture () =
  let root = Core_unix.mkdtemp "/tmp/workbench-inspection-" |> Filename_unix.realpath in
  let execution_file = Filename.concat root "execution.json" in
  let bytes = Yojson.Safe.to_string (json [ "attempt_id", str run.id ]) ^ "\n" in
  Out_channel.write_all execution_file ~data:bytes;
  let registered = make_registered execution_file in
  let execution_sha256 = Inspection.execution_hash ~registered ~execution_file in
  require
    (String.equal execution_sha256 (Public.digest bytes))
    "Execution hash lost exact bytes";
  let response =
    json
      [ "contract", str "hardcaml-asic.inspection"
      ; "schema_version", `Int 1
      ; "execution_file", str execution_file
      ; "execution_sha256", str execution_sha256
      ; "attempt_id", str run.id
      ; "domain", str "timing"
      ; "stage", str "routing"
      ; "source_digest", str digest
      ; "rows", `List [ row "path-1" `Null ]
      ; "diagnostics", `List [ str "corner unavailable" ]
      ; "truncated", `Bool false
      ]
  in
  let parse response =
    Inspection.parse_index
      ~registered
      ~execution_file
      ~execution_sha256
      ~domain:"timing"
      ~stage:"routing"
      response
  in
  root, registered, response, parse
;;

let parser_tests () =
  let root, registered, response, parse = fixture () in
  let index = parse response in
  let first = List.hd_exn index.rows in
  require
    (Option.is_none first.value
     && String.equal first.status "unavailable"
     && List.equal Poly.equal first.fields [ "endpoint", "reg/Q" ])
    "Unknown value/provenance fields were rewritten";
  List.iter
    [ "contract", str "wrong"
    ; "schema_version", `Int 2
    ; "execution_file", str "/wrong/execution.json"
    ; "execution_sha256", str (String.make 64 '0')
    ; "attempt_id", str "other"
    ; "domain", str "clocks"
    ; "stage", str "cts"
    ; "source_digest", str "bad"
    ; "rows", `List [ row "duplicate" `Null; row "duplicate" `Null ]
    ; "rows", `List [ row "path" (`Float Float.nan) ]
    ; "rows", `List [ replace (row "path" `Null) "source" (str "not json") ]
    ; "rows", `List (List.init 4097 ~f:(fun i -> row (Int.to_string i) `Null))
    ; "diagnostics", `List [ str (String.make (Inspection.index_limit + 1) 'x') ]
    ]
    ~f:(fun (key, value) -> rejects (fun () -> parse (replace response key value)));
  (* WB-006: producer-supplied production times keep their meaning and zone; anything else
     stays visibly unknown rather than being reinterpreted. *)
  let produced value =
    let index =
      parse
        (replace
           response
           "production_times"
           (`List [ json [ "producer", str "opensta"; "produced_at", value ] ]))
    in
    Evidence_time.Index.production index.times ~producer:"opensta"
  in
  let supplied raw expected =
    match produced (str raw) with
    | Supplied { at } ->
      require
        (Time_ns.equal
           (Timestamp.to_time_ns at)
           (Time_ns.of_string_with_utc_offset expected))
        ("Production time was reinterpreted: " ^ raw)
    | Unknown | Rejected _ -> failwith ("Valid production time rejected: " ^ raw)
  in
  supplied "2026-10-19T15:04:05.123456Z" "2026-10-19 15:04:05.123456Z";
  supplied "2026-10-19T17:04:05+02:00" "2026-10-19 15:04:05Z";
  supplied "2026-10-19T11:04:05-04:00" "2026-10-19 15:04:05Z";
  supplied "1850-01-01T00:00:00Z" "1850-01-01T00:00:00Z";
  let boundary raw expected =
    match produced (str raw) with
    | Supplied { at } ->
      require
        (Int63.equal
           (Time_ns.Span.to_int63_ns
              (Time_ns.to_span_since_epoch (Timestamp.to_time_ns at)))
           expected)
        ("Production boundary lost precision: " ^ raw)
    | Unknown | Rejected _ -> failwith ("Valid production boundary rejected: " ^ raw)
  in
  boundary "1823-11-12T00:06:21.572612096Z" Int63.min_value;
  boundary "2116-02-20T23:53:38.427387903Z" Int63.max_value;
  boundary "1823-11-11T23:06:21.572612096-01:00" Int63.min_value;
  boundary "2116-02-21T00:53:38.427387903+01:00" Int63.max_value;
  List.iter
    [ "2026-10-19T15:04:05"
    ; "yesterday"
    ; "2026-13-45T99:00:00Z"
    ; "2200-01-01T00:00:00Z"
    ; "1700-01-01T00:00:00Z"
    ; "1823-11-12T00:06:21.572612095Z"
    ; "2116-02-20T23:53:38.427387904Z"
    ; "1823-11-12T00:06:21.572612096+00:01"
    ; "2116-02-20T23:53:38.427387903-00:01"
    ; String.make 80 '1' ^ "Z"
    ]
    ~f:(fun raw ->
      match produced (str raw) with
      | Rejected { raw = kept; _ } ->
        require (String.length kept <= 128) "Rejected production time was unbounded"
      | Unknown | Supplied _ -> failwith ("Invalid production time accepted: " ^ raw));
  require
    (Evidence_time.Production.equal
       (Evidence_time.Index.production (parse response).times ~producer:"opensta")
       Unknown)
    "Absent production time was not unknown";
  rejects (fun () -> parse (replace response "production_times" (str "not a list")));
  rejects (fun () ->
    let entry =
      json [ "producer", str "opensta"; "produced_at", str "2026-10-19T00:00:00Z" ]
    in
    parse (replace response "production_times" (`List [ entry; entry ])));
  let detail =
    response
    |> fun j -> replace (replace j "row_id" (str "path-1")) "detail" (str "path report")
  in
  let parse_detail j = Inspection.parse_detail ~registered ~index ~row_id:"path-1" j in
  require (String.equal (parse_detail detail).text "path report") "Detail missing";
  List.iter
    [ "row_id", str "path-2"
    ; "source_digest", str (String.make 64 'c')
    ; "execution_sha256", str (String.make 64 'c')
    ; "detail", str (String.make 65537 'x')
    ]
    ~f:(fun (key, value) -> rejects (fun () -> parse_detail (replace detail key value)));
  let execution_file = Option.value_exn registered.execution_file in
  let alias = Filename.concat root "alias.json" in
  Core_unix.symlink ~target:execution_file ~link_name:alias;
  rejects (fun () ->
    Inspection.execution_hash ~registered:(make_registered alias) ~execution_file:alias);
  Out_channel.write_all execution_file ~data:"{\"attempt_id\":\"wrong\"}";
  rejects (fun () -> Inspection.execution_hash ~registered ~execution_file)
;;

let cache_tests () =
  let root, registered, response, parse = fixture () in
  let index =
    parse
      (replace
         response
         "production_times"
         (`List
           [ json
               [ "producer", str "opensta"
               ; "produced_at", str "1850-01-01T01:00:00+01:00"
               ]
           ]))
    |> Inspection.observe_times
         ~execution_file:(Option.value_exn registered.execution_file)
         ~validated_at:
           (Timestamp.of_time_ns
              (Time_ns.of_string_with_utc_offset "2026-10-19T15:30:00Z"))
  in
  require
    (Option.is_some (Evidence_time.Index.validated index.times)
     && Option.is_some (Evidence_time.Index.file_modified index.times))
    "Restart fixture lacks observation times";
  let state_dir = Filename.concat root "cache" in
  let identity = "project/environment/configuration" in
  let load run =
    Inspection.load
      ~state_dir
      ~identity
      ~run
      ~execution_file:index.execution_file
      ~domain:index.domain
      ~stage:index.stage
  in
  rejects (fun () -> load run);
  let large = { index with diagnostics = [ String.make (300 * 1024) 'x' ] } in
  Inspection.save ~state_dir ~identity large;
  require
    (List.equal String.equal (load run).diagnostics large.diagnostics)
    "Rich cache incorrectly inherited the 256KiB summary budget";
  Inspection.save ~state_dir ~identity index;
  Core_unix.unlink index.execution_file;
  let cached = load run in
  require
    (cached.cached_unverified
     && Asic_inspection.Index.equal cached { index with cached_unverified = true })
    "Offline restart cache did not preserve evidence/freshness";
  rejects (fun () -> load { run with label = Some "wrong identity" });
  rejects (fun () ->
    Inspection.load
      ~state_dir
      ~identity
      ~run
      ~execution_file:"/different/execution.json"
      ~domain:index.domain
      ~stage:index.stage);
  List.iter
    (List.init 8 ~f:(fun i -> Int.to_string i))
    ~f:(fun id ->
      Inspection.save ~state_dir ~identity { index with run = { run with id } });
  rejects (fun () -> load run);
  ignore (load { run with id = "7" } : Asic_inspection.Index.t);
  let cache_file = List.hd_exn (Sys_unix.ls_dir state_dir) |> Filename.concat state_dir in
  let bytes = In_channel.read_all cache_file in
  Out_channel.write_all
    cache_file
    ~data:
      (String.substr_replace_first
         bytes
         ~pattern:"corner unavailable"
         ~with_:"corner tampered");
  rejects (fun () -> load { run with id = "7" });
  rejects (fun () -> Inspection.save ~state_dir ~identity index);
  Inspection.save ~rebuild_invalid:true ~state_dir ~identity index;
  require (load run).cached_unverified "Explicit validated cache rebuild failed";
  root, registered
;;

let handle service root operation =
  Service.handle service ~root ~environment operation
  >>| function
  | Ok snapshot -> snapshot
  | Error error ->
    raise_s [%message "Inspection service request failed" (error : V1.Error.t)]
;;

let cache_descriptor_tests () =
  let root, _, response, parse = fixture () in
  let index = parse response in
  let state_dir = Filename.concat root "descriptor-cache" in
  let identity = "descriptor-budget" in
  Inspection.save ~state_dir ~identity index;
  let path =
    Filename.concat state_dir ("asic-" ^ Public.digest identity ^ "-inspections-v1.sexp")
  in
  let load () =
    Inspection.load
      ~state_dir
      ~identity
      ~run
      ~execution_file:index.execution_file
      ~domain:index.domain
      ~stage:index.stage
  in
  Core_unix.unlink path;
  Core_unix.mkfifo path ~perm:0o600;
  let read = In_thread.run (fun () -> Or_error.try_with load) in
  let%bind () =
    match%bind Clock.with_timeout (Time_float.Span.of_sec 2.) read with
    | `Result result ->
      require
        (match result with
         | Error error ->
           String.is_substring (Error.to_string_hum error) ~substring:"not a regular file"
         | Ok _ -> false)
        "Writerless inspection cache FIFO was not rejected";
      Deferred.unit
    | `Timeout ->
      let%bind () =
        In_thread.run (fun () ->
          let peer = Core_unix.openfile path ~mode:[ O_RDWR; O_NONBLOCK; O_CLOEXEC ] in
          Core_unix.close peer)
      in
      failwith "Inspection cache FIFO open blocked waiting for a writer"
  in
  Core_unix.unlink path;
  let oversized = Filename.concat root "oversized-cache" in
  Out_channel.write_all
    oversized
    ~data:(String.make ((8 * Inspection.index_limit) + 65537) 'x');
  Core_unix.symlink ~target:oversized ~link_name:path;
  let result = Or_error.try_with load in
  require
    (match result with
     | Error error ->
       String.is_substring (Error.to_string_hum error) ~substring:"exceeds byte budget"
     | Ok _ -> false)
    "Oversized opened inspection cache descriptor was accepted";
  Deferred.unit
;;

let settled service root operation =
  let%bind (_ : Asic.Snapshot.t) = handle service root operation in
  let%bind () = Service.completion service in
  handle service root Get
;;

(* Seed a registered execution and derived cache. No provider is configured: even a
   metadata probe would fail, proving cached loads and rendering use no provider. *)
let service_tests () =
  let root, registered, response, parse = fixture () in
  let state_dir = Filename.concat root "cache" in
  let identity =
    Sexp.to_string_mach
      [%sexp
        (root : string)
        , (environment : V1.Environment_selection.t)
        , (None : Hardcaml_workbench_project_integration.Asic_config.t option)]
  in
  let index = parse response in
  let index =
    { index with
      times =
        { index.times with
          production =
            [ ( "opensta"
              , Supplied
                  { at =
                      Timestamp.of_time_ns
                        (Time_ns.of_string_with_utc_offset "1850-01-01T00:00:00Z")
                  } )
            ]
        }
    }
    |> Inspection.observe_times
         ~execution_file:index.execution_file
         ~validated_at:
           (Timestamp.of_time_ns
              (Time_ns.of_string_with_utc_offset "2026-10-19T15:30:00Z"))
  in
  Inspection.save ~state_dir ~identity index;
  let registry =
    Sexp.List
      [ [%sexp "version", (1 : int)]
      ; [%sexp "identity", (identity : string)]
      ; [%sexp "runs", ([ registered ] : Asic.Run.t list)]
      ; [%sexp "submissions", ([] : (string * Asic.Preview.t * string option) list)]
      ; [%sexp "index", ([] : (string * string) list)]
      ]
  in
  Out_channel.write_all
    (Filename.concat state_dir ("asic-" ^ Public.digest identity ^ ".sexp"))
    ~data:(Sexp.to_string_mach registry);
  Core_unix.unlink index.execution_file;
  let service = Service.create ~state_dir in
  let%bind snapshot = handle service root Get in
  require (List.is_empty snapshot.inspections) "Rendering implicitly loaded rich indexes";
  let request refresh =
    Asic.Operation.Inspect { run; domain = "timing"; stage = "routing"; refresh }
  in
  let%bind snapshot = settled service root (request false) in
  require
    ((List.hd_exn snapshot.inspections).cached_unverified
     && List.for_all snapshot.operations ~f:(fun pending ->
       String.equal pending.state "completed"))
    "Warm cached load invoked provider or failed";
  let%bind snapshot = settled service root (request true) in
  require
    (List.exists snapshot.operations ~f:(fun pending ->
       String.equal pending.kind "inspection"
       && String.equal pending.state "failed"
       && Option.is_some pending.error))
    "Explicit missing provider/source was not a read error";
  let%bind snapshot =
    settled
      service
      root
      (Inspect_detail
         { run
         ; domain = "timing"
         ; stage = "routing"
         ; source_digest = digest
         ; row_id = "path-1"
         })
  in
  require
    (Option.is_some (List.hd_exn snapshot.inspection_details).error)
    "Detail failure was not exposed";
  let%bind () =
    Deferred.List.iter (List.init 9 ~f:Int.to_string) ~how:`Sequential ~f:(fun row_id ->
      let%map (_ : Asic.Snapshot.t) =
        settled
          service
          root
          (Inspect_detail
             { run; domain = "timing"; stage = "routing"; source_digest = digest; row_id })
      in
      ())
  in
  let%bind snapshot = handle service root Get in
  require (List.length snapshot.inspection_details = 8) "Ephemeral detail budget exceeded";
  let%bind () = Service.shutdown service in
  let restarted = Service.create ~state_dir in
  let%bind snapshot = settled restarted root (request false) in
  require (List.hd_exn snapshot.inspections).cached_unverified "Restart freshness lost";
  require
    (Evidence_time.Index.equal (List.hd_exn snapshot.inspections).times index.times)
    "Service restart changed production, validation or filesystem observation times";
  let cache_file =
    Filename.concat state_dir ("asic-" ^ Public.digest identity ^ "-inspections-v1.sexp")
  in
  Core_unix.unlink cache_file;
  let%bind snapshot = settled restarted root (request false) in
  require
    (List.for_all snapshot.operations ~f:(fun pending ->
       String.equal pending.state "completed"))
    "Warm L1 load attempted provider after L2 eviction";
  let%bind () = Service.shutdown restarted in
  let cold = Service.create ~state_dir in
  let%bind snapshot = handle cold root Get in
  require
    (List.is_empty snapshot.inspections && List.is_empty snapshot.operations)
    "Rendering a cold run implicitly requested inspection";
  let%bind snapshot = settled cold root (request false) in
  require
    (List.exists snapshot.operations ~f:(fun pending ->
       String.equal pending.kind "inspection"
       && String.equal pending.state "failed"
       && Option.value_map pending.error ~default:false ~f:(fun error ->
         String.is_substring error ~substring:"Project has no ASIC configuration")))
    "Cold explicit Inspect did not fall back to provider validation";
  Service.shutdown cold
;;

let observation_generation_tests () =
  let module Config = Hardcaml_workbench_project_integration.Asic_config in
  let root, registered, response, _ = fixture () in
  let response =
    replace
      response
      "rows"
      (`List (List.init 12 ~f:(fun i -> row (sprintf "path-%d" (i + 1)) `Null)))
  in
  let file name = Filename.concat root name in
  let executable = file "fixture-provider" in
  Out_channel.write_all executable ~data:(In_channel.read_all "inspection_provider.py");
  Core_unix.chmod executable ~perm:0o700;
  let config : Config.t =
    { schema_version = 1
    ; project_executable = executable
    ; provider_executable = executable
    ; results_root = file "results"
    ; toolchain = file "toolchain"
    ; python = None
    ; support_tools = None
    ; pdk_root = None
    ; stage_timeout_seconds = None
    }
  in
  Out_channel.write_all
    (file Config.filename)
    ~data:(Sexp.to_string_mach (Config.sexp_of_t config));
  Out_channel.write_all (file "response.json") ~data:(Yojson.Safe.to_string response);
  let set_cursor cursor =
    Out_channel.write_all (file "cursor") ~data:(Int.to_string cursor)
  in
  set_cursor registered.cursor;
  let identity =
    Sexp.to_string_mach
      [%sexp
        (root : string)
        , (environment : V1.Environment_selection.t)
        , (Some config : Config.t option)]
  in
  let state_dir = file "cache" in
  Core_unix.mkdir_p state_dir ~perm:0o700;
  let registry =
    Sexp.List
      [ [%sexp "version", (1 : int)]
      ; [%sexp "identity", (identity : string)]
      ; [%sexp "runs", ([ registered ] : Asic.Run.t list)]
      ; [%sexp "submissions", ([] : (string * Asic.Preview.t * string option) list)]
      ; [%sexp "index", ([] : (string * string) list)]
      ]
  in
  Out_channel.write_all
    (Filename.concat state_dir ("asic-" ^ Public.digest identity ^ ".sexp"))
    ~data:(Sexp.to_string_mach registry);
  let service = Service.create ~state_dir in
  let inspect refresh =
    Asic.Operation.Inspect { run; domain = "timing"; stage = "routing"; refresh }
  in
  let detail =
    Asic.Operation.Inspect_detail
      { run
      ; domain = "timing"
      ; stage = "routing"
      ; source_digest = digest
      ; row_id = "path-1"
      }
  in
  let detail_for row_id =
    Asic.Operation.Inspect_detail
      { run; domain = "timing"; stage = "routing"; source_digest = digest; row_id }
  in
  let inspection_calls () =
    In_channel.read_lines (file "inspection-calls")
    |> List.count ~f:(fun line ->
      match Public.decode line with
      | `List (`String "inspect" :: _) -> true
      | _ -> false)
  in
  let wait_until description predicate =
    let rec loop () =
      let%bind ready = predicate () in
      if ready
      then Deferred.unit
      else (
        let%bind () = Clock.after (Time_float.Span.of_sec 0.01) in
        loop ())
    in
    match%map Clock.with_timeout (Time_float.Span.of_sec 5.) (loop ()) with
    | `Result () -> ()
    | `Timeout -> failwith ("Timed out: " ^ description)
  in
  let observe_cursor cursor =
    set_cursor cursor;
    let%bind (_ : Asic.Snapshot.t) = handle service root (Observe run) in
    wait_until "observation cursor publication" (fun () ->
      let%map snapshot = handle service root Get in
      List.exists snapshot.runs ~f:(fun current ->
        Run_ref.equal current.run run && current.cursor = cursor))
  in
  let assert_invalidated (snapshot : Asic.Snapshot.t) =
    require
      (List.hd_exn snapshot.inspections).cached_unverified
      "Same-path cursor advance left a validated rich index";
    require
      (List.is_empty snapshot.inspection_details)
      "Same-path cursor advance retained old row details"
  in
  let hold kind =
    let started = file ("started-" ^ kind) in
    if Poly.equal (Sys_unix.file_exists started) `Yes then Core_unix.unlink started;
    Out_channel.write_all (file ("hold-" ^ kind)) ~data:"hold"
  in
  let wait_started kind =
    wait_until (kind ^ " query start") (fun () ->
      return (Poly.equal (Sys_unix.file_exists (file ("started-" ^ kind))) `Yes))
  in
  let release kind = Core_unix.unlink (file ("hold-" ^ kind)) in
  let index_key = Asic_inspection.index_key ~run ~domain:"timing" ~stage:"routing" in
  let pending (snapshot : Asic.Snapshot.t) =
    List.find_exn snapshot.operations ~f:(fun p -> String.equal p.key index_key)
  in
  let current (snapshot : Asic.Snapshot.t) = List.hd_exn snapshot.inspections in
  let successful_detail (snapshot : Asic.Snapshot.t) =
    let value = List.hd_exn snapshot.inspection_details in
    require (Option.is_none value.error) "Expected successful detail";
    value
  in
  let cache_tests () =
    let calls = inspection_calls () in
    (* A successful hit must work even when the execution file is absent. This also
       catches an accidental hash read before the reusable-cache lookup. *)
    let execution_file = Option.value_exn registered.execution_file in
    let bytes = In_channel.read_all execution_file in
    Core_unix.unlink execution_file;
    let%bind snapshot =
      Monitor.protect
        ~finally:(fun () ->
          Out_channel.write_all execution_file ~data:bytes;
          Deferred.unit)
        (fun () -> settled service root detail)
    in
    ignore (successful_detail snapshot : Asic_inspection.Detail.t);
    require (inspection_calls () = calls) "Successful detail hit queried provider";
    require
      (List.exists snapshot.operations ~f:(fun op ->
         String.equal op.kind "inspection-detail"
         && String.equal op.state "completed"
         && Asic.Pending.Activity.equal op.activity Evidence_cache_lookup))
      "Successful hit was not reported as a cache lookup";
    let%bind () =
      Deferred.List.iter
        (List.init 9 ~f:(fun i -> sprintf "path-%d" (i + 2)))
        ~how:`Sequential
        ~f:(fun row_id ->
          let%map snapshot = settled service root (detail_for row_id) in
          ignore (successful_detail snapshot : Asic_inspection.Detail.t);
          require
            (List.length snapshot.inspection_details <= 8)
            "Snapshot detail bound exceeded")
    in
    let%bind snapshot = handle service root Get in
    require
      (not
         (List.exists snapshot.inspection_details ~f:(fun d ->
            String.equal d.row_id "path-1")))
      "Expected first detail to leave the publication window";
    let calls = inspection_calls () in
    let%bind snapshot = settled service root detail in
    require (inspection_calls () = calls) "Snapshot eviction discarded reusable detail";
    require
      (String.equal (successful_detail snapshot).row_id "path-1")
      "Hit did not republish detail";
    (* Concurrent identical misses share one held provider read. *)
    hold "detail";
    let calls = inspection_calls () in
    let%bind (_ : Asic.Snapshot.t) = handle service root (detail_for "path-11") in
    let%bind () = wait_started "detail" in
    let%bind () =
      Deferred.List.iter (List.init 3 ~f:Fn.id) ~how:`Sequential ~f:(fun _ ->
        let%map (_ : Asic.Snapshot.t) = handle service root (detail_for "path-11") in
        ())
    in
    require
      (inspection_calls () = calls + 1)
      "Concurrent detail requests were not coalesced";
    release "detail";
    let%bind () = Service.completion service in
    hold "detail";
    let%bind (_ : Asic.Snapshot.t) = handle service root (detail_for "path-12") in
    let%bind () = wait_started "detail" in
    let key =
      Asic_inspection.detail_key
        ~run
        ~domain:"timing"
        ~stage:"routing"
        ~source_digest:digest
        ~row_id:"path-12"
    in
    let%bind (_ : Asic.Snapshot.t) = handle service root (Cancel key) in
    release "detail";
    let%bind () = Service.completion service in
    let calls = inspection_calls () in
    let%bind snapshot = settled service root (detail_for "path-12") in
    ignore (successful_detail snapshot : Asic_inspection.Detail.t);
    require
      (inspection_calls () = calls + 1)
      "Cancelled detail was retained or could not retry";
    (* Same digest, changed row content invalidates both reuse and publications. *)
    let changed =
      replace
        response
        "rows"
        (`List [ replace (row "path-1" `Null) "name" (str "changed endpoint") ])
    in
    Out_channel.write_all (file "response.json") ~data:(Yojson.Safe.to_string changed);
    let%bind snapshot = settled service root (inspect true) in
    require
      (List.is_empty snapshot.inspection_details)
      "Changed rows retained old publication";
    let calls = inspection_calls () in
    let%bind snapshot = settled service root (detail_for "path-2") in
    require
      (inspection_calls () = calls
       && Option.is_some (List.hd_exn snapshot.inspection_details).error)
      "Removed row reused stale detail or queried provider";
    let calls = inspection_calls () in
    let%bind snapshot = settled service root detail in
    ignore (successful_detail snapshot : Asic_inspection.Detail.t);
    require
      (inspection_calls () = calls + 1)
      "Same-digest row replacement reused old detail";
    (* Same digest/row, changed execution SHA also invalidates reuse. *)
    Out_channel.write_all execution_file ~data:(bytes ^ " ");
    let sha = Inspection.execution_hash ~registered ~execution_file in
    let changed = replace changed "execution_sha256" (str sha) in
    Out_channel.write_all (file "response.json") ~data:(Yojson.Safe.to_string changed);
    let%bind snapshot = settled service root (inspect true) in
    require
      (List.is_empty snapshot.inspection_details)
      "Changed execution SHA retained old publication";
    let calls = inspection_calls () in
    let%bind snapshot = settled service root detail in
    ignore (successful_detail snapshot : Asic_inspection.Detail.t);
    require (inspection_calls () = calls + 1) "Changed execution SHA reused old detail";
    Out_channel.write_all execution_file ~data:bytes;
    Out_channel.write_all (file "response.json") ~data:(Yojson.Safe.to_string response);
    let%bind (_ : Asic.Snapshot.t) = settled service root (inspect true) in
    (* A failed miss is never retained: repairing provider evidence permits retry. *)
    Out_channel.write_all
      (file "response.json")
      ~data:
        (Yojson.Safe.to_string
           (replace response "source_digest" (str (String.make 64 'c'))));
    let%bind snapshot = settled service root detail in
    require
      (Option.is_some (List.hd_exn snapshot.inspection_details).error)
      "Expected failed detail";
    Out_channel.write_all (file "response.json") ~data:(Yojson.Safe.to_string response);
    let calls = inspection_calls () in
    let%bind snapshot = settled service root detail in
    let value = successful_detail snapshot in
    require (inspection_calls () = calls + 1) "Failed detail prevented explicit retry";
    (* Source replacement rejects requests naming the old digest before lookup. *)
    let replacement_digest = String.make 64 'd' in
    Out_channel.write_all
      (file "response.json")
      ~data:
        (Yojson.Safe.to_string
           (replace response "source_digest" (str replacement_digest)));
    let%bind snapshot = settled service root (inspect true) in
    require
      (List.is_empty snapshot.inspection_details)
      "Source replacement retained publications";
    let calls = inspection_calls () in
    let%bind snapshot = settled service root detail in
    require
      (inspection_calls () = calls
       && Option.is_some (List.hd_exn snapshot.inspection_details).error)
      "Old source digest crossed cache fence";
    let%bind snapshot =
      settled
        service
        root
        (Inspect_detail
           { run
           ; domain = "timing"
           ; stage = "routing"
           ; source_digest = replacement_digest
           ; row_id = "path-1"
           })
    in
    ignore (successful_detail snapshot : Asic_inspection.Detail.t);
    require (inspection_calls () = calls + 1) "Replacement source reused old detail";
    Out_channel.write_all (file "response.json") ~data:(Yojson.Safe.to_string response);
    let%bind (_ : Asic.Snapshot.t) = settled service root (inspect true) in
    let payload_bytes =
      String.length (Sexp.to_string_mach (Asic_inspection.Detail.sexp_of_t value))
    in
    (* Exercise daemon policy at the service boundary as well as the LRU itself. *)
    Deferred.List.iter
      [ 2, 4194304, 4
      ; 64, payload_bytes * 2, 4
      ; 0, 4194304, 5
      ; 64, 0, 5
      ; 64, payload_bytes - 1, 5
      ]
      ~how:`Sequential
      ~f:(fun (entries, bytes, expected_calls) ->
        let limited =
          Service.create_with_detail_cache
            ~state_dir
            ~inspection_detail_cache_entries:entries
            ~inspection_detail_cache_bytes:bytes
            ()
        in
        Monitor.protect
          ~finally:(fun () -> Service.shutdown limited)
          (fun () ->
            let%bind (_ : Asic.Snapshot.t) = settled limited root (inspect false) in
            let calls = inspection_calls () in
            let%bind () =
              Deferred.List.iter
                [ "path-1"; "path-2"; "path-1"; "path-3"; "path-2" ]
                ~how:`Sequential
                ~f:(fun row_id ->
                  let%map snapshot = settled limited root (detail_for row_id) in
                  ignore (successful_detail snapshot : Asic_inspection.Detail.t))
            in
            require
              (inspection_calls () = calls + expected_calls)
              (sprintf "Incorrect detail LRU limits: entries=%d bytes=%d" entries bytes);
            Deferred.unit))
  in
  let index_eviction_tests () =
    let contexts =
      List.cartesian_product
        [ "timing"; "clocks" ]
        [ "synthesis"; "floorplan"; "placement"; "cts"; "signoff" ]
      |> Fn.flip List.take 9
    in
    let%bind () =
      Deferred.List.iter contexts ~how:`Sequential ~f:(fun (domain, stage) ->
        let source =
          replace (replace response "domain" (str domain)) "stage" (str stage)
        in
        Out_channel.write_all (file "response.json") ~data:(Yojson.Safe.to_string source);
        let%bind (_ : Asic.Snapshot.t) =
          settled service root (Inspect { run; domain; stage; refresh = true })
        in
        let calls = inspection_calls () in
        let%map snapshot =
          settled
            service
            root
            (Inspect_detail
               { run; domain; stage; source_digest = digest; row_id = "path-1" })
        in
        ignore (successful_detail snapshot : Asic_inspection.Detail.t);
        require
          (inspection_calls () = calls + 1)
          "Detail cache crossed domain/stage identity";
        require
          (List.length snapshot.inspections <= 8
           && List.length snapshot.inspection_details <= 8)
          "Inspection publication window exceeded eight")
    in
    let calls = inspection_calls () in
    let%bind snapshot = settled service root detail in
    require
      (inspection_calls () = calls
       && Option.is_some (List.hd_exn snapshot.inspection_details).error)
      "Detail hit bypassed missing current index";
    Out_channel.write_all (file "response.json") ~data:(Yojson.Safe.to_string response);
    let%bind (_ : Asic.Snapshot.t) = settled service root (inspect true) in
    let calls = inspection_calls () in
    let%map snapshot = settled service root detail in
    ignore (successful_detail snapshot : Asic_inspection.Detail.t);
    require (inspection_calls () = calls + 1) "Index eviction retained reusable details"
  in
  (* WB-003 #1/#2 and WB-006 #1/#2 against the daemon: a held explicit refresh reports an
     evidence read for its whole duration; refreshing unchanged bytes moves only the
     validation time; a warm reopen reports only a cache lookup and calls no provider. *)
  let activity_and_time_tests () =
    let%bind before = handle service root Get in
    let before = current before in
    require
      (List.is_empty before.times.production
       && Evidence_time.Production.equal
            (Evidence_time.Index.production before.times ~producer:"opensta")
            Unknown)
      "Missing production time was not unknown";
    require
      (Option.is_some (Evidence_time.Index.validated before.times)
       && Option.exists
            (Evidence_time.Index.file_modified before.times)
            ~f:(fun (path, _) -> String.equal path before.execution_file))
      "Provider-validated index lacks its observation times";
    let%bind () = Clock.after (Time_float.Span.of_ms 5.) in
    hold "index";
    let%bind (_ : Asic.Snapshot.t) = handle service root (inspect true) in
    let%bind () = wait_started "index" in
    let%bind () =
      Deferred.List.iter (List.init 3 ~f:Fn.id) ~how:`Sequential ~f:(fun _ ->
        let%bind snapshot = handle service root Get in
        let op = pending snapshot in
        require
          (String.equal op.state "executing"
           && Asic.Pending.Activity.equal op.activity Evidence_read)
          "Held explicit refresh did not report an evidence read";
        require
          (current snapshot).cached_unverified
          "Prior evidence kept a validated label while its refresh was pending";
        Clock.after (Time_float.Span.of_ms 20.))
    in
    release "index";
    let%bind () = Service.completion service in
    let%bind snapshot = handle service root Get in
    let after = current snapshot in
    require
      (String.equal (pending snapshot).state "completed" && not after.cached_unverified)
      "Released refresh did not complete";
    require
      (Asic_inspection.Index.equal
         { after with times = Evidence_time.Index.empty }
         { before with times = Evidence_time.Index.empty }
       && List.equal
            (Tuple2.equal ~eq1:String.equal ~eq2:Evidence_time.Production.equal)
            after.times.production
            before.times.production
       && Option.equal
            (Tuple2.equal ~eq1:String.equal ~eq2:Timestamp.equal)
            (Evidence_time.Index.file_modified after.times)
            (Evidence_time.Index.file_modified before.times))
      "Refreshing unchanged evidence changed more than its validation time";
    require
      (match
         ( Evidence_time.Index.validated before.times
         , Evidence_time.Index.validated after.times )
       with
       | Some old, Some fresh -> Timestamp.compare fresh old > 0
       | _ -> false)
      "Refresh did not move the validation time";
    let calls = inspection_calls () in
    let%bind reopened = handle service root (inspect false) in
    require
      (not (Asic.Pending.Activity.equal (pending reopened).activity Evidence_read))
      "Warm reopen claimed a provider read";
    let%bind () = Service.completion service in
    let%map reopened = handle service root Get in
    require (inspection_calls () = calls) "Warm reopen queried the provider";
    require
      (Asic.Pending.Activity.equal (pending reopened).activity Evidence_cache_lookup
       && String.equal (pending reopened).state "completed")
      "Warm reopen was not reported as a cache lookup"
  in
  Monitor.protect
    ~finally:(fun () ->
      List.iter [ "index"; "detail" ] ~f:(fun kind ->
        let path = file ("hold-" ^ kind) in
        if Poly.equal (Sys_unix.file_exists path) `Yes then Core_unix.unlink path);
      Service.shutdown service)
    (fun () ->
      let%bind snapshot = settled service root (inspect true) in
      require
        (not (List.hd_exn snapshot.inspections).cached_unverified)
        "Fresh inspection was not validated";
      let%bind snapshot = settled service root detail in
      require
        (String.equal
           (List.hd_exn snapshot.inspection_details).text
           "verified path detail")
        "Initial validated detail was not published";
      let%bind () = activity_and_time_tests () in
      let%bind () = cache_tests () in
      let%bind () = index_eviction_tests () in
      let calls = inspection_calls () in
      let%bind () = observe_cursor 2 in
      let%bind snapshot = handle service root Get in
      assert_invalidated snapshot;
      require
        (inspection_calls () = calls)
        "Observation implicitly queried rich inspection";
      let%bind snapshot = settled service root (inspect false) in
      assert_invalidated snapshot;
      require
        (inspection_calls () = calls)
        "Unverified offline index unexpectedly queried provider";
      let%bind snapshot = settled service root (inspect true) in
      require
        (not (List.hd_exn snapshot.inspections).cached_unverified)
        "Explicit refresh did not revalidate index after cursor advance";
      let calls = inspection_calls () in
      let%bind snapshot = settled service root detail in
      ignore (successful_detail snapshot : Asic_inspection.Detail.t);
      require (inspection_calls () = calls + 1) "Cursor advance retained reusable detail";
      hold "index";
      let%bind (_ : Asic.Snapshot.t) = handle service root (inspect true) in
      let%bind () = wait_started "index" in
      let%bind () = observe_cursor 3 in
      let%bind snapshot = handle service root Get in
      assert_invalidated snapshot;
      release "index";
      let%bind () = Service.completion service in
      let%bind snapshot = handle service root Get in
      assert_invalidated snapshot;
      require
        (List.exists snapshot.operations ~f:(fun pending ->
           String.equal pending.kind "inspection" && String.equal pending.state "failed"))
        "In-flight index crossed a same-path cursor fence";
      let%bind (_ : Asic.Snapshot.t) = settled service root (inspect true) in
      hold "detail";
      let%bind (_ : Asic.Snapshot.t) = handle service root detail in
      let%bind () = wait_started "detail" in
      let%bind () = observe_cursor 4 in
      let%bind snapshot = handle service root Get in
      assert_invalidated snapshot;
      release "detail";
      let%bind () = Service.completion service in
      let%bind snapshot = handle service root Get in
      require
        (List.hd_exn snapshot.inspections).cached_unverified
        "Stale detail revalidated an old index";
      require
        (List.for_all snapshot.inspection_details ~f:(fun detail ->
           Option.is_some detail.error && String.is_empty detail.text))
        "In-flight detail crossed a same-path cursor fence";
      require
        (List.exists snapshot.operations ~f:(fun pending ->
           String.equal pending.kind "inspection-detail"
           && String.equal pending.state "failed"))
        "Stale in-flight detail did not report failure";
      let%bind (_ : Asic.Snapshot.t) = settled service root (inspect true) in
      let calls = inspection_calls () in
      let%bind snapshot = settled service root detail in
      ignore (successful_detail snapshot : Asic_inspection.Detail.t);
      require (inspection_calls () = calls + 1) "Held stale load populated reusable cache";
      (* Execution-file replacement at an unchanged cursor is an independent fence. *)
      let execution_file = file "replacement-execution.json" in
      Out_channel.write_all
        execution_file
        ~data:(In_channel.read_all (Option.value_exn registered.execution_file));
      Out_channel.write_all (file "observed-execution") ~data:execution_file;
      let%bind snapshot = settled service root (Observe run) in
      require
        (List.is_empty snapshot.inspections && List.is_empty snapshot.inspection_details)
        "Execution-file replacement retained rich evidence";
      let calls = inspection_calls () in
      let%bind snapshot = settled service root detail in
      require
        (inspection_calls () = calls
         && Option.is_some (List.hd_exn snapshot.inspection_details).error)
        "Execution-file replacement reused detail without a current index";
      Out_channel.write_all
        (file "response.json")
        ~data:
          (Yojson.Safe.to_string (replace response "execution_file" (str execution_file)));
      let%bind (_ : Asic.Snapshot.t) = settled service root (inspect true) in
      let calls = inspection_calls () in
      let%map snapshot = settled service root detail in
      ignore (successful_detail snapshot : Asic_inspection.Detail.t);
      require
        (inspection_calls () = calls + 1)
        "Execution-file replacement retained reusable cache")
;;

let main () =
  List.iter
    [ -1, 1; 4097, 1; 1, -1; 1, 268435457 ]
    ~f:(fun (entries, bytes) ->
      rejects (fun () ->
        Service.create_with_detail_cache
          ~state_dir:"/unused"
          ~inspection_detail_cache_entries:entries
          ~inspection_detail_cache_bytes:bytes
          ()));
  List.iter
    [ 0, 0; 4096, 268435456; 64, 4194304 ]
    ~f:(fun (entries, bytes) ->
      ignore
        (Service.create_with_detail_cache
           ~state_dir:"/unused"
           ~inspection_detail_cache_entries:entries
           ~inspection_detail_cache_bytes:bytes
           ()
         : Service.t));
  parser_tests ();
  ignore (cache_tests () : string * Asic.Run.t);
  let%bind () = cache_descriptor_tests () in
  let%bind () = service_tests () in
  observation_generation_tests ()
;;

let () =
  don't_wait_for (main () >>= fun () -> Shutdown.exit 0);
  never_returns (Scheduler.go ())
;;
