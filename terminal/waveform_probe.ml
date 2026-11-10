open! Core

(* Agent B integration requirement (this file is an executable, not a library module):
   (executable (name waveform_probe) (modules waveform_probe) (libraries core
   terminal_presentation hardcaml hardcaml_waveterm) (preprocess (pps ppx_jane)))
   terminal_presentation must expose Waveform_data. No build is invoked by the acceptance
   runner. CLI: waveform_probe FILE START STOP [QUERY_TICK ...]. *)
module W = Terminal_presentation.Waveform_data
module V = Terminal_presentation.Waveform_view
module T = Terminal_presentation.Waveform_time

let atom s = Sexp.Atom s
let pair key value = Sexp.List [ atom key; value ]
let integer n = atom (Int.to_string n)
let tick n = atom (Int64.to_string n)

let text_option = function
  | None -> Sexp.List []
  | Some s -> Sexp.List [ atom s ]
;;

let error e = atom (Error.to_string_hum e)
let cpu_time = Stdlib.Sys.time
let elapsed since = atom (Float.to_string ((cpu_time () -. since) *. 1000.))
let hex bytes = String.concat_map bytes ~f:(fun c -> sprintf "%02x" (Char.to_int c))

let view_frames trace ~bytes ~start =
  let _, last = W.time_bounds trace in
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "probe-vcd"
    ; attempt_id = "probe-attempt"
    ; case_id = Some "probe"
    ; label = "probe"
    ; kind = "waveform"
    ; media_type = "text/vcd"
    ; size = Some (String.length bytes)
    ; sha256 = Some (String.make 64 'a')
    ; availability = Available
    }
  in
  let initial = V.receive (V.create ~project:"probe-project" artifact) (Ok trace) in
  let selected = W.signals trace |> Array.to_list |> Fn.flip List.take 3 in
  let initial =
    { initial with
      selected = Int.Set.of_list (List.map selected ~f:(fun s -> s.W.index))
    }
  in
  let advance from amount =
    Int64.(
      if from > max_value - of_int amount then last else min last (from + of_int amount))
  in
  let image_ansi image ~width ~height =
    let buffer = Buffer.create 16384 in
    Notty.Render.to_buffer
      buffer
      Notty.Cap.ansi
      (0, 0)
      (width, height)
      (Bonsai_term.View.Private.notty_image image);
    (* Standalone Render buffers use LF row separators; a real PTY expands these with
       ONLCR. Include CR explicitly for the external ANSI oracle. *)
    String.concat ~sep:"\r\n" (String.split (Buffer.contents buffer) ~on:'\n')
  in
  let ansi view ~width ~height =
    image_ansi (V.render_waves ~hints:false view ~width ~height) ~width ~height
  in
  let frame ?extent name ~width ~span ~window_start ~cursor =
    let height = 24 in
    let view =
      { initial with
        start = window_start
      ; cursor
      ; span = Option.value extent ~default:(Int64.of_int span)
      }
    in
    let view = V.prepare_waves view ~width in
    let mapping = V.waves_mapping view trace ~width in
    let stop = T.stop mapping in
    let columns = T.columns mapping in
    let ruler = T.ruler mapping ~timescale:(W.timescale trace) in
    let offscreen =
      if Int64.(window_start > 0L)
      then Some 0L
      else if Int64.(last > stop)
      then Some last
      else None
    in
    let baseline =
      Option.map offscreen ~f:(fun cursor ->
        pair "offscreen_ansi_hex" (atom (hex (ansi { view with cursor } ~width ~height))))
    in
    Sexp.List
      ([ pair "name" (atom name)
       ; pair "width" (integer width)
       ; pair "height" (integer height)
       ; pair "start" (tick window_start)
       ; pair "stop" (tick stop)
       ; pair "cursor" (tick cursor)
       ; pair "mapping" (atom "inclusive-original-ticks")
       ; pair "extent_basis" (atom view.extent_basis)
       ; pair
           "physical_extent"
           (atom (T.format_compact (W.timescale trace) Int64.(stop - window_start)))
       ; pair "cursor_location" (T.sexp_of_cursor (T.cursor mapping cursor))
       ; pair "physical_cursor" (atom (T.format_time (W.timescale trace) cursor))
       ; pair
           "ruler_labels"
           (Sexp.List
              (List.map ruler.labels ~f:(fun label ->
                 Sexp.List
                   [ pair "tick" (tick label.tick)
                   ; pair "column" (integer label.column)
                   ; pair "text_column" (integer label.text_column)
                   ; pair "text" (atom label.text)
                   ])))
       ; pair "major_columns" (Sexp.List (List.map ruler.major_columns ~f:integer))
       ; pair "minor_columns" (Sexp.List (List.map ruler.minor_columns ~f:integer))
       ; pair
           "cell_bounds"
           (Sexp.List
              (List.init columns ~f:(fun column ->
                 match T.cell_bounds mapping ~column with
                 | None -> Sexp.List []
                 | Some (first, last) -> Sexp.List [ tick first; tick last ])))
       ; pair "timescale" (atom (W.timescale_to_string (W.timescale trace)))
       ; pair "ansi_hex" (atom (hex (ansi view ~width ~height)))
       ; pair
           "signals_ansi_hex"
           (atom
              (hex
                 (image_ansi
                    (V.render_signals ~hints:false view ~width ~height)
                    ~width
                    ~height)))
       ; pair
           "values"
           (Sexp.List
              (List.map selected ~f:(fun signal ->
                 Sexp.List
                   [ atom signal.name
                   ; text_option (W.value_at trace signal ~time:cursor)
                   ])))
       ]
       @ Option.to_list baseline)
  in
  Sexp.List
    [ frame
        "default"
        ~extent:initial.span
        ~width:120
        ~span:0
        ~window_start:initial.start
        ~cursor:initial.cursor
    ; frame "fit" ~extent:last ~width:120 ~span:0 ~window_start:0L ~cursor:initial.cursor
    ; frame
        "fit-narrow"
        ~extent:last
        ~width:32
        ~span:0
        ~window_start:0L
        ~cursor:initial.cursor
    ; frame "expanded-0" ~width:120 ~span:16 ~window_start:start ~cursor:start
    ; frame "expanded-1" ~width:120 ~span:16 ~window_start:start ~cursor:(advance start 1)
    ; frame "expanded-5" ~width:120 ~span:16 ~window_start:start ~cursor:(advance start 5)
    ; frame "compressed-0" ~width:120 ~span:4096 ~window_start:start ~cursor:start
    ; frame
        "compressed-1"
        ~width:120
        ~span:4096
        ~window_start:start
        ~cursor:(advance start 1)
    ; frame
        "compressed-5"
        ~width:120
        ~span:4096
        ~window_start:start
        ~cursor:(advance start 5)
    ; frame
        "compressed-64"
        ~width:120
        ~span:4096
        ~window_start:start
        ~cursor:(advance start 64)
    ; frame "panned" ~width:120 ~span:256 ~window_start:(advance start 20) ~cursor:start
    ; frame "resized" ~width:80 ~span:4096 ~window_start:start ~cursor:(advance start 64)
    ; frame
        "last"
        ~width:120
        ~span:128
        ~window_start:Int64.(max start (last - 64L))
        ~cursor:last
    ]
