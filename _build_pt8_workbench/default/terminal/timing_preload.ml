open! Core

(** A bounded, level-triggered planner. Candidates are recomputed from current exact
    workspace bindings; there is deliberately no backlog of obsolete selections. An
    attempt is remembered even on failure/missing publication. Only an explicit user
    action retries it. Scope includes connection and project identity. *)
type t =
  { scope : string
  ; attempted : string list
  ; running : string option
  }

let empty = { scope = ""; attempted = []; running = None }
let limit = 128

let step t ~scope ~enabled ~interactive ~candidates =
  let t = if String.equal t.scope scope then t else { empty with scope } in
  if (not enabled)
     || interactive
     || Option.is_some t.running
     || List.length t.attempted >= limit
  then t, None
  else (
    match
      List.find candidates ~f:(fun key ->
        not (List.mem t.attempted key ~equal:String.equal))
    with
    | None -> t, None
    | Some key -> { t with attempted = key :: t.attempted; running = Some key }, Some key)
;;

let finish t ~scope ~key =
  if String.equal t.scope scope && Option.equal String.equal t.running (Some key)
  then { t with running = None }
  else t
;;

let%test_unit "selection changes discard backlog without releasing active work" =
  let step t candidates =
    step t ~scope:"s" ~enabled:true ~interactive:false ~candidates
  in
  let t, _ = step empty [ "old-source"; "obsolete-selection" ] in
  let t, request = step t [ "new-source" ] in
  assert (Option.is_none request);
  assert (Option.equal String.equal t.running (Some "old-source"));
  let unrelated = finish t ~scope:"s" ~key:"new-source" in
  assert (Option.equal String.equal unrelated.running t.running);
  let t = finish t ~scope:"s" ~key:"old-source" in
  let _, request = step t [ "new-source" ] in
  assert (Option.equal String.equal request (Some "new-source"))
;;

let%test_unit "finite failure, coalescing, priority, scope fences and bounded memory" =
  let plan = step in
  let step ?(enabled = true) ?(interactive = false) t candidates =
    step t ~scope:"connection/project" ~enabled ~interactive ~candidates
  in
  let t, request = step empty [ "exact-a"; "exact-b" ] in
  assert (Option.equal String.equal request (Some "exact-a"));
  assert (Option.is_none (snd (step t [ "exact-a"; "exact-b" ])));
  let stale = finish t ~scope:"old-connection/project" ~key:"exact-a" in
  assert (Option.is_some stale.running);
  let t = finish t ~scope:"connection/project" ~key:"exact-a" in
  for _ = 1 to 100 do
    assert (Option.is_none (snd (step t [ "exact-a" ])))
  done;
  assert (Option.is_none (snd (step ~interactive:true t [ "exact-b" ])));
  assert (Option.is_none (snd (step ~enabled:false t [ "exact-b" ])));
  let t, request = step t [ "exact-b" ] in
  assert (Option.equal String.equal request (Some "exact-b"));
  let t =
    List.fold (List.init 1000 ~f:Int.to_string) ~init:t ~f:(fun t key ->
      let t = { t with running = None } in
      fst (step t [ key ]))
  in
  assert (List.length t.attempted = limit);
  assert (
    Option.is_none (snd (step { t with running = None } [ "exact-a"; "never-seen" ])));
  let _, request =
    plan
      t
      ~scope:"new-connection/project"
      ~enabled:true
      ~interactive:false
      ~candidates:[ "exact-a" ]
  in
  assert (Option.is_some request)
;;
