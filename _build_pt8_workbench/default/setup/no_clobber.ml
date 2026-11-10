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
      let temporary, channel =
        Filename_unix.open_temp_file
          ~in_dir:directory
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
          | Core_unix.Unix_error (EEXIST, _, _) -> Error (existing_error path))
        ~finally:(fun () ->
          Out_channel.close_no_err channel;
          Core_unix.unlink temporary))
  with
  | Ok result -> result
  | Error error -> Error (Error.to_string_hum error)
;;
