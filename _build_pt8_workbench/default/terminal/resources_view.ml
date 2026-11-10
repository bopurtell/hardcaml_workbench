open! Core
open Hardcaml_workbench_protocol
module R = Asic_resources
module E = Evidence_style

(** Pure resource investigation. Only [input] returns read intents. Reconciliation,
    rendering and filtering consume published facts and never initiate provider work. *)
type mode =
  | Table
  | Detail
  | Sources
  | Text
  | Context
  | Compare
[@@deriving equal]

type captured =
  { source : R.Source.t
  ; index : R.Index.t
  }

type t =
  { explicit : R.Target.t option
  ; target : R.Target.t option
  ; source : R.Source.t option
  ; index : R.Index.t option
  ; selected : string option
  ; mode : mode
  ; section : string
  ; offset : int
  ; history : int list
  ; catalog_offset : int
  ; catalog_history : int list
  ; artifact : string option
  ; byte_offset : int
  ; byte_history : int list
  ; scroll : int
  ; generation : int
  ; pending : string option
  ; request_floor : int option
  ; receipt_floor : int option
  ; loading_index : bool
  ; error : string option
  ; left : captured option
  ; right : captured option
  }

let empty =
  { explicit = None
  ; target = None
  ; source = None
  ; index = None
  ; selected = None
  ; mode = Table
  ; section = "inventory"
  ; offset = 0
  ; history = []
  ; catalog_offset = 0
  ; catalog_history = []
  ; artifact = None
  ; byte_offset = 0
  ; byte_history = []
  ; scroll = 0
  ; generation = 0
  ; pending = None
  ; request_floor = None
  ; receipt_floor = None
  ; loading_index = false
  ; error = None
  ; left = None
  ; right = None
  }
;;

let is_kind = function
  | "resources" | "resource-summary" -> true
  | _ -> false
;;

let sections =
  [ "inventory"; "synthesis"; "final"; "geometry"; "timing"; "electrical"; "provenance" ]
;;

let snapshot asic =
  Option.bind asic ~f:(fun s -> s.Asic.Snapshot.resources)
  |> Option.value ~default:R.Snapshot.empty
;;

let target_label = function
  | R.Target.Run run -> "Execution " ^ run.id
  | Workflow_bundle id -> "Workflow bundle " ^ id
  | Finalization { run; attempt } -> "Finalization " ^ run.id ^ " / " ^ attempt
  | Coarse_run path -> "Imported coarse evidence " ^ path
  | Bundle path -> "Emitted bundle " ^ path
;;

let freshness = function
  | R.Freshness.Validated -> E.Role.Validated, "Validated source"
  | Cached_unverified -> Pending, "CACHED UNVERIFIED"
  | Missing_source reason -> Stale, "Missing source: " ^ reason
  | Stale reason -> Stale, "STALE: " ^ reason
  | Refresh_failed reason -> Stale, "Refresh failed: " ^ reason
  | Unsupported reason -> Muted, "Unsupported: " ^ reason
;;

let source_for target snapshot =
  Option.bind target ~f:(fun target ->
    List.find snapshot.R.Snapshot.sources ~f:(fun s -> R.Target.equal s.target target))
;;

let clear_pages t =
  { t with
    mode = Table
  ; offset = 0
  ; history = []
  ; catalog_offset = 0
  ; catalog_history = []
  ; artifact = None
  ; byte_offset = 0
  ; byte_history = []
  ; scroll = 0
  ; pending = None
  ; request_floor = None
  ; receipt_floor = None
  ; loading_index = false
  ; error = None
  ; generation = t.generation + 1
  }
;;

