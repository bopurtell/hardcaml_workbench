open! Core
open Hardcaml_workbench_protocol

(* Scope: daemon operations count only when an open inspector currently wants their exact
   key (its run/domain/stage index, or its requested row detail), or when they are an
   explicit summary refresh for a run some tile shows. A late or obsolete read therefore
   never surfaces, and nothing here issues a request: this is a pure projection of the
   latest snapshot. *)

type target =
  | Index of
      { domain : string
      ; stage : string
      }
  | Detail of
      { domain : string
      ; stage : string
      }
  | Summary_refresh

type read =
  { key : string
  ; run : Run_ref.t option
  ; target : target
  }

type failure =
  { key : string
  ; scope : string
  ; error : string
  ; prior : string
  }

type t =
  | Idle
  | Cache_lookup of
      { lookups : int
      ; unclassified : int
      ; failures : failure list
      }
  | Reading of
      { reads : read list
      ; failures : failure list
      }
  | Not_updated of failure list

let index_key (view : Inspection_view.t) = Inspection_view.index_key view

let freshness (view : Inspection_view.t) =
  match view.index with
  | None -> "no prior evidence shown"
  | Some index ->
    if index.cached_unverified
    then "prior evidence kept: CACHED UNVERIFIED"
    else "prior evidence kept: validated"
;;

let scope_text ~domain ~stage = domain ^ "/" ^ stage

let failure_of ~scope ~prior (op : Asic.Pending.t) =
  let error =
    match op.error with
    | Some error -> Some error
    | None ->
      if List.mem [ "failed"; "detached" ] op.state ~equal:String.equal
      then Some op.state
      else None
  in
  Option.map error ~f:(fun error -> { key = op.key; scope; error; prior })
;;

let summarize ~(views : Inspection_view.t list) ~runs (snapshot : Asic.Snapshot.t option) =
  match snapshot with
  | None -> Idle
  | Some snapshot ->
    let find key = List.find snapshot.operations ~f:(fun op -> String.equal op.key key) in
    let active key = Option.filter (find key) ~f:Plain_rpc.active in
    let views =
      List.dedup_and_sort views ~compare:(fun (a : Inspection_view.t) b ->
        Comparable.lift
          [%compare: string * string option]
          ~f:(fun (v : Inspection_view.t) -> index_key v, v.operation_key)
          a
          b)
    in
    let reads, lookups =
      List.concat_map views ~f:(fun view ->
        let index =
          Option.map
            (active (index_key view))
            ~f:(fun op ->
              ( op
              , Index { domain = view.domain; stage = view.stage }
              , String.equal op.kind "inspection" ))
        in
        let detail =
          Option.bind view.operation_key ~f:(fun key ->
            if String.equal key (index_key view)
            then None
            else
              Option.map (active key) ~f:(fun op ->
                ( op
                , Detail { domain = view.domain; stage = view.stage }
                , String.equal op.kind "inspection-detail" )))
        in
        List.filter_opt [ index; detail ])
      |> List.dedup_and_sort ~compare:(fun ((a : Asic.Pending.t), _, _) (b, _, _) ->
        String.compare a.key b.key)
      |> List.partition_map ~f:(fun ((op : Asic.Pending.t), target, known_kind) ->
        match op.activity with
        | Evidence_read when known_kind -> First { key = op.key; run = op.run; target }
        | Evidence_read | Evidence_cache_lookup -> Second true
        | Unreported -> Second false)
    in
    let refreshes =
      List.filter_map snapshot.operations ~f:(fun op ->
        if String.equal op.kind "refresh"
           && Plain_rpc.active op
           && Asic.Pending.Activity.equal op.activity Evidence_read
           && Option.exists op.run ~f:(List.mem runs ~equal:Run_ref.equal)
        then Some { key = op.key; run = op.run; target = Summary_refresh }
        else None)
    in
    let refresh_failures =
      List.filter_map snapshot.operations ~f:(fun op ->
        if String.equal op.kind "refresh"
           && (not (Plain_rpc.active op))
           && Option.exists op.run ~f:(List.mem runs ~equal:Run_ref.equal)
        then (
          let run = Option.value_exn op.run in
          let prior =
            match List.find snapshot.summaries ~f:(fun s -> Run_ref.equal s.run run) with
            | None -> "no prior evidence shown"
            | Some summary ->
              "prior evidence kept: "
              ^
                (match summary.freshness with
                | Validated -> "validated"
                | Cached_unverified -> "CACHED UNVERIFIED"
                | Missing_source -> "MISSING SOURCE"
                | Refresh_failed _ -> "REFRESH FAILED")
          in
          failure_of ~scope:("summary · run " ^ run.id) ~prior op)
        else None)
    in
    let failures =
      List.filter_map views ~f:(fun view ->
        Option.bind view.operation_key ~f:(fun key ->
          Option.bind (find key) ~f:(fun op ->
            if Plain_rpc.active op
            then None
            else
              failure_of
                ~scope:(scope_text ~domain:view.domain ~stage:view.stage)
                ~prior:(freshness view)
                op)))
      |> fun failures -> failures @ refresh_failures
    in
    (match reads @ refreshes, lookups, failures with
     | (_ :: _ as reads), _, failures -> Reading { reads; failures }
     | [], (_ :: _ as lookups), failures ->
       Cache_lookup
         { lookups = List.count lookups ~f:Fn.id
         ; unclassified = List.count lookups ~f:not
         ; failures
         }
     | [], [], (_ :: _ as failures) -> Not_updated failures
     | [], [], [] -> Idle)
