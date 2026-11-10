open! Core
open Hardcaml_workbench_protocol
module O = Overview_tiles

module Rtl_scope = struct
  type t =
    { project : Project_id.t
    ; target : Target_id.t
    ; configuration : Configuration_id.t
    }

  let create ~(project : Project.t option) ~target ~configuration =
    Option.bind project ~f:(fun p ->
      Option.bind target ~f:(fun target ->
        Option.bind configuration ~f:(fun configuration ->
          if Option.is_some (Project.target p target)
             && List.exists p.configurations ~f:(fun c ->
               Configuration_id.equal c.id configuration
               && Target_id.equal c.target target)
          then Some { project = p.id; target; configuration }
          else None)))
  ;;
end

let latest_rtl ~scope ~jobs =
  Option.bind scope ~f:(fun (s : Rtl_scope.t) ->
    State.latest_generation
      jobs
      ~project:s.project
      ~target:s.target
      ~configuration:s.configuration)
;;

let active (a : Preparation.Attempt.t) =
  match a.outcome with
  | Building | Emitting -> true
  | _ -> false
;;

let outcome = function
  | Preparation.Outcome.Building -> O.Status.Running
  | Emitting -> Running
  | Completed -> Completed
  | Build_failed | Emission_failed -> Failed
  | Cancelled -> Cancelled
;;

let outcome_label : Preparation.Outcome.t -> string = function
  | Building -> "building"
  | Emitting -> "emitting elaboration bundle"
  | Completed -> "completed"
  | Build_failed -> "build failed"
  | Emission_failed -> "emission failed"
  | Cancelled -> "cancelled"
;;

let unrequested_status = function
  | Some { Preparation.Snapshot.availability = Available; _ } -> O.Status.Not_requested
  | None | Some { availability = Unavailable _; _ } -> O.Status.Unsupported
;;

let checklist_status snapshot =
  Option.bind snapshot ~f:(fun (s : Preparation.Snapshot.t) -> s.latest)
  |> Option.value_map ~default:(unrequested_status snapshot) ~f:(fun a ->
    outcome a.outcome)
;;

let status_label = function
  | O.Status.Unsupported -> "unavailable"
  | status -> O.Status.label status
;;

let job_status (j : Job.t) : O.Status.t =
  match j.state with
  | Queued -> Pending
  | Starting | Running -> Running
  | Complete -> Completed
  | Failed -> Failed
  | Cancelled -> Cancelled
;;

let attempts snapshot =
  Option.value_map snapshot ~default:[] ~f:(fun (s : Preparation.Snapshot.t) ->
    Option.to_list s.latest @ s.history
    |> List.stable_dedup ~compare:(fun a b ->
      String.compare a.Preparation.Attempt.id b.id))
;;

let selected snapshot cursor =
  let all = attempts snapshot in
  Option.first_some
    (Option.bind cursor ~f:(fun id -> List.find all ~f:(fun a -> String.equal a.id id)))
    (List.hd all)
;;

let selection ~remembered ~(asic : Asic.Snapshot.t option) =
  let chosen =
    match remembered with
    | Some s -> Ok s
    | None ->
      (match Option.bind asic ~f:(fun s -> s.catalog_default) with
       | None -> Error "Choose current flow/profile/overrides in Plan first"
       | Some p ->
         let endpoint =
           Option.bind asic ~f:(fun a ->
             List.find a.flows ~f:(fun f -> String.equal f.id p.flow))
           |> Option.bind ~f:Launch_preferences.default_endpoint
         in
         (match endpoint with
          | None -> Error "Choose an explicit selected-flow endpoint in Plan first"
          | Some endpoint ->
            Ok
              { Asic.Selection.flow = p.flow
              ; profile = p.profile
              ; endpoint
              ; assignments = []
              }))
  in
  (* Explicit current-project inputs can be built before an ASIC catalog exists. The
     freshly built selected-flow publisher validates them authoritatively. *)
  chosen
;;

