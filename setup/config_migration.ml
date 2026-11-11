open! Core
module Integration = Hardcaml_workbench_project_integration
module Location = Integration.Config_location

type copy =
  { filename : string
  ; source : string
  ; target : string
  ; contents : string
  }

type t =
  { root : string
  ; copies : copy list
  }

let filenames =
  [ Integration.Manifest.filename
  ; Integration.Asic_config.filename
  ; Integration.Simulation_config.filename
  ; Integration.Preparation_config.filename
  ]
;;

let filesystem_result f =
  match Or_error.try_with f with
  | Ok result -> result
  | Error error -> Error (Error.to_string_hum error)
;;

let iter_result items ~f = List.fold_result items ~init:() ~f:(fun () item -> f item)

(* Migration is deliberately schema-independent, including configurations from newer
   versions. Resolve applies the shared filesystem checks and byte conflict rules. *)
let resolve ~root ~filename =
  Location.resolve ~root ~filename ~max_bytes:Location.max_config_bytes
  |> Result.map_error ~f:Error.to_string_hum
;;

let prepare ~root =
  let%bind.Result root = Project_discovery.explicit_root root in
  let%map.Result copies =
    List.fold_result filenames ~init:[] ~f:(fun copies filename ->
      let%map.Result resolved = resolve ~root ~filename in
      match resolved with
      | Some { location = Legacy; path = source; contents } ->
        { filename; source; target = Location.preferred_path ~root ~filename; contents }
        :: copies
      | Some { location = Common; _ } | None -> copies)
  in
  { root; copies = List.rev copies }
;;

let preview t =
  match t.copies with
  | [] -> "No configuration copies needed.\n"
  | copies ->
    let directory = Filename.concat t.root ".workbench" in
    (if No_clobber.exists directory then "" else sprintf "Create directory %s\n" directory)
    ^ String.concat
        (List.map copies ~f:(fun copy ->
           sprintf "Copy %s -> %s (retain legacy)\n" copy.source copy.target))
;;

let require_absent ~root ~filename =
  filesystem_result (fun () ->
    let legacy = Location.legacy_path ~root ~filename in
    let common = Location.preferred_path ~root ~filename in
    if No_clobber.exists legacy
    then Error (No_clobber.existing_error legacy)
    else if No_clobber.exists common
    then Error (No_clobber.existing_error common)
    else Result.map (resolve ~root ~filename) ~f:(fun _ -> ()))
;;

let ensure_common_directory ~root =
  filesystem_result (fun () ->
    let directory = Filename.concat root ".workbench" in
    (try Core_unix.mkdir ~perm:0o700 directory with
     | Core_unix.Unix_error (EEXIST, _, _) -> ());
    if not (Poly.equal (Core_unix.lstat directory).st_kind S_DIR)
    then Error (directory ^ ": expected a directory, symlinks not allowed")
    else Ok directory)
;;

let publish t =
  (* Recheck the entire set before any mutation, then each copy immediately before
     publication. A failed suffix leaves both the originals and completed copies. *)
  let%bind.Result (_ : t) = prepare ~root:t.root in
  let%bind.Result () =
    iter_result t.copies ~f:(fun copy ->
      let%bind.Result current = resolve ~root:t.root ~filename:copy.filename in
      match current with
      | Some current when String.equal current.contents copy.contents -> Ok ()
      | _ -> Error (copy.source ^ ": changed since migration was prepared"))
  in
  match t.copies with
  | [] -> Ok ()
  | _ ->
    let%bind.Result directory = ensure_common_directory ~root:t.root in
    iter_result t.copies ~f:(fun copy ->
      let%bind.Result current = resolve ~root:t.root ~filename:copy.filename in
      match current with
      | Some current when String.equal current.contents copy.contents ->
        (match current.location with
         | Common -> Ok ()
         | Legacy ->
           No_clobber.publish
             ~directory
             ~path:copy.target
             ~temporary_prefix:".workbench-migrate-"
             ~contents:copy.contents)
      | _ -> Error (copy.source ^ ": changed during migration"))
;;
