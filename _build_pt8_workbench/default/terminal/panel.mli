open! Core
open Bonsai_term

(** One geometry calculation for rendering and input/paging. Padding axes are independent;
    short panels retain one content row before padding or borders. *)
type geometry =
  { border : int
  ; inner_width : int
  ; inner_height : int
  ; horizontal_padding : int
  ; vertical_padding : int
  ; content_width : int
  ; content_height : int
  }

val framed : Appearance.t -> width:int -> height:int -> bool

val geometry
  :  framed:bool
  -> width:int
  -> height:int
  -> horizontal_padding:int
  -> vertical_padding:int
  -> geometry

(** [title] is already visibility-filtered by the caller. It may contain an independently
    visible pin badge even when the heading is hidden. *)
val render
  :  Appearance.t
  -> attrs:Attr.t list
  -> title:View.t
  -> geometry:geometry
  -> width:int
  -> height:int
  -> View.t
  -> View.t
