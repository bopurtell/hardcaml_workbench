open! Core
open Hardcaml_workbench_protocol

let cancellable (operation : Asic.Pending.t) =
  Plain_rpc.active operation && Option.is_none operation.error
;;

type allocation =
  | Awaiting
  | Allocated of Run_ref.t
  | Allocation_failed of string

let legacy_allocation ~key (snapshot : Asic.Snapshot.t) =
  match
    List.find snapshot.operations ~f:(fun op -> String.equal op.key ("run:" ^ key))
  with
  | None -> Awaiting
  | Some { error = Some error; _ } -> Allocation_failed error
  | Some op ->
    (match op.state, op.run with
     | ("failed" | "detached"), _ -> Allocation_failed (op.key ^ ": " ^ op.state)
     | ("pending" | "executing" | "completed"), Some run -> Allocated run
     | "completed", None ->
       Allocation_failed "ASIC launch completed without an allocation"
     | ("pending" | "executing"), None -> Awaiting
     | state, _ -> Allocation_failed ("Unknown launch operation state: " ^ state))
;;

let allocation ~key (snapshot : Asic.Snapshot.t) =
  match List.find snapshot.workflows ~f:(fun w -> String.equal w.key key) with
  | None -> legacy_allocation ~key snapshot
  | Some w ->
    (match w.run with
     | Some run -> Allocated run
     | None ->
       (match w.phase with
        | Failed | Cancelled | Interrupted ->
          Allocation_failed
            (Option.value
               w.error
               ~default:("Workflow " ^ Sexp.to_string (Asic.Fresh.Phase.sexp_of_t w.phase)))
        | Completed ->
          Allocation_failed "Elaboration-only workflow completed; no physical allocation"
        | Reserved | Building | Emitting | Prepared | Physical -> Awaiting))
;;

(** Client-local interest bookkeeping, never evidence or run selection. Unknown executions
    get one probe per visible-interest lifetime; unowned live runs get bounded polling.
    Failed readers require the explicit Refresh command. *)
type t =
  { observed : (Run_ref.t * Time_ns.t) list
  ; unknown_probed : Run_ref.t list
  ; summary_requested : Run_ref.t list
  }

let empty = { observed = []; unknown_probed = []; summary_requested = [] }
let mem runs run = List.mem runs run ~equal:Run_ref.equal

let live_status status =
  List.mem
    [ "allocated"; "observing"; "running"; "starting"; "queued" ]
    status
    ~equal:String.equal
;;

let terminal (run : Asic.Run.t) =
  (not (live_status run.status))
  && (Option.is_some run.execution_file
      || List.mem
           [ "completed"
           ; "complete"
           ; "succeeded"
           ; "success"
           ; "failed"
           ; "cancelled"
           ; "canceled"
           ; "interrupted"
           ; "terminated"
           ]
           run.status
           ~equal:String.equal)
;;

let plan t ~now (snapshot : Asic.Snapshot.t) ~visible =
  let visible = List.dedup_and_sort visible ~compare:Run_ref.compare in
  let t =
    { observed = List.filter t.observed ~f:(fun (run, _) -> mem visible run)
    ; unknown_probed = List.filter t.unknown_probed ~f:(mem visible)
    ; summary_requested = List.filter t.summary_requested ~f:(mem visible)
    }
  in
  List.fold visible ~init:(t, []) ~f:(fun (t, intents) reference ->
    match List.find snapshot.runs ~f:(fun run -> Run_ref.equal run.run reference) with
    | None -> t, intents (* A saved missing run is never substituted or registered. *)
    | Some run ->
      let observe_key = "observe:" ^ reference.id in
      let summary_key = "summary:" ^ reference.id in
      let refresh_key = "refresh:" ^ reference.id in
      let active_key key =
        List.exists snapshot.operations ~f:(fun op ->
          String.equal op.key key && Plain_rpc.active op)
      in
      let failed_key key =
        List.exists snapshot.operations ~f:(fun op ->
          String.equal op.key key
          && (Option.is_some op.error
              || List.mem [ "failed"; "detached" ] op.state ~equal:String.equal))
      in
      let owned_reader =
        List.exists snapshot.operations ~f:(fun op ->
          cancellable op
          && (String.equal op.key observe_key
              || String.equal op.key refresh_key
              || (String.equal op.kind "run"
                  && Option.value_map op.run ~default:false ~f:(Run_ref.equal reference))
             ))
      in
      let cached =
        List.exists snapshot.summaries ~f:(fun summary ->
          Run_ref.equal summary.run reference)
      in
      let due =
        List.Assoc.find t.observed reference ~equal:Run_ref.equal
        |> Option.value_map ~default:true ~f:(fun last ->
          Time_ns.Span.compare (Time_ns.diff now last) (Time_ns.Span.of_sec 2.) >= 0)
      in
      let observe =
        (not (terminal run))
        && (not owned_reader)
        && Option.is_none run.error
        && (not (failed_key observe_key))
        &&
        if live_status run.status
        then due
        else (not cached) && not (mem t.unknown_probed reference)
      in
      let summary =
        terminal run
        && (not cached)
        && (not owned_reader)
        && Option.is_none run.error
        && (not
              (active_key summary_key || active_key refresh_key || active_key observe_key))
        && (not (failed_key summary_key || failed_key refresh_key))
        && not (mem t.summary_requested reference)
      in
      let t =
        { observed =
            (if observe
             then List.Assoc.add t.observed ~equal:Run_ref.equal reference now
             else t.observed)
        ; unknown_probed =
            (if observe && not (live_status run.status)
             then reference :: t.unknown_probed
             else t.unknown_probed)
        ; summary_requested =
            (if summary then reference :: t.summary_requested else t.summary_requested)
        }
      in
      ( t
      , intents
        @ (if observe then [ Asic.Operation.Observe reference ] else [])
        @ if summary then [ Asic.Operation.Load_summary reference ] else [] ))
