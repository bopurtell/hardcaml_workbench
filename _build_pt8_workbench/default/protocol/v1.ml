(** Frozen version 1 application wire definitions.

    This module contains portable values and S-expression codecs only. HTTP, Async, and
    operating-system behavior belong to native transport libraries. *)

open! Core

let version = 1
let content_type = "application/sexp"
let protocol_header = "X-Workbench-Protocol"
let max_request_body_bytes = 1024 * 1024
let max_update_events = 256
let max_poll_timeout_ms = 25_000
let max_log_records = 256
let max_log_bytes = 256 * 1024
let max_artifact_bytes = 256 * 1024
let max_hierarchy_bytes = 8 * 1024 * 1024

module Error = struct
  module Kind = struct
    type t =
      | Invalid_request
      | Unsupported_operation
      | Not_found
      | Conflict
      | Instance_changed
      | Resync_required
      | Internal_failure
    [@@deriving bin_io, compare, equal, sexp]
  end

  type t =
    { kind : Kind.t
    ; message : string
    }
  [@@deriving bin_io, compare, equal, sexp]

  let create kind message = { kind; message }
end

module Daemon_instance_id = struct
  type t = string [@@deriving bin_io, compare, equal, sexp]

  let of_string value = value
  let to_string value = value
end

module Cursor = struct
  type t =
    { instance_id : Daemon_instance_id.t
    ; sequence : int
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Hello = struct
  module Response = struct
    type t =
      { application_version : string
      ; protocol_versions : int list
      ; instance_id : Daemon_instance_id.t
      ; capabilities : string list
      }
    [@@deriving bin_io, compare, equal, sexp]
  end
end

module Environment_selection = struct
  type t =
    | Inherit_daemon
    | Opam_switch of string
  [@@deriving bin_io, compare, equal, sexp]
end

module Environment_summary = struct
  type t =
    { selection : Environment_selection.t
    ; provenance : string
    ; dune_version : string
    ; command_prefix : string list
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Dune_workspace = struct
  module Item = struct
    type t =
      { kind : string
      ; names : string list
      ; source_path : string option
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Inspection = struct
    type t =
      { contexts : string list
      ; items : Item.t list
      }
    [@@deriving bin_io, compare, equal, sexp]
  end
end

module Dune_action = struct
  type t =
    | Build
    | Test
  [@@deriving bin_io, compare, equal, sexp]
end

module Open_project = struct
  module Request = struct
    type t =
      { instance_id : Daemon_instance_id.t
      ; root : string
      ; environment : Environment_selection.t
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Payload = struct
    type t =
      { project : Project.t
      ; environment : Environment_summary.t
      ; workspace : Dune_workspace.Inspection.t
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Response = struct
    type t = (Payload.t, Error.t) Result.t [@@deriving bin_io, compare, equal, sexp]
  end
end

module Submit_job = struct
  module Request = struct
    type t =
      { instance_id : Daemon_instance_id.t
      ; project : Project_id.t
      ; action : Dune_action.t
      ; submission_key : string
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Payload = struct
    type t = { job : Job.t } [@@deriving bin_io, compare, equal, sexp]
  end

  module Response = struct
    type t = (Payload.t, Error.t) Result.t [@@deriving bin_io, compare, equal, sexp]
  end
end

module Refresh_integration = struct
  module Request = struct
    type t =
      { instance_id : Daemon_instance_id.t
      ; project : Project_id.t
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Payload = struct
    (** The manifest has been reloaded on success. [None] means that the valid manifest
        declares no driver, so no discovery job or tool work is needed. [Some job] is the
        queued discovery of the declared driver. *)
    type t = { job : Job.t option } [@@deriving bin_io, compare, equal, sexp]
  end

  module Response = struct
    type t = (Payload.t, Error.t) Result.t [@@deriving bin_io, compare, equal, sexp]
  end
end

module Generate_rtl = struct
  module Request = struct
    type t =
      { instance_id : Daemon_instance_id.t
      ; project : Project_id.t
      ; target : Target_id.t
      ; configuration : Configuration_id.t
      ; submission_key : string
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Payload = struct
    type t = { job : Job.t } [@@deriving bin_io, compare, equal, sexp]
  end

  module Response = struct
    type t = (Payload.t, Error.t) Result.t [@@deriving bin_io, compare, equal, sexp]
  end
end

module Cancel_job = struct
  module Request = struct
    type t =
      { instance_id : Daemon_instance_id.t
      ; job : Job_id.t
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Payload = struct
    type t = { job : Job.t } [@@deriving bin_io, compare, equal, sexp]
  end

  module Response = struct
    type t = (Payload.t, Error.t) Result.t [@@deriving bin_io, compare, equal, sexp]
  end
end

module Read_log = struct
  module Stream = struct
    type t =
      | Stdout
      | Stderr
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Record = struct
    type t =
      { offset : int
      ; stream : Stream.t
      ; data : string
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Request = struct
    type t =
      { instance_id : Daemon_instance_id.t
      ; job : Job_id.t
      ; offset : int
      ; max_records : int
      ; max_bytes : int
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Payload = struct
    type t =
      { records : Record.t list
      ; next_offset : int
      ; eof : bool
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Response = struct
    type t = (Payload.t, Error.t) Result.t [@@deriving bin_io, compare, equal, sexp]
  end
end

module Read_artifact = struct
  module Request = struct
    type t =
      { instance_id : Daemon_instance_id.t
      ; artifact : Artifact_id.t
      ; offset : int
      ; max_bytes : int
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Payload = struct
    type t =
      { data : string
      ; next_offset : int
      ; total_size : int
      ; eof : bool
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Response = struct
    type t = (Payload.t, Error.t) Result.t [@@deriving bin_io, compare, equal, sexp]
  end
end

module Read_hierarchy = struct
  module Request = struct
    type t =
      { instance_id : Daemon_instance_id.t
      ; artifact : Artifact_id.t
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Payload = struct
    type t = { hierarchy : Hierarchy.t } [@@deriving bin_io, compare, equal, sexp]
  end

  module Response = struct
    type t = (Payload.t, Error.t) Result.t [@@deriving bin_io, compare, equal, sexp]
  end
end

module Event = struct
  type t =
    | Project_upsert of Project.t
    | Project_removed of Project_id.t
    | Job_upsert of Job.t
    | Job_removed of Job_id.t
    | Artifact_upsert of Artifact.t
    | Artifact_removed of Artifact_id.t
    | Log_available of
        { job : Job_id.t
        ; next_offset : int
        }
  [@@deriving bin_io, compare, equal, sexp]

  type sequenced =
    { sequence : int
    ; event : t
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Snapshot = struct
  module Request = struct
    type t = { instance_id : Daemon_instance_id.t }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Payload = struct
    type t =
      { projects : Project.t list
      ; jobs : Job.t list
      ; artifacts : Artifact.t list
      ; cursor : Cursor.t
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Response = struct
    type t = (Payload.t, Error.t) Result.t [@@deriving bin_io, compare, equal, sexp]
  end
end

module Updates = struct
  module Request = struct
    type t =
      { instance_id : Daemon_instance_id.t
      ; cursor : Cursor.t
      ; max_events : int
      ; timeout_ms : int
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Payload = struct
    type t =
      { events : Event.sequenced list
      ; next_cursor : Cursor.t
      ; heartbeat : bool
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Response = struct
    type t = (Payload.t, Error.t) Result.t [@@deriving bin_io, compare, equal, sexp]
  end
end

module Codec = struct
  let encode sexp_of value = Sexp.to_string_mach (sexp_of value)

  let decode of_sexp body =
    try Ok (of_sexp (Sexp.of_string body)) with
    | exn -> Error (Error.create Invalid_request (Exn.to_string exn))
  ;;
end