let reconcile ?revision t ~run ~filter asic =
  let target =
    Option.first_some t.explicit (Option.map run ~f:(fun r -> R.Target.Run r))
  in
  let changed = not (Option.equal R.Target.equal t.target target) in
  let t =
    if changed
    then { (clear_pages t) with selected = None; source = None; index = None; target }
    else t
  in
  let published = snapshot asic in
  let source = source_for target published in
  let index =
    Option.bind source ~f:(fun s ->
      List.find published.indexes ~f:(fun i -> String.equal i.source_id s.id))
  in
  let changed_digest =
    match t.index, index with
    | Some a, Some b ->
      (not (R.Index.equal a b))
      || not
           (Option.equal
              String.equal
              (Option.map t.source ~f:(fun s -> s.R.Source.provider_identity))
              (Option.map source ~f:(fun s -> s.R.Source.provider_identity)))
    | Some _, None -> true
    | _ -> false
  in
  let t =
    if changed_digest
    then (
      let reset = clear_pages t in
      if t.loading_index && Option.is_some t.pending
      then
        { reset with
          generation = t.generation
        ; pending = t.pending
        ; request_floor = t.request_floor
        ; receipt_floor = t.receipt_floor
        ; loading_index = true
        }
      else reset)
    else t
  in
  let rows = Option.value_map index ~default:[] ~f:(fun i -> i.rows) in
  let selected =
    match t.selected with
    | Some id when List.exists rows ~f:(fun row -> String.equal row.id id) -> Some id
    | _ -> Option.map (List.hd rows) ~f:(fun row -> row.R.Row.id)
  in
  let error, pending =
    match t.pending, t.receipt_floor, revision, asic with
    | Some key, Some floor, Some revision, Some s
      when revision >= floor
           && Option.value_map t.request_floor ~default:false ~f:(fun issued ->
             revision >= issued) ->
      (match
         List.find s.Asic.Snapshot.operations ~f:(fun op -> String.equal op.key key)
       with
       | Some op when String.equal op.state "failed" || Option.is_some op.error ->
         Some (Option.value op.error ~default:"Resource read failed"), None
       | Some op when String.equal op.state "completed" -> None, None
       | _ -> t.error, t.pending)
    | _ -> t.error, t.pending
  in
  ignore (filter : string);
  { t with target; source; index; selected; error; pending }
;;

let select_target t explicit =
  { (clear_pages t) with
    explicit
  ; target = None
  ; source = None
  ; index = None
  ; selected = None
  }
;;

let reconnect t =
  let unverified (s : R.Source.t) = { s with freshness = Cached_unverified } in
  let captured =
    Option.map ~f:(fun (c : captured) -> { c with source = unverified c.source })
  in
  { t with
    generation = t.generation + 1
  ; pending = None
  ; request_floor = None
  ; receipt_floor = None
  ; loading_index = false
  ; error = None
  ; source = Option.map t.source ~f:unverified
  ; left = captured t.left
  ; right = captured t.right
  }
;;

let visible t ~filter =
  Option.value_map t.index ~default:[] ~f:(fun i ->
    List.filter i.rows ~f:(fun row ->
      String.is_substring
        (String.lowercase
           (String.concat
              ~sep:" "
              [ row.id
              ; row.contract
              ; row.policy
              ; row.implementation
              ; row.reason
              ; row.role
              ]))
        ~substring:(String.lowercase filter)))
;;

let selected_row t =
  Option.bind t.index ~f:(fun i ->
    List.find i.rows ~f:(fun row -> Option.equal String.equal t.selected (Some row.id)))
;;

let current_detail t asic =
  Option.bind t.index ~f:(fun index ->
    List.find (snapshot asic).details ~f:(fun p ->
      String.equal p.source_id index.source_id
      && String.equal p.digest index.digest
      && Option.equal String.equal t.selected (Some p.resource_id)
      && String.equal p.section t.section
      && p.offset = t.offset))
;;

let current_catalog t asic =
  Option.bind t.index ~f:(fun index ->
    List.find (snapshot asic).artifacts ~f:(fun p ->
      String.equal p.source_id index.source_id
      && String.equal p.digest index.digest
      && p.offset = t.catalog_offset))
;;

let current_bytes t asic =
  Option.bind t.index ~f:(fun index ->
    List.find (snapshot asic).bytes ~f:(fun p ->
      String.equal p.source_id index.source_id
      && String.equal p.digest index.digest
      && Option.equal String.equal t.artifact (Some p.artifact_id)
      && p.offset = t.byte_offset))
;;

let page_operation t =
  Option.bind t.index ~f:(fun i ->
    let source_id = i.source_id
    and expected_digest = i.digest in
    match t.mode with
    | Detail ->
      Option.map t.selected ~f:(fun resource_id ->
        R.Operation.Detail
          { source_id
          ; expected_digest
          ; resource_id
          ; section = t.section
          ; offset = t.offset
          ; limit = 8
          })
    | Sources ->
      Some
        (R.Operation.Artifacts
           { source_id; expected_digest; offset = t.catalog_offset; limit = 16 })
    | Text ->
      Option.map t.artifact ~f:(fun artifact_id ->
        R.Operation.Read_artifact
          { source_id
          ; expected_digest
          ; artifact_id
          ; offset = t.byte_offset
          ; limit = 4096
          })
    | Table | Context | Compare -> None)
;;

type input =
  | Move of int
  | Open
  | Back
  | Refresh
  | Show_table
  | Show_sources
  | Show_context
  | Section of string
  | Next_page
  | Previous_page
  | Capture_left
  | Capture_right
  | Show_compare
  | Swap_compare
  | Scroll of int

