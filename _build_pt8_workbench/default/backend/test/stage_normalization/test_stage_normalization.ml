open! Core
open Hardcaml_workbench_protocol
module Public = Hardcaml_workbench_backend.Asic_public

let require b message = if not b then failwith message
let stream = "6c006def1f794542a1c4cf481e8eba2f"

let set j key value =
  match j with
  | `Assoc fields ->
    `Assoc ((key, value) :: List.Assoc.remove fields key ~equal:String.equal)
  | _ -> assert false
;;

let occurrence ?(stage = "synthesis") status exit =
  `Assoc
    [ "occurrence_id", `String (stream ^ "/implementation." ^ stage)
    ; "action_key", `String ("implementation." ^ stage)
    ; "status", `String status
    ; "exit_code", exit
    ; "duration_seconds", `Int 0
    ; "best_effort", `Bool false
    ; "error", `Null
    ; "verdict", `Null
    ]
;;

let recipe ?(version = 3) ?(initial = `Null) stages =
  if version = 2
  then
    `Assoc
      [ "schema_version", `Int 2
      ; "endpoint", `String (Option.value (List.last stages) ~default:"signoff")
      ; "resume", `Bool (not (Poly.equal initial `Null))
      ]
  else
    `Assoc
      [ "schema_version", `Int version
      ; "stages", `List (List.map stages ~f:(fun s -> `String s))
      ; "initial_boundary", initial
      ]
;;

