open! Core
open! Async
module Inspection = Asic_inspection
open Hardcaml_workbench_protocol
module Inspection_wire = Hardcaml_workbench_protocol.Asic_inspection
module Config = Hardcaml_workbench_project_integration.Asic_config
module Adapter = Hardcaml_workbench_adapters.Asic_adapter
module Public = Asic_public

let failure_message exn = Exn.to_string (Monitor.extract_exn exn)

module Finalization_stored = struct
  type t =
    { value : Asic.Finalization.t
    ; acceptance : Asic.Acceptance.t option
    ; execution_hash : string option
    ; operation_id : string option
    ; producer_error : string option [@sexp.default None]
    ; observation_error : string option [@sexp.default None]
    }
  [@@deriving sexp]
end

let with_finalization_errors
  (f : Finalization_stored.t)
  ~producer_error
  ~observation_error
  =
  let error =
    match producer_error, observation_error with
    | None, error | error, None -> error
    | Some producer, Some observation ->
      Some
        (if String.equal producer observation
         then producer
         else producer ^ "; " ^ observation)
  in
  { f with producer_error; observation_error; value = { f.value with error } }
;;

module Stored = struct
  type t =
    { version : int
    ; identity : string
    ; runs : Asic.Run.t list
    ; submissions : (string * Asic.Preview.t * string option) list
    ; index : (string * string) list
    ; terminal_attempts : (string * string) list [@sexp.default []]
    ; finalizations : Finalization_stored.t list [@sexp.default []]
    ; stage_starts : (string * (string * Timestamp.t) list) list [@sexp.default []]
    ; workflows : Asic.Fresh.Workflow.t list [@sexp.default []]
    }
  [@@deriving sexp]
end

module Summary_blob = struct
  type t =
    { version : int
    ; normalized_digest : string
    ; summary : Asic.Summary.t
    }
  [@@deriving sexp]
end

(* Schema-1 analysis metadata is bounded at 1MiB; the typed metric provenance and sexp
   escaping also occupy space. Keep the complete observation within one blob. *)
let summary_limit = 4 * 1024 * 1024

let summary_digest summary =
  Public.digest (Sexp.to_string_mach (Asic.Summary.sexp_of_t summary))
;;

(* v1 predates metrics; v2 predates terminal results. Reconstruct each version's exact
   canonical record shape after decoding with defaults. Keeping the blob path namespace
   permits old L2 entries to reopen without IO to the provider. Absent terminal evidence
   requires explicit adoption. *)
let decode_summary_blob sexp =
  let blob = Summary_blob.t_of_sexp sexp in
  let valid =
    match blob.version with
    | 3 | 4 | 5 -> String.equal blob.normalized_digest (summary_digest blob.summary)
    | (1 | 2) as version ->
      let legacy =
        match Asic.Summary.sexp_of_t blob.summary with
        | Sexp.List fields ->
          Sexp.List
            (List.filter fields ~f:(function
              | Sexp.List (Sexp.Atom "metrics" :: _) when version = 1 -> false
              | Sexp.List (Sexp.Atom "terminal" :: _) -> false
              | _ -> true))
        | _ -> failwith "Expected summary record"
      in
      (version <> 1 || List.is_empty blob.summary.metrics)
      && Option.is_none blob.summary.terminal
      && String.equal blob.normalized_digest (Public.digest (Sexp.to_string_mach legacy))
    | _ -> false
  in
  Public.require valid "Corrupt/incompatible normalized summary";
  Public.require
    (blob.version >= 5 || Option.is_none blob.summary.timing_analysis)
    "Timing analysis requires summary cache version 5";
  Option.iter
    blob.summary.timing_analysis
    ~f:(Asic_timing_analysis.validate_cached ~execution_file:blob.summary.execution_file);
  Public.require (List.length blob.summary.metrics <= 64) "Metric cache exceeds budget";
  Option.iter blob.summary.terminal ~f:(fun terminal ->
    Public.require
      (List.length terminal.metrics <= 64
       && List.length terminal.checks <= 64
       && String.length terminal.evidence <= 160 * 1024)
      "Terminal cache exceeds budget");
  let summary = blob.summary in
  (* Before v4 the last checkpoint was projected as synthesis, even for physical
     executions. Keep old caches readable but never relabel routing evidence. A refresh
     recovers explicit synthesis evidence from the full public report. *)
  let explicit_synthesis =
    Or_error.try_with (fun () ->
      Poly.equal
        (Public.field
           "boundary"
           (Public.field "reference" (Public.decode summary.producer)))
        (`String "synthesis"))
    |> Result.ok
    |> Option.value ~default:false
  in
  if blob.version < 4 && not explicit_synthesis
  then
    { summary with
      cell_count = None
    ; cells = []
    ; metrics = []
    ; producer = "no synthesis checkpoint in legacy projection"
    }
  else summary
;;

type task =
  { cancel : unit Ivar.t
  ; mutable pending : Asic.Pending.t
  ; mutable completion : unit Deferred.t
  }

type reservation =
  { preview : Asic.Preview.t
  ; result : (unit, exn) Result.t Deferred.t
  }

type project =
  { root : string
  ; environment : V1.Environment_selection.t
  ; config : Config.t option
  ; identity : string
  ; mutable runs : Asic.Run.t list
  ; mutable submissions : (string * Asic.Preview.t * string option) list
  ; mutable index : (string * string) list
  ; mutable terminal_attempts : (string * string) list
  ; mutable finalizations : Finalization_stored.t list
  ; mutable stage_starts : (string * (string * Timestamp.t) list) list
  ; mutable artifacts : Asic_artifact.Reference.t list
  ; mutable artifact_pages : Asic_artifact.Page.t list
  ; mutable artifact_byte_pages : Asic_artifact.Byte_page.t list
  ; mutable inspections : Inspection_wire.Index.t list
  ; mutable inspection_details : Inspection_wire.Detail.t list
  ; resources : Asic_resources_service.t
  ; resource_refreshes : bool ref String.Table.t
  ; workloads : Asic_workloads_service.t
  ; workload_refreshes : bool ref String.Table.t
  ; detail_cache : Inspection_detail_cache.t
  ; inspection_refreshes : bool ref String.Table.t
  ; hot : Asic.Summary.t String.Table.t
  ; mutable recency : string list
  ; tasks : task String.Table.t
  ; reservations : reservation String.Table.t
  ; mutable flows : Asic.Flow.t list
  ; mutable catalog_default : Asic.Flow_default.t option
  ; mutable description : string option
  ; mutable preview : Asic.Preview.t option
  ; mutable desired_plan : Asic.Selection.t option
  ; mutable desired_description : string option
  ; read_tails : unit Deferred.t String.Table.t
  ; mutable provider_check : (unit, exn) Result.t Deferred.t option
  ; mutable timing_stage : bool
  ; mutable cache_error : string option
  ; mutable registry_writable : bool
  ; mutable save_tail : unit Deferred.t
  ; mutable fresh_intent : Asic.Fresh.Intent.t option
  ; mutable fresh_generation : int
  ; mutable workflows : Asic.Fresh.Workflow.t list
  ; workflow_reservations : (unit, exn) Result.t Deferred.t String.Table.t
  }

type preparation_runner =
  root:string
  -> environment:V1.Environment_selection.t
  -> unique:bool
  -> cancelled:(unit -> bool)
  -> Preparation.Operation.t
  -> Preparation.Response.t Deferred.t

type t =
  { state_dir : string
  ; inspection_detail_cache_entries : int
  ; inspection_detail_cache_bytes : int
  ; projects : (project, exn) Result.t Deferred.t String.Table.t
  ; queries : unit Throttle.t
  ; executions : unit Throttle.t
  ; mutable closing : bool
  ; mutable preparation_runner : preparation_runner option
  }

let create_with_detail_cache
  ?(inspection_detail_cache_entries = 64)
  ?(inspection_detail_cache_bytes = 4194304)
  ~state_dir
  ()
  =
  Inspection_detail_cache.validate_limits
    ~entries:inspection_detail_cache_entries
    ~bytes:inspection_detail_cache_bytes;
  { state_dir
  ; inspection_detail_cache_entries
  ; inspection_detail_cache_bytes
  ; projects = String.Table.create ()
  ; queries = Throttle.create ~continue_on_error:true ~max_concurrent_jobs:4
  ; executions = Throttle.create ~continue_on_error:true ~max_concurrent_jobs:1
  ; closing = false
  ; preparation_runner = None
  }
;;

let create ~state_dir = create_with_detail_cache ~state_dir ()
let set_preparation_runner t runner = t.preparation_runner <- Some runner

let path t identity suffix =
  Filename.concat t.state_dir ("asic-" ^ Public.digest identity ^ suffix)
;;

let registry_path t p = path t p.identity ".sexp"
let summary_prefix p = "asic-" ^ Public.digest p.identity ^ "-summary-v1-"

let summary_path t p digest =
  Filename.concat t.state_dir (summary_prefix p ^ Public.digest digest ^ ".summary.sexp")
;;

let atomic_write t filename data =
  Core_unix.mkdir_p t.state_dir ~perm:0o700;
  let temporary = Filename_unix.temp_file ~in_dir:t.state_dir ".asic-" ".tmp" in
  Exn.protect
    ~finally:(fun () ->
      if Poly.equal (Sys_unix.file_exists temporary) `Yes then Core_unix.unlink temporary)
    ~f:(fun () ->
      Out_channel.write_all temporary ~data;
      Core_unix.rename ~src:temporary ~dst:filename)
;;

let read_bounded filename limit =
  let stat = Core_unix.stat filename in
  if Int64.(stat.st_size > of_int limit) then failwith "ASIC cache file exceeds budget";
  In_channel.read_all filename
;;

let read_public_bounded = Asic_evidence_file.read_bounded

let save_registry ?reservation t p =
  let previous = p.save_tail in
  let outcome =
    let%bind () = previous in
    Monitor.try_with (fun () ->
      Public.require
        p.registry_writable
        "ASIC registry is corrupt/incompatible; cannot save submissions";
      (* Capture at execution time, not enqueue time: earlier queued writes may commit new
         reservations while we wait for the single registry writer. *)
      let submissions =
        match reservation with
        | None -> p.submissions
        | Some (key, (preview : Asic.Preview.t)) ->
          Public.require
            (List.length p.submissions < 256)
            "ASIC submission budget exhausted";
          Public.require
            (String.length preview.plan_json <= 256 * 1024
             && List.sum (module Int) p.submissions ~f:(fun (_, p, _) ->
                  String.length p.Asic.Preview.plan_json)
                + String.length preview.plan_json
                < 3 * 1024 * 1024)
            "ASIC retained preview budget exhausted";
          (key, preview, None) :: p.submissions
      in
      let stored : Stored.t =
        { version = 1
        ; identity = p.identity
        ; runs = p.runs
        ; submissions
        ; index = p.index
        ; terminal_attempts = p.terminal_attempts
        ; finalizations = p.finalizations
        ; stage_starts = p.stage_starts
        ; workflows = p.workflows
        }
      in
      let data = Sexp.to_string (Stored.sexp_of_t stored) in
      Public.require
        (String.length data <= 4 * 1024 * 1024)
        "ASIC registry exceeds byte budget";
      let%map () = In_thread.run (fun () -> atomic_write t (registry_path t p) data) in
      (* No uncommitted key is ever visible to another save or Run. Commit without
         yielding after successful rename, preserving concurrent run-reference edits. *)
      Option.iter reservation ~f:(fun (key, preview) ->
        p.submissions <- (key, preview, None) :: p.submissions))
  in
  let work =
    outcome
    >>| fun result ->
    match result with
    | Ok () -> ()
    | Error exn -> p.cache_error <- Some (Exn.to_string exn)
  in
  p.save_tail <- work;
  outcome
;;

let persist t p =
  let%map (_ : (unit, exn) Result.t) = save_registry t p in
  ()
;;

let load_project t ~root ~environment =
  let%bind config =
    In_thread.run (fun () ->
      let filename = Filename.concat root Config.filename in
      match Sys_unix.file_exists filename with
      | `No -> None
      | `Unknown -> failwith "Cannot inspect ASIC configuration"
      | `Yes -> Some (Config.parse_string (read_bounded filename 65536) |> Or_error.ok_exn))
  in
  let%bind () =
    In_thread.run (fun () ->
      (* Resolve for the storage-separation check only, never for executable argv. *)
      let rec physical path =
        match Sys_unix.file_exists path with
        | `Yes -> Filename_unix.realpath path
        | `Unknown -> failwith "Cannot validate ASIC cache separation"
        | `No ->
          let parent = physical (Filename.dirname path) in
          (match Filename.basename path with
           | "." -> parent
           | ".." -> Filename.dirname parent
           | name -> Filename.concat parent name)
      in
      Option.iter config ~f:(fun (config : Config.t) ->
        let cache = physical t.state_dir
        and results = physical config.results_root in
        Public.require
          (not
             (String.equal results "/"
              || String.equal cache results
              || String.is_prefix cache ~prefix:(results ^ "/")))
          "Workbench ASIC cache must be outside provider results"))
  in
  let identity =
    Sexp.to_string_mach
      [%sexp
        (root : string)
        , (environment : V1.Environment_selection.t)
         , (config : Config.t option)]
  in
  let%bind workloads = In_thread.run (fun () ->
    Asic_workloads_service.create ~state_dir:t.state_dir ~identity) in
  let p =
    { root
    ; environment
    ; config
    ; identity
    ; runs = []
    ; submissions = []
    ; index = []
    ; terminal_attempts = []
    ; finalizations = []
    ; stage_starts = []
    ; artifacts = []
    ; artifact_pages = []
    ; artifact_byte_pages = []
    ; inspections = []
    ; inspection_details = []
    ; resources = Asic_resources_service.create ~state_dir:t.state_dir ~identity
    ; resource_refreshes = String.Table.create ()
    ; workloads
    ; workload_refreshes = String.Table.create ()
    ; detail_cache =
        Inspection_detail_cache.create
          ~entries:t.inspection_detail_cache_entries
          ~bytes:t.inspection_detail_cache_bytes
    ; inspection_refreshes = String.Table.create ()
    ; hot = String.Table.create ()
    ; recency = []
    ; tasks = String.Table.create ()
    ; reservations = String.Table.create ()
    ; flows = []
    ; catalog_default = None
    ; description = None
    ; preview = None
    ; desired_plan = None
    ; desired_description = None
    ; read_tails = String.Table.create ()
    ; provider_check = None
    ; timing_stage = false
    ; cache_error = None
    ; registry_writable = true
    ; save_tail = Deferred.unit
    ; fresh_intent = None
    ; fresh_generation = 0
    ; workflows = []
    ; workflow_reservations = String.Table.create ()
    }
  in
  let%bind loaded =
    Monitor.try_with (fun () ->
      In_thread.run (fun () ->
        let filename = registry_path t p in
        if Poly.equal (Sys_unix.file_exists filename) `No
        then None
        else (
          let stored =
            Stored.t_of_sexp (Sexp.of_string (read_bounded filename (4 * 1024 * 1024)))
          in
          List.iter stored.runs ~f:(fun run -> Public.validate_stages run.stages);
          let workflow_keys = String.Hash_set.create () in
          List.iter stored.workflows ~f:(fun w ->
            Public.require
              (not (Hash_set.mem workflow_keys w.Asic.Fresh.Workflow.key))
              "Duplicate retained workflow submission key";
            Hash_set.add workflow_keys w.key;
            Public.require
              (String.equal
                 w.id
                 ("workflow-" ^ Public.digest (p.identity ^ "\000" ^ w.key)))
              "Retained workflow identity mismatch";
            Preparation_receipt.validate_selection
              w.intent.selection
              w.intent.expected_plan_identity;
            Option.iter w.prepared ~f:(fun prepared ->
              Public.require
                (Preparation_receipt.valid_identity prepared.bundle_identity
                 && Preparation_receipt.valid_identity prepared.plan_identity
                 && Preparation_receipt.valid_identity prepared.methodology_plan_digest
                 && String.equal
                      prepared.methodology_plan_path
                      (path t (p.identity ^ w.id) "-methodology-plan.json"))
                "Invalid retained prepared-input identity");
            match w.run, w.reference with
            | None, None -> ()
            | Some run, Some reference ->
              Public.require
                (List.exists stored.runs ~f:(fun r ->
                   Run_ref.equal r.Asic.Run.run run
                   && Asic.Reference.equal r.reference reference))
                "Retained workflow/provider linkage mismatch"
            | _ -> failwith "Incomplete retained workflow/provider linkage");
          Some stored)))
  in
  (match loaded with
   | Error exn ->
     p.registry_writable <- false;
     p.cache_error <- Some ("Registry unavailable: " ^ Exn.to_string exn)
   | Ok None -> ()
   | Ok (Some s) ->
     if s.version <> 1
        || (not (String.equal s.identity identity))
        || List.length s.runs > 256
        || List.length s.index > 128
        || List.length s.submissions > 256
        || List.length s.terminal_attempts > 256
        || List.length s.finalizations > 256
        || List.length s.workflows > 256
        || List.length s.finalizations
           <> List.length
                (List.dedup_and_sort
                   (List.map s.finalizations ~f:(fun f -> f.value.key))
                   ~compare:String.compare)
     then (
       p.registry_writable <- false;
       p.cache_error <- Some "Incompatible ASIC registry")
     else (
       p.runs
       <- List.map s.runs ~f:(fun r ->
            { r with
              execution_timing = Execution_timing.stopped r.execution_timing
            ; stages =
                List.map r.stages ~f:(fun stage ->
                  { stage with
                    execution_timing = Execution_timing.stopped stage.execution_timing
                  })
            });
       p.submissions <- s.submissions;
       p.workflows
       <- List.map s.workflows ~f:(fun w ->
            let active =
              match w.Asic.Fresh.Workflow.phase with
              | Reserved | Building | Emitting | Prepared | Physical -> true
              | Completed | Failed | Cancelled | Interrupted -> false
            in
            { w with
              phase = (if active then Interrupted else w.phase)
            ; build_job = None
            ; emission_job = None
            ; elaboration_status =
                (if List.mem
                      [ "building"; "emitting"; "not_requested" ]
                      w.elaboration_status
                      ~equal:String.equal
                    && active
                 then "interrupted"
                 else w.elaboration_status)
            ; error =
                (if active
                 then
                   Some
                     "Daemon restarted; producer ownership unavailable; no automatic \
                      replay"
                 else w.error)
            });
       p.index <- s.index;
       p.terminal_attempts <- s.terminal_attempts;
       p.stage_starts
       <- List.filter_map p.runs ~f:(fun r ->
            Option.map
              (List.Assoc.find s.stage_starts r.run.id ~equal:String.equal)
              ~f:(fun starts ->
                ( r.run.id
                , List.filter_map Public.canonical_stages ~f:(fun id ->
                    Option.map
                      (List.Assoc.find starts id ~equal:String.equal)
                      ~f:(fun at -> id, at)) )));
       p.finalizations
       <- List.map s.finalizations ~f:(fun f ->
            (* Older records have only an undifferentiated error. Preserve it as a stable
               baseline rather than silently erasing a possible producer failure. *)
            let f =
              if Option.is_none f.producer_error && Option.is_none f.observation_error
              then { f with producer_error = f.value.error }
              else f
            in
            { f with
              value =
                { f.value with
                  owned = false
                ; execution_timing = Execution_timing.stopped f.value.execution_timing
                ; state =
                    (if List.mem
                          [ "pending"; "executing" ]
                          f.value.state
                          ~equal:String.equal
                     then "unknown"
                     else f.value.state)
                }
            })));
  (* This is our explicitly configured, single-writer derived cache directory, never a
     provider directory. Recover only our own namespace's orphan blobs. *)
  let retained =
    List.map p.index ~f:(fun (_, digest) -> Filename.basename (summary_path t p digest))
  in
  let%map cleanup =
    Monitor.try_with (fun () ->
      In_thread.run (fun () ->
        if p.registry_writable && Poly.equal (Sys_unix.file_exists t.state_dir) `Yes
        then
          List.iter (Sys_unix.ls_dir t.state_dir) ~f:(fun name ->
            if String.is_prefix name ~prefix:(summary_prefix p)
               && String.is_suffix name ~suffix:".summary.sexp"
               && not (List.mem retained name ~equal:String.equal)
            then Core_unix.unlink (Filename.concat t.state_dir name))))
  in
  (match cleanup with
   | Ok () -> ()
   | Error exn -> p.cache_error <- Some (Exn.to_string exn));
  p
;;

let config p = Option.value_exn p.config ~message:"Project has no ASIC configuration"
let invoke p f = f (config p) ~root:p.root ~environment:p.environment

let query ?(max_bytes = 16 * 1024 * 1024) ?(before = fun () -> ()) t _p cancel invocation =
  Throttle.enqueue t.queries (fun () ->
    Public.require (not (Deferred.is_determined cancel)) "ASIC query cancelled";
    before ();
    let%map output =
      Asic_process.run
        ~seconds:30.
        ~cancel
        ~on_process:ignore
        ~on_line:(fun _ -> Deferred.unit)
        invocation
    in
    Public.require
      (String.length output <= max_bytes)
      "ASIC query response exceeds budget";
    Public.decode output)
;;

(* A catalog describes the provider's general routes, not what its active execution
   policy permits. Admit using metadata from the actual producer environment. Never
   infer activation from synthesis_collection1, which is also advertised by default. *)
let validate_execution_selection metadata (selection : Asic.Selection.t) =
  match Public.field "execution_envelope" metadata with
  | `Null -> ()
  | envelope ->
    Public.require
      (List.for_all
         [ "schema_version", `Int 1
         ; "profile", `String "synthesis-total-tasks-v1"
         ; "total_container_tasks", `Int 6
         ; "configured_executor_max_workers", `Int 6
         ; "reduced_usable_executor_concurrency", `Bool true
         ]
         ~f:(fun (key, expected) -> Poly.equal (Public.field key envelope) expected))
      "Provider advertises an unsupported active execution_envelope; execution blocked";
    Public.require
      (String.equal selection.endpoint "synthesis")
      (sprintf
         "Endpoint '%s' is incompatible with active provider execution_envelope \
          'synthesis-total-tasks-v1' (6 total container tasks): only fresh synthesis-only \
          execution is supported. Select endpoint 'synthesis' or use elaboration-only."
         selection.endpoint)
