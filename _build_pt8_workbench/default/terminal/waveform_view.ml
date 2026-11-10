open! Core
module D = Waveform_data
module Time = Waveform_time

type value_layout = Waveform_preferences.value_layout =
  | Inline
  | Stacked

(* Legacy exact-renderer raster helper retained for API/probe compatibility. The
   production graph uses bounded original-event cell projection, not this tick cap. *)
let max_span = 4096L
let max_selected = 16

type loaded =
  | Loading
  | Failed of string
  | Ready of D.t

type editing =
  | Filter
  | Time

type t =
  { project : string
  ; artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t
  ; loaded : loaded
  ; filter : string
  ; editing : editing option
  ; query : string
  ; focus : int
  ; selected : Int.Set.t
  ; cursor : int64
  ; start : int64
  ; span : int64 (* elapsed tick distance, not inclusive tick count *)
  ; extent_basis : string
  ; notice : string
  ; value_offset : int
  ; value_page_size : int
  ; identity_scroll : int option
  ; viewport_ticks : int64 option
  ; mutable cache : (int * int * int * int64 * int64 * int list * string) option
  }

let create ~project artifact =
  { project
  ; artifact
  ; loaded = Loading
  ; filter = ""
  ; editing = None
  ; query = ""
  ; focus = 0
  ; selected = Int.Set.empty
  ; cursor = 0L
  ; start = 0L
  ; span = 128L
  ; extent_basis = "Default extent"
  ; notice = "Fetching bounded bytes; verifying exact identity and SHA256"
  ; cache = None
  ; value_offset = 0
  ; value_page_size = 32
  ; identity_scroll = None
  ; viewport_ticks = None
  }
;;

let same t ~project artifact =
  String.equal t.project project
  && Hardcaml_workbench_protocol.Simulation.Artifact.equal t.artifact artifact
;;

let remember t =
  { t with
    loaded = Loading
  ; cache = None
  ; editing = None
  ; identity_scroll = None
  ; notice = "Fetching bounded bytes; verifying exact identity and SHA256"
  }
;;

let default_extent data =
  let first, last = D.time_bounds data in
  match D.infer_clock data with
  | Some (signal, period) ->
    let distance = Int64.(last - first) in
    let clipped = Int64.(period > distance / 8L) in
    let span = if clipped then distance else Int64.(period * 8L) in
    ( first
    , span
    , sprintf
        "%s · inferred %s period %s (view heuristic)"
        (if clipped then "8-cycle target (clipped to trace)" else "8 cycles")
        signal.D.reference
        (Time.format_compact (D.timescale data) period) )
  | None -> first, Int64.(last - first), "Fit full trace · no reliable clock inferred"
;;

let receive ?(restore_navigation = false) t = function
  | Error e -> { t with loaded = Failed (Error.to_string_hum e); cache = None }
  | Ok data ->
    let first, span, extent_basis = default_extent data in
    let received =
      { t with
        loaded = Ready data
      ; cursor = first
      ; start = first
      ; span
      ; extent_basis
      ; notice = ""
      ; selected =
          D.signals data
          |> Array.to_list
          |> Fn.flip List.take 8
          |> List.map ~f:(fun s -> s.D.index)
          |> Int.Set.of_list
      ; cache = None
      }
    in
    if restore_navigation
    then
      { received with
        cursor = t.cursor
      ; start = t.start
      ; span = t.span
      ; extent_basis = t.extent_basis
      ; selected = t.selected
      }
    else received
;;

let filtered t data =
  D.signals data
  |> Array.to_list
  |> List.filter ~f:(fun s ->
    String.is_substring (String.lowercase s.D.name) ~substring:(String.lowercase t.filter))
;;

let clamp_time data time =
  let first, last = D.time_bounds data in
  Int64.max first (Int64.min last time)
;;

let stop t data =
  let _, last = D.time_bounds data in
  (* Subtraction before addition also handles timestamps near Int64.max_value. *)
  Int64.(t.start + min t.span (last - t.start))
;;

type input =
  | Char of char
  | Up
  | Down
  | Left
  | Right
  | Enter
  | Escape
  | Backspace
  | Delete_word

let drop_character text =
  let rec start offset =
    if offset > 0 && Char.to_int text.[offset] land 0xc0 = 0x80
    then start (offset - 1)
    else offset
  in
  if String.is_empty text
  then text
  else String.prefix text (start (String.length text - 1))
;;

let delete_word text =
  let word c = Char.is_alphanum c || Char.equal c '_' || Char.to_int c >= 128 in
  let rec skip offset predicate =
    if offset > 0 && predicate text.[offset - 1]
    then skip (offset - 1) predicate
    else offset
  in
  let offset = skip (String.length text) (fun c -> not (word c)) in
  String.prefix text (skip offset word)
;;

(* Use the modifiers that the native decoder actually preserves. DEL without a modifier
   remains ordinary Backspace; it cannot identify a distinct gesture. Ctrl-W is available
   even when the terminal maps both gestures to plain DEL. *)
let edit_key (event : Bonsai_term.Event.t) =
  match event with
  | Key_press { key = Backspace; mods } ->
    Some
      (if List.exists mods ~f:(function
            | Ctrl | Meta -> true
            | _ -> false)
       then Delete_word
       else Backspace)
  | Key_press { key = ASCII ('w' | 'W' | 'h' | 'H' | '\008' | '\127'); mods }
    when List.exists mods ~f:(function
           | Ctrl -> true
           | _ -> false) -> Some Delete_word
  | Key_press { key = Uchar c; mods }
    when List.exists mods ~f:(function
           | Ctrl -> true
           | _ -> false)
         && List.exists [ 'w'; 'W'; 'h'; 'H'; '\008'; '\127' ] ~f:(fun x ->
           Uchar.equal c (Uchar.of_char x)) -> Some Delete_word
  | Key_press { key = ASCII '\023'; mods = [] } -> Some Delete_word
  | Key_press { key = ASCII ('\008' | '\127'); mods = [] } -> Some Backspace
  | _ -> None
;;

let input t key =
  match t.identity_scroll with
  | Some scroll ->
    (match key with
     | Escape | Char ('q' | 'i') -> { t with identity_scroll = None }
     | Down | Char 'j' -> { t with identity_scroll = Some (scroll + 1) }
     | Up | Char 'k' -> { t with identity_scroll = Some (Int.max 0 (scroll - 1)) }
     | _ -> t)
  | None ->
    (match t.editing with
     | Some editing ->
       (match key with
        | Escape -> { t with editing = None; query = "" }
        | Enter ->
          (match editing with
           | Filter ->
             { t with filter = t.query; editing = None; focus = 0; value_offset = 0 }
           | Time ->
             (match t.loaded, Or_error.try_with (fun () -> Int64.of_string t.query) with
              | Ready data, Ok time ->
                let time = clamp_time data time in
                { t with
                  cursor = time
                ; start = time
                ; editing = None
                ; notice = ""
                ; extent_basis = "Manual window"
                }
              | _ -> { t with notice = "Enter an integer VCD tick" }))
        | Backspace -> { t with query = drop_character t.query }
        | Delete_word ->
          (match editing with
           | Filter -> { t with query = delete_word t.query }
           | Time -> t)
        | Char c when Char.is_print c && String.length t.query < 256 ->
          { t with query = t.query ^ String.of_char c }
        | _ -> t)
     | None ->
       (match key, t.loaded with
        | Char 'i', _ -> { t with identity_scroll = Some 0 }
        | Char '/', _ -> { t with editing = Some Filter; query = t.filter }
        | Char ':', _ -> { t with editing = Some Time; query = Int64.to_string t.cursor }
        | _, (Loading | Failed _) -> t
        | _, Ready data ->
          let signals = filtered t data in
          let move delta =
            { t with
              focus = Int.max 0 (Int.min (List.length signals - 1) (t.focus + delta))
            ; value_offset = 0
            }
          in
          let cursor time =
            let cursor = clamp_time data time in
            let start =
              if Int64.(cursor < t.start || cursor > stop t data) then cursor else t.start
            in
            { t with
              cursor
            ; start
            ; extent_basis =
                (if Int64.equal start t.start then t.extent_basis else "Manual window")
            }
          in
          (match key with
           | Char 'f' ->
             let first, last = D.time_bounds data in
             { t with
               start = first
             ; span = Int64.(last - first)
             ; extent_basis = "Fit full trace"
             ; notice = ""
             ; viewport_ticks = None
             }
           | Char 'd' ->
             let start, span, extent_basis = default_extent data in
             { t with start; span; extent_basis; notice = ""; viewport_ticks = None }
           | Up | Char 'k' -> move (-1)
           | Down | Char 'j' -> move 1
           | Char '{' ->
             { t with value_offset = Int.max 0 (t.value_offset - t.value_page_size) }
           | Char '}' ->
             let limit =
               Option.value_map (List.nth signals t.focus) ~default:0 ~f:(fun s ->
                 Int.max 0 (s.D.width - 1))
             in
             { t with value_offset = Int.min limit (t.value_offset + t.value_page_size) }
           | Left | Char 'h' -> cursor Int64.(max 0L (t.cursor - 1L))
           | Right | Char 'l' ->
             let _, last = D.time_bounds data in
             cursor (if Int64.(t.cursor < last) then Int64.succ t.cursor else last)
           | Char 'g' -> cursor (fst (D.time_bounds data))
           | Char 'G' -> cursor (snd (D.time_bounds data))
           | Char '[' ->
             { t with
               extent_basis = "Manual window"
             ; start = clamp_time data Int64.(max 0L (t.start - max 1L (t.span / 2L)))
             }
           | Char ']' ->
             let _, last = D.time_bounds data in
             { t with
               extent_basis = "Manual window"
             ; start = Int64.(t.start + min (last - t.start) (max 1L (t.span / 2L)))
             }
           | Char ('+' | '=') ->
             { t with
               span = Int64.(t.span / 2L)
             ; extent_basis = "Manual window"
             ; start = t.cursor
             ; viewport_ticks = None
             }
           | Char '-' ->
             let first, last = D.time_bounds data in
             let distance = Int64.(last - first) in
             { t with
               span =
                 (if Int64.(t.span > distance / 2L)
                  then distance
                  else Int64.min distance (Int64.max 1L Int64.(t.span * 2L)))
             ; extent_basis = "Manual window"
             ; start = t.cursor
             ; viewport_ticks = None
             }
           | Enter ->
             (match List.nth signals t.focus with
              | None -> t
              | Some s ->
                if Set.mem t.selected s.index
                then { t with selected = Set.remove t.selected s.index; notice = "" }
                else if Set.length t.selected >= max_selected
                then
                  { t with notice = "Selection limit: 16 signals; deselect a lane first" }
                else { t with selected = Set.add t.selected s.index; notice = "" })
           | _ -> t)))
;;

let safe = Artifact_view.safe

let box ~width ~height view =
  let open Bonsai_term in
  let view =
    View.crop
      ~r:(Int.max 0 (View.width view - width))
      ~b:(Int.max 0 (View.height view - height))
      view
  in
  View.zcat [ view; View.rectangle ~width ~height () ]
;;

(* The installed renderer's -1 is ONE char/tick, not compression. Other negative codes are
   ticks/char; nonnegative codes are 2*(code+1) chars/tick. Fit a power-of-two integer
   raster, never an approximate fractional clock. The visible range snaps to the actual
   number of cells (also on resize). *)
type raster =
  { code : int
  ; ticks : int
  ; description : string
  }

let raster ~columns ~target =
  let columns = Int.max 1 columns in
  let expanded =
    List.init 12 ~f:(fun n ->
      let cells = Int.pow 2 n in
      let code = if cells = 1 then -1 else (cells / 2) - 1 in
      { code
      ; ticks = Time.capacity ~code ~columns
      ; description = sprintf "%d cells/tick" cells
      })
  in
  let compressed =
    List.init 12 ~f:(fun n ->
      let ticks = Int.pow 2 (n + 1) in
      { code = -ticks
      ; ticks = Time.capacity ~code:(-ticks) ~columns
      ; description =
          sprintf "%d ticks/cell (compressed; multiple transitions = dense mark)" ticks
      })
  in
  expanded @ compressed
  |> List.filter ~f:(fun r -> r.ticks <= Int64.to_int_exn max_span)
  |> List.filter ~f:(fun r -> r.ticks <= target)
  |> List.min_elt ~compare:(fun a b ->
    Int.compare (Int.abs (a.ticks - target)) (Int.abs (b.ticks - target)))
  |> Option.value_exn