;;

let host_views (host : Workspace_host.t) =
  Option.value_map host.registry ~default:[] ~f:(fun registry ->
    List.filter_map registry.Workspace.Snapshot.tiles ~f:(fun tile ->
      Workspace_host.inspection host tile.id))
;;

let of_host ?selected_run (host : Workspace_host.t) snapshot =
  summarize
    ~views:(host_views host)
    ~runs:(Option.to_list selected_run @ Workspace_host.evidence_runs host)
    snapshot
;;

let read_scope read =
  let run = Option.value_map read.run ~default:"" ~f:(fun run -> " · run " ^ run.id) in
  match read.target with
  | Index { domain; stage } -> scope_text ~domain ~stage ^ run
  | Detail { domain; stage } -> scope_text ~domain ~stage ^ " row detail" ^ run
  | Summary_refresh -> "summary" ^ run
;;

let read_detail read =
  (match read.target with
   | Index _ -> "Reading index "
   | Detail _ -> "Reading "
   | Summary_refresh -> "Revalidating ")
  ^ read_scope read
  ^ " · read-only evidence read; not flow execution; no progress total reported"
;;

let failure_detail failure =
  "Not updated " ^ failure.scope ^ ": " ^ failure.error ^ " · " ^ failure.prior
;;

let label = "Evidence"

let row t =
  let module O = Overview_tiles in
  match t with
  | Idle -> O.row ~role:Muted ~details:[ "No evidence read in progress" ] label "idle"
  | Cache_lookup { lookups; unclassified; failures } ->
    (* Still in flight, so never "idle", but no provider operation is claimed. *)
    O.row
      ~role:(if List.is_empty failures then Muted else Warning)
      ~details:
        ((if lookups > 0
          then
            [ sprintf
                "%d cache lookup(s): Workbench-derived cache only; no provider operation"
                lookups
            ]
          else [])
         @ (if unclassified > 0
            then
              [ sprintf "%d evidence lookup(s) the daemon did not classify" unclassified ]
            else [])
         @ List.map failures ~f:failure_detail)
      label
      ((if unclassified = 0 then "cache lookup" else "opening evidence")
       ^
       match failures with
       | [] -> ""
       | first :: _ -> " · not updated: " ^ first.error)
  | Reading { reads; failures } ->
    let details = List.map reads ~f:read_detail @ List.map failures ~f:failure_detail in
    (match reads with
     | [ read ] ->
       O.row
         ~role:Running
         ~status:Running
         ~details
         (* One unaligned label so narrow tiles clip the scope, never the activity. *)
         ("updating evidence · "
          ^
          match read.target with
          | Index { domain; stage } -> scope_text ~domain ~stage
          | Detail { domain; stage } -> scope_text ~domain ~stage ^ " detail"
          | Summary_refresh ->
            "summary " ^ Option.value_map read.run ~default:"" ~f:(fun r -> r.id))
         ""
     | reads ->
       O.row
         ~role:Running
         ~status:Running
         ~details
         (sprintf "updating evidence (%d)" (List.length reads))
         "")
  | Not_updated failures ->
    let first = List.hd_exn failures in
    O.row
      ~role:Warning
      ~details:(List.map failures ~f:failure_detail)
      label
      ("not updated: " ^ first.error)
