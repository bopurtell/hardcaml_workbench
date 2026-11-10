open! Core
open Hardcaml_workbench_protocol

let version = 1
let max_stdout_bytes = 1024 * 1024
let describe_capability = "describe"
let generate_rtl_capability = "generate-rtl"
let generate_rtl_hierarchy_capability = "generate-rtl-hierarchy"
let max_outputs = 16
let max_hierarchy_nodes = 10_000
let max_hierarchy_depth = 256
let max_hierarchy_entries_per_node = 4_096
let max_hierarchy_string_bytes = 4_096
let hierarchy_namespace = "hardcaml"
let hierarchy_name = "elaboration-hierarchy"
let hierarchy_media = "application/x-hardcaml-workbench-hierarchy-sexp"

module Clock = struct
  type t =
    { name : string
    ; period_ns : float option
    ; description : string option
    }
  [@@deriving compare, equal, sexp]
end

module Fact = struct
  type t =
    { namespace : string
    ; name : string
    ; value : string
    ; display : string option
    }
  [@@deriving compare, equal, sexp]
end

module Target = struct
  type t =
    { key : string
    ; name : string
    ; top : string
    ; backend : string
    ; clocks : Clock.t list
    ; facts : Fact.t list
    }
  [@@deriving compare, equal, sexp]
end

module Configuration = struct
  type t =
    { key : string
    ; target : string
    ; name : string
    ; description : string option
    }
  [@@deriving compare, equal, sexp]
end

module Describe_response = struct
  type t =
    { protocol_version : int
    ; capabilities : string list
    ; targets : Target.t list
    ; configurations : Configuration.t list
    }
  [@@deriving compare, equal, sexp]
end

module Tool = struct
  type t =
    { name : string
    ; version : string option
    }
  [@@deriving compare, equal, sexp]
end

module Backend_ref = struct
  type t =
    { backend : string
    ; id : string
    ; label : string option
    }
  [@@deriving compare, equal, sexp]
end

module Run_ref = struct
  type t =
    { backend : string
    ; id : string
    ; build : Backend_ref.t option
    ; label : string option
    }
  [@@deriving compare, equal, sexp]
end

module Output = struct
  type t =
    { path : string
    ; namespace : string
    ; name : string
    ; role : Artifact.Role.t
    ; media : string option
    ; display_name : string
    ; description : string option
    }
  [@@deriving compare, equal, sexp]
end

module Generate_rtl_response = struct
  type t =
    { protocol_version : int
    ; target : string
    ; configuration : string
    ; outputs : Output.t list
    ; tools : Tool.t list
    ; build : Backend_ref.t option
    ; run : Run_ref.t option
    }
  [@@deriving compare, equal, sexp]
end

module Hierarchy_response = struct
  type t =
    { protocol_version : int
    ; target : string
    ; configuration : string
    ; root : string
    ; nodes : Hierarchy.Node.t list
    }
  [@@deriving compare, equal, sexp]
end

let valid_key value =
  let valid_tail = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
    | _ -> false
  in
  match String.to_list value with
  | ('A' .. 'Z' | 'a' .. 'z' | '0' .. '9') :: tail -> List.for_all tail ~f:valid_tail
  | [] | _ -> false
;;

let nonempty field value =
  if String.is_empty value then Error (field ^ " must not be empty") else Ok ()
;;

let unique_keys kind values ~key =
  let seen = Hash_set.create (module String) in
  List.fold_result values ~init:() ~f:(fun () value ->
    let value = key value in
    if not (valid_key value)
    then Error (sprintf "%s key %S is invalid" kind value)
    else if Hash_set.mem seen value
    then Error (sprintf "%s key %S is duplicated" kind value)
    else (
      Hash_set.add seen value;
      Ok ()))
;;

