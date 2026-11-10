(** Portable layout data only. This module deliberately does not depend on Workspace:
    templates cannot carry registry identities, provider references or client state. View
    kinds are extensible identifiers; importing an unknown kind does not execute it. *)
open! Core

module Geometry = struct
  type t =
    { x : int
    ; y : int
    ; width : int
    ; height : int
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module View = struct
  type t =
    { kind : string
    ; hidden : bool
    ; geometry : Geometry.t
    }
  [@@deriving bin_io, compare, equal, sexp]
end

type t =
  { version : int
  ; name : string
  ; preset : string option [@sexp.default None]
  ; views : View.t list
  }
[@@deriving bin_io, compare, equal, sexp]

let version = 1
let max_encoded_bytes = 1024 * 1024
let max_views = 1000

let valid_label s =
  (not (String.is_empty (String.strip s)))
  && String.length s <= 256
  && not (String.exists s ~f:(fun c -> Char.to_int c < 32 || Char.to_int c = 127))
;;

let validate t =
  let valid_geometry (g : Geometry.t) =
    let limit = 1_000_000 in
    g.x >= 0
    && g.y >= 0
    && g.width > 0
    && g.height > 0
    && g.width <= limit
    && g.height <= limit
    && g.x <= limit - g.width
    && g.y <= limit - g.height
  in
  if t.version <> version
  then Or_error.error_string "Unsupported workspace template version"
  else if not (valid_label t.name)
  then
    Or_error.error_string
      "Template name must contain 1-256 bytes without control characters"
  else if List.length t.views > max_views
  then Or_error.error_string "Workspace template exceeds 1000 views"
  else if Option.exists t.preset ~f:(fun preset -> not (valid_label preset))
  then Or_error.error_string "Invalid template preset identity"
  else if List.exists t.views ~f:(fun v -> not (valid_label v.kind))
  then Or_error.error_string "Invalid template view kind"
  else if List.exists t.views ~f:(fun v -> not (valid_geometry v.geometry))
  then Or_error.error_string "Template geometry must fit positive cells within 1000000"
  else Ok ()
;;

(** Use these at file boundaries rather than the unchecked generated sexp reader. *)
let decode text =
  if String.length text > max_encoded_bytes
  then Or_error.error_string "Workspace template exceeds 1 MiB"
  else
    Or_error.bind
      (Or_error.try_with (fun () -> t_of_sexp (Sexp.of_string text)))
      ~f:(fun t -> Or_error.map (validate t) ~f:(fun () -> t))
;;

let encode t =
  Or_error.map (validate t) ~f:(fun () -> Sexp.to_string_hum (sexp_of_t t) ^ "\n")
;;

let starter name kinds =
  { version
  ; name
  ; preset = None
  ; views =
      List.mapi kinds ~f:(fun i kind ->
        { View.kind
        ; hidden = false
        ; geometry = { x = i mod 2 * 60; y = i / 2 * 16; width = 60; height = 16 }
        })
  }
;;

let generic = starter "Generic" [ "project"; "execution"; "project-tests"; "logs" ]

let asic =
  starter
    "ASIC"
    [ "run-selector"
    ; "asic"
    ; "synthesis"
    ; "placement"
    ; "cts"
    ; "routing"
    ; "timing"
    ; "checks"
    ; "finalization"
    ]
;;