;;

let frame_geometry appearance (dimensions : Bonsai_term.Dimensions.t) =
  Panel.geometry
    ~framed:(Panel.framed appearance ~width:dimensions.width ~height:dimensions.height)
    ~width:dimensions.width
    ~height:dimensions.height
    ~horizontal_padding:0
    ~vertical_padding:0
;;

let sidebar_width t ~width =
  let names =
    match t.loaded with
    | Loading | Failed _ -> []
    | Ready data -> filtered t data |> List.map ~f:(fun s -> String.length s.D.name + 8)
  in
  Int.min
    (Int.max 18 (width / 3))
    (Int.min
       30
       (Int.max 20 (List.max_elt names ~compare:Int.compare |> Option.value ~default:20)))
;;

let wave_labels_width width = Int.min 14 (Int.max 10 (width / 6))

type waves_geometry =
  { label_width : int
  ; plot_width : int
  ; columns : int
  ; graph_height : int
  ; graph_y : int
  ; plot_x : int
  ; plot_y : int
  ; ruler_y : int
  ; marks_y : int
  }

let waves_geometry ~width ~height =
  let label_width = wave_labels_width width in
  let graph_width = Int.max 7 (Int.min 1024 width) in
  let plot_width = Int.max 7 (graph_width - label_width - 1) in
  { label_width
  ; plot_width
  ; columns = plot_width - 2
  ; graph_height = Int.max 3 (Int.min 80 (height - 6))
  ; graph_y = 4
  ; plot_x = label_width + 2
  ; plot_y = 5
  ; ruler_y = 2
  ; marks_y = 3
  }
;;

let waves_mapping t data ~width =
  let g = waves_geometry ~width ~height:10 in
  Time.create_window ~columns:g.columns ~start:t.start ~stop:(stop t data)
;;

let prepare ?(appearance = Appearance.default) t dimensions =
  ignore (appearance, dimensions);
  t
;;

let graph t data ~width ~height signals =
  let stop = stop t data in
  let ids = List.map signals ~f:(fun s -> s.D.index) in
  match t.cache with
  | Some (w, h, code, start, finish, previous, text)
    when w = width
         && h = height
         && code = 0
         && Int64.equal start t.start
         && Int64.equal finish stop
         && List.equal Int.equal ids previous -> text
  | _ ->
    let result =
      Or_error.try_with_join (fun () ->
        let open Or_error.Let_syntax in
        let columns = Int.max 1 (width - 2) in
        let mapping = Time.create_window ~columns ~start:t.start ~stop in
        let cells =
          Array.init columns ~f:(fun column ->
            Option.value_exn (Time.cell_bounds mapping ~column))
        in
        let%map lanes = D.project_window data ~signals ~cells in
        let border left middle right =
          left ^ String.concat (List.init columns ~f:(fun _ -> middle)) ^ right
        in
        let row text =
          "│" ^ text ^ String.make (Int.max 0 (columns - String.length text)) ' ' ^ "│"
        in
        let rows =
          List.concat_map lanes ~f:(fun lane ->
            let s = lane.D.signal in
            let lane_height = if s.width = 1 then 2 else 3 in
            List.init lane_height ~f:(fun y ->
              match lane.reason with
              | Some reason ->
                row
                  (if y = (lane_height - 1) / 2
                   then String.prefix (reason ^ "; no graph") columns
                   else "")
              | None ->
                let chars =
                  Array.mapi lane.samples ~f:(fun i value ->
                    if lane.transitions.(i) >= 2
                    then '#'
                    else if lane.transitions.(i) = 1
                    then '|'
                    else if s.width > 1
                    then if y = 1 then '=' else '-'
                    else (
                      match value with
                      | Some "1" -> if y = 0 then '_' else ' '
                      | _ -> if y = 1 then '_' else ' '))
                in
                if s.width > 1 && y = 1
                then (
                  let rec label i =
                    if i < Array.length chars
                    then
                      if lane.transitions.(i) <> 0
                      then label (i + 1)
                      else (
                        let finish = ref (i + 1) in
                        while
                          !finish < Array.length chars
                          && lane.transitions.(!finish) = 0
                          && Option.equal
                               String.equal
                               lane.samples.(i)
                               lane.samples.(!finish)
                        do
                          incr finish
                        done;
                        Option.iter lane.samples.(i) ~f:(fun value ->
                          let hex =
                            Hardcaml.Bits.of_bit_string value
                            |> Hardcaml.Bits.to_constant
                            |> Hardcaml.Constant.to_hex_string
                                 ~capitalize:true
                                 ~signedness:Unsigned
                          in
                          if String.length hex + 2 <= !finish - i
                          then String.iteri hex ~f:(fun j c -> chars.(i + 1 + j) <- c));
                        label !finish)
                  in
                  label 0);
                row (String.of_char_list (Array.to_list chars))))
        in
        let rows = List.take rows (Int.max 0 (height - 2)) in
        let blanks =
          List.init (Int.max 0 (height - 2 - List.length rows)) ~f:(fun _ -> row "")
        in
        String.concat
          ~sep:"\n"
          ((border "┌" "─" "┐" :: rows) @ blanks @ [ border "└" "─" "┘" ]))
    in
    let text =
      match result with
      | Ok text -> text
      | Error e ->
        "Graph unavailable (no values fabricated).\n"
        ^ Error.to_string_hum e
        ^ "\nExact binary/X/Z cursor values remain in the signal list.\n"
        ^ "Narrow the window or selection, or use export/external viewer from Testing."
    in
    t.cache <- Some (width, height, 0, t.start, stop, ids, text);
    text
;;

let shorten ~width text =
  let text = safe text in
  if Bonsai_term.View.width (Bonsai_term.View.text text) <= width
  then text
  else if width <= 1
  then ""
  else (Artifact_view.wrap ~width:(width - 1) text |> List.hd_exn) ^ "…"
;;

(* Opaque IDs stay exact in the identity inspector. In compact Session metadata keep
   literal first/last four characters, including the actual "sim-" prefix. *)
let abbreviate_attempt id = Presentation.identifier ~compress:true id
let lane_height (s : D.signal) = if s.width = 1 then 2 else 3

let lane_page signals ~focused ~height =
  let budget = Int.max 3 (height - 2) in
  let rec page remaining =
    let rec take used taken rest =
      match rest with
      | s :: tail when used + lane_height s <= budget ->
        take (used + lane_height s) (s :: taken) tail
      | _ -> List.rev taken, rest
    in
    let shown, rest = take 0 [] remaining in
    if List.is_empty rest
       || Option.value_map focused ~default:true ~f:(fun focused ->
         List.exists shown ~f:(fun s -> s.D.index = focused))
    then shown
    else page rest
  in
  page signals
;;

type signal_columns =
  { name_width : int
  ; width_digits : int
  ; value_width : int
  ; value_start : int
  ; page_size : int
  }

let signal_columns t ~width =
  let digits, longest_name =
    match t.loaded with
    | Loading | Failed _ -> 1, 1
    | Ready data ->
      filtered t data
      |> List.fold ~init:(1, 1) ~f:(fun (digits, longest) s ->
        ( Int.max digits (String.length (Int.to_string s.D.width))
        , Int.max longest (Bonsai_term.View.width (Bonsai_term.View.text (safe s.name))) ))
  in
  let minimum_value_width =
    Int.max 1 (Int.min (Int.max 5 (Int.min 24 (width / 3))) (width - 13 - digits))
  in
  (* Measure the bounded filtered list, including disabled/off-screen entries, rather than
     the current page. Focus/scroll/time changes do not move columns. Clamp names on small
     panes, but give surplus width to values, not a gap. *)
  let name_width =
    Int.min longest_name (Int.max 1 (width - 5 - (digits + 3) - 3 - minimum_value_width))
  in
  let value_width = Int.max 1 (width - 5 - (digits + 3) - 3 - name_width) in
  { name_width
  ; width_digits = digits
  ; value_width
  ; value_start = 5 + name_width + digits + 3 + 3
  ; page_size = Int.max 1 (value_width - 1)
  }
;;

let prepare_signals ?(value_layout = Inline) t ~width =
  let page_size =
    match value_layout with
    | Inline -> (signal_columns t ~width).page_size
    | Stacked -> Int.max 1 (width - 6)
  in
  if page_size = t.value_page_size then t else { t with value_page_size = page_size }
;;

let prepare_quick ?(appearance = Appearance.default) ?(value_layout = Inline) t dimensions
  =
  let t = prepare ~appearance t dimensions in
  let g = frame_geometry appearance dimensions in
  prepare_signals ~value_layout t ~width:(sidebar_width t ~width:g.content_width)
;;

let editing_prompt ~width t =
  match t.editing with
  | Some Filter ->
    let help = if width >= 70 then " · Enter/Esc · Ctrl-BS/Ctrl-W word" else "" in
    Some ("/ " ^ String.suffix t.query (Int.max 1 (width - 2 - String.length help)) ^ help)
  | Some Time -> Some ("Tick: " ^ t.query ^ " · Enter/Esc")
  | None -> None
;;

let value_chunk ~columns ~offset value =
  let offset = Int.min offset (Int.max 0 (String.length value - 1)) in
  let remaining = String.drop_prefix value offset in
  let count =
    if String.length remaining <= columns
    then String.length remaining
    else Int.max 1 (columns - 1)
  in
  let text =
    String.prefix remaining count ^ if count < String.length remaining then "…" else ""
  in
  text, offset, offset + count
;;

let inline_signal_row ~appearance ~columns ~active ~enabled (s : D.signal) ~value ~offset =
  let open Bonsai_term in
  let module R = Host_view.Role in
  let role = if active then R.Selection else R.Foreground in
  let value_role = if active then R.Metric else R.Muted in
  let text role s = View.text ~attrs:(R.attrs appearance role) (safe s) in
  let name = text role s.name in
  let name =
    if View.width name <= columns.name_width
    then name
    else
      View.hcat
        [ text role "…"
        ; View.crop ~l:(Int.max 0 (View.width name - columns.name_width + 1)) name
        ]
  in
  let value, _, _ = value_chunk ~columns:columns.value_width ~offset value in
  View.hcat
    [ text
        role
        (sprintf "%s[%s] " (if active then ">" else " ") (if enabled then "*" else " "))
    ; box ~width:columns.name_width ~height:1 name
    ; text role (sprintf " [%*d]" columns.width_digits s.width)
    ; text value_role " = "
    ; text value_role value |> box ~width:columns.value_width ~height:1
    ]
;;

