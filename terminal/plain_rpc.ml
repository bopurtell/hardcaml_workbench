open! Core
open Hardcaml_workbench_protocol

(** These are the daemon's machine operation identifiers/states, not log messages or
    provider execution-status prose. Query completion is not run completion. *)
let active (operation : Asic.Pending.t) =
  String.equal operation.state "pending" || String.equal operation.state "executing"
;;

let digest text =
  Cryptokit.hash_string (Cryptokit.Hash.sha256 ()) text
  |> Cryptokit.transform_string (Cryptokit.Hexa.encode ())
;;

let keys (operation : Asic.Operation.t) (snapshot : Asic.Snapshot.t) =
  match operation with
  | Get -> List.filter snapshot.operations ~f:active |> List.map ~f:(fun op -> op.key)
  | Discover -> [ "discover" ]
  | Resources operation -> [ Asic_resources.Operation.key operation ]
  | Workloads operation -> [ Asic_workloads.Operation.key operation ]
  | Describe flow -> [ "describe:" ^ flow ]
  | Plan selection ->
    [ "plan:" ^ digest (Sexp.to_string_mach (Asic.Selection.sexp_of_t selection)) ]
  | Run { key; _ } -> [ "run:" ^ key ]
  | Stage_fresh _ -> []
  | Launch_fresh { key; _ } ->
    List.filter_map snapshot.workflows ~f:(fun w ->
      if String.equal w.key key then Some ("workflow:" ^ w.id) else None)
  | Cancel_workflow id -> [ "workflow:" ^ id ]
  | Register _ -> []
  | Observe run ->
    let key = "observe:" ^ run.id in
    (* The service coalesces Observe with an already running automatic observer. Automatic
       observers carry [run]; their lifetime is the physical execution, not a one-shot
       query. Return their current snapshot instead of waiting for that entire execution.
       One-shot reads have no Pending.run and are awaited. *)
    if List.exists snapshot.operations ~f:(fun op ->
         String.equal op.key key && active op && Option.is_some op.run)
    then []
    else [ key ]
  | Load_summary run -> [ "summary:" ^ run.id ]
  | Refresh run -> [ "refresh:" ^ run.id ]
  | Inspect_finalization { run; attempt } ->
    [ "finalization:" ^ run.id ^ ":" ^ digest attempt ]
  | Finalize { key; _ } -> [ "finalize:" ^ key ]
  | Observe_finalization key -> [ "finalize-observe:" ^ key ]
  | List_artifacts run -> [ "artifacts:" ^ run.id ]
  | Read_artifact { run; artifact_id; offset; limit } ->
    [ Asic_artifact.read_key ~run ~artifact_id ~offset ~limit ]
  | Read_artifact_bytes { run; artifact_id; offset; limit } ->
    [ Asic_artifact.byte_read_key ~run ~artifact_id ~offset ~limit ]
  | Inspect { run; domain; stage; refresh = _ } ->
    [ Asic_inspection.index_key ~run ~domain ~stage ]
  | Inspect_detail { run; domain; stage; source_digest; row_id } ->
    [ Asic_inspection.detail_key ~run ~domain ~stage ~source_digest ~row_id ]
  | Inspect_analysis { run; target; refresh = _ } ->
    [ Asic_inspection.analysis_index_key ~run ~target ]
  | Inspect_analysis_detail { run; target; source_digest; row_id } ->
    [ Asic_inspection.analysis_detail_key ~run ~target ~source_digest ~row_id ]
  | Cancel key ->
    [ (if List.exists snapshot.operations ~f:(fun op -> String.equal op.key key)
       then key
       else if List.exists snapshot.operations ~f:(fun op ->
                 String.equal op.key ("finalize:" ^ key))
       then "finalize:" ^ key
       else "run:" ^ key)
    ]
;;

