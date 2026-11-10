open! Core
include Hardcaml_workbench_provider.Wire

let rpc_path = "/api/v1/simulation"

module Parent = struct
  type t =
    { attempt_id : string
    ; job : Job_id.t
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Captured = struct
  type t =
    { selection : Selection.t
    ; discovery_digest : string
    ; provider_executable : string
    ; provider_args : string list
    ; environment : V1.Environment_selection.t
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Lifecycle = struct
  type t =
    | Queued
    | Running
    | Finished
    | Cancelled
    | Interrupted
  [@@deriving bin_io, compare, equal, sexp]
end

module Artifact = struct
  module Availability = struct
    type t =
      | Available
      | Missing
      | Changed
      | Rejected of string
    [@@deriving bin_io, compare, equal, sexp]
  end

  type t =
    { id : string
    ; attempt_id : string
    ; case_id : string option
    ; label : string
    ; kind : string
    ; media_type : string
    ; size : int option
    ; sha256 : string option
    ; availability : Availability.t
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Case_result = struct
  type t =
    { case_id : string
    ; status : Case_status.t
    ; message : string option
    ; progress : Progress.t option
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Attempt = struct
  type t =
    { id : string
    ; job : Job_id.t
    ; project_root : string
    ; created_at : string
    ; parent : Parent.t option
    ; captured : Captured.t
    ; lifecycle : Lifecycle.t
    ; outcome : Outcome.t
    ; exit_code : int option
    ; diagnostic : string option
    ; progress : Progress.t option
    ; cases : Case_result.t list
    ; artifacts : Artifact.t list
    ; next_sequence : int
    ; recent_events : Provider.Event.t list
    ; execution_timing : Execution_timing.t option
         [@sexp.default None] [@sexp_drop_default.equal]
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Summary = struct
  type t =
    { id : string
    ; job : Job_id.t
    ; suite : string
    ; seed : string
    ; execution_timing : Execution_timing.t option
         [@sexp.default None] [@sexp_drop_default.equal]
    ; created_at : string
    ; parent : Parent.t option
    ; lifecycle : Lifecycle.t
    ; outcome : Outcome.t
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Byte_page = struct
  type t =
    { attempt_id : string
    ; artifact_id : string
    ; sha256 : string
    ; offset : int
    ; next_offset : int
    ; total_size : int
    ; eof : bool
    ; bytes_hex : string
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Operation = struct
  type t =
    | Get
    | Discover
    | Launch of
        { submission_key : string
        ; discovery_digest : string
        ; selection : Selection.t
        }
    | Rerun of
        { submission_key : string
        ; attempt_id : string
        ; cases : string list
        }
    | Observe of string
    | History of
        { before : string option
        ; limit : int
        }
    | Cancel of string
    | Read_artifact_bytes of
        { attempt_id : string
        ; artifact_id : string
        ; sha256 : string
        ; offset : int
        ; limit : int
        }
  [@@deriving bin_io, compare, equal, sexp]
end

module Snapshot = struct
  type t =
    { configured : bool
    ; discovery : Discovery.t option
    ; discovery_digest : string option
    ; discovery_job : Job_id.t option
    ; discovery_error : string option
    ; attempts : Summary.t list
    ; next_before : string option
    ; detail : Attempt.t option
    ; byte_page : Byte_page.t option
    ; history_error : string option
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

  let sexp_of_negotiated ~execution_timing_header_value response =
    sexp_of_t response
    |> Execution_timing.negotiate ~header_value:execution_timing_header_value
  ;;
end
