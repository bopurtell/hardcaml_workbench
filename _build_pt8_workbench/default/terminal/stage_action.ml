open! Core
open Hardcaml_workbench_protocol

let required value ~none = Option.value_map value ~default:(Error none) ~f:(fun x -> Ok x)

type intent =
  | Physical_stage of Asic.Stage.t
  | Fresh_endpoint of string

let endpoint = function
  | Physical_stage stage -> stage.Asic.Stage.id
  | Fresh_endpoint endpoint -> endpoint
;;

let advertised_selection = function
  | Physical_stage stage -> stage.Asic.Stage.action
  | Fresh_endpoint _ -> None
;;

let resolve_intent ~intent ~remembered ~observed ~(snapshot : Asic.Snapshot.t option) =
  let endpoint = endpoint intent in
  match advertised_selection intent with
  | Some selection -> Ok selection
  | None ->
    let open Result.Let_syntax in
    let%bind snapshot =
      required snapshot ~none:"Discover ASIC capabilities first (press r to retry)"
    in
    let%bind selection =
      match Option.first_some remembered observed with
      | Some selection -> Ok selection
      | None ->
        required
          snapshot.catalog_default
          ~none:"No declared catalog default; choose explicit flow/profile inputs"
        |> Result.map ~f:(fun pair ->
          { Asic.Selection.flow = pair.flow
          ; profile = pair.profile
          ; endpoint
          ; assignments = []
          })
    in
    let%bind flow =
      List.find snapshot.flows ~f:(fun flow -> String.equal flow.id selection.flow)
      |> required ~none:("Selected flow unavailable: " ^ selection.flow)
    in
    if not (List.mem flow.profiles selection.profile ~equal:String.equal)
    then
      Error ("Selected profile unavailable: " ^ selection.flow ^ "/" ^ selection.profile)
    else if not (List.mem flow.fresh_stage_endpoints endpoint ~equal:String.equal)
    then Error ("Unsupported fresh endpoint: " ^ selection.flow ^ "/" ^ endpoint)
    else Ok { selection with endpoint }
;;

let resolve ~stage ~remembered ~observed ~snapshot =
  resolve_intent ~intent:(Physical_stage stage) ~remembered ~observed ~snapshot
;;

let%test_unit "fresh stage resolution captures exact inputs and rejects stale choices" =
  let stage : Asic.Stage.t =
    { id = "routing"
    ; name = "Routing"
    ; status = Not_requested
    ; requested = false
    ; reason = None
    ; action = None
    ; execution_timing = None
    }
  in
  let selection : Asic.Selection.t =
    { flow = "standard"
    ; profile = "balanced"
    ; endpoint = "synthesis"
    ; assignments = [ "CLOCK=9"; "opaque=value with spaces" ]
    }
  in
  let snapshot =
    { Fs0_fixture.snapshot with
      flows =
        [ { id = "other"
          ; profiles = [ "first" ]
          ; default_profile = "first"
          ; fresh_stage_endpoints = []
          }
        ; { id = "standard"
          ; profiles = [ "balanced"; "delay" ]
          ; default_profile = "delay"
          ; fresh_stage_endpoints = [ "routing" ]
          }
        ]
    ; catalog_default = Some { flow = "standard"; profile = "balanced" }
    }
  in
  let resolve ?(stage = stage) ?remembered ?observed ?(snapshot = Some snapshot) () =
    resolve ~stage ~remembered ~observed ~snapshot
  in
  let expect result expected =
    match result with
    | Ok actual -> assert (Asic.Selection.equal actual expected)
    | Error reason -> failwith reason
  in
  expect (resolve ~remembered:selection ()) { selection with endpoint = "routing" };
  expect (resolve ~observed:selection ()) { selection with endpoint = "routing" };
  expect (resolve ()) { selection with endpoint = "routing"; assignments = [] };
  expect
    (resolve ~remembered:selection ~observed:{ selection with profile = "delay" } ())
    { selection with endpoint = "routing" };
  assert (Result.is_error (resolve ~remembered:{ selection with flow = "gone" } ()));
  assert (Result.is_error (resolve ~remembered:{ selection with profile = "gone" } ()));
  assert (Result.is_error (resolve ~snapshot:None ()));
  assert (
    Result.is_error (resolve ~snapshot:(Some { snapshot with catalog_default = None }) ()));
  assert (Result.is_error (resolve ~stage:{ stage with id = "invented" } ()));
  expect
    (resolve ~stage:{ stage with action = Some selection } ~snapshot:None ())
    selection
;;

let%test_unit "fresh Timing intent preserves captured inputs and requires current catalog"
  =
  let observed : Asic.Selection.t =
    { flow = "upgraded"
    ; profile = "balanced"
    ; endpoint = "signoff"
    ; assignments = [ "CLOCK=9" ]
    }
  in
  let flow : Asic.Flow.t =
    { id = observed.flow
    ; profiles = [ "balanced"; "delay" ]
    ; default_profile = "delay"
    ; fresh_stage_endpoints = [ "timing" ]
    }
  in
  let snapshot = { Fs0_fixture.snapshot with flows = [ flow ] } in
  let resolve ?remembered ?(snapshot = Some snapshot) () =
    resolve_intent
      ~intent:(Fresh_endpoint "timing")
      ~remembered
      ~observed:(Some observed)
      ~snapshot
  in
  assert (
    Asic.Selection.equal
      (Result.ok_or_failwith (resolve ()))
      { observed with endpoint = "timing" });
  let remembered =
    { observed with profile = "delay"; assignments = [ "CLOCK=7"; "X=a b" ] }
  in
  assert (
    Asic.Selection.equal
      (Result.ok_or_failwith (resolve ~remembered ()))
      { remembered with endpoint = "timing" });
  assert (Result.is_error (resolve ~snapshot:None ()));
  assert (
    Result.is_error
      (resolve
         ~snapshot:
           (Some { snapshot with flows = [ { flow with fresh_stage_endpoints = [] } ] })
         ()))
;;
