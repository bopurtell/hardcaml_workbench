open! Core
open Hardcaml_workbench_protocol

(** Embedded by dune from the shipped, editable spec; no runtime path dependency. *)
let config = Workspace_config.Resolved.decode Stock_data.text |> Or_error.ok_exn

let find key =
  List.find config.definitions ~f:(fun d ->
    String.equal d.Workspace_config.Definition.key key)
  |> Option.value_exn
;;
