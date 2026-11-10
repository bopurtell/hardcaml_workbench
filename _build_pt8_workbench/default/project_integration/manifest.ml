open! Core

type t =
  { project_name : string
  ; driver : string option
  ; build_alias : string
  ; test_alias : string
  }
[@@deriving compare, equal, sexp]

let version = 1
let filename = "hardcaml-workbench.sexp"
let default_build_alias = "@all"
let default_test_alias = "@runtest"
let error field message = Error (sprintf "%s: %s" field message)

let one_field fields name ~required =
  let values =
    List.filter_map fields ~f:(function
      | Sexp.List (Atom field :: values) when String.equal field name -> Some values
      | Atom _ | List _ -> None)
  in
  match values, required with
  | [], false -> Ok None
  | [], true -> error name "required field is missing"
  | [ [ Atom value ] ], _ when not (String.is_empty value) -> Ok (Some value)
  | [ [ Atom _ ] ], _ -> error name "value must not be empty"
  | [ _ ], _ -> error name "expected exactly one atom"
  | _ :: _ :: _, _ -> error name "field is duplicated"
;;

let validate_known_fields stanza fields known =
  List.fold_result fields ~init:() ~f:(fun () -> function
    | Sexp.List (Atom name :: _) when List.mem known name ~equal:String.equal -> Ok ()
    | Sexp.List (Atom name :: _) -> error (stanza ^ "." ^ name) "unknown field"
    | Atom _ | List [] | List (List _ :: _) -> error stanza "malformed field")
;;

let valid_components value =
  (not (Filename.is_absolute value))
  && List.for_all (String.split value ~on:'/') ~f:(fun component ->
    (not (String.is_empty component))
    && (not (String.equal component "."))
    && not (String.equal component ".."))
;;

let validate_alias field value =
  let components = String.split value ~on:'/' in
  match List.last components with
  | Some alias
    when valid_components value
         && String.is_prefix alias ~prefix:"@"
         && String.length alias > 1 -> Ok value
  | _ ->
    error field "expected @name or path/@name with no empty, '.' or '..' path component"
;;

let validate_driver value =
  match String.chop_prefix value ~prefix:"./" with
  | Some path when valid_components path -> Ok value
  | _ -> error "dune.driver" "expected ./path with no empty, '.' or '..' component"
;;

let stanza sexps name =
  let matches =
    List.filter_map sexps ~f:(function
      | Sexp.List (Atom stanza :: fields) when String.equal stanza name -> Some fields
      | Atom _ | List _ -> None)
  in
  match matches with
  | [] -> error name "required stanza is missing"
  | [ fields ] -> Ok fields
  | _ -> error name "stanza is duplicated"
;;

let parse_sexps sexps =
  match sexps with
  | Sexp.List [ Atom "lang"; Atom "hardcaml-workbench"; Atom version_string ] :: _ ->
    (match Int.of_string_opt version_string with
     | Some parsed when parsed = version ->
       let known_top = [ "lang"; "project"; "dune" ] in
       let%bind.Result () =
         List.fold_result sexps ~init:() ~f:(fun () -> function
           | Sexp.List (Atom name :: _) when List.mem known_top name ~equal:String.equal
             -> Ok ()
           | Sexp.List (Atom name :: _) -> error name "unknown top-level form"
           | Atom _ | List [] | List (List _ :: _) -> error "manifest" "malformed form")
       in
       let%bind.Result project_fields = stanza sexps "project" in
       let%bind.Result dune_fields = stanza sexps "dune" in
       let lang_count =
         List.count sexps ~f:(function
           | Sexp.List (Atom "lang" :: _) -> true
           | _ -> false)
       in
       if lang_count <> 1
       then Error "lang: stanza is duplicated"
       else (
         let%bind.Result () = validate_known_fields "project" project_fields [ "name" ] in
         let%bind.Result () =
           validate_known_fields
             "dune"
             dune_fields
             [ "driver"; "build_alias"; "test_alias" ]
         in
         let%bind.Result project_name =
           one_field project_fields "name" ~required:true
           |> Result.map ~f:(fun value -> Option.value_exn value)
         in
         let%bind.Result driver = one_field dune_fields "driver" ~required:false in
         let%bind.Result build_alias =
           one_field dune_fields "build_alias" ~required:false
         in
         let%bind.Result test_alias =
           one_field dune_fields "test_alias" ~required:false
         in
         let%bind.Result driver =
           Option.value_map driver ~default:(Ok None) ~f:(fun value ->
             validate_driver value |> Result.map ~f:Option.some)
         in
         let%bind.Result build_alias =
           validate_alias
             "dune.build_alias"
             (Option.value build_alias ~default:default_build_alias)
         in
         let%map.Result test_alias =
           validate_alias
             "dune.test_alias"
             (Option.value test_alias ~default:default_test_alias)
         in
         { project_name; driver; build_alias; test_alias })
     | Some parsed ->
       Error
         (sprintf
            "lang: unsupported hardcaml-workbench manifest version %d (supported: 1)"
            parsed)
     | None -> Error "lang: version must be an integer")
  | Sexp.List (Atom "lang" :: _) :: _ ->
    Error "lang: expected (lang hardcaml-workbench 1)"
  | _ -> Error "lang: must be the first form"
;;

let parse_string contents =
  match Or_error.try_with (fun () -> Sexp.of_string_many contents) with
  | Error error -> Error (Error.to_string_hum error)
  | Ok sexps -> parse_sexps sexps
;;

(* This is the on-disk, versioned format, not [sexp_of_t]'s record encoding. *)
let to_string t =
  let field name value = Sexp.List [ Atom name; Atom value ] in
  let forms =
    [ Sexp.List [ Atom "lang"; Atom "hardcaml-workbench"; Atom (Int.to_string version) ]
    ; Sexp.List [ Atom "project"; field "name" t.project_name ]
    ; Sexp.List
        (Atom "dune"
         :: (Option.to_list (Option.map t.driver ~f:(field "driver"))
             @ [ field "build_alias" t.build_alias; field "test_alias" t.test_alias ]))
    ]
  in
  String.concat ~sep:"\n" (List.map forms ~f:Sexp.to_string_hum) ^ "\n"
;;
