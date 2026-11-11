open! Core
open Hardcaml_workbench_project_integration

let with_root f =
  let root = Filename_unix.temp_dir "wb049-" "" |> Filename_unix.realpath in
  let rec remove path =
    if Poly.equal (Core_unix.lstat path).st_kind S_DIR
    then (
      List.iter (Sys_unix.ls_dir path) ~f:(fun name -> remove (Filename.concat path name));
      Core_unix.rmdir path)
    else Core_unix.unlink path
  in
  Exn.protect ~f:(fun () -> f root) ~finally:(fun () -> remove root)
;;

let filenames =
  [ Manifest.filename
  ; Asic_config.filename
  ; Simulation_config.filename
  ; Preparation_config.filename
  ]
;;

let expect_race_error result =
  match result with
  | Ok _ -> failwith "Concurrent configuration mutation was accepted"
  | Error error ->
    assert (String.is_substring (Error.to_string_hum error) ~substring:"changed")
;;

let%test_unit "pathname replacement through ancestor rename after read is detected" =
  with_root (fun root ->
    let filename = Manifest.filename in
    let common = Config_location.preferred_path ~root ~filename in
    let directory = Filename.dirname common in
    Core_unix.mkdir directory;
    Out_channel.write_all common ~data:"original";
    let on_event = function
      | Config_location.For_testing.Read path when String.equal path common ->
        (* The opened file itself is untouched: its size/mtime/ctime do not change.
           Only the ancestor and current pathname are replaced. *)
        Core_unix.rename ~src:directory ~dst:(directory ^ "-saved");
        Core_unix.mkdir directory;
        Out_channel.write_all common ~data:"replaced"
      | _ -> ()
    in
    Config_location.For_testing.resolve ~root ~filename ~max_bytes:128 ~on_event
    |> expect_race_error)
;;

let%test_unit "pair fence detects either candidate being replaced, changed or removed" =
  List.iter [ `Common; `Legacy ] ~f:(fun candidate ->
    List.iter [ `Replace; `Rewrite; `Remove ] ~f:(fun mutation ->
      with_root (fun root ->
        let filename = Manifest.filename in
        let common = Config_location.preferred_path ~root ~filename in
        let legacy = Config_location.legacy_path ~root ~filename in
        Core_unix.mkdir (Filename.dirname common);
        List.iter [ common; legacy ] ~f:(fun path ->
          Out_channel.write_all path ~data:"identical");
        let path = match candidate with `Common -> common | `Legacy -> legacy in
        let on_event = function
          | Config_location.For_testing.Loaded_pair ->
            (match mutation with
             | `Replace ->
               (* Even replacing with identical bytes must invalidate the observation. *)
               let replacement = path ^ ".replacement" in
               Out_channel.write_all replacement ~data:"identical";
               Core_unix.rename ~src:replacement ~dst:path
             | `Rewrite -> Out_channel.write_all path ~data:"changed size"
             | `Remove -> Core_unix.unlink path)
          | _ -> ()
        in
        Config_location.For_testing.resolve ~root ~filename ~max_bytes:128 ~on_event
        |> expect_race_error)))
;;

