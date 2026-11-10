open! Core
open Hardcaml_workbench_protocol

type evidence =
  { hierarchy : Hierarchy.t
  ; nodes : Hierarchy.Node.t String.Map.t
  ; branches : String.Set.t
  ; preorder : (int * Hierarchy.Node.t) list
  }

type t =
  { evidence : evidence
  ; selected_key : string
  ; expanded : String.Set.t
  ; visible : (int * Hierarchy.Node.t) list
  ; selected_index : int
  }

let evidence (hierarchy : Hierarchy.t) =
  (* The provider validator rejects duplicate keys, cycles and unreachable nodes. Still
     terminate deterministically if handed unvalidated typed values: first duplicate wins,
     only root-reachable nodes are navigable, and visit once. Do not rewrite the evidence
     or impose a new key encoding (older fixtures use non-[/] roots). All retained indexes
     are persistent maps/sets/lists. *)
  let nodes =
    List.fold hierarchy.nodes ~init:String.Map.empty ~f:(fun nodes node ->
      if Map.mem nodes node.key then nodes else Map.set nodes ~key:node.key ~data:node)
  in
  let children =
    Map.fold nodes ~init:String.Map.empty ~f:(fun ~key:_ ~data:node children ->
      match node.parent with
      | None -> children
      | Some parent -> Map.add_multi children ~key:parent ~data:node)
    |> Map.map
         ~f:
           (List.sort ~compare:(fun a b ->
              match
                Option.compare
                  String.compare
                  a.Hierarchy.Node.instance_name
                  b.Hierarchy.Node.instance_name
              with
              | 0 -> String.compare a.key b.key
              | order -> order))
  in
  let rec visit pending seen reachable branches reversed =
    match pending with
    | [] -> reachable, branches, List.rev reversed
    | (depth, key) :: pending ->
      if Set.mem seen key
      then visit pending seen reachable branches reversed
      else (
        let seen = Set.add seen key in
        match Map.find nodes key with
        | None -> visit pending seen reachable branches reversed
        | Some node ->
          let children =
            Map.find children key
            |> Option.value ~default:[]
            |> List.filter ~f:(fun child -> not (Set.mem seen child.key))
          in
          let pending =
            List.fold (List.rev children) ~init:pending ~f:(fun pending child ->
              (depth + 1, child.key) :: pending)
          in
          visit
            pending
            seen
            (Map.set reachable ~key ~data:node)
            (if List.is_empty children then branches else Set.add branches key)
            ((depth, node) :: reversed))
  in
  let nodes, branches, preorder =
    visit [ 0, hierarchy.root ] String.Set.empty String.Map.empty String.Set.empty []
  in
  { hierarchy; nodes; branches; preorder }
;;

let project evidence expanded =
  (* Preorder and depth let us skip closed subtrees in one tail-recursive pass, without
     rebuilding the shared index or recursively concatenating trees. *)
  let _, reversed =
    List.fold evidence.preorder ~init:(None, []) ~f:(fun (closed, rows) (depth, node) ->
      match closed with
      | Some closed_depth when depth > closed_depth -> closed, rows
      | _ ->
        (if Set.mem expanded node.key then None else Some depth), (depth, node) :: rows)
  in
  List.rev reversed
;;

let create evidence =
  let expanded = String.Set.singleton evidence.hierarchy.root in
  { evidence
  ; selected_key = evidence.hierarchy.root
  ; expanded
  ; visible = project evidence expanded
  ; selected_index = 0
  }
;;

let hierarchy t = t.evidence.hierarchy
let selected_key t = t.selected_key
let selected_node t = Map.find t.evidence.nodes t.selected_key
let visible t = t.visible

let move t delta =
  let last = List.length t.visible - 1 in
  if last < 0
  then t
  else (
    (* Clamp before adding, including [Int.min_value]/[Int.max_value]. *)
    let delta = Int.max (-t.selected_index) (Int.min delta (last - t.selected_index)) in
    let selected_index = t.selected_index + delta in
    match List.nth t.visible selected_index with
    | None -> t
    | Some (_, node) -> { t with selected_key = node.key; selected_index })
