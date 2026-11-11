open! Core

type location =
  | Common
  | Legacy
[@@deriving compare, equal, sexp]

type resolved =
  { path : string
  ; contents : string
  ; location : location
  }

let max_config_bytes = 64 * 1024

type event =
  | Opened of string
  | Read of string
  | Loaded_pair

let check_filename filename =
  if String.is_empty filename
     || String.equal filename "."
     || String.equal filename ".."
     || String.contains filename '/'
     || String.contains filename '\000'
  then invalid_arg "Configuration filename must be a single basename"
;;

let legacy_path ~root ~filename =
  check_filename filename;
  Filename.concat root filename
;;

let preferred_path ~root ~filename =
  check_filename filename;
  Filename.concat (Filename.concat root ".workbench") filename
;;

let require yes message = if not yes then failwith message

(* Inspect each component with lstat: a dangling symlink is an error, not absence.
   Only ENOENT means absent; permission errors and ENOTDIR remain visible. *)
let inspect_safely path =
  require (Filename.is_absolute path) "Expected absolute project configuration path";
  let rec loop prefix = function
    | [] -> Some (Core_unix.lstat prefix)
    | part :: rest ->
      require
        (not (String.equal part "." || String.equal part ".."))
        "Invalid configuration path component";
      let next = Filename.concat prefix part in
      let stat =
        try Some (Core_unix.lstat next) with
        | Core_unix.Unix_error (ENOENT, _, _) -> None
      in
      (match stat with
       | None -> None
       | Some stat ->
         require (not (Poly.equal stat.st_kind S_LNK)) (next ^ ": symlink not allowed");
         if not (List.is_empty rest)
         then require (Poly.equal stat.st_kind S_DIR) (next ^ ": not a directory");
         if List.is_empty rest then Some stat else loop next rest)
  in
  loop "/" (String.split path ~on:'/' |> List.filter ~f:(Fn.non String.is_empty))
;;

let same_version (a : Core_unix.stats) (b : Core_unix.stats) =
  Poly.equal a.st_dev b.st_dev
  && Poly.equal a.st_ino b.st_ino
  && Poly.equal a.st_kind b.st_kind
  && Int64.equal a.st_size b.st_size
  && Poly.equal a.st_mtime b.st_mtime
  && Poly.equal a.st_ctime b.st_ctime
;;

let revalidate path expected =
  require
    (Option.equal same_version expected (inspect_safely path))
    (path ^ ": configuration changed during resolution")
;;

let read path ~observed ~max_bytes ~on_event =
  let fd = Core_unix.openfile path ~mode:[ O_RDONLY; O_NONBLOCK; O_CLOEXEC ] in
  Exn.protect
    ~finally:(fun () -> Core_unix.close fd)
    ~f:(fun () ->
      let before = Core_unix.fstat fd in
      require (same_version observed before) (path ^ ": changed before opening");
      require (Poly.equal before.st_kind S_REG) (path ^ ": not a regular file");
      require
        Int64.(before.st_size >= 0L && before.st_size <= of_int max_bytes)
        (path ^ ": configuration exceeds byte limit");
      on_event (Opened path);
      let target =
        Filename_unix.realpath
          ("/proc/self/fd/" ^ Int.to_string (Core_unix.File_descr.to_int fd))
      in
      require (String.equal target path) (path ^ ": descriptor path changed");
      revalidate path (Some before);
      let buffer = Bytes.create (Int64.to_int_exn before.st_size + 1) in
      let rec loop pos =
        require (pos < Bytes.length buffer) (path ^ ": grew while reading");
        let n = Core_unix.read fd ~buf:buffer ~pos ~len:(Bytes.length buffer - pos) in
        if n = 0 then Bytes.To_string.sub buffer ~pos:0 ~len:pos else loop (pos + n)
      in
      let contents = loop 0 in
      on_event (Read path);
      let after = Core_unix.fstat fd in
      require
        (same_version before after
         && Int64.equal after.st_size (Int64.of_int (String.length contents)))
        (path ^ ": changed while reading");
      revalidate path (Some after);
      contents)
;;

let resolve_with_hook ~root ~filename ~max_bytes ~on_event =
  Or_error.try_with (fun () ->
    require (max_bytes >= 0 && max_bytes < Int.max_value) "Invalid configuration byte limit";
    let max_bytes = Int.min max_bytes max_config_bytes in
    let load location path =
      let observed = inspect_safely path in
      let file =
        Option.map observed ~f:(fun observed ->
          { path; contents = read path ~observed ~max_bytes ~on_event; location })
      in
      path, observed, file
    in
    let common_path, common_stat, common = load Common (preferred_path ~root ~filename) in
    let legacy_path, legacy_stat, legacy = load Legacy (legacy_path ~root ~filename) in
    on_event Loaded_pair;
    (* Recheck both observations, including absence. This is a bounded change-detection
       fence, not an atomic snapshot: writers can still race after either check. *)
    revalidate common_path common_stat;
    revalidate legacy_path legacy_stat;
    match common, legacy with
    | Some common, Some legacy ->
      require
        (String.equal common.contents legacy.contents)
        (sprintf "Conflicting configuration files: %s and %s differ" common.path legacy.path);
      Some common
    | Some value, None | None, Some value -> Some value
    | None, None -> None)
;;

let resolve ~root ~filename ~max_bytes =
  resolve_with_hook ~root ~filename ~max_bytes ~on_event:ignore
;;

module For_testing = struct
  type nonrec event = event =
    | Opened of string
    | Read of string
    | Loaded_pair

  let resolve = resolve_with_hook
end