let watched_keys operation keys (snapshot : Asic.Snapshot.t) =
  match (operation : Asic.Operation.t) with
  | Run _ | Launch_fresh _ ->
    keys
    @ List.concat_map snapshot.operations ~f:(fun op ->
      if List.mem keys op.key ~equal:String.equal
      then
        Option.value_map op.run ~default:[] ~f:(fun run ->
          let observer = "observe:" ^ run.id in
          if List.exists snapshot.operations ~f:(fun op -> String.equal op.key observer)
          then [ observer ]
          else [])
      else [])
    |> List.dedup_and_sort ~compare:String.compare
  | _ -> keys
;;

let%test_unit "artifact waits distinguish offset and byte budget with the shared key" =
  let run = Fs0_fixture.run_a in
  let key offset limit =
    keys
      (Read_artifact { run; artifact_id = "exact-report"; offset; limit })
      Fs0_fixture.snapshot
    |> List.hd_exn
  in
  assert (
    String.equal
      (key 0 4096)
      (Asic_artifact.read_key ~run ~artifact_id:"exact-report" ~offset:0 ~limit:4096));
  assert (not (String.equal (key 0 4096) (key 0 65536)));
  assert (not (String.equal (key 0 4096) (key 4096 4096)))
;;

let%test_unit "FS1 waits use shared index detail and binary page identities" =
  let run = Fs0_fixture.run_a in
  let keys_for op = keys op Fs0_fixture.snapshot in
  let index refresh =
    keys_for (Inspect { run; domain = "timing"; stage = "signoff"; refresh })
  in
  assert (
    List.equal
      String.equal
      (index false)
      [ Asic_inspection.index_key ~run ~domain:"timing" ~stage:"signoff" ]);
  assert (List.equal String.equal (index false) (index true));
  let detail digest row_id =
    keys_for
      (Inspect_detail
         { run; domain = "timing"; stage = "signoff"; source_digest = digest; row_id })
  in
  assert (
    List.equal
      String.equal
      (detail "digest" "row")
      [ Asic_inspection.detail_key
          ~run
          ~domain:"timing"
          ~stage:"signoff"
          ~source_digest:"digest"
          ~row_id:"row"
      ]);
  assert (not (List.equal String.equal (detail "digest" "row") (detail "changed" "row")));
  assert (not (List.equal String.equal (detail "digest" "row") (detail "digest" "other")));
  let bytes offset limit =
    keys_for (Read_artifact_bytes { run; artifact_id = "gds"; offset; limit })
  in
  assert (
    List.equal
      String.equal
      (bytes 0 65536)
      [ Asic_artifact.byte_read_key ~run ~artifact_id:"gds" ~offset:0 ~limit:65536 ]);
  assert (not (List.equal String.equal (bytes 0 65536) (bytes 65536 65536)));
  assert (not (List.equal String.equal (bytes 0 65536) (bytes 0 4096)))
;;

type progress =
  | Pending
  | Complete
  | Failed of string

let%test_unit "fresh RPC keys preserve historical snapshot defaults and distinguish \
               workflow ownership"
  =
  let old = Asic.Snapshot.sexp_of_t Fs0_fixture.snapshot in
  let historical =
    match old with
    | Sexp.List fields ->
      Sexp.List
        (List.filter fields ~f:(function
          | Sexp.List (Sexp.Atom ("fresh_intent" | "workflows") :: _) -> false
          | _ -> true))
    | _ -> assert false
  in
  let restored = Asic.Snapshot.t_of_sexp historical in
  assert (Option.is_none restored.fresh_intent && List.is_empty restored.workflows);
  let intent = Fs0_fixture.fresh_intent "wait" in
  let w = Fs0_fixture.workflow "wait-key" intent in
  let snapshot = { restored with fresh_intent = Some intent; workflows = [ w ] } in
  assert (
    List.is_empty
      (keys
         (Stage_fresh
            { selection = intent.selection
            ; elaboration_only = false
            ; expected_plan_identity = None
            })
         snapshot));
  assert (
    List.equal
      String.equal
      (keys (Launch_fresh { key = w.key; intent_id = intent.id }) snapshot)
      [ "workflow:" ^ w.id ]);
  assert (
    List.equal String.equal (keys (Cancel_workflow w.id) snapshot) [ "workflow:" ^ w.id ])
