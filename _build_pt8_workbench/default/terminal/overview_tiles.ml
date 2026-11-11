open! Core
open Hardcaml_workbench_protocol
open Bonsai_term

(** Pure utility tiles. Only explicit per-stage observations fill in a checklist;
    aggregate completion and metrics never stand in for stage evidence. *)
module Status = struct
  type t =
    | Unknown
    | Not_requested
    | Pending
    | Running
    | Completed
    | Failed
    | Skipped
    | Cancelled
    | Unsupported
    | Unrecognized of string
  [@@deriving compare, equal, sexp]

  let label = function
    | Unknown -> "not reported"
    | Not_requested -> "not requested"
    | Pending -> "pending"
    | Running -> "running"
    | Completed -> "completed"
    | Failed -> "failed"
    | Skipped -> "skipped"
    | Cancelled -> "cancelled"
    | Unsupported -> "unsupported"
    | Unrecognized ("observation_unavailable" | "unconfirmed") -> "unconfirmed"
    | Unrecognized "not_started" -> "not started"
    | Unrecognized value -> "unknown: " ^ value
  ;;
end

module Role = struct
  type t =
    | Heading
    | Foreground
    | Muted
    | Active
    | Running
    | Success
    | Warning
    | Failure
    | Linked
  [@@deriving compare, equal, sexp]
end

type row =
  { label : string
  ; value : string
  ; role : Role.t
  ; status : Status.t option
  ; indicator : Indicator.t option
  (** Static semantic marker, separate from stage status and its running animation. A
      status takes precedence so a row never acquires two indicators. *)
  ; active : bool
  ; workspace : Workspace.Workspace_id.t option
  ; details : string list
  ; display_run : Run_ref.t option
  ; time : string option
  ; emphasis : int
  (** Leading bytes of [value] rendered with [Role.Linked]; [0] for none. The emphasized
      text is part of [value], so state never depends on color alone. *)
  }

let row
  ?(role = Role.Foreground)
  ?status
  ?indicator
  ?(active = false)
  ?workspace
  ?(details = [])
  ?display_run
  ?(emphasis = 0)
  ?time
  label
  value
  =
  { label
  ; value
  ; role
  ; status
  ; indicator
  ; active
  ; workspace
  ; details
  ; display_run
  ; emphasis
  ; time
  }
;;

let status_role : Status.t -> Role.t = function
  | Unknown | Not_requested | Unsupported | Unrecognized _ -> Muted
  | Pending | Skipped | Cancelled -> Warning
  | Running -> Running
  | Completed -> Success
  | Failed -> Failure
;;

(** [requested=false] is not allowed to erase an observed outcome. A completed stage from
    an earlier invocation can legitimately be outside the current request. *)
let stage_status (stage : Stage.t) : Status.t =
  match stage.status with
  | Not_run -> if stage.requested then Pending else Not_requested
  | Running -> Running
  | Completed -> Completed
  | Failed _ -> Failed
  | Skipped _ -> Skipped
;;

let stage_row (stage : Stage.t) =
  let status = stage_status stage in
  let reason =
    match stage.status with
    | Failed { reason } | Skipped { reason } -> [ "Reason: " ^ reason ]
    | Not_run | Running | Completed -> []
  in
  row
    ~time:"unknown"
    ~role:(status_role status)
    ~status
    ~details:([ sprintf "Requested: %b" stage.requested ] @ reason)
    stage.name
    (Status.label status)
;;

let default_stages = [ "Synthesis"; "Placement"; "CTS"; "Routing"; "Checks" ]
let run_identity (run : Run_ref.t) = Backend_id.to_string run.backend ^ "/" ^ run.id

let asic_stage_status : Asic.Stage.Status.t -> Status.t = function
  | Pending -> Pending
  | Running -> Running
  | Completed -> Completed
  | Failed -> Failed
  | Skipped -> Skipped
  | Cancelled -> Cancelled
  | Not_requested -> Not_requested
  | Unsupported -> Unsupported
  | Unknown value -> Unrecognized value
;;

let asic_stage_row ?(now = Time_ns.now ()) ~run ~selected (stage : Asic.Stage.t) =
  let status = asic_stage_status stage.status in
  row
    ~time:(Execution_time_view.list_value ~now stage.execution_timing)
    ~role:(status_role status)
    ~status
    ~active:selected
    ~details:
      ([ "Run: " ^ run_identity run
       ; "Stage ID: " ^ stage.id
       ; sprintf "Requested: %b" stage.requested
       ; "Reason: " ^ Option.value stage.reason ~default:"not reported"
       ]
       @ Option.to_list
           (Option.bind stage.execution_timing ~f:(fun t ->
              Option.map t.measured_seconds ~f:(fun seconds ->
                sprintf "Stage time: %.9g s (full execution segment)" seconds)))
       @ (match stage.status, stage.action with
          | Unsupported, _ -> [ "Action: unavailable (unsupported stage)" ]
          | _, None -> [ "Action: unavailable (no advertised stage selection)" ]
          | _, Some _ ->
            [ "Action: r prepares NEW run through endpoint (never resume this run)" ])
       @ Option.to_list
           (Option.map stage.action ~f:(fun selection ->
              "Advertised selection: "
              ^ Sexp.to_string_hum (Asic.Selection.sexp_of_t selection))))
    stage.name
    (Status.label status)
;;

(** Compact Overview keeps the six explicit stage observations ahead of aggregate facts.
    Callers retain full rows for inspection; this only controls presentation. *)
let checklist_rows ?(compact = false) ~stages ~aggregate () =
  if not compact
  then aggregate @ stages
  else (
    match stages with
    | [] -> aggregate
    | first :: rest ->
      { first with
        details =
          first.details
          @ List.concat_map aggregate ~f:(fun row ->
            (row.label ^ ": " ^ row.value) :: row.details)
      }
      :: rest)
;;

let%test_unit "compact checklist prioritizes explicit stages and retains aggregate \
               inspection"
  =
  let stages =
    List.init 6 ~f:(fun i -> row ~status:Status.Unknown (Int.to_string i) "not reported")
  in
  let aggregate = [ row ~details:[ "source digest" ] "Accept (agg.)" "pass" ] in
  let compact = checklist_rows ~compact:true ~stages ~aggregate () in
  assert (List.length compact = 6);
  assert (
    List.for_all compact ~f:(fun r -> Option.equal Status.equal r.status (Some Unknown)));
  assert (List.mem (List.hd_exn compact).details "Accept (agg.): pass" ~equal:String.equal);
  assert (List.mem (List.hd_exn compact).details "source digest" ~equal:String.equal);
  assert (List.length (checklist_rows ~stages ~aggregate ()) = 7)
;;

let execution ~asic ~run =
  Option.bind asic ~f:(fun (snapshot : Asic.Snapshot.t) ->
    List.find snapshot.runs ~f:(fun execution -> Run_ref.equal execution.run run))
;;

let observed_stages ~asic ~run =
  execution ~asic ~run |> Option.value_map ~default:[] ~f:(fun run -> run.stages)
;;

(** An endpoint is captured intent, not evidence of its prefix or its outcome. Do not
    use the current catalog or a global preview to reconstruct a historical recipe. *)
let unconfirmed_endpoint (selection : Asic.Selection.t) : Asic.Stage.t =
  { id = selection.endpoint
  ; name = selection.endpoint
  ; requested = true
  ; status = Unknown "unconfirmed"
  ; reason =
      Some
        "Captured requested endpoint; stage observation unavailable. Prefix stages are \
         not reported."
  ; action = None
  ; execution_timing = None
  }
;;

let workflow_endpoint_rows (w : Asic.Fresh.Workflow.t) =
  if w.intent.elaboration_only
  then []
  else
    [ row
        ~status:(Status.Unrecognized "unconfirmed")
        ~role:Muted
        ~time:"unknown"
        ~details:
          [ "Workflow: " ^ w.id
          ; "Requested endpoint only; no physical stage observation or prefix reported"
          ]
        w.intent.selection.endpoint
        "unconfirmed"
    ]
;;

(** Supplementary observations are deliberately not [Asic.Stage.t]: they have no launch
    endpoint and must never enter physical stage action inference. *)
type checklist_item =
  | Physical_stage of Asic.Stage.t
  | Timing_analysis of Asic.Summary.t option
  | Elaboration_preparation

let checklist_id = function
  | Elaboration_preparation -> "preparation:elaboration"
  | Physical_stage s -> s.Asic.Stage.id
  | Timing_analysis _ -> "analysis:post-pnr-sta"
;;

let timing_summary ~asic ~run =
  Option.bind asic ~f:(fun (snapshot : Asic.Snapshot.t) ->
    List.find snapshot.summaries ~f:(fun s -> Run_ref.equal s.run run))
;;

(** Generic inspection follows this run's observed schema, never the current provider
    catalog. Prefer the complete captured analysis identity (including frozen source).
    Six-stage retained executions still inspect Signoff. *)
