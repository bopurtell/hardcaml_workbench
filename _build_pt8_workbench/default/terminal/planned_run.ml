open! Core
open Hardcaml_workbench_protocol

type status =
  | Empty
  | Pending
  | Failed
  | Stale
  | Ready
[@@deriving equal, sexp]

type model =
  { status : status
  ; selection : Asic.Selection.t option
  ; preview : Asic.Preview.t option
  ; requested : Asic.Selection.t option
  ; operation_key : string option
  ; message : string
  ; launch : launch
  ; launch_preview : Asic.Preview.t option
  }

and launch =
  { key : string option
  ; run_id : string option
  ; state : launch_status
  ; message : string
  }

and launch_status =
  | Submitting
  | Allocated
  | Running
  | Completed
  | Launch_failed
  | Cancelled
  | Detached
  | Unavailable
[@@deriving equal, sexp]

type role =
  | Fact
  | Muted
  | Warning
  | Error
  | Success
[@@deriving equal, sexp]

type row =
  { role : role
  ; text : string
  }

type ticket =
  { scope : string
  ; generation : int
  }

type intent =
  { selection : Asic.Selection.t
  ; key : string
  ; acknowledged : bool
  ; floor : int
  ; error : string option
  ; fresh_receipt : Asic.Fresh.Intent.t option
  }

type t =
  { scope : string
  ; generation : int
  ; revision : int
  ; intent : intent option
  ; snapshot : Asic.Snapshot.t option
  ; launch_generation : int
  ; launch_intent : launch_intent option
  ; fresh_mode : bool
  ; elaboration_only : bool
  }

and launch_intent =
  { preview : Asic.Preview.t
  ; fresh_input : Asic.Fresh.Intent.t option
  ; key : string
  ; acknowledged : bool
  ; floor : int
  ; error : string option
  }

type launch_ticket =
  { launch_scope : string
  ; launch_generation : int
  }

let empty =
  { scope = ""
  ; generation = 0
  ; revision = -1
  ; intent = None
  ; snapshot = None
  ; launch_generation = 0
  ; launch_intent = None
  ; fresh_mode = false
  ; elaboration_only = false
  }
;;

let reset t ~scope =
  if String.equal scope t.scope
  then t
  else
    { empty with
      scope
    ; generation = t.generation + 1
    ; launch_generation = t.launch_generation + 1
    }
;;

let begin_launch (t : t) ~key preview =
  let launch_generation = t.launch_generation + 1 in
  ( { t with
      launch_generation
    ; launch_intent =
        Some
          { preview
          ; fresh_input = None
          ; key
          ; acknowledged = false
          ; floor = Int.max_value
          ; error = None
          }
    }
  , { launch_scope = t.scope; launch_generation } )
;;

let launch_receipt (t : t) ticket ~floor result =
  if (not (String.equal t.scope ticket.launch_scope))
     || t.launch_generation <> ticket.launch_generation
  then t
  else
    { t with
      launch_intent =
        Option.map t.launch_intent ~f:(fun i ->
          { i with acknowledged = true; floor; error = Result.error result })
    }
;;

let key selection = List.hd_exn (Plain_rpc.keys (Plan selection) Fs0_fixture.snapshot)

let begin_plan t selection =
  let generation = t.generation + 1 in
  ( { t with
      generation
    ; intent =
        Some
          { selection
          ; key = key selection
          ; acknowledged = false
          ; floor = Int.max_value
          ; error = None
          ; fresh_receipt = None
          }
    }
  , { scope = t.scope; generation } )
;;

let begin_fresh t ~elaboration_only selection =
  let t, ticket = begin_plan t selection in
  { t with fresh_mode = true; elaboration_only }, ticket
;;

let fresh_preview (i : Asic.Fresh.Intent.t) : Asic.Preview.t =
  { selection = i.selection; plan_identity = i.id; plan_json = "" }
;;

let begin_fresh_launch t ~key intent =
  let t, ticket = begin_launch t ~key (fresh_preview intent) in
  ( { t with
      launch_intent =
        Option.map t.launch_intent ~f:(fun i -> { i with fresh_input = Some intent })
    }
  , ticket )
;;

let workflow_active (w : Asic.Fresh.Workflow.t) =
  match w.phase with
  | Reserved | Building | Emitting | Prepared | Physical -> true
  | Completed | Failed | Cancelled | Interrupted -> false
;;

let shared_fresh_intent t = Option.bind t.snapshot ~f:(fun s -> s.fresh_intent)

let fresh_intent t =
  if t.fresh_mode
  then Option.bind t.intent ~f:(fun i -> i.fresh_receipt)
  else shared_fresh_intent t
;;

let workflow t =
  Option.bind t.snapshot ~f:(fun s ->
    match t.launch_intent with
    | Some i -> List.find s.workflows ~f:(fun w -> String.equal w.key i.key)
    | None -> List.hd s.workflows)
;;

let same_generation t (ticket : ticket) =
  String.equal t.scope ticket.scope && t.generation = ticket.generation
;;

let current_ticket t ticket = same_generation t ticket && Option.is_some t.intent

let receipt t ticket ~floor result =
  if not (current_ticket t ticket)
  then t
  else
    { t with
      intent =
        Option.map t.intent ~f:(fun i ->
          { i with acknowledged = true; floor; error = Result.error result })
    }
;;

let fresh_receipt t ticket ~floor result =
  if not (current_ticket t ticket)
  then t
  else (
    let result =
      Result.bind result ~f:(fun (received : Asic.Fresh.Intent.t) ->
        let requested = Option.value_exn t.intent in
        if Asic.Selection.equal requested.selection received.selection
           && Bool.equal t.elaboration_only received.elaboration_only
        then Ok received
        else Error "Staging receipt does not match requested fresh inputs")
    in
    { t with
      intent =
        Option.map t.intent ~f:(fun i ->
          { i with
            acknowledged = true
          ; floor
          ; error = Result.error result
          ; fresh_receipt = Result.ok result
          })
    })
