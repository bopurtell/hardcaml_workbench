open! Core
open Hardcaml_workbench_protocol

let duration seconds =
  let n = Float.to_int (Float.round_down seconds) in
  if n >= 3600
  then sprintf "%dh %02dm %02ds" (n / 3600) (n / 60 % 60) (n % 60)
  else if n >= 60
  then sprintf "%dm %02ds" (n / 60) (n % 60)
  else sprintf "%ds" n
;;

let value ~now (timing : Execution_timing.t option) =
  match timing with
  | None -> "unknown"
  | Some t ->
    (match t.measured_seconds with
     | Some seconds ->
       Option.value_map
         (Execution_timing.seconds (Some seconds))
         ~default:"unknown"
         ~f:duration
     | None when t.running ->
       Option.bind t.started_at ~f:(fun start ->
         Time_ns.diff now (Timestamp.to_time_ns start)
         |> Time_ns.Span.to_sec
         |> fun seconds -> Execution_timing.seconds (Some seconds))
       |> Option.value_map ~default:"unknown" ~f:(fun seconds ->
         duration seconds ^ " elapsed")
     | None -> "unknown")
;;

let line ~now timing = "Time: " ^ value ~now timing

(** Lifecycle status already distinguishes elapsed from terminal measurements in lists. *)
let list_value ~now timing =
  let value = value ~now timing in
  Option.value (String.chop_suffix value ~suffix:" elapsed") ~default:value
;;

let compact_line ~now timing =
  let value = value ~now timing in
  match String.chop_suffix value ~suffix:" elapsed" with
  | Some value -> "Elapsed: " ^ value
  | None -> "Time: " ^ value
;;

let%test_unit "measurements freeze including zero; only valid running starts advance" =
  let now = Time_ns.epoch in
  let later = Time_ns.add now (Time_ns.Span.of_sec 127.) in
  let timing measured_seconds running started_at =
    Some { Execution_timing.measured_seconds; running; started_at }
  in
  let start = Some (Timestamp.of_time_ns now) in
  List.iter
    [ 0., "0s"; 14., "14s"; 127., "2m 07s"; 3723., "1h 02m 03s" ]
    ~f:(fun (seconds, expected) ->
      let t = timing (Some seconds) true start in
      assert (String.equal (value ~now t) expected);
      assert (String.equal (value ~now:later t) expected));
  let running = timing None true start in
  assert (String.equal (value ~now running) "0s elapsed");
  assert (String.equal (value ~now:later running) "2m 07s elapsed");
  List.iter
    [ None
    ; timing None false start
    ; timing None true None
    ; timing None true (Some (Timestamp.of_time_ns later))
    ; timing (Some Float.nan) true start
    ; timing (Some (-1.)) false start
    ; timing (Some Float.infinity) false start
    ]
    ~f:(fun t -> assert (String.equal (value ~now t) "unknown"))
;;
