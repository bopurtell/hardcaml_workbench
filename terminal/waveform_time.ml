open! Core

type scale =
  | Cells_per_tick of int
  | Ticks_per_cell of int
  | Window_cells of { compressed : bool }

type cursor =
  | Left
  | Right
  | Column of int
[@@deriving equal, sexp_of]

type t =
  { columns : int
  ; start : int64
  ; stop : int64
  ; scale : scale
  ; cells : (int64 * int64) array option
  }

let scale_of_code code =
  if code < -1_000_000 || code > 1_000_000 then invalid_arg "Waveform raster code limit";
  if code = -1
  then Cells_per_tick 1
  else if code < -1
  then Ticks_per_cell (-code)
  else Cells_per_tick (2 * (code + 1))
;;

let capacity ~code ~columns =
  if columns < 1 || columns > 4096 then invalid_arg "Waveform raster column limit";
  match scale_of_code code with
  | Cells_per_tick n -> (columns + n - 1) / n
  | Ticks_per_cell n -> columns * n
  | Window_cells _ -> assert false
;;

let create ~code ~columns ~start ~stop =
  if Int64.(start < 0L || stop < start) then invalid_arg "Invalid waveform time window";
  let length = capacity ~code ~columns in
  { columns
  ; start
  ; stop = Int64.(start + min (stop - start) (of_int length - 1L))
  ; scale = scale_of_code code
  ; cells = None
  }
;;

(* Divide before multiplying: even [0,max_value] never forms an inclusive length. *)
let offset distance numerator denominator =
  let d = Int64.of_int denominator
  and n = Int64.of_int numerator in
  Int64.((distance / d * n) + (rem distance d * n / d))
;;

let create_window ~columns ~start ~stop =
  if columns < 1 || columns > 4096 || Int64.(start < 0L || stop < start)
  then invalid_arg "Invalid waveform window";
  let distance = Int64.(stop - start) in
  let compressed = Int64.(distance >= of_int columns) in
  let cells =
    Array.init columns ~f:(fun i ->
      if compressed
      then (
        let first = Int64.(start + offset distance i columns) in
        let last =
          if i = columns - 1
          then stop
          else Int64.(start + offset distance (Int.succ i) columns - 1L)
        in
        first, last)
      else (
        let denominator = Int.max 1 (columns - 1) in
        let tick = Int64.(start + offset distance i denominator) in
        tick, tick))
  in
  { columns; start; stop; scale = Window_cells { compressed }; cells = Some cells }
;;

let columns t = t.columns
let start t = t.start
let stop t = t.stop
let scale t = t.scale