;;

let receive t ~revision snapshot =
  if revision < t.revision
  then t
  else (
    let intent =
      Option.filter t.intent ~f:(fun i ->
        not
          ((not t.fresh_mode)
           && i.acknowledged
           && Option.is_none i.error
           && revision >= i.floor
           && Option.exists snapshot.Asic.Snapshot.preview ~f:(fun p ->
             Asic.Selection.equal p.selection i.selection)
           && List.exists snapshot.operations ~f:(fun op ->
             String.equal op.key i.key && String.equal op.state "completed")
           && not
                (List.exists snapshot.operations ~f:(fun op ->
                   String.equal op.kind "plan" && Plain_rpc.active op))))
    in
    let launch_intent =
      Option.filter t.launch_intent ~f:(fun i ->
        let superseded_before_reservation =
          t.fresh_mode
          && i.acknowledged
          && Option.is_some i.error
          && Option.exists intent ~f:(fun staged ->
            staged.acknowledged
            && Option.is_none staged.error
            && revision >= staged.floor
            && Option.exists staged.fresh_receipt ~f:(fun received ->
              Option.exists i.fresh_input ~f:(fun prior ->
                not (String.equal received.id prior.id))
              && Option.exists
                   snapshot.Asic.Snapshot.fresh_intent
                   ~f:(Asic.Fresh.Intent.equal received)))
          && not (List.exists snapshot.workflows ~f:(fun w -> String.equal w.key i.key))
        in
        (* A new successful Stage_fresh supersedes the old intent before the daemon's
           reservation guard. A post-receipt snapshot with no old workflow proves that old
           key cannot subsequently reserve. Ordinary polls cannot clear uncertainty. *)
        (not superseded_before_reservation)
        && not
             (i.acknowledged
              && revision >= i.floor
              && List.exists snapshot.launches ~f:(fun l ->
                String.equal l.key i.key && Asic.Preview.equal l.preview i.preview)))
    in
    { t with
      revision
    ; snapshot = Some snapshot
    ; intent
    ; launch_intent
    ; launch_generation =
        (if Option.is_some t.launch_intent && Option.is_none launch_intent
         then t.launch_generation + 1
         else t.launch_generation)
    })
;;

let launch_active (op : Asic.Pending.t) =
  Plain_rpc.active op || String.equal op.state "reserving"
;;

let launch_model t preview =
  let make ?key ?run_id state message = { key; run_id; state; message } in
  match
    Option.filter t.launch_intent ~f:(fun i ->
      Option.exists preview ~f:(Asic.Preview.equal i.preview))
  with
  | Some i ->
    let op =
      Option.bind t.snapshot ~f:(fun s ->
        if (not i.acknowledged) || t.revision < i.floor
        then None
        else List.find s.operations ~f:(fun op -> String.equal op.key ("run:" ^ i.key)))
    in
    (match op with
     | Some op when String.equal op.state "failed" ->
       make
         ~key:i.key
         ?run_id:(Option.map op.run ~f:(fun run -> run.id))
         Launch_failed
         ("Launch operation failed; allocation "
          ^ (if Option.is_none op.run then "not observed: " else "observed: ")
          ^ Option.value op.error ~default:"unavailable")
     | Some op when String.equal op.state "cancelled" ->
       make
         ~key:i.key
         ?run_id:(Option.map op.run ~f:(fun run -> run.id))
         Cancelled
         "Launch operation cancelled; inspect exact allocation when available"
     | _ ->
       make
         ~key:i.key
         (if Option.is_none i.error then Submitting else Unavailable)
         (match i.error with
          | Some error ->
            "Launch request failed/unconfirmed; allocation unknown: " ^ error
          | None -> "Submitting; waiting for exact launch receipt/observation"))
  | None ->
    let reference =
      Option.bind t.snapshot ~f:(fun s ->
        List.find s.launches ~f:(fun l ->
          Option.exists preview ~f:(Asic.Preview.equal l.preview)))
    in
    (match reference with
     | None ->
       make Unavailable "Launch association unavailable; allocation not established"
     | Some l ->
       let snapshot = Option.value_exn t.snapshot in
       let op =
         List.find snapshot.operations ~f:(fun op -> String.equal op.key ("run:" ^ l.key))
       in
       let run =
         Option.bind l.run_id ~f:(fun id ->
           List.find snapshot.runs ~f:(fun r -> String.equal r.run.id id))
       in
       let owned = Option.exists op ~f:launch_active in
       let state, message =
         match run with
         | Some r when String.equal r.status "completed" ->
           Completed, "Producer completed"
         | Some r when String.equal r.status "failed" -> Launch_failed, "Producer failed"
         | Some r
           when List.mem [ "cancelled"; "interrupted" ] r.status ~equal:String.equal ->
           Cancelled, "Producer cancelled/interrupted"
         | _ ->
           (match op with
            | Some op when String.equal op.state "failed" ->
              ( Launch_failed
              , "Launch operation failed: " ^ Option.value op.error ~default:"unavailable"
              )
            | Some op when String.equal op.state "cancelled" ->
              Cancelled, "Launch operation cancelled"
            | _ when not owned ->
              Detached, "Producer ownership detached; current execution state unavailable"
            | _ ->
              (match run, l.run_id with
               | Some r, _ when String.equal r.status "observing" ->
                 Running, "Producer running (observed)"
               | _, Some _ -> Allocated, "Run allocated; awaiting producer observation"
               | _ -> Submitting, "Submission reserved; allocation not yet observed"))
       in
       let message =
         message
         ^ if owned then "; launch operation active" else "; no active launch owner"
       in
       make ~key:l.key ?run_id:l.run_id state message)
;;