;;

let session_row ?selected_run host snapshot = row (of_host ?selected_run host snapshot)

(* Shared by the asynchronous request callback and its regression test. Identity fences
   close/reopen; apply_response owns the generation, epoch and exact-operation fence. Only
   an accepted error may publish a global notice. *)
let inspection_receipt host ~tile_id ~identity ~ticket ~publish_notice response =
  if not (phys_equal (Workspace_host.local host tile_id).identity identity)
  then host
  else (
    match Workspace_host.inspection host tile_id with
    | None -> host
    | Some view ->
      let inspection = Inspection_view.apply_response view ticket response in
      let host = Workspace_host.set_inspection host tile_id (Some inspection) in
      (match response with
       | Error message when publish_notice && not (phys_equal inspection view) ->
         { host with notice = "ASIC: " ^ message }
       | _ -> host))
;;

module Test = struct
  let run = Fs0_fixture.run_a

  let index ?(stage = "routing") ?(cached_unverified = false) () : Asic_inspection.Index.t
    =
    { run
    ; execution_file = Fs0_fixture.execution_file run
    ; execution_sha256 = String.make 64 'a'
    ; domain = "timing"
    ; stage
    ; source_digest = String.make 64 'b'
    ; rows =
        [ { id = "path-1"
          ; category = "path"
          ; producer = "sta@11-sta"
          ; corner = Some "slow"
          ; group = Some "clk"
          ; name = "path-1"
          ; value = Some 0.5
          ; unit_ = Some "ns"
          ; status = "met"
          ; source = "{}"
          ; fields = []
          }
        ]
    ; diagnostics = []
    ; truncated = false
    ; cached_unverified
    ; analysis = None
    ; times = Evidence_time.Index.empty
    }
  ;;

  let op ?error ?(activity = Asic.Pending.Activity.Evidence_read) ~key ~kind state
    : Asic.Pending.t
    =
    { key; kind; state; run = Some run; error; activity }
  ;;

  let snapshot ?(inspections = []) operations =
    Some { Fs0_fixture.snapshot with operations; inspections }
  ;;

  let view ?(stage = "routing") () =
    Inspection_view.create ~generation:1 ~run ~domain:"timing" ~stage ()
  ;;

  let key ?(stage = "routing") () = Asic_inspection.index_key ~run ~domain:"timing" ~stage
  let summarize ?(runs = []) views snapshot = summarize ~views ~runs snapshot

  let text ?(icons = Appearance.Icons.None_) t =
    let appearance = { Appearance.default with icons } in
    let row = row t in
    String.concat
      (List.map (Overview_tiles.row_spans ~appearance ~width:80 ~indent:"" row) ~f:snd)
  ;;

  let is_idle = function
    | Idle -> true
    | Cache_lookup _ | Reading _ | Not_updated _ -> false
  ;;

  let running t = Option.equal Overview_tiles.Status.equal (row t).status (Some Running)
end

let%test_unit "WB-003 #1: a delayed explicit refresh shows activity until its result" =
  let open Test in
  (* Validated evidence is on screen; the user asks for an explicit refresh. *)
  let shown =
    Inspection_view.reconcile
      (view ())
      (Option.value_exn (snapshot ~inspections:[ index () ] []))
  in
  let refreshing, operation = Inspection_view.input ~width:80 ~height:20 shown Refresh in
  let refreshing = Option.value_exn refreshing in
  assert (
    match operation with
    | Some (Inspect { refresh = true; _ }) -> true
    | _ -> false);
  (* The daemon held the provider read: every poll while it executes reports activity, and
     the previous index stays on screen, now honestly labelled unverified. *)
  let pending = index ~cached_unverified:true () in
  List.iter [ "pending"; "executing"; "executing"; "executing" ] ~f:(fun state ->
    let snapshot =
      snapshot ~inspections:[ pending ] [ op ~key:(key ()) ~kind:"inspection" state ]
    in
    let view = Inspection_view.reconcile refreshing (Option.value_exn snapshot) in
    assert (Option.is_some view.index);
    assert (
      List.exists
        (Inspection_view.rows ~width:120 ~height:20 view)
        ~f:(String.is_substring ~substring:"CACHED UNVERIFIED"));
    let t = summarize [ view ] snapshot in
    assert (running t);
    assert (String.is_prefix (text t) ~prefix:"updating evidence · timing/routing");
    assert (
      List.exists (row t).details ~f:(String.is_substring ~substring:"not flow execution")));
  (* Terminal result: activity clears. *)
  let done_ =
    summarize
      [ refreshing ]
      (snapshot
         ~inspections:[ index () ]
         [ op ~key:(key ()) ~kind:"inspection" "completed" ])
  in
  assert (is_idle done_ && not (running done_));
  [%test_result: string] (text done_) ~expect:"Evidence: idle"