;;

let finalization_error key (snapshot : Asic.Snapshot.t) =
  let identity =
    Option.first_some
      (String.chop_prefix key ~prefix:"finalize:")
      (String.chop_prefix key ~prefix:"finalize-observe:")
  in
  Option.bind identity ~f:(fun identity ->
    List.find snapshot.finalizations ~f:(fun f -> String.equal f.key identity)
    |> Option.bind ~f:(fun f ->
      Option.first_some
        f.error
        (if List.exists [ Some f.state; f.operation_status; f.acceptance ] ~f:(function
              | Some ("failed" | "interrupted" | "fail" | "rejected" | "error") -> true
              | _ -> false)
         then
           Some
             ("Finalization reported "
              ^ f.state
              ^ "; operation="
              ^ Option.value f.operation_status ~default:"unreported"
              ^ "; acceptance="
              ^ Option.value f.acceptance ~default:"unreported")
         else None)))
;;

let progress ~wait keys (snapshot : Asic.Snapshot.t) =
  List.fold keys ~init:Complete ~f:(fun progress key ->
    match progress with
    | Failed _ -> progress
    | Pending | Complete ->
      let workflow =
        List.find snapshot.workflows ~f:(fun w -> String.equal key ("workflow:" ^ w.id))
      in
      (match workflow with
       | Some w ->
         (match w.phase with
          | Failed | Cancelled | Interrupted ->
            Failed
              (Option.value
                 w.error
                 ~default:
                   ("Workflow " ^ Sexp.to_string (Asic.Fresh.Phase.sexp_of_t w.phase)))
          | Completed -> progress
          | Reserved | Building | Emitting | Prepared | Physical ->
            if wait then Pending else progress)
       | None ->
         (match List.find snapshot.operations ~f:(fun op -> String.equal op.key key) with
          | None -> Failed ("Requested ASIC operation is absent or evicted: " ^ key)
          | Some { error = Some error; _ } -> Failed (key ^ ": " ^ error)
          | Some op ->
            (match op.state with
             | "completed" ->
               Option.value_map
                 (finalization_error key snapshot)
                 ~default:progress
                 ~f:(fun error -> Failed (key ^ ": " ^ error))
             | "pending" | "executing" -> if wait then Pending else progress
             | "failed" | "detached" -> Failed (key ^ ": " ^ op.state)
             | state -> Failed ("Unknown ASIC operation state for " ^ key ^ ": " ^ state)))))
;;

let%test_unit "documented typed operation sexps decode without a shell or human-output \
               parser"
  =
  let plan =
    Asic.Operation.t_of_sexp
      (Sexp.of_string
         "(Plan ((flow synth) (profile default) (endpoint synthesis) (assignments \
          (WIDTH=4))))")
  in
  assert (
    match plan with
    | Plan selection ->
      String.equal selection.flow "synth"
      && List.equal String.equal selection.assignments [ "WIDTH=4" ]
    | _ -> false);
  let mutation =
    Workspace.Operation.t_of_sexp
      (Sexp.of_string
         "(Mutate (expected_revision 0) (mutation (Make_independent workspace-4)))")
  in
  assert (
    match mutation with
    | Mutate { expected_revision = 0; mutation = Make_independent _ } -> true
    | _ -> false)
;;

