open! Core

(** Execution wall duration, unrelated to circuit timing or evidence freshness. An absent
    containing field means unknown, including legacy data. [measured_seconds] is a frozen
    terminal measurement; zero is real. [started_at] is a real producer/service start,
    never first observation. Only [running=true] authorizes a live estimate from
    [started_at]. A retained start with [running=false] and no measurement is unknown, not
    an elapsed duration. *)
type t =
  { measured_seconds : float option
  ; started_at : Timestamp.t option
  ; running : bool
  }
[@@deriving bin_io, compare, equal, sexp]

let seconds value =
  Option.filter value ~f:(fun n -> Float.is_finite n && Float.(n >= 0. && n <= 1e12))
;;

let timestamp text =
  if String.length text > 128
  then None
  else
    Or_error.try_with (fun () ->
      Timestamp.of_time_ns (Time_ns.of_string_with_utc_offset text))
    |> Result.ok
;;

let make ?measured_seconds ?started_at ~running () =
  let measured_seconds = seconds measured_seconds in
  let running = running && Option.is_some started_at && Option.is_none measured_seconds in
  if Option.is_none measured_seconds && Option.is_none started_at
  then None
  else Some { measured_seconds; started_at; running }
;;

let stopped timing = Option.map timing ~f:(fun t -> { t with running = false })

(** Independent opt-in for ASIC and simulation. Unknown versions are legacy. Request
    records and the base protocol version are unchanged. *)
let header = "X-Workbench-Execution-Timing"

let version = "1"
let negotiated value = Option.value_map value ~default:false ~f:(String.equal version)

let rec strip = function
  | Sexp.Atom _ as atom -> atom
  | List fields ->
    Sexp.List
      (List.filter_map fields ~f:(function
        | Sexp.List [ Atom "execution_timing"; _ ] -> None
        | value -> Some (strip value)))
;;

let negotiate ~header_value sexp = if negotiated header_value then sexp else strip sexp