let legacy_model t =
  let preview = Option.bind t.snapshot ~f:(fun s -> s.preview) in
  let launch_preview =
    match preview with
    | Some _ -> preview
    | None ->
      (match t.launch_intent with
       | Some i -> Some i.preview
       | None ->
         Option.bind t.snapshot ~f:(fun s ->
           Option.map (List.hd s.launches) ~f:(fun l -> l.preview)))
  in
  let plans =
    Option.value_map t.snapshot ~default:[] ~f:(fun s ->
      List.filter s.operations ~f:(fun op -> String.equal op.kind "plan"))
  in
  let operation key = List.find plans ~f:(fun op -> String.equal op.key key) in
  let active = List.exists plans ~f:Plain_rpc.active in
  let make ?selection ?requested ?operation_key status message =
    { status
    ; selection
    ; requested
    ; operation_key
    ; preview
    ; message
    ; launch = launch_model t launch_preview
    ; launch_preview
    }
  in
  let shared () =
    match preview with
    | Some p ->
      let operation_key = key p.selection in
      let status, message =
        if active
        then Pending, "Shared plan operation pending; retained preview is not ready"
        else (
          match operation operation_key with
          | Some op when String.equal op.state "completed" ->
            Ready, "Plan ready for explicit reuse; producer lifecycle shown separately"
          | Some op when String.equal op.state "failed" ->
            Failed, Option.value op.error ~default:"Plan failed"
          | _ -> Stale, "Preview retained; exact completed plan operation unavailable")
      in
      make ~selection:p.selection ~operation_key status message
    | None ->
      if active
      then make Pending "Shared plan pending; selection not published by daemon yet"
      else (
        match List.find plans ~f:(fun op -> String.equal op.state "failed") with
        | Some op ->
          make
            ~operation_key:op.key
            Failed
            ("Shared preview unavailable; observed plan failure (selection/order \
              unpublished): "
             ^ Option.value op.error ~default:"plan operation failed")
        | None ->
          if List.is_empty plans
          then make Empty "No plan preview; stage r or palette Plan prepares a plan"
          else
            make
              Stale
              "Plan operation retained but current preview absent; prepare explicitly \
               again")
  in
  match t.intent with
  | None -> shared ()
  | Some i ->
    let local status message =
      make
        ~selection:i.selection
        ~requested:i.selection
        ~operation_key:i.key
        status
        message
    in
    (match i.error with
     | Some error -> local Failed ("Plan request failed/unconfirmed: " ^ error)
     | None when (not i.acknowledged) || t.revision < i.floor ->
       local Pending "Plan requested; waiting for matching request receipt/observation"
     | None ->
       (match operation i.key with
        | Some op when Plain_rpc.active op ->
          local Pending "Requested plan pending; previous preview is not ready"
        | Some op when String.equal op.state "failed" ->
          local Failed (Option.value op.error ~default:"Requested plan failed")
        | Some op when String.equal op.state "completed" ->
          (match preview with
           | Some p when Asic.Selection.equal p.selection i.selection -> shared ()
           | _ ->
             let m = shared () in
             { m with
               status = Stale
             ; requested = Some i.selection
             ; message =
                 "Requested plan completed but preview is absent/superseded; inspect \
                  current shared selection: "
                 ^ m.message
             })
        | _ ->
          local
            Stale
            "Requested plan operation expired or unavailable; prepare explicitly again"))
;;

let model t =
  if (not t.fresh_mode) && Option.is_none (fresh_intent t) && Option.is_none (workflow t)
  then legacy_model t
  else (
    let intent = fresh_intent t in
    let consumed i =
      Option.exists t.snapshot ~f:(fun s ->
        List.exists s.workflows ~f:(fun w ->
          String.equal w.intent.id i.Asic.Fresh.Intent.id))
    in
    let status, message =
      match t.intent, shared_fresh_intent t with
      | Some i, _ when Option.is_some i.error ->
        Failed, "Input staging failed: " ^ Option.value_exn i.error
      | Some i, _ when (not i.acknowledged) || t.revision < i.floor ->
        Pending, "Staging current source/configuration inputs; no producer started"
      | Some i, Some current
        when not (Option.exists i.fresh_receipt ~f:(Asic.Fresh.Intent.equal current)) ->
        Stale, "Staged inputs superseded; press r again"
      | _, Some i when consumed i ->
        Stale, "Input intent consumed; r stages a new fresh run"
      | _, Some _ ->
        Ready, "Fresh input intent ready; launch builds and emits current source"
      | Some _, None -> Stale, "Fresh input intent unavailable; stage again"
      | None, None -> Empty, "No fresh input intent; r stages current inputs"
    in
    let launch =
      match workflow t with
      | Some w ->
        let state : launch_status =
          match w.phase with
          | Completed -> Completed
          | Failed -> Launch_failed
          | Cancelled -> Cancelled
          | Interrupted -> Detached
          | Physical -> if Option.is_some w.run then Running else Submitting
          | Reserved | Building | Emitting | Prepared -> Submitting
        in
        { key = Some w.key
        ; run_id = Option.map w.run ~f:(fun r -> r.id)
        ; state
        ; message =
            "Elaboration: "
            ^ w.elaboration_status
            ^ "; workflow "
            ^ w.id
            ^ "; "
            ^ Sexp.to_string (Asic.Fresh.Phase.sexp_of_t w.phase)
            ^ Option.value_map w.error ~default:"" ~f:(fun e -> ": " ^ e)
        }
      | None ->
        (match t.launch_intent with
         | Some i ->
           { key = Some i.key
           ; run_id = None
           ; state = (if Option.is_some i.error then Unavailable else Submitting)
           ; message =
               Option.value
                 i.error
                 ~default:"Submitting fresh workflow; reservation pending"
           }
         | None ->
           { key = None; run_id = None; state = Unavailable; message = "Not submitted" })
    in
    { status
    ; selection =
        Option.first_some
          (Option.map t.intent ~f:(fun i -> i.selection))
          (Option.map intent ~f:(fun i -> i.selection))
    ; requested = Option.map t.intent ~f:(fun i -> i.selection)
    ; operation_key = None
    ; preview = None
    ; launch_preview = None
    ; message
    ; launch
    })
;;