;;

let check_provider ?(cache = true) ?selection t p cancel =
  (* Admission must not reuse a discovery probe: the active opt-in can change while
     the service remains open. Recheck before preparation and before allocation. *)
  let cache = cache && Option.is_none selection in
  let probe () =
    Monitor.try_with (fun () ->
      let%map metadata = query t p cancel (invoke p Adapter.metadata) in
      Public.metadata metadata;
      Option.iter selection ~f:(validate_execution_selection metadata);
      p.timing_stage
      <- Poly.equal
           (Public.field
              "timing_stage1"
              (Public.field "capabilities" (Public.field "cli_contract" metadata)))
           (`Bool true))
  in
  let checked =
    match if cache then p.provider_check else None with
    | Some checked -> checked
    | None ->
      let checked = probe () in
      if cache then p.provider_check <- Some checked;
      checked
  in
  checked
  >>| function
  | Ok () -> ()
  | Error exn ->
    if cache then p.provider_check <- None;
    raise exn
;;

let run_id (reference : Asic.Reference.t) = reference.stream_id

let find_run (p : project) (run : Run_ref.t) : Asic.Run.t =
  List.find p.runs ~f:(fun r -> Run_ref.equal r.Asic.Run.run run)
  |> Option.value_exn ~message:"Unknown registered ASIC run"
;;

let replace_run (p : project) (r : Asic.Run.t) =
  Option.iter
    (List.find p.runs ~f:(fun old -> Run_ref.equal old.Asic.Run.run r.run))
    ~f:(fun old ->
      if not
           (Asic.Reference.equal old.reference r.reference
            && old.cursor = r.cursor
            && Option.equal String.equal old.execution_file r.execution_file)
      then (
        Asic_resources_service.invalidate_run p.resources r.run;
        Inspection_detail_cache.retain p.detail_cache ~f:(fun ~identity:_ detail ->
          not (Run_ref.equal detail.run r.run));
        p.inspection_details
        <- List.filter p.inspection_details ~f:(fun detail ->
             not (Run_ref.equal detail.Inspection_wire.Detail.run r.run))));
  p.runs
  <- r
     :: List.filter p.runs ~f:(fun (old : Asic.Run.t) ->
       not (Run_ref.equal old.run r.run))
;;

let register
  ?(persist_reference = true)
  t
  (p : project)
  ?selection
  (reference : Asic.Reference.t)
  =
  ignore (Public.absolute reference.Asic.Reference.attempt : string);
  Public.require (not (String.is_empty reference.stream_id)) "Empty stream ID";
  let id = run_id reference in
  let run : Run_ref.t =
    { backend = Backend_id.of_string "asic"; id; build = None; label = None }
  in
  match List.find p.runs ~f:(fun r -> Run_ref.equal r.Asic.Run.run run) with
  | Some r ->
    Public.require
      (Asic.Reference.equal r.reference reference)
      "Conflicting public run reference";
    return r
  | None ->
    Public.require (List.length p.runs < 256) "Registered ASIC run budget (256) exhausted";
    let r : Asic.Run.t =
      { run
      ; reference
      ; selection
      ; cursor = 0
      ; status = "allocated"
      ; execution_file = None
      ; error = None
      ; stages = []
      ; execution_timing = None
      }
    in
    replace_run p r;
    let%map () = if persist_reference then persist t p else Deferred.unit in
    r
;;

let hot p (summary : Asic.Summary.t) =
  let id = summary.run.id in
  if not
       (Option.value_map (Hashtbl.find p.hot id) ~default:false ~f:(fun old ->
          String.equal old.source_digest summary.source_digest))
  then (
    p.artifacts
    <- List.filter p.artifacts ~f:(fun r ->
         not (Run_ref.equal r.Asic_artifact.Reference.run summary.run));
    p.artifact_pages
    <- List.filter p.artifact_pages ~f:(fun page ->
         not (Run_ref.equal page.Asic_artifact.Page.run summary.run));
    p.artifact_byte_pages
    <- List.filter p.artifact_byte_pages ~f:(fun page ->
         not (Run_ref.equal page.Asic_artifact.Byte_page.run summary.run)));
  Hashtbl.set p.hot ~key:id ~data:summary;
  p.recency <- id :: List.filter p.recency ~f:(fun key -> not (String.equal id key));
  let retained = List.take p.recency 32
  and evicted = List.drop p.recency 32 in
  List.iter evicted ~f:(Hashtbl.remove p.hot);
  p.artifacts
  <- List.filter p.artifacts ~f:(fun r ->
       Hashtbl.mem p.hot r.Asic_artifact.Reference.run.id);
  p.artifact_pages
  <- List.filter p.artifact_pages ~f:(fun page ->
       List.exists p.artifacts ~f:(fun r ->
         Run_ref.equal r.run page.Asic_artifact.Page.run
         && String.equal r.id page.artifact_id));
  p.artifact_byte_pages
  <- List.filter p.artifact_byte_pages ~f:(fun page ->
       List.exists p.artifacts ~f:(fun r ->
         Run_ref.equal r.run page.Asic_artifact.Byte_page.run
         && String.equal r.id page.artifact_id
         && String.equal r.terminal_attempt page.terminal_attempt
         && String.equal r.sha256 page.sha256));
  p.recency <- retained
;;

let prune_byte_pages p =
  p.artifact_byte_pages
  <- List.filter p.artifact_byte_pages ~f:(fun page ->
       List.exists p.artifacts ~f:(fun r ->
         Run_ref.equal r.Asic_artifact.Reference.run page.Asic_artifact.Byte_page.run
         && String.equal r.id page.artifact_id
         && String.equal r.terminal_attempt page.terminal_attempt
         && String.equal r.sha256 page.sha256))
;;

let expected_plan p (run : Run_ref.t) =
  List.find_map p.submissions ~f:(fun (_, preview, id) ->
    if Option.equal String.equal id (Some run.id)
    then Some preview.Asic.Preview.plan_identity
    else None)
;;

let expected_bundle p (run : Run_ref.t) =
  List.find_map p.submissions ~f:(fun (_, preview, id) ->
    if Option.equal String.equal id (Some run.Run_ref.id)
    then
      Public.optional_text
        (Public.field "bundle_identity" (Public.decode preview.Asic.Preview.plan_json))
    else None)
;;

let serialized p key f =
  let previous = Hashtbl.find p.read_tails key |> Option.value ~default:Deferred.unit in
  let done_ = Ivar.create () in
  Hashtbl.set p.read_tails ~key ~data:(Ivar.read done_);
  Monitor.protect
    ~finally:(fun () ->
      Ivar.fill_exn done_ ();
      Deferred.unit)
    (fun () ->
      let%bind () = previous in
      f ())
;;

let observe_unlocked t p cancel (run : Run_ref.t) =
  Public.require
    (not (Deferred.is_determined cancel))
    "ASIC observation stopped; reconnect with Observe";
  let%bind () = check_provider t p cancel in
  let r = find_run p run in
  (* Replay the small prefix until execution delivery. A failed admission may have
     been preceded by an earlier pending observation; a suffix is not proof that
     no Prepared/Started event occurred. The provider validates the journal. *)
  let read_from = if Option.is_none r.execution_file then { r with cursor = 0 } else r in
  let%bind updates =
    query
      t
      p
      cancel
      (invoke p (fun c ~root ~environment ->
          Adapter.updates c ~root ~environment r.reference ~after:read_from.cursor))
  in
  let cursor = Public.updates read_from updates in
  Public.require (cursor >= r.cursor) "Regressed replayed observation cursor";
  match Asic_rejection.from_updates read_from ~expected_plan:(expected_plan p run) updates with
  | Some rejected ->
    Public.require
      (not (Deferred.is_determined cancel))
      "ASIC observation stopped; reconnect with Observe";
    replace_run p rejected;
    let%map () = persist t p in
    true
  | None -> (
  let%bind inspection =
    query
      t
      p
      cancel
      (invoke p (fun c ~root ~environment ->
         Adapter.inspect c ~root ~environment r.reference))
  in
  let next, final = Public.inspection r ~cursor inspection in
  let next =
    Public.updates_timing
      next
      ~writer_active:(Poly.equal (Public.field "writer_active" inspection) (`Bool true))
      updates
  in
  let starts =
    List.fold
      (Public.stage_start_events updates)
      ~init:
        (Option.value
           (List.Assoc.find p.stage_starts run.id ~equal:String.equal)
           ~default:[])
      ~f:(fun starts (id, at) -> List.Assoc.add starts ~equal:String.equal id at)
  in
  let next =
    Public.with_stage_starts
      next
      starts
      ~writer_active:(Poly.equal (Public.field "writer_active" inspection) (`Bool true))
  in
  Public.require
    (not (Deferred.is_determined cancel))
    "ASIC observation stopped; reconnect with Observe";
  let methodology =
    Public.envelope
      (Public.field "methodology" inspection)
      "hardcaml-asic.historical-methodology"
      1
  in
  let reference =
    match Public.field "state" methodology with
    | `String "pending" -> Public.field "launch" methodology
    | `String "recorded" -> Public.field "reference" methodology
    | _ -> failwith "Missing historical methodology"
  in
  Public.require
    (Poly.equal (Public.field "attempt_id" reference) (`String r.reference.stream_id))
    "Historical methodology attempt mismatch";
  Option.iter (expected_plan p run) ~f:(fun identity ->
    let actual =
      match Public.field "state" methodology with
      | `String "pending" ->
        Public.field "expected_plan_identity" (Public.field "launch" methodology)
      | `String "recorded" -> Public.field "plan_identity" methodology
      | _ -> failwith "Missing historical methodology"
    in
    Public.require
      (Poly.equal actual (`String identity))
      "Inspection plan identity mismatch");
  (* Serial/coalesced observation per run prevents a late cursor from regressing it. *)
  let current = find_run p run in
  if current.cursor <= next.cursor
  then (
    replace_run p next;
    p.stage_starts <- List.Assoc.add p.stage_starts ~equal:String.equal run.id starts;
    if not (Option.equal String.equal current.execution_file next.execution_file)
    then
      p.inspections
      <- List.filter p.inspections ~f:(fun index ->
           not (Run_ref.equal index.Inspection_wire.Index.run run))
    else if current.cursor < next.cursor
    then
      (* A public execution path can be reused by a newer source generation. Retain
         offline index evidence, but do not present it or its old details as current. *)
      p.inspections
      <- List.map p.inspections ~f:(fun index ->
           if Run_ref.equal index.Inspection_wire.Index.run run
           then { index with cached_unverified = true }
           else index);
    if current.cursor < next.cursor
       || not (Option.equal String.equal current.execution_file next.execution_file)
    then
      p.inspection_details
      <- List.filter p.inspection_details ~f:(fun detail ->
           not (Run_ref.equal detail.Inspection_wire.Detail.run run));
    if current.cursor < next.cursor
       || not (Option.equal String.equal current.execution_file next.execution_file)
    then
      Option.iter (Hashtbl.find p.hot run.id) ~f:(fun s ->
        hot
          p
          { s with
            freshness =
              (if Option.is_none next.execution_file && final
               then Missing_source
               else Cached_unverified)
          }));
  let%map () = persist t p in
  final)
;;

let observe t p cancel (run : Run_ref.t) =
  serialized p ("observe:" ^ run.Run_ref.id) (fun () ->
    let%bind result = Monitor.try_with (fun () -> observe_unlocked t p cancel run) in
    match result with
    | Ok final -> return final
    | Error exn ->
      let r = find_run p run in
      replace_run
        p
        { r with
          execution_timing = Execution_timing.stopped r.execution_timing
        ; stages =
            List.map r.stages ~f:(fun stage ->
              { stage with
                execution_timing = Execution_timing.stopped stage.execution_timing
              })
        };
      let%bind () = persist t p in
      raise exn)
;;

let materialize_unlocked ?attempt t p cancel (run : Run_ref.t) =
  Public.require (not (Deferred.is_determined cancel)) "ASIC report read cancelled";
  let%bind () = check_provider t p cancel in
  let r = find_run p run in
  match r.execution_file with
  | None when Asic_rejection.is_rejection r -> Deferred.unit
  | None ->
    Option.iter (Hashtbl.find p.hot run.id) ~f:(fun s ->
      hot p { s with freshness = Missing_source });
    failwith "No public execution_file reference available"
  | Some execution_file ->
    let%bind result =
      Monitor.try_with (fun () ->
        let%bind report =
          query
            t
            p
            cancel
            (invoke p (fun c ~root ~environment ->
               Adapter.report c ~root ~environment execution_file))
        in
        Option.iter (expected_bundle p run) ~f:(fun bundle ->
          Public.require
            (Poly.equal
               (Public.field "bundle_identity" (Public.field "methodology" report))
               (`String bundle))
            "Report bundle identity mismatch");
        let summary =
          Public.summary r ~expected_plan:(expected_plan p run) ~execution_file report
        in
        let%bind summary =
          if Poly.equal (Public.field "timing_analysis" report) `Null
          then return summary
          else
            In_thread.run (fun () ->
              let execution_sha256 =
                Inspection.execution_hash ~registered:r ~execution_file
              in
              let execution_bytes =
                read_public_bounded execution_file (8 * 1024 * 1024)
              in
              Public.require
                (String.equal (Public.digest execution_bytes) execution_sha256)
                "Execution changed during timing report read";
              let actual_execution = Public.decode execution_bytes in
              Public.require
                (Poly.equal
                   (Public.canonical_json actual_execution)
                   (Public.canonical_json (Public.field "execution" report)))
                "Timing report execution content mismatch";
              let timing_analysis =
                Asic_timing_analysis.parse
                  ~registered:r
                  ~execution_file
                  ~execution_sha256
                  report
              in
              { summary with timing_analysis })
        in
        let attempt =
          match attempt with
          | Some _ -> attempt
          | None -> List.Assoc.find p.terminal_attempts run.id ~equal:String.equal
        in
        let%bind terminal_summary =
          Monitor.try_with (fun () ->
            match attempt with
            | None -> return summary
            | Some attempt ->
              let%bind receipt =
                query
                  t
                  p
                  cancel
                  (invoke p (fun c ~root ~environment ->
                     Adapter.inspect_finalization c ~root ~environment attempt))
              in
              let results_file = Public.terminal_results_file receipt in
              let%map terminal =
                In_thread.run (fun () ->
                  let execution_file = Filename_unix.realpath execution_file in
                  let execution_bytes =
                    read_public_bounded execution_file (8 * 1024 * 1024)
                  in
                  let results_bytes = read_public_bounded results_file (128 * 1024) in
                  let terminal =
                    Public.terminal_result
                      ~attempt
                      ~execution_file
                      ~execution_bytes
                      ~report
                      ~receipt
                      ~results_bytes
                  in
                  let snapshot_bytes =
                    Option.map
                      (Public.declared_clock_snapshot report)
                      ~f:(fun (path, _) -> read_public_bounded path (256 * 1024))
                  in
                  let clock =
                    Public.declared_clock_metric ~report ~receipt ~snapshot_bytes
                  in
                  { terminal with metrics = terminal.metrics @ [ clock ] })
              in
              { summary with
                terminal = Some terminal
              ; source_digest =
                  Public.digest
                    (summary.source_digest
                     ^ terminal.evidence
                     ^ Sexp.to_string_mach
                         ([%sexp_of: Asic.Metric.t list] terminal.metrics))
              })
        in
        match terminal_summary with
        | Ok summary -> return summary
        | Error exn when Option.is_some summary.timing_analysis ->
          (* Supplementary completion does not depend on finalization hydration. Never
             borrow old terminal metrics if its adopted source cannot be validated. *)
          return { summary with freshness = Refresh_failed (Exn.to_string exn) }
        | Error exn -> raise exn)
    in
    (match result with
     | Error exn ->
       Option.iter (Hashtbl.find p.hot run.id) ~f:(fun s ->
         hot p { s with freshness = Refresh_failed (Exn.to_string exn) });
       raise exn
     | Ok summary ->
       Public.require
         (not (Deferred.is_determined cancel))
         "ASIC report read cancelled before publication";
       let current = find_run p run in
       Public.require
         (current.cursor = r.cursor
          && Option.equal String.equal current.execution_file r.execution_file)
         "Observation advanced during report read; refresh again";
       let data = Sexp.to_string (Asic.Summary.sexp_of_t summary) in
       Public.require
         (String.length data <= summary_limit)
         "Normalized ASIC summary exceeds 4MiB";
       let blob : Summary_blob.t =
         { version = 5; normalized_digest = summary_digest summary; summary }
       in
       let data = Sexp.to_string (Summary_blob.sexp_of_t blob) in
       hot p summary;
       let%bind saved =
         Monitor.try_with (fun () ->
           In_thread.run (fun () ->
             atomic_write t (summary_path t p summary.source_digest) data))
       in
       let%bind () =
         match saved with
         | Error exn ->
           p.cache_error <- Some (Exn.to_string exn);
           Deferred.unit
         | Ok () ->
           let old_index = p.index in
           p.index
           <- (run.id, summary.source_digest)
              :: List.filter p.index ~f:(fun (id, _) -> not (String.equal id run.id));
           p.index <- List.take p.index 128;
           let retained = List.map p.index ~f:snd in
           In_thread.run (fun () ->
             List.iter old_index ~f:(fun (_, digest) ->
               if not (List.mem retained digest ~equal:String.equal)
               then (
                 try Core_unix.unlink (summary_path t p digest) with
                 | _ -> ())))
       in
       Option.iter summary.terminal ~f:(fun terminal ->
         p.terminal_attempts
         <- (run.id, terminal.attempt)
            :: List.filter p.terminal_attempts ~f:(fun (id, _) ->
              not (String.equal id run.id)));
       persist t p)
;;

let materialize ?attempt t p cancel (run : Run_ref.t) =
  (* Global publication ordering also protects L2 eviction from deleting a digest
     concurrently reintroduced by another registered run. *)
  serialized p "report-publication" (fun () ->
    materialize_unlocked ?attempt t p cancel run)
;;

let load_summary t p cancel (run : Run_ref.t) =
  match Hashtbl.find p.hot run.Run_ref.id with
  | Some summary ->
    hot p summary;
    Deferred.unit
  | None ->
    let%bind loaded =
      Monitor.try_with (fun () ->
        match List.Assoc.find p.index run.id ~equal:String.equal with
        | None -> return None
        | Some digest ->
          In_thread.run (fun () ->
            let s =
              decode_summary_blob
                (Sexp.of_string
                   (read_bounded (summary_path t p digest) (summary_limit + 1024)))
            in
            Public.require
              (Run_ref.equal s.run run && String.equal s.source_digest digest)
              "Wrong L2 summary identity";
            Some { s with freshness = Cached_unverified }))
    in
    (match loaded with
     | Ok (Some summary) ->
       if not (Hashtbl.mem p.hot run.id) then hot p summary;
       Deferred.unit
     | Ok None | Error _ ->
       let%bind (_ : bool) = observe t p cancel run in
       materialize t p cancel run)
;;

let snapshot p : Asic.Snapshot.t =
  { configured = Option.is_some p.config
  ; flows = p.flows
  ; catalog_default = p.catalog_default
  ; description_json = p.description
  ; preview = p.preview
  ; runs = p.runs
  ; launches =
      List.map p.submissions ~f:(fun (key, preview, run_id) ->
        { Asic.Launch.key; preview; run_id })
  ; operations =
      (Hashtbl.data p.tasks |> List.map ~f:(fun t -> t.pending))
      @ (Hashtbl.keys p.reservations
         |> List.filter_map ~f:(fun key ->
           if Hashtbl.mem p.tasks ("run:" ^ key)
           then None
           else
             Some
               { Asic.Pending.key = "run:" ^ key
               ; kind = "run"
               ; state = "reserving"
               ; run = None
               ; error = None
               ; activity = Unreported
               }))
      @ List.filter_map p.submissions ~f:(fun (key, _, id) ->
        if Hashtbl.mem p.tasks ("run:" ^ key) || Hashtbl.mem p.reservations key
        then None
        else
          Some
            { Asic.Pending.key = "run:" ^ key
            ; kind = "run"
            ; state = "detached"
            ; run =
                Option.bind id ~f:(fun id ->
                  List.find_map p.runs ~f:(fun r ->
                    if String.equal r.Asic.Run.run.id id then Some r.run else None))
            ; error =
                Some
                  "Submission reserved; execution ownership unavailable. Observe \
                   registered reference; never relaunch implicitly."
            ; activity = Unreported
            })
      @ List.filter_map p.finalizations ~f:(fun f ->
        let key = "finalize:" ^ f.value.key in
        if Hashtbl.mem p.tasks key
        then None
        else
          Some
            { Asic.Pending.key
            ; kind = "finalize"
            ; state = f.value.state
            ; run = Some f.value.run
            ; error = f.value.error
            ; activity = Unreported
            })
  ; summaries = Hashtbl.data p.hot
  ; finalizations =
      List.map p.finalizations ~f:(fun f ->
        if f.value.owned
        then f.value
        else
          { f.value with
            execution_timing = Execution_timing.stopped f.value.execution_timing
          })
  ; artifacts = p.artifacts
  ; artifact_pages = p.artifact_pages
  ; artifact_byte_pages = p.artifact_byte_pages
  ; inspections = p.inspections
  ; inspection_details = p.inspection_details
  ; cache_error = Option.first_some p.cache_error (Asic_resources_service.cache_error p.resources)
  ; fresh_intent = p.fresh_intent
  ; workflows = p.workflows
  ; resources = Some (Asic_resources_service.snapshot p.resources)
  ; workloads = Some (Asic_workloads_service.snapshot p.workloads)
  }
;;

let schedule t p ~key ~kind ~execution f =
  Public.require (not t.closing) "ASIC service shutting down";
  match Hashtbl.find p.tasks key with
  | Some task
    when String.equal task.pending.state "pending"
         || String.equal task.pending.state "executing" -> ()
  | _ ->
    if Hashtbl.length p.tasks >= 64
    then
      Hashtbl.filter_inplace p.tasks ~f:(fun task ->
        String.equal task.pending.state "pending"
        || String.equal task.pending.state "executing");
    Public.require (Hashtbl.length p.tasks < 64) "ASIC pending operation budget exhausted";
    let task =
      { cancel = Ivar.create ()
      ; completion = Deferred.unit
      ; pending =
          { Asic.Pending.key
          ; kind
          ; state = "pending"
          ; run = None
          ; error = None
          ; activity = Unreported
          }
      }
    in
    Hashtbl.set p.tasks ~key ~data:task;
    let work () =
      let%bind result =
        Monitor.try_with (fun () ->
          Public.require (not (Ivar.is_full task.cancel)) "ASIC operation cancelled";
          task.pending <- { task.pending with state = "executing" };
          f task)
      in
      task.pending
      <- (match result with
          | Ok () -> { task.pending with state = "completed" }
          | Error exn ->
            { task.pending with state = "failed"; error = Some (failure_message exn) });
      if String.equal kind "finalize"
      then (
        p.finalizations
        <- List.map p.finalizations ~f:(fun f ->
             if String.equal ("finalize:" ^ f.value.key) key
             then (
               let f =
                 match result with
                 | Error exn
                   when Option.is_none f.producer_error
                        && Option.is_none f.observation_error ->
                   with_finalization_errors
                     f
                     ~producer_error:(Some (Exn.to_string exn))
                     ~observation_error:None
                 | Ok () | Error _ -> f
               in
               { f with
                 value =
                   { f.value with
                     owned = false
                   ; state =
                       (if List.mem
                             [ "pending"; "executing" ]
                             f.value.state
                             ~equal:String.equal
                        then if Ivar.is_full task.cancel then "interrupted" else "failed"
                        else f.value.state)
                   }
               })
             else f);
        persist t p)
      else Deferred.unit
    in
    let completion = if execution then Throttle.enqueue t.executions work else work () in
    task.completion <- completion;
    don't_wait_for completion
;;

let observation_key (run : Run_ref.t) = "observe:" ^ run.id

let reserve_and_schedule t p ~key ~preview launch =
  Public.require (not t.closing) "ASIC service shutting down";
  let await result =
    result
    >>| function
    | Ok () -> ()
    | Error exn -> raise exn
  in
  match Hashtbl.find p.reservations key with
  | Some reservation ->
    Public.require
      (Asic.Preview.equal reservation.preview preview)
      "Submission key reused with different preview";
    await reservation.result
  | None ->
    (match List.find p.submissions ~f:(fun (old, _, _) -> String.equal key old) with
     | Some (_, old, _) ->
       Public.require
         (Asic.Preview.equal old preview)
         "Submission key reused with different preview";
       Deferred.unit
     | None ->
       Public.require
         (Hashtbl.length p.reservations < 64)
         "ASIC in-flight reservation budget exhausted";
       let outcome = Ivar.create () in
       let result = Ivar.read outcome in
       Hashtbl.set p.reservations ~key ~data:{ preview; result };
       let work =
         Monitor.try_with (fun () ->
           let%map saved = save_registry ~reservation:(key, preview) t p in
           match saved with
           | Error exn -> raise exn
           | Ok () -> launch ())
       in
       don't_wait_for
         (work
          >>| fun result ->
          (* Failure before commit leaves no key to roll back. Existing waiters all
             receive this exact outcome; a later request may safely retry the key. *)
          Hashtbl.remove p.reservations key;
          Ivar.fill_exn outcome result);
       await result)
;;

let find_finalization p key =
  List.find_exn p.finalizations ~f:(fun f -> String.equal f.value.key key)
;;

let update_finalization p key f =
  p.finalizations
  <- List.map p.finalizations ~f:(fun old ->
       if String.equal old.value.key key then f old else old)
;;

let save_required t p =
  save_registry t p
  >>| function
  | Ok () -> ()
  | Error exn -> raise exn
;;

let validate_finalization_input ~key ~execution_file ~acceptance =
  Public.require
    ((not (String.is_empty key)) && String.length key <= 256)
    "Invalid finalization key";
  ignore (Public.absolute execution_file : string);
  Public.require (String.length execution_file <= 4096) "Execution path exceeds budget";
  Option.iter acceptance ~f:(fun (a : Asic.Acceptance.t) ->
    List.iter
      [ a.support_tools; a.precheck_python; a.testbench; a.replay_trace ]
      ~f:(fun path ->
        ignore (Public.absolute path : string);
        Public.require (String.length path <= 4096) "Acceptance path exceeds budget");
    Public.require
      ((not (String.is_empty (String.strip a.testbench_top)))
       && String.length a.testbench_top <= 4096)
      "Explicit acceptance testbench top required")
;;

(* Neither CLI4/namedflow1 nor a synthesis checkpoint implies collection support.
   Require an explicit provider capability AND its active opt-in envelope. These
   are queried in the same project environment as the eventual producer. *)
let synthesis_collection_supported metadata =
  let field = Public.field in
  let capability =
    field "synthesis_collection1" (field "capabilities" (field "cli_contract" metadata))
  in
  let expected fields value =
    List.for_all fields ~f:(fun (key, expected) -> Poly.equal (field key value) expected)
  in
  expected
    [ "schema_version", `Int 1
    ; "profile", `String "synthesis-total-tasks-v1"
    ; "total_container_tasks", `Int 6
    ; "fresh_only", `Bool true
    ; "acceptance", `Bool false
    ; "opt_in", `String "HARDCAML_ASIC_SYNTHESIS_TASK_LIMIT=6"
    ]
    capability
  && expected
       [ "schema_version", `Int 1
       ; "profile", `String "synthesis-total-tasks-v1"
       ; "total_container_tasks", `Int 6
       ; "configured_executor_max_workers", `Int 6
       ; "reduced_usable_executor_concurrency", `Bool true
       ]
       (field "execution_envelope" metadata)