let observation ?(plan = recipe [ "synthesis" ]) occurrences =
  `Assoc
    [ "contract", `String "hardcaml-asic.stage-observation"
    ; "schema_version", `Int 2
    ; "stream_id", `String stream
    ; "cursor", `Int 4
    ; "writer_active", `Bool true
    ; "observation_status", `String "live"
    ; "execution_file", `Null
    ; ( "state"
      , `Assoc
          [ "attempt_id", `String stream
          ; "plan", plan
          ; "occurrences", `List occurrences
          ; "outcome", `Null
          ; "artifacts", `List [ `Assoc [ "boundary", `String "synthesis" ] ]
          ] )
    ]
;;

let run : Asic.Run.t =
  { run =
      { backend = Backend_id.of_string "asic"; id = stream; build = None; label = None }
  ; reference = { attempt = "/public/attempt"; stream_id = stream }
  ; selection = None
  ; cursor = 0
  ; status = "allocated"
  ; execution_file = None
  ; error = None
  ; stages = []
  ; execution_timing = None
  }
;;

let stages j =
  let r, _ = Public.inspection run ~cursor:4 j in
  r.stages
;;

let synthesis j = List.hd_exn (stages j)

let rejected f =
  require (Result.is_error (Or_error.try_with f)) "Invalid stage evidence accepted"
;;

let unknown (s : Asic.Stage.t) =
  match s.status with
  | Unknown _ -> ()
  | _ -> failwith "Unknown stage evidence acquired a known status"
;;

let fixtures () =
  List.iter
    [ "unreached", `Null; "running", `Null ]
    ~f:(fun (status, exit) ->
      require
        (Option.is_none
           (synthesis (observation [ occurrence status exit ])).execution_timing)
        "Placeholder zero became measured duration");
  let completed =
    occurrence "completed" (`Int 0) |> fun o -> set o "duration_seconds" (`Float 12.5)
  in
  let measured = synthesis (observation [ completed ]) in
  require
    (Option.equal
       Float.equal
       (Option.value_exn measured.execution_timing).measured_seconds
       (Some 12.5))
    "Authoritative occurrence duration lost";
  List.iter
    [ `Int (-1); `Float Float.infinity; `String "12"; `Null ]
    ~f:(fun value ->
      require
        (Option.is_none
           (synthesis (observation [ set completed "duration_seconds" value ]))
             .execution_timing)
        "Invalid duration accepted");
  let event name data elapsed =
    `Assoc
      [ "event", `String name
      ; "data", data
      ; "recorded_at", `String "2026-10-20T12:00:00.000000Z"
      ; "elapsed_seconds", `Float elapsed
      ]
  in
  let events xs = `Assoc [ "events", `List xs ] in
  let r, _ =
    Public.inspection run ~cursor:4 (observation [ occurrence "running" `Null ])
  in
  let running =
    Public.updates_timing
      r
      ~writer_active:true
      (events
         [ event "allocated" `Null 0.
         ; event "started" (`Assoc [ "occurrence", occurrence "running" `Null ]) 2.
         ])
  in
  require (Option.value_exn running.execution_timing).running "Run start missing";
  require
    (Option.value_exn (List.hd_exn running.stages).execution_timing).running
    "Stage start missing";
  let starts =
    Public.stage_start_events
      (events
         [ event "started" (`Assoc [ "occurrence", occurrence "running" `Null ]) 2. ])
  in
  let starts =
    [%of_sexp: (string * Timestamp.t) list]
      ([%sexp_of: (string * Timestamp.t) list] starts)
  in
  let ahead, _ =
    Public.inspection run ~cursor:3 (observation [ occurrence "running" `Null ])
  in
  require (List.is_empty ahead.stages) "Race fixture did not fence checklist";
  let caught_up, _ =
    Public.inspection ahead ~cursor:4 (observation [ occurrence "running" `Null ])
  in
  let caught_up = Public.with_stage_starts caught_up ~writer_active:true starts in
  require
    (Option.value_exn (List.hd_exn caught_up.stages).execution_timing).running
    "Retained start anchor lost across cursor race/serialization";
  let detached, _ =
    Public.inspection
      running
      ~cursor:4
      (observation [ occurrence "running" `Null ]
       |> fun j -> set j "writer_active" (`Bool false))
  in
  require
    (not (Option.value_exn detached.execution_timing).running)
    "Detached run still ticking";
  require
    (not (Option.value_exn (List.hd_exn detached.stages).execution_timing).running)
    "Detached stage still ticking";
  let finished =
    Public.updates_timing
      detached
      ~writer_active:false
      (events [ event "outcome" `Null 99. ])
  in
  require
    (Option.equal
       Float.equal
       (Option.value_exn finished.execution_timing).measured_seconds
       (Some 99.))
    "Run total must be outcome elapsed, not stage sum";
  let receipt =
    `Assoc
      [ "started_at", `String "2026-10-20T12:00:00.000000Z"
      ; "ended_at", `String "2026-10-20T12:00:07.500000Z"
      ]
  in
  require
    (Option.equal
       Float.equal
       (Option.value_exn (Public.receipt_timing ~running:false receipt)).measured_seconds
       (Some 7.5))
    "Receipt duration lost";
  List.iter
    [ "unreached", `Null, Asic.Stage.Status.Pending
    ; "running", `Null, Running
    ; "completed", `Int 0, Completed
    ; "failed", `Int 1, Failed
    ; "interrupted", `Int 130, Cancelled
    ]
    ~f:(fun (status, exit, expected) ->
      let j = observation [ occurrence status exit ] in
      let all = stages j in
      let first = List.hd_exn all in
      require
        (Asic.Stage.Status.equal first.status expected && first.requested)
        "Occurrence status lost";
      require (List.length all = 6) "Canonical stage list missing";
      List.iter (List.tl_exn all) ~f:(fun s ->
        require
          ((not s.requested) && Asic.Stage.Status.equal s.status Not_requested)
          "Synthesis-only requested physical stages");
      List.iter all ~f:(fun s ->
        require (Option.is_none s.action) "Invented fresh selection");
      (* A publication never completes a running occurrence. Outer failure does not
         overwrite an independently completed earlier stage either. *)
      List.iter [ "completed"; "failed"; "interrupted" ] ~f:(fun outer ->
        let state =
          Public.field "state" j
          |> fun state ->
          set state "outcome" (`Assoc [ "status", `String outer; "exit_code", `Int 1 ])
        in
        require
          (Asic.Stage.Status.equal (synthesis (set j "state" state)).status expected)
          "Aggregate outcome reinterpreted occurrence";
        let terminal =
          set
            (set (set j "state" state) "writer_active" (`Bool false))
            "observation_status"
            (`String "final")
        in
        let terminal_run, final = Public.inspection run ~cursor:4 terminal in
        require
          (final
           && String.equal terminal_run.status outer
           && Asic.Stage.Status.equal (List.hd_exn terminal_run.stages).status expected)
          "Terminal outcome reinterpreted stage occurrence");
      let detached =
        set
          (set j "writer_active" (`Bool false))
          "observation_status"
          (`String "writer_lost_or_unknown")
      in
      require
        (Asic.Stage.Status.equal (synthesis detached).status expected)
        "Writer loss inferred occurrence completion");
  List.iter
    [ occurrence "future" (`Int 0)
    ; occurrence "completed" (`Int 1)
    ; occurrence "running" (`Int 0)
    ; occurrence "failed" (`Int 0)
    ; occurrence "interrupted" (`Int 0)
    ; occurrence "failed" `Null
    ; occurrence "completed" (`String "0")
    ]
    ~f:(fun o -> unknown (synthesis (observation [ o ])));
  unknown (synthesis (observation []));
  let completed = occurrence "completed" (`Int 0) in
  List.iter
    [ observation [ completed; completed ]
    ; observation
        [ set completed "occurrence_id" (`String "other/implementation.synthesis") ]
    ; observation [ set completed "action_key" (`String "implementation.librelane") ]
    ; observation ~plan:(recipe [ "synthesis"; "synthesis" ]) [ completed ]
    ; observation ~plan:(recipe [ "floorplan" ]) [ completed ]
    ; observation ~plan:(recipe [ "future_stage" ]) [ completed ]
    ; observation [ `Assoc [ "status", `String "completed" ] ]
    ; observation [ set completed "best_effort" (`Bool true) ]
    ; observation [ set completed "verdict" (`String "pass") ]
    ]
    ~f:(fun j -> rejected (fun () -> stages j));
  let j = observation [ completed ] in
  let state = Public.field "state" j in
  rejected (fun () -> stages (set j "state" (set state "attempt_id" (`String "other"))));
  let resumed =
    observation
      ~plan:(recipe ~initial:(`String "synthesis") [ "floorplan" ])
      [ occurrence ~stage:"floorplan" "running" `Null ]
  in
  let input = synthesis resumed in
  require
    ((not input.requested)
     && Asic.Stage.Status.equal input.status Not_requested
     && String.is_substring
          (Option.value_exn input.reason)
          ~substring:"not newly measured")
    "Resume boundary became measured completion";
  let carried =
    set
      resumed
      "state"
      (set
         (Public.field "state" resumed)
         "occurrences"
         (`List [ completed; occurrence ~stage:"floorplan" "running" `Null ]))
    |> synthesis
  in
  require
    ((not carried.requested)
     && Asic.Stage.Status.equal carried.status Completed
     && String.is_substring carried.name ~substring:"carried forward")
    "Carry-forward evidence conflated with requested measurement";
  let unrequested_failure =
    set
      resumed
      "state"
      (set
         (Public.field "state" resumed)
         "occurrences"
         (`List
           [ occurrence "failed" (`Int 1); occurrence ~stage:"floorplan" "running" `Null ]))
  in
  unknown (synthesis unrequested_failure);
  List.iter [ 2; 3; 4 ] ~f:(fun version ->
    let canonical = Public.recipe_stages (recipe ~version []) in
    let full =
      stages
        (observation
           ~plan:(recipe ~version canonical)
           (List.map canonical ~f:(fun stage -> occurrence ~stage "completed" (`Int 0))))
    in
    require
      (List.for_all full ~f:(fun s ->
         s.requested && Asic.Stage.Status.equal s.status Completed))
      "Full-run explicit evidence lost";
    require
      (List.length full = if version = 4 then 7 else 6)
      "Recipe-specific stage count changed";
    require
      (Bool.equal
         (version = 4)
         (List.exists full ~f:(fun s -> String.equal s.id "timing")))
      "Legacy recipe gained fabricated Timing occurrence");
  let prefix = List.take Public.canonical_stages 6 in
  let stopped =
    stages
      (observation
         ~plan:(recipe ~version:4 prefix)
         (List.map prefix ~f:(fun stage -> occurrence ~stage "completed" (`Int 0))))
  in
  let timing = List.find_exn stopped ~f:(fun s -> String.equal s.id "timing") in
  let signoff = List.last_exn stopped in
  require
    (timing.requested
     && Asic.Stage.Status.equal timing.status Completed
     && (not signoff.requested)
     && Asic.Stage.Status.equal signoff.status Not_requested)
    "Timing endpoint invented downstream execution";
  List.iter
    [ "routing", "timing"; "timing", "signoff" ]
    ~f:(fun (source, target) ->
      let resumed =
        stages
          (observation
             ~plan:(recipe ~version:4 ~initial:(`String source) [ target ])
             [ occurrence ~stage:target "completed" (`Int 0) ])
      in
      require
        ((List.find_exn resumed ~f:(fun s -> String.equal s.id target)).requested
         && not (List.find_exn resumed ~f:(fun s -> String.equal s.id source)).requested)
        "Exact continuation stage identity lost");
  let legacy_resume =
    stages
      (observation
         ~plan:(recipe ~version:2 ~initial:(`String "synthesis") [ "signoff" ])
         (List.map
            [ "floorplan"; "placement"; "cts"; "routing"; "signoff" ]
            ~f:(fun stage -> occurrence ~stage "completed" (`Int 0))))
  in
  require
    (List.length legacy_resume = 6
     && (not (List.hd_exn legacy_resume).requested)
     && List.for_all (List.tl_exn legacy_resume) ~f:(fun s -> s.requested))
    "Historical schema-2 resume was expanded using new Timing graph";
  let next, _ = Public.inspection run ~cursor:3 j in
  require
    (List.is_empty next.stages && next.cursor = 3)
    "Ahead inspection escaped cursor fence";
  let caught_up, _ = Public.inspection next ~cursor:4 j in
  require (List.length caught_up.stages = 6) "Caught-up inspection lost stages";
  rejected (fun () -> Public.inspection caught_up ~cursor:3 j);
  rejected (fun () -> Public.inspection run ~cursor:5 j);
  rejected (fun () ->
    Public.inspection run ~cursor:4 (set j "stream_id" (`String "other")));
  List.iter
    [ `Null
    ; `Assoc [ "schema_version", `Int 1 ]
    ; (recipe [] |> fun p -> set p "schema_version" (`Int 99))
    ]
    ~f:(fun plan ->
      require
        (List.is_empty (stages (observation ~plan [])))
        "Unknown/legacy plan inferred stages");
  let extension version =
    `Assoc
      [ "contract", `String "hardcaml-asic.stage-plan"
      ; "schema_version", `Int version
      ; ( "stages"
        , `List
            [ `Assoc
                [ "id", `String "override"
                ; "name", `String "Override"
                ; "status", `String "pending"
                ; "requested", `Bool true
                ]
            ] )
      ]
  in
  require
    (String.equal (List.hd_exn (stages (set j "stage_plan" (extension 1)))).id "override")
    "Supported extension lost precedence";
  require
    (List.is_empty (stages (set j "stage_plan" (extension 2))))
    "Unsupported extension reinterpreted via fallback";
  require
    (List.length (stages (set j "stage_plan" `Null)) = 6)
    "Null extension blocked structured state";
  print_endline "structured stage normalization fixtures passed"
;;

let () =
  fixtures ();
  (* Optional read-only proof against a captured public inspect response. *)
  Array.iter
    (Array.sub (Sys.get_argv ()) ~pos:1 ~len:(Array.length (Sys.get_argv ()) - 1))
    ~f:(fun path ->
      let j = Public.decode (In_channel.read_all path) in
      let stream_id = Public.text (Public.field "stream_id" j) in
      let r = { run with reference = { run.reference with stream_id } } in
      let cursor = Public.integer (Public.field "cursor" j) in
      let r, _ = Public.inspection r ~cursor j in
      require (List.length r.stages = 6) "Retained observation lacks normalized stages";
      print_s [%sexp (path : string), (r.stages : Asic.Stage.t list)])
;;
