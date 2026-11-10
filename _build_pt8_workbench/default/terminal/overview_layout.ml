(** Compatibility entry point projecting the canonical [workspaces/stock.sexp] Overview
    tree. New callers should use [Layout.compute] with their resolved definition. *)
module Shared = Hardcaml_workbench_workspaces

type t = Shared.Layout.t =
  | Grid of Hardcaml_workbench_protocol.Workspace.Geometry.t list
  | Compact

let compute ~width ~height ~kinds =
  Shared.Layout.compute Shared.Overview.definition ~width ~height ~kinds
;;