let fresh_launchable t (intent : Asic.Fresh.Intent.t) =
  equal_status (model t).status Ready
  && Option.exists (fresh_intent t) ~f:(Asic.Fresh.Intent.equal intent)
  && not
       (Option.exists t.launch_intent ~f:(fun i ->
          match workflow t with
          | Some w when String.equal w.key i.key ->
            workflow_active w || Asic.Fresh.Phase.equal w.phase Interrupted
          | _ -> true))
;;

let launchable t preview =
  let m = model t in
  equal_status m.status Ready
  && Option.equal Asic.Preview.equal m.preview (Some preview)
  && (not
        (Option.exists t.snapshot ~f:(fun s ->
           List.exists s.launches ~f:(fun l ->
             Asic.Preview.equal l.preview preview
             && List.exists s.operations ~f:(fun op ->
               String.equal op.key ("run:" ^ l.key) && launch_active op)))))
  && (not
        (Option.exists t.launch_intent ~f:(fun i ->
           let l = launch_model t (Some i.preview) in
           not
             (List.mem
                [ Launch_failed; Cancelled; Completed ]
                l.state
                ~equal:equal_launch_status))))
  && (not
        (List.mem
           [ Submitting; Allocated; Running; Detached ]
           m.launch.state
           ~equal:equal_launch_status))
  && not
       (List.mem [ Launch_failed; Cancelled ] m.launch.state ~equal:equal_launch_status
        && Option.is_some m.launch.run_id
        && not
             (Option.exists t.snapshot ~f:(fun s ->
                List.exists s.runs ~f:(fun r ->
                  Option.equal String.equal (Some r.run.id) m.launch.run_id
                  && List.mem
                       [ "completed"; "failed"; "cancelled"; "interrupted" ]
                       r.status
                       ~equal:String.equal))))
;;

let launch_label (m : model) =
  if Option.is_none m.preview
  then "last launch reference (no current plan)"
  else if equal_status m.status Ready
  then "last launch using this plan"
  else "last launch using retained shared preview"
;;

let rows m ~detail =
  let role =
    match m.status with
    | Ready -> Success
    | Failed -> Error
    | Pending | Stale -> Warning
    | Empty -> Muted
  in
  let state = String.lowercase (Sexp.to_string (sexp_of_status m.status)) in
  let facts selection =
    [ { role = Fact
      ; text =
          "flow: "
          ^ selection.Asic.Selection.flow
          ^ " / profile: "
          ^ selection.profile
          ^ " / endpoint: "
          ^ selection.endpoint
      }
    ; { role = Fact
      ; text =
          ("assignments: "
           ^
           if List.is_empty selection.assignments
           then "(none)"
           else String.concat ~sep:"; " selection.assignments)
      }
    ]
  in
  [ { role; text = state ^ ": " ^ m.message } ]
  @ [ { role = Fact; text = launch_label m ^ ": " ^ m.launch.message } ]
  @ Option.value_map m.launch.key ~default:[] ~f:(fun key ->
    [ { role = Fact; text = "submission key: " ^ key } ])
  @ Option.value_map m.launch.run_id ~default:[] ~f:(fun id ->
    [ { role = Fact; text = "exact allocated run: " ^ id } ])
  @ Option.value_map m.selection ~default:[] ~f:facts
  @
  if not detail
  then []
  else
    (if Option.is_none m.preview
     then
       Option.value_map m.launch_preview ~default:[] ~f:(fun p ->
         [ { role = Muted
           ; text = "Separate launch preview; not a current reusable plan:"
           }
         ; { role = Fact; text = "exact launch plan identity: " ^ p.plan_identity }
         ]
         @ facts p.selection)
     else [])
    @ Option.value_map m.operation_key ~default:[] ~f:(fun key ->
      [ { role = Muted; text = "plan operation: " ^ key } ])
    @ Option.value_map m.requested ~default:[] ~f:(fun selection ->
      { role = Muted; text = "local requested selection (not a producer association):" }
      :: facts selection)
    @ Option.value_map m.preview ~default:[] ~f:(fun p ->
      (if equal_status m.status Ready
       then []
       else
         [ { role = Warning
           ; text =
               "Retained/unconfirmed shared preview below; not ready for current intent."
           }
         ])
      @ [ { role = Muted
          ; text =
              "Generated provider plan preview (separate from PREPARATION input plan):"
          }
        ; { role = Fact; text = "exact plan identity: " ^ p.plan_identity }
        ; { role = Muted; text = "shared preview selection:" }
        ]
      @ facts p.selection
      @ [ { role = Muted; text = "exact plan metadata (JSON):" } ]
      @ List.map (String.split_lines p.plan_json) ~f:(fun text -> { role = Fact; text }))
    @ [ { role = Muted
        ; text = "Plan reuse readiness is separate from launch/producer lifecycle."
        }
      ]
;;

let max_scroll m ~detail = Int.max 0 (List.length (rows m ~detail) - 1)

let%test_unit "local fresh receipt never adopts same-selection replacement and survives \
               legacy preview completion"
  =
  let first = Fs0_fixture.fresh_intent "first" in
  let state, ticket =
    begin_fresh (reset empty ~scope:"owner") ~elaboration_only:false first.selection
  in
  let state = fresh_receipt state ticket ~floor:2 (Ok first) in
  let snapshot intent = { Fs0_fixture.snapshot with fresh_intent = Some intent } in
  let ready = receive state ~revision:2 (snapshot first) in
  assert (fresh_launchable ready first);
  List.iter
    [ { first with id = "same-selection-other-client" }
    ; { first with scope = "different captured provider/source scope" }
    ; { first with expected_plan_identity = Some "explicit-assertion" }
    ]
    ~f:(fun replacement ->
      let replaced = receive ready ~revision:3 (snapshot replacement) in
      assert (equal_status (model replaced).status Stale);
      assert (Option.equal Asic.Fresh.Intent.equal (fresh_intent replaced) (Some first));
      assert (not (fresh_launchable replaced first));
      assert (not (fresh_launchable replaced replacement)));
  let preview : Asic.Preview.t =
    { selection = first.selection; plan_identity = "pinned"; plan_json = "{}" }
  in
  let plan : Asic.Pending.t =
    { key = key first.selection
    ; kind = "plan"
    ; state = "completed"
    ; run = None
    ; error = None
    ; activity = Unreported
    }
  in
  let replaced =
    receive
      ready
      ~revision:4
      { (snapshot { first with id = "other" }) with
        preview = Some preview
      ; operations = [ plan ]
      }
  in
  assert (Option.is_some replaced.intent);
  assert (equal_status (model replaced).status Stale);
  let restaging, newer = begin_fresh replaced ~elaboration_only:false first.selection in
  let late = fresh_receipt restaging ticket ~floor:5 (Ok first) in
  assert (equal_status (model late).status Pending);
  let replacement = { first with id = "own-new-receipt" } in
  let restored = fresh_receipt late newer ~floor:6 (Ok replacement) in
  let restored = receive restored ~revision:6 (snapshot replacement) in
  assert (fresh_launchable restored replacement)