let begin_request t operation =
  ( { t with
      pending = Some (R.Operation.key operation)
    ; request_floor = None
    ; receipt_floor = None
    ; loading_index =
        (match operation with
         | Load _ -> true
         | _ -> false)
    ; error = None
    ; generation = t.generation + 1
    }
  , Some operation )
;;

let input t ~filter ~asic event =
  let request t =
    match page_operation t with
    | None -> t, None
    | Some op -> begin_request t op
  in
  let move ids selected delta =
    let index =
      Option.bind selected ~f:(fun id ->
        List.findi ids ~f:(fun _ x -> String.equal id x) |> Option.map ~f:fst)
      |> Option.value ~default:(if delta > 0 then -1 else 1)
    in
    List.nth ids (Int.max 0 (Int.min (List.length ids - 1) (index + delta)))
  in
  match event with
  | Refresh ->
    (match t.target with
     | None ->
       ( { t with
           error = Some "No exact source selected; select a run, workflow or import"
         }
       , None )
     | Some target -> begin_request t (Load { target; refresh = true }))
  | Show_table ->
    ( { t with mode = Table; scroll = 0; pending = None; generation = t.generation + 1 }
    , None )
  | Show_context ->
    ( { t with mode = Context; scroll = 0; pending = None; generation = t.generation + 1 }
    , None )
  | Show_sources -> request { t with mode = Sources; scroll = 0 }
  | Section section ->
    if List.mem sections section ~equal:String.equal
    then (
      let candidates = visible t ~filter in
      let selected =
        if List.exists candidates ~f:(fun r ->
             Option.equal String.equal t.selected (Some r.R.Row.id))
        then t.selected
        else Option.map (List.hd candidates) ~f:(fun r -> r.R.Row.id)
      in
      if Option.is_none selected
      then { t with error = Some "No resource matches the filter" }, None
      else
        request
          { t with
            mode = Detail
          ; selected
          ; section
          ; offset = 0
          ; history = []
          ; scroll = 0
          })
    else { t with error = Some "Unknown resource section" }, None
  | Back ->
    ( { t with
        mode = (if equal_mode t.mode Text then Sources else Table)
      ; scroll = 0
      ; pending = None
      ; generation = t.generation + 1
      }
    , None )
  | Scroll delta -> { t with scroll = Int.max 0 (t.scroll + delta) }, None
  | Move delta when equal_mode t.mode Table ->
    ( { t with
        selected =
          move (List.map (visible t ~filter) ~f:(fun r -> r.R.Row.id)) t.selected delta
      ; scroll = 0
      ; offset = 0
      ; history = []
      ; pending = None
      ; generation = t.generation + 1
      }
    , None )
  | Move delta when equal_mode t.mode Sources ->
    let ids =
      Option.value_map (current_catalog t asic) ~default:[] ~f:(fun p ->
        List.map p.entries ~f:(fun a -> a.R.Artifact.id))
    in
    ( { t with
        artifact = move ids (Option.first_some t.artifact (List.hd ids)) delta
      ; scroll = 0
      ; pending = None
      ; generation = t.generation + 1
      }
    , None )
  | Move delta -> { t with scroll = Int.max 0 (t.scroll + delta) }, None
  | Open when equal_mode t.mode Sources ->
    let artifact =
      Option.first_some
        t.artifact
        (Option.bind (current_catalog t asic) ~f:(fun p ->
           Option.map (List.hd p.entries) ~f:(fun a -> a.R.Artifact.id)))
    in
    request
      { t with mode = Text; artifact; byte_offset = 0; byte_history = []; scroll = 0 }
  | Open when equal_mode t.mode Table ->
    let rows = visible t ~filter in
    let selected =
      if List.exists rows ~f:(fun r -> Option.equal String.equal t.selected (Some r.id))
      then t.selected
      else Option.map (List.hd rows) ~f:(fun r -> r.R.Row.id)
    in
    if Option.is_none selected
    then { t with error = Some "No resource matches the filter" }, None
    else request { t with mode = Detail; selected; offset = 0; history = []; scroll = 0 }
  | Open -> t, None
  | Capture_left | Capture_right ->
    (match t.source, t.index with
     | Some source, Some index ->
       let captured = Some { source; index } in
       ( (match event with
          | Capture_left -> { t with left = captured }
          | _ -> { t with right = captured })
       , None )
     | _ ->
       { t with error = Some "Load an exact source before capturing comparison" }, None)
  | Show_compare ->
    ( { t with mode = Compare; scroll = 0; pending = None; generation = t.generation + 1 }
    , None )
  | Swap_compare ->
    ( { t with
        left = t.right
      ; right = t.left
      ; scroll = 0
      ; pending = None
      ; generation = t.generation + 1
      }
    , None )
  | Next_page | Previous_page ->
    let next offset history next total =
      match event with
      | Previous_page ->
        (match history with
         | [] -> offset, history
         | previous :: rest -> previous, rest)
      | _ ->
        if next < total && next > offset then next, offset :: history else offset, history
    in
    let t =
      match t.mode with
      | Detail ->
        Option.value_map (current_detail t asic) ~default:t ~f:(fun p ->
          let offset, history = next t.offset t.history p.next_offset p.total in
          { t with offset; history; scroll = 0 })
      | Sources ->
        Option.value_map (current_catalog t asic) ~default:t ~f:(fun p ->
          let catalog_offset, catalog_history =
            next t.catalog_offset t.catalog_history p.next_offset p.total
          in
          { t with catalog_offset; catalog_history; artifact = None; scroll = 0 })
      | Text ->
        Option.value_map (current_bytes t asic) ~default:t ~f:(fun p ->
          let byte_offset, byte_history =
            next t.byte_offset t.byte_history p.next_offset p.total
          in
          { t with byte_offset; byte_history; scroll = 0 })
      | Table | Context | Compare -> t
    in
    request t