let timing_inspection_target ~asic ~run =
  match Option.bind (timing_summary ~asic ~run) ~f:(fun s -> s.timing_analysis) with
  | Some analysis -> analysis.target.stage, Some analysis.target
  | None ->
    let stage =
      if List.exists (observed_stages ~asic ~run) ~f:(fun s ->
           String.equal s.Asic.Stage.id "timing")
      then "timing"
      else "signoff"
    in
    stage, None
;;

let checklist_items ~asic ~run =
  let stages = observed_stages ~asic ~run in
  let captured_selection =
    Option.first_some
      (Option.bind (execution ~asic ~run) ~f:(fun r -> r.selection))
      (Option.bind asic ~f:(fun (s : Asic.Snapshot.t) ->
         List.find_map s.workflows ~f:(fun w ->
           if Option.exists w.run ~f:(Run_ref.equal run) && not w.intent.elaboration_only
           then Some w.intent.selection
           else None)))
  in
  let endpoint_only = List.is_empty stages && Option.is_some captured_selection in
  let stages =
    match captured_selection with
    | Some selection
      when not (List.exists stages ~f:(fun s -> String.equal s.Asic.Stage.id selection.endpoint)) ->
      stages @ [ unconfirmed_endpoint selection ]
    | _ -> stages
  in
  let timing = Timing_analysis (timing_summary ~asic ~run) in
  let rec insert = function
    | [] -> [ timing ]
    | (s : Asic.Stage.t) :: rest when String.equal s.id "routing" ->
      Physical_stage s :: timing :: List.map rest ~f:(fun s -> Physical_stage s)
    | s :: rest when String.equal s.id "signoff" ->
      timing :: List.map (s :: rest) ~f:(fun s -> Physical_stage s)
    | s :: rest -> Physical_stage s :: insert rest
  in
  Elaboration_preparation
  ::
  (if endpoint_only
   then List.map stages ~f:(fun s -> Physical_stage s)
   else if List.exists stages ~f:(fun s -> String.equal s.Asic.Stage.id "timing")
   then
     List.map stages ~f:(fun s ->
       let s =
         if String.equal s.id "timing" && Option.is_none s.action
         then (
           let observed = Option.bind (execution ~asic ~run) ~f:(fun r -> r.selection) in
           match
             Stage_action.resolve ~stage:s ~remembered:None ~observed ~snapshot:asic
           with
           | Ok selection -> { s with action = Some selection }
           | Error _ -> s)
         else s
       in
       Physical_stage s)
   else insert stages)
;;

let goal_label : Asic.Timing_analysis.Goal.t -> string = function
  | Pass -> "pass"
  | Fail -> "fail"
  | Unknown -> "unknown"
;;

let analysis_duration (a : Asic.Timing_analysis.t) =
  Option.value_map a.duration ~default:"unknown" ~f:(fun d ->
    Option.value_map
      (Execution_timing.seconds (Some d.seconds))
      ~default:"unknown"
      ~f:(fun seconds -> sprintf "%gs" seconds))
;;

let timing_metric_value ~decimal_places ~key ~unit_ value =
  if Option.equal String.equal unit_ (Some "count")
     || List.mem [ "setup_violations"; "hold_violations" ] key ~equal:String.equal
  then sprintf "%g" value
  else Presentation.decimal ~places:decimal_places value
;;

let analysis_details ?(decimal_places = 3) ~run (summary : Asic.Summary.t option) =
  [ "Run: " ^ run_identity run
  ; "Analysis: post-PNR STA (independent of physical stage completion)"
  ]
  @ Option.value_map
      summary
      ~default:[ "No authoritative analysis observation" ]
      ~f:(fun s ->
        [ ("Evidence freshness: "
           ^
           match s.freshness with
           | Validated -> "validated"
           | Cached_unverified -> "cached/unverified"
           | Missing_source -> "missing source"
           | Refresh_failed _ -> "refresh failed (details below)")
        ]
        @ Option.value_map
            s.timing_analysis
            ~default:
              ([ "Analysis not yet observed; no status, duration or metrics inferred" ]
               @
               match s.freshness with
               | Refresh_failed reason -> [ "Refresh error: " ^ reason ]
               | _ -> [])
            ~f:(fun a ->
              [ "Stage: " ^ a.target.stage ^ " / post-PNR STA"
              ; "Attempt: " ^ a.target.attempt_id
              ; "Occurrence: " ^ a.target.occurrence_id
              ; "Analysis ID: " ^ a.target.analysis_id
              ; "Analysis source digest: " ^ a.target.source_digest
              ; "Execution SHA256: " ^ a.target.execution_sha256
              ; "Current execution outcome: " ^ s.completion
              ; "Captured source status: " ^ a.enclosing_status
              ; "Timing goal: "
                ^ goal_label a.timing_goal
                ^ " (independent of analysis completion and signoff acceptance)"
              ; (if String.equal a.target.stage "timing"
                 then
                   "Action: Enter exact evidence; physical Timing r prepares advertised \
                    endpoint"
                 else
                   "Action: Enter exact historical evidence; r prepares a NEW timing run \
                    only if current catalog supports it")
              ]
              @ Evidence_time_view.summary_lines s.observed_at
              @ Option.to_list (Option.map a.reason ~f:(fun r -> "Reason: " ^ r))
              @ Option.value_map a.duration ~default:[ "Duration: unknown" ] ~f:(fun d ->
                [ sprintf
                    "Duration: %g s; basis: %s; precision: %g s; source: %s"
                    d.seconds
                    d.basis
                    d.precision_seconds
                    d.source
                ])
              @ List.map a.corners ~f:(fun c ->
                sprintf
                  "Corner %s: measured=%b; setup=%s; hold=%s"
                  c.corner
                  c.measured
                  (goal_label c.setup_goal)
                  (goal_label c.hold_goal))
              @ List.map a.metrics ~f:(fun m ->
                sprintf
                  "Metric %s / %s: %s %s; raw key: %s; source: %s%s"
                  m.key
                  m.corner
                  (Option.value_map
                     m.value
                     ~default:"unavailable"
                     ~f:(timing_metric_value ~decimal_places ~key:m.key ~unit_:m.unit_))
                  (Option.value m.unit_ ~default:"unit unknown")
                  m.raw_key
                  m.provenance
                  (Option.value_map m.reason ~default:"" ~f:(fun r -> "; " ^ r)))
              @ [ "Producer: " ^ Option.value a.producer ~default:"unknown"
                ; "Evidence: " ^ a.evidence
                ]
              @
              match s.freshness with
              | Refresh_failed reason -> [ "Refresh error: " ^ reason ]
              | _ -> []))
;;

let analysis_row ?(decimal_places = 3) ~run ~selected summary =
  let analysis = Option.bind summary ~f:(fun s -> s.Asic.Summary.timing_analysis) in
  let status =
    match analysis with
    | Some { status = Completed; _ } -> Status.Completed
    | Some { status = Unavailable; _ } | None -> Status.Unknown
  in
  row
    ~status
    ~active:selected
    ~role:(status_role status)
    ~time:(Option.value_map analysis ~default:"unknown" ~f:analysis_duration)
    ~details:(analysis_details ~decimal_places ~run summary)
    "Timing"
    (match analysis with
     | Some { status = Unavailable; _ } -> "unavailable"
     | _ -> Status.label status)
;;

let checklist_row ?now ~run ~selected = function
  | Elaboration_preparation ->
    row
      ~status:Status.Unknown
      ~active:selected
      ~role:Muted
      ~details:
        [ "Elaboration linkage unavailable until the selected run's workflow is resolved"
        ; "r: stage fresh source inputs; Enter: read-only linked evidence"
        ]
      "Elaboration"
      "unavailable"
  | Physical_stage s -> asic_stage_row ?now ~run ~selected s
  | Timing_analysis summary ->
    let row = analysis_row ~run ~selected summary in
    { row with
      details =
        "Historical supplementary STA: no physical Timing occurrence in this record; r \
         checks current catalog for a NEW timing run"
        :: row.details
    }
;;

let workflow_for_run ~asic ~run =
  Option.bind asic ~f:(fun (s : Asic.Snapshot.t) ->
    List.find s.workflows ~f:(fun w -> Option.exists w.run ~f:(Run_ref.equal run)))
;;