let%test_unit "pair fence rechecks absence even when neither config initially exists" =
  List.iter [ `Common; `Legacy; `Neither ] ~f:(fun initially ->
    with_root (fun root ->
      let filename = Manifest.filename in
      let common = Config_location.preferred_path ~root ~filename in
      let legacy = Config_location.legacy_path ~root ~filename in
      Core_unix.mkdir (Filename.dirname common);
      (match initially with
       | `Common -> Out_channel.write_all common ~data:"same"
       | `Legacy -> Out_channel.write_all legacy ~data:"same"
       | `Neither -> ());
      let on_event = function
        | Config_location.For_testing.Loaded_pair ->
          let path = match initially with `Common -> legacy | `Legacy | `Neither -> common in
          Out_channel.write_all path ~data:"same"
        | _ -> ()
      in
      Config_location.For_testing.resolve ~root ~filename ~max_bytes:128 ~on_event
      |> expect_race_error))
;;

let%test_unit "first candidate is revalidated after reading the second" =
  with_root (fun root ->
    let filename = Manifest.filename in
    let common = Config_location.preferred_path ~root ~filename in
    let legacy = Config_location.legacy_path ~root ~filename in
    Core_unix.mkdir (Filename.dirname common);
    List.iter [ common; legacy ] ~f:(fun path -> Out_channel.write_all path ~data:"same");
    let on_event = function
      | Config_location.For_testing.Read path when String.equal path legacy ->
        Out_channel.write_all common ~data:"changed while reading legacy"
      | _ -> ()
    in
    Config_location.For_testing.resolve ~root ~filename ~max_bytes:128 ~on_event
    |> expect_race_error)
;;

let%test_unit "shared config ceiling applies even when caller requests more" =
  List.iter filenames ~f:(fun filename ->
    with_root (fun root ->
      let path = Config_location.legacy_path ~root ~filename in
      let resolve max_bytes = Config_location.resolve ~root ~filename ~max_bytes in
      Out_channel.write_all path ~data:(String.make Config_location.max_config_bytes 'x');
      assert (Result.is_ok (resolve Config_location.max_config_bytes));
      assert (Result.is_error (resolve (Config_location.max_config_bytes - 1)));
      Out_channel.write_all
        path
        ~data:(String.make (Config_location.max_config_bytes + 1) 'x');
      assert (Result.is_error (resolve (Int.max_value - 1)))))
;;

let%test_unit "all schemas select old, new, and identical bytes; differing bytes conflict" =
  List.iter filenames ~f:(fun filename ->
    with_root (fun root ->
      let old = Config_location.legacy_path ~root ~filename in
      let common = Config_location.preferred_path ~root ~filename in
      let resolve () = Config_location.resolve ~root ~filename ~max_bytes:128 in
      assert (Option.is_none (Or_error.ok_exn (resolve ())));
      Out_channel.write_all old ~data:"same\000bytes\n";
      let selected () = Option.value_exn (Or_error.ok_exn (resolve ())) in
      [%test_eq: Config_location.location] (selected ()).location Legacy;
      Core_unix.mkdir (Filename.dirname common);
      Out_channel.write_all common ~data:"same\000bytes\n";
      [%test_eq: Config_location.location] (selected ()).location Common;
      [%test_eq: string] (selected ()).path common;
      Out_channel.write_all common ~data:"same\000bytes\n\n";
      assert (Result.is_error (resolve ()));
      let message = Result.error (resolve ()) |> Option.value_exn |> Error.to_string_hum in
      assert (String.is_substring message ~substring:old);
      assert (String.is_substring message ~substring:common);
      Core_unix.unlink old;
      [%test_eq: string] (selected ()).contents "same\000bytes\n\n"))
;;

let%test_unit "unsafe common entries never fall back to a valid legacy file" =
  List.iter [ `Directory; `Fifo; `Symlink; `Dangling; `Large ] ~f:(fun kind ->
    with_root (fun root ->
      let filename = Manifest.filename in
      let old = Config_location.legacy_path ~root ~filename in
      let common = Config_location.preferred_path ~root ~filename in
      Out_channel.write_all old ~data:"valid";
      Core_unix.mkdir (Filename.dirname common);
      (match kind with
       | `Directory -> Core_unix.mkdir common
       | `Fifo -> Core_unix.mkfifo common ~perm:0o600
       | `Symlink -> Core_unix.symlink ~target:old ~link_name:common
       | `Dangling -> Core_unix.symlink ~target:(old ^ ".missing") ~link_name:common
       | `Large -> Out_channel.write_all common ~data:(String.make 129 'x'));
      assert (Result.is_error (Config_location.resolve ~root ~filename ~max_bytes:128))))
;;

let%test_unit "symlinked common directory and unsafe legacy entries are visible" =
  with_root (fun root ->
    let filename = Manifest.filename in
    let old = Config_location.legacy_path ~root ~filename in
    let common = Config_location.preferred_path ~root ~filename in
    let resolve () = Config_location.resolve ~root ~filename ~max_bytes:128 in
    Out_channel.write_all old ~data:"valid";
    Core_unix.symlink ~target:root ~link_name:(Filename.dirname common);
    assert (Result.is_error (resolve ()));
    Core_unix.unlink (Filename.dirname common);
    Core_unix.mkdir (Filename.dirname common);
    Out_channel.write_all common ~data:"valid";
    Core_unix.unlink old;
    Core_unix.symlink ~target:common ~link_name:old;
    assert (Result.is_error (resolve ())))
;;

let%test_unit "invalid new schema is selected without fallback and relative driver is preserved" =
  with_root (fun root ->
    let filename = Manifest.filename in
    let old = Config_location.legacy_path ~root ~filename in
    let common = Config_location.preferred_path ~root ~filename in
    let valid =
      "(lang hardcaml-workbench 1) (project (name demo)) (dune (driver ./app/driver.exe))"
    in
    Out_channel.write_all old ~data:valid;
    Core_unix.mkdir (Filename.dirname common);
    Out_channel.write_all common ~data:valid;
    let selected () =
      Config_location.resolve ~root ~filename ~max_bytes:65536
      |> Or_error.ok_exn
      |> Option.value_exn
    in
    let parsed = Manifest.parse_string (selected ()).contents |> Result.ok_or_failwith in
    [%test_eq: string option] parsed.driver (Some "./app/driver.exe");
    Core_unix.unlink old;
    Out_channel.write_all common ~data:"(lang hardcaml-workbench 999)";
    assert (Result.is_error (Manifest.parse_string (selected ()).contents));
    Out_channel.write_all old ~data:valid;
    assert (Result.is_error (Config_location.resolve ~root ~filename ~max_bytes:65536)))
;;