;;

let admit t ~generation ~request_floor =
  if generation <> t.generation || Option.is_none t.pending
  then t
  else { t with request_floor = Some request_floor; receipt_floor = None }
;;

let receipt ?(floor = 0) t ~generation result =
  if generation <> t.generation
  then t
  else (
    match result with
    | Ok () -> { t with error = None; receipt_floor = Some floor }
    | Error error -> { t with pending = None; error = Some error })
;;

let fact label value = E.plain (label ^ ": " ^ value)
let missing text = [ { E.text; role = E.Role.Muted } ]
let number value = sprintf "%.12g" value

let classification (m : R.Measurement.t) =
  match m.classification with
  | Observed -> "observed"
  | Derived -> "derived (source-qualified)"
  | Estimate -> "estimate"
  | Unknown -> "unknown classification"
;;

let measurement (m : R.Measurement.t) =
  fact
    m.name
    (Option.value_map
       m.value
       ~default:
         ("unavailable" ^ Option.value_map m.reason ~default:"" ~f:(fun s -> " — " ^ s))
       ~f:number
     ^ " "
     ^ m.unit_
     ^ " · stage="
     ^ m.stage
     ^ " · scope="
     ^ m.scope
     ^ " · "
     ^ m.definition
     ^ " · "
     ^ classification m)
;;

let inventory (i : R.Index.t) =
  match i.inventory_status with
  | Available ->
    if List.is_empty i.rows
    then "0 resources (verified empty inventory)"
    else sprintf "%d resources (available inventory)" (List.length i.rows)
  | Unavailable ->
    "inventory unavailable — "
    ^ Option.value i.inventory_reason ~default:"reason not supplied"
  | Unknown ->
    "inventory unknown — "
    ^ Option.value
        i.inventory_reason
        ~default:"legacy/incomplete availability information"
;;

let row_facts (r : R.Row.t) =
  [ fact "Resource" r.id
  ; fact "Requested contract" r.contract
  ; fact "Requirement / policy" (r.requirement ^ " / " ^ r.policy)
  ; fact "Selected implementation" r.implementation
  ; fact "Selection reason" r.reason
  ; fact "Actual role" r.role
  ; fact "Elaborated instances" (String.concat ~sep:", " r.instances)
  ; fact "Realized synthesis / final" (r.synthesis ^ " / " ^ r.final)
  ]
  @
  if String.equal r.role "behavioral_model"
  then [ missing "Behavioral/simulation elaboration is not physical realization" ]
  else []
;;

let capture_lines name (captured : captured option) =
  match captured with
  | None -> [ missing (name ^ ": not captured — capture an explicitly loaded source") ]
  | Some c ->
    let role, text = freshness c.source.freshness in
    [ fact name (target_label c.source.target)
    ; fact (name ^ " digest") c.index.digest
    ; fact (name ^ " source") c.source.path
    ; fact (name ^ " resource verdict") c.index.verdict
    ; fact (name ^ " inventory") (inventory c.index)
    ; fact
        (name ^ " coverage")
        (if c.index.truncated then "TRUNCATED" else "complete retained projection")
    ; [ { E.text = name ^ " " ^ text; role } ]
    ]
;;

