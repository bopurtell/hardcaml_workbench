open! Core
open Hardcaml_workbench_protocol

(** Canonical complete stock config, including the default window composition. *)
let stock_config = Stock.config

let export_config () = Workspace_config.Resolved.encode stock_config

(** CLI resolver contract. Built-ins never depend on the selected user catalog. *)
let builtins key =
  match
    List.find stock_config.definitions ~f:(fun d ->
      String.equal d.Workspace_config.Definition.key key)
  with
  | Some d -> Ok d
  | None -> Or_error.error_string ("Unknown built-in workspace: " ^ key)
;;

(** Accept complete stock exports as editable input while keeping reserved identities
    immutable. To edit a stock definition, rename its key, omit preset, and use Custom. *)
let decode text =
  match Workspace_config.decode text with
  | Ok config -> Ok config
  | Error original ->
    let open Or_error.Let_syntax in
    let%bind config = Workspace_config.Resolved.decode text in
    let%bind () =
      List.fold config.definitions ~init:(Ok ()) ~f:(fun acc d ->
        let%bind () = acc in
        if Workspace_config.builtin_definition d
        then (
          let%bind stock = builtins d.key in
          if Workspace_config.Definition.equal stock d then Ok () else Error original)
        else Ok ())
    in
    let config =
      { config with
        definitions =
          List.filter config.definitions ~f:(fun d ->
            not (Workspace_config.builtin_definition d))
      }
    in
    let%map () = Workspace_config.validate config in
    config
;;

let resolve config = Workspace_config.resolve config ~builtins
let custom_example () = decode Custom_data.text
let all = List.map stock_config.definitions ~f:Definition.of_spec
let find id = List.find all ~f:(fun d -> String.equal d.Definition.id id)

let starters =
  List.concat_map stock_config.windows ~f:(fun window ->
    List.map window.Workspace_config.Window.workspaces ~f:(fun instance ->
      match instance.Workspace_config.Instance.definition with
      | Builtin key -> find key |> Option.value_exn
      | Custom _ -> failwith "Stock startup instances must reference built-ins"))
;;

(** Safe after Get, after import, on reconnect, and concurrently from multiple clients.
    The service atomically persists both defaults and their completion marker. *)
let bootstrap =
  Hardcaml_workbench_protocol.Workspace.Operation.Bootstrap
    (List.map starters ~f:(fun d ->
       (builtins d.Definition.id |> Or_error.ok_exn).template))
;;

(** Fresh sessions consume the actual shipped window composition, rather than reducing it
    to Bootstrap's two legacy placeholder arrangements. Bootstrap is retained only for
    unfinished legacy sessions whose live state must be preserved. *)
let startup_operation ?selected (snapshot : Workspace.Snapshot.t) =
  if snapshot.configuration_pending
  then
    Some
      (Workspace.Operation.Initialize_config (Option.value selected ~default:stock_config))
  else if not snapshot.defaults_initialized
  then Some bootstrap
  else None
;;

let for_arrangement (w : Hardcaml_workbench_protocol.Workspace.Arrangement.t) =
  Option.bind w.preset ~f:find
;;

(** Machine-readable S-expression; the Python seeder consumes this directly. *)
let export_sexp () = [%sexp (all : Definition.t list)]
