open! Core
open Hardcaml_workbench_protocol

let require ok message = if not ok then failwith message

let field name = function
  | `Assoc fields ->
    Option.value (List.Assoc.find fields name ~equal:String.equal) ~default:`Null
  | _ -> `Null
;;

let text = function
  | `String s -> s
  | _ -> failwith "Expected JSON string"
;;

let integer = function
  | `Int n -> n
  | _ -> failwith "Expected JSON integer"
;;

let list = function
  | `List xs -> xs
  | _ -> failwith "Expected JSON array"
;;

let optional_text = function
  | `Null -> None
  | j -> Some (text j)
;;

let duration_number = function
  | `Float f -> Execution_timing.seconds (Some f)
  | `Int n -> Execution_timing.seconds (Some (Float.of_int n))
  | _ -> None
;;

let timing_start timing = Option.bind timing ~f:(fun t -> t.Execution_timing.started_at)

let receipt_timing ~running receipt =
  let stamp name =
    match field name receipt with
    | `String text -> Execution_timing.timestamp text
    | _ -> None
  in
  let started_at = stamp "started_at" in
  let measured_seconds =
    match started_at, stamp "ended_at" with
    | Some start, Some finish when not running ->
      Some
        (Time_ns.Span.to_sec
           (Time_ns.diff (Timestamp.to_time_ns finish) (Timestamp.to_time_ns start)))
    | _ -> None
  in
  Execution_timing.make ?started_at ?measured_seconds ~running ()
;;

let absolute s =
  require (Filename.is_absolute s) "Expected absolute public reference";
  s
;;

let decode text =
  let j = Yojson.Safe.from_string text in
  let rec check = function
    | `Assoc xs ->
      require
        (List.length xs
         = List.length (List.dedup_and_sort (List.map xs ~f:fst) ~compare:String.compare)
        )
        "Duplicate JSON key";
      List.iter xs ~f:(fun (_, j) -> check j)
    | `List xs -> List.iter xs ~f:check
    | `Float f -> require (Float.is_finite f) "Nonfinite JSON"
    | `Tuple _ | `Variant _ -> failwith "Nonstandard JSON"
    | _ -> ()
  in
  check j;
  j
;;

let envelope j contract version =
  require
    (String.equal (text (field "contract" j)) contract
     && integer (field "schema_version" j) = version)
    ("Unsupported public envelope: " ^ contract);
  j
;;

let metadata j =
  let c = field "cli_contract" j in
  require
    (integer (field "version" c) = 4
     && Poly.equal (field "namedflow1" (field "capabilities" c)) (`Bool true))
    "Installed provider requires exact CLI4 + namedflow1=true"
;;

let canonical_stages =
  [ "synthesis"; "floorplan"; "placement"; "cts"; "routing"; "timing"; "signoff" ]
;;

let recipe_stages plan =
  match integer (field "schema_version" plan) with
  | 2 | 3 -> List.filter canonical_stages ~f:(fun s -> not (String.equal s "timing"))
  | 4 -> canonical_stages
  | _ -> failwith "Unsupported execution stage plan"
;;

(* Schema 2 predates explicit sequences: [resume] means a synthesis checkpoint. Expand
   only in the historical six-stage graph, without upgrading its identity. *)
let explicit_recipe_plan plan =
  if not (Poly.equal (field "schema_version" plan) (`Int 2))
  then plan
  else (
    let canonical = recipe_stages plan in
    let endpoint = text (field "endpoint" plan) in
    require (List.mem canonical endpoint ~equal:String.equal) "Unknown legacy endpoint";
    let resume =
      match field "resume" plan with
      | `Bool value -> value
      | _ -> failwith "Missing legacy recipe resume boolean"
    in
    let prefix =
      List.take_while canonical ~f:(fun s -> not (String.equal s endpoint)) @ [ endpoint ]
    in
    let requested = if resume then List.tl_exn prefix else prefix in
    require (not (List.is_empty requested)) "Empty legacy recipe";
    `Assoc
      [ "schema_version", `Int 3
      ; "stages", `List (List.map requested ~f:(fun s -> `String s))
      ; ("initial_boundary", if resume then `String "synthesis" else `Null)
      ])
;;

let catalog_identity j =
  let s = text j in
  require
    (String.length s > 0
     && String.length s <= 256
     && String.for_all s ~f:(function
       | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' -> true
       | _ -> false))
    "Invalid catalog identity/text budget";
  s
;;

let catalog_list ~limit j =
  let xs = list j in
  require (List.length xs <= limit) "Catalog entry budget exceeded";
  xs
;;

let catalog_unique xs =
  require
    (List.length xs = List.length (List.dedup_and_sort xs ~compare:String.compare))
    "Duplicate catalog identity"
;;

(* Only this explicit public fresh-prefix contract authorizes checklist mapping.
   Legacy/other provider catalogs remain useful for ordinary explicit Plan/Run. *)
