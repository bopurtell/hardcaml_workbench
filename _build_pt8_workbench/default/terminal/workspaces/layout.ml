open! Core
open Hardcaml_workbench_protocol
module G = Workspace.Geometry

type t =
  | Grid of G.t list
  | Compact

type resolved =
  | Cell of int * int * int * int
  | Stack of resolved list
  | Columns of resolved list
  | Weighted_columns of (int * resolved) list
  | Narrow of resolved

let rec min_size ?(gutter = 0) = function
  | Cell (_, w, h, _) -> w, h
  | Narrow tree -> min_size ~gutter tree
  | Weighted_columns children ->
    let width, height =
      List.fold children ~init:(0, 0) ~f:(fun (u, h) (_, child) ->
        let w, ch = min_size ~gutter child in
        u + w, Int.max h ch)
    in
    width + (gutter * (List.length children - 1)), height
  | Stack children ->
    let sizes = List.map children ~f:(min_size ~gutter) in
    List.fold
      sizes
      ~init:(0, gutter * Int.max 0 (List.length sizes - 1))
      ~f:(fun (w, h) (a, b) -> Int.max w a, h + b)
  | Columns children ->
    let sizes = List.map children ~f:(min_size ~gutter) in
    List.fold
      sizes
      ~init:(gutter * Int.max 0 (List.length sizes - 1), 0)
      ~f:(fun (w, h) (a, b) -> w + a, Int.max h b)
;;

let rec weight = function
  | Cell (_, _, _, w) -> w
  | Narrow _ -> 0
  | Weighted_columns children ->
    List.fold children ~init:0 ~f:(fun w (_, child) -> Int.max w (weight child))
  | Stack children | Columns children ->
    List.fold children ~init:0 ~f:(fun w child -> Int.max w (weight child))
;;

let rec place ?(gutter = 0) tree (g : G.t) =
  match tree with
  | Cell (i, _, min_height, weight) ->
    [ (i, if weight = 0 then { g with height = min_height } else g) ]
  | Narrow tree -> place ~gutter tree g
  | Weighted_columns children ->
    let total = g.width - (gutter * (List.length children - 1)) in
    (* Ratios describe full width; clamp undersized columns at their minima and
       redistribute the remainder. This is shared policy, including custom trees. *)
    let rec allocate available children =
      let sum = List.sum (module Int) children ~f:(fun (_, w, _) -> w) in
      let fixed, flexible =
        List.partition_tf children ~f:(fun (_, w, child) ->
          available * w / Int.max 1 sum < fst (min_size ~gutter child))
      in
      if List.is_empty fixed
      then (
        let _, sizes =
          List.fold children ~init:(0, []) ~f:(fun (used, sizes) (i, w, _) ->
            ( used + w
            , (i, (available * (used + w) / sum) - (available * used / sum)) :: sizes ))
        in
        sizes)
      else (
        let fixed =
          List.map fixed ~f:(fun (i, _, child) -> i, fst (min_size ~gutter child))
        in
        fixed @ allocate (available - List.sum (module Int) fixed ~f:snd) flexible)
    in
    let sizes =
      allocate total (List.mapi children ~f:(fun i (w, child) -> i, w, child))
    in
    let _, cells =
      List.foldi children ~init:(0, []) ~f:(fun i (offset, cells) (_, child) ->
        let width = List.Assoc.find_exn sizes i ~equal:Int.equal in
        ( offset + width + gutter
        , cells @ place ~gutter child { g with x = g.x + offset; width } ))
    in
    cells
  | Stack children | Columns children ->
    let vertical =
      match tree with
      | Stack _ -> true
      | _ -> false
    in
    let minimum child =
      let w, h = min_size ~gutter child in
      if vertical then h else w
    in
    let total = if vertical then g.height else g.width in
    let spare =
      total
      - List.sum (module Int) children ~f:minimum
      - (gutter * (List.length children - 1))
    in
    let weights = List.map children ~f:weight in
    let sum = List.sum (module Int) weights ~f:Fn.id in
    let weights =
      if sum = 0
      then
        List.map children ~f:(function
          | Narrow _ when not vertical -> 0
          | _ -> 1)
      else weights
    in
    let sum = Int.max 1 (List.sum (module Int) weights ~f:Fn.id) in
    let _, _, cells =
      List.fold2_exn
        children
        weights
        ~init:(0, 0, [])
        ~f:(fun (offset, used_weight, cells) child w ->
          let extra = (spare * (used_weight + w) / sum) - (spare * used_weight / sum) in
          let size = minimum child + extra in
          let cell =
            if vertical
            then { g with y = g.y + offset; height = size }
            else { g with x = g.x + offset; width = size }
          in
          offset + size + gutter, used_weight + w, cells @ place ~gutter child cell)
    in
    cells