let elaboration_row ~now ~selected workflow =
  match workflow with
  | None ->
    row
      ~status:Status.Unknown
      ~active:selected
      ~role:Muted
      ~details:
        [ "Elaboration linkage unavailable for this historical run; no project-latest \
           substitution"
        ]
      "Elaboration"
      "unavailable"
  | Some (w : Asic.Fresh.Workflow.t) ->
    let status : Status.t =
      match w.elaboration_status with
      | "building" | "emitting" -> Running
      | "completed" -> Completed
      | "build_failed" | "emission_failed" -> Failed
      | "cancelled" -> Cancelled
      | "interrupted" -> Unknown
      | _ -> Pending
    in
    let time =
      Option.value_map w.elaboration_started_at ~default:"unknown" ~f:(fun start ->
        let finish =
          match w.elaboration_finished_at with
          | Some finish -> Some (Timestamp.to_time_ns finish)
          | None
            when List.mem
                   [ "building"; "emitting" ]
                   w.elaboration_status
                   ~equal:String.equal -> Some now
          | None -> None
        in
        Option.value_map finish ~default:"unknown" ~f:(fun finish ->
          let seconds =
            Time_ns.Span.to_sec (Time_ns.diff finish (Timestamp.to_time_ns start))
          in
          let seconds = Float.max 0. seconds in
          if Float.(seconds < 60.)
          then Int.to_string (Float.to_int seconds) ^ "s"
          else
            Int.to_string (Float.to_int (seconds /. 60.))
            ^ "m "
            ^ Int.to_string (Float.to_int seconds mod 60)
            ^ "s"))
    in
    row
      ~status
      ~active:selected
      ~role:(status_role status)
      ~time
      ~details:
        ([ "Workflow: " ^ w.id
         ; "Submission key: " ^ w.key
         ; "Preparation: " ^ Option.value w.preparation_id ~default:"awaiting admission"
         ; "Source input intent: " ^ w.intent.id
         ; "Elaboration: " ^ w.elaboration_status
         ]
         @ Option.to_list w.error
         @ Option.value_map w.prepared ~default:[] ~f:(fun p ->
           [ "Bundle: " ^ p.bundle_identity
           ; "Output directory: " ^ p.bundle_directory
           ; "Exact plan identity: " ^ p.plan_identity
           ; "Methodology plan: " ^ p.methodology_plan_path
           ; "Plan digest: " ^ p.methodology_plan_digest
           ]))
      "Elaboration"
      w.elaboration_status
;;

(** Only shorten ASCII opaque identifiers. Human/provider labels remain intact and are
    clipped by display cells during rendering, never by UTF-8 byte offsets. *)
let short_id text = Presentation.identifier ~compress:true text

let run_label (run : Run_ref.t) =
  Option.filter run.label ~f:(fun label -> not (String.is_empty (String.strip label)))
  |> Option.value ~default:run.id
;;

(** Keep combining marks attached to their preceding scalar. All clipping budgets are
    terminal cells, and a suffix is contiguous (never skip a wide scalar to fill a gap). *)
let display_clusters text =
  let rec loop offset acc =
    if offset >= String.length text
    then List.rev acc
    else (
      let decoded = Stdlib.String.get_utf_8_uchar text offset in
      let length = Stdlib.Uchar.utf_decode_length decoded in
      let scalar = String.sub text ~pos:offset ~len:length in
      let acc =
        match acc with
        | previous :: rest
          when View.uchar_tty_width (Stdlib.Uchar.utf_decode_uchar decoded) = 0 ->
          (previous ^ scalar) :: rest
        | _ -> scalar :: acc
      in
      loop (offset + length) acc)
  in
  loop 0 []
;;

let cell_width text = View.width (View.text text)

let take_cells ~width clusters =
  let rec loop remaining = function
    | [] -> []
    | cluster :: rest ->
      let cells = cell_width cluster in
      if cells > remaining then [] else cluster :: loop (remaining - cells) rest
  in
  loop (Int.max 0 width) clusters
;;

let fit_run_label ~width (run : Run_ref.t) =
  let width = Int.max 0 width in
  let head = run_label run in
  let full = if String.equal head run.id then head else head ^ " · " ^ run.id in
  if cell_width full <= width
  then full
  else if width <= 2
  then String.concat (take_cells ~width (display_clusters head))
  else (
    let tail_budget = Int.min 8 (Int.max 1 (width - 2)) in
    let tail =
      display_clusters run.id
      |> List.rev
      |> take_cells ~width:tail_budget
      |> List.rev
      |> String.concat
    in
    let prefix =
      display_clusters head
      |> take_cells ~width:(width - cell_width tail - 1)
      |> String.concat
    in
    prefix ^ "…" ^ tail)
;;

(** Status vocabularies are field-specific. An unfamiliar value remains visible but
    neutral: e.g. operation completion cannot turn acceptance into a pass. These aggregate
    facts deliberately have no [Status.t] stage/checklist marker. *)
module Fact = struct
  type t =
    | Operation
    | Physical_completion
    | Verdict
    | Summary_completion

  let role field value : Role.t =
    match field, value with
    | Operation, "completed"
    | Physical_completion, "full"
    | Verdict, "pass"
    | Summary_completion, "completed" -> Success
    | Operation, "failed" | Physical_completion, "failed" | Verdict, "fail" -> Failure
    | Operation, ("running" | "starting") -> Running
    | Operation, ("interrupted" | "cancelled" | "queued")
    | Physical_completion, ("partial" | "incomplete")
    | Verdict, ("not_evaluated" | "not_requested" | "skipped") -> Warning
    | _ -> Muted
  ;;
end

let freshness_label : Asic.Summary.Freshness.t -> string * Role.t = function
  | Validated -> "validated", Success
  | Cached_unverified -> "cached/unverified", Warning
  | Missing_source -> "source unavailable", Warning
  | Refresh_failed _ -> "refresh failed", Warning
;;

let freshness_indicator : Asic.Summary.Freshness.t -> Indicator.t = function
  | Validated -> Completed
  | Cached_unverified -> Cached
  | Missing_source -> Unavailable
  | Refresh_failed _ -> Stale
;;

(** Compose only with a summary whose [run] matches the selected run; the caller already
    has that identity when loading host data. Cached facts retain their reported verdict,
    with freshness visible on every row and in inspection. No metrics, check counts, or
    summary completion are used to populate stages. *)
let summary_rows ?(freshness = true) (summary : Asic.Summary.t) =
  let show_freshness = freshness in
  let freshness, freshness_role = freshness_label summary.freshness in
  let details =
    [ "Run: " ^ run_identity summary.run; "Freshness: " ^ freshness ]
    @ Evidence_time_view.summary_lines summary.observed_at
    @ [ "Source digest: " ^ summary.source_digest
      ; "Execution file: " ^ summary.execution_file
      ; "Producer: " ^ summary.producer
      ]
    @
    match summary.freshness with
    | Refresh_failed reason -> [ "Refresh error: " ^ reason ]
    | Validated | Cached_unverified | Missing_source -> []
  in
  let fact ?(extra = []) field label value =
    let visible = if String.is_empty value then "not reported" else value in
    let visible =
      match summary.freshness with
      | Validated -> visible
      | Cached_unverified | Missing_source | Refresh_failed _ ->
        visible ^ " (" ^ freshness ^ ")"
    in
    row ~role:(Fact.role field value) ~details:(details @ extra) label visible
  in
  (if show_freshness || not (Asic.Summary.Freshness.equal summary.freshness Validated)
   then
     [ row
         ~indicator:(freshness_indicator summary.freshness)
         ~role:freshness_role
         ~details
         "Freshness"
         freshness
     ]
   else [])
  @
  match summary.terminal with
  | None ->
    [ fact Summary_completion "Outcome (agg.)" summary.completion
    ; fact Verdict "Accept (agg.)" summary.acceptance
    ; row ~role:Muted ~details "Terminal result" "not imported"
    ]
  | Some terminal ->
    let extra =
      [ "Finalization attempt: " ^ terminal.attempt
      ; "Results file: " ^ terminal.results_file
      ; "Results digest: " ^ terminal.results_digest
      ]
    in
    [ fact ~extra Operation "Operation (agg.)" terminal.operation_status
    ; fact ~extra Physical_completion "Physical (agg.)" terminal.physical_completion
    ; fact ~extra Verdict "Accept (agg.)" terminal.acceptance
    ; fact ~extra Verdict "Timing (agg.)" terminal.timing_goal
    ]
    @
    if List.is_empty terminal.checks
    then
      [ row ~role:Muted ~details:(details @ extra) "Checks (aggregate)" "not reported" ]
    else
      List.map terminal.checks ~f:(fun (check : Asic.Check.t) ->
        fact
          ~extra:
            (extra
             @ Option.to_list
                 (Option.map check.reason ~f:(fun reason -> "Reason: " ^ reason))
             @ Option.to_list
                 (Option.map check.source ~f:(fun source -> "Source: " ^ source)))
          Verdict
          ("Check " ^ check.name ^ " (aggregate)")
          check.status)
;;

(** [observation] must identify its run explicitly. [expected_stages] supplies labels
    only, not a claim that work was requested. Matching is exact; extra observed stages
    are preserved. Duplicate observations are ambiguous and never produce a pass. *)