let render_signals
  ?(appearance = Appearance.default)
  ?(hints = true)
  ?(value_layout = Inline)
  t
  ~width
  ~height
  =
  let open Bonsai_term in
  let module R = Host_view.Role in
  let text role s = View.text ~attrs:(R.attrs appearance role) (safe s) in
  let rows =
    match t.loaded with
    | Loading ->
      [ text R.Muted t.notice ]
      @ Option.to_list (Option.map (editing_prompt ~width t) ~f:(text R.Muted))
    | Failed e ->
      [ text R.Failure ("VCD unavailable: " ^ e) ]
      @ Option.to_list (Option.map (editing_prompt ~width t) ~f:(text R.Muted))
    | Ready data ->
      let signals = filtered t data in
      let columns = signal_columns t ~width in
      let rows_per_signal =
        match value_layout with
        | Inline -> 1
        | Stacked -> 2
      in
      let page =
        Option.bind (List.nth signals t.focus) ~f:(fun s ->
          let value = D.value_at data s ~time:t.cursor |> Option.value ~default:"unset" in
          let available =
            match value_layout with
            | Inline -> columns.value_width
            | Stacked -> Int.max 1 (width - 5)
          in
          let _, first, last =
            value_chunk ~columns:available ~offset:t.value_offset value
          in
          if first > 0 || last < String.length value
          then
            Some (sprintf "Value %d..%d/%d · { } page" first last (String.length value))
          else None)
      in
      let footer =
        Option.first_some
          (editing_prompt ~width t)
          (if not (String.is_empty t.notice)
           then Some t.notice
           else
             Option.first_some
               page
               (if hints
                then Some "j/k browse · Enter toggle · / filter · Space c c commands"
                else None))
      in
      let editing_error = Option.is_some t.editing && not (String.is_empty t.notice) in
      let visible =
        Int.max
          1
          ((height
            - 1
            - (if Option.is_some footer then 1 else 0)
            - if editing_error then 1 else 0)
           / rows_per_signal)
      in
      let first = Int.max 0 (t.focus - visible + 1) in
      let rows =
        List.drop signals first
        |> Fn.flip List.take visible
        |> List.concat_mapi ~f:(fun i s ->
          let active = first + i = t.focus in
          let enabled = Set.mem t.selected s.D.index in
          let value = D.value_at data s ~time:t.cursor |> Option.value ~default:"unset" in
          let role = if active then R.Selection else R.Foreground in
          let value_role = if active then R.Metric else R.Muted in
          let offset = if active then t.value_offset else 0 in
          match value_layout with
          | Inline ->
            [ inline_signal_row ~appearance ~columns ~active ~enabled s ~value ~offset ]
          | Stacked ->
            let value, _, _ =
              value_chunk ~columns:(Int.max 1 (width - 5)) ~offset value
            in
            [ text
                role
                (sprintf
                   "%s[%s] %s [%d]"
                   (if active then ">" else " ")
                   (if enabled then "*" else " ")
                   s.name
                   s.width)
            ; text value_role ("   = " ^ value)
            ])
      in
      (text
         R.Muted
         (sprintf
            "%d matching · %d enabled · filter: %s"
            (List.length signals)
            (Set.length t.selected)
            t.filter)
       :: rows)
      @ Option.to_list
          (Option.map footer ~f:(fun s ->
             text (if String.is_empty t.notice then R.Muted else R.Warning) s))
      @ if editing_error then [ text R.Warning t.notice ] else []
  in
  View.vcat rows |> box ~width ~height |> Host_view.colored appearance R.Foreground
;;

(* Invert existing Focus/Foreground palette roles, not waveform characters. Start with
   uncoloured glyphs so with_colors can apply a real background to the cursor slice;
   applying it over already coloured text would not override it. *)
let cursor_row ~appearance ~role ~width ~column text =
  let open Bonsai_term in
  let module R = Host_view.Role in
  let raw =
    View.text
      ~attrs:
        (match role with
         | R.Metric -> [ Attr.bold ]
         | _ -> [])
      text
    |> box ~width ~height:1
  in
  let normal view =
    View.with_colors
      ~fill_backdrop:true
      view
      ~fg:(R.foreground appearance role)
      ~bg:(R.backdrop appearance role)
  in
  let slice start count = View.crop ~l:start raw |> box ~width:count ~height:1 in
  match column with
  | Some column when column >= 0 && column < width ->
    let cursor =
      View.with_colors
        ~fill_backdrop:true
        (slice column 1)
        ~fg:(R.backdrop appearance R.Foreground)
        ~bg:(R.foreground appearance R.Focus)
    in
    View.hcat
      [ normal (slice 0 column)
      ; cursor
      ; normal (slice (column + 1) (width - column - 1))
      ]
  | _ -> normal raw
;;

let ruler_rows ~appearance mapping ~timescale =
  let columns = Time.columns mapping in
  let ticks = Time.ruler mapping ~timescale in
  let labels = Bytes.make columns ' ' in
  List.iter ticks.labels ~f:(fun label ->
    String.iteri label.text ~f:(fun i c -> Bytes.set labels (label.text_column + i) c));
  let major, minor =
    match appearance.Appearance.icons with
    | Unicode -> "┬", "╷"
    | Ascii | None_ -> "+", "'"
  in
  let marks = Array.create ~len:columns " " in
  List.iter ticks.minor_columns ~f:(fun c -> marks.(c) <- minor);
  List.iter ticks.major_columns ~f:(fun c -> marks.(c) <- major);
  Bytes.to_string labels, String.concat (Array.to_list marks)
;;

let render_plot ~appearance mapping ~cursor ~width ~height ~native text =
  let open Bonsai_term in
  if native && width <> Time.columns mapping + 2
  then invalid_arg "Waveform cursor/raster width mismatch";
  let column =
    match Time.cursor mapping cursor with
    | Time.Column c -> Some (c + 1)
    | Left | Right -> None
  in
  let rows = String.split_lines text |> Array.of_list in
  List.init height ~f:(fun y ->
    let text = if y < Array.length rows then rows.(y) else "" in
    cursor_row
      ~appearance
      ~role:Host_view.Role.Metric
      ~width
      ~column:(if native && y > 0 && y < height - 1 then column else None)
      text)
  |> View.vcat
;;

let offscreen_status appearance mapping cursor =
  let unicode = Appearance.Icons.equal appearance.Appearance.icons Unicode in
  match Time.cursor mapping cursor with
  | Left -> Some ((if unicode then "←" else "<") ^ " off-screen left")
  | Right -> Some ("off-screen right " ^ if unicode then "→" else ">")
  | Column _ -> None
;;

let render_waves ?(appearance = Appearance.default) ?(hints = true) t ~width ~height =
  let open Bonsai_term in
  let module R = Host_view.Role in
  let text role s = View.text ~attrs:(R.attrs appearance role) (safe s) in
  let geometry = waves_geometry ~width ~height in
  let graph_height = geometry.graph_height in
  let body =
    match t.loaded with
    | Loading ->
      View.vcat
        ([ text R.Muted t.notice ]
         @ Option.to_list (Option.map (editing_prompt ~width t) ~f:(text R.Muted)))
    | Failed e ->
      View.vcat
        ([ text R.Failure ("VCD unavailable: " ^ e) ]
         @ Option.to_list (Option.map (editing_prompt ~width t) ~f:(text R.Muted)))
    | Ready data ->
      let selected =
        D.signals data
        |> Array.to_list
        |> List.filter ~f:(fun s -> Set.mem t.selected s.D.index)
      in
      let focused =
        List.nth (filtered t data) t.focus
        |> Option.bind ~f:(fun s ->
          if Set.mem t.selected s.D.index then Some s.index else None)
      in
      let selected = lane_page selected ~focused ~height:graph_height in
      (* Tile-local labels remain adjacent to the exact lane they describe. *)
      let label_width = geometry.label_width in
      let plot_width = geometry.plot_width in
      let mapping = waves_mapping t data ~width in
      let status = offscreen_status appearance mapping t.cursor in
      let cursor_column =
        match Time.cursor mapping t.cursor with
        | Column c -> Some c
        | Left | Right -> None
      in
      let labels =
        List.map selected ~f:(fun s ->
          View.vcat
            (List.init (lane_height s) ~f:(fun row ->
               if row = (lane_height s - 1) / 2
               then text R.Foreground s.D.reference
               else text R.Foreground "")))
        |> View.vcat
        |> View.pad ~t:1
        |> box ~width:label_width ~height:graph_height
      in
      let plot =
        if List.is_empty selected
        then
          if hints
          then "No enabled signals · Enter in Signals to enable"
          else "No enabled signals"
        else graph t data ~width:plot_width ~height:graph_height selected
      in
      let native =
        (not (List.is_empty selected))
        && not (String.is_prefix plot ~prefix:"Graph unavailable")
      in
      let ruler_labels, ruler_marks =
        ruler_rows ~appearance mapping ~timescale:(D.timescale data)
      in
      let ruler_row label line =
        View.hcat
          [ text R.Muted label |> box ~width:label_width ~height:1
          ; text R.Foreground " "
          ; cursor_row
              ~appearance
              ~role:R.Muted
              ~width:geometry.columns
              ~column:cursor_column
              line
            |> View.pad ~l:1 ~r:1
          ]
      in
      let description =
        match Time.scale mapping, cursor_column with
        | Window_cells { compressed = true }, Some column | Ticks_per_cell _, Some column
          ->
          (match Time.cell_bounds mapping ~column with
           | Some (first, last) ->
             sprintf
               "Compressed | edge # dense (ordering hidden) · cell %Ld..%Ld · exact \
                cursor"
               first
               last
           | None -> "Compressed graph; cursor exact")
        | Window_cells { compressed = true }, None ->
          "Compressed | edge # dense (ordering hidden) · exact cursor off-screen"
        | _ -> "Exact tick cells · | transition, # dense; cursor values exact"
      in
      let description =
        if Int64.equal (Time.stop mapping) (snd (D.time_bounds data))
        then description ^ " · end of trace"
        else description
      in
      View.vcat
        [ text
            (if Option.is_some status then R.Warning else R.Muted)
            (sprintf
               "%sCursor %Ld ticks × %s · window %Ld..%Ld"
               (Option.value_map status ~default:"" ~f:(fun status -> status ^ " · "))
               t.cursor
               (D.timescale_to_string (D.timescale data))
               t.start
               (Time.stop mapping))
        ; text
            R.Muted
            (sprintf
               "%s · extent %s"
               t.extent_basis
               (Time.format_compact
                  (D.timescale data)
                  Int64.(Time.stop mapping - t.start)))
        ; ruler_row "Time" ruler_labels
        ; ruler_row "absolute" ruler_marks
        ; View.hcat
            [ labels
            ; text R.Foreground " "
            ; render_plot
                ~appearance
                mapping
                ~cursor:t.cursor
                ~width:plot_width
                ~height:graph_height
                ~native
                plot
            ]
        ; text
            R.Muted
            (Option.value
               (editing_prompt ~width t)
               ~default:(if String.is_empty t.notice then description else t.notice))
        ; (if Option.is_some t.editing && not (String.is_empty t.notice)
           then text R.Warning t.notice
           else View.none)
        ]
  in
  body |> box ~width ~height |> Host_view.colored appearance R.Foreground
;;

let prepare_waves t ~width =
  ignore width;
  t
;;

let render_session
  ?(appearance = Appearance.default)
  ?(hints = true)
  ?(string_compression = true)
  t
  ~project_label
  ~width
  ~height
  =
  let open Bonsai_term in
  let module R = Host_view.Role in
  let field = Int.max 4 (width / 4) in
  let attempt =
    Presentation.identifier ~compress:string_compression t.artifact.attempt_id
  in
  let state =
    match t.loaded with
    | Loading -> "Loading"
    | Failed _ -> "Unavailable"
    | Ready _ -> "Ready"
  in
  let top =
    if width < 80
    then (
      let separator = if width < 32 then " " else " · " in
      let label_width =
        width - View.width (View.text attempt) - View.width (View.text separator)
      in
      if label_width < 2
      then attempt
      else if width < 32
      then attempt ^ separator ^ shorten ~width:label_width t.artifact.label
      else shorten ~width:label_width t.artifact.label ^ separator ^ attempt)
    else
      sprintf
        "%s · %s / %s · %s"
        (shorten ~width:field project_label)
        (shorten ~width:field (Option.value t.artifact.case_id ~default:"attempt"))
        (shorten ~width:field t.artifact.label)
        state
  in
  let details, role =
    match t.loaded with
    | Loading ->
      ( (if width < 80
         then "Loading · " ^ Option.value t.artifact.case_id ~default:"attempt"
         else t.notice)
      , R.Muted )
    | Failed e ->
      ( (if width < 80
         then
           Option.value t.artifact.case_id ~default:"attempt" ^ ": VCD unavailable: " ^ e
         else "VCD unavailable: " ^ e)
      , R.Failure )
    | Ready data ->
      ( (if width < 80
         then (
           let prefix = "Ready · " ^ D.timescale_to_string (D.timescale data) in
           let available = width - View.width (View.text prefix) - 3 in
           if available < 2
           then prefix
           else
             prefix
             ^ " · "
             ^ shorten
                 ~width:available
                 (Option.value t.artifact.case_id ~default:"attempt"))
         else
           sprintf
             "Cursor %Ld × %s · %d signals / %d enabled · attempt %s%s"
             t.cursor
             (D.timescale_to_string (D.timescale data))
             (Array.length (D.signals data))
             (Set.length t.selected)
             attempt
             (if hints then " · i exact identity" else ""))
      , R.Muted )
  in
  let details =
    match editing_prompt ~width t with
    | Some prompt when not (String.is_empty t.notice) -> t.notice ^ " · " ^ prompt
    | Some prompt -> prompt
    | None -> details
  in
  let details = if width < 80 then shorten ~width details else details in
  View.vcat
    [ View.text ~attrs:(R.attrs appearance R.Heading) (safe top)
    ; View.text ~attrs:(R.attrs appearance role) (safe details)
    ]
  |> box ~width ~height
  |> Host_view.colored appearance R.Foreground
