open! Core
module Backend_id = Backend_id
module Build_ref = Build_ref
module Run_ref = Run_ref

let version = 1

module Limits = struct
  let config_bytes = 16 * 1024
  let discovery_bytes = 1024 * 1024
  let suites = 64
  let cases = 1024
  let parameters = 32
  let key_bytes = 128
  let string_bytes = 4096
  let event_bytes = 16 * 1024
  let stream_bytes = 16 * 1024 * 1024
  let events = 100_000
  let retained_events = 256
  let artifacts = 128
  let artifact_bytes = 64 * 1024 * 1024
  let attempt_artifact_bytes = 256 * 1024 * 1024
  let byte_page = 64 * 1024
  let history_attempts = 100
  let history_bytes = 16 * 1024 * 1024
  let history_artifact_bytes = 512 * 1024 * 1024
  let history_page = 25
end

module Parameter = struct
  type t =
    { key : string
    ; label : string
    ; default : string
    ; choices : string list
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Case = struct
  type t =
    { id : string
    ; label : string
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Suite = struct
  type t =
    { id : string
    ; label : string
    ; cases : Case.t list
    ; parameters : Parameter.t list
    ; default_seed : string
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Discovery = struct
  type t =
    { protocol_version : int
    ; suites : Suite.t list
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Asic_input = struct
  type t =
    { run : Run_ref.t
    ; attempt : string
    ; artifact_id : string
    ; sha256 : string
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Selection = struct
  type t =
    { suite : string
    ; cases : string list
    ; seed : string
    ; parameters : (string * string) list
    ; asic_inputs : Asic_input.t list
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Case_status = struct
  type t =
    | Pending
    | Running
    | Passed
    | Failed
    | Skipped
    | Incomplete
  [@@deriving bin_io, compare, equal, sexp]
end

module Outcome = struct
  type t =
    | Unknown
    | Passed
    | Failed
    | Incomplete
  [@@deriving bin_io, compare, equal, sexp]
end

module Progress = struct
  type t =
    { case_id : string option
    ; completed : int
    ; total : int option
    ; unit_ : string
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Provider = struct
  module Request = struct
    type t =
      { protocol_version : int
      ; attempt_id : string
      ; selection : Selection.t
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Artifact = struct
    type t =
      { id : string
      ; case_id : string option
      ; label : string
      ; kind : string
      ; media_type : string
      ; path : string
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Event = struct
    module Case_finished = struct
      type t =
        { case_id : string
        ; status : Case_status.t
        ; message : string option
        }
      [@@deriving bin_io, compare, equal, sexp]
    end

    type payload =
      | Started
      | Case_started of string
      | Progress of Progress.t
      | Case_finished of Case_finished.t
      | Artifact of Artifact.t
      | Finished of Outcome.t
    [@@deriving bin_io, compare, equal, sexp]

    type t =
      { protocol_version : int
      ; attempt_id : string
      ; sequence : int
      ; payload : payload
      }
    [@@deriving bin_io, compare, equal, sexp]
  end
end