let stage_rows ?(expected_stages = default_stages) ~selected_run ~asic ~observation () =
  let observed =
    match selected_run, observation with
    | Some selected, Some (run, stages) when Run_ref.equal selected run -> stages
    | _ -> []
  in
  (* Preserve the requested checklist order, followed by any provider-specific names. *)
  let names =
    List.stable_dedup
      (expected_stages @ List.map observed ~f:(fun (s : Stage.t) -> s.name))
      ~compare:String.compare
  in
  let missing_reason =
    match selected_run, observation with
    | None, _ -> "No run selected"
    | Some selected, Some (run, _) when not (Run_ref.equal selected run) ->
      "Stage observation belongs to another run"
    | Some _, _ -> "No explicit stage status reported"
  in
  let checklist =
    List.map names ~f:(fun name ->
      match List.filter observed ~f:(fun s -> String.equal s.name name) with
      | [ stage ] -> stage_row stage
      | stages ->
        row
          ~time:"unknown"
          ~role:Muted
          ~status:Unknown
          ~details:
            [ (if List.is_empty stages
               then missing_reason
               else "Conflicting/duplicate stage observations; inspect source")
            ]
          name
          (Status.label Unknown))
  in
  let process =
    match selected_run, asic with
    | Some run, Some (snapshot : Asic.Snapshot.t) ->
      (match List.find snapshot.runs ~f:(fun r -> Run_ref.equal r.run run) with
       | None -> [ row ~role:Muted "Observation" "selected run unavailable" ]
       | Some execution ->
         [ row
             ~role:Muted
             ~details:
               ([ "Run: " ^ run_identity run; "Process observation, not stage evidence" ]
                @ Option.to_list execution.error)
             "Process"
             (if String.is_empty execution.status
              then "not reported"
              else execution.status)
         ])
    | Some _, None -> [ row ~role:Muted "Observation" "ASIC not loaded" ]
    | None, _ -> [ row ~role:Muted "Run" "none selected" ]
  in
  checklist @ process
;;

(** Registry names are authoritative. Missing standard destinations are visible but have
    no [workspace] target; the parent can disable input or offer creation. *)
let navigation_rows ~(snapshot : Workspace.Snapshot.t) ~active_workspace =
  let existing =
    List.map snapshot.workspaces ~f:(fun w ->
      let active =
        Option.value_map
          active_workspace
          ~default:false
          ~f:(Workspace.Workspace_id.equal w.id)
      in
      row
        ~role:(if active then Active else Foreground)
        ~active
        ~workspace:w.id
        ~details:
          [ "Workspace: " ^ Workspace.Workspace_id.to_string w.id
          ; "Window: " ^ Workspace.Window_id.to_string w.window
          ; "Context: " ^ Workspace.Context_id.to_string w.context
          ]
        w.name
        (if active then "active" else ""))
  in
  existing
  @ List.filter_map [ "Overview"; "Testing"; "Waveforms"; "Timing" ] ~f:(fun name ->
    if List.exists snapshot.workspaces ~f:(fun w -> String.equal w.name name)
    then None
    else Some (row ~role:Muted name "not created"))
;;

(** Connection is verbatim: no green/connected inference from an arbitrary transport
    string. Project and run are explicit host inputs, never guessed from other runs. *)
let connection_role connection : Role.t =
  match String.lowercase (String.strip connection) with
  | "connected" -> Success
  | "disconnected" | "error" | "failed" -> Failure
  | "connecting" | "reconnecting" -> Warning
  | _ -> Muted
;;

let status_rows
  ~string_compression
  ~(snapshot : Workspace.Snapshot.t)
  ~active_workspace
  ~(project : Project.t option)
  ~(selected_run : Run_ref.t option)
  ~connection
  =
  let arrangement =
    Option.bind active_workspace ~f:(fun id ->
      List.find snapshot.workspaces ~f:(fun w -> Workspace.Workspace_id.equal w.id id))
  in
  let linkage =
    match arrangement with
    | None -> row ~indicator:Unavailable ~role:Muted "Context" "workspace unavailable"
    | Some w ->
      (match
         List.find snapshot.contexts ~f:(fun c ->
           Workspace.Context_id.equal c.id w.context)
       with
       | None -> row ~indicator:Unavailable ~role:Warning "Context" "unavailable"
       | Some context ->
         let shared =
           Workspace.Context_id.equal context.id snapshot.main_context
           || List.count snapshot.workspaces ~f:(fun other ->
                Workspace.Context_id.equal other.context context.id)
              > 1
         in
         (* One label colon only: the binding state is a lowercase keyword that leads the
            value, so it survives right-clipping before the context name does. *)
         let keyword = if shared then "linked" else "own" in
         row
           ~indicator:(if shared then Linked else Independent)
           ~emphasis:(if shared then String.length keyword else 0)
           ~details:
             [ "Context: " ^ Workspace.Context_id.to_string context.id
             ; "Workspace: " ^ Workspace.Workspace_id.to_string w.id
             ; sprintf "Selection revision: %d" context.selection_revision
             ]
           "Context"
           (keyword ^ (if shared then " to " else " ") ^ context.name))
  in
  [ row
      ~role:(connection_role connection)
      "Connection"
      (if String.is_empty connection then "not reported" else connection)
  ; row
      ~details:
        (Option.to_list
           (Option.map project ~f:(fun p -> "Project: " ^ Project_id.to_string p.id)))
      "Project"
      (Option.value_map project ~default:"none open" ~f:(fun p -> p.name))
  ; linkage
  ; row
      ~details:
        (Option.to_list
           (Option.map selected_run ~f:(fun run -> "Run: " ^ run_identity run)))
      "Run"
      (Option.value_map selected_run ~default:"none selected" ~f:(fun run ->
         let id = Presentation.identifier ~compress:string_compression run.id in
         match run.label with
         | Some label
           when (not (String.is_empty label)) && not (String.equal label run.id) ->
           label ^ " · " ^ id
         | _ -> id))
  ]
;;

let status_indicator : Status.t -> Indicator.t = function
  | Running -> Running
  | Pending -> Pending
  | Completed -> Completed
  | Failed -> Failed
  | Cancelled -> Cancelled
  | Skipped -> Skipped
  | Not_requested -> Not_requested
  | Unknown | Unsupported | Unrecognized _ -> Unknown
;;

let marker (appearance : Appearance.t) (row : row) =
  match Option.first_some (Option.map row.status ~f:status_indicator) row.indicator with
  | Some kind ->
    let glyph = Indicator.text appearance.icons kind in
    if String.is_empty glyph then "" else glyph ^ " "
  | None ->
    if row.active && not (Appearance.Icons.equal appearance.icons None_) then "> " else ""
;;

let row_prefix ~appearance ~indent row =
  indent
  ^ (if row.active && (Option.is_some row.status || Option.is_some row.indicator)
     then "> "
     else "")
  ^ marker appearance row
;;

(** Narrowest label kept when a checklist group shrinks to keep its status keywords whole:
    two label cells plus an ellipsis. *)
let min_label_cells = 3

let fit_cells ~width text =
  if cell_width text <= width
  then text
  else if width <= 0
  then ""
  else String.concat (take_cells ~width:(width - 1) (display_clusters text)) ^ "…"
;;

let aligned row = Option.is_some row.status && not (String.is_empty row.value)

(** The display cell where status keywords start for the visible checklist group (rows
    with a [status]). Prefixes are measured per row, so Off mode has no phantom icon cells
    and the selection marker never pushes its keyword out of the column. When the width is
    short, the column moves left (labels clip with an ellipsis) so the longest keyword
    stays whole; it never moves past [min_label_cells] of label. [None] when nothing needs
    aligning. *)
let status_column ~appearance ~width ~indent rows =
  match List.filter rows ~f:aligned with
  | [] -> None
  | group ->
    let max_of f = List.fold group ~init:0 ~f:(fun acc row -> Int.max acc (f row)) in
    let prefix row = cell_width (row_prefix ~appearance ~indent row) in
    let timed = List.exists group ~f:(fun r -> Option.is_some r.time) in
    let prefix_width =
      if timed
      then max_of (fun r -> cell_width (indent ^ marker appearance r) + 2)
      else max_of prefix
    in
    let natural =
      max_of (fun row ->
        (if timed then prefix_width else prefix row) + cell_width row.label + 2)
    in
    let floor = prefix_width + min_label_cells + 2 in
    let value_width = max_of (fun r -> cell_width r.value) in
    let time_width = max_of (fun r -> Option.value_map r.time ~default:0 ~f:cell_width) in
    let with_time = value_width + if time_width = 0 then 0 else 3 + time_width in
    let reserved = if floor + with_time <= width then with_time else value_width in
    Some (Int.min natural (Int.max floor (width - reserved)))
;;

(** Map roles to the host's theme, e.g. [Active -> Host_view.Role.Selection]. Full values
    and identity are available through [inspection_lines] before clipping. [title=None]
    makes a headerless tile. [status_column] pads the label so the value starts at that
    display cell. No nested frame or background is imposed. *)