;;

let%test_unit "rejected or uncertain fresh launch recovers only after exact new staging \
               barrier and absence of old reservation"
  =
  let first = Fs0_fixture.fresh_intent "first" in
  let replacement = { first with id = "recovery" } in
  let state, ticket =
    begin_fresh (reset empty ~scope:"owner") ~elaboration_only:false first.selection
  in
  let state = fresh_receipt state ticket ~floor:1 (Ok first) in
  let snapshot intent workflows =
    { Fs0_fixture.snapshot with fresh_intent = Some intent; workflows }
  in
  let state = receive state ~revision:1 (snapshot first []) in
  let submitted, launch_ticket =
    begin_fresh_launch state ~key:"possibly-submitted" first
  in
  let rejected =
    launch_receipt
      submitted
      launch_ticket
      ~floor:2
      (Error "request rejected or transport unconfirmed")
  in
  let observed =
    receive rejected ~revision:2 (snapshot { first with id = "foreign" } [])
  in
  assert (Option.is_some observed.launch_intent);
  assert (not (fresh_launchable observed replacement));
  let restaged, ticket = begin_fresh observed ~elaboration_only:false first.selection in
  let restaged = fresh_receipt restaged ticket ~floor:5 (Ok replacement) in
  let before_floor = receive restaged ~revision:4 (snapshot replacement []) in
  assert (Option.is_some before_floor.launch_intent);
  assert (not (fresh_launchable before_floor replacement));
  let recovered = receive before_floor ~revision:5 (snapshot replacement []) in
  assert (Option.is_none recovered.launch_intent);
  assert (fresh_launchable recovered replacement);
  let late =
    launch_receipt recovered launch_ticket ~floor:6 (Error "late old response")
  in
  assert (fresh_launchable late replacement);
  let reserved = Fs0_fixture.workflow "possibly-submitted" first in
  let still_owned = receive restaged ~revision:5 (snapshot replacement [ reserved ]) in
  assert (Option.is_some still_owned.launch_intent);
  assert (not (fresh_launchable still_owned replacement));
  let missing_receipt, ticket =
    begin_fresh rejected ~elaboration_only:false first.selection
  in
  let missing_receipt = receipt missing_receipt ticket ~floor:5 (Ok ()) in
  let missing_receipt = receive missing_receipt ~revision:5 (snapshot replacement []) in
  assert (Option.is_some missing_receipt.launch_intent);
  assert (not (fresh_launchable missing_receipt replacement));
  (* The staging barrier cannot prove absence of a legacy Run, whose daemon entry point
     deliberately has no staged-intent supersession guard. *)
  let legacy, legacy_ticket =
    begin_launch state ~key:"legacy-unconfirmed" (fresh_preview first)
  in
  let legacy =
    launch_receipt legacy legacy_ticket ~floor:2 (Error "transport unconfirmed")
  in
  let legacy, ticket = begin_fresh legacy ~elaboration_only:false first.selection in
  let legacy = fresh_receipt legacy ticket ~floor:5 (Ok replacement) in
  let legacy = receive legacy ~revision:5 (snapshot replacement []) in
  assert (Option.is_some legacy.launch_intent);
  assert (not (fresh_launchable legacy replacement))
;;

let%test_unit "fresh staging ignores pinned preview, fences receipts and follows exact \
               workflow before allocation"
  =
  let intent = Fs0_fixture.fresh_intent "input" in
  let pinned : Asic.Preview.t =
    { selection = intent.selection
    ; plan_identity = "old-pinned-executable"
    ; plan_json = "{}"
    }
  in
  let base = { Fs0_fixture.snapshot with preview = Some pinned } in
  let owner = reset empty ~scope:"daemon/project" in
  let pending, ticket = begin_fresh owner ~elaboration_only:false intent.selection in
  let observed = { base with fresh_intent = Some intent } in
  let pending = receive pending ~revision:3 observed in
  assert (equal_status (model pending).status Pending);
  let pending = fresh_receipt pending ticket ~floor:5 (Ok intent) in
  let pending = receive pending ~revision:4 observed in
  assert (not (fresh_launchable pending intent));
  let ready = receive pending ~revision:5 observed in
  assert (fresh_launchable ready intent);
  assert (Option.is_none (model ready).preview);
  let submitting, launch_ticket = begin_fresh_launch ready ~key:"fresh" intent in
  assert (not (fresh_launchable submitting intent));
  let unknown = launch_receipt submitting launch_ticket ~floor:6 (Error "timeout") in
  assert (not (fresh_launchable unknown intent));
  let w = Fs0_fixture.workflow "fresh" intent in
  let accepted = receive unknown ~revision:6 { observed with workflows = [ w ] } in
  assert (equal_launch_status (model accepted).launch.state Submitting);
  assert (Option.is_none (model accepted).launch.run_id);
  assert (String.is_substring (model accepted).launch.message ~substring:"building");
  let allocated =
    { w with
      phase = Physical
    ; run = Some Fs0_fixture.run_a
    ; elaboration_status = "completed"
    }
  in
  let accepted =
    receive accepted ~revision:7 { observed with workflows = [ allocated ] }
  in
  assert (
    Option.equal String.equal (model accepted).launch.run_id (Some Fs0_fixture.run_a.id));
  let next = { intent with id = "next-input" } in
  let pending, ticket = begin_fresh accepted ~elaboration_only:false intent.selection in
  let pending = fresh_receipt pending ticket ~floor:8 (Ok next) in
  let ready =
    receive
      pending
      ~revision:8
      { observed with fresh_intent = Some next; workflows = [ allocated ] }
  in
  assert (not (fresh_launchable ready next));
  let completed = { allocated with phase = Completed } in
  let ready =
    receive
      ready
      ~revision:9
      { observed with fresh_intent = Some next; workflows = [ completed ] }
  in
  assert (fresh_launchable ready next);
  assert (not (fresh_launchable ready intent));
  let reset = reset ready ~scope:"replacement/project" in
  assert (Option.is_none (fresh_intent reset));
  assert (Option.is_none (workflow reset))
