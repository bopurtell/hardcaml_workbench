(** One supervised action: the Workbench's unit of supervision.

    Every substantial action becomes a job — generate RTL, run tests, run a synthesis
    report, run a flow stage, program a device. A job is not the unit of design identity:
    where a backend already separates an immutable build from its executions, the job
    references those identities through [build] and [run] rather than replacing them.

    Jobs run for minutes to hours, and the daemon outlives its clients. A client exiting
    must not cancel or orphan a job, and a reconnecting client recovers a job's state from
    its snapshot without resubmitting it.

    Logs are not part of this snapshot. A job's stdout and stderr are streamed separately
    and retrieved by identifier, so that a snapshot stays small enough to send on every
    update. *)

open! Core

module Kind = struct
  (** What the job does, named by the subsystem that submitted it.

      Kinds are namespaced strings rather than a closed variant for the same reason
      artifact kinds are: a backend must be able to introduce an action without revising
      the protocol schema. *)
  type t =
    { namespace : string (** [dune], [driver], [vivado], [asic], ... *)
    ; name : string (** [build], [test], [generate_rtl], [synthesis], ... *)
    }
  [@@deriving bin_io, compare, equal, hash, sexp]

  let to_string t = t.namespace ^ "." ^ t.name
end

module State = struct
  type t =
    | Queued
    | Starting
    | Running
    | Complete
    | Failed
    | Cancelled
  [@@deriving bin_io, compare, equal, enumerate, sexp]

  let is_terminal = function
    | Complete | Failed | Cancelled -> true
    | Queued | Starting | Running -> false
  ;;

  let to_string t = Sexp.to_string (sexp_of_t t)
end

module Exit_status = struct
  (** How a supervised process ended.

      [Launch_failed] is distinct from a nonzero exit: a command that could not be started
      did not run and produced no results, and the two must not be shown alike. *)
  type t =
    | Exited of int
    | Signaled of { signal : string }
    | Launch_failed of { reason : string }
  [@@deriving bin_io, compare, equal, sexp]
end

type t =
  { id : Job_id.t
  ; kind : Kind.t
  ; project : Project_id.t
  ; target : Target_id.t option (** absent for generic project actions *)
  ; configuration : Configuration_id.t option
  ; parent : Job_id.t option
  ; children : Job_id.t list
  ; build : Build_ref.t option
  (** the backend build identity, where the backend has one *)
  ; run : Run_ref.t option
  (** the backend execution identity, where the backend has one *)
  ; state : State.t
  ; phase : string option (** what the job is doing now, for display only *)
  ; exit_status : Exit_status.t option (** set once the supervised process ends *)
  ; failure : string option
  (** why a [Failed] job failed, when the reason is not the exit status alone *)
  ; created_at : Timestamp.t
  ; started_at : Timestamp.t option
  ; finished_at : Timestamp.t option
  ; artifacts : Artifact_id.t list (** artifacts this job generated *)
  ; result : Structured_result.t option
  (** present once the job produced a structured result; a job can complete without one *)
  }
[@@deriving bin_io, compare, equal, sexp]

let is_terminal t = State.is_terminal t.state

(** A newly submitted job, before supervision starts. The daemon mints the identifier and
    stamps [created_at]. *)
let create ~id ~kind ~project ~created_at =
  { id
  ; kind
  ; project
  ; target = None
  ; configuration = None
  ; parent = None
  ; children = []
  ; build = None
  ; run = None
  ; state = Queued
  ; phase = None
  ; exit_status = None
  ; failure = None
  ; created_at
  ; started_at = None
  ; finished_at = None
  ; artifacts = []
  ; result = None
  }
;;
