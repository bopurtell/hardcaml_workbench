open! Core
open Hardcaml_workbench_protocol.Simulation

let require yes message = if not yes then failwith message

let digest bytes =
  Cryptokit.hash_string (Cryptokit.Hash.sha256 ()) bytes
  |> Cryptokit.transform_string (Cryptokit.Hexa.encode ())
;;

let mkdir path =
  Core_unix.mkdir_p path;
  Core_unix.chmod path ~perm:0o700
;;

let directory_entries path ~limit =
  require (limit >= 0) "Negative directory scan limit";
  let dir = Core_unix.opendir path in
  Exn.protect
    ~finally:(fun () -> Core_unix.closedir dir)
    ~f:(fun () ->
      let rec next () =
        match Core_unix.readdir_opt dir with
        | Some ("." | "..") -> next ()
        | entry -> entry
      in
      let rec loop count names =
        match next () with
        | None -> List.rev names, false
        | Some _ when count = limit -> List.rev names, true
        | Some name -> loop (count + 1) (name :: names)
      in
      loop 0 [])
;;

let rec remove path =
  match Sys_unix.file_exists ~follow_symlinks:false path with
  | `No | `Unknown -> ()
  | `Yes ->
    let stat = Core_unix.lstat path in
    if Poly.equal stat.st_kind S_DIR
    then (
      List.iter (Sys_unix.ls_dir path) ~f:(fun name -> remove (Filename.concat path name));
      Core_unix.rmdir path)
    else Core_unix.unlink path
;;

let atomic path text =
  let tmp = path ^ ".tmp-" ^ Int.to_string (Random.int 1_000_000_000) in
  let fd =
    Core_unix.openfile tmp ~mode:[ O_WRONLY; O_CREAT; O_EXCL; O_CLOEXEC ] ~perm:0o600
  in
  Exn.protect
    ~finally:(fun () ->
      ignore (Or_error.try_with (fun () -> Core_unix.unlink tmp) : unit Or_error.t))
    ~f:(fun () ->
      Exn.protect
        ~finally:(fun () -> Core_unix.close fd)
        ~f:(fun () ->
          let bytes = Bytes.of_string text in
          let rec write pos =
            if pos < Bytes.length bytes
            then (
              let n =
                Core_unix.write fd ~buf:bytes ~pos ~len:(Bytes.length bytes - pos)
              in
              require (n > 0) "Could not persist simulation record";
              write (pos + n))
          in
          write 0;
          Core_unix.fsync fd);
      Core_unix.rename ~src:tmp ~dst:path;
      let dir =
        Core_unix.openfile (Filename.dirname path) ~mode:[ O_RDONLY; O_CLOEXEC ]
      in
      Exn.protect
        ~finally:(fun () -> Core_unix.close dir)
        ~f:(fun () -> Core_unix.fsync dir))
;;

(** No symlink component, bounded allocation, nonblocking open, and descriptor target
    verification to catch ancestor replacement between validation and open. *)
let read path ~max_bytes =
  require (Filename.is_absolute path) "Expected absolute simulation path";
  let rec components prefix = function
    | [] -> ()
    | part :: rest ->
      require
        (not (String.equal part "." || String.equal part ".."))
        "Invalid path component";
      let next = Filename.concat prefix part in
      let stat = Core_unix.lstat next in
      require (not (Poly.equal stat.st_kind S_LNK)) "Symlink in simulation artifact path";
      components next rest
  in
  components "/" (String.split path ~on:'/' |> List.filter ~f:(Fn.non String.is_empty));
  let fd = Core_unix.openfile path ~mode:[ O_RDONLY; O_NONBLOCK; O_CLOEXEC ] in
  Exn.protect
    ~finally:(fun () -> Core_unix.close fd)
    ~f:(fun () ->
      let before = Core_unix.fstat fd in
      require (Poly.equal before.st_kind S_REG) "Simulation file is not regular";
      require
        Int64.(before.st_size >= 0L && before.st_size <= of_int max_bytes)
        "Simulation file exceeds byte limit";
      let target =
        Filename_unix.realpath
          ("/proc/self/fd/" ^ Int.to_string (Core_unix.File_descr.to_int fd))
      in
      require (String.equal target path) "Simulation descriptor path changed";
      let buffer = Bytes.create (Int64.to_int_exn before.st_size + 1) in
      let rec loop pos =
        require (pos < Bytes.length buffer) "Simulation file grew while reading";
        let n = Core_unix.read fd ~buf:buffer ~pos ~len:(Bytes.length buffer - pos) in
        if n = 0 then Bytes.To_string.sub buffer ~pos:0 ~len:pos else loop (pos + n)
      in
      let bytes = loop 0 in
      let after = Core_unix.fstat fd in
      require
        (Int64.equal before.st_size after.st_size
         && Int64.equal after.st_size (Int64.of_int (String.length bytes))
         && Poly.equal before.st_mtime after.st_mtime
         && Poly.equal before.st_ctime after.st_ctime)
        "Simulation file changed while reading";
      bytes)
;;

let hex bytes = Cryptokit.transform_string (Cryptokit.Hexa.encode ()) bytes
let artifact_path dir id = Filename.concat dir ("artifact-" ^ digest id ^ ".bytes")

let is_active (a : Attempt.t) =
  match a.lifecycle with
  | Queued | Running -> true
  | _ -> false
;;