let compare_measurements a b =
  let supplied side (m : R.Measurement.t) =
    side
    ^ "="
    ^
    match m.value with
    | None -> "unavailable — " ^ Option.value m.reason ~default:"not reported"
    | Some value when not (Float.is_finite value) -> "nonfinite"
    | Some value -> number value ^ " " ^ m.unit_
  in
  List.map a ~f:(fun (a : R.Measurement.t) ->
    match List.find b ~f:(R.Measurement.compatible a) with
    | None ->
      fact
        a.name
        (supplied "A" a
         ^ "; B missing or incompatible name/stage/unit/definition/scope/classification; \
            no delta")
    | Some b ->
      (match a.value, b.value with
       | None, _ | _, None ->
         fact
           a.name
           (supplied "A" a ^ "; " ^ supplied "B" b ^ "; unavailable measurement; no delta")
       | Some av, Some bv when not (Float.is_finite av && Float.is_finite bv) ->
         fact
           a.name
           (supplied "A" a ^ "; " ^ supplied "B" b ^ "; nonfinite measurement; no delta")
       | _ when not (R.Measurement.is_measured a && R.Measurement.is_measured b) ->
         fact
           a.name
           (supplied "A" a
            ^ "; "
            ^ supplied "B" b
            ^ " · "
            ^ classification a
            ^ "; no measured delta")
       | Some av, Some bv
         when Float.is_finite av && Float.is_finite bv && Float.is_finite (bv -. av) ->
         fact
           a.name
           (sprintf
              "A=%s B=%s Δ(B−A)=%s %s · %s · %s · %s · %s"
              (number av)
              (number bv)
              (number (bv -. av))
              a.unit_
              a.stage
              a.scope
              a.definition
              (classification a))
       | _ -> fact a.name "measurement subtraction overflow; no delta"))
  @ List.filter_map b ~f:(fun b ->
    if List.exists a ~f:(R.Measurement.compatible b)
    then None
    else
      Some
        (fact
           b.R.Measurement.name
           (supplied "B" b ^ "; A missing or incompatible measurement; no delta")))
;;

let compare_lines t =
  capture_lines "A" t.left
  @ capture_lines "B" t.right
  @
  match t.left, t.right with
  | Some a, Some b ->
    [ missing
        "Only finite observed or source-qualified derived measurements with identical \
         name/stage/unit/definition/scope/classification have deltas; no best-result \
         verdict"
    ]
    @ compare_measurements a.index.measurements b.index.measurements
    @ List.concat_map a.index.rows ~f:(fun row ->
      match List.find b.index.rows ~f:(fun r -> String.equal r.id row.id) with
      | None -> [ fact row.id "A-only resource; B unavailable" ]
      | Some other ->
        [ fact "Resource" row.id
        ; fact "Contract A / B" (row.contract ^ " / " ^ other.contract)
        ; fact "Requirement A / B" (row.requirement ^ " / " ^ other.requirement)
        ; fact "Policy A / B" (row.policy ^ " / " ^ other.policy)
        ; fact "Selection A / B" (row.implementation ^ " / " ^ other.implementation)
        ; fact "Reason A / B" (row.reason ^ " / " ^ other.reason)
        ; fact "Role A / B" (row.role ^ " / " ^ other.role)
        ; fact "Synthesis A / B" (row.synthesis ^ " / " ^ other.synthesis)
        ; fact "Final A / B" (row.final ^ " / " ^ other.final)
        ]
        @ compare_measurements row.measurements other.measurements)
    @ List.filter_map b.index.rows ~f:(fun row ->
      if List.exists a.index.rows ~f:(fun r -> String.equal r.id row.id)
      then None
      else Some (fact row.id "B-only resource; A unavailable"))
  | _ -> []
;;

let source_lines t =
  [ fact
      "Scope"
      (Option.value_map
         t.target
         ~default:"No selected run or explicit source"
         ~f:target_label)
  ; fact
      "Binding"
      (if Option.is_some t.explicit
       then "Explicit source (independent of Main)"
       else "Exact run follow/pin")
  ]
  @ Option.value_map t.source ~default:[] ~f:(fun source ->
    let role, text = freshness source.freshness in
    [ [ { E.text; role } ] ]
    @ Option.to_list (Option.map source.error ~f:(fact "Source error")))
  @ Option.value_map t.pending ~default:[] ~f:(fun _ ->
    [ missing "Read requested (retained evidence only)" ])
  @ Option.value_map t.error ~default:[] ~f:(fun text ->
    [ [ { E.text = "Read error: " ^ text; role = E.Role.Stale } ] ])
  @ Option.value_map t.index ~default:[] ~f:(fun i ->
    fact "Inventory" (inventory i)
    ::
    (if i.truncated
     then
       [ [ { E.text =
               "TRUNCATED index: provider reports an incomplete projection; inspect \
                original sources"
           ; role = E.Role.Stale
           }
         ]
       ]
     else []))