let validate (response : Describe_response.t) =
  if response.protocol_version <> version
  then
    Error
      (sprintf
         "unsupported driver protocol version %d (supported: 1)"
         response.protocol_version)
  else if not (List.mem response.capabilities describe_capability ~equal:String.equal)
  then Error "driver does not advertise required capability describe"
  else (
    let%bind.Result () =
      unique_keys "target" response.targets ~key:(fun target -> target.key)
    in
    let%bind.Result () =
      unique_keys "configuration" response.configurations ~key:(fun config -> config.key)
    in
    let target_keys =
      String.Set.of_list (List.map response.targets ~f:(fun target -> target.key))
    in
    let%bind.Result () =
      List.fold_result response.targets ~init:() ~f:(fun () target ->
        let%bind.Result () = nonempty "target.name" target.name in
        let%bind.Result () = nonempty "target.top" target.top in
        let%bind.Result () = nonempty "target.backend" target.backend in
        Ok ())
    in
    let%map.Result () =
      List.fold_result response.configurations ~init:() ~f:(fun () config ->
        let%bind.Result () = nonempty "configuration.name" config.name in
        if Set.mem target_keys config.target
        then Ok ()
        else
          Error
            (sprintf
               "configuration %S refers to unknown target key %S"
               config.key
               config.target))
    in
    response)
;;

let parse output =
  if String.length output > max_stdout_bytes
  then Error (sprintf "driver stdout exceeded %d bytes" max_stdout_bytes)
  else (
    match
      Or_error.try_with (fun () -> Sexp.of_string output |> Describe_response.t_of_sexp)
    with
    | Error error ->
      Error ("malformed driver describe response: " ^ Error.to_string_hum error)
    | Ok response -> validate response)
;;

let valid_relative_path path =
  (not (String.is_empty path))
  && (not (Filename.is_absolute path))
  && String.split path ~on:'/'
     |> List.for_all ~f:(fun component ->
       not
         (String.is_empty component
          || String.equal component "."
          || String.equal component ".."))
;;

let validate_backend_ref field (reference : Backend_ref.t) =
  let%bind.Result () = nonempty (field ^ ".backend") reference.backend in
  nonempty (field ^ ".id") reference.id
;;

let validate_generate ~target ~configuration (response : Generate_rtl_response.t) =
  if response.protocol_version <> version
  then
    Error
      (sprintf
         "unsupported driver protocol version %d (supported: 1)"
         response.protocol_version)
  else if not (String.equal response.target target)
  then Error "generate-rtl result target does not match the request"
  else if not (String.equal response.configuration configuration)
  then Error "generate-rtl result configuration does not match the request"
  else if List.is_empty response.outputs
  then Error "generate-rtl result declared no outputs"
  else if List.length response.outputs > max_outputs
  then Error (sprintf "generate-rtl result exceeded %d outputs" max_outputs)
  else (
    let seen = Hash_set.create (module String) in
    let%bind.Result () =
      List.fold_result response.outputs ~init:() ~f:(fun () output ->
        if not (valid_relative_path output.path)
        then
          Error (sprintf "output path %S is not a normalized relative path" output.path)
        else if Hash_set.mem seen output.path
        then Error (sprintf "output path %S is duplicated" output.path)
        else (
          Hash_set.add seen output.path;
          let%bind.Result () = nonempty "output.namespace" output.namespace in
          let%bind.Result () = nonempty "output.name" output.name in
          nonempty "output.display_name" output.display_name))
    in
    let%bind.Result () =
      List.fold_result response.tools ~init:() ~f:(fun () tool ->
        nonempty "tool.name" tool.name)
    in
    let%bind.Result () =
      Option.value_map response.build ~default:(Ok ()) ~f:(validate_backend_ref "build")
    in
    let%map.Result () =
      Option.value_map response.run ~default:(Ok ()) ~f:(fun run ->
        let%bind.Result () = nonempty "run.backend" run.backend in
        let%bind.Result () = nonempty "run.id" run.id in
        Option.value_map run.build ~default:(Ok ()) ~f:(validate_backend_ref "run.build"))
    in
    response)
;;

let parse_generate ~target ~configuration output =
  if String.length output > max_stdout_bytes
  then Error (sprintf "driver stdout exceeded %d bytes" max_stdout_bytes)
  else (
    match
      Or_error.try_with (fun () ->
        Sexp.of_string output |> Generate_rtl_response.t_of_sexp)
    with
    | Error error ->
      Error ("malformed driver generate-rtl response: " ^ Error.to_string_hum error)
    | Ok response -> validate_generate ~target ~configuration response)
;;

let hierarchy_output (output : Output.t) =
  String.equal output.namespace hierarchy_namespace
  && String.equal output.name hierarchy_name
  && Artifact.Role.equal output.role Report
  && Option.equal String.equal output.media (Some hierarchy_media)
;;

