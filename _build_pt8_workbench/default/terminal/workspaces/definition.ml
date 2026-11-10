open! Core
open Hardcaml_workbench_protocol

type t =
  { id : string
  ; name : string
  ; tiles : Common.tile list
  ; layout : Common.tree
  }
[@@deriving sexp]

let specs t = List.map t.tiles ~f:(fun tile -> tile.Common.kind, tile.geometry)

let template t : Workspace_template.t =
  { version = Workspace_template.version
  ; name = t.name
  ; preset = Some t.id
  ; views =
      List.map t.tiles ~f:(fun tile ->
        let g = tile.Common.geometry in
        { Workspace_template.View.kind = tile.kind
        ; hidden = false
        ; geometry = { x = g.x; y = g.y; width = g.width; height = g.height }
        })
  }
;;

let apply t ~workspace =
  Workspace.Mutation.Apply_preset { workspace; preset = t.id; tiles = specs t }
;;

let reset t ~workspace =
  Workspace.Mutation.Reset_arrangement { workspace; preset = t.id; tiles = specs t }
;;

let restore t ~workspace =
  Workspace.Mutation.Restore_default_layout { workspace; preset = t.id; tiles = specs t }
;;

let presentation t ~kind =
  List.find_map t.tiles ~f:(fun tile ->
    if String.equal kind tile.Common.kind then Some tile.presentation else None)
;;

(** Compatibility projection only. The authoring definition is the source of truth; keys
    become leaf labels here, so the renderer can address duplicate kinds. *)
let rec tree_of_spec : Workspace_config.Tree.t -> Common.tree = function
  | Leaf { tile; min_width; min_height; weight } ->
    Leaf { kind = tile; min_width; min_height; weight }
  | Stack ts -> Stack (List.map ts ~f:tree_of_spec)
  | Columns ts -> Columns (List.map ts ~f:tree_of_spec)
  | Weighted_columns ts ->
    Weighted_columns (List.map ts ~f:(fun (w, t) -> w, tree_of_spec t))
  | Narrow t -> Narrow (tree_of_spec t)
;;

let of_spec (d : Workspace_config.Definition.t) =
  Workspace_config.validate_definition d |> Or_error.ok_exn;
  { id = d.key
  ; name = d.template.name
  ; tiles =
      List.map2_exn d.template.views d.tiles ~f:(fun view tile ->
        let g = view.Workspace_template.View.geometry in
        { Common.kind = view.kind
        ; geometry =
            { Workspace.Geometry.x = g.x; y = g.y; width = g.width; height = g.height }
        ; presentation =
            Option.value
              tile.Workspace_config.Tile.presentation
              ~default:Common.inherit_presentation
        })
  ; layout = Option.value_map d.layout ~default:(Common.Stack []) ~f:tree_of_spec
  }
;;

let rec leaf_min_height tree ~key =
  match tree with
  | Common.Leaf { kind; min_height; _ } ->
    if String.equal kind key then Some min_height else None
  | Stack trees | Columns trees -> List.find_map trees ~f:(leaf_min_height ~key)
  | Weighted_columns trees ->
    List.find_map trees ~f:(fun (_, tree) -> leaf_min_height tree ~key)
  | Narrow tree -> leaf_min_height tree ~key
;;