;;

let validate_finalization_execution
  ~stream_id
  ~acceptance_requested
  ~metadata
  ~report
  execution
  =
  let field = Public.field in
  let plan = Public.explicit_recipe_plan (field "plan" execution) in
  let synthesis_only =
    Poly.equal (field "schema_version" plan) (`Int 4)
    && Poly.equal (field "stages" plan) (`List [ `String "synthesis" ])
  in
  let stages =
    if synthesis_only
    then (
      Public.require
        ((not acceptance_requested) && synthesis_collection_supported metadata)
        "Synthesis collection requires explicit active provider support; acceptance is prohibited";
      [ "synthesis" ])
    else Public.recipe_stages (field "plan" execution)
  in
  Public.require
    (Poly.equal
       (Public.canonical_json execution)
       (Public.canonical_json (field "execution" report))
     && Poly.equal (field "attempt_id" execution) (`String stream_id)
     && Poly.equal
          (field "physical" (field "completion" report))
          (`String (if synthesis_only then "synthesis" else "full"))
     && Poly.equal (field "status" execution) (`String "completed")
     && Poly.equal (field "exit_code" execution) (`Int 0)
     && Poly.equal (field "initial_boundary" plan) `Null
     && (match plan with
         | `Assoc fields -> List.Assoc.mem fields "initial_boundary" ~equal:String.equal
         | _ -> false)
     && Poly.equal (field "stages" plan) (`List (List.map stages ~f:(fun s -> `String s))))
    "Finalize requires an exact completed fresh supported execution";
  let occurrences = Public.list (field "occurrences" execution) in
  let artifacts = Public.list (field "artifacts" execution) in
  let checkpoints = Public.list (field "checkpoints" report) in
  Public.require
    (List.length occurrences = List.length stages
     && List.length artifacts = List.length stages
     && List.length checkpoints = List.length stages)
    "Finalize requires all selected stage publications";
  List.iteri stages ~f:(fun i stage ->
    let occurrence = List.nth_exn occurrences i in
    let artifact = List.nth_exn artifacts i in
    let reference = field "reference" (List.nth_exn checkpoints i) in
    ignore (Public.absolute (Public.text (field "path" artifact)) : string);
    Public.require
      (not (String.is_empty (Public.text (field "identity" artifact))))
      "Selected checkpoint identity is missing";
    Public.require
      (Poly.equal (field "action_key" occurrence) (`String ("implementation." ^ stage))
       && Poly.equal
            (field "occurrence_id" occurrence)
            (`String (stream_id ^ "/implementation." ^ stage))
       && Poly.equal (field "status" occurrence) (`String "completed")
       && Poly.equal (field "exit_code" occurrence) (`Int 0)
       && Poly.equal (field "boundary" artifact) (`String stage)
       && List.for_all [ "path"; "identity"; "boundary" ] ~f:(fun key ->
         Poly.equal (field key artifact) (field key reference)))
      "Incomplete or mismatched selected stage evidence")
;;

module For_testing = struct
  let validate_finalization_execution = validate_finalization_execution
end

let finalization_eligibility t p cancel (f : Finalization_stored.t) =
  let v = f.value in
  let r = find_run p v.run in
  Public.require
    (Option.equal String.equal r.execution_file (Some v.execution_file))
    "Finalize requires the exact registered execution_file; Observe first";
  let%bind () = check_provider t p cancel in
  let%bind report =
    query
      t
      p
      cancel
      (invoke p (fun c ~root ~environment ->
         Adapter.report c ~root ~environment v.execution_file))
  in
  ignore
    (Public.summary
       r
       ~expected_plan:(expected_plan p v.run)
       ~execution_file:v.execution_file
       report
     : Asic.Summary.t);
  Option.iter (expected_bundle p v.run) ~f:(fun bundle ->
    Public.require
      (Poly.equal
         (Public.field "bundle_identity" (Public.field "methodology" report))
         (`String bundle))
      "Report bundle identity mismatch");
  let%bind metadata =
    if Poly.equal
         (Public.field "physical" (Public.field "completion" report))
         (`String "synthesis")
    then (
      let%map metadata = query t p cancel (invoke p Adapter.metadata) in
      Public.metadata metadata;
      metadata)
    else return `Null
  in
  let%map hash =
    In_thread.run (fun () ->
      Public.require
        (String.equal (Filename_unix.realpath v.execution_file) v.execution_file)
        "Finalize requires the exact canonical execution path";
      let bytes = read_public_bounded v.execution_file (8 * 1024 * 1024) in
      let execution = Public.decode bytes in
      validate_finalization_execution
        ~stream_id:r.reference.stream_id
        ~acceptance_requested:v.acceptance_requested
        ~metadata
        ~report
        execution;
      Public.digest bytes)
  in
  Public.require
    (Option.equal String.equal (find_run p v.run).execution_file (Some v.execution_file))
    "Execution reference changed during finalization validation";
  hash
;;

(* Reads only the reference delivered by the owned producer. A restarted service never
   reconstructs an attempt from an operation store, PID, newest directory, or run ID. *)
let inspect_owned_finalization t p cancel key =
  serialized p ("finalize-inspect:" ^ key) (fun () ->
    let f = find_finalization p key in
    match f.value.attempt with
    | None -> failwith "No finalization allocation reference was retained; never relaunch"
    | Some attempt ->
      let%bind receipt =
        query
          t
          p
          cancel
          (invoke p (fun c ~root ~environment ->
             Adapter.inspect_finalization c ~root ~environment attempt))
      in
      let receipt = Public.envelope receipt "hardcaml-asic.segment-finalization" 1 in
      let field = Public.field in
      let request = field "request" receipt in
      Public.require
        (Poly.equal (field "execution" request) (`String f.value.execution_file)
         && Poly.equal (field "accept" request) (`Bool f.value.acceptance_requested)
         && Option.value_map f.operation_id ~default:false ~f:(fun id ->
           Poly.equal (field "attempt_id" receipt) (`String id)))
        "Finalization receipt request/operation mismatch";
      List.iter
        [ ( "support_tools"
          , Option.map f.acceptance ~f:(fun a -> a.Asic.Acceptance.support_tools) )
        ; "precheck_python", Option.map f.acceptance ~f:(fun a -> a.precheck_python)
        ; "testbench", Option.map f.acceptance ~f:(fun a -> a.testbench)
        ; "testbench_top", Option.map f.acceptance ~f:(fun a -> a.testbench_top)
        ; "replay_trace", Option.map f.acceptance ~f:(fun a -> a.replay_trace)
        ]
        ~f:(fun (name, expected) ->
          Public.require
            (Poly.equal
               (field name request)
               (Option.value_map expected ~default:`Null ~f:(fun s -> `String s)))
            "Finalization acceptance inputs differ from reservation");
      let execution = field "execution" receipt in
      if not (Poly.equal execution `Null)
      then
        Public.require
          (Poly.equal (field "path" execution) (`String f.value.execution_file)
           && Poly.equal
                (field "attempt_id" execution)
                (`String (find_run p f.value.run).reference.stream_id)
           && Option.value_map f.execution_hash ~default:false ~f:(fun hash ->
             Poly.equal (field "sha256" execution) (`String hash)))
          "Finalization receipt differs from captured execution hash";
      let status = Public.text (field "status" receipt) in
      Public.require
        (List.mem
           [ "running"; "completed"; "failed"; "interrupted" ]
           status
           ~equal:String.equal)
        "Invalid finalization status";
      let terminal = not (String.equal status "running") in
      let acceptance = Public.text (field "acceptance" receipt) in
      Public.require
        (List.mem [ "not_evaluated"; "pass"; "fail" ] acceptance ~equal:String.equal
         && (String.equal acceptance "not_evaluated" || f.value.acceptance_requested)
         && ((not (String.equal acceptance "pass"))
             || (String.equal status "completed"
                 && Poly.equal (field "external_postcheck" receipt) (`String "completed")
                )))
        "Invalid or unearned finalization acceptance";
      if String.equal status "completed"
      then
        Public.require
          ((not (Poly.equal execution `Null))
           && not (Poly.equal (field "results" receipt) `Null))
          "Completed finalization lacks execution/results references";
      if terminal
      then (
        Public.require
          (not (Poly.equal (field "ended_at" receipt) `Null))
          "Terminal finalization has no end time";
        Public.require
          (Bool.equal
             (String.equal status "completed")
             (Public.integer (field "exit_code" receipt) = 0))
          "Finalization status/exit mismatch");
      update_finalization p key (fun current ->
        { current with
          value =
            { current.value with
              state =
                (if terminal
                 then status
                 else if current.value.owned
                 then "executing"
                 else "unknown")
            ; phase =
                Option.map
                  (Public.supplied_string (field "phase" receipt))
                  ~f:(fun s -> String.prefix s 4096)
            ; operation_status = Some status
            ; execution_timing =
                Public.receipt_timing
                  ~running:((not terminal) && current.value.owned)
                  receipt
            ; acceptance =
                (if terminal && not (Poly.equal (field "results" receipt) `Null)
                 then current.value.acceptance
                 else Some acceptance)
            }
        });
      let%bind () = save_required t p in
      let%bind () =
        if terminal && not (Poly.equal (field "results" receipt) `Null)
        then (
          let%bind hash =
            In_thread.run (fun () ->
              Public.digest (read_public_bounded f.value.execution_file (8 * 1024 * 1024)))
          in
          Public.require
            (Option.equal String.equal f.execution_hash (Some hash))
            "Captured execution bytes changed before terminal import";
          materialize ~attempt t p cancel f.value.run)
        else Deferred.unit
      in
      update_finalization p key (fun current ->
        let producer_error =
          Option.first_some
            current.producer_error
            (Option.map
               (Public.supplied_string (field "error" receipt))
               ~f:(fun s -> String.prefix s 4096))
        in
        let current =
          with_finalization_errors current ~producer_error ~observation_error:None
        in
        { current with value = { current.value with acceptance = Some acceptance } });
      let%map () = save_required t p in
      terminal)
;;

let launch_finalization t p key task =
  task.pending <- { task.pending with run = Some (find_finalization p key).value.run };
  let deadline = Clock.after (Time_float.Span.of_sec 1800.) in
  let stop = Ivar.create () in
  let cancel = Deferred.any [ Ivar.read task.cancel; Ivar.read stop; deadline ] in
  let finished = Ivar.create () in
  let polling = ref Deferred.unit in
  let polling_error = ref None in
  let result =
    Monitor.try_with (fun () ->
      let f = find_finalization p key in
      let%bind hash = finalization_eligibility t p cancel f in
      update_finalization p key (fun f ->
        { f with
          execution_hash = Some hash
        ; value = { f.value with state = "executing"; owned = true }
        });
      let%bind () = save_required t p in
      let on_line line =
        let j =
          Public.envelope (Public.decode line) "hardcaml-asic.segment-finalization" 1
        in
        match Public.field "event" j with
        | `String "allocated" ->
          let current = find_finalization p key in
          Public.require
            (Option.is_none current.value.attempt)
            "Duplicate finalization allocation";
          let attempt = Public.absolute (Public.text (Public.field "attempt" j)) in
          let operation_id = Public.text (Public.field "attempt_id" j) in
          Public.require
            (String.length attempt <= 4096
             && (not (String.is_empty operation_id))
             && String.length operation_id <= 256)
            "Invalid finalization allocation";
          update_finalization p key (fun f ->
            { f with
              operation_id = Some operation_id
            ; value = { f.value with attempt = Some attempt }
            });
          let%map () = save_required t p in
          let rec poll remaining =
            if Ivar.is_full finished || Deferred.is_determined cancel
            then Deferred.unit
            else (
              Public.require (remaining > 0) "Finalization observation budget exhausted";
              let%bind terminal = inspect_owned_finalization t p cancel key in
              if terminal
              then Deferred.unit
              else (
                let%bind () =
                  Deferred.any
                    [ Clock.after (Time_float.Span.of_sec 1.)
                    ; Ivar.read finished
                    ; cancel
                    ]
                in
                poll (remaining - 1)))
          in
          (polling
           := Monitor.try_with (fun () -> poll 1800)
              >>| function
              | Ok () -> ()
              | Error exn ->
                if (not (Ivar.is_full finished)) && not (Deferred.is_determined cancel)
                then (
                  polling_error := Some exn;
                  Ivar.fill_if_empty stop ()));
          don't_wait_for !polling
        | `Null ->
          Public.require
            (Option.is_some (find_finalization p key).value.attempt)
            "Finalization terminal output before allocation";
          Deferred.unit
        | _ -> failwith "Unexpected finalization producer event"
      in
      let%bind (_ : string) =
        Asic_process.run
          ~stop_grace_seconds:15.
          ~seconds:1800.
          ~cancel
          ~on_process:ignore
          ~on_line
          (invoke p (fun c ~root ~environment ->
             Adapter.finalize
               c
               ~root
               ~environment
               ~execution_file:f.value.execution_file
               ~acceptance:f.acceptance))
      in
      Public.require
        (Option.is_some (find_finalization p key).value.attempt)
        "Finalization producer exited without allocation";
      Deferred.unit)
  in
  let%bind result in
  Ivar.fill_if_empty finished ();
  let%bind polling_result = Monitor.try_with (fun () -> !polling) in
  update_finalization p key (fun f ->
    { f with
      value =
        { f.value with
          owned = false
        ; execution_timing = Execution_timing.stopped f.value.execution_timing
        }
    });
  (* Nonzero acceptance still publishes a valid receipt/results. Process outcome is kept
     in error/pending independently of the receipt's status and acceptance verdict. *)
  let%bind inspection =
    Monitor.try_with (fun () ->
      if Option.is_some (find_finalization p key).value.attempt
      then
        inspect_owned_finalization t p deadline key
        >>| fun terminal ->
        Public.require terminal "Producer exited with nonterminal finalization receipt"
      else Deferred.unit)
  in
  let poll_outcome =
    match !polling_error with
    | None -> polling_result
    | Some exn -> Error exn
  in
  let errors =
    List.filter_map [ result; poll_outcome; inspection ] ~f:(function
      | Ok () -> None
      | Error exn -> Some (Exn.to_string exn))
  in
  update_finalization p key (fun f ->
    let producer_errors =
      List.filter_map [ result; poll_outcome ] ~f:(function
        | Ok () -> None
        | Error exn -> Some (Exn.to_string exn))
    in
    let producer_error =
      if List.is_empty producer_errors
      then f.producer_error
      else Some (String.concat ~sep:"; " producer_errors)
    in
    let observation_error =
      match inspection with
      | Ok () -> None
      | Error exn -> Some (Exn.to_string exn)
    in
    let f = with_finalization_errors f ~producer_error ~observation_error in
    { f with
      value =
        { f.value with
          state =
            (if List.mem
                  [ "pending"; "executing"; "unknown" ]
                  f.value.state
                  ~equal:String.equal
             then
               if Ivar.is_full task.cancel
               then "interrupted"
               else if Option.is_none f.value.attempt
               then "failed"
               else "unknown"
             else f.value.state)
        }
    });
  let%bind () = save_required t p in
  if not (List.is_empty errors) then failwith (String.concat ~sep:"; " errors);
  let v = (find_finalization p key).value in
  Public.require (String.equal v.state "completed") ("Finalization operation " ^ v.state);
  Deferred.unit
;;

let reserve_finalization t p ~key ~run ~execution_file ~acceptance =
  validate_finalization_input ~key ~execution_file ~acceptance;
  ignore (find_run p run : Asic.Run.t);
  serialized p "finalization-reservations" (fun () ->
    match List.find p.finalizations ~f:(fun f -> String.equal f.value.key key) with
    | Some f ->
      Public.require
        (Run_ref.equal f.value.run run
         && String.equal f.value.execution_file execution_file
         && Option.equal Asic.Acceptance.equal f.acceptance acceptance)
        "Finalization key reused with different inputs";
      Deferred.unit
    | None ->
      Public.require
        p.registry_writable
        "ASIC registry unavailable; cannot reserve finalization";
      Public.require (not t.closing) "ASIC service shutting down";
      Public.require
        (List.length p.finalizations < 256)
        "Finalization reservation budget exhausted";
      let f : Finalization_stored.t =
        { value =
            { key
            ; run
            ; execution_file
            ; acceptance_requested = Option.is_some acceptance
            ; attempt = None
            ; state = "pending"
            ; phase = None
            ; operation_status = None
            ; acceptance = None
            ; error = None
            ; owned = true
            ; execution_timing = None
            }
        ; acceptance
        ; execution_hash = None
        ; operation_id = None
        ; producer_error = None
        ; observation_error = None
        }
      in
      Public.require
        (String.length
           (Sexp.to_string_mach
              ([%sexp_of: Finalization_stored.t list] (f :: p.finalizations)))
         <= 512 * 1024)
        "Finalization retained input budget exhausted";
      p.finalizations <- f :: p.finalizations;
      let%bind result =
        Monitor.try_with (fun () ->
          let%map () = save_required t p in
          schedule
            t
            p
            ~key:("finalize:" ^ key)
            ~kind:"finalize"
            ~execution:true
            (launch_finalization t p key))
      in
      (match result with
       | Ok () -> Deferred.unit
       | Error exn ->
         update_finalization p key (fun f ->
           let f =
             with_finalization_errors
               f
               ~producer_error:(Some (Exn.to_string exn))
               ~observation_error:None
           in
           { f with value = { f.value with state = "failed"; owned = false } });
         let%bind () = persist t p in
         raise exn))
;;

let inspection_matches (index : Inspection_wire.Index.t) ~run ~domain ~stage =
  Run_ref.equal index.run run
  && String.equal index.domain domain
  && String.equal index.stage stage
;;

let detail_source_identity (registered : Asic.Run.t) (index : Inspection_wire.Index.t) =
  (* Include all row/index content, even if a provider reuses a digest. Observation times
     and the offline label are not source identity. No filesystem I/O on hits. *)
  Public.digest
    (Sexp.to_string_mach
       [%sexp
         (registered.run : Run_ref.t)
         , (registered.reference : Asic.Reference.t)
         , (registered.cursor : int)
         , (registered.execution_file : string option)
         , ({ index with times = Evidence_time.Index.empty; cached_unverified = false }
            : Inspection_wire.Index.t)])
;;

let detail_identity registered index row_id =
  detail_source_identity registered index ^ ":" ^ Public.digest row_id
;;

let retain_current_details p =
  let sources =
    List.map p.inspections ~f:(fun index ->
      index, detail_source_identity (find_run p index.run) index)
  in
  Inspection_detail_cache.retain p.detail_cache ~f:(fun ~identity detail ->
    List.exists sources ~f:(fun (index, source_identity) ->
      inspection_matches index ~run:detail.run ~domain:detail.domain ~stage:detail.stage
      && String.equal index.source_digest detail.source_digest
      && List.exists index.rows ~f:(fun row -> String.equal row.id detail.row_id)
      && String.equal identity (source_identity ^ ":" ^ Public.digest detail.row_id)))
;;

let publish_detail p (detail : Inspection_wire.Detail.t) =
  let key d =
    Inspection_wire.detail_key
      ~run:d.Inspection_wire.Detail.run
      ~domain:d.domain
      ~stage:d.stage
      ~source_digest:d.source_digest
      ~row_id:d.row_id
  in
  p.inspection_details
  <- List.take
       (detail
        :: List.filter p.inspection_details ~f:(fun old ->
          not (String.equal (key old) (key detail))))
       8
;;

let publish_inspection p (index : Inspection_wire.Index.t) =
  (* Publication invalidation must compare full source identity, not just digest:
     unchanged digests can accompany changed rows or execution hashes. *)
  let previous =
    List.find p.inspections ~f:(fun old ->
      inspection_matches old ~run:index.run ~domain:index.domain ~stage:index.stage)
  in
  Option.iter previous ~f:(fun old ->
    let registered = find_run p index.run in
    if not
         (String.equal
            (detail_source_identity registered old)
            (detail_source_identity registered index))
    then
      p.inspection_details
      <- List.filter p.inspection_details ~f:(fun detail ->
           not
             (Run_ref.equal detail.Inspection_wire.Detail.run index.run
              && String.equal detail.domain index.domain
              && String.equal detail.stage index.stage)));
  p.inspections
  <- List.take
       (index
        :: List.filter p.inspections ~f:(fun old ->
          not
            (inspection_matches
               old
               ~run:index.run
               ~domain:index.domain
               ~stage:index.stage)))
       8;
  p.inspection_details
  <- List.filter p.inspection_details ~f:(fun detail ->
       List.exists p.inspections ~f:(fun current ->
         inspection_matches
           current
           ~run:detail.Inspection_wire.Detail.run
           ~domain:detail.domain
           ~stage:detail.stage
         && String.equal current.source_digest detail.source_digest
         && List.exists current.rows ~f:(fun row -> String.equal row.id detail.row_id)));
  retain_current_details p
;;

let check_inspection_current p cancel (registered : Asic.Run.t) =
  Public.require (not (Deferred.is_determined cancel)) "Inspection read cancelled";
  let current = find_run p registered.run in
  (* [registered] is the immutable pre-read snapshot. Path equality alone cannot fence an
     observation that advances the generation at the same public execution path. *)
  Public.require
    (Asic.Reference.equal current.reference registered.reference
     && current.cursor = registered.cursor
     && Option.equal String.equal current.execution_file registered.execution_file)
    "Registered execution changed during inspection; request again"
;;

let inspection_hash t p cancel registered execution_file =
  Throttle.enqueue t.queries (fun () ->
    check_inspection_current p cancel registered;
    In_thread.run (fun () -> Inspection.execution_hash ~registered ~execution_file))
;;

let check_analysis_target registered analysis (index : Inspection_wire.Index.t) =
  Option.iter analysis ~f:(fun target ->
    Asic_timing_analysis.validate_target target;
    Public.require
      (String.equal target.attempt_id registered.Asic.Run.reference.stream_id
       && Option.equal Inspection_wire.Analysis_target.equal (Some target) index.analysis
      )
      "Captured timing analysis changed or is unavailable")
;;

let load_inspection t p cancel ~analysis ~run ~domain ~stage ~refresh ~on_read =
  serialized p "inspection-publication" (fun () ->
    let registered = find_run p run in
    let execution_file =
      Option.value_exn
        registered.execution_file
        ~message:"No registered execution_file; Observe first"
    in
    let fetch () =
      on_read ();
      p.inspections
      <- List.map p.inspections ~f:(fun index ->
           if inspection_matches index ~run ~domain ~stage
           then { index with cached_unverified = true }
           else index);
      let%bind () = check_provider t p cancel in
      let%bind execution_sha256 = inspection_hash t p cancel registered execution_file in
      let%bind () =
        In_thread.run (fun () ->
          Option.iter analysis ~f:(Asic_timing_analysis.validate_source ~execution_file))
      in
      let%bind response =
        query
          ~max_bytes:Inspection.index_limit
          ~before:(fun () -> check_inspection_current p cancel registered)
          t
          p
          cancel
          (invoke p (fun c ~root ~environment ->
             Adapter.inspection
               ?expected_analysis_digest:
                 (Option.map analysis ~f:(fun target ->
                    target.Inspection_wire.Analysis_target.source_digest))
               c
               ~root
               ~environment
               ~execution_file
               ~domain
               ~stage
               ~detail:None))
      in
      let index =
        Inspection.parse_index
          ?analysis
          ~registered
          ~execution_file
          ~execution_sha256
          ~domain
          ~stage
          response
      in
      check_analysis_target registered analysis index;
      let%bind after = inspection_hash t p cancel registered execution_file in
      Public.require
        (String.equal after execution_sha256)
        "Execution bytes changed during inspection";
      let%bind () =
        In_thread.run (fun () ->
          Option.iter analysis ~f:(Asic_timing_analysis.validate_source ~execution_file))
      in
      let validated_at = Timestamp.of_time_ns (Time_ns.now ()) in
      let%bind index =
        In_thread.run (fun () ->
          Inspection.observe_times ~execution_file ~validated_at index)
      in
      let%map () =
        Throttle.enqueue t.queries (fun () ->
          check_inspection_current p cancel registered;
          In_thread.run (fun () ->
            Inspection.save
              ~rebuild_invalid:true
              ~state_dir:t.state_dir
              ~identity:p.identity
              index))
      in
      index
    in
    let started_refresh = !refresh in
    let cached () =
      let%map index =
        match
          List.find p.inspections ~f:(fun index ->
            inspection_matches index ~run ~domain ~stage)
        with
        | Some index ->
          Public.require
            (String.equal index.execution_file execution_file)
            "Stale inspection execution";
          return index
        | None ->
          Throttle.enqueue t.queries (fun () ->
            check_inspection_current p cancel registered;
            In_thread.run (fun () ->
              Inspection.load
                ~state_dir:t.state_dir
                ~identity:p.identity
                ~run
                ~execution_file
                ~domain
                ~stage))
      in
      (* The generic slot can contain checkpoint-backed evidence or another analysis. Such
         an entry is a miss for a captured target, not proof that its source changed. The
         fallback fetch remains pinned and validates the reply below. *)
      check_analysis_target registered analysis index;
      index
    in
    let%bind initial =
      Monitor.try_with (fun () -> if started_refresh then fetch () else cached ())
    in
    (* Inspect is an explicit user read. Warm ordinary loads stay offline, while a
       missing/invalid cache falls back to the same bounded read-only query as Refresh.
       Rendering/Get never enters this path. A refresh also upgrades an in-flight cache
       lookup under the same wait key without issuing a duplicate fetch. *)
    let%bind index =
      if !refresh && not started_refresh
      then fetch ()
      else (
        match initial with
        | Ok index -> return index
        | Error _ when not started_refresh -> fetch ()
        | Error exn -> raise exn)
    in
    check_inspection_current p cancel registered;
    check_analysis_target registered analysis index;
    publish_inspection p index;
    Deferred.unit)
;;

let load_inspection_detail
  t
  p
  cancel
  ~analysis
  ~run
  ~domain
  ~stage
  ~source_digest
  ~row_id
  ~on_read
  =
  serialized p "inspection-publication" (fun () ->
    let registered = find_run p run in
    let index =
      List.find p.inspections ~f:(fun index ->
        inspection_matches index ~run ~domain ~stage)
      |> Option.value_exn ~message:"Load inspection index before requesting detail"
    in
    check_analysis_target registered analysis index;
    Public.require
      (String.equal index.source_digest source_digest
       && Option.equal String.equal registered.execution_file (Some index.execution_file)
       && List.exists index.rows ~f:(fun row -> String.equal row.id row_id))
      "Stale inspection digest or unknown row";
    check_inspection_current p cancel registered;
    let identity = detail_identity registered index row_id in
    match Inspection_detail_cache.find p.detail_cache identity with
    | Some detail ->
      publish_detail p detail;
      Deferred.unit
    | None ->
      on_read ();
      let%bind () = check_provider t p cancel in
      let%bind hash = inspection_hash t p cancel registered index.execution_file in
      let%bind () =
        In_thread.run (fun () ->
          Option.iter
            index.analysis
            ~f:(Asic_timing_analysis.validate_source ~execution_file:index.execution_file))
      in
      Public.require
        (String.equal hash index.execution_sha256
         || Option.exists index.analysis ~f:(fun target ->
           Option.is_some target.execution_file))
        "Inspection execution bytes changed";
      let%bind response =
        query
          ~max_bytes:(512 * 1024)
          ~before:(fun () -> check_inspection_current p cancel registered)
          t
          p
          cancel
          (invoke p (fun c ~root ~environment ->
             Adapter.inspection
               c
               ~root
               ~environment
               ~execution_file:index.execution_file
               ~domain
               ~stage
               ~detail:(Some (row_id, source_digest))))
      in
      let detail =
        Inspection.parse_detail ~execution_sha256:hash ~registered ~index ~row_id response
      in
      let%bind after = inspection_hash t p cancel registered index.execution_file in
      Public.require
        (String.equal after hash)
        "Execution bytes changed during detail read";
      let%map () =
        In_thread.run (fun () ->
          Option.iter
            index.analysis
            ~f:(Asic_timing_analysis.validate_source ~execution_file:index.execution_file))
      in
      check_inspection_current p cancel registered;
      Inspection_detail_cache.add p.detail_cache ~identity detail;
      publish_detail p detail)
;;

let fresh_scope ?(physical = true) p =
  In_thread.run (fun () ->
    let module Preparation_config =
      Hardcaml_workbench_project_integration.Preparation_config
    in
    let preparation =
      Preparation_config.parse_string
        (read_bounded (Filename.concat p.root Preparation_config.filename) 65536)
      |> Or_error.ok_exn
    in
    let asic_path = Filename.concat p.root Config.filename in
    let current =
      match Sys_unix.file_exists asic_path with
      | `No -> None
      | `Yes | `Unknown ->
        Some (Config.parse_string (read_bounded asic_path 65536) |> Or_error.ok_exn)
    in
    Public.require
      (Option.equal Config.equal current p.config)
      "ASIC configuration changed; loaded provider scope is stale";
    let provider_stamp =
      if not physical
      then "elaboration-only"
      else (
        let config = config p in
        Public.require
          (Poly.equal (Core_unix.stat config.provider_executable).st_kind S_REG)
          "Provider executable must be a regular file";
        Filename_unix.realpath config.provider_executable
        ^ Preparation_receipt.sha256
            (read_bounded config.provider_executable (128 * 1024 * 1024)))
    in
    Sexp.to_string_mach
      (Sexp.List
         [ Sexp.List [ Atom "project_scope"; Sexp.of_string p.identity ]
         ; Sexp.List [ Atom "provider_stamp"; Atom provider_stamp ]
         ; Sexp.List [ Atom "preparation"; Preparation_config.sexp_of_t preparation ]
         ]))
;;

let workflow p id =
  List.find_exn p.workflows ~f:(fun w -> String.equal w.Asic.Fresh.Workflow.id id)
;;

let update_workflow p id f =
  p.workflows
  <- List.map p.workflows ~f:(fun w ->
       if String.equal w.Asic.Fresh.Workflow.id id then f w else w)
;;

let workflow_active (w : Asic.Fresh.Workflow.t) =
  match w.phase with
  | Reserved | Building | Emitting | Prepared | Physical -> true
  | Completed | Failed | Cancelled | Interrupted -> false
;;

let workflow_cancel_key (w : Asic.Fresh.Workflow.t) key =
  List.mem [ w.id; w.key; "run:" ^ w.key; "workflow:" ^ w.id ] key ~equal:String.equal
;;

let legacy_intent_id key preview =
  "legacy-fresh-"
  ^ Public.digest (key ^ Sexp.to_string_mach (Asic.Preview.sexp_of_t preview))
;;

let await_workflow_reservation p key =
  match Hashtbl.find p.workflow_reservations key with
  | None -> Deferred.unit
  | Some result ->
    result
    >>| (function
     | Ok () -> ()
     | Error exn -> raise exn)
;;

let resource_target p (target : Asic_resources.Target.t) =
  let absolute path =
    Public.require (String.length path <= 4096 && not (String.contains path '\000')) "Resource path budget";
    Public.absolute path in
  match target with
  | Coarse_run path -> "coarse_run", absolute path, Sexp.to_string_mach (Asic_resources.Target.sexp_of_t target)
  | Bundle path -> "bundle", absolute path, Sexp.to_string_mach (Asic_resources.Target.sexp_of_t target)
  | Workflow_bundle id ->
    let w = List.find_exn p.workflows ~f:(fun w -> String.equal w.Asic.Fresh.Workflow.id id) in
    let b = Option.value_exn w.prepared ~message:"Workflow has no verified emitted bundle" in
    "bundle", b.bundle_directory, Sexp.to_string_mach (Asic.Fresh.Prepared.sexp_of_t b)
  | Run run ->
    let r = find_run p run in
    "execution", Option.value_exn r.execution_file ~message:"Run has no registered execution; Observe first",
    Sexp.to_string_mach (Asic.Run.sexp_of_t r)
  | Finalization { run; attempt } ->
    let r = find_run p run in
    let adopted = List.exists p.terminal_attempts ~f:(fun (id,path) -> String.equal id run.id && String.equal path attempt)
      || List.exists p.finalizations ~f:(fun f -> Run_ref.equal f.value.run run && Option.equal String.equal f.value.attempt (Some attempt)) in
    Public.require adopted "Resource finalization must be explicitly adopted for this run";
    "finalization", absolute attempt, Sexp.to_string_mach (Asic.Run.sexp_of_t r)
;;

let resource_provider_identity p =
  let executable = Filename_unix.realpath (config p).provider_executable in
  let companion = Filename.concat (Filename.dirname executable)
    (if String.equal (Filename.basename executable) "flow_cli.exe"
     then "experimental_resource_inspect.exe" else "hardcaml-asic-experimental-resource-inspect") in
  let hash path =
    let fd = Core_unix.openfile path ~mode:[O_RDONLY;O_NONBLOCK;O_CLOEXEC] in
    Exn.protect ~finally:(fun () -> Core_unix.close fd) ~f:(fun () ->
      let before = Core_unix.fstat fd in
      Public.require (Poly.equal before.st_kind S_REG && Int64.(before.st_size <= of_int 134217728)) "Resource provider binary budget/type";
      let h = Cryptokit.Hash.sha256 () and buf = Bytes.create 65536 in
      let total = ref 0 in
      let rec loop () =
        let n = Core_unix.read fd ~buf ~pos:0 ~len:(Bytes.length buf) in
        if n > 0 then (
          total := !total+n;
          Public.require (!total <= 128*1024*1024) "Provider binary grew beyond budget";
          h#add_substring buf 0 n;
          loop ()) in
      loop ();
      let after=Core_unix.fstat fd in
      Public.require (Int.equal before.st_ino after.st_ino && Int64.equal before.st_size after.st_size
        && Poly.equal before.st_mtime after.st_mtime && Poly.equal before.st_ctime after.st_ctime)
        "Provider binary changed while hashing";
      Cryptokit.transform_string (Cryptokit.Hexa.encode ()) h#result) in
  Public.digest (executable ^ "\000" ^ hash executable ^ "\000" ^ Filename_unix.realpath companion ^ "\000" ^ hash companion)
;;

let check_resource_lineage p target response =
  let provenance = Public.field "provenance" response in
  let linked_bundle run build =
    List.iter p.workflows ~f:(fun w ->
      if Option.equal Run_ref.equal w.Asic.Fresh.Workflow.run (Some run) then
        Option.iter w.prepared ~f:(fun b ->
          Public.require (Poly.equal build (`String b.bundle_identity)) "Resource execution/workflow bundle mismatch")) in
  match (target : Asic_resources.Target.t) with
  | Workflow_bundle id ->
    let w = List.find_exn p.workflows ~f:(fun w -> String.equal w.Asic.Fresh.Workflow.id id) in
    let b = Option.value_exn w.prepared in
    Public.require (Poly.equal (Public.field "build_identity" provenance) (`String b.bundle_identity)) "Resource bundle/workflow identity mismatch"
  | Run run ->
    let r=find_run p run in
    Public.require (Poly.equal (Public.field "attempt_id" provenance) (`String r.reference.stream_id)) "Resource named execution/run mismatch";
    linked_bundle run (Public.field "build_identity" provenance)
  | Finalization {run;_} ->
    let r=find_run p run in
    let execution=Public.field "execution" (Public.field "finalization" provenance) in
    Public.require (Poly.equal (Public.field "attempt_id" execution) (`String r.reference.stream_id)
      && Poly.equal (Public.field "path" execution) (Option.value_map r.execution_file ~default:`Null ~f:(fun s -> `String s)))
      "Resource finalization/selected execution mismatch";
    linked_bundle run (Public.field "build_identity" (Public.field "resource_provenance" provenance))
  | Coarse_run _ | Bundle _ -> ()
;;

let rec handle_operation ?prepared_input t p operation =
  let analysis, operation =
    match operation with
    | Asic.Operation.Inspect_analysis { run; target; refresh } ->
      ( Some target
      , Asic.Operation.Inspect { run; domain = "timing"; stage = target.stage; refresh } )
    | Inspect_analysis_detail { run; target; source_digest; row_id } ->
      ( Some target
      , Asic.Operation.Inspect_detail
          { run; domain = "timing"; stage = target.stage; source_digest; row_id } )
    | operation -> None, operation
  in
  Option.iter analysis ~f:Asic_timing_analysis.validate_target;
  let enqueue ~key ~kind f =
    schedule t p ~key ~kind ~execution:false (fun task -> f (Ivar.read task.cancel))
  in
  let public_query ~key ~kind invocation apply =
    enqueue ~key ~kind (fun cancel ->
      let%bind () = check_provider t p cancel in
      let%map value = query t p cancel invocation in
      apply value)
  in
  match operation with
  | Asic.Operation.Get -> Deferred.unit
  | Workloads (Asic_workloads.Operation.Load { query = workload_query; refresh } as operation) ->
    Asic_workloads_service.select p.workloads workload_query;
    let key = Asic_workloads.Operation.key operation in
    (match Hashtbl.find p.workload_refreshes key with
     | Some requested -> if refresh then requested := true
     | None ->
       let requested = ref refresh in
       Hashtbl.set p.workload_refreshes ~key ~data:requested;
       let start () =
         schedule t p ~key ~kind:"workloads" ~execution:false (fun task ->
           Monitor.protect
             ~finally:(fun () -> Hashtbl.remove p.workload_refreshes key; Deferred.unit)
             (fun () -> serialized p "workloads-publication" (fun () ->
               task.pending <- { task.pending with activity = Evidence_cache_lookup };
               if not !requested && Asic_workloads_service.cached p.workloads workload_query
               then Deferred.unit
               else (
                 task.pending <- { task.pending with activity = Evidence_read };
                 let%bind result = Monitor.try_with (fun () ->
                   let cancel = Ivar.read task.cancel in
                   let executable = (config p).provider_executable in
                   let%bind provider_identity = In_thread.run (fun () ->
                     Asic_workloads_service.check_separation ~state_dir:t.state_dir workload_query;
                     Asic_workloads_service.provider_identity ~executable workload_query) in
                   let%bind paths = In_thread.run (fun () ->
                     Asic_workloads_service.capture_targets workload_query) in
                   let%bind metadata = query ~max_bytes:(1024*1024) t p cancel (invoke p Adapter.metadata) in
                   Asic_workloads_service.check_capabilities workload_query metadata;
                   let%bind raw = Throttle.enqueue t.queries (fun () ->
                     Asic_process.run ~max_stdout_bytes:(1024*1024) ~max_record_bytes:(1024*1024)
                       ~seconds:30. ~cancel ~on_process:ignore ~on_line:(fun _ -> Deferred.unit)
                       (invoke p (fun c ~root ~environment -> Adapter.workloads c ~root ~environment workload_query))) in
                   let%bind after = In_thread.run (fun () ->
                     Public.require (List.equal String.equal paths
                       (Asic_workloads_service.capture_targets workload_query)) "Workload selected root aliases changed during read";
                     Asic_workloads_service.provider_identity ~executable workload_query) in
                   Public.require (String.equal provider_identity after) "Workload provider changed during read";
                   Public.require (not (Ivar.is_full task.cancel)) "Workload read cancelled";
                   Asic_workloads_service.check_targets workload_query ~paths raw;
                   Asic_workloads_service.publish ~paths
                     ~check:(fun () -> Public.require (not (Ivar.is_full task.cancel)) "Workload read cancelled")
                     p.workloads workload_query ~provider_identity raw)
                 in
                 match result with
                 | Ok () -> Deferred.unit
                 | Error exn ->
                   Asic_workloads_service.fail p.workloads workload_query (Exn.to_string exn);
                   raise exn))))
       in
       (try start () with exn -> Hashtbl.remove p.workload_refreshes key; raise exn));
    Deferred.unit
  | Resources operation ->
    let key = Asic_resources.Operation.key operation in
    (match operation with
     | Asic_resources.Operation.Load { target; refresh } ->
       (match Hashtbl.find p.resource_refreshes key with
        | Some requested -> if refresh then requested := true
        | None ->
          let requested = ref refresh in
          Hashtbl.set p.resource_refreshes ~key ~data:requested;
          let start () =
          schedule t p ~key ~kind:"resources" ~execution:false (fun task ->
            Monitor.protect ~finally:(fun () -> Hashtbl.remove p.resource_refreshes key; Deferred.unit)
              (fun () ->
                task.pending <- {task.pending with activity=Evidence_cache_lookup};
                serialized p "resources-publication" (fun () ->
                  if not !requested && Asic_resources_service.cached p.resources target then Deferred.unit
                  else (
                    task.pending <- {task.pending with activity=Evidence_read};
                    let%bind result = Monitor.try_with (fun () ->
                      let kind,path,binding = resource_target p target in
                      let%bind () = In_thread.run (fun () ->
                        match target with
                        | Asic_resources.Target.Workflow_bundle id ->
                          let w=List.find_exn p.workflows ~f:(fun w -> String.equal w.Asic.Fresh.Workflow.id id) in
                          let b=Option.value_exn w.prepared in
                          let raw=Asic_evidence_file.read_bounded b.methodology_plan_path (16*1024*1024) in
                          Public.require (String.equal (Public.digest raw) b.methodology_plan_digest) "Workflow resource plan bytes changed";
                          let plan=Public.decode raw in
                          Public.require (Poly.equal (Public.field "bundle_identity" plan) (`String b.bundle_identity)
                            && Poly.equal (Public.field "plan_identity" plan) (`String b.plan_identity))
                            "Workflow resource plan/bundle identity mismatch"
                        | _ -> ()) in
                      let%bind path = In_thread.run (fun () -> Filename_unix.realpath path) in
                      let%bind () = In_thread.run (fun () ->
                        let source_root = if String.equal kind "execution" then Filename.dirname path else path in
                        let cache = Filename_unix.realpath t.state_dir in
                        Public.require (not (String.equal source_root "/" || String.equal cache source_root
                          || String.is_prefix cache ~prefix:(source_root ^ "/")))
                          "Resource cache must be outside the selected evidence root") in
                      let%bind metadata = query t p (Ivar.read task.cancel) (invoke p Adapter.metadata) in
                      Public.metadata metadata;
                      Public.require (Poly.equal (Public.field "resource_inspection1" (Public.field "capabilities" (Public.field "cli_contract" metadata))) (`Bool true)) "Provider lacks resource_inspection1";
                      let%bind provider_identity = In_thread.run (fun () -> resource_provider_identity p) in
                      let check () =
                        Public.require (not (Ivar.is_full task.cancel)) "Resource read cancelled";
                        let current_kind,_,current_binding = resource_target p target in
                        Public.require (String.equal current_kind kind && String.equal current_binding binding) "Resource target changed during read" in
                      let query args =
                        let%bind output = Throttle.enqueue t.queries (fun () ->
                           Asic_process.run_with_status ~accept_evidence_failure:true ~max_stdout_bytes:(2*1024*1024) ~max_record_bytes:(2*1024*1024) ~seconds:30. ~cancel:(Ivar.read task.cancel)
                            ~on_process:ignore ~on_line:(fun _ -> Deferred.unit)
                            (invoke p (fun c ~root ~environment -> Adapter.resources c ~root ~environment ~kind ~target:path args))) in
                        check ();
                        let%map after = In_thread.run (fun () -> resource_provider_identity p) in
                        Public.require (String.equal after provider_identity) "Resource provider changed during read";
                         Public.require (String.length output.stdout <= 2*1024*1024) "Resource provider index budget";
                         let response=Asic_resources_service.parse_process_result output in
                        check_resource_lineage p target response;
                        response in
                      Asic_resources_service.load p.resources ~target ~kind ~path ~provider_identity ~check ~query)
                    in
                    match result with
                    | Ok () -> Deferred.unit
                    | Error exn -> Asic_resources_service.fail p.resources target (Exn.to_string exn); raise exn)))) in
          (try start () with exn -> Hashtbl.remove p.resource_refreshes key; raise exn))
     | _ ->
       schedule t p ~key ~kind:"resources" ~execution:false (fun task ->
         task.pending <- {task.pending with activity=Evidence_read};
         serialized p "resources-publication" (fun () ->
           let id = match operation with
             | Detail {source_id;_} | Artifacts {source_id;_} | Read_artifact {source_id;_} -> source_id
             | Load _ -> assert false in
           let s = Asic_resources_service.source p.resources id in
           let _,_,binding = resource_target p s.target in
           let%bind provider_identity = In_thread.run (fun () -> resource_provider_identity p) in
           Public.require (String.equal provider_identity s.provider_identity) "Resource provider generation changed; refresh index";
           let check () =
             Public.require (not (Ivar.is_full task.cancel)) "Resource read cancelled";
             let _,_,current = resource_target p s.target in
             Public.require (String.equal binding current) "Resource target changed during page read" in
           let query args =
             let%bind output = Throttle.enqueue t.queries (fun () ->
               Asic_process.run_with_status ~accept_evidence_failure:true ~max_stdout_bytes:65536 ~max_record_bytes:65536 ~seconds:30. ~cancel:(Ivar.read task.cancel)
                 ~on_process:ignore ~on_line:(fun _ -> Deferred.unit)
                 (invoke p (fun c ~root ~environment -> Adapter.resources c ~root ~environment ~kind:s.kind ~target:s.path args))) in
             let%map after = In_thread.run (fun () -> resource_provider_identity p) in
             Public.require (String.equal after provider_identity) "Resource provider changed during page read";
              Public.require (String.length output.stdout <= 65536) "Resource provider page budget";
              Asic_resources_service.parse_process_result output in
           Asic_resources_service.page p.resources operation ~check ~query)));
    Deferred.unit
  | Inspect_analysis _ | Inspect_analysis_detail _ -> assert false
  | Inspect { run; domain; stage; refresh } ->
    ignore (find_run p run : Asic.Run.t);
    Inspection.validate_selection ~domain ~stage;
    let key =
      match analysis with
      | None -> Inspection_wire.index_key ~run ~domain ~stage
      | Some target -> Inspection_wire.analysis_index_key ~run ~target
    in
    (match Hashtbl.find p.inspection_refreshes key with
     | Some requested -> if refresh then requested := true
     | None ->
       let requested = ref refresh in
       Hashtbl.set p.inspection_refreshes ~key ~data:requested;
       (try
          schedule t p ~key ~kind:"inspection" ~execution:false (fun task ->
            (* Only a provider query is reported as an evidence read; a warm reopen
               reports a cache lookup until (unless) it falls back to the provider. *)
            task.pending
            <- { task.pending with
                 run = Some run
               ; activity = (if !requested then Evidence_read else Evidence_cache_lookup)
               };
            Monitor.protect
              ~finally:(fun () ->
                Hashtbl.remove p.inspection_refreshes key;
                Deferred.unit)
              (fun () ->
                load_inspection
                  t
                  p
                  (Ivar.read task.cancel)
                  ~analysis
                  ~run
                  ~domain
                  ~stage
                  ~refresh:requested
                  ~on_read:(fun () ->
                    task.pending <- { task.pending with activity = Evidence_read })))
        with
        | exn ->
          Hashtbl.remove p.inspection_refreshes key;
          raise exn));
    Deferred.unit
  | Inspect_detail { run; domain; stage; source_digest; row_id } ->
    ignore (find_run p run : Asic.Run.t);
    Inspection.validate_selection ~domain ~stage;
    Inspection.validate_digest source_digest;
    Inspection.validate_row_id row_id;
    schedule
      t
      p
      ~key:
        (match analysis with
         | None -> Inspection_wire.detail_key ~run ~domain ~stage ~source_digest ~row_id
         | Some target ->
           Inspection_wire.analysis_detail_key ~run ~target ~source_digest ~row_id)
      ~kind:"inspection-detail"
      ~execution:false
      (fun task ->
        task.pending
        <- { task.pending with run = Some run; activity = Evidence_cache_lookup };
        let cancel = Ivar.read task.cancel in
        let%bind result =
          Monitor.try_with (fun () ->
            load_inspection_detail
              t
              p
              cancel
              ~analysis
              ~run
              ~domain
              ~stage
              ~source_digest
              ~row_id
              ~on_read:(fun () ->
                task.pending <- { task.pending with activity = Evidence_read }))
        in
        match result with
        | Ok () -> Deferred.unit
        | Error exn ->
          let detail : Inspection_wire.Detail.t =
            { run
            ; domain
            ; stage
            ; source_digest
            ; row_id
            ; text = ""
            ; error = Some (Exn.to_string exn)
            }
          in
          publish_detail p detail;
          raise exn);
    Deferred.unit
  | Finalize { key; run; execution_file; acceptance } ->
    reserve_finalization t p ~key ~run ~execution_file ~acceptance
  | Observe_finalization key ->
    let f = find_finalization p key in
    enqueue ~key:("finalize-observe:" ^ key) ~kind:"finalize-observe" (fun cancel ->
      let%bind result =
        Monitor.try_with (fun () ->
          let%bind () = check_provider t p cancel in
          inspect_owned_finalization t p cancel key >>| fun _ -> ())
      in
      match result with
      | Ok () -> Deferred.unit
      | Error exn ->
        update_finalization p key (fun current ->
          with_finalization_errors
            current
            ~producer_error:current.producer_error
            ~observation_error:(Some (Exn.to_string exn)));
        let%bind () = persist t p in
        raise exn);
    ignore (f : Finalization_stored.t);
    Deferred.unit
  | List_artifacts run ->
    ignore (find_run p run : Asic.Run.t);
    enqueue ~key:("artifacts:" ^ run.id) ~kind:"artifacts" (fun cancel ->
      Public.require (not (Deferred.is_determined cancel)) "Artifact listing cancelled";
      let summary = Hashtbl.find_exn p.hot run.id in
      Public.require
        (Run_ref.equal summary.run run && Option.is_some summary.terminal)
        "Artifacts require an adopted validated terminal summary; load it first";
      let%map references =
        Throttle.enqueue t.queries (fun () ->
          Public.require
            (not (Deferred.is_determined cancel))
            "Artifact listing cancelled";
          In_thread.run (fun () -> Asic_artifacts.list ~summary))
      in
      Public.require (not (Deferred.is_determined cancel)) "Artifact listing cancelled";
      Public.require
        (String.equal (Hashtbl.find_exn p.hot run.id).source_digest summary.source_digest)
        "Terminal summary changed while listing artifacts";
      p.artifacts
      <- List.take references 32
         @ List.filter p.artifacts ~f:(fun r ->
           not (Run_ref.equal r.Asic_artifact.Reference.run run));
      (* At most 32 catalogs (the hot-summary bound), each containing at most 32 refs. *)
      p.artifacts <- List.filter p.artifacts ~f:(fun r -> Hashtbl.mem p.hot r.run.id);
      p.artifact_pages
      <- List.filter p.artifact_pages ~f:(fun page ->
           not (Run_ref.equal page.Asic_artifact.Page.run run));
      p.artifact_byte_pages
      <- List.filter p.artifact_byte_pages ~f:(fun page ->
           not (Run_ref.equal page.Asic_artifact.Byte_page.run run));
      prune_byte_pages p);
    Deferred.unit
  | Read_artifact_bytes { run; artifact_id; offset; limit } ->
    ignore (find_run p run : Asic.Run.t);
    Public.require (String.length artifact_id <= 256) "Artifact ID exceeds budget";
    Public.require
      (offset >= 0 && limit > 0 && limit <= 64 * 1024)
      "Artifact byte page requires nonnegative offset and limit 1..65536";
    enqueue
      ~key:(Asic_artifact.byte_read_key ~run ~artifact_id ~offset ~limit)
      ~kind:"artifact-byte-read"
      (fun cancel ->
         Public.require
           (not (Deferred.is_determined cancel))
           "Artifact byte read cancelled";
         let summary = Hashtbl.find_exn p.hot run.id in
         Public.require (Run_ref.equal summary.run run) "Wrong artifact summary run";
         let terminal = Option.value_exn summary.terminal in
         let reference =
           List.find_exn p.artifacts ~f:(fun reference ->
             Run_ref.equal reference.Asic_artifact.Reference.run run
             && String.equal reference.id artifact_id
             && String.equal reference.terminal_attempt terminal.attempt)
         in
         let%map page =
           Throttle.enqueue t.queries (fun () ->
             Public.require
               (not (Deferred.is_determined cancel))
               "Artifact byte read cancelled";
             In_thread.run (fun () -> Asic_artifacts.read_bytes ~reference ~offset ~limit))
         in
         Public.require
           (not (Deferred.is_determined cancel))
           "Artifact byte read cancelled";
         let current = Hashtbl.find_exn p.hot run.id in
         Public.require
           (Run_ref.equal current.run run
            && String.equal current.source_digest summary.source_digest
            && Option.value_map current.terminal ~default:false ~f:(fun terminal ->
              String.equal terminal.attempt reference.terminal_attempt)
            && List.mem p.artifacts reference ~equal:Asic_artifact.Reference.equal
            && Run_ref.equal page.Asic_artifact.Byte_page.run run
            && String.equal page.artifact_id artifact_id
            && String.equal page.terminal_attempt reference.terminal_attempt
            && String.equal page.sha256 reference.sha256
            && page.offset = offset
            && page.limit = limit)
           "Artifact byte reference is stale; list current adopted artifacts";
         prune_byte_pages p;
         p.artifact_byte_pages
         <- List.take
              (page
               :: List.filter p.artifact_byte_pages ~f:(fun old ->
                 not
                   (Run_ref.equal old.run run
                    && String.equal old.artifact_id artifact_id
                    && old.offset = offset
                    && old.limit = limit)))
              8);
    Deferred.unit
  | Read_artifact { run; artifact_id; offset; limit } ->
    ignore (find_run p run : Asic.Run.t);
    Public.require (String.length artifact_id <= 256) "Artifact ID exceeds budget";
    Public.require
      (offset >= 0 && limit > 0 && limit <= 64 * 1024)
      "Artifact page requires nonnegative offset and limit 1..65536";
    enqueue
      ~key:(Asic_artifact.read_key ~run ~artifact_id ~offset ~limit)
      ~kind:"artifact-read"
      (fun cancel ->
         Public.require (not (Deferred.is_determined cancel)) "Artifact read cancelled";
         let summary = Hashtbl.find_exn p.hot run.id in
         let terminal = Option.value_exn summary.terminal in
         let reference =
           List.find_exn p.artifacts ~f:(fun r ->
             Run_ref.equal r.Asic_artifact.Reference.run run
             && String.equal r.id artifact_id
             && String.equal r.terminal_attempt terminal.attempt)
         in
         let%map page =
           Throttle.enqueue t.queries (fun () ->
             Public.require
               (not (Deferred.is_determined cancel))
               "Artifact read cancelled";
             In_thread.run (fun () -> Asic_artifacts.read ~reference ~offset ~limit))
         in
         Public.require (not (Deferred.is_determined cancel)) "Artifact read cancelled";
         Public.require
           (String.equal
              (Hashtbl.find_exn p.hot run.id).source_digest
              summary.source_digest
            && List.mem p.artifacts reference ~equal:Asic_artifact.Reference.equal)
           "Artifact reference is stale; list current adopted artifacts";
         p.artifact_pages
         <- List.take
              (page
               :: List.filter p.artifact_pages ~f:(fun old ->
                 not
                   (Run_ref.equal old.run page.run
                    && String.equal old.artifact_id page.artifact_id
                    && String.equal old.terminal_attempt page.terminal_attempt
                    && String.equal old.sha256 page.sha256
                    && old.offset = page.offset
                    && old.limit = page.limit)))
              8);
    Deferred.unit
  | Stage_fresh { selection; elaboration_only; expected_plan_identity } ->
    p.fresh_generation <- p.fresh_generation + 1;
    let generation = p.fresh_generation in
    p.fresh_intent <- None;
    Preparation_receipt.validate_selection selection expected_plan_identity;
    let%map scope = fresh_scope ~physical:(not elaboration_only) p in
    Public.require (generation = p.fresh_generation) "Fresh input staging superseded";
    let created_at = Timestamp.of_time_ns (Time_ns.now ()) in
    let id =
      "fresh-intent-"
      ^ Public.digest
          (scope
           ^ Int.to_string generation
           ^ Sexp.to_string_mach
               ([%sexp_of: Asic.Selection.t * bool * string option * Timestamp.t]
                  (selection, elaboration_only, expected_plan_identity, created_at)))
    in
    p.fresh_intent
    <- Some
         { Asic.Fresh.Intent.id
         ; selection
         ; elaboration_only
         ; expected_plan_identity
         ; scope
         ; created_at
         }
  | Launch_fresh { key; intent_id } ->
    (match
       List.find p.workflows ~f:(fun w -> String.equal w.Asic.Fresh.Workflow.key key)
     with
     | Some w ->
       Public.require
         (String.equal w.intent.id intent_id)
         "Submission key reused with different intent";
       await_workflow_reservation p key
     | None ->
       let intent =
         Option.value_exn
           p.fresh_intent
           ~message:"Fresh input intent unavailable; stage again"
       in
       Public.require
         (String.equal intent.id intent_id)
         "Fresh input intent superseded; stage again";
       launch_fresh ~staged:true t p ~key ~intent)
  | Cancel_workflow id -> cancel_workflow t p id
  | Cancel key when List.exists p.workflows ~f:(fun w -> workflow_cancel_key w key) ->
    let w = List.find_exn p.workflows ~f:(fun w -> workflow_cancel_key w key) in
    cancel_workflow t p w.id
  | Cancel key ->
    let task =
      match Hashtbl.find p.tasks key with
      | Some task -> task
      | None ->
        (match Hashtbl.find p.tasks ("finalize:" ^ key) with
         | Some task -> task
         | None -> Hashtbl.find_exn p.tasks ("run:" ^ key))
    in
    Ivar.fill_if_empty task.cancel ();
    if String.equal task.pending.kind "run"
    then
      Option.iter task.pending.run ~f:(fun run ->
        Option.iter
          (Hashtbl.find p.tasks (observation_key run))
          ~f:(fun observer -> Ivar.fill_if_empty observer.cancel ()));
    Deferred.unit
  | Discover ->
    (* Retire the previous mapping immediately, including on refresh failure. The
       invocation and publication belong to this immutable captured project config. *)
    p.flows <- [];
    p.catalog_default <- None;
    let invocation = invoke p Adapter.discover in
    enqueue ~key:"discover" ~kind:"discover" (fun cancel ->
      let%bind () = check_provider t p cancel in
      let%map j = query ~max_bytes:(1024 * 1024) t p cancel invocation in
      Public.require (not (Deferred.is_determined cancel)) "ASIC discovery cancelled";
      let flows, catalog_default = Public.flow_catalog j in
      p.flows
      <- List.map flows ~f:(fun flow ->
           { flow with
             Asic.Flow.fresh_stage_endpoints =
               List.filter flow.fresh_stage_endpoints ~f:(fun endpoint ->
                 p.timing_stage || not (String.equal endpoint "timing"))
           });
      p.catalog_default <- catalog_default);
    Deferred.unit
  | Describe flow ->
    p.desired_description <- Some flow;
    p.description <- None;
    public_query
      ~key:("describe:" ^ flow)
      ~kind:"describe"
      (invoke p (fun c ~root ~environment -> Adapter.describe c ~root ~environment flow))
      (fun j ->
        let j = Public.envelope j "hardcaml-asic.flow-describe" 1 in
        if Option.equal String.equal p.desired_description (Some flow)
        then p.description <- Some (Yojson.Safe.to_string j));
    Deferred.unit
  | Plan selection ->
    p.desired_plan <- Some selection;
    p.preview <- None;
    enqueue
      ~key:
        ("plan:"
         ^ Public.digest (Sexp.to_string_mach (Asic.Selection.sexp_of_t selection)))
      ~kind:"plan"
      (fun cancel ->
        let%bind () = check_provider ~selection t p cancel in
        let%bind () =
          if not (String.equal selection.endpoint "timing")
          then Deferred.unit
          else (
            Public.require p.timing_stage "Provider does not advertise executable Timing";
            let%map description =
              query
                t
                p
                cancel
                (invoke p (fun c ~root ~environment ->
                   Adapter.describe c ~root ~environment selection.flow))
            in
            Public.validate_physical_selection selection description)
        in
        let%map j =
          query
            t
            p
            cancel
            (invoke p (fun c ~root ~environment ->
               Adapter.plan c ~root ~environment selection))
        in
        let preview = Public.preview selection j in
        if Option.equal Asic.Selection.equal p.desired_plan (Some selection)
        then p.preview <- Some preview);
    Deferred.unit
  | Register reference ->
    let%map (_ : Asic.Run.t) = register t p reference in
    ()
  | Observe run ->
    ignore (find_run p run : Asic.Run.t);
    enqueue ~key:(observation_key run) ~kind:"observe" (fun cancel ->
      observe t p cancel run >>| fun _ -> ());
    Deferred.unit
  | Load_summary run | Refresh run ->
    ignore (find_run p run : Asic.Run.t);
    let refresh =
      match operation with
      | Refresh _ -> true
      | _ -> false
    in
    schedule
      t
      p
      ~key:((if refresh then "refresh:" else "summary:") ^ run.id)
      ~kind:(if refresh then "refresh" else "summary")
      ~execution:false
      (fun task ->
        (* An explicit Refresh revalidates retained evidence; a summary load may stay
           offline, so it makes no evidence-read claim. *)
        task.pending
        <- { task.pending with
             run = Some run
           ; activity = (if refresh then Evidence_read else Unreported)
           };
        let cancel = Ivar.read task.cancel in
        serialized p ("summaryop:" ^ run.id) (fun () ->
          let%bind result =
            Monitor.try_with (fun () ->
              if refresh
              then (
                let%bind (_ : bool) = observe t p cancel run in
                materialize t p cancel run)
              else load_summary t p cancel run)
          in
          match result with
          | Ok () -> Deferred.unit
          | Error exn ->
            Option.iter (Hashtbl.find p.hot run.id) ~f:(fun s ->
              if not (Asic.Summary.Freshness.equal s.freshness Missing_source)
              then hot p { s with freshness = Refresh_failed (Exn.to_string exn) });
            raise exn));
    Deferred.unit
  | Inspect_finalization { run; attempt } ->
    ignore (find_run p run : Asic.Run.t);
    ignore (Public.absolute attempt : string);
    Public.require (String.length attempt <= 4096) "Finalization reference exceeds budget";
    enqueue
      ~key:("finalization:" ^ run.id ^ ":" ^ Public.digest attempt)
      ~kind:"finalization"
      (fun cancel ->
        serialized p ("summaryop:" ^ run.id) (fun () ->
          Monitor.try_with (fun () ->
            let%bind (_ : bool) = observe t p cancel run in
            materialize ~attempt t p cancel run)
          >>| function
          | Ok () -> ()
          | Error exn ->
            Option.iter (Hashtbl.find p.hot run.id) ~f:(fun s ->
              hot p { s with freshness = Refresh_failed (Exn.to_string exn) });
            raise exn));
    Deferred.unit
  | Run { key; preview } when Option.is_none prepared_input ->
    (* Compatibility is strict: an explicitly supplied generated preview is an
       expectation, never permission to execute a pinned source producer. *)
    (match
       List.find p.workflows ~f:(fun w -> String.equal w.Asic.Fresh.Workflow.key key)
     with
     | Some w ->
       Public.require
         (String.equal w.intent.id (legacy_intent_id key preview)
          && Asic.Selection.equal w.intent.selection preview.selection
          && Option.equal
               String.equal
               w.intent.expected_plan_identity
               (Some preview.plan_identity))
         "Submission key reused with different fresh inputs";
       await_workflow_reservation p key
     | None ->
       let validated =
         Public.preview preview.selection (Public.decode preview.plan_json)
       in
       Public.require
         (String.equal validated.plan_identity preview.plan_identity)
         "Preview identity mismatch";
       let%bind scope = fresh_scope p in
       let created_at = Timestamp.of_time_ns (Time_ns.now ()) in
       let intent : Asic.Fresh.Intent.t =
         { id = legacy_intent_id key preview
         ; selection = preview.selection
         ; elaboration_only = false
         ; expected_plan_identity = Some preview.plan_identity
         ; scope
         ; created_at
         }
       in
       launch_fresh t p ~key ~intent)
  | Run { key; preview } ->
    Public.require
      p.registry_writable
      "ASIC registry unavailable; submission deduplication cannot be established";
    Public.require
      ((not (String.is_empty key)) && String.length key <= 256)
      "Invalid ASIC submission key";
    ignore
      (Public.preview preview.selection (Public.decode preview.plan_json)
       : Asic.Preview.t);
    Public.require
      (String.equal
         preview.plan_identity
         (Public.text (Public.field "plan_identity" (Public.decode preview.plan_json))))
      "Preview identity mismatch";
    (* Retain the complete plan once in the workflow file. The legacy launch ledger needs
       only exact identities for observation/report fencing. *)
    let reservation_preview =
      match prepared_input with
      | None -> preview
      | Some (_, (prepared : Asic.Fresh.Prepared.t)) ->
        { preview with
          plan_json =
            Yojson.Safe.to_string
              (`Assoc
                [ "contract", `String "hardcaml-asic.methodology-plan"
                ; "schema_version", `Int 1
                ; "plan_identity", `String prepared.plan_identity
                ; "bundle_identity", `String prepared.bundle_identity
                ])
        }
    in
    reserve_and_schedule t p ~key ~preview:reservation_preview (fun () ->
      schedule t p ~key:("run:" ^ key) ~kind:"run" ~execution:true (fun task ->
        (* The entire execution task, including metadata and its automatic reader, shares
           one deadline. Allocation must not reset the execution budget. *)
        let deadline = Clock.after (Time_float.Span.of_sec 1800.) in
        let cancel = Deferred.any [ Ivar.read task.cancel; deadline ] in
        let%bind () = check_provider ~selection:preview.selection t p cancel in
        Public.require
          (p.timing_stage || not (String.equal preview.selection.endpoint "timing"))
          "Provider does not advertise executable Timing";
        let%bind () =
          if Option.is_some prepared_input
             || String.equal preview.selection.endpoint "synthesis"
          then Deferred.unit
          else (
            let%map description =
              query
                t
                p
                cancel
                (invoke p (fun c ~root ~environment ->
                   Adapter.describe c ~root ~environment preview.selection.flow))
            in
            Public.validate_physical_selection preview.selection description)
        in
        let allocated = ref None in
        let delivered_execution = ref None in
        let validate_delivery run =
          Option.iter !delivered_execution ~f:(fun delivered ->
            let r = find_run p run in
            Public.require
              (Option.equal String.equal r.execution_file (Some delivered))
              "Launcher/inspection execution reference mismatch")
        in
        let on_line line =
          let j = Public.decode line in
          match Public.field "event" j with
          | `String "observation_allocated" ->
            Public.require (Option.is_none !allocated) "Duplicate allocation";
            let reference = Public.allocation j in
            Public.require
              (not
                 (List.exists p.submissions ~f:(fun (other, _, run) ->
                    (not (String.equal other key))
                    && Option.equal String.equal run (Some reference.stream_id))))
              "Provider allocation already belongs to another submission";
            (* Publish allocation and workflow linkage in one registry write. *)
            let%bind r =
              register ~persist_reference:false t p ~selection:preview.selection reference
            in
            allocated := Some r.run;
            task.pending <- { task.pending with run = Some r.run };
            p.submissions
            <- List.map p.submissions ~f:(fun (k, v, id) ->
                 k, v, if String.equal k key then Some r.run.id else id);
            Option.iter prepared_input ~f:(fun (id, _) ->
              update_workflow p id (fun w ->
                { w with run = Some r.run; reference = Some reference }));
            let%map () = save_required t p in
            (* Start observation before waiting for launcher EOF. *)
            if not (Deferred.is_determined cancel)
            then
              schedule
                t
                p
                ~key:(observation_key r.run)
                ~kind:"observe"
                ~execution:false
                (fun observer ->
                   observer.pending <- { observer.pending with run = Some r.run };
                   let cancel = Deferred.any [ Ivar.read observer.cancel; cancel ] in
                   let check_reader () =
                     Public.require
                       (not (Deferred.is_determined cancel))
                       "Automatic observation stopped: execution deadline/cancellation; \
                        reconnect with Observe"
                   in
                   let rec loop remaining =
                     check_reader ();
                     Public.require
                       (remaining > 0)
                       "Observation budget exhausted; reconnect with Observe";
                     let%bind final = observe t p cancel r.run in
                     check_reader ();
                     if final
                     then (
                       validate_delivery r.run;
                       materialize t p cancel r.run)
                     else (
                       let%bind () =
                         Deferred.any [ Clock.after (Time_float.Span.of_sec 1.); cancel ]
                       in
                       loop (remaining - 1))
                   in
                   let%bind result = Monitor.try_with (fun () -> loop 1800) in
                   match result with
                   | Ok () -> Deferred.unit
                   | Error exn ->
                     let current = find_run p r.run in
                     replace_run
                       p
                       { current with
                         error =
                           Some
                             ("Observation stopped; provider outcome not inferred: "
                              ^ Exn.to_string exn)
                       };
                     let%bind () = persist t p in
                     raise exn)
          | `String "observation_terminal" ->
            ignore (Public.envelope j "hardcaml-asic.stage-observation" 1 : Yojson.Safe.t);
            delivered_execution
            := Option.map
                 (Public.optional_text (Public.field "execution_file" j))
                 ~f:Public.absolute;
            Deferred.unit
          | _ ->
            let run =
              Option.value_exn !allocated ~message:"Launcher output before allocation"
            in
            Public.execution_summary (find_run p run) preview j;
            delivered_execution
            := Option.map
                 (Public.optional_text (Public.field "execution_file" j))
                 ~f:Public.absolute;
            Deferred.unit
        in
        let%bind result =
          Monitor.try_with (fun () ->
            let id, prepared = Option.value_exn prepared_input in
            let%bind scope = fresh_scope p in
            let current = workflow p id in
            Public.require
              (String.equal scope current.intent.scope)
              "Fresh scope changed while physical execution was queued";
            let workspace =
              Filename.concat (config p).results_root ("fresh-" ^ Public.digest id)
            in
            let%bind () =
              In_thread.run (fun () ->
                Public.require
                  (String.equal
                     prepared.methodology_plan_digest
                     (Preparation_receipt.sha256
                        (read_bounded prepared.methodology_plan_path (16 * 1024 * 1024))))
                  "Frozen workflow methodology plan changed before launch";
                (* The public observation writer requires an existing workspace parent.
                   The provider owns creation of the fresh workspace. *)
                Core_unix.mkdir_p (config p).results_root;
                Public.require
                  (Poly.equal (Sys_unix.file_exists workspace) `No)
                  "Fresh physical workspace already exists; implicit reuse forbidden")
            in
            Asic_process.run
            (* The adopted producer needs its child termination grace, five-second
               container cleanup window, and terminal receipt publication before
               escalation. Queries retain the shorter default grace. *)
              ~stop_grace_seconds:15.
              ~seconds:1800.
              ~cancel
              ~on_process:ignore
              ~on_line
              (let id, prepared = Option.value_exn prepared_input in
               let w = workflow p id in
               Public.require
                 ((not w.cancel_requested) && not t.closing)
                 "Fresh workflow cancelled before provider process creation";
               invoke p (fun c ~root ~environment ->
                 Adapter.run_prepared c ~root ~environment ~prepared ~workspace)))
        in
        (* EOF (including nonzero exit) is not provider stage evidence. Retire and join
           the polling reader before a fresh, bounded reconciliation: otherwise its
           cancelled in-flight read can discard the producer's last records or overwrite
           the reconciled state with a late cancellation error. *)
        let%bind () =
          match !allocated with
          | None -> Deferred.unit
          | Some run ->
            let observer = Hashtbl.find p.tasks (observation_key run) in
            Option.iter observer ~f:(fun observer ->
              Ivar.fill_if_empty observer.cancel ());
            let%bind () =
              Option.value_map observer ~default:Deferred.unit ~f:(fun o -> o.completion)
            in
            let already_materialized =
              Option.value_map observer ~default:false ~f:(fun o ->
                String.equal o.pending.state "completed")
            in
            (* Deliberately independent of the execution cancellation/deadline: an
               interrupted producer may have recorded its terminal truth during its
               termination grace. These queries only read the retained reference. *)
            let final_cancel = Clock.after (Time_float.Span.of_sec 90.) in
            let%bind reconciled =
              Monitor.try_with (fun () ->
                let%bind final = observe t p final_cancel run in
                (* Inspection can race ahead of the updates cursor. One catch-up read
                   suffices for a stopped writer; never poll a surviving writer. *)
                let%bind final =
                  if final then return true else observe t p final_cancel run
                in
                Public.require
                  final
                  "Final observation unavailable: provider writer still active or \
                   terminal records unavailable; reconnect with Observe";
                validate_delivery run;
                if already_materialized
                then Deferred.unit
                else materialize t p final_cancel run)
            in
            (match reconciled with
             | Ok () ->
               Option.iter observer ~f:(fun o ->
                 o.pending <- { o.pending with state = "completed"; error = None })
             | Error exn ->
               let current = find_run p run in
               let observation_error =
                 "Final observation unavailable: " ^ failure_message exn
               in
               let error =
                 match result with
                 | Ok _ -> observation_error
                 | Error producer -> failure_message producer ^ "; " ^ observation_error
               in
               (* Preserve already-recorded terminal stages; never infer failure or
                  cancellation from the owned process's exit status. *)
               replace_run
                 p
                 { current with
                   status =
                     (if List.mem
                           [ "allocated"; "observing" ]
                           current.status
                           ~equal:String.equal
                      then "observation_unavailable"
                      else current.status)
                 ; error = Some error
                 ; execution_timing = Execution_timing.stopped current.execution_timing
                 ; stages =
                     List.map current.stages ~f:(fun stage ->
                       { stage with
                         status =
                           (match stage.status with
                            | Running | Pending -> Unknown "observation_unavailable"
                            | status -> status)
                       ; execution_timing =
                           Execution_timing.stopped stage.execution_timing
                       })
                 };
               Option.iter observer ~f:(fun o ->
                 o.pending <- { o.pending with state = "failed"; error = Some error }));
            Deferred.unit
        in
        let%bind () = persist t p in
        match result with
        | Error exn -> raise exn
        | Ok _ ->
          let run =
            Option.value_exn !allocated ~message:"Launcher exited without allocation"
          in
          let r = find_run p run in
          if not (List.mem [ "allocated"; "observing" ] r.status ~equal:String.equal)
          then validate_delivery run;
          Deferred.unit))