;;

let%test_unit "launch lifecycle uses exact durable reservations, local receipt fences, \
               and independent plan reuse"
  =
  let selection : Asic.Selection.t =
    { flow = "flow"; profile = "profile"; endpoint = "synthesis"; assignments = [] }
  in
  let preview : Asic.Preview.t =
    { selection; plan_identity = "exact"; plan_json = "full raw preview" }
  in
  let other =
    { preview with plan_json = "different exact preview, same identity/selection" }
  in
  let plan : Asic.Pending.t =
    { key = key selection
    ; kind = "plan"
    ; state = "completed"
    ; run = None
    ; error = None
    ; activity = Unreported
    }
  in
  let operation ?run state : Asic.Pending.t =
    { key = "run:new"; kind = "run"; state; run; error = None; activity = Unreported }
  in
  let reference ?(key = "new") ?run_id preview : Asic.Launch.t =
    { key; preview; run_id }
  in
  let snapshot ?(preview = preview) ?(launches = []) ?(ops = []) ?(runs = []) () =
    { Fs0_fixture.snapshot with
      preview = Some preview
    ; launches
    ; operations = plan :: ops
    ; runs
    }
  in
  let ready = receive (reset empty ~scope:"owner") ~revision:1 (snapshot ()) in
  assert (launchable ready preview);
  assert (equal_launch_status (model ready).launch.state Unavailable);
  assert (
    not
      (List.exists
         (rows (model ready) ~detail:true)
         ~f:(fun row -> String.is_substring row.text ~substring:"no job allocated")));
  let local, ticket = begin_launch ready ~key:"new" preview in
  assert (equal_launch_status (model local).launch.state Submitting);
  assert (not (launchable local preview));
  let replanning, _ = begin_plan local { selection with endpoint = "signoff" } in
  assert (equal_status (model replanning).status Pending);
  assert (Option.is_some replanning.launch_intent);
  assert (
    List.exists
      (rows (model replanning) ~detail:true)
      ~f:(fun row ->
        String.is_prefix row.text ~prefix:"last launch using retained shared preview:"));
  let replanning =
    launch_receipt replanning ticket ~floor:2 (Error "late launch transport")
  in
  assert (equal_status (model replanning).status Pending);
  assert (equal_launch_status (model replanning).launch.state Unavailable);
  let reserved =
    snapshot ~launches:[ reference preview ] ~ops:[ operation "pending" ] ()
  in
  let before_receipt = receive local ~revision:8 reserved in
  assert (not (launchable before_receipt preview));
  let confirmed = launch_receipt before_receipt ticket ~floor:10 (Ok ()) in
  let confirmed = receive confirmed ~revision:9 reserved in
  assert (Option.is_some confirmed.launch_intent);
  let confirmed = receive confirmed ~revision:10 reserved in
  assert (Option.is_none confirmed.launch_intent);
  assert (equal_launch_status (model confirmed).launch.state Submitting);
  assert (Option.is_none (model confirmed).launch.run_id);
  let reserving =
    receive
      confirmed
      ~revision:11
      { reserved with operations = [ plan; operation "reserving" ] }
  in
  assert (equal_launch_status (model reserving).launch.state Submitting);
  assert (not (launchable reserving preview));
  let run = Fs0_fixture.run_a in
  let allocated =
    snapshot
      ~launches:[ reference ~run_id:run.id preview ]
      ~ops:[ operation ~run "executing" ]
      ~runs:[ { (Fs0_fixture.run run) with status = "allocated" } ]
      ()
  in
  let allocated_model = receive confirmed ~revision:11 allocated |> model in
  assert (equal_launch_status allocated_model.launch.state Allocated);
  assert (Option.equal String.equal allocated_model.launch.run_id (Some run.id));
  let observe status =
    { allocated with runs = [ { (Fs0_fixture.run run) with status } ] }
  in
  let running = receive confirmed ~revision:12 (observe "observing") in
  assert (equal_launch_status (model running).launch.state Running);
  assert (not (launchable running preview));
  let terminal_owner_active = receive running ~revision:13 (observe "completed") in
  assert (not (launchable terminal_owner_active preview));
  let failed_owner_live =
    receive
      running
      ~revision:13
      { (observe "observing") with operations = [ plan; operation ~run "failed" ] }
  in
  assert (not (launchable failed_owner_live preview));
  List.iter
    [ "completed", Completed; "failed", Launch_failed; "interrupted", Cancelled ]
    ~f:(fun (status, expected) ->
      let terminal =
        receive running ~revision:13 { (observe status) with operations = [ plan ] }
      in
      assert (equal_status (model terminal).status Ready);
      assert (equal_launch_status (model terminal).launch.state expected);
      assert (launchable terminal preview));
  let detached =
    receive running ~revision:13 { allocated with operations = [ plan ]; runs = [] }
  in
  assert (equal_launch_status (model detached).launch.state Detached);
  assert (not (launchable detached preview));
  assert (Option.equal String.equal (model detached).launch.run_id (Some run.id));
  let failed =
    receive
      confirmed
      ~revision:14
      (snapshot ~launches:[ reference preview ] ~ops:[ operation "failed" ] ())
  in
  assert (equal_launch_status (model failed).launch.state Launch_failed);
  assert (Option.is_none (model failed).launch.run_id && launchable failed preview);
  let next, next_ticket = begin_launch failed ~key:"next" preview in
  let late = launch_receipt next ticket ~floor:15 (Error "delayed previous receipt") in
  assert (equal_launch_status (model late).launch.state Submitting);
  let unknown = launch_receipt late next_ticket ~floor:16 (Error "transport timeout") in
  assert (equal_launch_status (model unknown).launch.state Unavailable);
  assert (not (launchable unknown preview));
  let unknown = receive unknown ~revision:16 (snapshot ()) in
  assert (not (launchable unknown preview));
  let next_launch = reference ~key:"next" ~run_id:Fs0_fixture.run_b.id preview in
  let recovered =
    receive
      unknown
      ~revision:17
      { (observe "completed") with
        launches = [ next_launch; reference preview ]
      ; operations = [ plan ]
      ; runs =
          [ { (Fs0_fixture.run run) with status = "observing" }
          ; Fs0_fixture.run Fs0_fixture.run_b
          ]
      }
  in
  assert (launchable recovered preview);
  assert (Option.equal String.equal (model recovered).launch.key (Some "next"));
  assert (
    Option.equal String.equal (model recovered).launch.run_id (Some Fs0_fixture.run_b.id));
  let recovered = launch_receipt recovered next_ticket ~floor:18 (Error "late failure") in
  assert (launchable recovered preview);
  (* Newest reservation wins among exact matches only, not newer mismatched preview. *)
  let shared =
    snapshot
      ~launches:[ reference ~key:"foreign-other" other; next_launch; reference preview ]
      ~runs:
        [ { (Fs0_fixture.run run) with status = "failed" }
        ; Fs0_fixture.run Fs0_fixture.run_b
        ]
      ()
  in
  List.iter
    [ recovered; reset empty ~scope:"another-client" ]
    ~f:(fun client ->
      let client = receive client ~revision:18 shared in
      assert (Option.equal String.equal (model client).launch.key (Some "next")));
  let restarted =
    receive
      (reset empty ~scope:"restarted-daemon")
      ~revision:1
      { shared with
        preview = None
      ; launches = [ next_launch; reference preview ]
      ; operations = []
      }
  in
  assert (equal_status (model restarted).status Empty);
  assert (Option.is_none (model restarted).preview);
  assert (Option.equal String.equal (model restarted).launch.key (Some "next"));
  assert (equal_launch_status (model restarted).launch.state Completed);
  assert (
    String.equal
      (launch_label (model restarted))
      "last launch reference (no current plan)");
  assert (not (launchable restarted preview));
  let replan = receive recovered ~revision:19 { shared with preview = Some other } in
  assert (Option.equal String.equal (model replan).launch.key (Some "foreign-other"));
  let no_match =
    receive
      replan
      ~revision:20
      { shared with preview = Some { other with plan_identity = "new" } }
  in
  assert (equal_launch_status (model no_match).launch.state Unavailable);
  let new_owner = reset next ~scope:"replacement" in
  let new_owner = launch_receipt new_owner next_ticket ~floor:21 (Error "old owner") in
  assert (Option.is_none new_owner.launch_intent)
