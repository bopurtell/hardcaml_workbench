open! Core
open Async
open Hardcaml_workbench_protocol

(** Coalesce each read domain independently. A held ASIC or workspace response must not
    serialize the other domains, including an already-known tab's Simulation Get.
    Replacing this object abandons old lanes; response owners still fence transport. *)
type t = unit Deferred.t String.Table.t

let create () = String.Table.create ()

let run t ~key f =
  match Hashtbl.find t key with
  | Some pending -> pending
  | None ->
    let finished = Ivar.create () in
    let pending = Ivar.read finished in
    Hashtbl.set t ~key ~data:pending;
    don't_wait_for
      (Monitor.protect
         ~finally:(fun () ->
           Hashtbl.remove t key;
           Ivar.fill_exn finished ();
           return ())
         f);
    pending
;;

(** The caller fences transport/project/workspace identity through [current]. A Get
    may default the selection, but only its own generation may continue to Observe:
    a newer page request or restored selection owns the view even with the same ID. *)
let refresh_simulation ~current ~request =
  match current () with
  | None -> return ()
  | Some view when view.Simulation_view.busy -> return ()
  | Some view when view.older ->
    Option.value_map view.attempt ~default:(return ()) ~f:(fun id ->
      request (Simulation.Operation.Observe id))
  | Some _ ->
    let pending = request Simulation.Operation.Get in
    let issued = current () in
    let%bind () = pending in
    (match issued, current () with
     | Some issued, Some view
       when issued.request = view.request && not view.busy ->
       Option.value_map view.attempt ~default:(return ()) ~f:(fun id ->
         request (Simulation.Operation.Observe id))
     | _ -> return ())
;;

(** A refresh joins in-flight work; only an explicit invalidation requests a rerun.
    Publish idle and flush durable intent before starting that rerun. *)
module Coordinator = struct
  type t =
    { mutable pending : unit Deferred.t option
    ; mutable again : bool
    }

  let create () = { pending = None; again = false }
  let busy t = Option.is_some t.pending
  let invalidate t = t.again <- true

  let rec request t ?(reschedule = false) ~idle f =
    match t.pending with
    | Some pending ->
      if reschedule then invalidate t;
      pending
    | None ->
      let finished = Ivar.create () in
      let pending = Ivar.read finished in
      t.pending <- Some pending;
      don't_wait_for
        (Monitor.protect
           ~finally:(fun () ->
             t.pending <- None;
             let%map () = idle () in
             Ivar.fill_exn finished ();
             if t.again
             then (
               t.again <- false;
               don't_wait_for (request t ~idle f)))
           f);
      pending
  ;;
end

(** Completion, not issuance, establishes that a preference identity was loaded. A stale
    transport's completion cannot complete the replacement's load. *)
module Load = struct
  type t =
    { mutable completed : string option
    ; mutable generation : int
    }

  type ticket = int

  let create () = { completed = None; generation = 0 }
  let loaded t key = Option.equal String.equal t.completed (Some key)
  let ready t = Option.is_some t.completed

  let begin_load t =
    t.generation <- t.generation + 1;
    t.generation
  ;;

  let complete t ticket key =
    if ticket <> t.generation
    then false
    else (
      t.completed <- Some key;
      true)
  ;;

  let reconnect t ~replacement =
    t.generation <- t.generation + 1;
    if replacement then t.completed <- None
  ;;
end