and cancel_workflow t p id =
  let w = workflow p id in
  if not (workflow_active w)
  then Deferred.unit
  else (
    (* No yield between the latch and finding/cancelling the physical owner. *)
    update_workflow p id (fun w -> { w with cancel_requested = true });
    Option.iter
      (Hashtbl.find p.tasks ("workflow:" ^ id))
      ~f:(fun task -> Ivar.fill_if_empty task.cancel ());
    Option.iter
      (Hashtbl.find p.tasks ("run:" ^ w.key))
      ~f:(fun task -> Ivar.fill_if_empty task.cancel ());
    let%bind () = save_required t p in
    match w.preparation_id, t.preparation_runner with
    | Some attempt, Some runner ->
      let%map (_ : Preparation.Response.t) =
        runner
          ~root:p.root
          ~environment:p.environment
          ~unique:true
          ~cancelled:(fun () -> true)
          (Preparation.Operation.Cancel attempt)
      in
      ()
    | _ -> Deferred.unit)

and launch_fresh ?(staged = false) t p ~key ~(intent : Asic.Fresh.Intent.t) =
  Public.require
    ((not (String.is_empty key)) && String.length key <= 256)
    "Invalid fresh submission key";
  serialized p "fresh-reservation" (fun () ->
    match
      List.find p.workflows ~f:(fun w -> String.equal w.Asic.Fresh.Workflow.key key)
    with
    | Some w ->
      Public.require
        (String.equal w.intent.id intent.id
         && Asic.Selection.equal w.intent.selection intent.selection
         && Bool.equal w.intent.elaboration_only intent.elaboration_only
         && Option.equal
              String.equal
              w.intent.expected_plan_identity
              intent.expected_plan_identity
         && String.equal w.intent.scope intent.scope)
        "Submission key reused with different fresh intent";
      Deferred.unit
    | None ->
      Public.require p.registry_writable "Fresh workflow registry unavailable";
      Public.require
        (not
           (List.exists p.workflows ~f:(fun w ->
              String.equal w.Asic.Fresh.Workflow.intent.id intent.id)))
        "Fresh input intent already launched; stage again for a distinct submission";
      Public.require
        (List.length p.workflows < 256)
        "Fresh workflow history budget exhausted";
      Public.require
        (not (List.exists p.submissions ~f:(fun (old, _, _) -> String.equal old key)))
        "Historical submission key already reserved; observe it instead of relaunching";
      let%bind scope = fresh_scope ~physical:(not intent.elaboration_only) p in
      Public.require
        (String.equal scope intent.scope)
        "Fresh input scope changed; stage again";
      if staged
      then
        Public.require
          (Option.exists p.fresh_intent ~f:(fun current ->
             String.equal current.id intent.id))
          "Fresh input intent superseded before reservation; stage again";
      ignore
        (Option.value_exn
           t.preparation_runner
           ~message:"Preparation supervisor unavailable"
         : preparation_runner);
      let id = "workflow-" ^ Public.digest (p.identity ^ "\000" ^ key) in
      let w : Asic.Fresh.Workflow.t =
        { id
        ; key
        ; intent
        ; phase = Reserved
        ; cancel_requested = false
        ; preparation_id = None
        ; elaboration_status = "not_requested"
        ; elaboration_started_at = None
        ; elaboration_finished_at = None
        ; build_job = None
        ; emission_job = None
        ; prepared = None
        ; run = None
        ; reference = None
        ; error = None
        ; created_at = Timestamp.of_time_ns (Time_ns.now ())
        ; finished_at = None
        }
      in
      p.workflows <- w :: p.workflows;
      let reserved = Ivar.create () in
      Hashtbl.set p.workflow_reservations ~key ~data:(Ivar.read reserved);
      let%bind saved = Monitor.try_with (fun () -> save_required t p) in
      Ivar.fill_exn reserved saved;
      Hashtbl.remove p.workflow_reservations key;
      (match saved with
       | Error exn ->
         p.workflows
         <- List.filter p.workflows ~f:(fun old -> not (String.equal old.id id));
         raise exn
       | Ok () ->
         schedule
           t
           p
           ~key:("workflow:" ^ id)
           ~kind:"workflow"
           ~execution:false
           (fun task -> execute_fresh t p id task);
         Deferred.unit))

