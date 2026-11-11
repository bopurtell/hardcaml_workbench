open! Core
module Migration = Hardcaml_workbench_setup.Config_migration
module Initialization = Hardcaml_workbench_setup.Initialization

let filename = "hardcaml-workbench.sexp"

let with_project f =
  let root = Filename_unix.temp_dir "workbench-migration-test-" "" in
  let rec remove path =
    match (Core_unix.lstat path).st_kind with
    | S_DIR ->
      List.iter (Sys_unix.ls_dir path) ~f:(fun name -> remove (Filename.concat path name));
      Core_unix.rmdir path
    | _ -> Core_unix.unlink path
  in
  Exn.protect
    ~f:(fun () ->
      Out_channel.write_all
        (Filename.concat root "dune-project")
        ~data:"(lang dune 3.22)\n";
      f root)
    ~finally:(fun () -> remove root)
;;

let ok = function
  | Ok value -> value
  | Error message -> failwith message
;;

let%test_unit "changed sources and newly conflicting suffix fail before any write" =
  List.iter [ `Source; `Conflict ] ~f:(fun mutation ->
    with_project (fun root ->
      let legacy = Filename.concat root filename in
      Out_channel.write_all legacy ~data:"original";
      let plan = ok (Migration.prepare ~root) in
      let common = Filename.concat root ".workbench" in
      (match mutation with
       | `Source -> Out_channel.write_all legacy ~data:"changed"
       | `Conflict ->
         Core_unix.mkdir common;
         Out_channel.write_all
           (Filename.concat root "hardcaml-workbench-preparation.sexp")
           ~data:"legacy suffix";
         Out_channel.write_all
           (Filename.concat common "hardcaml-workbench-preparation.sexp")
           ~data:"conflicting suffix");
      assert (Result.is_error (Migration.publish plan));
      assert (not (Sys_unix.file_exists_exn (Filename.concat common filename)))))
;;

let%test_unit "replaying a successful migration plan skips equal destinations" =
  with_project (fun root ->
    Out_channel.write_all (Filename.concat root filename) ~data:"unchanged bytes\000";
    let plan = ok (Migration.prepare ~root) in
    ok (Migration.publish plan);
    ok (Migration.publish plan);
    [%test_eq: string]
      (In_channel.read_all (Filename.concat root filename))
      "unchanged bytes\000")
;;

let%test_unit "unsafe common directory appearing after preparation is rejected" =
  with_project (fun root ->
    let init = ok (Initialization.prepare ~root ()) in
    Out_channel.write_all (Filename.concat root filename) ~data:"legacy";
    let migration = ok (Migration.prepare ~root) in
    Core_unix.symlink ~target:root ~link_name:(Filename.concat root ".workbench");
    assert (Result.is_error (Migration.publish migration));
    Core_unix.unlink (Filename.concat root filename);
    assert (Result.is_error (Initialization.publish init));
    assert (not (Sys_unix.file_exists_exn (Filename.concat root filename))))
;;
