open! Core
open Bonsai_term

type geometry =
  { border : int
  ; inner_width : int
  ; inner_height : int
  ; horizontal_padding : int
  ; vertical_padding : int
  ; content_width : int
  ; content_height : int
  }

let box ~width ~height view =
  let width = Int.max 0 width
  and height = Int.max 0 height in
  View.crop
    ~r:(Int.max 0 (View.width view - width))
    ~b:(Int.max 0 (View.height view - height))
    view
  |> fun view -> View.zcat [ view; View.rectangle ~width ~height () ]
;;

let framed (appearance : Appearance.t) ~width ~height =
  width >= 4
  && height >= 3
  &&
  match appearance.preset with
  | Instrument | Structured | Structured_studio -> true
  | Minimal | Studio -> false
;;

let geometry ~framed ~width ~height ~horizontal_padding ~vertical_padding =
  let width = Int.max 0 width
  and height = Int.max 0 height in
  let border = if framed && width >= 4 && height >= 3 then 1 else 0 in
  let inner_width = Int.max 0 (width - (2 * border)) in
  let inner_height = Int.max 0 (height - (2 * border)) in
  let horizontal_padding =
    Int.clamp_exn horizontal_padding ~min:0 ~max:(Int.max 0 ((inner_width - 4) / 2))
  in
  let vertical_padding =
    Int.clamp_exn vertical_padding ~min:0 ~max:(Int.max 0 ((inner_height - 1) / 2))
  in
  { border
  ; inner_width
  ; inner_height
  ; horizontal_padding
  ; vertical_padding
  ; content_width = inner_width - (2 * horizontal_padding)
  ; content_height = inner_height - (2 * vertical_padding)
  }
;;

let render appearance ~attrs ~title ~geometry:g ~width ~height content =
  let content =
    box ~width:g.content_width ~height:g.content_height content
    |> View.pad
         ~l:g.horizontal_padding
         ~r:g.horizontal_padding
         ~t:g.vertical_padding
         ~b:g.vertical_padding
    |> box ~width:g.inner_width ~height:g.inner_height
  in
  if g.border = 0
  then box ~width ~height content
  else (
    let tl, tr, bl, br, horizontal, vertical =
      match appearance.Appearance.icons, appearance.preset with
      | Unicode, Instrument -> "╭", "╮", "╰", "╯", "─", "│"
      | Unicode, _ -> "┌", "┐", "└", "┘", "─", "│"
      | (None_ | Ascii), _ -> "+", "+", "+", "+", "-", "|"
    in
    let text = View.text ~attrs in
    let rule n =
      text (String.concat (List.init (Int.max 0 n) ~f:(fun _ -> horizontal)))
    in
    let title =
      if View.width title = 0
      then View.none
      else
        View.hcat [ text " "; title; text " " ]
        |> fun title -> View.crop ~r:(Int.max 0 (View.width title - g.inner_width)) title
    in
    let side = View.vcat (List.init g.inner_height ~f:(fun _ -> text vertical)) in
    View.vcat
      [ View.hcat [ text tl; title; rule (g.inner_width - View.width title); text tr ]
      ; View.hcat [ side; content; side ]
      ; View.hcat [ text bl; rule g.inner_width; text br ]
      ]
    |> box ~width ~height)
;;

let%test_unit "finite geometry retains short frames and independent padding" =
  for width = 0 to 30 do
    for height = 0 to 12 do
      let g =
        geometry ~framed:true ~width ~height ~horizontal_padding:2 ~vertical_padding:0
      in
      let image =
        render
          Appearance.default
          ~attrs:[]
          ~title:(View.text "Title 界")
          ~geometry:g
          ~width
          ~height
          (View.text "body")
      in
      if (height > 0 && View.width image <> width) || View.height image <> height
      then
        failwithf
          "panel requested %dx%d got %dx%d"
          width
          height
          (View.width image)
          (View.height image)
          ();
      assert (g.content_height = Int.max 0 (height - (2 * g.border)));
      if width >= 4 && height >= 3 then assert (g.border = 1 && g.content_height >= 1)
    done
  done
;;

let%test_unit "short border title reclaims a row and preserves skin fallback" =
  let appearance = { Appearance.default with preset = Instrument; icons = Unicode } in
  let g =
    geometry ~framed:true ~width:24 ~height:3 ~horizontal_padding:1 ~vertical_padding:0
  in
  let render appearance title =
    let view =
      render
        appearance
        ~attrs:[]
        ~title:(View.text title)
        ~geometry:g
        ~width:24
        ~height:3
        (View.text "only content row")
    in
    let buffer = Buffer.create 100 in
    Notty.Render.to_buffer
      buffer
      Notty.Cap.dumb
      (0, 0)
      (24, 3)
      (View.Private.notty_image view);
    Buffer.contents buffer
  in
  let unicode = render appearance "session" in
  assert (String.is_substring unicode ~substring:"╭ session ─");
  assert (String.is_substring unicode ~substring:"│ only content row");
  assert (String.is_substring unicode ~substring:"╰─");
  let ascii = render { appearance with icons = Ascii } "PIN exact/run" in
  assert (String.is_substring ascii ~substring:"+ PIN exact/run -");
  assert (String.is_substring ascii ~substring:"| only content row");
  assert (not (String.is_substring (render appearance "") ~substring:"Session"))
;;

let%test_unit "rounded labels are exact and retain evidence identity" =
  let g =
    geometry ~framed:true ~width:32 ~height:3 ~horizontal_padding:0 ~vertical_padding:0
  in
  let image =
    render
      Appearance.default
      ~attrs:[]
      ~title:(View.text "timing PIN Run-AbC")
      ~geometry:g
      ~width:32
      ~height:3
      View.none
  in
  let buffer = Buffer.create 200 in
  Notty.Render.to_buffer
    buffer
    Notty.Cap.dumb
    (0, 0)
    (32, 3)
    (View.Private.notty_image image);
  assert (
    String.is_prefix
      (Buffer.contents buffer)
      ~prefix:
        ("╭ timing PIN Run-AbC " ^ String.concat (List.init 10 ~f:(fun _ -> "─")) ^ "╮"))
;;