;;

let%test_unit "WB-003 #2: a cache-only reopen shows no provider operation" =
  let open Test in
  let reopened = view () in
  let lookup =
    summarize
      [ reopened ]
      (snapshot
         [ op ~activity:Evidence_cache_lookup ~key:(key ()) ~kind:"inspection" "executing"
         ])
  in
  assert (not (running lookup));
  assert (not (is_idle lookup));
  assert (not (String.is_substring (text lookup) ~substring:"updating"));
  [%test_result: string] (text lookup) ~expect:"Evidence: cache lookup";
  assert (
    List.exists (row lookup).details ~f:(String.is_substring ~substring:"no provider"));
  (* An unclassified lookup is not claimed to be either a provider read or the cache. *)
  let unclassified =
    summarize
      [ reopened ]
      (snapshot [ op ~activity:Unreported ~key:(key ()) ~kind:"inspection" "executing" ])
  in
  assert (not (running unclassified));
  [%test_result: string] (text unclassified) ~expect:"Evidence: opening evidence";
  assert (
    is_idle
      (summarize
         [ reopened ]
         (snapshot
            [ op
                ~activity:Evidence_cache_lookup
                ~key:(key ())
                ~kind:"inspection"
                "completed"
            ])))
;;

let%test_unit "WB-003 #3: failure and cancellation clear activity and keep a useful \
               error and prior freshness"
  =
  let open Test in
  let view =
    Inspection_view.reconcile
      (view ())
      (Option.value_exn (snapshot ~inspections:[ index () ] []))
  in
  let view, _ = Inspection_view.input ~width:80 ~height:20 view Refresh in
  let view = Option.value_exn view in
  List.iter
    [ "provider timed out after 30s"; "Inspection read cancelled" ]
    ~f:(fun error ->
      let snapshot =
        snapshot
          ~inspections:[ index ~cached_unverified:true () ]
          [ op ~error ~key:(key ()) ~kind:"inspection" "failed" ]
      in
      let view = Inspection_view.reconcile view (Option.value_exn snapshot) in
      let t = summarize [ view ] snapshot in
      assert (not (running t));
      assert (not (is_idle t));
      [%test_result: string] (text t) ~expect:("Evidence: not updated: " ^ error);
      assert (
        List.exists
          (row t).details
          ~f:(String.is_substring ~substring:"prior evidence kept: CACHED UNVERIFIED"));
      (* The inspector itself still shows the prior rows and the same error. *)
      assert (Option.is_some view.index);
      assert (
        List.exists
          (Inspection_view.rows ~width:160 ~height:20 view)
          ~f:(String.is_substring ~substring:error)))
;;

let%test_unit "WB-003 #4: a late response cannot restore activity or evidence for an \
               obsolete selection"
  =
  let open Test in
  let routing = view () in
  let ticket = Inspection_view.capture routing (Inspection_view.operation routing) in
  (* The user moves on to the next stage while the routing read is still in flight. *)
  let timing, _ = Inspection_view.input ~width:80 ~height:20 routing Stage in
  let timing = Option.value_exn timing in
  assert (String.equal timing.stage "timing");
  let late =
    snapshot
      ~inspections:[ index ~stage:"routing" () ]
      [ op ~key:(key ~stage:"routing" ()) ~kind:"inspection" "executing" ]
  in
  let reconciled = Inspection_view.reconcile timing (Option.value_exn late) in
  assert (Option.is_none reconciled.index);
  assert (is_idle (summarize [ reconciled ] late));
  (* A late failure for the old selection does not surface either. *)
  let failed =
    snapshot
      [ op ~error:"late" ~key:(key ~stage:"routing" ()) ~kind:"inspection" "failed" ]
  in
  assert (is_idle (summarize [ reconciled ] failed));
  let applied = Inspection_view.apply_response reconciled ticket (Error "late") in
  assert (Option.is_none applied.error);
  (* Closing the inspector entirely also drops its activity. *)
  assert (is_idle (summarize [] late))
