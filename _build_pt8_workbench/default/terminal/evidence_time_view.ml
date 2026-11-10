open! Core
open Hardcaml_workbench_protocol

(* Presentation of typed evidence times. Absolute times are always UTC to the minute and
   say so; ages are coarse (two units at most). A time ahead of this client's clock is
   flagged as possible clock skew instead of being shown as a negative age. Every label
   names what the time measures, so a Workbench read never reads as production. *)

let skew_tolerance_ns = 60_000_000_000L

let absolute at =
  let time = Timestamp.to_time_ns at in
  let date, ofday = Time_ns.to_date_ofday time ~zone:Time_float.Zone.utc in
  let parts = Time_ns.Ofday.to_parts ofday in
  sprintf "%s %02d:%02d UTC" (Date.to_string date) parts.hr parts.min
;;

let duration_text nanoseconds =
  let minutes = Int64.(to_int_exn (nanoseconds / 60_000_000_000L)) in
  let hours = minutes / 60
  and days = minutes / (60 * 24) in
  if minutes < 1
  then "<1m"
  else if minutes < 60
  then sprintf "%dm" minutes
  else if hours < 10
  then
    if minutes % 60 = 0
    then sprintf "%dh" hours
    else sprintf "%dh %dm" hours (minutes % 60)
  else if hours < 48
  then sprintf "%dh" hours
  else if days < 730
  then sprintf "%dd" days
  else sprintf "%dy" (days / 365)
;;

let age ~now at =
  (* Widen before subtracting: the difference of two Int63 instants fits Int64, but need
     not fit the Int63 representation used by Time_ns.Span. *)
  let nanoseconds time =
    Time_ns.to_span_since_epoch time |> Time_ns.Span.to_int63_ns |> Int63.to_int64
  in
  let diff = Int64.(nanoseconds now - nanoseconds (Timestamp.to_time_ns at)) in
  if Int64.(diff >= zero)
  then duration_text diff ^ " ago"
  else if Int64.(neg diff <= skew_tolerance_ns)
  then "just now"
  else "FUTURE +" ^ duration_text (Int64.neg diff) ^ ": clock skew?"
;;

let stamped ~now at = absolute at ^ " (" ^ age ~now at ^ ")"

let production_text ~now : Evidence_time.Production.t -> string = function
  | Unknown -> "unknown"
  | Supplied { at } -> stamped ~now at
  | Rejected { raw; reason } ->
    sprintf "unknown (unusable producer value %S: %s)" raw reason
;;