let flow_catalog j =
  require
    (String.length (Yojson.Safe.to_string j) <= 1024 * 1024)
    "Catalog byte budget exceeded";
  let j = envelope j "hardcaml-asic.flow-list" 1 in
  let catalog = envelope (field "declaration" j) "hardcaml-asic.flow-catalog" 1 in
  let capabilities = field "capabilities" j in
  let matches j key value = Poly.equal (field key j) (`String value) in
  let supported =
    matches capabilities "backend_recipe" "librelane.classic.v1"
    && matches capabilities "input" "fresh"
    && matches capabilities "stage_selection" "complete-prefix-through-declared-endpoint"
    && Poly.equal (field "continuation" capabilities) (`Bool false)
  in
  List.iter [ "backend_recipe"; "input"; "stage_selection" ] ~f:(fun key ->
    match field key capabilities with
    | `Null -> ()
    | value -> ignore (catalog_identity value : string));
  let flows =
    catalog_list ~limit:128 (field "entries" catalog)
    |> List.map ~f:(fun e ->
      let methodology = field "methodology" e in
      List.iter [ "backend_recipe"; "input" ] ~f:(fun key ->
        match field key methodology with
        | `Null -> ()
        | value -> ignore (catalog_identity value : string));
      let id = catalog_identity (field "id" methodology) in
      let profiles =
        catalog_list ~limit:64 (field "profiles" e)
        |> List.map ~f:(fun p -> catalog_identity (field "id" p))
      in
      catalog_unique profiles;
      let default_profile = catalog_identity (field "default_profile" e) in
      require
        (List.mem profiles default_profile ~equal:String.equal)
        "Unknown catalog entry default profile";
      let fresh_stage_endpoints =
        if supported
           && matches methodology "backend_recipe" "librelane.classic.v1"
           && matches methodology "input" "fresh"
        then (
          let endpoints =
            catalog_list ~limit:7 (field "endpoints" methodology)
            |> List.map ~f:catalog_identity
          in
          catalog_unique endpoints;
          require
            (List.for_all endpoints ~f:(fun endpoint ->
               List.mem canonical_stages endpoint ~equal:String.equal))
            "Unknown fresh-prefix endpoint";
          endpoints)
        else []
      in
      { Asic.Flow.id; profiles; default_profile; fresh_stage_endpoints })
  in
  catalog_unique (List.map flows ~f:(fun f -> f.Asic.Flow.id));
  let catalog_default =
    match field "default" catalog with
    | `Null ->
      require (not supported) "Fresh-prefix catalog requires an explicit default pair";
      (* An absent legacy extension is not an invented default. A supplied null is
         malformed rather than a declaration of an actual pair. *)
      (match catalog with
       | `Assoc fields ->
         require
           (not (List.Assoc.mem fields "default" ~equal:String.equal))
           "Catalog default must be an explicit pair"
       | _ -> ());
      None
    | value ->
      let flow = catalog_identity (field "flow" value) in
      let profile = catalog_identity (field "profile" value) in
      require
        (List.exists flows ~f:(fun f ->
           String.equal f.id flow && List.mem f.profiles profile ~equal:String.equal))
        "Unknown catalog default flow/profile pair";
      Some { Asic.Flow_default.flow; profile }
  in
  flows, catalog_default
;;

let flows j = fst (flow_catalog j)

let preview selection j : Asic.Preview.t =
  let j = envelope j "hardcaml-asic.methodology-plan" 1 in
  let plan_identity = text (field "plan_identity" j) in
  require
    (String.length plan_identity = 64
     && String.for_all plan_identity ~f:(function
       | '0' .. '9' | 'a' .. 'f' -> true
       | _ -> false))
    "Invalid plan identity";
  { selection; plan_identity; plan_json = Yojson.Safe.to_string j }
;;

let allocation j : Asic.Reference.t =
  let j = envelope j "hardcaml-asic.stage-observation" 1 in
  require
    (String.equal (text (field "event" j)) "observation_allocated")
    "Expected early allocation";
  let stream_id = text (field "stream_id" j) in
  require (not (String.is_empty stream_id)) "Empty stream identity";
  { attempt = absolute (text (field "attempt" j)); stream_id }
;;

