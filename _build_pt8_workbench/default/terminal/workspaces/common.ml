open! Core
open Hardcaml_workbench_protocol

(** Sparse, terminal-independent presentation defaults. [None] inherits app policy. These
    never create providers, change binding, or carry backend evidence. *)
type presentation = Workspace_config.Presentation.t =
  { title : bool option
  ; binding_badge : string option
  ; run_reference : bool option
  ; freshness : bool option
  ; hints : bool option
  ; frame : bool option
  ; padding : int option
  ; visible_rows : int option
  ; compact_summary : bool option [@sexp.default None]
  ; horizontal_stages : bool option [@sexp.default None]
  ; string_compression : bool option [@sexp.default None]
  ; decimal_places : int option [@sexp.default None]
  }
[@@deriving sexp]

type tile =
  { kind : string
  ; geometry : Workspace.Geometry.t
  ; presentation : presentation
  }
[@@deriving sexp]

let inherit_presentation = Workspace_config.Presentation.inherit_defaults

let tile ?(width = 80) ?(height = 10) ?(presentation = inherit_presentation) kind =
  { kind; geometry = { Workspace.Geometry.x = 0; y = 0; width; height }; presentation }
;;

(** Renderer projection of the shared slicing tree. Leaf labels are authoring keys for
    configured workspaces, kinds for legacy arrangements. Stock policy lives exclusively
    in [stock.sexp]; remaining duplicate/custom tiles are placed as extras. *)
type tree =
  | Leaf of
      { kind : string
      ; min_width : int
      ; min_height : int
      ; weight : int
      }
  | Stack of tree list
  | Columns of tree list
  | Weighted_columns of (int * tree) list
  | Narrow of tree
[@@deriving sexp]