;;

let execution_lines t asic =
  let run_status run =
    [ fact
        "Execution status"
        (Option.bind asic ~f:(fun s ->
           List.find s.Asic.Snapshot.runs ~f:(fun r -> Run_ref.equal r.run run))
         |> Option.value_map
              ~default:"unavailable (no exact execution observation loaded)"
              ~f:(fun r -> r.status))
    ]
  in
  match t.target with
  | Some (R.Target.Run run) -> run_status run
  | Some (Finalization { run; attempt }) ->
    run_status run
    @ [ fact
          "Finalization status"
          (Option.bind asic ~f:(fun s ->
             List.find s.Asic.Snapshot.finalizations ~f:(fun f ->
               Run_ref.equal f.run run
               && Option.equal String.equal f.attempt (Some attempt)))
           |> Option.value_map
                ~default:"unavailable (inspect exact retained provenance)"
                ~f:(fun f -> f.state))
      ]
  | Some (Workflow_bundle id) ->
    [ fact
        "Workflow elaboration status"
        (Option.bind asic ~f:(fun s ->
           List.find s.Asic.Snapshot.workflows ~f:(fun w -> String.equal w.id id))
         |> Option.value_map
              ~default:"unavailable (no exact workflow observation loaded)"
              ~f:(fun w -> w.elaboration_status))
    ]
  | Some (Bundle _) ->
    [ fact "Execution association" "bundle inventory only; no execution selected" ]
  | Some (Coarse_run _) ->
    [ fact
        "Execution status"
        "retained coarse source; original lifecycle in provenance (not a named run)"
    ]
  | None -> []
;;

let summary t =
  Option.value_map
    t.index
    ~default:[ missing "Resources: inspect / import (Enter)" ]
    ~f:(fun i ->
      let role, _ =
        Option.value_map t.source ~default:(E.Role.Muted, "unavailable") ~f:(fun s ->
          freshness s.freshness)
      in
      let compact_status =
        match t.source with
        | None -> "source unavailable"
        | Some s ->
          (match s.freshness with
           | Validated -> "validated"
           | Cached_unverified -> "cached-unverified"
           | Missing_source _ -> "source missing"
           | Stale _ -> "stale"
           | Refresh_failed _ -> "refresh failed"
           | Unsupported _ -> "unsupported")
      in
      let compact_inventory =
        match i.inventory_status with
        | Available ->
          if List.is_empty i.rows
          then "0 (verified empty)"
          else sprintf "%d resources" (List.length i.rows)
        | Unavailable -> "inventory unavailable"
        | Unknown -> "inventory unknown"
      in
      [ [ { E.text =
              sprintf
                "Resources%s: %s · %s · %s · Enter"
                (if i.truncated then " TRUNCATED" else "")
                compact_inventory
                compact_status
                i.verdict
          ; role = (if i.truncated then E.Role.Stale else role)
          }
        ]
      ])
  @ source_lines t
;;

let comparison_validation t asic =
  List.concat_map
    [ "A", t.left; "B", t.right ]
    ~f:(fun (side, captured) ->
      Option.value_map captured ~default:[] ~f:(fun (c : captured) ->
        match
          ( List.find (snapshot asic).sources ~f:(fun s -> String.equal s.id c.source.id)
          , List.find (snapshot asic).indexes ~f:(fun i ->
              String.equal i.source_id c.source.id) )
        with
        | Some source, Some index
          when R.Index.equal index c.index
               && String.equal source.provider_identity c.source.provider_identity
               && R.Target.equal source.target c.source.target
               && String.equal source.kind c.source.kind
               && String.equal source.path c.source.path ->
          let role, text = freshness source.freshness in
          [ [ { E.text = side ^ " current source: " ^ text; role } ] ]
        | _ ->
          [ missing
              (side
               ^ " captured provider/projection is no longer the loaded observation; \
                  retained capture only, not revalidated")
          ]))
;;

