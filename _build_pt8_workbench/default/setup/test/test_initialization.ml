open! Core
module Initialization = Hardcaml_workbench_setup.Initialization

let with_project f =
  let root = Filename_unix.temp_dir "workbench-init-test-" "" in
  Exn.protect
    ~f:(fun () ->
      Out_channel.write_all
        (Filename.concat root "dune-project")
        ~data:"(lang dune 3.22)\n";
      f root)
    ~finally:(fun () ->
      List.iter (Sys_unix.ls_dir root) ~f:(fun name ->
        Core_unix.unlink (Filename.concat root name));
      Core_unix.rmdir root)
;;

let prepare_exn root =
  match Initialization.prepare ~root () with
  | Ok plan -> plan
  | Error message -> failwith message
;;

let%test_unit "only direct project roots accepted by the opener can be initialized" =
  with_project (fun root ->
    let nested = Filename.concat root "nested" in
    Core_unix.mkdir nested;
    Exn.protect
      ~f:(fun () ->
        Out_channel.write_all (Filename.concat nested "dune") ~data:"";
        assert (Result.is_error (Initialization.prepare ~root:nested ()));
        assert (Result.is_ok (Initialization.prepare ~root ())))
      ~finally:(fun () ->
        Core_unix.unlink (Filename.concat nested "dune");
        Core_unix.rmdir nested))
;;

let%test_unit "publication refuses a file or dangling symlink created after preparation" =
  List.iter [ `File; `Symlink ] ~f:(fun occupant ->
    with_project (fun root ->
      let plan = prepare_exn root in
      let path = Initialization.path plan in
      (match occupant with
       | `File -> Out_channel.write_all path ~data:"created by another writer\n"
       | `Symlink ->
         Core_unix.symlink ~target:(Filename.concat root "missing") ~link_name:path);
      assert (Result.is_error (Initialization.publish plan));
      (match occupant with
       | `File ->
         [%test_eq: string] (In_channel.read_all path) "created by another writer\n"
       | `Symlink ->
         [%test_eq: string] (Core_unix.readlink path) (Filename.concat root "missing"));
      [%test_eq: string list]
        (List.sort (Sys_unix.ls_dir root) ~compare:String.compare)
        [ "dune-project"; "hardcaml-workbench.sexp" ]))
;;

let%test_unit "publishing the same plan twice preserves the complete first publication" =
  with_project (fun root ->
    let plan = prepare_exn root in
    assert (Result.is_ok (Initialization.publish plan));
    [%test_eq: string]
      (In_channel.read_all (Initialization.path plan))
      (Initialization.contents plan);
    assert (Result.is_error (Initialization.publish plan));
    [%test_eq: string]
      (In_channel.read_all (Initialization.path plan))
      (Initialization.contents plan);
    [%test_eq: int] (List.length (Sys_unix.ls_dir root)) 2)
;;
