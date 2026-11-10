open! Core
open Hardcaml_workbench_protocol
module Config = Hardcaml_workbench_project_integration.Preparation_config

let require condition message = if not condition then failwith message

let sha256 s =
  Cryptokit.hash_string (Cryptokit.Hash.sha256 ()) s
  |> Cryptokit.transform_string (Cryptokit.Hexa.encode ())
;;

let rec normalize : Yojson.Safe.t -> Yojson.Safe.t = function
  | `Assoc fields ->
    require
      (Option.is_none
         (List.find_a_dup fields ~compare:(fun (a, _) (b, _) -> String.compare a b)))
      "Duplicate JSON field";
    `Assoc
      (List.sort fields ~compare:(fun (a, _) (b, _) -> String.compare a b)
       |> List.map ~f:(fun (k, v) -> k, normalize v))
  | `List values -> `List (List.map values ~f:normalize)
  | (`Null | `Bool _ | `Int _ | `String _) as value -> value
  | `Float f as value ->
    require (Float.is_finite f) "Nonfinite JSON";
    value
  | _ -> failwith "Non-JSON extension"
;;

let canonical value = Yojson.Safe.to_string (normalize value)

let field value name =
  match value with
  | `Assoc fields -> List.Assoc.find_exn fields name ~equal:String.equal
  | _ -> failwith "Expected JSON object"
;;

let text = function
  | `String value -> value
  | _ -> failwith "Expected JSON string"
;;

let array = function
  | `List values -> values
  | _ -> failwith "Expected JSON array"
;;

let without value key =
  match value with
  | `Assoc fields -> `Assoc (List.Assoc.remove fields key ~equal:String.equal)
  | _ -> failwith "Expected JSON object"
;;

let exact_fields value names =
  match value with
  | `Assoc fields ->
    require
      (List.equal
         String.equal
         (List.sort (List.map fields ~f:fst) ~compare:String.compare)
         (List.sort names ~compare:String.compare))
      "JSON fields do not match the versioned preparation contract"
  | _ -> failwith "Expected JSON object"
;;

let identity contract payload =
  sha256
    (canonical
       (`Assoc
         [ "contract", `String contract; "schema_version", `Int 1; "payload", payload ]))
;;

let valid_identity value =
  String.length value = 64
  && String.for_all value ~f:(function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false)
;;