let contents t ~filter ~asic =
  let lines =
    match t.mode with
    | Compare -> comparison_validation t asic @ compare_lines t
    | Context ->
      Option.value_map t.source ~default:[] ~f:(fun s ->
        [ fact "Source ID" s.id
        ; fact "Provider kind" s.kind
        ; fact "Source path" s.path
        ; fact "Provider identity" s.provider_identity
        ])
      @ Option.value_map t.index ~default:[] ~f:(fun i ->
        [ fact "Source digest" i.digest
        ; fact "Full provenance" i.provenance
        ; fact
            "Index coverage"
            (if i.truncated then "TRUNCATED" else "Complete retained projection")
        ]
        @ List.map i.diagnostics ~f:(fact "Diagnostic")
        @ List.map i.measurements ~f:measurement)
    | Table ->
      let rows = visible t ~filter in
      [ fact
          "Filter"
          (sprintf
             "%s · %d matches"
             (if String.is_empty filter then "(none)" else filter)
             (List.length rows))
      ; E.plain "Resource | selected implementation | actual role | synthesis | final"
      ]
      @ List.map rows ~f:(fun r ->
        E.plain
          (sprintf
             "%s%s | %s | %s | %s | %s"
             (if Option.equal String.equal t.selected (Some r.id) then "> " else "  ")
             r.id
             r.implementation
             r.role
             r.synthesis
             r.final))
      @ (if List.is_empty rows
         then
           [ missing
               "No matching resources (empty inventory is distinct from unreadable \
                evidence)"
           ]
         else [])
      @ Option.value_map
          (List.find rows ~f:(fun r ->
             Option.equal String.equal t.selected (Some r.R.Row.id)))
          ~default:
            [ missing
                "Selected resource is outside this filter; Enter selects the first match"
            ]
          ~f:row_facts
    | Detail ->
      Option.value_map
        (selected_row t)
        ~default:[ missing "No resource selected" ]
        ~f:(fun r ->
          if String.equal t.section "inventory"
          then row_facts r
          else
            [ fact "Resource" r.id
            ; fact "Selected implementation" r.implementation
            ; fact "Selection reason" r.reason
            ; fact "Actual role" r.role
            ; fact "Realized synthesis / final" (r.synthesis ^ " / " ^ r.final)
            ])
      @ [ fact "Detail section" t.section ]
      @ Option.value_map
          (current_detail t asic)
          ~default:[ missing "Section page not loaded — choose section / n or p to read" ]
          ~f:(fun p ->
            [ fact
                "Page items"
                (sprintf "%d–%d / %d (n/p pages)" p.offset p.next_offset p.total)
            ]
            @ List.concat_map p.items ~f:(fun item ->
              E.plain ("— " ^ item.R.Item.title)
              :: List.map item.fields ~f:(fun (key, value) -> fact key value)))
      @ Option.value_map (selected_row t) ~default:[] ~f:(fun r ->
        List.map r.measurements ~f:measurement
        @ [ fact
              "Sections"
              (String.concat
                 ~sep:" · "
                 (List.map r.sections ~f:(fun s ->
                    sprintf "%s=%s(%d)" s.R.Section.id s.status s.count)))
          ])
    | Sources ->
      Option.value_map
        (current_catalog t asic)
        ~default:[ missing "Source catalog page not loaded — a loads authorized sources" ]
        ~f:(fun p ->
          [ fact
              "Source references"
              (sprintf
                 "%d–%d / %d · n/p pages; j/k select; Enter reads bytes"
                 p.offset
                 p.next_offset
                 p.total)
          ]
          @ List.map p.entries ~f:(fun a ->
            E.plain
              ((if Option.equal String.equal t.artifact (Some a.R.Artifact.id)
                then "> "
                else "  ")
               ^ a.label
               ^ " · "
               ^ a.format
               ^ " · "
               ^ a.id
               ^ " · sha256="
               ^ a.sha256)))
    | Text ->
      Option.value_map
        (current_bytes t asic)
        ~default:
          [ missing
              "Authorized source bytes unavailable or not retained; n/p reads exact pages"
          ]
        ~f:(fun p ->
          let text =
            Or_error.try_with (fun () ->
              Cryptokit.transform_string (Cryptokit.Hexa.decode ()) p.bytes_hex)
          in
          [ fact "Artifact" p.artifact_id
          ; fact "SHA256" p.sha256
          ; fact
              "Byte span"
              (sprintf
                 "%d–%d / %d (n/p pages; chunk boundaries may split text)"
                 p.offset
                 p.next_offset
                 p.total)
          ]
          @
          match text with
          | Error _ -> [ missing "Invalid byte transport" ]
          | Ok text ->
            List.map (String.split_lines text) ~f:(fun line ->
              E.plain (Artifact_view.safe line)))
  in
  [ missing
      "j/k browse/scroll · Enter detail/read · Esc back · / filter · Ctrl-U clear · r \
       refresh · a sources · d provenance · g/t/e geometry/timing/electrical · n/p pages \
       · c compare · Space c c commands"
  ]
  @ (if equal_mode t.mode Compare
     then []
     else
       source_lines t
       @ execution_lines t asic
       @ Option.value_map t.index ~default:[] ~f:(fun i ->
         [ fact "Resource verdict" i.verdict ]
         @ List.map i.diagnostics ~f:(fact "Qualification")))
  @ lines
