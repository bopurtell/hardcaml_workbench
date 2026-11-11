open! Core
module Manifest = Hardcaml_workbench_project_integration.Manifest
module Location = Hardcaml_workbench_project_integration.Config_location

type t =
  { root : string
  ; path : string
  ; contents : string
  }

let root t = t.root
let path t = t.path
let contents t = t.contents

let filesystem_result f =
  match Or_error.try_with f with
  | Ok result -> result
  | Error error -> Error (Error.to_string_hum error)
;;

let prepare ~root ?project_name ?driver ?build_alias ?test_alias () =
  let%bind.Result root = Project_discovery.explicit_root root in
  filesystem_result
  @@ fun () ->
  let path = Location.preferred_path ~root ~filename:Manifest.filename in
  let%bind.Result () =
    Config_migration.require_absent ~root ~filename:Manifest.filename
  in
  let project_name =
    Option.value_or_thunk project_name ~default:(fun () ->
      match Filename.basename root with
      | "" | "/" | "." -> "hardcaml-project"
      | name -> name)
  in
  if String.is_empty (String.strip project_name)
  then Error "project.name: must not be empty or whitespace"
  else (
    let manifest : Manifest.t =
      { project_name
      ; driver
      ; build_alias = Option.value build_alias ~default:Manifest.default_build_alias
      ; test_alias = Option.value test_alias ~default:Manifest.default_test_alias
      }
    in
    let contents = Manifest.to_string manifest in
    let%map.Result (_ : Manifest.t) = Manifest.parse_string contents in
    { root; path; contents })
;;

let publish t =
  let%bind.Result () =
    Config_migration.require_absent ~root:t.root ~filename:Manifest.filename
  in
  let%bind.Result directory = Config_migration.ensure_common_directory ~root:t.root in
  No_clobber.publish
    ~directory
    ~path:t.path
    ~temporary_prefix:".hardcaml-workbench-init-"
    ~contents:t.contents
;;