let%test_unit "workflow wait consults durable phase including failure after successful \
               RPC and restored terminal history"
  =
  let intent = Fs0_fixture.fresh_intent "wait" in
  let w = Fs0_fixture.workflow "wait-key" intent in
  let check phase expected =
    let snapshot = { Fs0_fixture.snapshot with workflows = [ { w with phase } ] } in
    match progress ~wait:true [ "workflow:" ^ w.id ] snapshot, expected with
    | Pending, `Pending | Complete, `Complete | Failed _, `Failed -> ()
    | _ -> assert false
  in
  List.iter
    [ Asic.Fresh.Phase.Reserved; Building; Emitting; Prepared; Physical ]
    ~f:(fun phase -> check phase `Pending);
  check Completed `Complete;
  List.iter [ Asic.Fresh.Phase.Failed; Cancelled; Interrupted ] ~f:(fun phase ->
    check phase `Failed)
;;

let%test_unit "lifecycle wait keys distinguish collection, reconnect, and acceptance \
               failure"
  =
  let run = Fs0_fixture.run_a in
  let key = "exact-finalization-key" in
  let finalization : Asic.Finalization.t =
    { key
    ; run
    ; execution_file = "/daemon/execution"
    ; acceptance_requested = true
    ; attempt = Some "/daemon/operation"
    ; state = "completed"
    ; phase = Some "acceptance"
    ; operation_status = Some "completed"
    ; acceptance = Some "fail"
    ; error = None
    ; owned = false
    ; execution_timing = None
    }
  in
  let pending key : Asic.Pending.t =
    { key
    ; kind = "finalize"
    ; state = "completed"
    ; run = Some run
    ; error = None
    ; activity = Unreported
    }
  in
  let snapshot =
    { Fs0_fixture.snapshot with
      finalizations = [ finalization ]
    ; operations = [ pending ("finalize:" ^ key); pending ("finalize-observe:" ^ key) ]
    }
  in
  assert (
    List.equal
      String.equal
      (keys
         (Finalize
            { key; run; execution_file = finalization.execution_file; acceptance = None })
         snapshot)
      [ "finalize:" ^ key ]);
  assert (
    List.equal
      String.equal
      (keys (Observe_finalization key) snapshot)
      [ "finalize-observe:" ^ key ]);
  List.iter
    [ "finalize:" ^ key; "finalize-observe:" ^ key ]
    ~f:(fun key ->
      match progress ~wait:true [ key ] snapshot with
      | Failed _ -> ()
      | _ -> assert false);
  let snapshot =
    { snapshot with finalizations = [ { finalization with acceptance = Some "pass" } ] }
  in
  (match progress ~wait:true [ "finalize:" ^ key ] snapshot with
   | Complete -> ()
   | _ -> assert false);
  (* Reported producer status never masquerades as a Pending machine state. *)
  let snapshot =
    { snapshot with
      operations = [ { (pending ("finalize:" ^ key)) with state = "executing" } ]
    }
  in
  match progress ~wait:true [ "finalize:" ^ key ] snapshot with
  | Pending -> ()
  | _ -> assert false
;;

let%test_unit "Observe waits for its read, independently of a long execution" =
  let run : Run_ref.t =
    { backend = Backend_id.of_string "asic"; id = "fixture"; build = None; label = None }
  in
  let operation key kind state : Asic.Pending.t =
    { key; kind; state; run = None; error = None; activity = Unreported }
  in
  let snapshot : Asic.Snapshot.t =
    { configured = true
    ; launches = []
    ; fresh_intent = None
    ; workflows = []
    ; resources = None
    ; workloads = None
    ; flows = []
    ; catalog_default = None
    ; description_json = None
    ; preview = None
    ; runs = []
    ; operations =
        [ operation "run:long" "run" "executing"
        ; operation "observe:fixture" "observe" "completed"
        ]
    ; summaries = []
    ; cache_error = None
    ; finalizations = []
    ; artifacts = []
    ; artifact_pages = []
    ; artifact_byte_pages = []
    ; inspections = []
    ; inspection_details = []
    }
  in
  let watched = keys (Observe run) snapshot in
  assert (
    match progress ~wait:true watched snapshot with
    | Complete -> true
    | _ -> false);
  assert (
    match progress ~wait:true (keys Get snapshot) snapshot with
    | Pending -> true
    | _ -> false);
  assert (
    match progress ~wait:false (keys Get snapshot) snapshot with
    | Complete -> true
    | _ -> false)