;;

let rows t ~filter ~asic ~width ~height =
  let lines =
    if equal_mode t.mode Table
    then (
      let candidates = visible t ~filter in
      let selected =
        Option.bind t.selected ~f:(fun id ->
          List.findi candidates ~f:(fun _ r -> String.equal r.id id) |> Option.map ~f:fst)
        |> Option.value ~default:0
      in
      let capacity = Int.max 1 (height / 3) in
      let start = Int.max 0 (selected - capacity + 1) in
      let entries = List.drop candidates start |> Fn.flip List.take capacity in
      [ missing
          "Enter detail · / filter · Ctrl-U clear · r refresh · a sources · g/t/e \
           geometry/timing/electrical · Space c c imports/select/compare"
      ]
      @ List.map (source_lines t) ~f:(E.clip ~width)
      @ List.map (execution_lines t asic) ~f:(E.clip ~width)
      @ [ fact
            "Filter"
            (sprintf
               "%s · %d matching retained rows"
               (if String.is_empty filter then "(none)" else filter)
               (List.length candidates))
        ; E.plain "Resource | implementation | actual role | synthesis | final"
        ]
      @ List.map entries ~f:(fun r ->
        E.plain
          (sprintf
             "%s%s | %s | %s | %s | %s"
             (if Option.equal String.equal t.selected (Some r.R.Row.id)
              then "> "
              else "  ")
             r.id
             r.implementation
             r.role
             r.synthesis
             r.final)
        |> E.clip ~width)
      @ (if Option.is_none t.index
         then
           [ missing
               "No loaded resource index — r loads the selected run; palette \
                selects/imports a source"
           ]
         else if List.is_empty candidates
         then (
           match t.index with
           | Some i when not (R.Inventory_status.equal i.inventory_status Available) ->
             [ missing (inventory i) ]
           | Some i when List.is_empty i.rows ->
             [ E.plain "Verified empty resource inventory" ]
           | _ -> [ missing "No resource matches this filter in the available inventory" ])
         else [])
      @ Option.value_map
          (List.find candidates ~f:(fun r ->
             Option.equal String.equal t.selected (Some r.R.Row.id)))
          ~default:
            (if List.is_empty candidates
             then []
             else
               [ missing
                   "Selected resource is outside this filter; Enter selects the first \
                    match"
               ])
          ~f:row_facts
      @ Option.value_map t.index ~default:[] ~f:(fun i ->
        [ fact "Resource verdict" i.verdict ]
        @ List.map i.diagnostics ~f:(fact "Qualification")))
    else if equal_mode t.mode Sources
    then (
      let page = current_catalog t asic in
      let entries = Option.value_map page ~default:[] ~f:(fun p -> p.entries) in
      let position =
        Option.bind t.artifact ~f:(fun id ->
          List.findi entries ~f:(fun _ a -> String.equal id a.R.Artifact.id)
          |> Option.map ~f:fst)
        |> Option.value ~default:0
      in
      let capacity = Int.max 1 (height / 3) in
      let start = Int.max 0 (position - capacity + 1) in
      [ missing
          "j/k select · Enter read text · n/p catalog pages · Esc table · [/] scroll \
           metadata"
      ]
      @ List.map (source_lines t) ~f:(E.clip ~width)
      @ List.map (execution_lines t asic) ~f:(E.clip ~width)
      @ Option.value_map
          page
          ~default:[ missing "Catalog page unavailable — a loads authorized sources" ]
          ~f:(fun p ->
            [ fact
                "Source references"
                (sprintf "%d–%d / %d" p.offset p.next_offset p.total)
            ])
      @ (List.drop entries start
         |> Fn.flip List.take capacity
         |> List.mapi ~f:(fun n a ->
           E.plain
             ((if start + n = position then "> " else "  ")
              ^ a.R.Artifact.label
              ^ " · "
              ^ a.format)
           |> E.clip ~width))
      @ Option.value_map (List.nth entries position) ~default:[] ~f:(fun artifact ->
        [ fact "Selected source" artifact.label
        ; fact "Opaque ID" artifact.id
        ; fact "Format" artifact.format
        ; fact "SHA256" artifact.sha256
        ]))
    else contents t ~filter ~asic
  in
  let scroll = if equal_mode t.mode Table then 0 else t.scroll in
  let wrapped = List.concat_map lines ~f:(E.wrap ~width) in
  let offset = Int.min scroll (Int.max 0 (List.length wrapped - height)) in
  List.drop wrapped offset |> Fn.flip List.take (Int.max 0 height)
;;