;;

let picker_candidates ~attempt ~case_id artifacts =
  List.filter artifacts ~f:(fun (a : Hardcaml_workbench_protocol.Simulation.Artifact.t) ->
    String.equal a.attempt_id attempt
    && Option.equal String.equal a.case_id case_id
    && Simulation_export.vcd_media a)
  |> Fn.flip List.take 128
;;

(* Display identity within an already project-scoped investigation. Availability and other
   observation metadata can change after a pin was captured. This is only for
   locating/marking its picker row, never for transport validation, lifetime fencing,
   cache reuse or deciding whether bytes may be opened. *)
let picker_matches_pin
  ~(pinned : Hardcaml_workbench_protocol.Simulation.Artifact.t)
  (artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t)
  =
  String.equal pinned.attempt_id artifact.attempt_id
  && String.equal pinned.id artifact.id
  && Option.equal String.equal pinned.case_id artifact.case_id
  && Option.equal String.equal pinned.sha256 artifact.sha256
;;

let picker_initial_index ~pinned artifacts =
  List.findi artifacts ~f:(fun _ artifact -> picker_matches_pin ~pinned artifact)
  |> Option.value_map ~default:0 ~f:fst
;;

let render_waveform
  ?(appearance = Appearance.default)
  ?(value_layout = Inline)
  ?(string_compression = true)
  t
  (dimensions : Bonsai_term.Dimensions.t)
  =
  let open Bonsai_term in
  let module R = Host_view.Role in
  let t = prepare_quick ~appearance ~value_layout t dimensions in
  let geometry = frame_geometry appearance dimensions in
  let width = Int.max 1 geometry.content_width in
  let height = Int.max 1 geometry.content_height in
  let line ?(role = R.Foreground) text =
    View.text ~attrs:(R.attrs appearance role) (safe text)
  in
  let prefix = "Waveform · "
  and suffix = " · Esc/q Back to Testing · i identity" in
  let label_width =
    Int.max 0 (width - 2 - View.width (line prefix) - View.width (line suffix))
  in
  let label = shorten ~width:label_width t.artifact.label in
  let title = prefix ^ label ^ suffix in
  let identity =
    Presentation.identifiers
      ~compress:string_compression
      (t.artifact.attempt_id :: Option.to_list t.artifact.sha256)
  in
  let header =
    [ sprintf
        "Case %s · attempt %s · %s %s"
        (shorten ~width:24 (Option.value t.artifact.case_id ~default:"(attempt)"))
        (identity t.artifact.attempt_id)
        (match t.loaded with
         | Ready _ -> "SHA"
         | _ -> "expected SHA")
        (Option.value_map t.artifact.sha256 ~default:"missing" ~f:identity)
    ]
    |> List.concat_map ~f:(fun line -> Artifact_view.wrap ~width (safe line))
  in
  let body =
    match t.loaded with
    | Loading -> View.vcat (List.map (header @ [ t.notice ]) ~f:(line ~role:R.Muted))
    | Failed e ->
      View.vcat
        (List.map
           (header @ [ "Cannot open retained VCD: " ^ e ])
           ~f:(line ~role:R.Failure))
    | Ready data ->
      let side_width = sidebar_width t ~width in
      let body_height = Int.min 80 (Int.max 3 (height - 5 - List.length header)) in
      let graph_width = Int.min 1024 (Int.max 7 (width - side_width - 1)) in
      let sidebar =
        render_signals ~appearance ~value_layout t ~width:side_width ~height:body_height
      in
      let waves = render_waves ~appearance t ~width:graph_width ~height:body_height in
      View.vcat
        (List.map header ~f:(line ~role:R.Muted)
         @ [ line
               (sprintf
                  "Cursor %Ld ticks × %s · window %Ld..%Ld · filter: %s"
                  t.cursor
                  (D.timescale_to_string (D.timescale data))
                  t.start
                  (stop t data)
                  t.filter)
           ; View.hcat [ sidebar; line " "; waves ]
           ])
  in
  let footer =
    match t.editing with
    | Some Filter -> "Filter (Enter apply / Esc cancel): " ^ t.query
    | Some Time -> "Absolute VCD tick (Enter / Esc): " ^ t.query
    | None ->
      "Space c c commands · j/k signal · Enter toggle · / filter · h/l tick · : time · \
       [/] pan · +/- zoom · f Fit · d Default · g/G ends · { } value"
  in
  let value =
    match t.loaded with
    | Loading | Failed _ -> ""
    | Ready data ->
      (match List.nth (filtered t data) t.focus with
       | None -> "No matching signal"
       | Some s ->
         let value =
           D.value_at data s ~time:t.cursor |> Option.value ~default:"uninitialized"
         in
         let offset = Int.min t.value_offset (Int.max 0 (String.length value - 1)) in
         let chunk =
           String.drop_prefix value offset
           |> Fn.flip String.prefix (Int.max 1 (width - 28))
         in
         sprintf
           "Value %d..%d/%d: %s · %s %s · signal %d/%d"
           offset
           (offset + String.length chunk)
           (String.length value)
           chunk
           (if Set.mem t.selected s.index then "[*]" else "[ ]")
           s.name
           (t.focus + 1)
           (List.length (filtered t data)))
  in
  let scale =
    match t.loaded with
    | Loading | Failed _ -> t.notice
    | Ready data ->
      let _, last = D.time_bounds data in
      let end_note =
        if Int64.equal (stop t data) last then " · end of trace (no data beyond)" else ""
      in
      if String.is_empty t.notice
      then
        t.extent_basis
        ^ " · extent "
        ^ Time.format_compact (D.timescale data) Int64.(stop t data - t.start)
        ^ end_note
      else t.notice
  in
  let content =
    View.vcat
      [ box ~width ~height:(Int.max 0 (height - 4)) body
      ; line ~role:R.Metric value
      ; line ~role:R.Muted scale
      ; line ~role:R.Muted footer
      ]
    |> box ~width ~height
  in
  let content =
    if geometry.border = 0
    then
      View.vcat [ line ~role:R.Heading title; View.crop ~b:1 content ]
      |> box ~width ~height
    else content
  in
  Panel.render
    appearance
    ~attrs:(R.attrs appearance R.Border)
    ~title:(line ~role:R.Focus title)
    ~geometry
    ~width:(Int.max 1 dimensions.width)
    ~height:(Int.max 1 dimensions.height)
    content
  |> Host_view.colored appearance R.Foreground
;;

let identity_lines t ~width =
  [ "Project " ^ t.project
  ; "Attempt " ^ t.artifact.attempt_id
  ; "Case " ^ Option.value t.artifact.case_id ~default:"(attempt)"
  ; "Artifact " ^ t.artifact.id
  ; "Label " ^ t.artifact.label
  ; "SHA256 " ^ Option.value t.artifact.sha256 ~default:"missing"
  ; "Media type " ^ t.artifact.media_type
  ; "Size " ^ Option.value_map t.artifact.size ~default:"unknown" ~f:Int.to_string
  ]
  |> List.concat_map ~f:(fun text -> Artifact_view.wrap ~width (safe text))
;;

let render
  ?(appearance = Appearance.default)
  ?(value_layout = Inline)
  ?(string_compression = true)
  t
  (dimensions : Bonsai_term.Dimensions.t)
  =
  match t.identity_scroll with
  | None -> render_waveform ~appearance ~value_layout ~string_compression t dimensions
  | Some scroll ->
    let open Bonsai_term in
    let module R = Host_view.Role in
    let geometry = frame_geometry appearance dimensions in
    let width = Int.max 1 geometry.content_width
    and height = Int.max 1 geometry.content_height in
    let lines = identity_lines t ~width in
    let visible = Int.max 1 (height - 2) in
    let scroll = Int.min scroll (Int.max 0 (List.length lines - visible)) in
    View.vcat
      [ View.text
          ~attrs:(R.attrs appearance R.Focus)
          "Waveform identity · Esc/q Back to waveform · j/k scroll"
      ; List.drop lines scroll
        |> Fn.flip List.take visible
        |> List.map ~f:(View.text ~attrs:(R.attrs appearance R.Foreground))
        |> View.vcat
      ]
    |> box ~width ~height
    |> Panel.render
         appearance
         ~attrs:(R.attrs appearance R.Border)
         ~title:
           (View.text ~attrs:(R.attrs appearance R.Focus) "Captured waveform identity")
         ~geometry
         ~width:(Int.max 1 dimensions.width)
         ~height:(Int.max 1 dimensions.height)
    |> Host_view.colored appearance R.Foreground
;;

let%test_unit "exact cursor, clamped pan, selection and explicit X lane marker" =
  let data =
    D.parse
      "$timescale 1 ns $end\n\
       $scope module top $end\n\
       $var wire 1 ! a $end\n\
       $upscope $end\n\
       $enddefinitions $end\n\
       #0\n\
       0!\n\
       #10\n\
       x!\n\
       #20\n\
       1!\n"
    |> Or_error.ok_exn
  in
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "vcd"
    ; attempt_id = "attempt"
    ; case_id = Some "case"
    ; label = "trace"
    ; kind = "waveform"
    ; media_type = "text/vcd"
    ; size = Some 100
    ; sha256 = Some (String.make 64 'a')
    ; availability = Available
    }
  in
  let t = receive (create ~project:"project" artifact) (Ok data) in
  let t = input t (Char 'G') in
  assert (Int64.equal t.cursor 20L);
  let t = input t Right in
  assert (Int64.equal t.cursor 20L);
  let t = input t (Char 'g') in
  let text = graph t data ~width:70 ~height:12 (Array.to_list (D.signals data)) in
  assert (String.is_substring text ~substring:"X/Z in window; no graph");
  assert (not (String.is_substring text ~substring:"Graph unavailable"));
  assert (Set.equal (input t (Char ' ')).selected t.selected);
  let t = input t Enter in
  assert (Set.is_empty t.selected);
  let t = input t (Char '/') |> fun t -> input t (Char 'z') |> fun t -> input t Enter in
  assert (List.is_empty (filtered t data))
;;

