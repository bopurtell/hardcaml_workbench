open! Core
open Hardcaml_workbench_protocol

module Invocation = struct
  type t =
    { executable : string
    ; argv : string list
    ; cwd : string
    ; environment : V1.Environment_selection.t
    }
  [@@deriving compare, equal, sexp]
end

let command_prefix = function
  | V1.Environment_selection.Inherit_daemon -> []
  | Opam_switch switch -> [ "opam"; "exec"; "--switch=" ^ switch; "--set-switch"; "--" ]
;;

let environment_summary selection ~dune_version : V1.Environment_summary.t =
  let provenance =
    match selection with
    | V1.Environment_selection.Inherit_daemon -> "daemon process"
    | Opam_switch switch -> "opam switch " ^ switch
  in
  { selection; provenance; dune_version; command_prefix = command_prefix selection }
;;

let invocation ~root environment dune_arguments =
  match command_prefix environment with
  | [] ->
    { Invocation.executable = "dune"
    ; argv = "dune" :: dune_arguments
    ; cwd = root
    ; environment
    }
  | executable :: prefix_arguments ->
    { Invocation.executable
    ; argv = (executable :: prefix_arguments) @ ("dune" :: dune_arguments)
    ; cwd = root
    ; environment
    }
;;

let probe_invocation ~root environment = invocation ~root environment [ "--version" ]

let parse_probe_output output =
  let version = String.strip output in
  match String.split version ~on:'.' with
  | major :: minor :: _ ->
    (match Int.of_string_opt major, Int.of_string_opt minor with
     | Some major, Some minor when major > 3 || (major = 3 && minor >= 22) -> Ok version
     | Some _, Some _ ->
       Error ("Dune 3.22 or newer is required; selected environment has " ^ version)
     | _ -> Error ("Could not parse Dune version: " ^ String.prefix version 256))
  | _ -> Error ("Could not parse Dune version: " ^ String.prefix version 256)
;;

let inspect_invocation ~root environment =
  invocation
    ~root
    environment
    [ "describe"; "workspace"; "--root"; root; "--format=sexp"; "--lang=0.1" ]
;;

let atom = function
  | Sexp.Atom value -> Some value
  | List _ -> None
;;

let record_fields = function
  | [ Sexp.List fields ] -> Some fields
  | _ -> None
;;

let find_field fields name =
  List.find_map fields ~f:(function
    | Sexp.List (Atom field_name :: values) when String.equal field_name name ->
      Some values
    | Atom _ | List _ -> None)
;;

let names fields =
  match find_field fields "names", find_field fields "name" with
  | Some [ List values ], _ -> List.filter_map values ~f:atom
  | Some _, _ -> []
  | None, Some [ value ] -> Option.to_list (atom value)
  | None, _ -> []
;;

let source_path fields =
  match find_field fields "source_dir" with
  | Some [ value ] ->
    Option.bind (atom value) ~f:(fun path ->
      if Filename.is_absolute path then None else Some path)
  | _ -> None
;;

let is_local fields =
  match find_field fields "local" with
  | Some [ Atom "true" ] -> true
  | Some [ Atom "false" ] -> false
  | _ -> true
;;

let context_name path = Filename.basename path

let parse_workspace output =
  let error message = Error ("Invalid Dune workspace lang 0.1 output: " ^ message) in
  match Or_error.try_with (fun () -> Sexp.of_string output) with
  | Error parse_error -> error (String.prefix (Error.to_string_hum parse_error) 512)
  | Ok (Atom _) -> error "expected a workspace record"
  | Ok (List fields) ->
    let rec parse fields contexts items =
      match fields with
      | [] ->
        if List.is_empty contexts
        then error "missing build_context"
        else
          Ok
            { V1.Dune_workspace.Inspection.contexts = List.rev contexts
            ; items = List.rev items
            }
      | Sexp.List (Atom "root" :: [ Atom _ ]) :: rest -> parse rest contexts items
      | Sexp.List (Atom "build_context" :: [ Atom path ]) :: rest ->
        parse rest (context_name path :: contexts) items
      | Sexp.List (Atom kind :: payload) :: rest ->
        (match record_fields payload with
         | None -> error ("malformed " ^ kind ^ " entry")
         | Some fields ->
           if not (is_local fields)
           then parse rest contexts items
           else (
             let item : V1.Dune_workspace.Item.t =
               { kind; names = names fields; source_path = source_path fields }
             in
             parse rest contexts (item :: items)))
      | _ :: _ -> error "malformed workspace field"
    in
    parse fields [] []
;;

let action_invocation
  ?(build_alias = "@all")
  ?(test_alias = "@runtest")
  ~root
  ~environment
  = function
  | V1.Dune_action.Build ->
    invocation
      ~root
      environment
      [ "build"; "-j20"; "--root"; root; "--no-buffer"; build_alias ]
  | Test ->
    invocation
      ~root
      environment
      [ "build"; "-j20"; "--root"; root; "--no-buffer"; test_alias ]
;;
