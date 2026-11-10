open! Core
open! Async
open Hardcaml_workbench_protocol

(** Callbacks run on the Service scheduler thread. The supervisor exclusively owns process
    creation, root queueing, logs, cancellation, timeouts and reaping. *)
type t =
  { invocation : Hardcaml_workbench_adapters.Dune_adapter.Invocation.t
  ; timeout_seconds : int
  (** Runs when dequeued, before process creation; failure prevents launch. *)
  ; preflight : unit -> unit Deferred.t
  ; start : unit -> unit
  ; stdout : string -> unit
  ; poll : unit -> bool
  ; drain : unit -> unit Deferred.t
  ; fail : string -> unit
  ; finish : cancelled:bool -> Job.Exit_status.t option -> string option
  }

(** Release reducer/store/buffer closures when Service retains a terminal job for logs. *)
let released : t =
  { invocation = { executable = ""; argv = []; cwd = "/"; environment = Inherit_daemon }
  ; timeout_seconds = 1
  ; preflight = (fun () -> return ())
  ; start = (fun () -> ())
  ; stdout = (fun _ -> ())
  ; poll = (fun () -> true)
  ; drain = (fun () -> return ())
  ; fail = (fun _ -> ())
  ; finish = (fun ~cancelled:_ _ -> None)
  }
;;