let prepare ~snapshot ~selection ~submission_key ~expected_plan_identity =
  match snapshot, selection with
  | Some { Preparation.Snapshot.availability = Available; latest; _ }, Ok selection
    when not (Option.exists latest ~f:active) ->
    Ok
      (Preparation.Operation.Prepare { submission_key; selection; expected_plan_identity })
  | Some { availability = Unavailable _; _ }, _ ->
    Error "Preparation unavailable (configuration)"
  | None, _ -> Error "Preparation capability unavailable or not loaded"
  | _, Error reason -> Error reason
  | _ -> Error "Preparation already active"
;;

let stage ~snapshot ~selection ~expected_plan_identity =
  match snapshot, selection with
  | Some { Preparation.Snapshot.availability = Available; _ }, Ok selection ->
    Ok (Preparation.Operation.Stage { selection; expected_plan_identity })
  | Some { availability = Unavailable _; _ }, _ ->
    Error "Preparation unavailable (configuration)"
  | None, _ -> Error "Preparation capability unavailable or not loaded"
  | _, Error reason -> Error reason
;;

let staged_available (s : Preparation.Snapshot.t) =
  match s.availability with
  | Unavailable _ -> None
  | Available ->
    Option.filter s.staged ~f:(fun staged ->
      not
        (Option.exists s.latest ~f:(fun a ->
           Timestamp.compare a.created_at staged.created_at >= 0)))
;;

(* Inclusive preparation time: starts at attempt acceptance, ends at the last supervised
   build/emission finish. Retained live samples never run backwards. *)
let elapsed_samples = String.Table.create ()

let monotonic_now () =
  Result.ok Core_unix.Clock.gettime
  |> Option.map ~f:(fun gettime -> Int63.to_float (gettime Monotonic) /. 1e9)
;;

let total_time ?(monotonic = monotonic_now ()) ~now snapshot =
  match Option.bind snapshot ~f:(fun s -> s.Preparation.Snapshot.latest) with
  | None -> "unknown"
  | Some a ->
    let finish =
      if active a
      then Some now
      else (
        let final_job =
          match a.outcome with
          | Build_failed -> a.build_job
          | Cancelled -> Option.first_some a.emission_job a.build_job
          | Completed | Emission_failed -> a.emission_job
          | Building | Emitting -> None
        in
        Option.bind final_job ~f:(fun j ->
          Option.map j.Job.finished_at ~f:Timestamp.to_time_ns))
    in
    Option.value_map finish ~default:"unknown" ~f:(fun finish ->
      let seconds =
        Float.max
          0.
          (Time_ns.Span.to_sec (Time_ns.diff finish (Timestamp.to_time_ns a.created_at)))
      in
      let key = a.id ^ Sexp.to_string_mach (Timestamp.sexp_of_t a.created_at) in
      let seconds =
        if active a
        then (
          match monotonic with
          | None -> seconds
          | Some tick ->
            let initial, started =
              match Hashtbl.find elapsed_samples key with
              | Some sample -> sample
              | None ->
                if Hashtbl.length elapsed_samples >= 256
                then Hashtbl.clear elapsed_samples;
                Hashtbl.set elapsed_samples ~key ~data:(seconds, tick);
                seconds, tick
            in
            initial +. Float.max 0. (tick -. started))
        else seconds
      in
      Execution_time_view.duration seconds)
;;

let staged_lines (s : Preparation.Staged.t) =
  [ "Stage receipt: " ^ s.id
  ; "Not a generated provider preview; staging starts no processes; source bytes are not \
     frozen"
  ; "Source root: " ^ s.source_root
  ; "Build: " ^ s.build_target ^ " / executable: " ^ s.source_executable
  ; "Results: " ^ s.results_root
  ; "Environment: " ^ Sexp.to_string (V1.Environment_selection.sexp_of_t s.environment)
  ; "Flow: "
    ^ s.selection.flow
    ^ " / profile: "
    ^ s.selection.profile
    ^ " / provider endpoint: "
    ^ s.selection.endpoint
  ; "Overrides: " ^ String.concat ~sep:"; " s.selection.assignments
  ; "Expected plan: " ^ Option.value s.expected_plan_identity ~default:"none"
  ; "Timeout: " ^ Int.to_string s.timeout_seconds ^ " seconds"
  ; "Created: " ^ Sexp.to_string (Timestamp.sexp_of_t s.created_at)
  ; "Launch planned run: builds and emits; no ASIC allocation or context switch"
  ]