;;

let%test_unit "finalization waits for the exact attempt rather than an earlier import" =
  let run = Fs0_fixture.run_a in
  let old_attempt = "/private/finalization/old/operation.json" in
  let attempt = "/private/finalization/exact/operation.json" in
  let snapshot = Fs0_fixture.snapshot in
  let requested = keys (Inspect_finalization { run; attempt }) snapshot in
  let old_key =
    List.hd_exn (keys (Inspect_finalization { run; attempt = old_attempt }) snapshot)
  in
  let key = List.hd_exn requested in
  assert (not (String.equal old_key key));
  let completed : Asic.Pending.t =
    { key = old_key
    ; kind = "finalization"
    ; state = "completed"
    ; run = None
    ; error = None
    ; activity = Unreported
    }
  in
  let snapshot = { snapshot with operations = [ completed ] } in
  (match progress ~wait:true requested snapshot with
   | Failed _ -> ()
   | _ -> assert false);
  let snapshot =
    { snapshot with
      operations = { completed with key; state = "executing" } :: snapshot.operations
    }
  in
  (match progress ~wait:true requested snapshot with
   | Pending -> ()
   | _ -> assert false);
  let snapshot = { snapshot with operations = [ { completed with key } ] } in
  match progress ~wait:true requested snapshot with
  | Complete -> ()
  | _ -> assert false
;;

let%test_unit "Observe does not await the lifetime of a coalesced automatic observer" =
  let run : Run_ref.t =
    { backend = Backend_id.of_string "asic"; id = "fixture"; build = None; label = None }
  in
  let observer : Asic.Pending.t =
    { key = "observe:fixture"
    ; kind = "observe"
    ; state = "executing"
    ; run = Some run
    ; error = None
    ; activity = Unreported
    }
  in
  let snapshot : Asic.Snapshot.t =
    { configured = true
    ; flows = []
    ; catalog_default = None
    ; description_json = None
    ; preview = None
    ; runs = []
    ; operations = [ observer ]
    ; launches = []
    ; fresh_intent = None
    ; workflows = []
    ; resources = None
    ; workloads = None
    ; summaries = []
    ; cache_error = None
    ; finalizations = []
    ; artifacts = []
    ; artifact_pages = []
    ; artifact_byte_pages = []
    ; inspections = []
    ; inspection_details = []
    }
  in
  assert (List.is_empty (keys (Observe run) snapshot));
  assert (
    match progress ~wait:true (keys Get snapshot) snapshot with
    | Pending -> true
    | _ -> false)
;;

let%test_unit "a targeted operation failure fails without treating historical failures \
               as Get failures"
  =
  let failed : Asic.Pending.t =
    { key = "discover"
    ; kind = "discover"
    ; state = "failed"
    ; run = None
    ; error = Some "fixture failure"
    ; activity = Unreported
    }
  in
  let snapshot : Asic.Snapshot.t =
    { configured = true
    ; flows = []
    ; catalog_default = None
    ; description_json = None
    ; preview = None
    ; runs = []
    ; operations = [ failed ]
    ; launches = []
    ; fresh_intent = None
    ; workflows = []
    ; resources = None
    ; workloads = None
    ; summaries = []
    ; cache_error = None
    ; finalizations = []
    ; artifacts = []
    ; artifact_pages = []
    ; artifact_byte_pages = []
    ; inspections = []
    ; inspection_details = []
    }
  in
  assert (
    match progress ~wait:true (keys Discover snapshot) snapshot with
    | Failed _ -> true
    | _ -> false);
  assert (
    match progress ~wait:true (keys Get snapshot) snapshot with
    | Complete -> true
    | _ -> false)
;;
