open! Core

let exists path =
  try
    ignore (Core_unix.lstat path : Core_unix.stats);
    true
  with
  | Core_unix.Unix_error (ENOENT, _, _) -> false
;;

let existing_error path =
  sprintf "refusing to overwrite existing %s; inspect or edit it explicitly" path
;;

let publish ~directory ~path ~temporary_prefix ~contents =
  match
    Or_error.try_with (fun () ->
      if not (String.equal (Filename.dirname path) directory)
      then failwith "publication target must be in the supplied directory";
      if not (Poly.equal (Core_unix.lstat directory).st_kind S_DIR)
      then failwith (directory ^ ": expected directory, symlinks not allowed");
      let fd = Core_unix.openfile directory ~mode:[ O_RDONLY; O_NONBLOCK; O_CLOEXEC ] in
      Exn.protect
        ~finally:(fun () -> Core_unix.close fd)
        ~f:(fun () ->
          let pinned =
            "/proc/self/fd/" ^ Int.to_string (Core_unix.File_descr.to_int fd)
          in
          if (not (Poly.equal (Core_unix.fstat fd).st_kind S_DIR))
             || (not (String.equal (Filename_unix.realpath pinned) directory))
             || not (Poly.equal (Core_unix.lstat directory).st_kind S_DIR)
          then failwith (directory ^ ": publication directory changed");
          (* Pin the inspected directory so a concurrent parent replacement cannot
             redirect temporary creation or the final no-replace link through a symlink. *)
          let display_path = path in
          let path = Filename.concat pinned (Filename.basename path) in
          let temporary, channel =
            Filename_unix.open_temp_file
              ~in_dir:pinned
              ~perm:0o600
              temporary_prefix
              ".sexp"
          in
          Exn.protect
            ~f:(fun () ->
              Out_channel.output_string channel contents;
              Out_channel.flush channel;
              Core_unix.fsync (Core_unix.descr_of_out_channel channel);
              Out_channel.close channel;
              try
                (* Unlike rename, link never replaces any existing directory entry. The
                   complete file is visible at once, including to concurrent readers. *)
                Core_unix.link ~force:false ~target:temporary ~link_name:path ();
                Ok ()
              with
              | Core_unix.Unix_error (EEXIST, _, _) -> Error (existing_error display_path))
            ~finally:(fun () ->
              Out_channel.close_no_err channel;
              Core_unix.unlink temporary)))
  with
  | Ok result -> result
  | Error error -> Error (Error.to_string_hum error)
;;