;;

let resolve ?(min_height_for_index = fun _ -> None) tree kinds =
  let minimum i h = Int.max h (Option.value (min_height_for_index i) ~default:0) in
  let claimed = ref [] in
  let rec loop = function
    | Common.Leaf { kind; min_width; min_height; weight } ->
      List.findi kinds ~f:(fun i k ->
        String.equal k kind && not (List.mem !claimed i ~equal:Int.equal))
      |> Option.map ~f:(fun (i, _) ->
        claimed := i :: !claimed;
        Cell (i, min_width, minimum i min_height, weight))
    | Common.Stack children -> node children (fun cs -> Stack cs)
    | Common.Columns children -> node children (fun cs -> Columns cs)
    | Common.Weighted_columns children ->
      (match
         List.filter_map children ~f:(fun (w, child) ->
           Option.map (loop child) ~f:(fun child -> Int.max 1 w, child))
       with
       | [] -> None
       | [ (_, child) ] -> Some child
       | children -> Some (Weighted_columns children))
    | Common.Narrow tree -> Option.map (loop tree) ~f:(fun t -> Narrow t)
  and node children make =
    match List.filter_map children ~f:loop with
    | [] -> None
    | [ child ] -> Some child
    | children -> Some (make children)
  in
  let primary = loop tree in
  let extras =
    List.filter_mapi kinds ~f:(fun i _ ->
      if List.mem !claimed i ~equal:Int.equal
      then None
      else Some (Cell (i, 24, minimum i 6, 1)))
  in
  match primary, extras with
  | None, [] -> None
  | Some tree, [] -> Some tree
  | None, extras -> Some (Stack extras)
  | Some tree, extras -> Some (Stack [ tree; Stack extras ])
;;

(** Input indices in depth-first layout order, independent of available geometry. [kinds]
    contains authoring keys for configured layouts, as in [compute]. Missing leaves are
    skipped; unmatched inputs follow the tree in their original order. *)
let navigation_order (definition : Definition.t) ~kinds =
  let rec leaves = function
    | Cell (i, _, _, _) -> [ i ]
    | Stack children | Columns children -> List.concat_map children ~f:leaves
    | Weighted_columns children ->
      List.concat_map children ~f:(fun (_, child) -> leaves child)
    | Narrow tree -> leaves tree
  in
  Option.value_map (resolve definition.layout kinds) ~default:[] ~f:leaves
;;

let grid ?(gutter = 0) ?(min_height_for_index = fun _ -> None) ~width ~height count =
  List.range 1 (Int.min count 4 + 1)
  |> List.find_map ~f:(fun columns ->
    let rows = (count + columns - 1) / columns in
    if width < (columns * 25) - 1 || height < (rows * 7) - 1
    then None
    else (
      let tree =
        Stack
          (List.init rows ~f:(fun row ->
             Columns
               (List.init
                  (Int.min columns (count - (row * columns)))
                  ~f:(fun col ->
                    let i = (row * columns) + col in
                    Cell
                      ( i
                      , 24
                      , Int.max 6 (Option.value (min_height_for_index i) ~default:0)
                      , 1 )))))
      in
      let w, h = min_size ~gutter tree in
      if width < w || height < h
      then None
      else Some (place ~gutter tree { G.x = 0; y = 0; width; height })))
;;

(** Fit never writes persisted requested geometry. Host handles [Compact] by showing the
    focused tile; zoom should bypass this function entirely. *)
let compute
  ?(gutter = 0)
  ?(min_height_for_index = fun _ -> None)
  (definition : Definition.t)
  ~width
  ~height
  ~kinds
  =
  let gutter = Int.max 0 gutter in
  if List.is_empty kinds
  then Grid []
  else (
    let layout = definition.layout in
    let cells =
      Option.bind (resolve ~min_height_for_index layout kinds) ~f:(fun tree ->
        let w, h = min_size ~gutter tree in
        if width >= w && height >= h
        then Some (place ~gutter tree { G.x = 0; y = 0; width; height })
        else None)
    in
    let cells =
      match cells with
      | Some _ -> cells
      | None -> grid ~gutter ~min_height_for_index ~width ~height (List.length kinds)
    in
    match cells with
    | None -> Compact
    | Some cells ->
      Grid
        (List.sort cells ~compare:(fun (a, _) (b, _) -> Int.compare a b)
         |> List.map ~f:snd))
;;
