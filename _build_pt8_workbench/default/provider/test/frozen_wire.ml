(** Independent snapshot of provider-visible FS2v1 representations before WB-066.
    Intentionally do not alias production types: detects encoding/constructor drift. *)
open! Core

module Backend_id = struct
  type t = string [@@deriving bin_io, sexp]
end

module Build_ref = struct
  type t =
    { backend : Backend_id.t
    ; id : string
    ; label : string option
    }
  [@@deriving bin_io, sexp]
end

module Run_ref = struct
  type t =
    { backend : Backend_id.t
    ; id : string
    ; build : Build_ref.t option
    ; label : string option
    }
  [@@deriving bin_io, sexp]
end

module Parameter = struct
  type t =
    { key : string
    ; label : string
    ; default : string
    ; choices : string list
    }
  [@@deriving bin_io, sexp]
end

module Case = struct
  type t =
    { id : string
    ; label : string
    }
  [@@deriving bin_io, sexp]
end

module Suite = struct
  type t =
    { id : string
    ; label : string
    ; cases : Case.t list
    ; parameters : Parameter.t list
    ; default_seed : string
    }
  [@@deriving bin_io, sexp]
end

module Discovery = struct
  type t =
    { protocol_version : int
    ; suites : Suite.t list
    }
  [@@deriving bin_io, sexp]
end

module Asic_input = struct
  type t =
    { run : Run_ref.t
    ; attempt : string
    ; artifact_id : string
    ; sha256 : string
    }
  [@@deriving bin_io, sexp]
end

module Selection = struct
  type t =
    { suite : string
    ; cases : string list
    ; seed : string
    ; parameters : (string * string) list
    ; asic_inputs : Asic_input.t list
    }
  [@@deriving bin_io, sexp]
end

module Progress = struct
  type t =
    { case_id : string option
    ; completed : int
    ; total : int option
    ; unit_ : string
    }
  [@@deriving bin_io, sexp]
end

module Case_status = struct
  type t =
    | Pending
    | Running
    | Passed
    | Failed
    | Skipped
    | Incomplete
  [@@deriving bin_io, sexp]
end

module Outcome = struct
  type t =
    | Unknown
    | Passed
    | Failed
    | Incomplete
  [@@deriving bin_io, sexp]
end

module Provider = struct
  module Request = struct
    type t =
      { protocol_version : int
      ; attempt_id : string
      ; selection : Selection.t
      }
    [@@deriving bin_io, sexp]
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
    [@@deriving bin_io, sexp]
  end

  module Event = struct
    module Case_finished = struct
      type t =
        { case_id : string
        ; status : Case_status.t
        ; message : string option
        }
      [@@deriving bin_io, sexp]
    end

    type payload =
      | Started
      | Case_started of string
      | Progress of Progress.t
      | Case_finished of Case_finished.t
      | Artifact of Artifact.t
      | Finished of Outcome.t
    [@@deriving bin_io, sexp]

    type t =
      { protocol_version : int
      ; attempt_id : string
      ; sequence : int
      ; payload : payload
      }
    [@@deriving bin_io, sexp]
  end
end