let execution_summary (r : Asic.Run.t) (preview : Asic.Preview.t) j =
  require
    (Poly.equal (field "contract" j) `Null && Poly.equal (field "schema_version" j) `Null)
    "Unsupported launcher record";
  require
    (String.equal (text (field "attempt_id" j)) r.reference.stream_id)
    "Launcher execution identity mismatch";
  require
    (List.mem
       [ "completed"; "failed"; "interrupted" ]
       (text (field "status" j))
       ~equal:String.equal)
    "Invalid execution status";
  ignore (integer (field "exit_code" j) : int);
  ignore (list (field "occurrences" j) : Yojson.Safe.t list);
  let plan = explicit_recipe_plan (field "plan" j) in
  ignore (recipe_stages plan : string list);
  ignore (list (field "stages" plan) : Yojson.Safe.t list);
  let reference =
    envelope (field "methodology" j) "hardcaml-asic.methodology-execution-reference" 1
  in
  require
    (Poly.equal (field "attempt_id" reference) (`String r.reference.stream_id)
     && Poly.equal (field "plan_identity" reference) (`String preview.plan_identity)
     && Poly.equal
          (field "expected_plan_identity" reference)
          (`String preview.plan_identity))
    "Launcher methodology identity mismatch";
  ignore (absolute (text (field "snapshot_path" reference)) : string)
;;

let updates (r : Asic.Run.t) j =
  let j = envelope j "hardcaml-asic.stage-observation" 2 in
  require
    (String.equal (text (field "stream_id" j)) r.reference.stream_id
     && integer (field "after" j) = r.cursor)
    "Update identity mismatch";
  let cursor = integer (field "cursor" j) in
  require (cursor >= r.cursor) "Regressed update cursor";
  ignore
    (List.fold
       (list (field "events" j))
       ~init:r.cursor
       ~f:(fun previous e ->
         let e = envelope e "hardcaml-asic.stage-observation" 2 in
         let sequence = integer (field "sequence" e) in
         require
           (String.equal (text (field "stream_id" e)) r.reference.stream_id
            && sequence > previous
            && sequence <= cursor)
           "Invalid observation sequence";
         sequence)
     : int);
  cursor
;;

let stage_text ~limit s =
  require
    (String.length s <= limit
     && String.for_all s ~f:(fun c -> Char.to_int c >= 32 && not (Char.equal c '\127')))
    "Invalid stage-plan text/budget"
;;

let stage_identity s =
  stage_text ~limit:256 s;
  require
    ((not (String.is_empty s))
     && String.for_all s ~f:(function
       | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' -> true
       | _ -> false))
    "Invalid stage-plan identity"
;;

let validate_stages (stages : Asic.Stage.t list) =
  require (List.length stages <= 128) "Stage-plan entry budget exceeded";
  let identities = String.Hash_set.create () in
  List.iter stages ~f:(fun stage ->
    stage_identity stage.id;
    require (not (Hash_set.mem identities stage.id)) "Duplicate stage-plan identity";
    Hash_set.add identities stage.id;
    stage_text ~limit:1024 stage.name;
    require (not (String.is_empty (String.strip stage.name))) "Empty stage name";
    (match stage.status with
     | Unknown s ->
       stage_text ~limit:256 s;
       require (not (String.is_empty s)) "Empty stage status"
     | _ -> ());
    Option.iter stage.reason ~f:(stage_text ~limit:4096);
    Option.iter stage.action ~f:(fun action ->
      List.iter [ action.flow; action.profile; action.endpoint ] ~f:stage_identity;
      require (List.length action.assignments <= 64) "Stage action assignment budget";
      List.iter action.assignments ~f:(fun s ->
        stage_text ~limit:4096 s;
        require (not (String.is_empty s)) "Empty stage action assignment")));
  require
    (String.length (Sexp.to_string_mach ([%sexp_of: Asic.Stage.t list] stages))
     <= 256 * 1024)
    "Normalized stage-plan exceeds byte budget"
;;

(* CLI4 observation state is a provider-validated journal prefix, not a report or a
   checkpoint inventory. Interpret explicit recipes in their historical stage order. *)
let observation_stages j =
  let supplied name = function
    | `Assoc fields -> List.Assoc.mem fields name ~equal:String.equal
    | _ -> false
  in
  let state = field "state" j in
  let plan = field "plan" state in
  if not
       (List.mem
          [ `Int 2; `Int 3; `Int 4 ]
          (field "schema_version" plan)
          ~equal:Poly.equal)
  then []
  else (
    let canonical_stages = recipe_stages plan in
    let plan = explicit_recipe_plan plan in
    let stream = text (field "stream_id" j) in
    require
      (String.equal (text (field "attempt_id" state)) stream)
      "Stage observation attempt identity mismatch";
    let stage value =
      let s = text value in
      require (List.mem canonical_stages s ~equal:String.equal) "Unknown physical stage";
      s
    in
    let requested = List.map (list (field "stages" plan)) ~f:stage in
    require (supplied "initial_boundary" plan) "Missing recipe initial boundary";
    let initial =
      match field "initial_boundary" plan with
      | `Null -> None
      | value -> Some (stage value)
    in
    let remaining =
      Option.value_map initial ~default:canonical_stages ~f:(fun source ->
        List.tl_exn
          (List.drop_while canonical_stages ~f:(fun s -> not (String.equal s source))))
    in
    require
      ((not (List.is_empty requested))
       && List.equal String.equal requested (List.take remaining (List.length requested))
      )
      "Invalid explicit stage recipe";
    let occurrences = list (field "occurrences" state) in
    require
      (List.length occurrences <= List.length canonical_stages)
      "Stage occurrence budget exceeded";
    let seen = String.Hash_set.create () in
    let occurrences =
      List.map occurrences ~f:(fun occurrence ->
        let key = text (field "action_key" occurrence) in
        let id =
          List.find_exn canonical_stages ~f:(fun s ->
            String.equal key ("implementation." ^ s))
        in
        require
          (String.equal (text (field "occurrence_id" occurrence)) (stream ^ "/" ^ key)
           && not (Hash_set.mem seen id))
          "Invalid/duplicate stage occurrence identity";
        Hash_set.add seen id;
        require (supplied "exit_code" occurrence) "Missing occurrence exit code";
        require
          (Poly.equal (field "best_effort" occurrence) (`Bool false)
           && supplied "verdict" occurrence
           && Poly.equal (field "verdict" occurrence) `Null)
          "Unsupported physical occurrence contract";
        let status = text (field "status" occurrence) in
        let exit = field "exit_code" occurrence in
        let status : Asic.Stage.Status.t =
          match status, exit with
          | "unreached", `Null -> Pending
          | "running", `Null -> Running
          | "completed", `Int 0 -> Completed
          | "failed", `Int n when n <> 0 -> Failed
          | "interrupted", `Int n when n <> 0 -> Cancelled
          | _ -> Unknown "invalid_or_unknown_occurrence_state"
        in
        let execution_timing =
          match status with
          | Completed | Failed | Cancelled ->
            Execution_timing.make
              ?measured_seconds:(duration_number (field "duration_seconds" occurrence))
              ~running:false
              ()
          | _ -> None
        in
        id, (status, execution_timing))
    in
    let stages =
      List.map canonical_stages ~f:(fun id ->
        let requested = List.mem requested id ~equal:String.equal in
        let occurrence = List.Assoc.find occurrences id ~equal:String.equal in
        let execution_timing = Option.bind occurrence ~f:snd in
        let occurrence = Option.map occurrence ~f:fst in
        let status, reason =
          match requested, occurrence with
          | true, Some Cancelled ->
            ( Asic.Stage.Status.Cancelled
            , "Explicit interrupted stage occurrence; not evidence of user cancellation" )
          | true, Some status -> status, "Explicit stage occurrence"
          | true, None ->
            Unknown "missing_occurrence", "Requested stage occurrence missing"
          | false, Some Completed ->
            ( Completed
            , "Carried forward: explicit completed occurrence; not requested in this \
               recipe" )
          | false, Some _ ->
            ( Unknown "unrequested_occurrence"
            , "Unrequested stage has non-completed occurrence" )
          | false, None when Option.equal String.equal initial (Some id) ->
            Not_requested, "Resume input boundary; not newly measured by this recipe"
          | false, None -> Not_requested, "Not requested in this recipe"
        in
        let execution_timing =
          match status with
          | Completed | Failed | Cancelled -> execution_timing
          | _ -> None
        in
        { Asic.Stage.id
        ; name =
            (if (not requested) && Asic.Stage.Status.equal status Completed
             then id ^ " (carried forward)"
             else id)
        ; status
        ; requested
        ; reason = Some reason
        ; action = None (* No fresh-selection capability is advertised by state. *)
        ; execution_timing
        })
    in
    validate_stages stages;
    stages)
;;

let stage_plan j =
  match field "stage_plan" j with
  | `Null -> observation_stages j
  | `Assoc _ as plan ->
    (* Optional extensions of another contract/version are deliberately opaque. *)
    let contract = text (field "contract" plan) in
    let version = integer (field "schema_version" plan) in
    if not (String.equal contract "hardcaml-asic.stage-plan" && version = 1)
    then []
    else (
      let entries = list (field "stages" plan) in
      require (List.length entries <= 128) "Stage-plan entry budget exceeded";
      let stages =
        List.map entries ~f:(fun entry ->
          let status : Asic.Stage.Status.t =
            match text (field "status" entry) with
            | "pending" -> Pending
            | "running" -> Running
            | "completed" -> Completed
            | "failed" -> Failed
            | "skipped" -> Skipped
            | "cancelled" -> Cancelled
            | "not_requested" -> Not_requested
            | "unsupported" -> Unsupported
            | s -> Unknown s
          in
          let requested =
            match field "requested" entry with
            | `Bool b -> b
            | _ -> failwith "Expected stage requested boolean"
          in
          let action =
            match field "action" entry with
            | `Null -> None
            | action ->
              Some
                { Asic.Selection.flow = text (field "flow" action)
                ; profile = text (field "profile" action)
                ; endpoint = text (field "endpoint" action)
                ; assignments = List.map (list (field "assignments" action)) ~f:text
                }
          in
          { Asic.Stage.id = text (field "id" entry)
          ; name = text (field "name" entry)
          ; status
          ; requested
          ; reason = optional_text (field "reason" entry)
          ; action
          ; execution_timing = None
          })
      in
      validate_stages stages;
      stages)
  | _ -> failwith "Expected stage-plan object"
;;

let inspection (r : Asic.Run.t) ~cursor j =
  let j = envelope j "hardcaml-asic.stage-observation" 2 in
  require
    (cursor >= r.cursor
     && String.equal (text (field "stream_id" j)) r.reference.stream_id
     && integer (field "cursor" j) >= cursor)
    "Inspection identity/cursor mismatch";
  let writer_active =
    match field "writer_active" j with
    | `Bool b -> b
    | _ -> failwith "Missing writer status"
  in
  let outcome = field "outcome" (field "state" j) in
  let final =
    Poly.equal (field "observation_status" j) (`String "final")
    && (not writer_active)
    && (not (Poly.equal outcome `Null))
    && integer (field "cursor" j) = cursor
  in
  let status = if final then text (field "status" outcome) else "observing" in
  let execution_file =
    Option.map (optional_text (field "execution_file" j)) ~f:absolute
  in
  let stages = stage_plan j in
  (* Inspect can race ahead of read-updates. Never attach its stage state to an older
     cursor, or retain the previous cursor's checklist. The next poll catches up. *)
  let stages = if integer (field "cursor" j) = cursor then stages else [] in
  let stages =
    List.map stages ~f:(fun stage ->
      let started_at =
        List.find r.stages ~f:(fun old -> String.equal old.id stage.id)
        |> Option.bind ~f:(fun old -> timing_start old.execution_timing)
      in
      let measured_seconds =
        Option.bind stage.execution_timing ~f:(fun t -> t.measured_seconds)
      in
      { stage with
        execution_timing =
          Execution_timing.make
            ?started_at
            ?measured_seconds
            ~running:(writer_active && Asic.Stage.Status.equal stage.status Running)
            ()
      })
  in
  let execution_timing =
    Option.map r.execution_timing ~f:(fun timing ->
      { timing with
        Execution_timing.running =
          writer_active
          && (not final)
          && Option.is_some timing.started_at
          && Option.is_none timing.measured_seconds
      })
  in
  { r with cursor; status; execution_file; stages; execution_timing; error = None }, final
;;

(* Only validated update records supply start anchors and total elapsed time. Old
   registries whose cursor passed these events remain unknown; no implicit replay. *)
let updates_timing (r : Asic.Run.t) ~writer_active j =
  List.fold
    (list (field "events" j))
    ~init:r
    ~f:(fun r event ->
      let started_at =
        match field "recorded_at" event with
        | `String text -> Execution_timing.timestamp text
        | _ -> None
      in
      match field "event" event with
      | `String "allocated" ->
        { r with
          execution_timing = Execution_timing.make ?started_at ~running:writer_active ()
        }
      | `String "outcome" ->
        { r with
          execution_timing =
            Execution_timing.make
              ?started_at:(timing_start r.execution_timing)
              ?measured_seconds:(duration_number (field "elapsed_seconds" event))
              ~running:false
              ()
        }
      | `String "started" ->
        let occurrence = field "occurrence" (field "data" event) in
        let key = field "action_key" occurrence in
        { r with
          stages =
            List.map r.stages ~f:(fun stage ->
              if Poly.equal key (`String ("implementation." ^ stage.id))
              then (
                let measured_seconds =
                  Option.bind stage.execution_timing ~f:(fun timing ->
                    timing.measured_seconds)
                in
                { stage with
                  execution_timing =
                    Execution_timing.make
                      ?started_at
                      ?measured_seconds
                      ~running:
                        (writer_active && Asic.Stage.Status.equal stage.status Running)
                      ()
                })
              else stage)
        }
      | _ -> r)
;;

(* At most six anchors per registered run. An inspect racing ahead of the update cursor
   intentionally projects no stages, so retain starts independently. *)
let stage_start_events j =
  List.filter_map
    (list (field "events" j))
    ~f:(fun event ->
      if not (Poly.equal (field "event" event) (`String "started"))
      then None
      else (
        let occurrence = field "occurrence" (field "data" event) in
        let id =
          List.find canonical_stages ~f:(fun id ->
            Poly.equal (field "action_key" occurrence) (`String ("implementation." ^ id)))
        in
        match id, field "recorded_at" event with
        | Some id, `String text ->
          Option.map (Execution_timing.timestamp text) ~f:(fun at -> id, at)
        | _ -> None))
;;

let with_stage_starts (r : Asic.Run.t) ~writer_active starts =
  { r with
    stages =
      List.map r.stages ~f:(fun stage ->
        let started_at =
          Option.first_some
            (List.Assoc.find starts stage.id ~equal:String.equal)
            (timing_start stage.execution_timing)
        in
        let measured_seconds =
          Option.bind stage.execution_timing ~f:(fun t -> t.measured_seconds)
        in
        { stage with
          execution_timing =
            Execution_timing.make
              ?started_at
              ?measured_seconds
              ~running:(writer_active && Asic.Stage.Status.equal stage.status Running)
              ()
        })
  }
;;

let digest text =
  Cryptokit.hash_string (Cryptokit.Hash.sha256 ()) text
  |> Cryptokit.transform_string (Cryptokit.Hexa.encode ())
;;

let count = function
  | `Int n when n >= 0 -> Some n
  | `Float f
    when Float.is_finite f
         && Float.(f >= 0. && f < of_int Int.max_value)
         && Float.equal (Float.round_down f) f -> Some (Float.to_int f)
  | _ -> None
;;

(* Exact recognized keys/units from the adopted installed Stage_report_service. Do not
   infer timing, interpret unknown keys, or manufacture absent measurements. *)
let known_metrics =
  [ "design__instance__area", ("Mapped cell area", "µm²", false)
  ; "design__instance__count", ("Mapped cells", "cells", true)
  ; "design__instance_unmapped__count", ("Unmapped cells", "cells", true)
  ; "synthesis__check_error__count", ("Synthesis check errors", "count", true)
  ; "design__inferred_latch__count", ("Inferred latches", "count", true)
  ; "design__lint_error__count", ("Lint errors", "count", true)
  ; "design__lint_warning__count", ("Lint warnings", "count", true)
  ; "design__lint_timing_construct__count", ("Lint timing constructs", "count", true)
  ]
;;

let metric_number ~integral j =
  let number =
    match j with
    | `Int n -> Some (Float.of_int n)
    | `Intlit s -> Float.of_string_opt s
    | `Float f -> Some f
    | _ -> None
  in
  Option.filter number ~f:(fun f ->
    Float.is_finite f
    && Float.(f >= 0.)
    && ((not integral) || Float.equal (Float.round_down f) f))
;;

let project_metrics metrics =
  let projected =
    List.filter_map metrics ~f:(fun m ->
      match field "raw_key" m with
      | `String key ->
        Option.map
          (List.Assoc.find known_metrics key ~equal:String.equal)
          ~f:(fun (label, expected_unit, integral) ->
            let unit_ =
              match field "unit" m with
              | `String s -> Some s
              | _ -> None
            in
            let value =
              if Poly.equal (field "availability" m) (`String "available")
                 && Option.equal String.equal unit_ (Some expected_unit)
              then metric_number ~integral (field "value" m)
              else None
            in
            { Asic.Metric.key
            ; label
            ; value
            ; unit_
            ; availability = (if Option.is_some value then "available" else "unavailable")
            ; source =
                (match field "source" m with
                 | `Null -> None
                 | source -> Some (Yojson.Safe.to_string source))
            })
      | _ -> None)
  in
  require (List.length projected <= 64) "Metric summary exceeds normalized budget";
  projected
;;

let summary (r : Asic.Run.t) ~expected_plan ~execution_file j : Asic.Summary.t =
  let j = envelope j "hardcaml-asic.report" 1 in
  require
    (String.equal (text (field "attempt_id" (field "execution" j))) r.reference.stream_id)
    "Report execution identity mismatch";
  let methodology = field "methodology" j in
  if Poly.equal methodology `Null && not (Poly.equal (field "timing_analysis" j) `Null)
  then
    (* Direct stage executions and failed supplementary-only records can have no
       methodology. Do not project checkpoint metrics without that identity. *)
    require (Option.is_none expected_plan) "Report missing expected methodology"
  else (
    ignore (envelope methodology "hardcaml-asic.historical-methodology" 1 : Yojson.Safe.t);
    require
      (Poly.equal (field "state" methodology) (`String "recorded")
       && String.equal
            (text (field "attempt_id" (field "reference" methodology)))
            r.reference.stream_id)
      "Report methodology identity mismatch");
  let plan_identity = optional_text (field "plan_identity" methodology) in
  Option.iter expected_plan ~f:(fun p ->
    require (Option.equal String.equal plan_identity (Some p)) "Report plan mismatch");
  let checkpoints =
    if Poly.equal methodology `Null then [] else list (field "checkpoints" j)
  in
  let checkpoint =
    match
      List.filter checkpoints ~f:(fun c ->
        Poly.equal (field "boundary" (field "reference" c)) (`String "synthesis"))
    with
    | [] -> None
    | [ checkpoint ] -> Some checkpoint
    | _ -> failwith "Ambiguous synthesis checkpoint references"
  in
  let metrics =
    Option.value_map checkpoint ~default:[] ~f:(fun c ->
      match field "metrics" c with
      | `Null -> []
      | metrics -> list metrics)
  in
  let cell_count =
    List.find_map metrics ~f:(fun m ->
      if Poly.equal (field "raw_key" m) (`String "design__instance__count")
         && Poly.equal (field "availability" m) (`String "available")
         && Poly.equal (field "unit" m) (`String "cells")
      then count (field "value" m)
      else None)
  in
  let cells =
    Option.value_map checkpoint ~default:[] ~f:(fun c ->
      (match field "supplementary" c with
       | `Null -> []
       | j -> list j)
      |> List.concat_map ~f:(fun s ->
        match field "mapped_cell_types" s with
        | `Assoc xs ->
          List.filter_map xs ~f:(fun (name, n) ->
            Option.map (count n) ~f:(fun n -> name, n))
        | _ -> []))
  in
  require (List.length cells <= 4096) "Cell summary exceeds normalized budget";
  { run = r.run
  ; source_digest = digest (Yojson.Safe.to_string j)
  ; execution_file
  ; plan_identity
  ; cell_count
  ; cells
  ; metrics = project_metrics metrics
  ; terminal = None
  ; timing_analysis = None
  ; timing = [] (* CLI4 has no normalized timing attribution/units contract. *)
  ; completion = text (field "status" (field "execution" j))
  ; acceptance = text (field "acceptance" j)
  ; producer =
      Option.value_map checkpoint ~default:"no synthesis checkpoint" ~f:(fun c ->
        Yojson.Safe.to_string
          (`Assoc
            [ "reference", field "reference" c; "metric_origin", field "metric_origin" c ]))
  ; observed_at = Time_float.to_string (Time_float.now ())
  ; freshness = Validated
  }
;;

let validate_physical_selection (s : Asic.Selection.t) description =
  require
    (List.mem
       [ "floorplan"; "placement"; "cts"; "routing"; "timing"; "signoff" ]
       s.endpoint
       ~equal:String.equal)
    "Unsupported physical endpoint";
  let description = envelope description "hardcaml-asic.flow-describe" 1 in
  let entry = field "entry" description in
  let methodology = field "methodology" entry in
  require
    (Poly.equal (field "id" methodology) (`String s.flow)
     && List.mem
          (list (field "endpoints" methodology))
          (`String s.endpoint)
          ~equal:Poly.equal
     && List.exists
          (list (field "profiles" entry))
          ~f:(fun p -> Poly.equal (field "id" p) (`String s.profile))
     && Poly.equal
          (field "stage_selection" (field "capabilities" description))
          (`String "complete-prefix-through-declared-endpoint"))
    "Physical endpoint/profile not advertised by public description"
;;

let verdict = function
  | `String (("pass" | "fail" | "unknown") as s) -> s
  | _ -> "unknown"
;;

let supplied_string = function
  | `String s -> Some s
  | _ -> None
;;

let supplied_null name = function
  | `Assoc fields ->
    Option.value_map
      (List.Assoc.find fields name ~equal:String.equal)
      ~default:false
      ~f:(fun value -> Poly.equal value `Null)
  | _ -> false
;;

let terminal_results_file receipt =
  let receipt = envelope receipt "hardcaml-asic.segment-finalization" 1 in
  absolute (text (field "path" (field "results" receipt)))
;;

let declared_clock_key = Asic.Metric.declared_clock_period_key

let declared_clock_snapshot report =
  let reference = field "reference" (field "methodology" report) in
  match field "snapshot_path" reference, field "snapshot_sha256" reference with
  | `Null, `Null -> None
  | `String path, `String sha256 when not (String.is_empty sha256) ->
    Some (absolute path, sha256)
  | _ -> failwith "Incomplete historical clock snapshot reference"
;;

(* Declared constraints only: never a measured clock or inferred achieved frequency.
   [snapshot_bytes] must come from [declared_clock_snapshot], not a current preview. *)
let declared_clock_metric ~report ~receipt ~snapshot_bytes : Asic.Metric.t =
  let methodology = field "methodology" report in
  let reference = field "reference" methodology in
  let make ~port ~value ~source =
    { Asic.Metric.key = declared_clock_key
    ; label =
        Option.value_map port ~default:"Declared clock period" ~f:(fun port ->
          "Declared clock " ^ port ^ " period")
    ; value
    ; unit_ = Some "ns"
    ; availability = (if Option.is_some value then "available" else "unavailable")
    ; source = Some (Yojson.Safe.to_string source)
    }
  in
  match declared_clock_snapshot report with
  | None ->
    make
      ~port:None
      ~value:None
      ~source:
        (`Assoc
          [ "reason", `String "historical_snapshot_not_recorded"; "reference", reference ])
  | Some (path, sha256) ->
    let bytes =
      Option.value_exn snapshot_bytes ~message:"Historical clock snapshot bytes missing"
    in
    require
      (String.length bytes <= 256 * 1024)
      "Historical clock snapshot exceeds byte budget";
    require (String.equal (digest bytes) sha256) "Historical clock snapshot hash mismatch";
    let snapshot = envelope (decode bytes) "hardcaml-asic.methodology-plan" 1 in
    let plan_identity = text (field "plan_identity" snapshot) in
    let bundle_identity = text (field "bundle_identity" snapshot) in
    require
      ((not (String.is_empty plan_identity))
       && (not (String.is_empty bundle_identity))
       && Poly.equal (field "plan_identity" methodology) (`String plan_identity)
       && Poly.equal (field "bundle_identity" methodology) (`String bundle_identity)
       && Poly.equal (field "plan_identity" reference) (`String plan_identity)
       && Poly.equal (field "bundle_identity" reference) (`String bundle_identity)
       && Poly.equal
            (field "attempt_id" reference)
            (field "attempt_id" (field "execution" report))
       && Poly.equal
            (field "attempt_id" reference)
            (field "attempt_id" (field "execution" receipt))
       && Poly.equal
            (field "build_identity" (field "evidence_context" receipt))
            (`String bundle_identity))
      "Historical clock snapshot plan/bundle/execution identity mismatch";
    let configuration_bytes = field "configuration_bytes" snapshot in
    let configuration =
      Or_error.try_with (fun () -> decode (text configuration_bytes))
      |> Result.ok
      |> Option.value ~default:`Null
    in
    let port =
      supplied_string (field "CLOCK_PORT" configuration)
      |> Option.filter ~f:(fun s -> not (String.is_empty (String.strip s)))
    in
    let value =
      if Option.is_none port
      then None
      else
        metric_number ~integral:false (field "CLOCK_PERIOD" configuration)
        |> Option.filter ~f:(fun f -> Float.(f > 0.))
    in
    make
      ~port
      ~value
      ~source:
        (`Assoc
          [ "kind", `String "declared_constraint"
          ; "snapshot_path", `String path
          ; "snapshot_sha256", `String sha256
          ; "plan_identity", `String plan_identity
          ; "bundle_identity", `String bundle_identity
          ; "reference", reference
          ; "configuration_bytes", configuration_bytes
          ; ( "fields"
            , `Assoc
                [ "CLOCK_PORT", field "CLOCK_PORT" configuration
                ; "CLOCK_PERIOD", field "CLOCK_PERIOD" configuration
                ] )
          ; "resolved_settings", field "resolved_settings" snapshot
          ; ( "reason"
            , if Option.is_some value
              then `Null
              else `String "invalid_or_missing_declared_clock" )
          ])
;;

let rec canonical_json (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
    `Assoc
      (List.map fields ~f:(fun (key, value) -> key, canonical_json value)
       |> List.sort ~compare:(fun (a, _) (b, _) -> String.compare a b))
  | `List values -> `List (List.map values ~f:canonical_json)
  | scalar -> scalar
;;

(* The stage report remains authoritative for physical completion and checkpoint
   selection. The operation receipt alone supplies terminal acceptance. *)
let terminal_result
  ~attempt
  ~execution_file
  ~execution_bytes
  ~report
  ~receipt
  ~results_bytes
  : Asic.Terminal_result.t
  =
  ignore (absolute attempt : string);
  let receipt = envelope receipt "hardcaml-asic.segment-finalization" 1 in
  let execution = field "execution" receipt in
  let actual_execution = decode execution_bytes in
  let implementation_id = text (field "attempt_id" (field "execution" report)) in
  require
    (Poly.equal (field "path" execution) (`String execution_file)
     && Poly.equal (field "sha256" execution) (`String (digest execution_bytes))
     && Poly.equal (field "attempt_id" execution) (`String implementation_id)
     && Poly.equal (field "attempt_id" actual_execution) (`String implementation_id))
    "Finalization execution path/hash/identity mismatch";
  require
    (Poly.equal
       (canonical_json (field "execution" report))
       (canonical_json actual_execution))
    "Stage report execution differs from hashed finalization execution";
  let operation_status = text (field "status" receipt) in
  require
    (List.mem
       [ "completed"; "failed"; "interrupted" ]
       operation_status
       ~equal:String.equal
     && not (Poly.equal (field "ended_at" receipt) `Null))
    "Finalization operation is not terminal";
  let exit_code = integer (field "exit_code" receipt) in
  require
    (Bool.equal (String.equal operation_status "completed") (exit_code = 0))
    "Finalization operation status/exit mismatch";
  let selected = list (field "selected_checkpoints" receipt) in
  let reported = list (field "checkpoints" report) |> List.map ~f:(field "reference") in
  let checkpoint_key j =
    text (field "path" j), text (field "identity" j), text (field "boundary" j)
  in
  require
    ((not (List.is_empty selected))
     && List.equal
          Poly.equal
          (List.map selected ~f:checkpoint_key)
          (List.map reported ~f:checkpoint_key))
    "Finalization selected checkpoints differ from stage report";
  let artifacts = list (field "artifacts" actual_execution) in
  require
    (List.equal
       Poly.equal
       (List.map selected ~f:checkpoint_key)
       (List.map artifacts ~f:checkpoint_key))
    "Finalization selected checkpoints differ from hashed execution";
  let results_file = terminal_results_file receipt in
  let results_digest = digest results_bytes in
  require
    (Poly.equal (field "sha256" (field "results" receipt)) (`String results_digest))
    "Finalization results hash mismatch";
  let results = decode results_bytes in
  require
    (Poly.equal (field "schema_version" results) (`Int 1))
    "Unsupported terminal results schema";
  let operation_file = Filename.concat attempt "operation.json" in
  let provenance = field "provenance" results in
  require
    (Poly.equal
       (field "contract" provenance)
       (`String "hardcaml-asic.segment-finalization")
     && Poly.equal (field "operation" provenance) (`String operation_file)
     && Poly.equal (field "run_id" results) (field "attempt_id" receipt)
     && not (String.is_empty (text (field "run_id" results))))
    "Terminal results operation provenance mismatch";
  Option.iter
    (supplied_string (field "bundle_identity" (field "methodology" report)))
    ~f:(fun bundle ->
      require
        (Poly.equal (field "build_identity" results) (`String bundle))
        "Terminal results bundle mismatch");
  let physical_completion =
    match field "physical" (field "completion" report) with
    | `String s -> s
    | _ -> "unknown"
  in
  if String.equal physical_completion "full"
  then
    require
      (List.exists selected ~f:(fun c ->
         Poly.equal (field "boundary" c) (`String "signoff"))
       && Poly.equal (field "status" actual_execution) (`String "completed")
       && List.exists
            (list (field "occurrences" actual_execution))
            ~f:(fun o ->
              Poly.equal (field "action_key" o) (`String "implementation.signoff")
              && Poly.equal (field "status" o) (`String "completed")
              && Poly.equal (field "exit_code" o) (`Int 0)))
      "Full physical completion lacks selected completed signoff evidence";
  let acceptance = text (field "acceptance" receipt) in
  require
    (List.mem [ "pass"; "fail"; "not_evaluated" ] acceptance ~equal:String.equal)
    "Invalid terminal acceptance";
  if not (String.equal acceptance "not_evaluated")
  then
    require
      (Poly.equal (field "accept" (field "request" receipt)) (`Bool true))
      "Acceptance was not requested";
  if String.equal acceptance "pass"
  then
    require
      (String.equal operation_status "completed"
       && Poly.equal (field "external_postcheck" receipt) (`String "completed"))
      "Unearned terminal acceptance";
  let context field_name supplied =
    let resolved_source =
      match field "source" supplied with
      | `String s when not (String.is_empty s) ->
        `String (if Filename.is_absolute s then s else Filename.concat attempt s)
      | _ -> `Null
    in
    Yojson.Safe.to_string
      (`Assoc
        [ "attempt", `String attempt
        ; "operation", `String operation_file
        ; "results_path", `String results_file
        ; "results_sha256", `String results_digest
        ; "field", `String field_name
        ; "resolved_source", resolved_source
        ; "supplied", supplied
        ])
  in
  let project group key label unit_ signed integral =
    match field group results with
    | `Assoc fields ->
      Option.map (List.Assoc.find fields key ~equal:String.equal) ~f:(fun supplied ->
        let number =
          match field "value" supplied with
          | `Int n -> Some (Float.of_int n)
          | `Intlit s -> Float.of_string_opt s
          | `Float f -> Some f
          | _ -> None
        in
        let value =
          Option.filter number ~f:(fun f ->
            Float.is_finite f
            && (signed || Float.(f >= 0.))
            && ((not integral) || Float.equal (Float.round_down f) f)
            && Poly.equal (field "unit" supplied) (`String unit_)
            && supplied_null "unavailable_reason" supplied)
        in
        { Asic.Metric.key
        ; label
        ; value
        ; unit_ = supplied_string (field "unit" supplied)
        ; availability = (if Option.is_some value then "available" else "unavailable")
        ; source = Some (context (group ^ "." ^ key) supplied)
        })
    | _ -> None
  in
  let metrics =
    [ "setup_slack", "Setup slack", "ns", true, false
    ; "hold_slack", "Hold slack", "ns", true, false
    ; "mapped_area", "Mapped cell area", "um^2", false, false
    ; "sequential_area", "Sequential cell area", "um^2", false, false
    ; "mapped_cells", "Mapped cells", "cells", false, true
    ; "final_standard_cell_area", "Final standard-cell area", "um^2", false, false
    ; "final_utilization", "Final utilization", "fraction", false, false
    ]
    |> List.filter_map ~f:(fun (key, label, unit_, signed, integral) ->
      project "metrics" key label unit_ signed integral)
  in
  let metrics =
    metrics
    @ List.filter_map
        [ "unmapped_instances", "Unmapped instances"
        ; "synthesis_errors", "Synthesis errors"
        ; "inferred_latches", "Inferred latches"
        ]
        ~f:(fun (key, label) -> project "synthesis_checks" key label "count" false true)
  in
  let checks =
    List.map [ "drc"; "lvs"; "antenna" ] ~f:(fun name ->
      let supplied = field name (field "checks" results) in
      { Asic.Check.name
      ; status = verdict (field "status" supplied)
      ; reason =
          (match supplied with
           | `Null -> Some "not_recorded"
           | _ -> supplied_string (field "reason" supplied))
      ; source =
          (if Poly.equal supplied `Null
           then None
           else Some (context ("checks." ^ name) supplied))
      })
  in
  let evidence =
    Yojson.Safe.to_string (`Assoc [ "operation", receipt; "results", results ])
  in
  require
    (String.length evidence <= 160 * 1024)
    "Terminal evidence exceeds normalized budget";
  { attempt
  ; results_file
  ; results_digest
  ; operation_status
  ; physical_completion
  ; acceptance
  ; timing_goal = verdict (field "timing_goal" results)
  ; metrics
  ; checks
  ; evidence
  ; execution_timing = receipt_timing ~running:false receipt
  }
;;
