open! Core
module D = Terminal_presentation.Waveform_data
module V = Terminal_presentation.Waveform_view
module T = Terminal_presentation.Waveform_time

type action =
  | Frame of string * int * int
  | Key of char
  | Window of int64 * int64 * int64
  | Seek of string
  | Reload
  | Select_all
[@@deriving of_sexp]

let atom s = Sexp.Atom s
let pair name value = Sexp.List [ atom name; value ]
let number n = atom (Int64.to_string n)
let opt = function None -> Sexp.List [] | Some s -> Sexp.List [ atom s ]

let ansi image ~width ~height =
  let b = Buffer.create 4096 in
  Notty.Render.to_buffer b Notty.Cap.ansi (0, 0) (width, height)
    (Bonsai_term.View.Private.notty_image image);
  String.concat ~sep:"\r\n" (String.split (Buffer.contents b) ~on:'\n')
  |> String.concat_map ~f:(fun c -> sprintf "%02x" (Char.to_int c))
;;

let main () =
  let args = Sys.get_argv () in
  let bytes = In_channel.read_all args.(1) in
  let data = D.parse bytes |> Or_error.ok_exn in
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "c-review-vcd"; attempt_id = "c-review-attempt"; case_id = Some "control"
    ; label = "independent synthetic control"; kind = "waveform"; media_type = "text/vcd"
    ; size = Some (String.length bytes); sha256 = Some (String.make 64 'a')
    ; availability = Available }
  in
  let view = ref (V.receive (V.create ~project:"c-private-review" artifact) (Ok data)) in
  let actions = [%of_sexp: action list] (Sexp.of_string args.(2)) in
  let frames = List.filter_map actions ~f:(function
    | Key key -> view := V.input !view (V.Char key); None
    | Window (start, stop, cursor) ->
      view := { !view with start; span = Int64.(stop-start); cursor; extent_basis = "C requested inclusive window" }; None
    | Seek query ->
      view := V.input !view (V.Char ':');
      for _ = 1 to String.length (!view).query do view := V.input !view V.Backspace done;
      String.iter query ~f:(fun c -> view := V.input !view (V.Char c));
      view := V.input !view V.Enter; None
    | Reload -> view := V.receive ~restore_navigation:true (V.remember !view) (Ok data); None
    | Select_all -> view := { !view with selected = Int.Set.of_list (Array.to_list (D.signals data) |> List.map ~f:(fun s -> s.D.index)) }; None
    | Frame (name,width,height) ->
      view := V.prepare_waves !view ~width;
      let t = !view in
      let mapping = V.waves_mapping t data ~width in
      let columns = T.columns mapping in
      let cells = Array.init columns ~f:(fun column -> Option.value_exn (T.cell_bounds mapping ~column)) in
      let selected = Array.to_list (D.signals data) |> List.filter ~f:(fun s -> Set.mem t.selected s.D.index) in
      let projected = D.project_window data ~signals:selected ~cells in
      Some (Sexp.List
        [ pair "name" (atom name); pair "width" (atom (Int.to_string width)); pair "height" (atom (Int.to_string height))
        ; pair "start" (number t.start); pair "stop" (number (V.stop t data)); pair "span" (number t.span)
        ; pair "cursor" (number t.cursor); pair "basis" (atom t.extent_basis)
        ; pair "cursor_location" (T.sexp_of_cursor (T.cursor mapping t.cursor))
        ; pair "cells" (Sexp.List (Array.to_list cells |> List.map ~f:(fun (a,b) -> Sexp.List [number a;number b])))
        ; pair "values" (Sexp.List (List.map selected ~f:(fun s -> Sexp.List [atom s.D.name;opt (D.value_at data s ~time:t.cursor)])))
        ; pair "projection" (match projected with Error e -> Sexp.List [pair "error" (atom (Error.to_string_hum e))]
            | Ok lanes -> Sexp.List (List.map lanes ~f:(fun lane -> Sexp.List
              [pair "name" (atom lane.D.signal.name);pair "reason" (opt lane.reason)
              ;pair "transitions" ([%sexp_of: int array] lane.transitions)])))
        ; pair "waves_ansi" (atom (ansi (V.render_waves ~hints:false t ~width ~height) ~width ~height))
        ; pair "signals_ansi" (atom (ansi (V.render_signals ~hints:false t ~width ~height) ~width ~height))
        ]))
  in
  print_endline (Sexp.to_string_mach (Sexp.List frames))
;;

let () = main ()
