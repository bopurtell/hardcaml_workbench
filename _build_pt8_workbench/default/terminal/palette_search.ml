open! Core

(* Adapted from Ches palette/fuzzy.ml (Wayne's Ches checkout): scalar decoding, fzf-style
   boundary/consecutive bonuses, gap costs, token-AND fields and stable ranking. Kept pure
   and independent of the Ches editor/runtime. Positions are UTF-8 byte offsets at
   codepoint boundaries, never terminal columns. ASCII case folds; other Unicode scalars
   compare exactly. *)
type field =
  { text : string
  ; weight : int
  }

type 'a result =
  { item : 'a
  ; score : int
  ; positions : (string * int list) list
  }

let decode text =
  let rec loop pos acc =
    if pos >= String.length text
    then Array.of_list_rev acc
    else (
      let d = Stdlib.String.get_utf_8_uchar text pos in
      loop
        (pos + Stdlib.Uchar.utf_decode_length d)
        ((Uchar.to_scalar (Stdlib.Uchar.utf_decode_uchar d), pos) :: acc))
  in
  loop 0 []
;;

let fold c = if c >= 65 && c <= 90 then c + 32 else c
let lower c = c >= 97 && c <= 122
let upper c = c >= 65 && c <= 90
let digit c = c >= 48 && c <= 57
let separator c = c < 128 && not (lower c || upper c || digit c)

let bonus previous current =
  if separator current
  then 0
  else if separator previous
  then 8
  else if (lower previous && upper current)
          || ((lower previous || upper previous || previous >= 128) && digit current)
  then 7
  else 0
;;

let align token text =
  let field = decode text in
  let m = Array.length token
  and n = Array.length field in
  if m = 0 || m > n
  then None
  else (
    let impossible = Int.min_value in
    let scores = Array.make_matrix ~dimx:m ~dimy:n impossible in
    let parents = Array.make_matrix ~dimx:m ~dimy:n (-1) in
    let bonuses =
      Array.mapi field ~f:(fun j (c, _) ->
        bonus (if j = 0 then 32 else fst field.(j - 1)) c)
    in
    for j = 0 to n - 1 do
      if token.(0) = fold (fst field.(j)) then scores.(0).(j) <- 16 + (2 * bonuses.(j))
    done;
    for i = 1 to m - 1 do
      let gap = ref impossible
      and parent = ref (-1) in
      for j = i to n - 1 do
        if j >= 2
        then (
          if !gap <> impossible then decr gap;
          if scores.(i - 1).(j - 2) <> impossible && scores.(i - 1).(j - 2) - 3 > !gap
          then (
            gap := scores.(i - 1).(j - 2) - 3;
            parent := j - 2));
        if token.(i) = fold (fst field.(j))
        then (
          let adjacent = scores.(i - 1).(j - 1) in
          let consecutive = if adjacent = impossible then impossible else adjacent + 4 in
          let best, from =
            if consecutive >= !gap then consecutive, j - 1 else !gap, !parent
          in
          if best <> impossible
          then (
            scores.(i).(j) <- best + 16 + bonuses.(j);
            parents.(i).(j) <- from))
      done
    done;
    let endpoint =
      Array.foldi
        scores.(m - 1)
        ~init:None
        ~f:(fun j best score ->
          if score = impossible
          then best
          else (
            match best with
            | Some k when scores.(m - 1).(k) >= score -> best
            | _ -> Some j))
    in
    Option.bind endpoint ~f:(fun j ->
      let score = scores.(m - 1).(j) + if m = n then 32 else 0 in
      let rec trace i j acc =
        let acc = snd field.(j) :: acc in
        if i = 0 then acc else trace (i - 1) parents.(i).(j) acc
      in
      Option.some_if
        (score * 100 >= ((16 * m) + 16 + (4 * (m - 1))) * 50)
        (score, trace (m - 1) j [])))
;;

(* Prefer action-first phrases and consecutive word prefixes over incidental token matches
   deep in metadata. Fuzzy matching and its byte-offset highlights remain available
   whenever a phrase does not match. This is independent of command IDs. *)
let prefix_bonus tokens text =
  let scalars = Array.map (decode text) ~f:(fun (c, _) -> fold c) in
  let words =
    Array.to_list scalars
    |> List.group ~break:(fun a b -> Bool.(separator a <> separator b))
    |> List.filter ~f:(fun word -> not (separator (List.hd_exn word)))
    |> List.map ~f:Array.of_list
  in
  let prefix token word =
    Array.length token <= Array.length word
    && Array.for_alli token ~f:(fun i c -> c = word.(i))
  in
  let rec leading tokens words =
    match tokens, words with
    | [], _ -> true
    | token :: tokens, word :: words when prefix token word -> leading tokens words
    | _ -> false
  in
  if List.is_empty tokens || not (leading tokens words)
  then 0
  else (
    let phrase =
      List.map tokens ~f:Array.to_list
      |> List.intersperse ~sep:[ Char.to_int ' ' ]
      |> List.concat
      |> Array.of_list
    in
    200 + if prefix phrase scalars then 600 else 0)
;;

let rank ~query candidates =
  let tokens =
    String.split_on_chars query ~on:[ ' '; '\t'; '\r'; '\n'; '\011'; '\012' ]
    |> List.filter ~f:(Fn.non String.is_empty)
    |> List.map ~f:(fun s -> Array.map (decode s) ~f:(fun (c, _) -> fold c))
  in
  List.filter_map candidates ~f:(fun (item, fields) ->
    List.fold_until
      tokens
      ~init:(0, [])
      ~finish:(fun (score, positions) ->
        let bonus =
          List.fold fields ~init:0 ~f:(fun best field ->
            Int.max best (prefix_bonus tokens field.text * field.weight / 100))
        in
        Some { item; score = score + bonus; positions })
      ~f:(fun (total, positions) token ->
        let best =
          List.fold fields ~init:None ~f:(fun best field ->
            match align token field.text with
            | None -> best
            | Some (raw, offsets) ->
              (* Small, capped specificity cost breaks otherwise equal phrase matches in
                 favor of concise actions, without suppressing fuzzy/alias matches. *)
              let score =
                (raw * field.weight / 100)
                - Int.min 12 (Array.length (decode field.text) / 16)
              in
              (match best with
               | Some (s, _, _) when s >= score -> best
               | _ -> Some (score, field.text, offsets)))
        in
        match best with
        | None -> Stop None
        | Some (score, text, offsets) ->
          Continue (total + score, (text, offsets) :: positions)))
  |> List.stable_sort ~compare:(fun a b -> Int.compare b.score a.score)
;;

let positions result text =
  List.concat_map result.positions ~f:(fun (field, offsets) ->
    if String.equal field text then offsets else [])
  |> List.dedup_and_sort ~compare:Int.compare
;;

(* Adapted from Ches screen/picker_text.ml: emit complete decoded codepoints. *)
let spans text ~positions =
  let positions = Int.Set.of_list positions in
  Array.to_list (decode text)
  |> List.map ~f:(fun (scalar, offset) ->
    Set.mem positions offset, Uchar.Utf8.to_string (Uchar.of_scalar_exn scalar))
;;

let%test_unit "rank subsequences, word AND, aliases, stable ties and Unicode offsets" =
  let field text = { text; weight = 100 } in
  let candidates =
    [ "loose", [ field "Finalization attempt reconnect" ]
    ; "exact", [ field "Reconnect finalization" ]
    ; "alias", [ field "Inspect evidence"; field "reconnect" ]
    ]
  in
  let ranked = rank ~query:"rc fn" candidates in
  assert (List.exists ranked ~f:(fun r -> String.equal r.item "exact"));
  assert (
    String.equal
      (List.hd_exn
         (rank
            ~query:"run"
            [ "long", [ field "Run selector" ]; "exact", [ field "Run" ] ]))
        .item
      "exact");
  assert (
    List.exists (rank ~query:"reconnect" candidates) ~f:(fun r ->
      String.equal r.item "alias"));
  assert (
    List.equal
      String.equal
      (List.map (rank ~query:"" candidates) ~f:(fun r -> r.item))
      [ "loose"; "exact"; "alias" ]);
  let result = List.hd_exn (rank ~query:"界é" [ (), [ field "界xé" ] ]) in
  assert (List.equal Int.equal (positions result "界xé") [ 0; 4 ]);
  assert (
    List.equal
      (fun (a, x) (b, y) -> Bool.equal a b && String.equal x y)
      (spans "界xé" ~positions:[ 0; 4 ])
      [ true, "界"; false, "x"; true, "é" ]);
  assert (
    List.equal
      String.equal
      (List.map
         (rank ~query:"same" [ "a", [ field "same" ]; "b", [ field "same" ] ])
         ~f:(fun r -> r.item))
      [ "a"; "b" ])
;;