;;

let%test_unit "old ready to local pending, transport failure, retry and new ready" =
  let a : Asic.Selection.t =
    { flow = "flow"; profile = "profile"; endpoint = "a"; assignments = [ "x=1" ] }
  in
  let b = { a with endpoint = "b" } in
  let preview selection identity : Asic.Preview.t =
    { selection; plan_identity = identity; plan_json = "{}" }
  in
  let pa = preview a "exact-a"
  and pb = preview b "exact-b" in
  let op selection state : Asic.Pending.t =
    { key = key selection
    ; kind = "plan"
    ; state
    ; run = None
    ; error = None
    ; activity = Unreported
    }
  in
  let snap p ops = { Fs0_fixture.snapshot with preview = p; operations = ops } in
  let ready =
    receive
      (reset empty ~scope:"daemon/project")
      ~revision:1
      (snap (Some pa) [ op a "completed" ])
  in
  assert (launchable ready pa);
  let pending, ticket = begin_plan ready b in
  assert (equal_status (model pending).status Pending && not (launchable pending pa));
  let failed = receipt pending ticket ~floor:2 (Error "transport") in
  let failed = receive failed ~revision:3 (snap (Some pa) [ op a "completed" ]) in
  assert (equal_status (model failed).status Failed && not (launchable failed pa));
  let retry, current = begin_plan failed b in
  let retry = receipt retry ticket ~floor:3 (Error "late old failure") in
  assert (equal_status (model retry).status Pending);
  let retry = receipt retry current ~floor:5 (Ok ()) in
  let retry = receive retry ~revision:4 (snap (Some pb) [ op b "completed" ]) in
  assert (equal_status (model retry).status Pending);
  let retry = receive retry ~revision:5 (snap (Some pb) [ op b "failed" ]) in
  assert (equal_status (model retry).status Failed);
  let retry = receive retry ~revision:6 (snap (Some pb) [ op b "completed" ]) in
  assert (launchable retry pb);
  let delayed = receive retry ~revision:2 (snap (Some pa) [ op a "completed" ]) in
  assert (launchable delayed pb);
  let foreign =
    receive retry ~revision:7 (snap (Some pa) [ op a "completed"; op b "completed" ])
  in
  assert (launchable foreign pa);
  let pending, ticket = begin_plan retry b in
  assert (not (launchable pending pb));
  let pending = receipt pending ticket ~floor:7 (Ok ()) in
  let superseded =
    receive pending ~revision:7 (snap (Some pa) [ op a "completed"; op b "completed" ])
  in
  assert (equal_status (model superseded).status Stale && not (launchable superseded pa));
  let other =
    receive ready ~revision:8 (snap (Some pa) [ op b "executing"; op a "completed" ])
  in
  assert (equal_status (model other).status Pending && not (launchable other pa));
  let reset = reset retry ~scope:"replacement/project" in
  assert (equal_status (model reset).status Empty);
  let reset = receipt reset current ~floor:10 (Error "late replaced daemon") in
  assert (equal_status (model reset).status Empty)