;;

let%test_unit "WB-003 #5: overlapping reads are summarized and never reported idle" =
  let open Test in
  let routing = view () in
  let signoff = view ~stage:"signoff" () in
  let read stage state = op ~key:(key ~stage ()) ~kind:"inspection" state in
  let both =
    summarize
      [ routing; signoff ]
      (snapshot [ read "routing" "executing"; read "signoff" "executing" ])
  in
  assert (running both);
  [%test_result: string] (text both) ~expect:"updating evidence (2)";
  assert (List.length (row both).details = 2);
  (* The same view twice (e.g. three timing panes sharing one view) counts once. *)
  let shared =
    summarize [ routing; routing; routing ] (snapshot [ read "routing" "executing" ])
  in
  [%test_result: string] (text shared) ~expect:"updating evidence · timing/routing";
  (* One finishes; the other is still reported. A cache lookup alongside a read does not
     downgrade the summary, and a lookup alone is still not idle. *)
  let one =
    summarize
      [ routing; signoff ]
      (snapshot [ read "routing" "completed"; read "signoff" "executing" ])
  in
  assert (running one);
  [%test_result: string] (text one) ~expect:"updating evidence · timing/signoff";
  let mixed =
    summarize
      [ routing; signoff ]
      (snapshot
         [ read "routing" "executing"
         ; op
             ~activity:Evidence_cache_lookup
             ~key:(key ~stage:"signoff" ())
             ~kind:"inspection"
             "executing"
         ])
  in
  assert (running mixed);
  (* A detail read and an explicit summary refresh for a shown run both count. *)
  let detail_key =
    Asic_inspection.detail_key
      ~run
      ~domain:"timing"
      ~stage:"routing"
      ~source_digest:(String.make 64 'b')
      ~row_id:"path-1"
  in
  let detailed = { routing with operation_key = Some detail_key } in
  let refresh = op ~key:("refresh:" ^ run.id) ~kind:"refresh" "executing" in
  let three =
    summarize
      ~runs:[ run ]
      [ detailed ]
      (snapshot
         [ read "routing" "executing"
         ; op ~key:detail_key ~kind:"inspection-detail" "executing"
         ; refresh
         ])
  in
  [%test_result: string] (text three) ~expect:"updating evidence (3)";
  (* A refresh for a run no tile shows is out of scope. *)
  assert (is_idle (summarize ~runs:[ Fs0_fixture.run_b ] [] (snapshot [ refresh ])));
  (* A read in progress plus an earlier failure keeps the failure in the details. *)
  let failing =
    summarize
      [ detailed; signoff ]
      (snapshot
         [ read "signoff" "executing"
         ; op ~error:"bad row" ~key:detail_key ~kind:"inspection-detail" "failed"
         ])
  in
  assert (running failing);
  assert (List.exists (row failing).details ~f:(String.is_substring ~substring:"bad row"))
;;

let%test_unit "WB-003: ASCII and Off modes keep a static text label" =
  let open Test in
  let t =
    summarize [ view () ] (snapshot [ op ~key:(key ()) ~kind:"inspection" "executing" ])
  in
  List.iter
    Appearance.Icons.[ Unicode; Ascii; None_ ]
    ~f:(fun icons ->
      assert (
        String.is_substring
          (text ~icons t)
          ~substring:"updating evidence · timing/routing"));
  assert (String.is_prefix (text ~icons:None_ t) ~prefix:"updating evidence")
;;

let%test_unit "WB-003: cache lookup retains concurrent failure and freshness" =
  let open Test in
  let failed =
    Inspection_view.reconcile
      (view ())
      (Option.value_exn (snapshot ~inspections:[ index ~cached_unverified:true () ] []))
  in
  let lookup = view ~stage:"signoff" () in
  let t =
    summarize
      [ failed; lookup ]
      (snapshot
         [ op ~error:"provider timed out" ~key:(key ()) ~kind:"inspection" "failed"
         ; op
             ~activity:Evidence_cache_lookup
             ~key:(key ~stage:"signoff" ())
             ~kind:"inspection"
             "executing"
         ])
  in
  assert (not (running t));
  assert (String.is_substring (text t) ~substring:"cache lookup");
  assert (String.is_substring (text t) ~substring:"provider timed out");
  assert (
    List.exists
      (row t).details
      ~f:(String.is_substring ~substring:"prior evidence kept: CACHED UNVERIFIED"))
;;