let%test_unit "mixed X Z unset and known lanes preserve exact row geometry and values" =
  let data =
    D.parse
      "$timescale 1ps $end $scope module tb $end $var wire 1 ! clk $end $var wire 8 # q \
       [7:0] $end $var wire 1 $ ena $end $var wire 1 % z $end $var wire 4 & unset [3:0] \
       $end $var wire 4 ' known [3:0] $end $upscope $end $enddefinitions $end #0 0! bx # \
       1$ z% b1010 ' #5 1! #10 b0 # 0% b0011 & #20 0!"
    |> Or_error.ok_exn
  in
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "mixed"
    ; attempt_id = "attempt"
    ; case_id = Some "case"
    ; label = "mixed"
    ; kind = "trace"
    ; media_type = "text/vcd"
    ; size = Some 100
    ; sha256 = Some (String.make 64 'a')
    ; availability = Available
    }
  in
  let t = receive (create ~project:"project" artifact) (Ok data) in
  let signals = Array.to_list (D.signals data) in
  List.iter [ 80; 120 ] ~f:(fun width ->
    let output = graph t data ~width ~height:20 signals |> String.split_lines in
    assert (List.length output = 20);
    List.iter output ~f:(fun line ->
      assert (Bonsai_term.View.width (Bonsai_term.View.text line) = width));
    List.iter [ 4; 8 ] ~f:(fun row ->
      assert (
        String.is_substring (List.nth_exn output row) ~substring:"X/Z in window; no graph"));
    assert (
      String.is_substring
        (List.nth_exn output 11)
        ~substring:"Uninitialized in window; no graph");
    (* Known scalar lanes on both sides of q retain their own renderer rows. *)
    let known = List.filteri signals ~f:(fun i _ -> i = 0 || i = 2 || i = 5) in
    let native =
      graph { t with cache = None } data ~width ~height:20 known |> String.split_lines
    in
    List.iter
      [ 1, 1; 2, 2; 6, 3; 7, 4; 13, 5; 14, 6; 15, 7 ]
      ~f:(fun (mixed, known) ->
        assert (String.equal (List.nth_exn output mixed) (List.nth_exn native known)));
    let rendered = render_waves ~hints:false t ~width ~height:30 in
    let image = Bonsai_term.View.Private.notty_image rendered in
    let buf = Buffer.create 16384 in
    Notty.Render.to_buffer buf Notty.Cap.dumb (0, 0) (width, 30) image;
    let text = Buffer.contents buf in
    assert (not (String.is_substring text ~substring:"Graph unavailable")));
  assert (
    Option.equal
      String.equal
      (D.value_at data (List.nth_exn signals 1) ~time:0L)
      (Some "xxxxxxxx"));
  assert (
    Option.equal
      String.equal
      (D.value_at data (List.nth_exn signals 3) ~time:0L)
      (Some "z"));
  assert (Option.is_none (D.value_at data (List.nth_exn signals 4) ~time:0L));
  let later =
    graph { t with start = 10L; cache = None } data ~width:80 ~height:20 signals
  in
  assert (not (String.is_substring later ~substring:"no graph"));
  (* Aggregate budgets still count marked lanes, rather than resetting per signal. *)
  let dense =
    "$timescale 1ps $end $var wire 1 ! x $end $var wire 1 # a $end $enddefinitions $end \
     #0 x! 0# #1 "
    ^ String.concat (List.init 50000 ~f:(fun _ -> "x! 1# "))
  in
  let dense = D.parse dense |> Or_error.ok_exn in
  assert (
    Or_error.is_error
      (D.classify_window
         dense
         ~signals:(Array.to_list (D.signals dense))
         ~start:0L
         ~stop:1L))
;;

let%test_unit "binary rendering, bounded zoom/resize and frozen artifact identity" =
  let data =
    D.parse
      "$timescale 10 ps $end\n\
       $scope module top $end\n\
       $var wire 4 ! bus [3:0] $end\n\
       $upscope $end\n\
       $enddefinitions $end\n\
       #0\n\
       b0011 !\n\
       #5000\n\
       b1110 !\n"
    |> Or_error.ok_exn
  in
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "vcd"
    ; attempt_id = "attempt"
    ; case_id = Some "case"
    ; label = "trace"
    ; kind = "waveform"
    ; media_type = "text/vcd"
    ; size = Some 100
    ; sha256 = Some (String.make 64 'a')
    ; availability = Available
    }
  in
  let t = receive (create ~project:"project" artifact) (Ok data) in
  assert (same t ~project:"project" artifact);
  assert (not (same t ~project:"other-project" artifact));
  assert (
    not (same t ~project:"project" { artifact with sha256 = Some (String.make 64 'b') }));
  let t = List.fold (List.init 30 ~f:Fn.id) ~init:t ~f:(fun t _ -> input t (Char '-')) in
  assert (Int64.(t.span >= 5000L));
  let t = input t (Char ']') in
  assert (Int64.equal t.start 2500L);
  let t = input t (Char ':') |> fun t -> input t Backspace in
  let t =
    List.fold (String.to_list "5000") ~init:t ~f:(fun t c -> input t (Char c))
    |> fun t -> input t Enter
  in
  assert (Int64.equal t.cursor 5000L);
  let graph = graph t data ~width:70 ~height:12 (Array.to_list (D.signals data)) in
  assert (not (String.is_substring graph ~substring:"unavailable"));
  assert (String.is_substring graph ~substring:"┌");
  assert (not (String.is_substring graph ~substring:"Signals"));
  List.iter
    [ 1, 1; 32, 8; 80, 24; 120, 40; 180, 55; 500, 200 ]
    ~f:(fun (width, height) ->
      let view = render t { Bonsai_term.Dimensions.width; height } in
      assert (Bonsai_term.View.width view = width);
      assert (Bonsai_term.View.height view = height))
;;

let%test_unit "80x24 shows bus value and Back even with long artifact metadata" =
  let data =
    D.parse
      "$timescale 1 ns $end\n\
       $scope module outputs $end\n\
       $var wire 5 ! occupancy $end\n\
       $upscope $end\n\
       $enddefinitions $end\n\
       #0\n\
       b10101 !\n\
       #100\n\
       b00000 !\n"
    |> Or_error.ok_exn
  in
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = String.make 100 'a' ^ "-artifact-tail"
    ; attempt_id = String.make 100 't' ^ "-attempt-tail"
    ; case_id = Some (String.make 100 'c' ^ "-case-tail")
    ; label = String.make 240 'l' ^ "-label-tail"
    ; kind = "waveform"
    ; media_type = "text/vcd"
    ; size = Some 100
    ; sha256 = Some (String.make 64 'd')
    ; availability = Available
    }
  in
  let t =
    receive (create ~project:(String.make 100 'p' ^ "-project-tail") artifact) (Ok data)
  in
  let screen_size t ~width ~height =
    let view = render t { Bonsai_term.Dimensions.width; height } in
    let buffer = Buffer.create 2000 in
    Notty.Render.to_buffer
      buffer
      Notty.Cap.dumb
      (0, 0)
      (width, height)
      (Bonsai_term.View.Private.notty_image view);
    Buffer.contents buffer
  in
  let screen t = screen_size t ~width:80 ~height:24 in
  let text = screen t in
  List.iter
    [ "Esc/q Back to Testing"
    ; "i identity"
    ; ">[*]"
    ; "= 10101"
    ; "Value 0..5/5: 10101"
    ; "SHA dddd…dddd"
    ]
    ~f:(fun substring ->
      if not (String.is_substring text ~substring)
      then failwithf "Missing %S in 80x24 waveform:\n%s" substring text ());
  let narrow = screen_size t ~width:68 ~height:20 in
  List.iter
    [ "Esc/q Back to Testing"; "i identity"; "= 10101"; "Value 0..5/5: 10101" ]
    ~f:(fun substring -> assert (String.is_substring narrow ~substring));
  let unicode =
    { t with
      artifact = { artifact with label = String.concat (List.init 100 ~f:(fun _ -> "界")) }
    }
  in
  assert (String.is_substring (screen unicode) ~substring:"Esc/q Back to Testing");
  let lines = identity_lines t ~width:80 in
  List.iter lines ~f:(fun line ->
    assert (Bonsai_term.View.width (Bonsai_term.View.text line) <= 80));
  let exact = String.concat lines in
  List.iter
    [ t.project
    ; artifact.attempt_id
    ; Option.value_exn artifact.case_id
    ; artifact.id
    ; artifact.label
    ; Option.value_exn artifact.sha256
    ]
    ~f:(fun substring -> assert (String.is_substring exact ~substring));
  let inspect = input t (Char 'i') in
  assert (String.is_substring (screen inspect) ~substring:"Back to waveform");
  let inspect =
    List.fold (List.init 30 ~f:Fn.id) ~init:inspect ~f:(fun t _ -> input t Down)
  in
  assert (String.is_substring (screen inspect) ~substring:"SHA256");
  let returned = input inspect Escape in
  assert (Option.is_none returned.identity_scroll);
  assert (String.is_substring (screen returned) ~substring:"= 10101")
;;

let%test_unit "cached navigation reload preserves selection, time, filter and value page" =
  let data =
    D.parse
      "$timescale 1 ns $end\n\
       $var wire 64 ! data $end\n\
       $enddefinitions $end\n\
       #0\n\
       b1 !\n\
       #100\n\
       b0 !\n"
    |> Or_error.ok_exn
  in
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "vcd"
    ; attempt_id = "attempt"
    ; case_id = None
    ; label = "trace"
    ; kind = "waveform"
    ; media_type = "text/vcd"
    ; size = Some 100
    ; sha256 = Some (String.make 64 'a')
    ; availability = Available
    }
  in
  let t = receive (create ~project:"project" artifact) (Ok data) in
  let t =
    { t with
      cursor = 50L
    ; start = 40L
    ; span = 32L
    ; filter = "data"
    ; selected = Int.Set.empty
    ; value_offset = 32
    }
  in
  let saved = remember t in
  assert (
    match saved.loaded with
    | Loading -> true
    | _ -> false);
  assert (Option.is_none saved.cache);
  let direct = receive ~restore_navigation:true saved (Ok data) in
  assert (direct.value_offset = 32);
  (* Filter changes made during the verified reload must also survive receipt. *)
  let loading =
    input saved (Char '/') |> fun t -> input t Backspace |> fun t -> input t Enter
  in
  let restored = receive ~restore_navigation:true loading (Ok data) in
  assert (Int64.equal restored.cursor 50L && Int64.equal restored.start 40L);
  assert (Int64.equal restored.span 32L);
  assert (Set.is_empty restored.selected);
  assert (String.equal restored.filter "dat");
  assert (restored.value_offset = 0);
  let fresh = receive loading (Ok data) in
  assert (Int64.equal fresh.cursor 0L && not (Set.is_empty fresh.selected));
  let failed =
    receive ~restore_navigation:true saved (Or_error.error_string "SHA256 mismatch")
  in
  assert (
    match failed.loaded with
    | Failed _ -> true
    | _ -> false);
  assert (Int64.equal failed.cursor 50L)
;;

let%test_unit "wide integer raster fills the plot and preserves a regular clock" =
  let changes = List.init 820 ~f:(fun n -> sprintf "#%d\n%d!\n" (n * 5) (n % 2)) in
  let data =
    D.parse
      ("$timescale 1 ns $end\n\
        $var wire 1 ! zclock $end\n\
        $var wire 4 \" abus $end\n\
        $enddefinitions $end\n\
        #0\n\
        b1010 \"\n"
       ^ String.concat changes)
    |> Or_error.ok_exn
  in
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "clock"
    ; attempt_id = "attempt"
    ; case_id = Some "regular clock"
    ; label = "Clock trace"
    ; kind = "waveform"
    ; media_type = "text/vcd"
    ; size = Some 100
    ; sha256 = Some (String.make 64 'a')
    ; availability = Available
    }
  in
  let t = receive (create ~project:"project" artifact) (Ok data) in
  let t = { t with span = 256L } in
  let dimensions = { Bonsai_term.Dimensions.width = 230; height = 40 } in
  let t = prepare t dimensions in
  let g = frame_geometry Appearance.default dimensions in
  let side = sidebar_width t ~width:g.content_width in
  assert (side <= 30);
  let width = g.content_width - side - 1 in
  let width = Int.max 7 (width - wave_labels_width width - 1) in
  let r = raster ~columns:(width - 2) ~target:256 in
  assert (r.code = -1);
  assert (Int64.equal (stop t data) 256L);
  let text = graph t data ~width ~height:8 (Array.to_list (D.signals data)) in
  assert (not (String.is_substring text ~substring:"Signals"));
  let rows = String.split_lines text |> Fn.flip List.drop 1 |> Fn.flip List.take 2 in
  assert (List.exists rows ~f:(fun row -> String.is_substring row ~substring:"|"));
  assert (String.is_substring (List.nth_exn (String.split_lines text) 4) ~substring:"A");
  let page = lane_page (Array.to_list (D.signals data)) ~focused:(Some 1) ~height:5 in
  assert (List.length page = 1 && (List.hd_exn page).index = 1);
  let plain view =
    let buffer = Buffer.create 512 in
    Notty.Render.to_buffer
      buffer
      Notty.Cap.dumb
      (0, 0)
      (Bonsai_term.View.width view, Bonsai_term.View.height view)
      (Bonsai_term.View.Private.notty_image view);
    Buffer.contents buffer
  in
  let slice row ~start ~count =
    Bonsai_term.View.text row
    |> Bonsai_term.View.crop ~l:start
    |> box ~width:count ~height:1
    |> plain
  in
  (* Inspect the last actual plot column, excluding its frame: the old ceil(3) scale left
     it blank. Check full periods, not merely string/frame width. *)
  assert (
    List.exists rows ~f:(fun row ->
      not (String.is_empty (String.strip (slice row ~start:(width - 2) ~count:1)))));
  (* Physical duration stays fixed; individual edges are localized to their original-event
     cells rather than assuming a fixed character period. *)
  assert (String.is_substring text ~substring:"|");
  let compressed = raster ~columns:(width - 2) ~target:4096 in
  assert (compressed.code < -1);
  assert (String.is_substring compressed.description ~substring:"multiple transitions");
  let small = prepare t { dimensions with width = 80 } in
  assert (Int64.equal (stop small data) (stop t data));
  assert (Int64.equal small.cursor t.cursor)