let row_spans
  ?status_column
  ?(status_width = 0)
  ?(time_width = 0)
  ~appearance
  ~width
  ~indent
  row
  =
  let prefix = row_prefix ~appearance ~indent row in
  let label =
    match status_column with
    | Some column when aligned row ->
      let budget = column - cell_width prefix - 2 in
      let label = fit_cells ~width:budget row.label in
      label ^ ": " ^ String.make (Int.max 0 (budget - cell_width label)) ' '
    | _ ->
      row.label
      ^ if String.is_empty row.value || String.is_empty row.label then "" else ": "
  in
  let value =
    Option.value_map row.display_run ~default:row.value ~f:(fun run ->
      fit_run_label ~width:(Int.max 0 (width - cell_width (prefix ^ label))) run)
  in
  let time =
    Option.value_map row.time ~default:"" ~f:(fun time ->
      let room = width - cell_width (prefix ^ label ^ value) in
      if time_width > 0
      then
        String.make (Int.max 0 (status_width - cell_width value)) ' '
        ^ " | "
        ^ String.make (Int.max 0 (time_width - cell_width time)) ' '
        ^ time
      else if Option.is_none status_column && room >= cell_width time + 3
      then " | " ^ time
      else "")
  in
  let value =
    let emphasis = Int.clamp_exn row.emphasis ~min:0 ~max:(String.length value) in
    if emphasis = 0 || Option.is_some row.display_run
    then [ row.role, value ]
    else
      [ Role.Linked, String.prefix value emphasis
      ; row.role, String.drop_prefix value emphasis
      ]
  in
  [ (if row.active then Role.Active else row.role), prefix; Role.Foreground, label ]
  @ value
  @ [ Role.Muted, time ]
;;

let render_row
  ?indicator_frames
  ?indicator_fg
  ?selected_bg
  ?status_column
  ?status_width
  ?time_width
  ~appearance
  ~attrs
  ~width
  ~indent
  row
  =
  let spans =
    row_spans ?status_column ?status_width ?time_width ~appearance ~width ~indent row
  in
  View.hcat
    (List.mapi spans ~f:(fun i (role, text) ->
       let attrs =
         attrs role
         @ Option.value_map selected_bg ~default:[] ~f:(fun bg ->
           if row.active then [ Attr.bg bg ] else [])
       in
       if i = 0
          && Option.equal Status.equal row.status (Some Running)
          && Option.is_some indicator_frames
          && not (Appearance.Icons.equal appearance.icons None_)
       then (
         let prefix = indent ^ if row.active then "> " else "" in
         let glyph = Indicator.view ?frames:indicator_frames appearance.icons Running in
         let glyph =
           View.crop
             ~r:(Int.max 0 (View.width glyph - 1))
             ~b:(Int.max 0 (View.height glyph - 1))
             glyph
           |> fun glyph -> View.zcat [ glyph; View.rectangle ~width:1 ~height:1 () ]
         in
         View.hcat
           [ View.text ~attrs prefix
           ; View.hcat
               [ glyph
               ; View.text (if String.is_empty (marker appearance row) then "" else " ")
               ]
             |> View.with_colors'
                  ?fg:indicator_fg
                  ?bg:(if row.active then selected_bg else None)
           ])
       else View.text ~attrs text))
;;

let render
  (* Supply the full filtered group when [rows] has already been scrolled. Column budgets
     are computed before the viewport height is applied. *)
  ?candidate_rows
  ?indicator_frames
  ?indicator_fg
  ?title
  ?selected_bg
  ~(appearance : Appearance.t)
  ~attrs
  ~width
  ~height
  rows
  =
  let width = Int.max 0 width
  and height = Int.max 0 height in
  let heading =
    Option.to_list
      (Option.map title ~f:(fun title ->
         let title =
           match appearance.preset with
           | Instrument -> String.uppercase title
           | Structured | Minimal | Studio | Structured_studio -> title
         in
         View.text ~attrs:(attrs Role.Heading) title))
  in
  let indent =
    match appearance.density with
    | Comfortable when width >= 30 -> " "
    | Compact | Comfortable -> ""
  in
  let candidates = Option.value candidate_rows ~default:rows in
  let status_column = status_column ~appearance ~width ~indent candidates in
  let group = List.filter candidates ~f:aligned in
  let status_width =
    List.fold group ~init:0 ~f:(fun n r -> Int.max n (cell_width r.value))
  in
  let time_width =
    List.fold group ~init:0 ~f:(fun n r ->
      Int.max n (Option.value_map r.time ~default:0 ~f:cell_width))
  in
  let time_width =
    if Option.value status_column ~default:width + status_width + 3 + time_width <= width
    then time_width
    else 0
  in
  let rows = List.take rows (Int.max 0 (height - List.length heading)) in
  let content =
    List.map
      rows
      ~f:
        (render_row
           ?indicator_frames
           ?indicator_fg
           ?selected_bg
           ?status_column
           ~status_width
           ~time_width
           ~appearance
           ~attrs
           ~width
           ~indent)
  in
  let view = View.vcat (heading @ content) in
  let view =
    View.crop
      ~r:(Int.max 0 (View.width view - width))
      ~b:(Int.max 0 (View.height view - height))
      view
  in
  View.zcat [ view; View.rectangle ~width ~height () ]
;;

let render_checklist_strip
  ?indicator_frames
  ?indicator_fg
  ?selected_bg
  ~appearance
  ~attrs
  ~width
  ~height
  rows
  =
  let rows = List.filter rows ~f:(fun row -> Option.is_some row.status) in
  let packed, current, _, active =
    List.fold rows ~init:([], [], 0, false) ~f:(fun (packed, current, used, active) row ->
      let natural =
        cell_width (row_prefix ~appearance ~indent:"" row ^ row.label ^ ": " ^ row.value)
        + Option.value_map row.time ~default:0 ~f:(fun time -> 3 + cell_width time)
      in
      let cells = Int.min (Int.max 0 width) natural in
      let item =
        render_row
          ?indicator_frames
          ?indicator_fg
          ?selected_bg
          ~appearance
          ~attrs
          ~width:cells
          ~indent:""
          row
      in
      if used > 0 && used + 3 + cells > width
      then (View.hcat (List.rev current), active) :: packed, [ item ], cells, row.active
      else
        ( packed
        , item :: (if used = 0 then current else View.text " · " :: current)
        , used + (if used = 0 then 0 else 3) + cells
        , active || row.active ))
  in
  let lines = List.rev ((View.hcat (List.rev current), active) :: packed) in
  let selected =
    List.findi lines ~f:(fun _ (_, active) -> active)
    |> Option.value_map ~default:0 ~f:fst
  in
  let start = Int.max 0 (selected - Int.max 1 height + 1) in
  List.drop lines start
  |> Fn.flip List.take (Int.max 0 height)
  |> List.map ~f:fst
  |> View.vcat
;;

let inspection_lines rows =
  List.concat_map rows ~f:(fun row ->
    (row.label ^ if String.is_empty row.value then "" else ": " ^ row.value)
    :: (List.map (Option.to_list row.time) ~f:(fun time -> "Time: " ^ time) @ row.details))
;;

let%test_unit "native stage frames change only running markers, with fixed cell budgets" =
  let image view =
    let buffer = Buffer.create 100 in
    Notty.Render.to_buffer
      buffer
      Notty.Cap.dumb
      (0, 0)
      (View.width view, View.height view)
      (View.Private.notty_image view);
    Buffer.contents buffer
  in
  let frames glyph : Indicator.frames =
    { dot = View.text glyph; line = View.text glyph }
  in
  List.iter Appearance.Icons.all ~f:(fun icons ->
    let appearance = { Appearance.default with icons; density = Compact } in
    List.iter
      [ Status.Running
      ; Pending
      ; Completed
      ; Failed
      ; Cancelled
      ; Skipped
      ; Not_requested
      ; Unknown
      ; Unsupported
      ; Unrecognized "running passed"
      ]
      ~f:(fun status ->
        let rows =
          [ row
              ~role:(status_role status)
              ~status
              ~active:true
              "界é stage"
              (Status.label status)
          ]
        in
        let render ?indicator_frames width height =
          render ?indicator_frames ~appearance ~attrs:(fun _ -> []) ~width ~height rows
        in
        List.iter
          [ 0, 0; 1, 1; 8, 2; 40, 2 ]
          ~f:(fun (width, height) ->
            let a = render ~indicator_frames:(frames "A") width height in
            let b = render ~indicator_frames:(frames "B") width height in
            assert (View.width a = width && View.height a = height);
            assert (View.width b = width && View.height b = height));
        let a = render ~indicator_frames:(frames "A") 60 1 |> image in
        let b = render ~indicator_frames:(frames "B") 60 1 |> image in
        let animated =
          Status.equal status Running && not (Appearance.Icons.equal icons None_)
        in
        assert (Bool.equal (not (String.equal a b)) animated);
        assert (String.is_substring a ~substring:("界é stage: " ^ Status.label status));
        assert (String.equal (render 60 1 |> image) (render 60 1 |> image));
        assert (
          String.equal
            (List.hd_exn (inspection_lines rows))
            ("界é stage: " ^ Status.label status))))
;;