;;

let fixture_reference : Run_ref.t =
  { backend = Backend_id.of_string "asic"
  ; id = "intent-fixture"
  ; build = None
  ; label = None
  }
;;

let fixture_run ?execution_file ?error status : Asic.Run.t =
  { run = fixture_reference
  ; reference = { attempt = "/explicit/fixture"; stream_id = "fixture" }
  ; selection = None
  ; stages = []
  ; execution_timing = None
  ; cursor = 0
  ; status
  ; execution_file
  ; error
  }
;;

let fixture_operation ?run ?error key kind state : Asic.Pending.t =
  { key; kind; state; run; error; activity = Unreported }
;;

let fixture_snapshot ?(operations = []) ?(summaries = []) runs : Asic.Snapshot.t =
  { configured = true
  ; flows = []
  ; catalog_default = None
  ; description_json = None
  ; preview = None
  ; runs
  ; operations
  ; launches = []
  ; fresh_intent = None
  ; workflows = []
  ; resources = None
  ; workloads = None
  ; summaries
  ; finalizations = []
  ; artifacts = []
  ; artifact_pages = []
  ; artifact_byte_pages = []
  ; inspections = []
  ; inspection_details = []
  ; cache_error = None
  }
;;

let fixture_summary : Asic.Summary.t =
  { run = fixture_reference
  ; source_digest = "synthetic"
  ; execution_file = "/explicit/fixture/execution"
  ; plan_identity = None
  ; cell_count = None
  ; cells = []
  ; timing = []
  ; metrics = []
  ; terminal = None
  ; timing_analysis = None
  ; completion = "fixture"
  ; acceptance = "unavailable"
  ; producer = "synthetic-test"
  ; observed_at = "fixture"
  ; freshness = Cached_unverified
  }
;;

let%test_unit "old cached evidence without metrics never schedules observation, summary \
               loads or Refresh"
  =
  let snapshot =
    fixture_snapshot
      ~summaries:[ fixture_summary ]
      [ fixture_run ~execution_file:"/explicit/fixture/execution" "completed" ]
  in
  let t, intents =
    plan
      empty
      ~now:Time_ns.epoch
      snapshot
      ~visible:[ fixture_reference; fixture_reference ]
  in
  assert (List.is_empty intents);
  let _, intents =
    plan
      t
      ~now:(Time_ns.add Time_ns.epoch (Time_ns.Span.of_sec 60.))
      snapshot
      ~visible:[ fixture_reference ]
  in
  assert (List.is_empty intents)
;;

let%test_unit "active owner suppresses duplicate reads, including after run allocation" =
  let live = fixture_run "observing" in
  List.iter
    [ fixture_operation ~run:fixture_reference "run:launch" "run" "executing"
    ; fixture_operation
        ~run:fixture_reference
        "observe:intent-fixture"
        "observe"
        "executing"
    ; fixture_operation "refresh:intent-fixture" "refresh" "pending"
    ]
    ~f:(fun owner ->
      let _, intents =
        plan
          empty
          ~now:Time_ns.epoch
          (fixture_snapshot ~operations:[ owner ] [ live ])
          ~visible:[ fixture_reference ]
      in
      assert (List.is_empty intents))
;;