;;

let%test_unit "waveform uses Workbench frames, palette and compact inspectable metadata" =
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "artifact-very-long-id"
    ; attempt_id = "attempt-very-long-id"
    ; case_id = Some "case"
    ; label = "Retained waveform"
    ; kind = "waveform"
    ; media_type = "text/vcd"
    ; size = Some 1
    ; sha256 = Some (String.make 64 'd')
    ; availability = Available
    }
  in
  let data =
    D.parse
      "$timescale 1 ns $end\n\
       $var wire 1 ! bit $end\n\
       $enddefinitions $end\n\
       #0\n\
       0!\n\
       #500\n\
       1!\n"
    |> Or_error.ok_exn
  in
  let t = receive (create ~project:"exact-project-id" artifact) (Ok data) in
  let dimensions = { Bonsai_term.Dimensions.width = 230; height = 40 } in
  let ansi view =
    let buffer = Buffer.create 20000 in
    Notty.Render.to_buffer
      buffer
      Notty.Cap.ansi
      (0, 0)
      (Bonsai_term.View.width view, Bonsai_term.View.height view)
      (Bonsai_term.View.Private.notty_image view);
    Buffer.contents buffer
  in
  let schemes =
    List.map Appearance.Scheme.all ~f:(fun scheme ->
      let appearance = { Appearance.default with scheme } in
      let view = render ~appearance t dimensions in
      let pane = render_waves ~appearance t ~width:100 ~height:10 in
      let g = waves_geometry ~width:100 ~height:10 in
      let stroke =
        Bonsai_term.View.crop ~l:(g.plot_x + 1) ~t:(g.plot_y + 1) pane
        |> box ~width:1 ~height:1
      in
      let expected_stroke =
        Bonsai_term.View.text ~attrs:(Host_view.Role.attrs appearance Metric) "_"
      in
      assert (String.equal (ansi stroke) (ansi expected_stroke));
      let background =
        Bonsai_term.View.crop ~l:228 ~t:38 view |> box ~width:1 ~height:1
      in
      let expected_background =
        Bonsai_term.View.rectangle ~width:1 ~height:1 ()
        |> Host_view.colored appearance Foreground
      in
      assert (String.equal (ansi background) (ansi expected_background));
      List.iter Appearance.Preset.all ~f:(fun preset ->
        let appearance = { appearance with preset } in
        let view = render ~appearance t dimensions in
        assert (Bonsai_term.View.width view = 230 && Bonsai_term.View.height view = 40);
        if Panel.framed appearance ~width:230 ~height:40
        then (
          let corner = if Appearance.Preset.equal preset Instrument then "╭" else "┌" in
          let expected =
            Bonsai_term.View.text ~attrs:(Host_view.Role.attrs appearance Border) corner
          in
          assert (String.equal (ansi (box ~width:1 ~height:1 view)) (ansi expected))));
      ansi view)
  in
  assert (
    List.length (List.dedup_and_sort schemes ~compare:String.compare)
    = List.length Appearance.Scheme.all);
  (* Raw provenance stays in the i inspector, not a six-line wall above the waves. *)
  let text = ansi (render t dimensions) in
  assert (not (String.is_substring text ~substring:"exact-project-id"));
  assert (not (String.is_substring text ~substring:(String.make 64 'd')));
  assert (
    String.is_substring
      (String.concat (identity_lines t ~width:80))
      ~substring:"exact-project-id");
  let inspection =
    render
      ~appearance:{ Appearance.default with scheme = Neon }
      (input t (Char 'i'))
      dimensions
  in
  assert (String.is_substring (ansi inspection) ~substring:"exact-project-id")
;;

let%test_unit "independent Signals never hides disabled names; Space is reserved for host"
  =
  let data =
    D.parse
      "$timescale 1 ns $end\n\
       $var wire 1 ! enabled $end\n\
       $var wire 5 \" disabled $end\n\
       $enddefinitions $end\n\
       #0\n\
       1!\n\
       b10101 \"\n\
       #100\n\
       0!\n"
    |> Or_error.ok_exn
  in
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "trace"
    ; attempt_id = "captured-attempt"
    ; case_id = Some "case"
    ; label = "VCD"
    ; kind = "waveform"
    ; media_type = "text/vcd"
    ; size = Some 1
    ; sha256 = Some (String.make 64 'a')
    ; availability = Available
    }
  in
  let t = receive (create ~project:"project" artifact) (Ok data) in
  let t = { t with selected = Int.Set.singleton 0; focus = 1 } in
  let plain view =
    let buffer = Buffer.create 4096 in
    Notty.Render.to_buffer
      buffer
      Notty.Cap.dumb
      (0, 0)
      (Bonsai_term.View.width view, Bonsai_term.View.height view)
      (Bonsai_term.View.Private.notty_image view);
    Buffer.contents buffer
  in
  let signals = plain (render_signals t ~width:60 ~height:10) in
  assert (String.is_substring signals ~substring:"[*] enabled");
  assert (String.is_substring signals ~substring:"[ ] disabled");
  assert (String.is_substring signals ~substring:"= 10101");
  assert (Set.equal (input t (Char ' ')).selected t.selected);
  let enabled = input t Enter in
  assert (Set.mem enabled.selected 1);
  let disabled = input enabled Enter in
  assert (not (Set.mem disabled.selected 1));
  assert (
    String.is_substring
      (plain (render_signals disabled ~width:60 ~height:10))
      ~substring:"[ ] disabled");
  let waves = render_waves { t with selected = Int.Set.empty } ~width:80 ~height:12 in
  assert (Bonsai_term.View.width waves = 80 && Bonsai_term.View.height waves = 12);
  assert (String.is_substring (plain waves) ~substring:"No enabled signals");
  assert (not (String.is_substring (plain waves) ~substring:"Back to Testing"));
  let candidates =
    picker_candidates
      ~attempt:artifact.attempt_id
      ~case_id:artifact.case_id
      [ artifact
      ; { artifact with attempt_id = "different-attempt" }
      ; { artifact with case_id = Some "different-case" }
      ; { artifact with media_type = "application/fst" }
      ; { artifact with media_type = "application/json-vcd" }
      ]
  in
  assert (List.length candidates = 1);
  assert (
    List.length
      (picker_candidates
         ~attempt:artifact.attempt_id
         ~case_id:artifact.case_id
         (List.init 256 ~f:(fun _ -> artifact)))
    = 128)
;;

let%test_unit "picker retains missing pin marker and cursor without matching changed \
               digest"
  =
  let pinned : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "trace"
    ; attempt_id = "attempt"
    ; case_id = Some "case"
    ; label = "Retained VCD"
    ; kind = "waveform"
    ; media_type = "text/vcd"
    ; size = Some 123
    ; sha256 = Some (String.make 64 'a')
    ; availability = Available
    }
  in
  let missing = { pinned with availability = Missing } in
  assert (picker_matches_pin ~pinned missing);
  assert (picker_matches_pin ~pinned { pinned with availability = Changed });
  let different_digest = { missing with sha256 = Some (String.make 64 'b') } in
  List.iter
    [ different_digest
    ; { missing with sha256 = None }
    ; { missing with attempt_id = "other-attempt" }
    ; { missing with id = "other-artifact" }
    ; { missing with case_id = Some "other-case" }
    ; { missing with case_id = None }
    ]
    ~f:(fun artifact -> assert (not (picker_matches_pin ~pinned artifact)));
  let candidates =
    picker_candidates
      ~attempt:pinned.attempt_id
      ~case_id:pinned.case_id
      [ different_digest; missing ]
  in
  assert (picker_initial_index ~pinned candidates = 1);
  (* The presentation relaxation must not make an unavailable observation equal to the
     captured artifact for model reuse or identity verification. *)
  assert (not (Hardcaml_workbench_protocol.Simulation.Artifact.equal pinned missing));
  assert (not (same (create ~project:"project" pinned) ~project:"project" missing));
  assert (Or_error.is_error (Simulation_export.identity missing))
;;