(** Horizontal presentation preserves the original stage record and provider order.
    Display labels are never identities. Actions are carried verbatim, never executed. *)
module Stage_strip = struct
  type item =
    { stage : Asic.Stage.t
    ; row : row
    }

  type t =
    { lines : item list list
    ; selected : item option
    ; selected_line : row
    }

  let text ~appearance item =
    (if item.row.active then "> " else "")
    ^ marker appearance item.row
    ^ item.row.label
    ^ ": "
    ^ item.row.value
    ^ Option.value_map item.row.time ~default:"" ~f:(fun time -> " | " ^ time)
  ;;

  let model ?(now = Time_ns.now ()) ~appearance ~width ~run ~selected_id stages =
    let items =
      List.map stages ~f:(fun (stage : Asic.Stage.t) ->
        { stage
        ; row =
            asic_stage_row
              ~now
              ~run
              ~selected:(Option.equal String.equal selected_id (Some stage.id))
              stage
        })
    in
    let show_time =
      List.for_all items ~f:(fun item ->
        let r = item.row in
        cell_width (row_prefix ~appearance ~indent:"" r)
        + min_label_cells
        + 2
        + cell_width r.value
        + Option.value_map r.time ~default:0 ~f:(fun time -> 3 + cell_width time)
        <= width)
    in
    let items =
      List.map items ~f:(fun item ->
        let r = item.row in
        let time = if show_time then r.time else None in
        let label_width =
          width
          - cell_width (row_prefix ~appearance ~indent:"" r)
          - 2
          - cell_width r.value
          - Option.value_map time ~default:0 ~f:(fun time -> 3 + cell_width time)
        in
        { item with row = { r with label = fit_cells ~width:label_width r.label; time } })
    in
    let lines, line, _ =
      List.fold items ~init:([], [], 0) ~f:(fun (lines, line, used) item ->
        let cells = View.width (View.text (text ~appearance item)) in
        let gap = if List.is_empty line then 0 else 3 in
        if (not (List.is_empty line)) && used + gap + cells > Int.max 1 width
        then lines @ [ line ], [ item ], cells
        else lines, line @ [ item ], used + gap + cells)
    in
    let lines = lines @ if List.is_empty line then [] else [ line ] in
    let selected = List.find items ~f:(fun item -> item.row.active) in
    let selected_line =
      match selected with
      | None -> row ~role:Muted "Selected stage" "not available"
      | Some item ->
        { item.row with
          label = "Selected: " ^ item.stage.name ^ " [" ^ item.stage.id ^ "]"
        ; details = item.row.details
        }
    in
    { lines; selected; selected_line }
  ;;

  let render
    ?indicator_frames
    ?indicator_fg
    ?selected_bg
    ~appearance
    ~attrs
    ~width
    ~height
    t
    =
    let width = Int.max 0 width
    and height = Int.max 0 height in
    let selected =
      render
        ?indicator_frames
        ?indicator_fg
        ?selected_bg
        ~appearance
        ~attrs
        ~width
        ~height:(Int.min 1 height)
        [ t.selected_line ]
    in
    let lines =
      List.take t.lines (Int.max 0 (height - 1))
      |> List.map ~f:(fun line ->
        View.hcat
          (List.concat_mapi line ~f:(fun i item ->
             (if i = 0 then [] else [ View.text ~attrs:(attrs Role.Muted) " | " ])
             @ [ render_row
                   ?indicator_frames
                   ?indicator_fg
                   ?selected_bg
                   ~appearance
                   ~attrs
                   ~width
                   ~indent:""
                   item.row
               ])))
    in
    (* Selection stays visible even when wrapping exceeds the available strip height. *)
    let view = View.vcat (lines @ if height = 0 then [] else [ selected ]) in
    let view =
      View.crop
        ~r:(Int.max 0 (View.width view - width))
        ~b:(Int.max 0 (View.height view - height))
        view
    in
    View.zcat [ view; View.rectangle ~width ~height () ]
  ;;
end

let%test_unit "horizontal stages wrap long duplicate labels without changing \
               identity/actions"
  =
  let action : Asic.Selection.t =
    { flow = "flow"
    ; profile = "profile"
    ; endpoint = "exact-endpoint"
    ; assignments = [ "X=1" ]
    }
  in
  let stages =
    List.init 6 ~f:(fun i ->
      { Asic.Stage.id = Int.to_string i
      ; name = String.make 80 'a'
      ; status = Completed
      ; requested = false
      ; reason = None
      ; action = Some action
      ; execution_timing = None
      })
  in
  let appearance = Appearance.default in
  let t =
    Stage_strip.model
      ~appearance
      ~width:80
      ~run:Fs0_fixture.run_a
      ~selected_id:(Some "4")
      stages
  in
  assert (List.length t.lines = 6);
  assert (Asic.Stage.equal (Option.value_exn t.selected).stage (List.nth_exn stages 4));
  assert (
    List.equal
      Asic.Stage.equal
      (List.concat t.lines |> List.map ~f:(fun item -> item.Stage_strip.stage))
      stages);
  List.iter
    [ 0, 0; 20, 2; 80, 4; 120, 5; 240, 8 ]
    ~f:(fun (width, height) ->
      let view = Stage_strip.render ~appearance ~attrs:(fun _ -> []) ~width ~height t in
      assert (View.width view = width && View.height view = height))
;;

let%test_unit "stage outcomes preserve request and observation distinctions" =
  let check requested status expect =
    [%test_result: Status.t] (stage_status { name = "stage"; requested; status }) ~expect
  in
  check false Not_run Not_requested;
  check true Not_run Pending;
  check false Completed Completed;
  check true Running Running;
  check true (Failed { reason = "tool error" }) Failed;
  check false (Skipped { reason = "unsupported" }) Skipped
;;

let%test_unit "ASIC stage projection preserves every explicit status and full action" =
  let run = Fs0_fixture.run_a in
  let action : Asic.Selection.t =
    { flow = "ordinary"
    ; profile = "default"
    ; endpoint = "route"
    ; assignments = [ "X=1" ]
    }
  in
  let cases : (Asic.Stage.Status.t * string * Role.t) list =
    [ Pending, "pending", Warning
    ; Running, "running", Running
    ; Completed, "completed", Success
    ; Failed, "failed", Failure
    ; Cancelled, "cancelled", Warning
    ; Skipped, "skipped", Warning
    ; Not_requested, "not requested", Muted
    ; Unsupported, "unsupported", Muted
    ; Unknown "provider-future", "unknown: provider-future", Muted
    ]
  in
  List.iter cases ~f:(fun (status, value, role) ->
    let stage : Asic.Stage.t =
      { id = "route-id"
      ; name = "Routing"
      ; status
      ; requested = false
      ; reason = Some "exact provider reason"
      ; action = Some action
      ; execution_timing = None
      }
    in
    let row = asic_stage_row ~run ~selected:true stage in
    [%test_result: string] row.value ~expect:value;
    [%test_result: Role.t] row.role ~expect:role;
    assert row.active;
    let detail = inspection_lines [ row ] |> String.concat ~sep:"\n" in
    List.iter
      [ "Stage ID: route-id"
      ; "Requested: false"
      ; "exact provider reason"
      ; "asic/fixture-A"
      ]
      ~f:(fun text -> assert (String.is_substring detail ~substring:text));
    match status with
    | Unsupported -> assert (String.is_substring detail ~substring:"unavailable")
    | _ ->
      assert (String.is_substring detail ~substring:"NEW run");
      assert (String.is_substring detail ~substring:"X=1"))
;;

let%test_unit "aggregate colors require field-specific explicit facts" =
  let check field value expect = [%test_result: Role.t] (Fact.role field value) ~expect in
  check Operation "completed" Success;
  check Verdict "completed" Muted;
  check Physical_completion "completed" Muted;
  check Physical_completion "full" Success;
  check Physical_completion "incomplete" Warning;
  check Verdict "pass" Success;
  check Verdict "fail" Failure;
  check Verdict "not_evaluated" Warning;
  check Verdict "unknown" Muted;
  check Verdict "future-provider-verdict" Muted;
  check Verdict "" Muted;
  [%test_result: string] (short_id "0123456789abcdefghijkl") ~expect:"0123…ijkl"
;;

