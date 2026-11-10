open! Core

let rpc_path = "/api/v1/preparation"
let capability = "source-bundle-preparation-v1"

module Selection = Asic.Selection

module Availability = struct
  type reason =
    | Not_configured
    | Invalid_configuration of string
  [@@deriving bin_io, compare, equal, sexp]

  type t =
    | Available
    | Unavailable of reason
  [@@deriving bin_io, compare, equal, sexp]
end

module Outcome = struct
  type t =
    | Building
    | Emitting
    | Completed
    | Build_failed
    | Emission_failed
    | Cancelled
  [@@deriving bin_io, compare, equal, sexp]
end

module Bundle = struct
  type t =
    { bundle_identity : string
    ; plan_identity : string
    ; output_dir : string
    ; reused : bool
    ; plan_json : string
    ; artifacts : Artifact_id.t list
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Attempt = struct
  type t =
    { id : string
    ; selection : Selection.t
    ; selection_identity : string
    ; expected_plan_identity : string option
    ; source_root : string
    ; build_target : string
    ; source_executable : string
    ; results_root : string
    ; timeout_seconds : int
    ; environment : V1.Environment_selection.t
    ; created_at : Timestamp.t
    ; outcome : Outcome.t
    ; build_job : Job.t option
    ; emission_job : Job.t option
    ; bundle : Bundle.t option
    ; diagnostic : string option
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Staged = struct
  (** Input plan only: staging does not generate a provider plan or bundle, nor freeze
      source file contents. The opaque id captures this selection and
      source/build/configuration scope for this daemon session. A new Stage supersedes the
      previous receipt. *)
  type t =
    { id : string
    ; selection : Selection.t
    ; expected_plan_identity : string option
    ; source_root : string
    ; build_target : string
    ; source_executable : string
    ; results_root : string
    ; timeout_seconds : int
    ; environment : V1.Environment_selection.t
    ; created_at : Timestamp.t
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Operation = struct
  type t =
    | Get
    | Prepare of
        { submission_key : string
        ; selection : Selection.t
        ; expected_plan_identity : string option
        }
    | Cancel of string
    | Stage of
        { selection : Selection.t
        ; expected_plan_identity : string option
        }
    | Launch_staged of
        (* Launches only the current stage, once. Reuse the same submission key to observe
           that attempt, including after supersession or config drift. A different key
           cannot launch an already accepted stage again. Cancel addresses attempts only
           and never launches or consumes a stage. *)
        { stage_id : string
        ; submission_key : string
        }
  [@@deriving bin_io, compare, equal, sexp]
end

module Snapshot = struct
  (** Newest first, including failures and cancellations. All evidence and
      job/log/artifact handles are scoped to this daemon session. Poll Get after job/log
      update events. *)
  type t =
    { availability : Availability.t
    ; session_only : bool
    ; requested_attempt : string option
    ; latest : Attempt.t option
    ; history : Attempt.t list
    ; staged : Staged.t option [@sexp.option]
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Request = struct
  type t =
    { instance_id : V1.Daemon_instance_id.t
    ; project : Project_id.t
    ; operation : Operation.t
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Response = struct
  type t = (Snapshot.t, V1.Error.t) Result.t [@@deriving bin_io, compare, equal, sexp]
end