let%test_unit "filter word boundaries and actual native deletion key encodings" =
  List.iter
    [ "", ""
    ; "top.outputs.occupancy", "top.outputs."
    ; "top.outputs.", "top."
    ; "top.data_bus", "top."
    ; "foo bar   ", "foo "
    ; "./[]  ", ""
    ; "top.data[7:0]", "top.data[7:"
    ; "top.界面", "top."
    ]
    ~f:(fun (before, after) -> assert (String.equal (delete_word before) after));
  assert (String.equal (drop_character "top.name") "top.nam");
  assert (String.equal (drop_character "a界") "a");
  let native_key text =
    let events =
      Notty.Unescape.decode (String.to_list text |> List.map ~f:Uchar.of_char)
    in
    match events with
    | [ `Key (key, mods) ] ->
      let key =
        match key with
        | `Backspace -> Bonsai_term.Event.Key.Backspace
        | `ASCII c -> ASCII c
        | `Uchar u -> Uchar u
        | _ -> assert false
      in
      let mods =
        List.map mods ~f:(function
          | `Ctrl -> Bonsai_term.Event.Modifier.Ctrl
          | `Meta -> Meta
          | `Shift -> Shift)
      in
      edit_key (Key_press { key; mods })
    | _ -> assert false
  in
  List.iter
    [ "\008", Delete_word
    ; "\023", Delete_word
    ; "\027\127", Delete_word
    ; "\127", Backspace
    ]
    ~f:(fun (bytes, expected) -> assert (Poly.equal (native_key bytes) (Some expected)));
  assert (
    Poly.equal
      (edit_key (Key_press { key = Uchar (Uchar.of_char 'w'); mods = [ Ctrl ] }))
      (Some Delete_word));
  assert (
    Poly.equal
      (edit_key (Key_press { key = Backspace; mods = [ Ctrl; Shift ] }))
      (Some Delete_word));
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "trace"
    ; attempt_id = "attempt"
    ; case_id = None
    ; label = "trace"
    ; kind = "waveform"
    ; media_type = "text/vcd"
    ; size = None
    ; sha256 = None
    ; availability = Missing
    }
  in
  let t =
    { (create ~project:"project" artifact) with
      editing = Some Filter
    ; query = "top.outputs.occupancy"
    }
  in
  let deleted = input t Delete_word in
  assert (String.equal deleted.query "top.outputs.");
  assert (String.is_empty deleted.filter);
  assert (String.equal (input deleted Enter).filter "top.outputs.");
  assert (String.equal (input t Backspace).query "top.outputs.occupanc");
  assert (same deleted ~project:"project" artifact)
;;

let%test_unit "inline columns use display cells; stacked and paging preserve exact values"
  =
  let bits = String.concat (List.init 32 ~f:(fun _ -> "10")) in
  let data =
    D.parse
      ("$timescale 1 ns $end\n\
        $var wire 4 ! short $end\n\
        $var wire 64 \" long_scope.disabled $end\n\
        $enddefinitions $end\n\
        #0\n\
        b1010 !\n\
        b"
       ^ bits
       ^ " \"\n#100\n")
    |> Or_error.ok_exn
  in
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "trace"
    ; attempt_id = "attempt"
    ; case_id = Some "captured-case"
    ; label = "Captured trace"
    ; kind = "waveform"
    ; media_type = "text/vcd"
    ; size = Some 100
    ; sha256 = Some (String.make 64 'a')
    ; availability = Available
    }
  in
  let t = receive (create ~project:"captured-project" artifact) (Ok data) in
  let t = { t with focus = 1; selected = Int.Set.singleton 0 } in
  let plain view =
    let b = Buffer.create 4096 in
    Notty.Render.to_buffer
      b
      Notty.Cap.dumb
      (0, 0)
      (Bonsai_term.View.width view, Bonsai_term.View.height view)
      (Bonsai_term.View.Private.notty_image view);
    Buffer.contents b
  in
  let columns = signal_columns t ~width:70 in
  let longest_name = "long_scope.disabled" in
  assert (columns.name_width = Bonsai_term.View.width (Bonsai_term.View.text longest_name));
  let wide_columns = signal_columns t ~width:300 in
  assert (wide_columns.name_width = columns.name_width);
  assert (wide_columns.value_start = columns.value_start);
  assert (
    (signal_columns { t with focus = 0; cursor = 100L } ~width:300).value_start
    = wide_columns.value_start);
  let filtered_columns = signal_columns { t with filter = "short" } ~width:300 in
  assert (
    filtered_columns.name_width = 5
    && filtered_columns.value_start < wide_columns.value_start);
  let wide = render_signals ~hints:false t ~width:300 ~height:4 |> plain in
  assert (String.is_substring wide ~substring:(longest_name ^ " [64] = " ^ bits));
  (* Column positions are based on the whole filtered list, including the disabled
     off-screen entry, not whichever name is currently focused. *)
  assert (
    (signal_columns { t with focus = 0 } ~width:300).name_width
    = String.length longest_name);
  let inline = render_signals ~hints:false t ~width:70 ~height:10 in
  let cell_line y column count =
    Bonsai_term.View.crop ~t:y ~l:column inline |> box ~width:count ~height:1 |> plain
  in
  assert (String.is_prefix (cell_line 1 columns.value_start 4) ~prefix:"1010");
  assert (String.is_prefix (cell_line 2 columns.value_start 4) ~prefix:"1010");
  List.iter [ 1; 2 ] ~f:(fun y ->
    assert (String.is_substring (cell_line y (columns.value_start - 2) 1) ~substring:"="));
  assert (String.is_substring (plain inline) ~substring:"[ ] long_scope.disabled");
  let signal = (D.signals data).(0) in
  List.iter
    [ "界界.long_name"; String.make 200 'x' ]
    ~f:(fun name ->
      let row =
        inline_signal_row
          ~appearance:Appearance.default
          ~columns
          ~active:false
          ~enabled:false
          { signal with name }
          ~value:"1010"
          ~offset:0
      in
      assert (Bonsai_term.View.width row = 70);
      assert (
        String.is_substring
          (plain
             (Bonsai_term.View.crop ~l:columns.value_start row |> box ~width:4 ~height:1))
          ~substring:"1010"));
  let stacked =
    render_signals ~hints:false ~value_layout:Stacked t ~width:70 ~height:10 |> plain
  in
  assert (String.is_substring stacked ~substring:("   = " ^ bits));
  List.iter [ 22; 40; 70 ] ~f:(fun width ->
    let view = ref (prepare_signals t ~width) in
    let covered = ref Int.Set.empty in
    for _ = 0 to 64 do
      let columns = signal_columns !view ~width in
      let _, first, last =
        value_chunk ~columns:columns.value_width ~offset:!view.value_offset bits
      in
      for i = first to last - 1 do
        covered := Set.add !covered i
      done;
      view := input !view (Char '}')
    done;
    assert (Set.length !covered = 64));
  assert (same t ~project:"captured-project" artifact)
;;

let%test_unit "resolved quiet policy hides idle hints but keeps prompts, errors and \
               Session metadata"
  =
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "trace"
    ; attempt_id = "captured-attempt"
    ; case_id = Some "captured-case"
    ; label = "Pinned VCD"
    ; kind = "waveform"
    ; media_type = "text/vcd"
    ; size = Some 100
    ; sha256 = Some (String.make 64 'a')
    ; availability = Available
    }
  in
  let data =
    D.parse
      "$timescale 1 ns $end\n\
       $var wire 1 ! bit $end\n\
       $enddefinitions $end\n\
       #0\n\
       1!\n\
       #100\n\
       0!\n"
    |> Or_error.ok_exn
  in
  let t = receive (create ~project:"captured-project-id" artifact) (Ok data) in
  let plain view =
    let b = Buffer.create 8192 in
    Notty.Render.to_buffer
      b
      Notty.Cap.dumb
      (0, 0)
      (Bonsai_term.View.width view, Bonsai_term.View.height view)
      (Bonsai_term.View.Private.notty_image view);
    Buffer.contents b
  in
  let quiet = render_signals ~hints:false t ~width:80 ~height:10 |> plain in
  assert (not (String.is_substring quiet ~substring:"j/k"));
  assert (not (String.is_substring quiet ~substring:"Enter toggle"));
  assert (
    String.is_substring
      (plain (render_signals ~hints:true t ~width:80 ~height:10))
      ~substring:"j/k browse");
  let editing = { t with editing = Some Filter; query = "top.outputs.occupancy" } in
  assert (
    String.is_substring
      (plain (render_signals ~hints:false editing ~width:80 ~height:10))
      ~substring:"/ top.outputs.occupancy");
  let invalid =
    { t with editing = Some Time; query = "bad"; notice = "Enter an integer VCD tick" }
  in
  let text = render_signals ~hints:false invalid ~width:80 ~height:10 |> plain in
  assert (String.is_substring text ~substring:"Tick: bad");
  assert (String.is_substring text ~substring:"Enter an integer VCD tick");
  let empty =
    render_waves ~hints:false { t with selected = Int.Set.empty } ~width:80 ~height:10
    |> plain
  in
  assert (String.is_substring empty ~substring:"No enabled signals");
  assert (not (String.is_substring empty ~substring:"Enter in Signals"));
  let failed = receive t (Or_error.error_string "retained artifact missing") in
  assert (
    String.is_substring
      (plain (render_signals ~hints:false failed ~width:80 ~height:10))
      ~substring:"retained artifact missing");
  let session =
    render_session ~hints:false t ~project_label:"captured-root" ~width:120 ~height:2
    |> plain
  in
  List.iter
    [ "captured-root"; "captured-case"; "Pinned VCD"; "Ready"; "1 ns" ]
    ~f:(fun substring -> assert (String.is_substring session ~substring));
  assert (not (String.is_substring session ~substring:"j/k"));
  assert (not (String.is_substring session ~substring:"captured-project-id"));
  let session_error =
    render_session ~hints:false failed ~project_label:"captured-root" ~width:120 ~height:2
    |> plain
  in
  assert (String.is_substring session_error ~substring:"retained artifact missing")
;;

let%test_unit "narrow Session keeps literal four/four attempt ID and concise metadata" =
  assert (String.equal (abbreviate_attempt "sim-0123456789abcdef") "sim-…cdef");
  assert (String.equal (abbreviate_attempt "abcdefghij") "abcdefghij");
  assert (String.equal (abbreviate_attempt "short") "short");
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "artifact"
    ; attempt_id = "sim-0123456789abcdef"
    ; case_id = Some "first"
    ; label = "retained-vcd"
    ; kind = "waveform"
    ; media_type = "text/vcd"
    ; size = Some 100
    ; sha256 = Some (String.make 64 'a')
    ; availability = Available
    }
  in
  let data =
    D.parse
      "$timescale 1 ns $end\n\
       $var wire 1 ! bit $end\n\
       $enddefinitions $end\n\
       #0\n\
       1!\n\
       #100\n\
       0!\n"
    |> Or_error.ok_exn
  in
  let t = receive (create ~project:"captured-project" artifact) (Ok data) in
  let plain view =
    let b = Buffer.create 1024 in
    Notty.Render.to_buffer
      b
      Notty.Cap.dumb
      (0, 0)
      (Bonsai_term.View.width view, Bonsai_term.View.height view)
      (Bonsai_term.View.Private.notty_image view);
    Buffer.contents b
  in
  List.iter [ 22; 44; 70; 120 ] ~f:(fun width ->
    let view =
      render_session ~hints:false t ~project_label:"captured-root" ~width ~height:2
    in
    assert (Bonsai_term.View.width view = width && Bonsai_term.View.height view = 2);
    let text = plain view in
    List.iter
      [ "sim-…cdef"; "retained-vcd"; "first"; "Ready"; "1 ns" ]
      ~f:(fun substring -> assert (String.is_substring text ~substring));
    assert (not (String.is_substring text ~substring:artifact.attempt_id)));
  let failed = receive t (Or_error.error_string "missing retained bytes") in
  let failed_text =
    render_session ~hints:false failed ~project_label:"captured-root" ~width:44 ~height:2
    |> plain
  in
  assert (String.is_substring failed_text ~substring:"sim-…cdef");
  assert (String.is_substring failed_text ~substring:"first: VCD unavailable");
  assert (
    String.is_substring
      (String.concat (identity_lines t ~width:80))
      ~substring:("Attempt " ^ artifact.attempt_id));
  assert (same t ~project:"captured-project" artifact)
;;

let%test_unit "native cursor is exact at transitions and preserves every glyph in all \
               themes"
  =
  let data =
    D.parse
      "$timescale 10 ps $end\n\
       $var wire 1 ! clock $end\n\
       $var wire 4 \" bus $end\n\
       $enddefinitions $end\n\
       #0\n\
       0!\n\
       b0000 \"\n\
       #5\n\
       1!\n\
       b1010 \"\n\
       #10\n\
       0!\n\
       b0101 \"\n\
       #15\n\
       1!\n\
       b1111 \"\n\
       #10000\n\
       0!\n"
    |> Or_error.ok_exn
  in
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "cursor"
    ; attempt_id = "attempt"
    ; case_id = None
    ; label = "Clock and bus"
    ; kind = "waveform"
    ; media_type = "text/vcd"
    ; size = Some 100
    ; sha256 = Some (String.make 64 'a')
    ; availability = Available
    }
  in
  let t =
    { (receive (create ~project:"project" artifact) (Ok data)) with
      span = 16L
    ; cursor = 5L
    }
  in
  let geometry = waves_geometry ~width:80 ~height:24 in
  let mapping = waves_mapping t data ~width:80 in
  assert (Int64.equal (Time.stop mapping) 16L);
  let cursor_column =
    match Time.cursor mapping 5L with
    | Column c -> c
    | _ -> assert false
  in
  let cursor_x = cursor_column + 1 in
  let a, b = Option.value_exn (Time.cell_bounds mapping ~column:cursor_column) in
  assert (Int64.equal a 5L && Int64.equal b 5L);
  let signals = Array.to_list (D.signals data) in
  assert (
    String.equal
      (Option.value_exn (D.value_at data (List.hd_exn signals) ~time:t.cursor))
      "1");
  let plot =
    graph t data ~width:geometry.plot_width ~height:geometry.graph_height signals
  in
  let output cap view =
    let b = Buffer.create 8192 in
    Notty.Render.to_buffer
      b
      cap
      (0, 0)
      (Bonsai_term.View.width view, Bonsai_term.View.height view)
      (Bonsai_term.View.Private.notty_image view);
    Buffer.contents b
  in
  let sample view x y = Bonsai_term.View.crop ~l:x ~t:y view |> box ~width:1 ~height:1 in
  let plain =
    render_plot
      ~appearance:Appearance.default
      mapping
      ~cursor:t.cursor
      ~width:geometry.plot_width
      ~height:geometry.graph_height
      ~native:false
      plot
  in
  let glyph = sample plain cursor_x 1 |> output Notty.Cap.dumb |> String.strip in
  assert (String.equal glyph "|");
  List.iter Appearance.Scheme.all ~f:(fun scheme ->
    List.iter Appearance.Preset.all ~f:(fun preset ->
      List.iter Appearance.Color.all ~f:(fun color ->
        let appearance = { Appearance.default with scheme; preset; color } in
        let overlay =
          render_plot
            ~appearance
            mapping
            ~cursor:t.cursor
            ~width:geometry.plot_width
            ~height:geometry.graph_height
            ~native:true
            plot
        in
        assert (String.equal (output Notty.Cap.dumb overlay) (output Notty.Cap.dumb plain));
        let expected =
          Bonsai_term.View.text ~attrs:[ Bonsai_term.Attr.bold ] glyph
          |> Bonsai_term.View.with_colors
               ~fill_backdrop:true
               ~fg:(Host_view.Role.backdrop appearance Foreground)
               ~bg:(Host_view.Role.foreground appearance Focus)
        in
        assert (
          String.equal
            (output Notty.Cap.ansi (sample overlay cursor_x 1))
            (output Notty.Cap.ansi expected));
        (* The frame and neighbouring cell must not acquire the cursor's fill. *)
        let normal =
          render_plot
            ~appearance
            mapping
            ~cursor:t.cursor
            ~width:geometry.plot_width
            ~height:geometry.graph_height
            ~native:false
            plot
        in
        List.iter
          [ cursor_x, 0; cursor_x + 1, 1; cursor_x, geometry.graph_height - 1 ]
          ~f:(fun (x, y) ->
            assert (
              String.equal
                (output Notty.Cap.ansi (sample overlay x y))
                (output Notty.Cap.ansi (sample normal x y)))))));
  let compressed = { t with span = 4096L } in
  let compressed_mapping = waves_mapping compressed data ~width:80 in
  assert (Time.equal_cursor (Time.cursor compressed_mapping t.cursor) (Column 0));
  assert (
    Option.equal
      [%equal: int64 * int64]
      (Time.cell_bounds compressed_mapping ~column:0)
      (Some (0L, 63L)));
  let dense =
    graph compressed data ~width:geometry.plot_width ~height:geometry.graph_height signals
  in
  let dense_view native =
    render_plot
      ~appearance:Appearance.default
      compressed_mapping
      ~cursor:t.cursor
      ~width:geometry.plot_width
      ~height:geometry.graph_height
      ~native
      dense
  in
  assert (
    String.equal
      (output Notty.Cap.dumb (dense_view true))
      (output Notty.Cap.dumb (dense_view false)));
  assert (
    not
      (String.equal
         (output Notty.Cap.ansi (sample (dense_view true) 1 1))
         (output Notty.Cap.ansi (sample (dense_view false) 1 1))));
  let rendered = render_waves ~hints:false t ~width:80 ~height:24 in
  let text = output Notty.Cap.dumb rendered in
  List.iter
    [ "Time"; "absolute"; "0 ps"; "160 ps"; "Cursor 5 ticks" ]
    ~f:(fun substring -> assert (String.is_substring text ~substring));
  assert (
    String.is_substring
      (output
         Notty.Cap.dumb
         (Bonsai_term.View.crop ~t:geometry.ruler_y rendered |> box ~width:80 ~height:2))
      ~substring:"160 ps");
  assert (
    String.equal
      (output
         Notty.Cap.ansi
         (sample rendered (geometry.plot_x + cursor_column) geometry.plot_y))
      (output
         Notty.Cap.ansi
         (sample
            (render_plot
               ~appearance:Appearance.default
               mapping
               ~cursor:t.cursor
               ~width:geometry.plot_width
               ~height:geometry.graph_height
               ~native:true
               plot)
            cursor_x
            1)))
;;

let%test_unit "compressed cells, offscreen pan, huge times, bounds and render \
               immutability"
  =
  let data =
    D.parse
      "$timescale 100 fs $end\n\
       $var wire 1 ! bit $end\n\
       $enddefinitions $end\n\
       #0\n\
       0!\n\
       #9223372036854775807\n\
       1!\n"
    |> Or_error.ok_exn
  in
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "huge"
    ; attempt_id = "attempt"
    ; case_id = None
    ; label = "Huge absolute time"
    ; kind = "waveform"
    ; media_type = "text/vcd"
    ; size = Some 100
    ; sha256 = Some (String.make 64 'a')
    ; availability = Available
    }
  in
  let base = receive (create ~project:"project" artifact) (Ok data) in
  let t =
    { base with start = Int64.(max_value - 100L); cursor = Int64.max_value; span = 128L }
  in
  let output view =
    let b = Buffer.create 8192 in
    Notty.Render.to_buffer
      b
      Notty.Cap.dumb
      (0, 0)
      (Bonsai_term.View.width view, Bonsai_term.View.height view)
      (Bonsai_term.View.Private.notty_image view);
    Buffer.contents b
  in
  List.iter [ 80; 120; 230 ] ~f:(fun width ->
    let mapping = waves_mapping t data ~width in
    assert (Int64.(Time.stop mapping <= max_value));
    let last = Time.stop mapping in
    let cursor = { t with cursor = last } in
    let position =
      match Time.cursor mapping last with
      | Column c -> c
      | _ -> assert false
    in
    let _, end_ = Option.value_exn (Time.cell_bounds mapping ~column:position) in
    assert (Int64.equal end_ last);
    let view = render_waves ~hints:false cursor ~width ~height:24 in
    assert (Bonsai_term.View.width view = width && Bonsai_term.View.height view = 24);
    assert (
      String.is_substring
        (output view)
        ~substring:(Time.format_compact (D.timescale data) (Time.start mapping)));
    assert (
      String.is_substring
        (String.concat (identity_lines cursor ~width))
        ~substring:"Huge absolute time"));
  let mapping = waves_mapping t data ~width:120 in
  assert (Int64.equal (Time.stop mapping) Int64.max_value);
  assert (
    String.is_substring
      (output (render_waves ~hints:false t ~width:120 ~height:24))
      ~substring:"922337.2036854775807 s");
  let compressed = { base with start = 100L; cursor = 105L; span = 4096L } in
  let mapping = waves_mapping compressed data ~width:80 in
  assert (
    match Time.scale mapping with
    | Window_cells { compressed = true } | Ticks_per_cell _ -> true
    | _ -> false);
  let column =
    match Time.cursor mapping compressed.cursor with
    | Column c -> c
    | _ -> assert false
  in
  let first, last = Option.value_exn (Time.cell_bounds mapping ~column) in
  assert (Int64.(first <= compressed.cursor && compressed.cursor <= last));
  let text = output (render_waves ~hints:false compressed ~width:80 ~height:24) in
  assert (String.is_substring text ~substring:"Cursor 105 ticks");
  assert (String.is_substring text ~substring:(sprintf "cell %Ld..%Ld" first last));
  List.iter
    [ { compressed with cursor = 0L }, "off-screen left"
    ; { compressed with cursor = 10000L }, "off-screen right"
    ]
    ~f:(fun (view, status) ->
      let start, cursor, span, filter, selected =
        view.start, view.cursor, view.span, view.filter, view.selected
      in
      assert (
        String.is_substring
          (output (render_waves ~hints:false view ~width:80 ~height:24))
          ~substring:status);
      let g = waves_geometry ~width:80 ~height:24 in
      let mapping = waves_mapping view data ~width:80 in
      let plot =
        graph
          view
          data
          ~width:g.plot_width
          ~height:g.graph_height
          (Array.to_list (D.signals data))
      in
      let ansi native =
        let image =
          render_plot
            ~appearance:Appearance.default
            mapping
            ~cursor:view.cursor
            ~width:g.plot_width
            ~height:g.graph_height
            ~native
            plot
        in
        let b = Buffer.create 4096 in
        Notty.Render.to_buffer
          b
          Notty.Cap.ansi
          (0, 0)
          (g.plot_width, g.graph_height)
          (Bonsai_term.View.Private.notty_image image);
        Buffer.contents b
      in
      assert (String.equal (ansi true) (ansi false));
      assert (
        Int64.equal start view.start
        && Int64.equal cursor view.cursor
        && Int64.equal span view.span
        && String.equal filter view.filter
        && Set.equal selected view.selected));
  let panned = input base (Char ']') in
  assert (Int64.equal panned.cursor base.cursor);
  assert (
    String.is_substring
      (output (render_waves panned ~width:80 ~height:24))
      ~substring:"off-screen left");
  let quick =
    render panned { Bonsai_term.Dimensions.width = 120; height = 40 } |> output
  in
  assert (String.is_substring quick ~substring:"off-screen left");
  assert (String.is_substring quick ~substring:"absolute")
;;

let%test_unit "default clock extent, explicit Fit and resize retain original ticks" =
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "extent"
    ; attempt_id = "attempt"
    ; case_id = None
    ; label = "extent"
    ; kind = "trace"
    ; media_type = "text/vcd"
    ; size = Some 100
    ; sha256 = Some (String.make 64 'a')
    ; availability = Available
    }
  in
  List.iter [ 2; 10000 ] ~f:(fun period ->
    let data =
      D.parse
        ("$timescale 1ps $end $var wire 1 ! clk $end $enddefinitions $end "
         ^ String.concat
             (List.init 30 ~f:(fun i -> sprintf "#%d %d! " (i * period / 2) (i % 2))))
      |> Or_error.ok_exn
    in
    let t = receive (create ~project:"p" artifact) (Ok data) in
    assert (Int64.equal t.span (Int64.of_int (8 * period)));
    assert (String.is_substring t.extent_basis ~substring:"8 cycles");
    let fit = input t (Char 'f') in
    let _, last = D.time_bounds data in
    assert (Int64.equal (stop fit data) last && Int64.equal fit.cursor t.cursor);
    List.iter [ 7; 32; 80; 230; 1000 ] ~f:(fun width ->
      let ready = prepare_waves fit ~width in
      let mapping = waves_mapping ready data ~width in
      assert (Int64.equal (Time.start mapping) 0L && Int64.equal (Time.stop mapping) last));
    assert (Int64.equal (input fit Right).cursor 1L);
    let default = input fit (Char 'd') in
    assert (Int64.equal default.span t.span));
  let point =
    D.parse "$timescale 100fs $end $var wire 1 ! data $end $enddefinitions $end #0 1!"
    |> Or_error.ok_exn
  in
  let t = receive (create ~project:"p" artifact) (Ok point) in
  assert (Int64.equal t.span 0L);
  assert (String.is_substring t.extent_basis ~substring:"no reliable clock");
  List.iter [ Char 'f'; Char 'd'; Char '+'; Char '-'; Right; Left ] ~f:(fun key ->
    let t = input t key in
    assert (Int64.equal t.cursor 0L && Int64.equal (stop t point) 0L);
    let text = graph t point ~width:3 ~height:4 (Array.to_list (D.signals point)) in
    assert (not (String.is_substring text ~substring:"unavailable")))
;;

let%test_unit "short inferred clock labels its clipped target rather than achieved eight \
               cycles"
  =
  let data =
    D.parse
      ("$timescale 1ps $end $var wire 1 ! clk $end $enddefinitions $end "
       ^ String.concat (List.init 11 ~f:(fun i -> sprintf "#%d %d! " (i * 5) (i % 2))))
    |> Or_error.ok_exn
  in
  let start, span, basis = default_extent data in
  assert (Int64.equal start 0L && Int64.equal span 50L);
  assert (String.is_substring basis ~substring:"8-cycle target (clipped to trace)");
  assert (not (String.is_substring basis ~substring:"8 cycles"));
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "short"
    ; attempt_id = "attempt"
    ; case_id = None
    ; label = "short"
    ; kind = "trace"
    ; media_type = "text/vcd"
    ; size = Some 100
    ; sha256 = Some (String.make 64 'a')
    ; availability = Available
    }
  in
  let t = receive (create ~project:"p" artifact) (Ok data) in
  let t = input (input t (Char 'f')) (Char 'd') in
  let view = render_waves t ~width:180 ~height:24 in
  let buffer = Buffer.create 8192 in
  Notty.Render.to_buffer
    buffer
    Notty.Cap.dumb
    (0, 0)
    (180, 24)
    (Bonsai_term.View.Private.notty_image view);
  let rendered = Buffer.contents buffer in
  assert (String.is_substring rendered ~substring:"clipped to trace");
  assert (String.is_substring rendered ~substring:"extent 50 ps");
  assert (not (String.is_substring rendered ~substring:"8 cycles"))
;;
