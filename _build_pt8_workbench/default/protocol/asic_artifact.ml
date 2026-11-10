open! Core

module Reference = struct
  type t =
    { id : string
    ; run : Run_ref.t
    ; terminal_attempt : string
    ; label : string
    ; path : string
    ; sha256 : string
    ; size : int
    ; kind : string
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Page = struct
  type t =
    { artifact_id : string
    ; run : Run_ref.t
    ; terminal_attempt : string
    ; sha256 : string
    ; offset : int
    ; limit : int
    ; next_offset : int
    ; eof : bool
    ; text : string
    ; error : string option
    }
  [@@deriving bin_io, compare, equal, sexp]
end

(** Raw byte pages use hexadecimal transport, independently of text rendering. Offsets and
    limits count decoded bytes, not hexadecimal characters. *)
module Byte_page = struct
  type t =
    { artifact_id : string
    ; run : Run_ref.t
    ; terminal_attempt : string
    ; sha256 : string
    ; offset : int
    ; limit : int
    ; next_offset : int
    ; eof : bool
    ; bytes_hex : string
    ; error : string option
    }
  [@@deriving bin_io, compare, equal, sexp]
end

(** Shared scheduling key. The backend validates the full run reference and artifact ID;
    both paging arguments are included so different page requests never coalesce. *)
let read_key ~(run : Run_ref.t) ~artifact_id ~offset ~limit =
  "artifact-read:"
  ^ run.id
  ^ ":"
  ^ artifact_id
  ^ ":"
  ^ Int.to_string offset
  ^ ":"
  ^ Int.to_string limit
;;

let byte_read_key ~(run : Run_ref.t) ~artifact_id ~offset ~limit =
  "artifact-bytes:"
  ^ run.id
  ^ ":"
  ^ artifact_id
  ^ ":"
  ^ Int.to_string offset
  ^ ":"
  ^ Int.to_string limit
;;