;;

let staged_state ~snapshot ~reason =
  match snapshot with
  | None -> `Unavailable "Preparation capability unavailable or not loaded"
  | Some { Preparation.Snapshot.availability = Unavailable Not_configured; _ } ->
    `Unavailable "Preparation unavailable: not configured"
  | Some { availability = Unavailable (Invalid_configuration reason); _ } ->
    `Unavailable ("Preparation unavailable: " ^ reason)
  | Some s ->
    (match s.staged, reason with
     | Some _, _ when Option.is_none (staged_available s) ->
       `Consumed
         ("Stage receipt consumed/stale: latest preparation attempt is at or after \
           staging"
          ^ Option.value_map s.latest ~default:"" ~f:(fun a -> "; attempt: " ^ a.id))
     | _, Some reason -> `Stale reason
     | Some _, None -> `Ready
     | None, None -> `Unavailable "No staged input plan; r stages current inputs")
;;

let staged_plan_rows ~snapshot ~reason ~detail =
  let state, role, availability =
    match staged_state ~snapshot ~reason with
    | `Ready -> "ready", Planned_run.Success, "staged, unconsumed"
    | `Stale reason -> "stale", Warning, reason
    | `Consumed reason -> "consumed/stale", Warning, reason
    | `Unavailable reason -> "unavailable", Muted, reason
  in
  let ready = String.equal state "ready" in
  let row role text = { Planned_run.role; text } in
  [ row
      role
      (state
       ^ ": elaboration input plan / launch: "
       ^ if ready then "not requested" else "disabled")
  ; row Fact "endpoint: elaboration"
  ; row Fact "launch: build and emit (EDA-less)"
  ]
  @ Option.value_map
      (Option.bind snapshot ~f:(fun s -> s.Preparation.Snapshot.staged))
      ~default:[]
      ~f:(fun s ->
        [ row Fact ("flow: " ^ s.selection.flow ^ " / profile: " ^ s.selection.profile)
        ; row
            Fact
            ("assignments: "
             ^
             if List.is_empty s.selection.assignments
             then "(none)"
             else String.concat ~sep:"; " s.selection.assignments)
        ]
        @ if detail then List.map (staged_lines s) ~f:(row Fact) else [])
  @
  if detail
  then
    [ row role ("Stage availability: " ^ availability) ]
    @ Option.value_map reason ~default:[] ~f:(fun reason ->
      [ row Warning ("Preparation reason: " ^ reason) ])
  else []
;;

let attempt_details (a : Preparation.Attempt.t) =
  [ "Selection: "
    ^ a.selection.flow
    ^ " / "
    ^ a.selection.profile
    ^ " / endpoint "
    ^ a.selection.endpoint
  ; "Overrides: " ^ String.concat ~sep:"; " a.selection.assignments
  ; "Selection identity: " ^ a.selection_identity
  ; "Expected plan: " ^ Option.value a.expected_plan_identity ~default:"none"
  ; "Source root: " ^ a.source_root
  ; "Build target: " ^ a.build_target
  ; "Source executable: " ^ a.source_executable
  ; "Results root: " ^ a.results_root
  ; "Timeout: " ^ Int.to_string a.timeout_seconds ^ " seconds"
  ; "Environment: " ^ Sexp.to_string (V1.Environment_selection.sexp_of_t a.environment)
  ; "Created: " ^ Sexp.to_string (Timestamp.sexp_of_t a.created_at)
  ; "Outcome: " ^ outcome_label a.outcome
  ]
  @ Option.to_list (Option.map a.diagnostic ~f:(fun d -> "Diagnostic: " ^ d))
  @ Option.value_map a.bundle ~default:[] ~f:(fun b ->
    [ "Bundle: " ^ b.bundle_identity
    ; "Plan: " ^ b.plan_identity
    ; "Output directory: " ^ b.output_dir
    ; "Reused: " ^ Bool.to_string b.reused
    ]
    @ List.map b.artifacts ~f:(fun id ->
      "Artifact (palette opens exact handle): " ^ Artifact_id.to_string id))
;;

let rows ~snapshot ~jobs ~project ~rtl_scope ~cursor ~detail ~log_lines =
  let row status label value details =
    O.row ~status ~role:(O.status_role status) ~details label value
  in
  let scope =
    "Current project; independent of selected historical ASIC run; session-only history"
  in
  let stage label job =
    match job with
    | None -> row O.Status.Not_requested label "not requested" [ scope ]
    | Some (j : Job.t) ->
      let status = job_status j in
      row
        status
        label
        (O.Status.label status)
        ([ "Job: " ^ Job_id.to_string j.id
         ; "Process exit: "
           ^ Option.value_map j.exit_status ~default:"not reported" ~f:(fun s ->
             Sexp.to_string (Job.Exit_status.sexp_of_t s))
         ]
         @ Option.to_list
             (Option.map j.failure ~f:(fun reason -> "Job failure: " ^ reason))
         @ log_lines j.id)
  in
  let verification =
    List.filter jobs ~f:(fun (j : Job.t) ->
      Option.exists project ~f:(Project_id.equal j.project)
      && String.equal j.kind.namespace "dune"
      && String.equal j.kind.name "test")
    |> List.max_elt ~compare:(fun a b -> Timestamp.compare a.created_at b.created_at)
  in
  let all = attempts snapshot in
  let generic_build =
    List.filter jobs ~f:(fun (j : Job.t) ->
      Option.exists project ~f:(Project_id.equal j.project)
      && String.equal j.kind.namespace "dune"
      && String.equal j.kind.name "build")
    |> List.max_elt ~compare:(fun a b -> Timestamp.compare a.created_at b.created_at)
  in
  let current = if detail then selected snapshot cursor else List.hd all in
  let availability =
    match snapshot with
    | None -> "capability unavailable / not loaded"
    | Some { availability = Unavailable Not_configured; _ } ->
      "unavailable: not configured"
    | Some { availability = Unavailable (Invalid_configuration reason); _ } ->
      "unavailable: " ^ reason
    | Some _ -> "not requested / no session history"
  in
  let result =
    match current with
    | None ->
      [ O.row ~role:Muted "Preparation" availability
      ; stage "Build (generic dune.build)" generic_build
      ; row
          (unrequested_status snapshot)
          "Elaboration-bundle emission"
          (status_label (unrequested_status snapshot))
          [ scope; availability ]
      ]
    | Some a ->
      let details =
        [ scope
        ; "Session-only: "
          ^ Bool.to_string
              (Option.value_map snapshot ~default:true ~f:(fun s -> s.session_only))
        ; "Requested attempt: "
          ^ Option.value
              (Option.bind snapshot ~f:(fun s -> s.requested_attempt))
              ~default:"none"
        ]
      in
      [ row
          (outcome a.outcome)
          "Project attempt"
          (a.id ^ " — " ^ outcome_label a.outcome)
          details
      ; stage "Build" a.build_job
      ; (let r = stage "Elaboration-bundle emission" a.emission_job in
         { r with
           details = r.details @ attempt_details a
         ; value =
             r.value
             ^ Option.value_map a.bundle ~default:"" ~f:(fun b ->
               " / bundle " ^ b.bundle_identity)
         })
      ]
  in
  let result =
    result
    @ [ (let r = stage "Verification (project test command)" verification in
         { r with
           value =
             (if Option.equal O.Status.equal r.status (Some Completed)
              then "process succeeded"
              else r.value)
         ; details = "Process success is not semantic test pass" :: r.details
         })
      ]
  in
  let result =
    match current, latest_rtl ~scope:rtl_scope ~jobs, rtl_scope with
    | None, Some job, Some selected ->
      let generic = stage "Generic RTL (not ASIC bundle)" (Some job) in
      result
      @ [ { generic with
            details =
              [ "Observed generate-rtl process for the exact current selected \
                 target/configuration"
              ; "Target: " ^ Target_id.to_string selected.target
              ; "Configuration: " ^ Configuration_id.to_string selected.configuration
              ; "Generic RTL generation is not selected-flow ASIC bundle publication"
              ; "This job is evidence of an invocation, not an advertisement of future \
                 driver capabilities"
              ]
              @ generic.details
              @ List.map job.artifacts ~f:(fun id ->
                "RTL artifact (palette opens exact handle): " ^ Artifact_id.to_string id)
          }
        ]
    | _ -> result
  in
  let result =
    match detail, Option.bind snapshot ~f:(fun s -> s.latest), current with
    | true, Some latest, Some inspected when not (String.equal latest.id inspected.id) ->
      row
        (outcome latest.outcome)
        "Latest project attempt"
        (latest.id ^ " — " ^ outcome_label latest.outcome)
        [ "Inspecting historical attempt "
          ^ inspected.id
          ^ "; latest outcome remains authoritative"
        ]
      :: result
    | _ -> result
  in
  let result =
    Option.value_map
      (Option.bind snapshot ~f:staged_available)
      ~default:[]
      ~f:(fun staged ->
        [ O.row
            ~role:Success
            ~details:(staged_lines staged)
            "PREPARATION input plan"
            ("ready: " ^ staged.id)
        ])
    @ (match snapshot with
       | Some s when Option.is_some s.staged && Option.is_none (staged_available s) ->
         [ O.row
             ~role:Muted
             "PREPARATION input plan"
             "consumed/stale; r stages new inputs"
         ]
       | _ -> [])
    @ result
  in
  if not detail
  then result
  else
    result
    @ [ O.row
          ~role:Muted
          "Controls"
          "j/k attempts; Enter inspect; r stage input plan; R stage+launch; x cancel; a \
           artifact"
      ]
    @ List.map all ~f:(fun a ->
      row (outcome a.outcome) "History" a.id (attempt_details a))
    @ (List.filter jobs ~f:(fun (j : Job.t) ->
         Option.exists project ~f:(Project_id.equal j.project)
         && String.equal j.kind.namespace "dune"
         && String.equal j.kind.name "test")
       |> List.map ~f:(fun j -> stage "Verification process history" (Some j)))
;;

let fixture_attempt id outcome : Preparation.Attempt.t =
  let job name state =
    { (Job.create
         ~id:(Job_id.of_string (id ^ "/" ^ name))
         ~kind:{ namespace = "preparation"; name }
         ~project:(Project_id.of_string "project")
         ~created_at:(Timestamp.of_time_ns Time_ns.epoch))
      with
      state
    }
  in
  { id
  ; selection =
      { flow = "flow"
      ; profile = "profile"
      ; endpoint = "routing"
      ; assignments = [ "X=a b" ]
      }
  ; selection_identity = "selection"
  ; expected_plan_identity = Some "plan"
  ; source_root = "/source"
  ; build_target = "source.exe"
  ; source_executable = "_build/default/source.exe"
  ; results_root = "/results"
  ; timeout_seconds = 10
  ; environment = Inherit_daemon
  ; created_at = Timestamp.of_time_ns Time_ns.epoch
  ; outcome
  ; build_job = Some (job "build" Complete)
  ; emission_job =
      Some
        (job
           "emit"
           (match outcome with
            | Completed -> Complete
            | Cancelled -> Cancelled
            | Emitting -> Running
            | _ -> Failed))
  ; bundle =
      (match outcome with
       | Completed ->
         Some
           { bundle_identity = "bundle-" ^ id
           ; plan_identity = "plan"
           ; output_dir = "/bundle"
           ; reused = false
           ; plan_json = "{}"
           ; artifacts = [ Artifact_id.of_string (id ^ "/artifact") ]
           }
       | _ -> None)
  ; diagnostic = None
  }
;;

let fixture_snapshot () : Preparation.Snapshot.t =
  { availability = Available
  ; session_only = true
  ; requested_attempt = None
  ; staged = None
  ; latest = Some (fixture_attempt "new-failure" Emission_failed)
  ; history =
      [ fixture_attempt "new-failure" Emission_failed
      ; fixture_attempt "old-success" Completed
      ]
  }
;;

let%test_unit "inclusive preparation clock advances across build/emission, ignores wall \
               rollback and freezes terminal"
  =
  let start = Time_ns.epoch in
  let at seconds = Time_ns.add start (Time_ns.Span.of_sec seconds) in
  let attempt =
    { (fixture_attempt "clock-test" Building) with
      created_at = Timestamp.of_time_ns start
    }
  in
  let snapshot attempt = Some { (fixture_snapshot ()) with latest = Some attempt } in
  assert (
    String.equal (total_time ~monotonic:(Some 100.) ~now:(at 5.) (snapshot attempt)) "5s");
  let emitting = { attempt with outcome = Emitting } in
  assert (
    String.equal
      (total_time ~monotonic:(Some 107.) ~now:(at (-20.)) (snapshot emitting))
      "12s");
  let finished_job =
    Option.map (fixture_attempt "finished-clock" Completed).emission_job ~f:(fun j ->
      { j with finished_at = Some (Timestamp.of_time_ns (at 15.)) })
  in
  let finished =
    { emitting with outcome = Completed; emission_job = finished_job; build_job = None }
  in
  assert (String.equal (total_time ~now:(at 100.) (snapshot finished)) "15s");
  assert (String.equal (total_time ~now:(at 200.) (snapshot finished)) "15s");
  assert (String.equal (total_time ~now:start None) "unknown");
  let unknown = { finished with emission_job = None } in
  assert (String.equal (total_time ~now:start (snapshot unknown)) "unknown");
  let missing_finish =
    { finished with
      build_job = finished_job
    ; emission_job = Option.map finished_job ~f:(fun j -> { j with finished_at = None })
    }
  in
  assert (String.equal (total_time ~now:start (snapshot missing_finish)) "unknown")
;;

let%test_unit "preparation preserves failed headline, completed build, exact logs and \
               prior publication"
  =
  let snapshot = Some (fixture_snapshot ()) in
  let rows =
    rows
      ~snapshot
      ~jobs:[]
      ~project:None
      ~rtl_scope:None
      ~cursor:None
      ~detail:false
      ~log_lines:(fun id -> [ "exact log " ^ Job_id.to_string id ])
  in
  assert (Option.equal O.Status.equal (List.hd_exn rows).status (Some Failed));
  assert (Option.equal O.Status.equal (List.nth_exn rows 1).status (Some Completed));
  assert (Option.equal O.Status.equal (List.nth_exn rows 2).status (Some Failed));
  assert (
    List.mem
      (List.nth_exn rows 1).details
      "exact log new-failure/build"
      ~equal:String.equal);
  assert (
    List.mem
      (List.nth_exn rows 2).details
      "exact log new-failure/emit"
      ~equal:String.equal);
  let old = selected snapshot (Some "old-success") |> Option.value_exn in
  assert (Option.is_some old.bundle);
  assert (List.length (attempts snapshot) = 2);
  assert (O.Status.equal (outcome Cancelled) Cancelled)
;;

let%test_unit "preparation guards capability, availability, activity and captures exact \
               inputs without physical Run"
  =
  let s = fixture_snapshot () in
  let captured = (fixture_attempt "captured" Completed).selection in
  let prepare snapshot selection =
    prepare
      ~snapshot
      ~selection
      ~submission_key:"key"
      ~expected_plan_identity:(Some "exact-plan")
  in
  (match prepare (Some s) (Ok captured) with
   | Ok (Prepare p) ->
     assert (Asic.Selection.equal p.selection captured);
     assert (Option.equal String.equal p.expected_plan_identity (Some "exact-plan"))
   | _ -> assert false);
  assert (Result.is_error (prepare None (Ok captured)));
  assert (
    Result.is_error
      (prepare (Some { s with availability = Unavailable Not_configured }) (Ok captured)));
  assert (
    Result.is_error
      (prepare
         (Some { s with latest = Some (fixture_attempt "active" Emitting) })
         (Ok captured)));
  assert (Result.is_error (prepare (Some s) (Error "no selection")));
  assert (
    Asic.Selection.equal
      (Result.ok_or_failwith (selection ~remembered:(Some captured) ~asic:None))
      captured);
  assert (Result.is_error (selection ~remembered:None ~asic:None));
  let rows =
    rows
      ~snapshot:(Some { s with latest = None; history = [] })
      ~jobs:[]
      ~project:None
      ~rtl_scope:None
      ~cursor:None
      ~detail:false
      ~log_lines:(fun _ -> [])
  in
  assert (String.is_substring (List.hd_exn rows).value ~substring:"no session history")
;;