let cursor t time =
  if Int64.(time < t.start)
  then Left
  else if Int64.(time > t.stop)
  then Right
  else (
    match t.cells with
    | Some cells ->
      let rec search i =
        if i = t.columns - 1 || Int64.(time <= snd cells.(i))
        then Column i
        else search (i + 1)
      in
      search 0
    | None ->
      let delta = Int64.(time - t.start) in
      let column =
        match t.scale with
        | Cells_per_tick n -> Int64.(delta * of_int n)
        | Ticks_per_cell n -> Int64.(delta / of_int n)
        | Window_cells _ -> assert false
      in
      (* [create] bounded the visible window before this multiplication, so an
       expanded tick's first cell is always in [0, columns). *)
      Column (Int64.to_int_exn column))
;;

let cell_bounds t ~column =
  if column < 0 || column >= t.columns
  then None
  else (
    match t.cells with
    | Some cells -> Some cells.(column)
    | None ->
      let offset, count =
        match t.scale with
        | Cells_per_tick n -> column / n, 1
        | Ticks_per_cell n -> column * n, n
        | Window_cells _ -> assert false
      in
      let offset = Int64.of_int offset in
      if Int64.(offset > t.stop - t.start)
      then None
      else (
        let first = Int64.(t.start + offset) in
        Some (first, Int64.(first + min (t.stop - first) (of_int count - 1L)))))
;;

let format_time (timescale : Waveform_data.timescale) time =
  if Int64.(time < 0L) then invalid_arg "Negative VCD physical time";
  let zeroes =
    match timescale.magnitude with
    | 1 -> 0
    | 10 -> 1
    | 100 -> 2
    | _ -> invalid_arg "Unsupported VCD timescale magnitude"
  in
  let unit_ =
    match timescale.unit_ with
    | S -> "s"
    | Ms -> "ms"
    | Us -> "us"
    | Ns -> "ns"
    | Ps -> "ps"
    | Fs -> "fs"
  in
  let number =
    if Int64.equal time 0L then "0" else Int64.to_string time ^ String.make zeroes '0'
  in
  number ^ " " ^ unit_
;;

let format_compact (timescale : Waveform_data.timescale) time =
  let raw = format_time timescale time |> String.lsplit2_exn ~on:' ' |> fst in
  let units = [| "fs"; "ps"; "ns"; "us"; "ms"; "s" |] in
  let initial =
    match timescale.unit_ with
    | Fs -> 0
    | Ps -> 1
    | Ns -> 2
    | Us -> 3
    | Ms -> 4
    | S -> 5
  in
  let groups = Int.min (5 - initial) ((String.length raw - 1) / 3) in
  if groups = 0
  then raw ^ " " ^ units.(initial)
  else (
    let split = String.length raw - (groups * 3) in
    let fraction = String.drop_prefix raw split |> String.rstrip ~drop:(Char.equal '0') in
    String.prefix raw split
    ^ (if String.is_empty fraction then "" else "." ^ fraction)
    ^ " "
    ^ units.(initial + groups))
;;

type label =
  { tick : int64
  ; column : int
  ; text_column : int
  ; text : string
  }

type ruler =
  { labels : label list
  ; major_columns : int list
  ; minor_columns : int list
  }

let legacy_ruler t ~timescale =
  let last_column =
    match cursor t t.stop with
    | Column c -> c
    | Left | Right -> assert false
  in
  let text_width =
    Int.max
      (String.length (format_time timescale t.start))
      (String.length (format_time timescale t.stop))
  in
  let desired_cells = text_width + 2 in
  let minimum_step =
    match t.scale with
    | Cells_per_tick n -> Int.max 1 ((desired_cells + n - 1) / n)
    | Ticks_per_cell n -> desired_cells * n
    | Window_cells _ -> assert false
  in
  let rec nice power =
    match List.find [ power; power * 2; power * 5 ] ~f:(fun n -> n >= minimum_step) with
    | Some n -> n
    | None -> nice (power * 10)
  in
  let step = nice 1 in
  let step =
    match t.scale with
    | Cells_per_tick _ -> step
    | Ticks_per_cell n -> (step + n - 1) / n * n
    | Window_cells _ -> assert false
  in
  let minor =
    match t.scale with
    | Cells_per_tick _ -> Int.max 1 (step / 5)
    | Ticks_per_cell n -> Int.max (2 * n) (step / 5 / n * n)
    | Window_cells _ -> assert false
  in
  let aligned stride =
    let stride = Int64.of_int stride in
    let remainder = Int64.rem t.start stride in
    let offset = if Int64.equal remainder 0L then 0L else Int64.(stride - remainder) in
    if Int64.(offset > t.stop - t.start)
    then []
    else (
      let rec loop tick columns =
        let column =
          match cursor t tick with
          | Column c -> c
          | _ -> assert false
        in
        let columns = column :: columns in
        if Int64.(t.stop - tick < stride)
        then List.rev columns
        else loop Int64.(tick + stride) columns
      in
      loop Int64.(t.start + offset) [])
  in
  let major_columns =
    0 :: last_column :: aligned step |> List.dedup_and_sort ~compare:Int.compare
  in
  let minor_columns =
    aligned minor
    |> List.dedup_and_sort ~compare:Int.compare
    |> List.filter ~f:(fun c -> not (List.mem major_columns c ~equal:Int.equal))
  in
  let candidate column =
    match cell_bounds t ~column with
    | None -> None
    | Some (tick, _) ->
      let text = format_time timescale tick in
      if String.length text > t.columns
      then None
      else
        Some
          { tick
          ; column
          ; text_column = Int.min column (t.columns - String.length text)
          ; text
          }
  in
  let apart a b =
    a.text_column + String.length a.text + 2 <= b.text_column
    || b.text_column + String.length b.text + 2 <= a.text_column
  in
  let endpoints =
    [ 0; last_column ]
    |> List.dedup_and_sort ~compare:Int.compare
    |> List.filter_map ~f:candidate
    |> List.fold ~init:[] ~f:(fun placed label ->
      if List.for_all placed ~f:(apart label) then label :: placed else placed)
  in
  let labels =
    major_columns
    |> List.filter ~f:(fun c -> c <> 0 && c <> last_column)
    |> List.filter_map ~f:candidate
    |> List.fold ~init:endpoints ~f:(fun placed label ->
      if List.for_all placed ~f:(apart label) then label :: placed else placed)
    |> List.sort ~compare:(fun a b -> Int.compare a.text_column b.text_column)
  in
  { labels; major_columns; minor_columns }
;;

let ruler t ~timescale =
  match t.cells with
  | None -> legacy_ruler t ~timescale
  | Some _ ->
    let labels = ref [] in
    List.iter
      [ 0; t.columns - 1; t.columns / 2; t.columns / 4; 3 * t.columns / 4 ]
      ~f:(fun column ->
        let tick, _ = Option.value_exn (cell_bounds t ~column) in
        let column =
          match cursor t tick with
          | Column c -> c
          | _ -> assert false
        in
        let text = format_compact timescale tick in
        let text_column = Int.min column (t.columns - String.length text) in
        if text_column >= 0
           && List.for_all !labels ~f:(fun l ->
             text_column + String.length text + 2 <= l.text_column
             || l.text_column + String.length l.text + 2 <= text_column)
        then labels := { tick; column; text_column; text } :: !labels);
    { labels =
        List.sort !labels ~compare:(fun a b -> Int.compare a.text_column b.text_column)
    ; major_columns = List.map !labels ~f:(fun l -> l.column)
    ; minor_columns = []
    }
;;

let%test_unit "exact mapping, compressed/expanded partial end and huge physical units" =
  let expanded = create ~code:1 ~columns:10 ~start:100L ~stop:200L in
  assert (Int64.equal (stop expanded) 102L);
  assert (equal_cursor (cursor expanded 100L) (Column 0));
  assert (equal_cursor (cursor expanded 101L) (Column 4));
  assert (equal_cursor (cursor expanded 102L) (Column 8));
  assert (
    Option.equal
      [%equal: int64 * int64]
      (cell_bounds expanded ~column:9)
      (Some (102L, 102L)));
  assert (
    equal_cursor (cursor expanded 99L) Left && equal_cursor (cursor expanded 103L) Right);
  let compressed = create ~code:(-4) ~columns:10 ~start:100L ~stop:110L in
  assert (equal_cursor (cursor compressed 107L) (Column 1));
  assert (equal_cursor (cursor compressed 110L) (Column 2));
  assert (
    Option.equal
      [%equal: int64 * int64]
      (cell_bounds compressed ~column:2)
      (Some (108L, 110L)));
  assert (Option.is_none (cell_bounds compressed ~column:3));
  let high =
    create ~code:(-4) ~columns:10 ~start:Int64.(max_value - 9L) ~stop:Int64.max_value
  in
  assert (equal_cursor (cursor high Int64.max_value) (Column 2));
  assert (
    String.equal
      (format_time { magnitude = 100; unit_ = Ns } Int64.max_value)
      "922337203685477580700 ns");
  assert (String.equal (format_time { magnitude = 10; unit_ = Ps } 0L) "0 ps");
  assert (
    String.equal
      (format_time { magnitude = 10; unit_ = Ps } 9007199254740993L)
      "90071992547409930 ps")
;;

let%test_unit "inclusive physical windows cover extreme bounds at every resolution" =
  List.iter
    [ 0L, Int64.max_value
    ; Int64.(max_value - 9L), Int64.max_value
    ; 9007199254740993L, 9007199254741000L
    ; 17L, 17L
    ; 0L, 1L
    ]
    ~f:(fun (start, stop) ->
      List.iter [ 1; 2; 5; 80; 4096 ] ~f:(fun columns ->
        let t = create_window ~columns ~start ~stop in
        assert (Int64.equal t.start start && Int64.equal t.stop stop);
        let previous = ref start in
        for column = 0 to columns - 1 do
          let a, b = Option.value_exn (cell_bounds t ~column) in
          assert (Int64.(a >= start && b >= a && b <= stop));
          if column > 0 then assert (Int64.(a = !previous || a - !previous = 1L));
          previous := b;
          List.iter [ a; b ] ~f:(fun tick ->
            match cursor t tick with
            | Column c ->
              let x, y = Option.value_exn (cell_bounds t ~column:c) in
              assert (Int64.(x <= tick && tick <= y))
            | _ -> assert false)
        done;
        assert (Int64.equal !previous stop);
        assert (Option.is_none (cell_bounds t ~column:columns));
        let r = ruler t ~timescale:{ magnitude = 100; unit_ = Fs } in
        List.iter r.labels ~f:(fun l ->
          assert (l.text_column >= 0 && l.text_column + String.length l.text <= columns))));
  assert (String.equal (format_compact { magnitude = 1; unit_ = Ps } 13070000L) "13.07 us");
  assert (
    String.equal
      (format_compact { magnitude = 100; unit_ = Ns } Int64.max_value)
      "922337203685.4775807 s")
;;

let%test_unit "ruler labels stay exact, separate and inside real cells at all UI widths" =
  List.iter [ -16; -4; -3; -1; 0; 2; 3; 31 ] ~f:(fun code ->
    List.iter [ 5; 32; 80; 120; 230 ] ~f:(fun columns ->
      List.iter
        [ 0L; 123L; Int64.(max_value - 5000L) ]
        ~f:(fun start ->
          let mapping = create ~code ~columns ~start ~stop:Int64.(start + 4095L) in
          let timescale : Waveform_data.timescale = { magnitude = 100; unit_ = Fs } in
          let ruler = ruler mapping ~timescale in
          List.iter ruler.labels ~f:(fun label ->
            assert (String.equal label.text (format_time timescale label.tick));
            assert (equal_cursor (cursor mapping label.tick) (Column label.column));
            assert (
              Int64.equal
                label.tick
                (fst (Option.value_exn (cell_bounds mapping ~column:label.column))));
            assert (
              label.text_column >= 0
              && label.text_column + String.length label.text <= columns));
          let rec separate = function
            | a :: (b :: _ as rest) ->
              assert (a.text_column + String.length a.text + 2 <= b.text_column);
              separate rest
            | _ -> ()
          in
          separate ruler.labels;
          List.iter (ruler.major_columns @ ruler.minor_columns) ~f:(fun column ->
            assert (Option.is_some (cell_bounds mapping ~column))))))
;;