;;

let run () =
  let args = Sys.get_argv () in
  if Array.length args < 4
  then failwith "usage: waveform_probe FILE START STOP [QUERY_TICK ...]";
  let bytes = In_channel.read_all args.(1) in
  let start = Int64.of_string args.(2)
  and stop = Int64.of_string args.(3) in
  let query_times = List.drop (Array.to_list args) 4 |> List.map ~f:Int64.of_string in
  let budget name default =
    match Sys.getenv ("WB028_" ^ name) with
    | None -> default
    | Some s -> Int.of_string s
  in
  let d = W.default_limits in
  let limits =
    { W.max_bytes = budget "MAX_BYTES" d.max_bytes
    ; max_signals = budget "MAX_SIGNALS" d.max_signals
    ; max_width = budget "MAX_WIDTH" d.max_width
    ; max_changes = budget "MAX_CHANGES" d.max_changes
    ; max_value_bytes = budget "MAX_VALUE_BYTES" d.max_value_bytes
    }
  in
  let since = cpu_time () in
  match W.parse ~limits bytes with
  | Error e ->
    Sexp.List
      [ pair "status" (atom "error")
      ; pair "error" (error e)
      ; pair "parse_ms" (elapsed since)
      ]
  | Ok trace ->
    let parse_ms = elapsed since in
    let signals = W.signals trace in
    let lo, hi = W.time_bounds trace in
    let samples =
      W.signal_samples
        trace
        ~signals:(Array.to_list signals)
        ~times:(Array.of_list query_times)
    in
    let projection =
      Or_error.try_with_join (fun () ->
        let projection_mapping = T.create_window ~columns:80 ~start ~stop in
        let cells =
          Array.init 80 ~f:(fun column ->
            Option.value_exn (T.cell_bounds projection_mapping ~column))
        in
        W.project_window trace ~signals:(Array.to_list signals) ~cells)
    in
    let since = cpu_time () in
    let converted = W.to_waveterm trace ~signals:(Array.to_list signals) ~start ~stop in
    let conversion_ms = elapsed since in
    let conversion, rendering =
      match converted with
      | Error e -> pair "conversion_error" (error e), []
      | Ok waves ->
        (* Independent boundary check: interrogate the installed renderer's data,
           including the cycle immediately preceding each transition. This catches
           off-by-one/rebasing errors without implementing another VCD parser. *)
        (match waves with
         | Hardcaml.Wave_data.By_cycle _ -> failwith "expected sparse event conversion"
         | Hardcaml.Wave_data.By_event rendered ->
           Array.iteri rendered ~f:(fun i wave ->
             let module D = Hardcaml.Wave_data_in_events.Bits in
             let expected_length = Int64.to_int_exn Int64.(stop - start + 1L) in
             assert (D.length wave.wave_data = expected_length);
             let check time =
               if Int64.(time >= start && time <= stop)
               then (
                 let actual =
                   D.get wave.wave_data (Int64.to_int_exn Int64.(time - start))
                 in
                 let expected = W.value_at trace signals.(i) ~time |> Option.value_exn in
                 if not (String.equal (Hardcaml.Bits.to_bstr actual) expected)
                 then
                   failwith
                     ("renderer disagrees at "
                      ^ Int64.to_string time
                      ^ " for "
                      ^ signals.(i).name))
             in
             check start;
             check stop;
             Array.iter
               (W.changes trace signals.(i))
               ~f:(fun change ->
                 check change.time;
                 if Int64.(change.time > 0L) then check Int64.(change.time - 1L))));
        let since = cpu_time () in
        let text =
          Hardcaml_waveterm.Waveform.to_string ~display_width:120 ~display_height:40 waves
        in
        ( pair "conversion" (atom "verified")
        , [ pair "render_ms" (elapsed since)
          ; pair "render_bytes" (integer (String.length text))
          ; pair "render" (atom text)
          ] )
    in
    Sexp.List
      ([ pair "status" (atom "ok")
       ; pair "bytes" (integer (String.length bytes))
       ; pair "parse_ms" parse_ms
       ; pair "conversion_ms" conversion_ms
       ; pair "timescale" (atom (W.timescale_to_string (W.timescale trace)))
       ; pair "bounds" (Sexp.List [ tick lo; tick hi ])
       ; pair "changes" (integer (W.change_count trace))
       ; pair
           "signal_samples_status"
           (match samples with
            | Ok _ -> atom "exact"
            | Error e -> error e)
       ; pair
           "projection"
           (match projection with
            | Error e -> Sexp.List [ pair "error" (error e) ]
            | Ok lanes ->
              Sexp.List
                (List.map lanes ~f:(fun lane ->
                   Sexp.List
                     [ pair "signal" (atom lane.W.signal.name)
                     ; pair "reason" (text_option lane.reason)
                     ; pair
                         "transitions"
                         (Sexp.List (Array.to_list lane.transitions |> List.map ~f:integer))
                     ])))
       ; conversion
       ; pair
           "signals"
           (Sexp.List
              (Array.to_list signals
               |> List.map ~f:(fun signal ->
                 Sexp.List
                   [ pair "name" (atom signal.name)
                   ; pair "identifier" (atom signal.identifier)
                   ; pair "width" (integer signal.width)
                   ; pair
                       "history_length"
                       (integer (Array.length (W.changes trace signal)))
                   ; pair
                       "values"
                       (Sexp.List
                          (match samples with
                           | Error _ -> []
                           | Ok samples ->
                             List.map2_exn
                               query_times
                               (Array.to_list (snd (List.nth_exn samples signal.index)))
                               ~f:(fun time value ->
                                 Sexp.List [ tick time; text_option value ])))
                   ])))
       ]
       @ rendering
       @
       if Option.is_some (Sys.getenv "WB028_VIEW")
       then [ pair "view_frames" (view_frames trace ~bytes ~start) ]
       else [])
;;

let () =
  let result = run () in
  print_endline (Sexp.to_string_mach result)
;;
