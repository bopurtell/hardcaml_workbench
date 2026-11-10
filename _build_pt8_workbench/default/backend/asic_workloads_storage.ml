open! Core

(* Linux descriptor-relative storage, matching the provider bridge's /proc runtime.
   Walk from / without following symlink components. /proc/self/fd keeps every
   mkdir/open/rename/unlink attached to the admitted directory, not its spelling. *)
type t =
  { requested : string
  ; canonical : string
  ; mutable directory_id : (int * int) option
  }

let require = Asic_public.require
let rec physical p =
  match Sys_unix.file_exists p with
  | `Yes -> Filename_unix.realpath p
  | `Unknown -> failwith "Cannot resolve workload cache directory"
  | `No ->
    let parent = physical (Filename.dirname p) in
    (match Filename.basename p with
     | "." -> parent | ".." -> Filename.dirname parent | name -> Filename.concat parent name)
;;
let id (s : Core_unix.stats) = s.st_dev, s.st_ino
let directory s = require (Poly.equal s.Core_unix.st_kind S_DIR) "Workload cache component is not a directory"
let create requested =
  require (Filename.is_absolute requested) "Workload cache directory must be absolute";
  let canonical = physical requested in
  let directory_id = match Sys_unix.file_exists canonical with
    | `Yes -> let s=Core_unix.stat canonical in directory s; Some (id s)
    | `No -> None | `Unknown -> failwith "Cannot inspect workload cache directory" in
  {requested;canonical;directory_id}
;;
let canonical t = t.canonical
let check t =
  require (String.equal (physical t.requested) t.canonical) "Workload cache directory alias changed";
  Option.iter t.directory_id ~f:(fun expected ->
    let s=Core_unix.stat t.canonical in directory s;
    require (Poly.equal expected (id s)) "Workload cache directory generation changed")
;;
let proc fd = "/proc/self/fd/" ^ Int.to_string (Core_unix.File_descr.to_int fd)
let member name =
  require (not (String.is_empty name) && String.equal name (Filename.basename name)
    && not (List.mem [".";".."] name ~equal:String.equal) && not (String.contains name '\000'))
    "Workload cache filename must be a single component"
;;
let with_directory t ~create f =
  let rec walk fd = function
    | [] ->
      let s=Core_unix.fstat fd in directory s;
      Option.iter t.directory_id ~f:(fun expected ->
        require (Poly.equal expected (id s)) "Workload cache directory generation changed");
      require (String.equal (Core_unix.readlink (proc fd)) t.canonical)
        "Workload cache canonical directory moved";
      f fd;
      t.directory_id <- Some (id s)
    | name::rest ->
      let path=Filename.concat (proc fd) name in
      let before =
        try Core_unix.lstat path with
        | Core_unix.Unix_error (ENOENT,_,_) when create ->
          Core_unix.mkdir path ~perm:0o700;
          Core_unix.lstat path in
      directory before;
      let next=Core_unix.openfile path ~mode:[O_RDONLY;O_NONBLOCK;O_CLOEXEC] in
      Exn.protect ~finally:(fun () -> Core_unix.close next) ~f:(fun () ->
        let after=Core_unix.fstat next in directory after;
        require (Poly.equal (id before) (id after)) "Workload cache component changed while opening";
        walk next rest)
  in
  let root=Core_unix.openfile "/" ~mode:[O_RDONLY;O_NONBLOCK;O_CLOEXEC] in
  Exn.protect ~finally:(fun () -> Core_unix.close root) ~f:(fun () ->
    walk root (String.split t.canonical ~on:'/' |> List.filter ~f:(fun s -> not (String.is_empty s))))
;;
let read t ~name ~max_bytes =
  member name;
  check t;
  let result=ref None in
  (try with_directory t ~create:false (fun fd ->
     let file=Filename.concat (proc fd) name in
     if Poly.equal (Sys_unix.file_exists file) `Yes then
       result := Some (Asic_evidence_file.read_bounded file max_bytes))
   with Core_unix.Unix_error (ENOENT,_,_) -> ());
  check t;
  !result
;;
let write t ~name ~data ~before_write =
  member name;
  before_write (); check t;
  with_directory t ~create:true (fun directory ->
    before_write (); check t;
    require (String.equal (Core_unix.readlink (proc directory)) t.canonical)
      "Workload cache canonical directory moved";
    let temporary=Filename.concat (proc directory)
      (".workloads-" ^ Asic_public.digest (Time_ns.to_string (Time_ns.now ()) ^ Int.to_string (Random.bits ()))) in
    let fd=Core_unix.openfile temporary ~mode:[O_WRONLY;O_CREAT;O_EXCL;O_CLOEXEC] ~perm:0o600 in
    Exn.protect
      ~finally:(fun () -> Core_unix.close fd;
        try Core_unix.unlink temporary with Core_unix.Unix_error (ENOENT,_,_) -> ())
      ~f:(fun () ->
        let rec output pos = if pos<String.length data then (
          let n=Core_unix.write_substring fd ~buf:data ~pos ~len:(String.length data-pos) in
          require (n>0) "Workload cache write made no progress"; output (pos+n)) in
        output 0;
        check t;
        before_write ();
        check t;
        require (String.equal (Core_unix.readlink (proc directory)) t.canonical)
          "Workload cache canonical directory moved";
        Core_unix.rename ~src:temporary ~dst:(Filename.concat (proc directory) name)))
;;