let%test_unit "running stage updates are polled even with an execution file and cached \
               summary"
  =
  let run = fixture_run ~execution_file:"/explicit/active/execution" "running" in
  let stage : Asic.Stage.t =
    { id = "placement"
    ; name = "Placement"
    ; status = Running
    ; requested = true
    ; reason = None
    ; action = None
    ; execution_timing = None
    }
  in
  let snapshot =
    fixture_snapshot ~summaries:[ fixture_summary ] [ { run with stages = [ stage ] } ]
  in
  let state, intents =
    plan empty ~now:Time_ns.epoch snapshot ~visible:[ fixture_reference ]
  in
  assert (List.equal Asic.Operation.equal intents [ Observe fixture_reference ]);
  let _, intents =
    plan state ~now:Time_ns.epoch snapshot ~visible:[ fixture_reference ]
  in
  assert (List.is_empty intents);
  let _, intents =
    plan
      state
      ~now:(Time_ns.add Time_ns.epoch (Time_ns.Span.of_sec 2.))
      snapshot
      ~visible:[ fixture_reference ]
  in
  assert (List.equal Asic.Operation.equal intents [ Observe fixture_reference ]);
  let completed =
    { run with status = "completed"; stages = [ { stage with status = Completed } ] }
  in
  let _, intents =
    plan
      state
      ~now:(Time_ns.add Time_ns.epoch (Time_ns.Span.of_sec 4.))
      (fixture_snapshot ~summaries:[ fixture_summary ] [ completed ])
      ~visible:[ fixture_reference ]
  in
  assert (List.is_empty intents)
;;

let%test_unit "unowned live polling is throttled and unknown executions receive only one \
               probe"
  =
  let live = fixture_snapshot [ fixture_run "observing" ] in
  let t, intents = plan empty ~now:Time_ns.epoch live ~visible:[ fixture_reference ] in
  assert (List.equal Asic.Operation.equal intents [ Observe fixture_reference ]);
  let t, intents =
    plan
      t
      ~now:(Time_ns.add Time_ns.epoch (Time_ns.Span.of_ms 500.))
      live
      ~visible:[ fixture_reference ]
  in
  assert (List.is_empty intents);
  let _, intents =
    plan
      t
      ~now:(Time_ns.add Time_ns.epoch (Time_ns.Span.of_sec 2.))
      live
      ~visible:[ fixture_reference ]
  in
  assert (List.equal Asic.Operation.equal intents [ Observe fixture_reference ]);
  let unknown = fixture_snapshot [ fixture_run "unknown" ] in
  let t, intents = plan empty ~now:Time_ns.epoch unknown ~visible:[ fixture_reference ] in
  assert (List.equal Asic.Operation.equal intents [ Observe fixture_reference ]);
  let _, intents =
    plan
      t
      ~now:(Time_ns.add Time_ns.epoch (Time_ns.Span.of_sec 60.))
      unknown
      ~visible:[ fixture_reference ]
  in
  assert (List.is_empty intents)
;;

let%test_unit "failed readers are not retried; uncached completed runs load once per \
               interest"
  =
  let failed =
    fixture_operation ~error:"fixture failure" "observe:intent-fixture" "observe" "failed"
  in
  let _, intents =
    plan
      empty
      ~now:Time_ns.epoch
      (fixture_snapshot ~operations:[ failed ] [ fixture_run "observing" ])
      ~visible:[ fixture_reference ]
  in
  assert (List.is_empty intents);
  let completed =
    fixture_snapshot
      [ fixture_run ~execution_file:"/explicit/fixture/execution" "completed" ]
  in
  let t, intents =
    plan empty ~now:Time_ns.epoch completed ~visible:[ fixture_reference ]
  in
  assert (List.equal Asic.Operation.equal intents [ Load_summary fixture_reference ]);
  let t, intents = plan t ~now:Time_ns.epoch completed ~visible:[ fixture_reference ] in
  assert (List.is_empty intents);
  let t, _ = plan t ~now:Time_ns.epoch completed ~visible:[] in
  let _, intents = plan t ~now:Time_ns.epoch completed ~visible:[ fixture_reference ] in
  assert (List.equal Asic.Operation.equal intents [ Load_summary fixture_reference ])
;;

let%test_unit "allocation failures take priority over a retained run reference and use \
               the prefixed key"
  =
  let allocated =
    fixture_operation ~run:fixture_reference "run:launch" "run" "executing"
  in
  assert (
    match allocation ~key:"launch" (fixture_snapshot ~operations:[ allocated ] []) with
    | Allocated _ -> true
    | _ -> false);
  List.iter
    [ { allocated with state = "failed"; error = Some "fixture failure" }
    ; { allocated with state = "detached" }
    ; { allocated with state = "completed"; run = None }
    ]
    ~f:(fun operation ->
      assert (
        match
          allocation ~key:"launch" (fixture_snapshot ~operations:[ operation ] [])
        with
        | Allocation_failed _ -> true
        | _ -> false))
;;