let hierarchy_key ~parent instance_name =
  sprintf
    "%s/%d:%s"
    (if String.equal parent "/" then "" else parent)
    (String.length instance_name)
    instance_name
;;

let validate_hierarchy_string field value =
  if String.is_empty value
  then Error (field ^ " must not be empty")
  else if String.length value > max_hierarchy_string_bytes
  then Error (sprintf "%s exceeded %d bytes" field max_hierarchy_string_bytes)
  else Ok ()
;;

let validate_named_values field values ~name =
  if List.length values > max_hierarchy_entries_per_node
  then Error (sprintf "%s exceeded %d entries" field max_hierarchy_entries_per_node)
  else (
    let seen = Hash_set.create (module String) in
    List.fold_result values ~init:() ~f:(fun () value ->
      let value_name = name value in
      let%bind.Result () = validate_hierarchy_string (field ^ ".name") value_name in
      if Hash_set.mem seen value_name
      then Error (sprintf "%s name %S is duplicated" field value_name)
      else (
        Hash_set.add seen value_name;
        Ok ())))
;;

let validate_hierarchy ~target ~configuration (response : Hierarchy_response.t) =
  if response.protocol_version <> version
  then
    Error
      (sprintf
         "unsupported hierarchy protocol version %d (supported: 1)"
         response.protocol_version)
  else if not (String.equal response.target target)
  then Error "hierarchy result target does not match the request"
  else if not (String.equal response.configuration configuration)
  then Error "hierarchy result configuration does not match the request"
  else if List.is_empty response.nodes
  then Error "hierarchy contains no nodes"
  else if List.length response.nodes > max_hierarchy_nodes
  then Error (sprintf "hierarchy exceeded %d nodes" max_hierarchy_nodes)
  else if not (String.equal response.root "/")
  then Error "hierarchy root key must be /"
  else (
    let nodes = Hashtbl.create (module String) in
    let%bind.Result () =
      List.fold_result response.nodes ~init:() ~f:(fun () (node : Hierarchy.Node.t) ->
        let%bind.Result () = validate_hierarchy_string "node.key" node.key in
        let%bind.Result () =
          validate_hierarchy_string "node.circuit_name" node.circuit_name
        in
        if Hashtbl.mem nodes node.key
        then Error (sprintf "hierarchy node key %S is duplicated" node.key)
        else (
          Hashtbl.set nodes ~key:node.key ~data:node;
          let%bind.Result () =
            if List.length node.input_ports + List.length node.output_ports
               > max_hierarchy_entries_per_node
            then
              Error
                (sprintf "node ports exceeded %d entries" max_hierarchy_entries_per_node)
            else Ok ()
          in
          let%bind.Result () =
            List.fold_result node.input_ports ~init:() ~f:(fun () port ->
              if port.Hierarchy.Port.width > 0
              then Ok ()
              else Error (sprintf "input port %S has non-positive width" port.name))
          in
          let%bind.Result () =
            validate_named_values
              "node.ports"
              (node.input_ports @ node.output_ports)
              ~name:(fun port -> port.Hierarchy.Port.name)
          in
          let%bind.Result () =
            List.fold_result node.output_ports ~init:() ~f:(fun () port ->
              if port.Hierarchy.Port.width > 0
              then Ok ()
              else Error (sprintf "output port %S has non-positive width" port.name))
          in
          let%bind.Result () =
            validate_named_values "node.metadata" node.metadata ~name:(fun metadata ->
              metadata.Hierarchy.Metadata.name)
          in
          List.fold_result node.metadata ~init:() ~f:(fun () metadata ->
            if String.length metadata.Hierarchy.Metadata.value
               > max_hierarchy_string_bytes
            then
              Error
                (sprintf
                   "node.metadata.value exceeded %d bytes"
                   max_hierarchy_string_bytes)
            else Ok ())))
    in
    let%bind.Result root =
      Hashtbl.find nodes response.root
      |> Result.of_option ~error:"declared hierarchy root does not exist"
    in
    let%bind.Result () =
      match root.parent, root.instance_name with
      | None, None -> Ok ()
      | _ -> Error "hierarchy root must have no parent or instance name"
    in
    let ancestor_state = Hashtbl.create (module String) in
    let ancestor_depth = Hashtbl.create (module String) in
    let rec check_ancestors key remaining_depth =
      if remaining_depth < 0
      then Error (sprintf "hierarchy exceeded depth %d" max_hierarchy_depth)
      else (
        match Hashtbl.find ancestor_state key with
        | Some `Visiting -> Error (sprintf "hierarchy contains a cycle at %S" key)
        | Some `Done ->
          let depth = Hashtbl.find_exn ancestor_depth key in
          if depth > remaining_depth
          then Error (sprintf "hierarchy exceeded depth %d" max_hierarchy_depth)
          else Ok depth
        | None ->
          Hashtbl.set ancestor_state ~key ~data:`Visiting;
          let%bind.Result depth =
            match Hashtbl.find nodes key with
            | None -> Ok 0
            | Some node ->
              (match node.parent with
               | None -> Ok 0
               | Some parent ->
                 Result.map (check_ancestors parent (remaining_depth - 1)) ~f:(( + ) 1))
          in
          if depth > max_hierarchy_depth
          then Error (sprintf "hierarchy exceeded depth %d" max_hierarchy_depth)
          else (
            Hashtbl.set ancestor_state ~key ~data:`Done;
            Hashtbl.set ancestor_depth ~key ~data:depth;
            Ok depth))
    in
    let%bind.Result () =
      List.fold_result response.nodes ~init:() ~f:(fun () node ->
        Result.map
          (check_ancestors node.Hierarchy.Node.key max_hierarchy_depth)
          ~f:(fun _ -> ()))
    in
    let sibling_names = Hashtbl.create (module String) in
    let%bind.Result () =
      List.fold_result response.nodes ~init:() ~f:(fun () (node : Hierarchy.Node.t) ->
        if String.equal node.key response.root
        then Ok ()
        else (
          match node.parent, node.instance_name with
          | None, _ -> Error (sprintf "non-root node %S has no parent" node.key)
          | _, None -> Error (sprintf "non-root node %S has no instance name" node.key)
          | Some parent, Some instance_name ->
            let%bind.Result () = validate_hierarchy_string "node.parent" parent in
            let%bind.Result () =
              validate_hierarchy_string "node.instance_name" instance_name
            in
            if not (Hashtbl.mem nodes parent)
            then Error (sprintf "node %S refers to unknown parent %S" node.key parent)
            else if not (String.equal node.key (hierarchy_key ~parent instance_name))
            then
              Error (sprintf "node %S does not match its encoded instance path" node.key)
            else (
              let names =
                Hashtbl.find_or_add sibling_names parent ~default:(fun () ->
                  Hash_set.create (module String))
              in
              if Hash_set.mem names instance_name
              then
                Error
                  (sprintf
                     "instance name %S is duplicated under parent %S"
                     instance_name
                     parent)
              else (
                Hash_set.add names instance_name;
                Ok ()))))
    in
    let children = Hashtbl.create (module String) in
    List.iter response.nodes ~f:(fun node ->
      Option.iter node.Hierarchy.Node.parent ~f:(fun parent ->
        Hashtbl.add_multi children ~key:parent ~data:node));
    let rec visit seen stack depth key =
      if depth > max_hierarchy_depth
      then Error (sprintf "hierarchy exceeded depth %d" max_hierarchy_depth)
      else if Set.mem stack key
      then Error (sprintf "hierarchy contains a cycle at %S" key)
      else if Set.mem seen key
      then Ok seen
      else (
        let stack = Set.add stack key in
        let seen = Set.add seen key in
        Hashtbl.find children key
        |> Option.value ~default:[]
        |> List.fold_result ~init:seen ~f:(fun seen node ->
          visit seen stack (depth + 1) node.key))
    in
    let%bind.Result seen = visit String.Set.empty String.Set.empty 0 response.root in
    if Set.length seen <> List.length response.nodes
    then Error "hierarchy contains unreachable nodes or a disconnected cycle"
    else Ok response)
;;

let parse_hierarchy ~target ~configuration output =
  if String.length output > V1.max_hierarchy_bytes
  then Error (sprintf "hierarchy sidecar exceeded %d bytes" V1.max_hierarchy_bytes)
  else (
    match
      Or_error.try_with (fun () -> Sexp.of_string output |> Hierarchy_response.t_of_sexp)
    with
    | Error error -> Error ("malformed hierarchy sidecar: " ^ Error.to_string_hum error)
    | Ok response -> validate_hierarchy ~target ~configuration response)
;;