let%test_unit "cached summary facts retain freshness and do not acquire stage statuses" =
  let summary : Asic.Summary.t =
    { run =
        { backend = Backend_id.of_string "asic"
        ; id = "saved-run"
        ; build = None
        ; label = None
        }
    ; source_digest = "digest"
    ; execution_file = "/saved/execution.json"
    ; plan_identity = None
    ; cell_count = Some 100
    ; cells = []
    ; metrics = []
    ; terminal = None
    ; timing_analysis = None
    ; timing = []
    ; completion = "completed"
    ; acceptance = "unknown"
    ; producer = "saved producer"
    ; observed_at = "saved observation"
    ; freshness = Cached_unverified
    }
  in
  let rows = summary_rows summary in
  assert (List.length (summary_rows ~freshness:false summary) = List.length rows);
  let validated = { summary with freshness = Validated } in
  assert (
    List.length (summary_rows ~freshness:false validated)
    = List.length (summary_rows validated) - 1);
  let completion = List.nth_exn rows 1 in
  [%test_result: Role.t] completion.role ~expect:Success;
  [%test_result: string] completion.value ~expect:"completed (cached/unverified)";
  assert (List.for_all rows ~f:(fun row -> Option.is_none row.status));
  assert (List.mem completion.details "Run: asic/saved-run" ~equal:String.equal);
  let failed = summary_rows { summary with freshness = Refresh_failed "offline" } in
  assert (
    List.mem (List.hd_exn failed).details "Refresh error: offline" ~equal:String.equal);
  let terminal : Asic.Terminal_result.t =
    { attempt = "attempt"
    ; results_file = "/saved/results.json"
    ; results_digest = "results-digest"
    ; operation_status = "completed"
    ; physical_completion = "incomplete"
    ; acceptance = "not_evaluated"
    ; timing_goal = "unknown"
    ; metrics = []
    ; checks =
        [ { name = "drc"
          ; status = "fail"
          ; reason = Some "violations"
          ; source = Some "report"
          }
        ]
    ; evidence = "{}"
    ; execution_timing = None
    }
  in
  let terminal_rows = summary_rows { summary with terminal = Some terminal } in
  let find label =
    List.find_exn terminal_rows ~f:(fun row -> String.equal row.label label)
  in
  [%test_result: Role.t] (find "Operation (agg.)").role ~expect:Success;
  [%test_result: Role.t] (find "Physical (agg.)").role ~expect:Warning;
  [%test_result: Role.t] (find "Accept (agg.)").role ~expect:Warning;
  [%test_result: Role.t] (find "Timing (agg.)").role ~expect:Muted;
  let drc = find "Check drc (aggregate)" in
  [%test_result: Role.t] drc.role ~expect:Failure;
  assert (List.mem drc.details "Reason: violations" ~equal:String.equal);
  assert (List.mem drc.details "Source: report" ~equal:String.equal);
  assert (List.for_all terminal_rows ~f:(fun row -> Option.is_none row.status))
;;

let%test_unit "process completion is not stage evidence; mismatched and duplicate \
               observations are unknown"
  =
  let run id : Run_ref.t =
    { backend = Backend_id.of_string "asic"; id; build = None; label = None }
  in
  let selected = run "selected" in
  let stage : Stage.t = { name = "Synthesis"; requested = true; status = Completed } in
  let asic : Asic.Snapshot.t =
    { configured = true
    ; flows = []
    ; catalog_default = None
    ; description_json = None
    ; preview = None
    ; runs =
        [ { run = selected
          ; reference = { attempt = "attempt"; stream_id = "stream" }
          ; selection = None
          ; stages = []
          ; execution_timing = None
          ; cursor = 0
          ; status = "completed"
          ; execution_file = None
          ; error = None
          }
        ]
    ; operations = []
    ; launches = []
    ; fresh_intent = None
    ; workflows = []
    ; resources = None
    ; workloads = None
    ; summaries = []
    ; finalizations = []
    ; artifacts = []
    ; artifact_pages = []
    ; artifact_byte_pages = []
    ; inspections = []
    ; inspection_details = []
    ; cache_error = None
    }
  in
  let check observation expect =
    let rows =
      stage_rows
        ~expected_stages:[ "Synthesis" ]
        ~selected_run:(Some selected)
        ~asic:(Some asic)
        ~observation
        ()
    in
    [%test_result: Status.t option] (List.hd_exn rows).status ~expect:(Some expect)
  in
  check None Unknown;
  check (Some (run "other", [ stage ])) Unknown;
  check (Some (selected, [ stage; stage ])) Unknown;
  check (Some (selected, [ stage ])) Completed
;;

let%test_unit "navigation retains registry identities and missing destinations are not \
               actionable"
  =
  let snapshot =
    Workspace.initial ~session_id:(Workspace.Session_id.of_string "session")
  in
  let active = (List.hd_exn snapshot.workspaces).id in
  let rows = navigation_rows ~snapshot ~active_workspace:(Some active) in
  let overview = List.find_exn rows ~f:(fun row -> String.equal row.label "Overview") in
  assert overview.active;
  assert (Option.equal Workspace.Workspace_id.equal overview.workspace (Some active));
  let testing = List.find_exn rows ~f:(fun row -> String.equal row.label "Testing") in
  assert (Option.is_none testing.workspace);
  assert (not testing.active);
  [%test_result: string] testing.value ~expect:"not created"
;;

let%test_unit "Session labels use actual cells and retain distinguishable hash suffixes" =
  let run =
    { Fs0_fixture.run_a with
      label = Some "Placement customer design"
    ; id = "opaque0123456789abcdef0123456789abcdef"
    }
  in
  assert (
    String.equal (fit_run_label ~width:100 run) ("Placement customer design · " ^ run.id));
  let short = fit_run_label ~width:26 run in
  assert (String.is_prefix short ~prefix:"Placement");
  assert (String.is_suffix short ~suffix:"…89abcdef");
  assert (cell_width short <= 26);
  let other = { run with id = "opaque0123456789abcdef0123456789abcdea" } in
  assert (not (String.equal short (fit_run_label ~width:26 other)));
  List.iter [ ""; "   " ] ~f:(fun label ->
    let unlabeled = { run with label = Some label } in
    assert (String.is_prefix (fit_run_label ~width:26 unlabeled) ~prefix:"opaque");
    assert (String.equal (fit_run_label ~width:100 unlabeled) run.id);
    assert (Option.equal String.equal unlabeled.label (Some label)));
  List.iter
    [ run
    ; { run with label = None }
    ; { run with label = Some "界é customer"; id = "識別界éabcdef界é" }
    ]
    ~f:(fun run ->
      List.iter (List.init 100 ~f:Fn.id) ~f:(fun width ->
        let label = fit_run_label ~width run in
        assert (Stdlib.String.is_valid_utf_8 label);
        assert (cell_width label <= width)));
  let rows =
    [ row ~display_run:run ~details:[ "Run: " ^ run_identity run ] "Run" (run_label run) ]
  in
  let spans =
    row_spans ~appearance:Appearance.default ~width:32 ~indent:" " (List.hd_exn rows)
  in
  assert (cell_width (String.concat (List.map spans ~f:snd)) <= 32);
  assert (
    List.mem (inspection_lines rows) ("Run: " ^ run_identity run) ~equal:String.equal)
;;

let plain_lines view =
  let buffer = Buffer.create 256 in
  Notty.Render.to_buffer
    buffer
    Notty.Cap.dumb
    (0, 0)
    (View.width view, View.height view)
    (View.Private.notty_image view);
  Buffer.contents buffer
  |> String.split_lines
  |> List.map ~f:(fun line -> String.rstrip line)
;;

let%test_unit "summary freshness markers are typed, static and never stage verdicts" =
  let summary = List.hd_exn Fs0_fixture.snapshot.summaries in
  List.iter
    [ Asic.Summary.Freshness.Validated, Indicator.Completed, "validated"
    ; Cached_unverified, Cached, "cached/unverified"
    ; Missing_source, Unavailable, "source unavailable"
    ; Refresh_failed "offline", Stale, "refresh failed"
    ]
    ~f:(fun (freshness, kind, label) ->
      let rows = summary_rows { summary with freshness } in
      let freshness_row = List.hd_exn rows in
      let facts = List.tl_exn rows in
      assert (List.for_all rows ~f:(fun r -> Option.is_none r.status));
      assert (List.for_all facts ~f:(fun r -> Option.is_none r.indicator));
      let inspection = inspection_lines rows in
      [%test_result: string] (List.hd_exn inspection) ~expect:("Freshness: " ^ label);
      (match freshness with
       | Refresh_failed reason ->
         assert (List.mem inspection ("Refresh error: " ^ reason) ~equal:String.equal)
       | Validated | Cached_unverified | Missing_source -> ());
      List.iter Appearance.Icons.all ~f:(fun icons ->
        let appearance = { Appearance.default with icons; density = Compact } in
        let glyph = Indicator.text icons kind in
        let prefix = if String.is_empty glyph then "" else glyph ^ " " in
        let text =
          row_spans ~appearance ~width:80 ~indent:"" freshness_row
          |> List.map ~f:snd
          |> String.concat
        in
        [%test_result: string] text ~expect:(prefix ^ "Freshness: " ^ label);
        let render_frame frame width height =
          let indicator_frames : Indicator.frames =
            { dot = View.text frame; line = View.text frame }
          in
          render ~indicator_frames ~appearance ~attrs:(fun _ -> []) ~width ~height rows
        in
        List.iter
          [ 0, 0; 1, 1; 24, 3; 80, 8 ]
          ~f:(fun (width, height) ->
            let a = render_frame "A" width height in
            let b = render_frame "B" width height in
            assert (View.width a = width && View.height a = height);
            assert (List.equal String.equal (plain_lines a) (plain_lines b)))));
  (* A lifecycle status owns the single marker even if semantic metadata is present. *)
  let both = row ~status:Running ~indicator:Cached "Updating" "" in
  List.iter Appearance.Icons.all ~f:(fun icons ->
    let appearance = { Appearance.default with icons } in
    let glyph = Indicator.text icons Running in
    [%test_result: string]
      (marker appearance both)
      ~expect:(if String.is_empty glyph then "" else glyph ^ " "))
