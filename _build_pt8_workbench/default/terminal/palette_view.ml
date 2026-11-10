open! Core
open Bonsai_term

type bounds =
  { x : int
  ; y : int
  ; width : int
  ; height : int
  }

(* Adapted from Ches screen/floating.ml: optional margins on each axis, centered within
   the actual viewport. Tiny terminals use every available cell. *)
let bounds ~width ~height =
  let axis extent preferred minimum =
    let extent = Int.max 0 extent in
    let available = if extent >= minimum + 2 then extent - 2 else extent in
    let size = Int.min preferred available in
    (extent - size) / 2, size
  in
  let x, width = axis width 88 24
  and y, height = axis height 20 6 in
  { x; y; width; height }
;;

let box ~width ~height view =
  View.crop
    ~r:(Int.max 0 (View.width view - width))
    ~b:(Int.max 0 (View.height view - height))
    view
  |> fun view -> View.zcat [ view; View.rectangle ~width ~height () ]
;;

(* Crop the image by terminal cells; no UTF-8 byte truncation, even for wide
   glyphs/combining marks. Query tails remain visible when entering long paths. *)
let query ?prompt_attrs ?caret_attrs ?(caret = "▏") ~attrs ~width text =
  let prompt_attrs = Option.value prompt_attrs ~default:attrs in
  let caret_attrs = Option.value caret_attrs ~default:prompt_attrs in
  let prompt = View.text ~attrs:prompt_attrs "> " in
  let view = View.text ~attrs text in
  let caret = View.text ~attrs:caret_attrs caret in
  let prompt = if width < 3 then View.none else prompt in
  let room = Int.max 0 (width - View.width prompt - 1) in
  View.hcat [ prompt; View.crop ~l:(Int.max 0 (View.width view - room)) view; caret ]
  |> box ~width ~height:1
;;

let matched ~attrs ~match_attrs text positions =
  Palette_search.spans text ~positions
  |> List.map ~f:(fun (matched, text) ->
    View.text ~attrs:(if matched then match_attrs else attrs) text)
  |> View.hcat
;;

let result_row
  ?marker_attrs
  ~attrs
  ~match_attrs
  ~width
  ~selected
  (result : Workspace_host.command Palette_search.result)
  =
  let command = result.item in
  let title =
    matched
      ~attrs
      ~match_attrs
      command.title
      (Palette_search.positions result command.title)
  in
  (* Expose whichever non-title fields actually matched. Alias-only matches must be
     discoverable rather than unexplained entries with no highlighted text. *)
  let fields =
    [ command.aliases; command.id ]
    |> List.filter ~f:(fun text ->
      not (List.is_empty (Palette_search.positions result text)))
  in
  let extra =
    List.map fields ~f:(fun text ->
      let positions = Palette_search.positions result text in
      let first = List.hd_exn positions in
      let prefix = String.prefix text first |> View.text |> View.width in
      let view = matched ~attrs ~match_attrs text positions in
      View.hcat [ View.text ~attrs " · "; View.crop ~l:(Int.max 0 (prefix - 3)) view ])
    |> View.hcat
  in
  let title =
    if List.is_empty fields
    then title
    else
      box
        ~width:(Int.min (View.width title) (Int.max 0 ((width - 5) / 2)))
        ~height:1
        title
  in
  View.hcat
    ([ View.text
         ~attrs:(Option.value marker_attrs ~default:attrs)
         (if selected then "> " else "  ")
     ; title
     ]
     @ [ extra ]
     @ Option.to_list
         (Option.map command.unavailable ~f:(fun reason ->
            View.text ~attrs (" [" ^ reason ^ "]"))))
  |> box ~width ~height:1
;;

let overlay ~background ~panel bounds =
  View.zcat [ View.pad ~l:bounds.x ~t:bounds.y panel; background ]
;;

let%test_unit "centered bounded overlay leaves exact background outside its bounds" =
  List.iter
    [ 0, 0; 1, 1; 12, 4; 80, 24; 120, 40; 200, 60 ]
    ~f:(fun (width, height) ->
      let b = bounds ~width ~height in
      assert (b.x >= 0 && b.y >= 0 && b.x + b.width <= width && b.y + b.height <= height);
      assert (Int.abs ((2 * b.x) + b.width - width) <= 1);
      assert (Int.abs ((2 * b.y) + b.height - height) <= 1));
  let b = bounds ~width:120 ~height:40 in
  let background =
    View.vcat (List.init 40 ~f:(fun _ -> View.text (String.make 120 'X')))
  in
  let panel =
    View.vcat (List.init b.height ~f:(fun _ -> View.text (String.make b.width 'P')))
  in
  let composed = overlay ~background ~panel b in
  let render image =
    let buffer = Buffer.create 5000 in
    Notty.Render.to_buffer
      buffer
      Notty.Cap.dumb
      (0, 0)
      (120, 40)
      (View.Private.notty_image image);
    Buffer.contents buffer
  in
  assert (
    String.equal (render (View.crop ~b:39 composed)) (render (View.crop ~b:39 background)));
  assert (String.is_substring (render composed) ~substring:(String.make b.width 'P'))
;;

let%test_unit "alias-only row reveals matching text and clips Unicode by display cells" =
  let command : Workspace_host.command =
    { id = "inspect"
    ; title = "Inspect a very long finalization evidence title 界é"
    ; aliases = "some descriptive keywords reconnect 界é"
    ; action = Toggle_chrome
    ; unavailable = None
    }
  in
  let result =
    List.hd_exn
      (Palette_search.rank
         ~query:"reconnect"
         [ ( command
           , [ { text = command.title; weight = 100 }
             ; { text = command.aliases; weight = 85 }
             ] )
         ])
  in
  let row =
    result_row ~attrs:[] ~match_attrs:[ Attr.underline ] ~width:40 ~selected:true result
  in
  let buffer = Buffer.create 100 in
  Notty.Render.to_buffer
    buffer
    Notty.Cap.dumb
    (0, 0)
    (40, 1)
    (View.Private.notty_image row);
  assert (String.is_substring (Buffer.contents buffer) ~substring:"reconnect");
  assert (View.width row = 40 && View.height row = 1);
  List.iter [ 0; 1; 2; 3; 5; 10 ] ~f:(fun width ->
    let row = query ~attrs:[] ~width "界é long input 界é" in
    assert (View.width row = width && View.height row = 1))
;;