;;

let with_expanded t expanded selected_key =
  let visible = project t.evidence expanded in
  let selected_index =
    List.findi visible ~f:(fun _ (_, node) -> String.equal node.key selected_key)
    |> Option.value_map ~default:0 ~f:fst
  in
  { t with expanded; visible; selected_key; selected_index }
;;

let toggle t =
  if not (Set.mem t.evidence.branches t.selected_key)
  then t
  else (
    let expanded =
      if Set.mem t.expanded t.selected_key
      then Set.remove t.expanded t.selected_key
      else Set.add t.expanded t.selected_key
    in
    with_expanded t expanded t.selected_key)
;;

let select t key =
  match Map.find t.evidence.nodes key with
  | None -> t
  | Some _ ->
    let rec ancestors key seen expanded =
      if String.equal key t.evidence.hierarchy.root || Set.mem seen key
      then expanded
      else (
        let seen = Set.add seen key in
        match Map.find t.evidence.nodes key with
        | None -> expanded
        | Some { parent = None; _ } -> expanded
        | Some { parent = Some parent; _ } ->
          ancestors parent seen (Set.add expanded parent))
    in
    with_expanded t (ancestors key String.Set.empty t.expanded) key
;;

let display_label text =
  let buffer = Buffer.create (String.length text) in
  let rec loop offset =
    if offset < String.length text
    then (
      let decoded = Stdlib.String.get_utf_8_uchar text offset in
      let length = Stdlib.Uchar.utf_decode_length decoded in
      let scalar = Stdlib.Uchar.to_int (Stdlib.Uchar.utf_decode_uchar decoded) in
      if not (Stdlib.Uchar.utf_decode_is_valid decoded)
      then Buffer.add_char buffer '?'
      else if scalar < 32
              || (scalar >= 127 && scalar < 160)
              || (scalar >= 0x2028 && scalar <= 0x202e)
              || (scalar >= 0x2066 && scalar <= 0x2069)
      then Buffer.add_char buffer ' '
      else Buffer.add_substring buffer text ~pos:offset ~len:length;
      loop (offset + length))
  in
  loop 0;
  Buffer.contents buffer
;;