;;

let%test_unit "missing session contexts use unavailable without inventing linkage" =
  let snapshot = Workspace.initial ~session_id:(Workspace.Session_id.of_string "s") in
  let active = (List.hd_exn snapshot.workspaces).id in
  List.iter
    [ snapshot, None, "workspace unavailable"
    ; { snapshot with contexts = [] }, Some active, "unavailable"
    ]
    ~f:(fun (snapshot, active_workspace, value) ->
      let rows =
        status_rows
          ~string_compression:true
          ~snapshot
          ~active_workspace
          ~project:None
          ~selected_run:None
          ~connection:"local"
      in
      let context = List.nth_exn rows 2 in
      [%test_result: string] context.value ~expect:value;
      assert (Option.is_none context.status);
      assert (context.emphasis = 0);
      List.iter Appearance.Icons.all ~f:(fun icons ->
        let glyph = Indicator.text icons Unavailable in
        [%test_result: string]
          (marker { Appearance.default with icons } context)
          ~expect:(if String.is_empty glyph then "" else glyph ^ " ")))
;;

let%test_unit "duration is additional to aligned checklist status and clips within \
               narrow cells"
  =
  let rows =
    [ row ~status:Completed ~time:"2m 07s" "Synthesis" "completed"
    ; row ~status:Running ~time:"14s" "Placement" "running"
    ]
  in
  List.iter Appearance.Icons.all ~f:(fun icons ->
    let appearance = { Appearance.default with icons; density = Compact } in
    List.iter [ 0; 1; 8; 22; 40; 60 ] ~f:(fun width ->
      let view = render ~appearance ~attrs:(fun _ -> []) ~width ~height:2 rows in
      assert (View.width view = width && View.height view = 2);
      if width >= 40
      then (
        let text = plain_lines view |> String.concat ~sep:"\n" in
        assert (String.is_substring text ~substring:"2m 07s");
        assert (String.is_substring text ~substring:"14s");
        let column = status_column ~appearance ~width ~indent:"" rows in
        let starts =
          List.map rows ~f:(fun row ->
            row_spans ?status_column:column ~appearance ~width ~indent:"" row
            |> Fn.flip List.take 2
            |> List.map ~f:snd
            |> String.concat
            |> cell_width)
        in
        assert (Int.equal (List.hd_exn starts) (List.last_exn starts)))))
;;

let%expect_test "checklist status keywords share a display-width column" =
  let stage ?(active = false) label status =
    row ~role:(status_role status) ~status ~active label (Status.label status)
  in
  let rows =
    [ stage "Synthesis" Completed
    ; stage ~active:true "Placement" Running
    ; stage "CTS" Pending
    ; stage "界é stage" Skipped
    ; stage "Global routing" Not_requested
    ; row ~role:Muted "Accept (agg.)" "pass"
    ]
  in
  List.iter Appearance.Icons.all ~f:(fun icons ->
    let appearance = { Appearance.default with icons; density = Compact } in
    List.iter [ 40; 30; 22; 12 ] ~f:(fun width ->
      printf "-- %s width %d\n" (Sexp.to_string (Appearance.Icons.sexp_of_t icons)) width;
      render ~appearance ~attrs:(fun _ -> []) ~width ~height:(List.length rows) rows
      |> plain_lines
      |> List.iter ~f:print_endline));
  (* Above the minimum useful width every keyword starts in one cell and stays whole. *)
  List.iter Appearance.Icons.all ~f:(fun icons ->
    let appearance = { Appearance.default with icons; density = Compact } in
    List.iter
      (List.init 40 ~f:(fun i -> i + 22))
      ~f:(fun width ->
        let starts =
          List.filter rows ~f:aligned
          |> List.map ~f:(fun row ->
            let spans =
              row_spans
                ?status_column:(status_column ~appearance ~width ~indent:"" rows)
                ~appearance
                ~width
                ~indent:""
                row
            in
            assert (cell_width (String.concat (List.map spans ~f:snd)) <= width);
            cell_width (String.concat (List.map (List.take spans 2) ~f:snd)))
        in
        assert (List.for_all starts ~f:(Int.equal (List.hd_exn starts)))));
  [%expect
    {|
    -- None_ width 40
    Synthesis:      completed
    > Placement:    running
    CTS:            pending
    界é stage:      skipped
    Global routing: not requested
    Accept (agg.): pass
    -- None_ width 30
    Synthesis:      completed
    > Placement:    running
    CTS:            pending
    界é stage:      skipped
    Global routing: not requested
    Accept (agg.): pass
    -- None_ width 22
    Synthe…: completed
    > Plac…: running
    CTS:     pending
    界é st…: skipped
    Global…: not requested
    Accept (agg.): pass
    -- None_ width 12
    Synt…: compl
    > Pl…: runni
    CTS:   pendi
    界é …: skipp
    Glob…: not r
    Accept (agg.
    -- Ascii width 40
    + Synthesis:      completed
    > | Placement:    running
    : CTS:            pending
    - 界é stage:      skipped
    . Global routing: not requested
    Accept (agg.): pass
    -- Ascii width 30
    + Synthesis:     completed
    > | Placement:   running
    : CTS:           pending
    - 界é stage:     skipped
    . Global routi…: not requested
    Accept (agg.): pass
    -- Ascii width 22
    + Synt…: completed
    > | Pl…: running
    : CTS:   pending
    - 界é …: skipped
    . Glob…: not requested
    Accept (agg.): pass
    -- Ascii width 12
    + Synt…: com
    > | Pl…: run
    : CTS:   pen
    - 界é …: ski
    . Glob…: not
    Accept (agg.
    -- Unicode width 40
    ✓ Synthesis:      completed
    > ⣷ Placement:    running
    ◷ CTS:            pending
    ↷ 界é stage:      skipped
    · Global routing: not requested
    Accept (agg.): pass
    -- Unicode width 30
    ✓ Synthesis:     completed
    > ⣷ Placement:   running
    ◷ CTS:           pending
    ↷ 界é stage:     skipped
    · Global routi…: not requested
    Accept (agg.): pass
    -- Unicode width 22
    ✓ Synt…: completed
    > ⣷ Pl…: running
    ◷ CTS:   pending
    ↷ 界é …: skipped
    · Glob…: not requested
    Accept (agg.): pass
    -- Unicode width 12
    ✓ Synt…: com
    > ⣷ Pl…: run
    ◷ CTS:   pen
    ↷ 界é …: ski
    · Glob…: not
    Accept (agg.
    |}]
;;

let%expect_test "context linkage avoids nested colons and keeps names visible" =
  let snapshot = Workspace.initial ~session_id:(Workspace.Session_id.of_string "s") in
  let overview = (List.hd_exn snapshot.workspaces).id in
  let independent = Workspace.apply_mutation snapshot (Make_independent overview) in
  List.iter [ snapshot; independent ] ~f:(fun snapshot ->
    let rows =
      status_rows
        ~string_compression:true
        ~snapshot
        ~active_workspace:(Some overview)
        ~project:None
        ~selected_run:None
        ~connection:"local"
    in
    let linkage = List.nth_exn rows 2 in
    (* Exactly one label colon; only the linked keyword carries emphasis. *)
    assert (
      String.count (List.hd_exn (inspection_lines [ linkage ])) ~f:(Char.equal ':') = 1);
    let emphasized =
      row_spans ~appearance:Appearance.default ~width:40 ~indent:"" linkage
      |> List.filter_map ~f:(fun (role, text) ->
        Option.some_if (Role.equal role Linked) text)
    in
    assert (
      List.equal
        String.equal
        emphasized
        (if String.is_prefix linkage.value ~prefix:"linked" then [ "linked" ] else []));
    List.iter Appearance.Icons.all ~f:(fun icons ->
      let appearance = { Appearance.default with icons; density = Compact } in
      List.iter [ 40; 24 ] ~f:(fun width ->
        render ~appearance ~attrs:(fun _ -> []) ~width ~height:1 [ linkage ]
        |> plain_lines
        |> List.iter ~f:print_endline)));
  [%expect
    {|
    Context: linked to Main
    Context: linked to Main
    = Context: linked to Main
    = Context: linked to Mai
    ↔ Context: linked to Main
    ↔ Context: linked to Mai
    Context: own Overview independent
    Context: own Overview in
    o Context: own Overview independent
    o Context: own Overview
    ○ Context: own Overview independent
    ○ Context: own Overview
    |}]
;;