and execute_fresh t p id task =
  let check () =
    Public.require
      ((not t.closing) && not (workflow p id).cancel_requested)
      "Fresh workflow cancelled; downstream launch blocked"
  in
  let runner = Option.value_exn t.preparation_runner in
  let call operation =
    runner
      ~root:p.root
      ~environment:p.environment
      ~unique:true
      ~cancelled:(fun () -> t.closing || (workflow p id).cancel_requested)
      operation
    >>| function
    | Ok value -> value
    | Error error -> failwith error.V1.Error.message
  in
  let%bind result =
    Monitor.try_with (fun () ->
      check ();
      let w = workflow p id in
      let%bind scope = fresh_scope ~physical:(not w.intent.elaboration_only) p in
      check ();
      Public.require
        (String.equal scope w.intent.scope)
        "Fresh scope changed before preparation";
      let%bind () =
        if w.intent.elaboration_only
        then Deferred.unit
        else
          (* This probe belongs to this workflow, not to the shared reader cache. Cancel
             and shutdown must terminate/reap it before orchestration joins. *)
          check_provider
            ~cache:false
            ~selection:w.intent.selection
            t
            p
            (Deferred.any
               [ Ivar.read task.cancel; Clock.after (Time_float.Span.of_sec 30.) ])
      in
      check ();
      let%bind started =
        call
          (Prepare
             { submission_key = "fresh:" ^ id
             ; selection = w.intent.selection
             ; expected_plan_identity = w.intent.expected_plan_identity
             })
      in
      let attempt_id = Option.value_exn started.requested_attempt in
      update_workflow p id (fun w ->
        { w with preparation_id = Some attempt_id; phase = Building });
      let%bind () = save_required t p in
      let rec wait_preparation (snapshot : Preparation.Snapshot.t) =
        let attempt =
          List.find_exn snapshot.history ~f:(fun a ->
            String.equal a.Preparation.Attempt.id attempt_id)
        in
        let active, phase, status =
          match attempt.outcome with
          | Building -> true, Asic.Fresh.Phase.Building, "building"
          | Emitting -> true, Emitting, "emitting"
          | Completed -> false, Prepared, "completed"
          | Build_failed -> false, Failed, "build_failed"
          | Emission_failed -> false, Failed, "emission_failed"
          | Cancelled -> false, Cancelled, "cancelled"
        in
        let before = workflow p id in
        update_workflow p id (fun w ->
          { w with
            phase
          ; elaboration_status = status
          ; elaboration_started_at = Some attempt.created_at
          ; elaboration_finished_at =
              (if active
               then None
               else
                 Option.first_some
                   (Option.bind
                      (Option.first_some attempt.emission_job attempt.build_job)
                      ~f:(fun job -> job.Job.finished_at))
                   (Some (Timestamp.of_time_ns (Time_ns.now ()))))
          ; build_job = attempt.build_job
          ; emission_job = attempt.emission_job
          ; error = attempt.diagnostic
          });
        let%bind () =
          if Asic.Fresh.Workflow.equal before (workflow p id)
          then Deferred.unit
          else save_required t p
        in
        if active
        then (
          let%bind () =
            if (workflow p id).cancel_requested || t.closing
            then call (Cancel attempt_id) >>| ignore
            else Deferred.unit
          in
          let%bind () = Clock.after (Time_float.Span.of_ms 50.) in
          let%bind snapshot = call Get in
          wait_preparation snapshot)
        else return attempt
      in
      let%bind attempt = wait_preparation started in
      check ();
      Public.require
        (Preparation.Outcome.equal attempt.outcome Completed)
        (Option.value attempt.diagnostic ~default:"Fresh preparation did not complete");
      let bundle = Option.value_exn attempt.bundle in
      let plan_path = path t (p.identity ^ id) "-methodology-plan.json" in
      let%bind () =
        In_thread.run (fun () ->
          if Poly.equal (Sys_unix.file_exists plan_path) `Yes
          then
            Public.require
              (String.equal (read_bounded plan_path (16 * 1024 * 1024)) bundle.plan_json)
              "Frozen workflow plan already exists with different bytes"
          else (
            atomic_write t plan_path bundle.plan_json;
            Core_unix.chmod plan_path ~perm:0o400))
      in
      check ();
      let prepared : Asic.Fresh.Prepared.t =
        { bundle_identity = bundle.bundle_identity
        ; bundle_directory = bundle.output_dir
        ; plan_identity = bundle.plan_identity
        ; methodology_plan_path = plan_path
        ; methodology_plan_digest = Preparation_receipt.sha256 bundle.plan_json
        }
      in
      update_workflow p id (fun w ->
        { w with prepared = Some prepared; phase = Prepared });
      let%bind () = save_required t p in
      check ();
      let%bind scope = fresh_scope ~physical:(not w.intent.elaboration_only) p in
      check ();
      Public.require
        (String.equal scope w.intent.scope)
        "Fresh scope changed before physical handoff";
      if w.intent.elaboration_only
      then Deferred.unit
      else (
        let preview : Asic.Preview.t =
          { selection = w.intent.selection
          ; plan_identity = bundle.plan_identity
          ; plan_json = bundle.plan_json
          }
        in
        update_workflow p id (fun w -> { w with phase = Physical });
        let%bind () = save_required t p in
        check ();
        let%bind () =
          handle_operation
            ~prepared_input:(id, prepared)
            t
            p
            (Run { key = w.key; preview })
        in
        let task = Hashtbl.find_exn p.tasks ("run:" ^ w.key) in
        if (workflow p id).cancel_requested then Ivar.fill_if_empty task.cancel ();
        let%bind () = task.completion in
        Public.require
          (String.equal task.pending.state "completed")
          (Option.value task.pending.error ~default:"Physical producer failed");
        let current = workflow p id in
        let run = find_run p (Option.value_exn current.run) in
        Public.require
          (String.equal run.status "completed")
          ("Provider terminal outcome: " ^ run.status);
        Deferred.unit))
  in
  let%bind () =
    match result, (workflow p id).preparation_id with
    | Error _, Some attempt ->
      Monitor.try_with (fun () -> call (Cancel attempt) >>| ignore) >>| ignore
    | _ -> Deferred.unit
  in
  update_workflow p id (fun w ->
    { w with
      phase =
        (if w.cancel_requested
            || t.closing
            || String.equal w.elaboration_status "cancelled"
         then Cancelled
         else (
           match result with
           | Ok () -> Completed
           | Error _ -> Failed))
    ; error =
        (match result with
         | Ok () -> w.error
         | Error exn -> Some (failure_message exn))
    ; finished_at = Some (Timestamp.of_time_ns (Time_ns.now ()))
    });
  (* Failure to retain a terminal update is exposed by cache_error; it must never cause a
     producer retry. *)
  persist t p
;;

let handle t ~root ~environment operation : Asic.Response.t Deferred.t =
  Monitor.try_with (fun () ->
    Public.require (not t.closing) "ASIC service shutting down";
    Public.require (Filename.is_absolute root) "ASIC project root must be absolute";
    Public.require
      (Filename.is_absolute t.state_dir)
      "ASIC state directory must be absolute";
    let key =
      Sexp.to_string_mach
        [%sexp (root : string), (environment : V1.Environment_selection.t)]
    in
    Public.require
      (Hashtbl.mem t.projects key || Hashtbl.length t.projects < 32)
      "ASIC project working-set budget exhausted (32)";
    let loaded =
      Hashtbl.find_or_add t.projects key ~default:(fun () ->
        Monitor.try_with (fun () -> load_project t ~root ~environment))
    in
    let%bind result = loaded in
    let p =
      match result with
      | Ok p -> p
      | Error exn -> raise exn
    in
    let%map () = handle_operation t p operation in
    snapshot p)
  >>| function
  | Ok snapshot -> Ok snapshot
  | Error exn -> Error (V1.Error.create Invalid_request (Exn.to_string exn))
;;

let peek_snapshot t ~root ~environment =
  let key =
    Sexp.to_string_mach
      [%sexp (root : string), (environment : V1.Environment_selection.t)]
  in
  Option.bind (Hashtbl.find t.projects key) ~f:(fun loaded ->
    match Deferred.peek loaded with
    | Some (Ok project) -> Some (snapshot project)
    | Some (Error _) | None -> None)
;;

(** Client detach does not call this. Daemon shutdown cancels/reaps owned launchers and
    bounded readers, then flushes registered references. Reconnected readers never signal
    a historical producer PID. *)
let shutdown t =
  t.closing <- true;
  Deferred.List.iter (Hashtbl.data t.projects) ~how:`Parallel ~f:(fun loaded ->
    match%bind loaded with
    | Error _ -> Deferred.unit
    | Ok p ->
      let%bind () =
        Deferred.all_unit
          (List.map (Hashtbl.data p.reservations) ~f:(fun r -> r.result >>| fun _ -> ()))
      in
      Hashtbl.iter p.tasks ~f:(fun task -> Ivar.fill_if_empty task.cancel ());
      let%bind () =
        Deferred.all_unit
          (List.map (Hashtbl.data p.tasks) ~f:(fun task -> task.completion))
      in
      p.save_tail)
;;

let rec completion t =
  Deferred.List.iter (Hashtbl.data t.projects) ~how:`Parallel ~f:(fun loaded ->
    match%bind loaded with
    | Error _ -> Deferred.unit
    | Ok p ->
      let%bind () =
        Deferred.all_unit
          (List.map (Hashtbl.data p.reservations) ~f:(fun r -> r.result >>| fun _ -> ()))
      in
      let%bind () =
        Deferred.all_unit
          (List.map (Hashtbl.data p.tasks) ~f:(fun task -> task.completion))
      in
      p.save_tail)
  >>= fun () ->
  let%bind active =
    Deferred.List.map (Hashtbl.data t.projects) ~how:`Parallel ~f:(fun loaded ->
      let%map result = loaded in
      match result with
      | Error _ -> false
      | Ok p ->
        (not (Hashtbl.is_empty p.reservations))
        || Hashtbl.exists p.tasks ~f:(fun task ->
          String.equal task.pending.state "pending"
          || String.equal task.pending.state "executing"))
  in
  if List.exists active ~f:Fn.id then completion t else Deferred.unit
;;