let assignments (selection : Preparation.Selection.t) =
  let values =
    List.map selection.assignments ~f:(fun assignment ->
      match String.lsplit2 assignment ~on:'=' with
      | Some (key, value) when not (String.is_empty key || String.is_empty value) ->
        let scalar =
          match value with
          | "true" -> `Bool true
          | "false" -> `Bool false
          | _ -> `String value
        in
        key, `Assoc [ "key", `String key; "value", scalar ]
      | _ -> failwith "Assignments must be KEY=VALUE")
  in
  require
    (Option.is_none (List.find_a_dup (List.map values ~f:fst) ~compare:String.compare))
    "Duplicate assignment key";
  `List
    (List.sort values ~compare:(fun (a, _) (b, _) -> String.compare a b)
     |> List.map ~f:snd)
;;

let validate_selection (selection : Preparation.Selection.t) expected =
  List.iter [ selection.flow; selection.profile; selection.endpoint ] ~f:(fun s ->
    require
      (not (String.is_empty s || String.contains s '\000'))
      "Empty/invalid selection");
  ignore (assignments selection : Yojson.Safe.t);
  Option.iter expected ~f:(fun id ->
    require (valid_identity id) "Invalid expected plan identity")
;;

type validated =
  { bundle : Preparation.Bundle.t
  ; files : (string * string) list
  }

let read_bounded path =
  let stat = Core_unix.lstat path in
  require
    (Poly.equal stat.st_kind S_REG && Int64.(stat.st_size <= of_int 16777216))
    "Bundle file must be regular and at most 16 MiB";
  let channel = Stdlib.open_in_bin path in
  Exn.protect
    ~finally:(fun () -> Stdlib.close_in_noerr channel)
    ~f:(fun () ->
      let result = Buffer.create (Int64.to_int_exn stat.st_size) in
      let chunk = Bytes.create 65536 in
      let rec read () =
        let count = Stdlib.input channel chunk 0 (Bytes.length chunk) in
        if count > 0
        then (
          require
            (Buffer.length result + count <= 16777216)
            "Bundle file grew past byte budget";
          Buffer.add_subbytes result chunk ~pos:0 ~len:count;
          read ())
      in
      read ();
      Buffer.contents result)
;;

(* Bundle.publish retains the public identity path. It may be a plain directory or a
   relative link to one direct, identity-prefixed private object. *)
let publication_root ~store ~bundle_identity output_dir =
  let expected = Filename.concat store bundle_identity in
  require
    (Filename.is_absolute output_dir && String.equal output_dir expected)
    "Receipt output directory mismatch";
  let plain_directory path =
    require
      (Poly.equal (Core_unix.lstat path).st_kind S_DIR)
      "Bundle publication object must be a plain directory"
  in
  let root =
    match (Core_unix.lstat output_dir).st_kind with
    | S_DIR -> output_dir
    | S_LNK ->
      let target = Core_unix.readlink output_dir in
      let name = Filename.basename target in
      require
        (Hardcaml_workbench_project_integration.Manifest.valid_components target
         && (not (String.contains target '\000'))
         && String.equal target (Filename.concat ".objects" name)
         && String.is_prefix name ~prefix:(bundle_identity ^ "."))
        "Bundle publication link escaped private object layout";
      plain_directory (Filename.concat store ".objects");
      Filename.concat store target
    | _ -> failwith "Bundle identity destination must be a directory or publication link"
  in
  plain_directory root;
  require
    (String.equal (Filename_unix.realpath root) root)
    "Bundle publication object escaped store";
  root
;;

let member_path root path =
  let rec parents path =
    let parent = Filename.dirname path in
    if not (String.equal parent ".")
    then (
      parents parent;
      require
        (Poly.equal (Core_unix.lstat (Filename.concat root parent)).st_kind S_DIR)
        "Bundle member directory must not be a symlink")
  in
  parents path;
  Filename.concat root path
;;

let validate config ~selection ~expected_plan_identity output =
  Or_error.try_with (fun () ->
    require (String.length output <= 16 * 1024 * 1024) "Receipt exceeded byte budget";
    let receipt = Yojson.Safe.from_string output in
    ignore (normalize receipt : Yojson.Safe.t);
    exact_fields
      receipt
      [ "schema_version"
      ; "kind"
      ; "bundle_identity"
      ; "plan_identity"
      ; "output_dir"
      ; "reused"
      ; "plan"
      ];
    require
      (Poly.equal (field receipt "schema_version") (`Int 1)
       && Poly.equal (field receipt "kind") (`String "bundle_emission"))
      "Unsupported emission receipt";
    let bundle_identity = text (field receipt "bundle_identity") in
    let plan_identity = text (field receipt "plan_identity") in
    require
      (valid_identity bundle_identity && valid_identity plan_identity)
      "Invalid receipt identities";
    Option.iter expected_plan_identity ~f:(fun expected ->
      require (String.equal expected plan_identity) "Expected plan mismatch");
    let plan = field receipt "plan" in
    exact_fields
      plan
      [ "contract"
      ; "schema_version"
      ; "methodology"
      ; "methodology_hash"
      ; "project_name"
      ; "bundle_identity"
      ; "bundle_manifest"
      ; "configuration_bytes"
      ; "plan_identity"
      ];
    require
      (Poly.equal (field plan "contract") (`String "hardcaml-asic.methodology-plan")
       && Poly.equal (field plan "schema_version") (`Int 1))
      "Unsupported methodology plan";
    require
      (String.equal
         (identity "hardcaml-asic.plan-identity" (without plan "plan_identity"))
         plan_identity
       && Poly.equal (field plan "plan_identity") (`String plan_identity)
       && Poly.equal (field plan "bundle_identity") (`String bundle_identity))
      "Plan identity mismatch";
    let methodology = field plan "methodology" in
    exact_fields
      methodology
      [ "snapshot"
      ; "project_assignments"
      ; "effective_parameters"
      ; "translation"
      ; "recipe"
      ];
    require
      (Poly.equal
         (field plan "methodology_hash")
         (`String (identity "hardcaml-asic.methodology-hash" methodology)))
      "Methodology hash mismatch";
    let snapshot = field methodology "snapshot" in
    exact_fields
      snapshot
      [ "contract"
      ; "schema_version"
      ; "declaration"
      ; "selected"
      ; "definition"
      ; "profile"
      ; "endpoint"
      ; "stages"
      ; "request"
      ; "parameters"
      ];
    require
      (Poly.equal (field snapshot "contract") (`String "hardcaml-asic.flow-snapshot")
       && Poly.equal (field snapshot "schema_version") (`Int 1))
      "Unsupported flow snapshot";
    let selected = field snapshot "selected" in
    exact_fields selected [ "flow"; "profile" ];
    require
      (Poly.equal (field selected "flow") (`String selection.Preparation.Selection.flow)
       && Poly.equal (field selected "profile") (`String selection.profile)
       && Poly.equal (field snapshot "endpoint") (`String selection.endpoint))
      "Receipt selection mismatch";
    let recipe = field methodology "recipe" in
    exact_fields recipe [ "schema_version"; "stages"; "initial_boundary" ];
    require
      (List.mem [ `Int 3; `Int 4 ] (field recipe "schema_version") ~equal:Poly.equal
       && Poly.equal (field recipe "initial_boundary") `Null
       && String.equal
            (canonical (field recipe "stages"))
            (canonical (field snapshot "stages"))
       && Option.equal
            Poly.equal
            (List.last (array (field recipe "stages")))
            (Some (`String selection.endpoint)))
      "Receipt does not describe the selected fresh recipe endpoint";
    let canonical_stages = Asic_public.recipe_stages recipe in
    let prefix =
      List.take_while canonical_stages ~f:(fun stage ->
        not (String.equal stage selection.endpoint))
      @ [ selection.endpoint ]
    in
    require
      (List.mem canonical_stages selection.endpoint ~equal:String.equal
       && Poly.equal
            (field recipe "stages")
            (`List (List.map prefix ~f:(fun s -> `String s))))
      "Receipt recipe is not a complete fresh prefix";
    let request =
      array (field snapshot "request")
      |> List.sort ~compare:(fun a b ->
        String.compare (text (field a "key")) (text (field b "key")))
    in
    require
      (String.equal (canonical (`List request)) (canonical (assignments selection)))
      "Receipt assignments mismatch";
    let output_dir = text (field receipt "output_dir") in
    let store =
      Filename_unix.realpath (Filename.concat config.Config.results_root "bundles")
    in
    let root = publication_root ~store ~bundle_identity output_dir in
    let manifest_bytes = read_bounded (Filename.concat root "manifest.json") in
    let manifest = Yojson.Safe.from_string manifest_bytes in
    ignore (normalize manifest : Yojson.Safe.t);
    require
      (Poly.equal (field manifest "schema_version") (`Int 1)
       && Poly.equal (field manifest "project") (field plan "project_name")
       && Poly.equal (field manifest "identity") (`String bundle_identity)
       && String.equal
            (sha256 (Yojson.Safe.to_string (without manifest "identity")))
            bundle_identity)
      "Manifest identity mismatch";
    require
      (String.equal
         (text (field plan "bundle_manifest"))
         (Yojson.Safe.to_string manifest))
      "Plan manifest mismatch";
    let files = array (field manifest "files") in
    require (List.length files <= 512) "Bundle file count exceeded";
    let total = ref 0 in
    let paths =
      List.map files ~f:(fun file ->
        exact_fields file [ "path"; "sha256" ];
        let path = text (field file "path") in
        require
          (Hardcaml_workbench_project_integration.Manifest.valid_components path
           && (not (String.contains path '\000'))
           && not (String.equal path "manifest.json"))
          "Invalid bundle path";
        let source = member_path root path in
        require
          (String.is_prefix (Filename_unix.realpath source) ~prefix:(root ^ "/"))
          "Bundle path escaped root";
        let bytes = read_bounded source in
        total := !total + String.length bytes;
        require (!total <= 64 * 1024 * 1024) "Bundle total byte budget exceeded";
        require
          (Poly.equal (field file "sha256") (`String (sha256 bytes)))
          "Bundle file hash mismatch";
        path, sha256 bytes)
    in
    require
      (Option.is_none (List.find_a_dup (List.map paths ~f:fst) ~compare:String.compare))
      "Duplicate bundle path";
    require
      (List.exists paths ~f:(fun (path, _) -> String.equal path "src/config.json"))
      "Manifest omitted src/config.json";
    require
      (String.equal
         (read_bounded (member_path root "src/config.json"))
         (text (field plan "configuration_bytes")))
      "Configuration bytes mismatch";
    let reused =
      match field receipt "reused" with
      | `Bool b -> b
      | _ -> failwith "Expected reused boolean"
    in
    { bundle =
        { bundle_identity
        ; plan_identity
        ; output_dir
        ; reused
        ; plan_json = Yojson.Safe.to_string plan
        ; artifacts = []
        }
    ; files = ("manifest.json", sha256 manifest_bytes) :: paths
    })
;;