(* Producers attributed by the index's own rows, in row order. *)
let producers (index : Asic_inspection.Index.t) =
  List.map index.rows ~f:(fun row -> row.producer)
  |> List.stable_dedup ~compare:String.compare
;;

(** Compact list-mode summary: [produced <age|unknown|n/m known> · validated <age>]. *)
let summary ~now (index : Asic_inspection.Index.t) =
  let produced =
    match producers index with
    | [] -> "unknown"
    | producers ->
      let known =
        List.filter_map producers ~f:(fun producer ->
          match Evidence_time.Index.production index.times ~producer with
          | Supplied { at } -> Some at
          | Unknown | Rejected _ -> None)
      in
      (match known with
       | [] -> "unknown"
       | [ at ] when List.length producers = 1 -> age ~now at
       | known ->
         sprintf "%d/%d producers known" (List.length known) (List.length producers))
  in
  let validated =
    match Evidence_time.Index.validated index.times with
    | Some at -> "validated " ^ age ~now at
    | None -> "validation time not recorded"
  in
  "produced " ^ produced ^ " · " ^ validated
;;

(** Labelled metadata lines. Each line names its meaning and recorder. *)
let lines ~now (index : Asic_inspection.Index.t) =
  let production =
    match producers index with
    | [] -> [ "Produced: unknown (no attributed producer)" ]
    | producers ->
      List.map producers ~f:(fun producer ->
        "Produced ("
        ^ producer
        ^ "): "
        ^ production_text ~now (Evidence_time.Index.production index.times ~producer)
        ^ " · producer-reported")
  in
  production
  @ [ (match Evidence_time.Index.validated index.times with
       | Some at ->
         "Validated by Workbench: "
         ^ stamped ~now at
         ^ " · provider read/refresh time, not production"
       | None -> "Validated by Workbench: not recorded for this index")
    ]
  @ Option.value_map
      (Evidence_time.Index.file_modified index.times)
      ~default:[]
      ~f:(fun (path, at) ->
        [ "Observed file modification: "
          ^ stamped ~now at
          ^ " · filesystem mtime of "
          ^ path
          ^ ", not production"
        ])
;;

(** The production time of one row's own producer. Carried-forward rows keep the time of
    the producer that made them, not of the index's stage or of a refresh. *)
let row_line ~now (index : Asic_inspection.Index.t) (row : Asic_inspection.Row.t) =
  "Produced: "
  ^ production_text
      ~now
      (Evidence_time.Index.production index.times ~producer:row.producer)
  ^ " · by "
  ^ row.producer
;;

(** A minute bucket for memoized lines that contain ages; [None] when nothing timed is
    shown, so untimed evidence never invalidates a memo. *)
let age_bucket ~now (index : Asic_inspection.Index.t option) =
  match index with
  | Some { times = { production = []; observations = [] }; _ } | None -> None
  | Some _ ->
    Some (Float.iround_down_exn (Time_ns.Span.to_min (Time_ns.to_span_since_epoch now)))
;;

(** Workbench's own read time from a summary's recorded observation string. *)
let observed_line raw =
  let parsed =
    Option.try_with (fun () ->
      Timestamp.of_time_ns
        (Time_ns.of_time_float_round_nearest (Time_float.of_string_with_utc_offset raw)))
  in
  "Observed by Workbench: "
  ^ Option.value_map parsed ~default:raw ~f:absolute
  ^ " · read time, not production"
;;

(** Summary evidence carries no producer-supplied production time; say so explicitly
    rather than letting the Workbench read time stand in for it. *)
let summary_lines observed_at =
  [ "Produced: unknown · not supplied by the producer"; observed_line observed_at ]
;;

module%test Wb006_timestamp_presentation = struct
  let at ?(minutes = 0.) base =
    Timestamp.of_time_ns (Time_ns.add base (Time_ns.Span.of_min minutes))
  ;;

  let now = Time_ns.of_string_with_utc_offset "2026-10-19 15:30:00Z"

  let%expect_test "valid instants can be farther apart than a Time_ns span" =
    let old = Time_ns.of_string_with_utc_offset "1850-01-01T00:00:00Z" in
    print_endline (age ~now (Timestamp.of_time_ns old));
    print_endline (age ~now:old (Timestamp.of_time_ns now));
    [%expect {|
      176y ago
      FUTURE +176y: clock skew?
      |}]
  ;;

  let%expect_test "absolute times name UTC and ages stay coarse" =
    List.iter
      [ -0.5; -3.; -125.; -600.; -60. *. 30.; -60. *. 24. *. 9.; -60. *. 24. *. 800. ]
      ~f:(fun minutes -> print_endline (stamped ~now (at ~minutes now)));
    [%expect
      {|
        2026-10-19 15:29 UTC (<1m ago)
        2026-10-19 15:27 UTC (3m ago)
        2026-10-19 13:25 UTC (2h 5m ago)
        2026-10-19 05:30 UTC (10h ago)
        2026-10-18 09:30 UTC (30h ago)
        2026-10-10 15:30 UTC (9d ago)
        2024-08-10 15:30 UTC (2y ago)
        |}]
  ;;

  let%expect_test "future values are flagged, never a negative age" =
    List.iter
      [ 0.5; 5.; 60. *. 26. ]
      ~f:(fun minutes -> print_endline (age ~now (at ~minutes now)));
    [%expect
      {|
        just now
        FUTURE +5m: clock skew?
        FUTURE +26h: clock skew?
        |}]
  ;;

  let%expect_test "skew tolerance and minute boundaries retain nanosecond precision" =
    List.iter [ 59_999_999_999L; 60_000_000_000L; 60_000_000_001L ] ~f:(fun ns ->
      let delta = Time_ns.Span.of_int63_ns (Int63.of_int64_exn ns) in
      print_endline (age ~now (Timestamp.of_time_ns (Time_ns.add now delta)));
      print_endline (age ~now (Timestamp.of_time_ns (Time_ns.sub now delta))));
    [%expect
      {|
      just now
      <1m ago
      just now
      1m ago
      FUTURE +1m: clock skew?
      1m ago
      |}]
  ;;

  let%expect_test "the entire representable instant range has safe ages in both \
                   directions"
    =
    let instant ns = Time_ns.of_span_since_epoch (Time_ns.Span.of_int63_ns ns) in
    let first = instant Int63.min_value
    and last = instant Int63.max_value in
    print_endline (age ~now:last (Timestamp.of_time_ns first));
    print_endline (age ~now:first (Timestamp.of_time_ns last));
    print_endline (age ~now:first (Timestamp.of_time_ns first));
    [%expect {|
      292y ago
      FUTURE +292y: clock skew?
      <1m ago
      |}]
  ;;

  let make_index ~times ~producers : Asic_inspection.Index.t =
    { run = Fs0_fixture.run_a
    ; execution_file = "/exact/execution.json"
    ; execution_sha256 = String.make 64 'a'
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = String.make 64 'b'
    ; rows =
        List.map producers ~f:(fun producer ->
          { Asic_inspection.Row.id = producer
          ; category = "path"
          ; producer
          ; corner = None
          ; group = None
          ; name = producer
          ; value = None
          ; unit_ = None
          ; status = "observed"
          ; source = "{}"
          ; fields = []
          })
    ; diagnostics = []
    ; truncated = false
    ; cached_unverified = true
    ; analysis = None
    ; times
    }
  ;;

  let%expect_test "unknown production never borrows a Workbench or file time" =
    let times =
      Evidence_time.Index.with_validated
        { production = []
        ; observations =
            [ File_modified
                { at = at ~minutes:(-90.) now; path = "/exact/execution.json" }
            ]
        }
        ~at:(at ~minutes:(-2.) now)
    in
    let index = make_index ~times ~producers:[ "sta@11-sta" ] in
    print_endline (summary ~now index);
    List.iter (lines ~now index) ~f:print_endline;
    print_endline (row_line ~now index (List.hd_exn index.rows));
    [%expect
      {|
        produced unknown · validated 2m ago
        Produced (sta@11-sta): unknown · producer-reported
        Validated by Workbench: 2026-10-19 15:28 UTC (2m ago) · provider read/refresh time, not production
        Observed file modification: 2026-10-19 14:00 UTC (1h 30m ago) · filesystem mtime of /exact/execution.json, not production
        Produced: unknown · by sta@11-sta
        |}];
    let legacy = make_index ~times:Evidence_time.Index.empty ~producers:[] in
    print_endline (summary ~now legacy);
    List.iter (lines ~now legacy) ~f:print_endline;
    [%expect
      {|
        produced unknown · validation time not recorded
        Produced: unknown (no attributed producer)
        Validated by Workbench: not recorded for this index
        |}]
  ;;

  let%expect_test "carried-forward rows keep their own producer's time and age" =
    let times : Evidence_time.Index.t =
      Evidence_time.Index.with_validated
        { production =
            [ ( "OpenROAD.DetailedRouting@9-route"
              , Supplied { at = at ~minutes:(-60. *. 50.) now } )
            ; "OpenROAD.STAPostPNR@11-sta", Supplied { at = at ~minutes:(-45.) now }
            ; "Legacy@3-x", Rejected { raw = "2026-10-19T10:00:00"; reason = "no offset" }
            ]
        ; observations = []
        }
        ~at:(at now)
    in
    let index =
      make_index
        ~times
        ~producers:
          [ "OpenROAD.STAPostPNR@11-sta"
          ; "OpenROAD.DetailedRouting@9-route"
          ; "Legacy@3-x"
          ]
    in
    print_endline (summary ~now index);
    List.iter index.rows ~f:(fun row -> print_endline (row_line ~now index row));
    (* Refreshing the same bytes moves only the Workbench time. *)
    let refreshed =
      { index with
        times = Evidence_time.Index.with_validated index.times ~at:(at ~minutes:5. now)
      }
    in
    let later = Time_ns.add now (Time_ns.Span.of_min 5.) in
    List.iter refreshed.rows ~f:(fun row ->
      print_endline (row_line ~now:later refreshed row));
    print_endline (summary ~now:later refreshed);
    [%expect
      {|
      produced 2/3 producers known · validated <1m ago
      Produced: 2026-10-19 14:45 UTC (45m ago) · by OpenROAD.STAPostPNR@11-sta
      Produced: 2026-10-17 13:30 UTC (2d ago) · by OpenROAD.DetailedRouting@9-route
      Produced: unknown (unusable producer value "2026-10-19T10:00:00": no offset) · by Legacy@3-x
      Produced: 2026-10-19 14:45 UTC (50m ago) · by OpenROAD.STAPostPNR@11-sta
      Produced: 2026-10-17 13:30 UTC (2d ago) · by OpenROAD.DetailedRouting@9-route
      Produced: unknown (unusable producer value "2026-10-19T10:00:00": no offset) · by Legacy@3-x
      produced 2/3 producers known · validated <1m ago
      |}]
  ;;

  let%expect_test "summary observation strings are labelled reads in UTC" =
    print_endline (observed_line "2026-10-19 11:04:05.123456-04:00");
    print_endline (observed_line "fixed fixture observation");
    [%expect
      {|
        Observed by Workbench: 2026-10-19 15:04 UTC · read time, not production
        Observed by Workbench: fixed fixture observation · read time, not production
        |}]
  ;;
end