;;

let%test_unit "same-selection retry waits past every pre-receipt poll then ordinary \
               reads stay ready"
  =
  let selection : Asic.Selection.t =
    { flow = "flow"; profile = "profile"; endpoint = "endpoint"; assignments = [] }
  in
  let preview : Asic.Preview.t =
    { selection; plan_identity = "exact-identity"; plan_json = "opaque metadata" }
  in
  let operation state : Asic.Pending.t =
    { key = key selection
    ; kind = "plan"
    ; state
    ; run = None
    ; error = None
    ; activity = Unreported
    }
  in
  let completed =
    { Fs0_fixture.snapshot with
      preview = Some preview
    ; operations = [ operation "completed" ]
    }
  in
  let ready = receive (reset empty ~scope:"same-owner") ~revision:1 completed in
  let retry, ticket = begin_plan ready selection in
  assert (current_ticket retry ticket && not (launchable retry preview));
  (* IDs 2..8 may have been issued before the Plan receipt; their snapshots can still
     contain the old completed task, despite arriving after the receipt. *)
  let retry = receipt retry ticket ~floor:9 (Ok ()) in
  let retry = receive retry ~revision:8 completed in
  assert (equal_status (model retry).status Pending && not (launchable retry preview));
  let pending =
    { completed with preview = None; operations = [ operation "executing" ] }
  in
  let retry = receive retry ~revision:9 pending in
  assert (equal_status (model retry).status Pending);
  let ready = receive retry ~revision:10 completed in
  assert (launchable ready preview && not (current_ticket ready ticket));
  let ready = receive ready ~revision:11 { completed with runs = [] } in
  assert (launchable ready preview);
  (* Late dispatcher rejection or duplicate receipt cannot reopen a completed intent. *)
  let ready = receipt ready ticket ~floor:12 (Error "late rejected dispatcher") in
  assert (launchable ready preview);
  let failed =
    receive ready ~revision:12 { completed with operations = [ operation "failed" ] }
  in
  assert (equal_status (model failed).status Failed && not (launchable failed preview));
  let expired = receive ready ~revision:12 { completed with operations = [] } in
  assert (equal_status (model expired).status Stale && not (launchable expired preview));
  let absent = receive ready ~revision:12 { completed with preview = None } in
  assert (equal_status (model absent).status Stale && not (launchable absent preview))
;;

let%test_unit "scope round trips and newer command acceptance invalidate old dispatch \
               and receipt"
  =
  let selection : Asic.Selection.t =
    { flow = "flow"; profile = "profile"; endpoint = "endpoint"; assignments = [] }
  in
  let owner = reset empty ~scope:"daemon/project" in
  let first, old_ticket = begin_plan owner selection in
  let second, ticket = begin_plan first { selection with endpoint = "new-endpoint" } in
  assert ((not (current_ticket second old_ticket)) && current_ticket second ticket);
  let rejected =
    receipt second ticket ~floor:Int.max_value (Error "target changed before dispatch")
  in
  assert (equal_status (model rejected).status Failed);
  let reconnected = reset (reset second ~scope:"") ~scope:"daemon/project" in
  let reconnected, replacement = begin_plan reconnected selection in
  assert (not (current_ticket reconnected old_ticket));
  assert (not (current_ticket reconnected ticket));
  assert (current_ticket reconnected replacement);
  let reconnected = receipt reconnected ticket ~floor:1 (Error "old transport") in
  assert (equal_status (model reconnected).status Pending);
  List.iter [ "other-daemon/project"; "daemon/other-project" ] ~f:(fun scope ->
    let changed = reset reconnected ~scope in
    assert (equal_status (model changed).status Empty);
    assert (not (current_ticket changed replacement)))
;;

let%test_unit "exact raw selection identity and metadata survive display projection \
               without normalization"
  =
  let selection : Asic.Selection.t =
    { flow = "Flow;\027[31m"
    ; profile = "Profile With Spaces"
    ; endpoint = "Endpoint/Case"
    ; assignments = [ "z=1"; "a=2"; "z=1" ]
    }
  in
  let preview : Asic.Preview.t =
    { selection
    ; plan_identity = "raw\027identity"
    ; plan_json = "{malformed opaque\000JSON}\nsecond line"
    }
  in
  let op : Asic.Pending.t =
    { key = key selection
    ; kind = "plan"
    ; state = "completed"
    ; run = None
    ; error = None
    ; activity = Unreported
    }
  in
  let snapshot =
    { Fs0_fixture.snapshot with preview = Some preview; operations = [ op ] }
  in
  let ready = receive empty ~revision:1 snapshot in
  assert (launchable ready preview);
  assert (not (launchable ready { preview with plan_json = "different raw metadata" }));
  assert (not (launchable ready { preview with plan_identity = "different" }));
  assert (
    not
      (String.equal
         (key selection)
         (key { selection with assignments = [ "a=2"; "z=1"; "z=1" ] })));
  assert (
    not
      (String.equal
         (key selection)
         (key { selection with assignments = [ "z=1"; "a=2" ] })));
  let before = model ready in
  let detail = rows before ~detail:true in
  assert (
    List.exists detail ~f:(fun row ->
      String.equal row.text "exact plan identity: raw\027identity"));
  assert (
    List.exists detail ~f:(fun row -> String.equal row.text "{malformed opaque\000JSON}"));
  assert (Asic.Preview.equal (Option.value_exn (model ready).preview) preview)
;;