let rows ?(icons = Appearance.Icons.Ascii) t ~height =
  if height <= 0
  then []
  else (
    (* A pure viewport: anchor near the selection and fill from the end when necessary.
       Resize never mutates navigation or another consumer's scroll. *)
    let height = Int.min height (List.length t.visible) in
    let start =
      Int.min
        (Int.max 0 (t.selected_index - (height / 2)))
        (List.length t.visible - height)
    in
    t.visible
    |> Fn.flip List.drop start
    |> Fn.flip List.take height
    |> List.map ~f:(fun (depth, node) ->
      let kind =
        if not (Set.mem t.evidence.branches node.key)
        then if String.equal node.key t.evidence.hierarchy.root then Indicator.Top else Leaf
        else if Set.mem t.expanded node.key
        then Expanded
        else Collapsed
      in
      let marker =
        (* Keep the marker column even with icons Off; labels and selection stay put. *)
        if Appearance.Icons.equal icons None_ then " " else Indicator.text icons kind
      in
      sprintf
        "%s%s%s %s : %s"
        (if String.equal node.key t.selected_key then ">" else " ")
        (String.make (2 * Int.min depth 32) ' ')
        marker
        (display_label (Option.value node.instance_name ~default:"<root>"))
        (display_label node.circuit_name)))
;;

module%test Tests = struct
  let node ?parent ?instance_name key : Hierarchy.Node.t =
    { key
    ; parent
    ; instance_name
    ; circuit_name = "circuit_" ^ key
    ; input_ports = []
    ; output_ports = []
    ; metadata = []
    }
  ;;

  let tree =
    { Baseline_fixture.hierarchy with
      root = "/"
    ; nodes =
        [ node "/"
        ; node ~parent:"/" ~instance_name:"z" "/z"
        ; node ~parent:"/a" ~instance_name:"leaf" "/a/leaf"
        ; node ~parent:"/" ~instance_name:"a" "/a"
        ]
    }
  ;;

  let keys t = List.map (visible t) ~f:(fun (_, node) -> node.key)

  let%test_unit "branch, leaf and top markers preserve labels and cell positions" =
    let initial = create (evidence tree) in
    [%test_eq: string list]
      (rows initial ~height:4)
      [ ">- <root> : circuit_/"; "   + a : circuit_/a"; "   . z : circuit_/z" ];
    let expanded = move initial 1 |> toggle in
    [%test_eq: string list]
      (rows ~icons:Ascii expanded ~height:4)
      [ " - <root> : circuit_/"
      ; ">  - a : circuit_/a"
      ; "     . leaf : circuit_/a/leaf"
      ; "   . z : circuit_/z"
      ];
    let width row = Notty.I.width (Notty.I.string Notty.A.empty row) in
    List.iter [ initial; expanded; toggle initial ] ~f:(fun view ->
      let ascii = rows ~icons:Ascii view ~height:4 in
      List.iter Appearance.Icons.all ~f:(fun icons ->
        let rendered = rows ~icons view ~height:4 in
        [%test_eq: int list] (List.map rendered ~f:width) (List.map ascii ~f:width);
        List.iter2_exn rendered ascii ~f:(fun row reference ->
          [%test_eq: string]
            (snd (String.lsplit2_exn row ~on:':'))
            (snd (String.lsplit2_exn reference ~on:':'));
          [%test_eq: char] row.[0] reference.[0])));
    [%test_eq: string list]
      (rows ~icons:None_ initial ~height:4)
      [ ">  <root> : circuit_/"; "     a : circuit_/a"; "     z : circuit_/z" ];
    [%test_eq: string list]
      (rows ~icons:Unicode initial ~height:4)
      [ ">▾ <root> : circuit_/"; "   ▸ a : circuit_/a"; "   · z : circuit_/z" ];
    let top = create (evidence { tree with nodes = [ node "/" ] }) in
    List.iter Appearance.Icons.all ~f:(fun icons ->
      let marker = if Appearance.Icons.equal icons None_ then " " else Indicator.text icons Top in
      [%test_eq: string list]
        (rows ~icons top ~height:1)
        [ ">" ^ marker ^ " <root> : circuit_/" ];
      [%test_eq: string list] (rows ~icons (toggle top) ~height:1) (rows ~icons top ~height:1));
    [%test_eq: string] (selected_key initial) "/"
  ;;

  let%test_unit "shared evidence and immutable independent navigation" =
    let shared = evidence tree in
    let first = create shared in
    let second = create shared in
    let moved = move first 1 |> toggle |> Fn.flip move 1 in
    [%test_eq: string list] (keys first) [ "/"; "/a"; "/z" ];
    [%test_eq: string list] (keys moved) [ "/"; "/a"; "/a/leaf"; "/z" ];
    [%test_eq: string] (selected_key moved) "/a/leaf";
    [%test_eq: string] (selected_key second) "/";
    assert (phys_equal (hierarchy first) (hierarchy moved));
    assert (phys_equal (hierarchy first) (hierarchy second))
  ;;

  let%test_unit "collapse keeps selection visible; select reopens ancestors" =
    let original = create (evidence tree) in
    let leaf = select original "/a/leaf" in
    let branch = move leaf (-1) |> toggle in
    [%test_eq: string list] (keys branch) [ "/"; "/a"; "/z" ];
    [%test_eq: string] (selected_key branch) "/a";
    let collapsed = move branch (-1) |> toggle in
    [%test_eq: string list] (keys collapsed) [ "/" ];
    let reopened = select collapsed "/a/leaf" in
    [%test_eq: string list] (keys reopened) [ "/"; "/a"; "/a/leaf"; "/z" ];
    [%test_eq: string] (selected_key reopened) "/a/leaf";
    [%test_eq: string] (selected_key (move reopened Int.max_value)) "/z";
    [%test_eq: string] (selected_key (move reopened Int.min_value)) "/"
  ;;

  let%test_unit "viewport stays bounded and contains selection at every size" =
    let initial = create (evidence tree) |> Fn.flip select "/a/leaf" in
    List.iter (keys initial) ~f:(fun key ->
      let view = select initial key in
      List.iter [ -1; 0; 1; 2; 3; 4; 20; Int.max_value ] ~f:(fun height ->
        let rendered = rows view ~height in
        assert (List.length rendered <= Int.max 0 height);
        if height > 0
        then (
          [%test_eq: int] (List.count rendered ~f:(String.is_prefix ~prefix:">")) 1;
          assert (
            List.exists rendered ~f:(fun row ->
              String.is_prefix row ~prefix:">"
              && String.is_substring row ~substring:("circuit_" ^ key))))));
    [%test_eq: string] (selected_key initial) "/a/leaf"
  ;;

  let%test_unit "keys and generations remain scoped to the loaded artifact" =
    let old = create (evidence tree) |> Fn.flip select "/a/leaf" in
    let newer_tree =
      { tree with
        artifact = Artifact_id.of_string "new-artifact"
      ; generating_job = Job_id.of_string "new-generation"
      ; nodes = [ node "/"; node ~parent:"/" ~instance_name:"a" "/a" ]
      }
    in
    let newer = create (evidence newer_tree) in
    [%test_eq: string] (selected_key (select newer (selected_key old))) "/";
    [%test_eq: string] (selected_key old) "/a/leaf";
    [%test_eq: Hierarchy.t] (hierarchy old) tree;
    [%test_eq: Hierarchy.t] (hierarchy newer) newer_tree;
    [%test_eq: string] (selected_key (select old "unknown")) "/a/leaf"
  ;;

  let%test_unit "provider-sized tree keeps last selection in a small viewport" =
    let children =
      List.init 9_999 ~f:(fun index ->
        let name = sprintf "child-%05d" index in
        node ~parent:"/" ~instance_name:name ("/" ^ name))
    in
    let view = create (evidence { tree with nodes = node "/" :: children }) in
    let last = move view Int.max_value in
    [%test_eq: int] (List.length (visible last)) 10_000;
    [%test_eq: string] (selected_key last) "/child-09998";
    [%test_eq: int] (List.length (rows last ~height:3)) 3;
    assert (String.is_prefix (List.last_exn (rows last ~height:3)) ~prefix:">");
    [%test_eq: string] (selected_key view) "/"
  ;;

  let%test_unit "malformed typed evidence is finite and missing roots are safe" =
    let malformed =
      { tree with
        nodes =
          [ node ~parent:"/a" "/"
          ; node ~parent:"/" ~instance_name:"a" "/a"
          ; node ~parent:"/" ~instance_name:"duplicate" "/a"
          ; node ~parent:"missing" ~instance_name:"orphan" "orphan"
          ; node ~parent:"cycle" ~instance_name:"cycle" "cycle"
          ]
      }
    in
    let view = create (evidence malformed) |> Fn.flip select "/a" |> toggle in
    [%test_eq: string list] (keys view) [ "/"; "/a" ];
    [%test_eq: string] (selected_key (select view "cycle")) "/a";
    List.iter
      [ []; [ node "not-root" ] ]
      ~f:(fun nodes ->
        let empty = create (evidence { tree with nodes }) in
        assert (Option.is_none (selected_node empty));
        [%test_eq: string list] (rows (move (toggle empty) Int.max_value) ~height:4) [])
  ;;

  let%test_unit "display labels are single-line safe UTF-8 without changing evidence" =
    let unsafe = "hello\n\t\027[31m\127\194\128\226\128\174\255世界" in
    let tree = { tree with nodes = [ { (node "/") with circuit_name = unsafe } ] } in
    let view = create (evidence tree) in
    [%test_eq: string list] (rows view ~height:1) [ ">^ <root> : hello   [31m   ?世界" ];
    [%test_eq: string] (Option.value_exn (selected_node view)).circuit_name unsafe
  ;;
end
