open! Core
module Project_discovery = Hardcaml_workbench_setup.Project_discovery

(* Trees live directly under /tmp rather than TMPDIR: under Dune, TMPDIR can be inside
   this repository's _build, whose own dune-project would become an enclosing root. *)
let rec remove path =
  match (Core_unix.lstat path).st_kind with
  | S_DIR ->
    Core_unix.chmod path ~perm:0o700;
    List.iter (Sys_unix.ls_dir path) ~f:(fun name -> remove (Filename.concat path name));
    Core_unix.rmdir path
  | _ -> Core_unix.unlink path
;;

let with_tree f =
  let base =
    Filename_unix.realpath (Filename_unix.temp_dir ~in_dir:"/tmp" "wb-discovery-" "")
  in
  Exn.protect ~f:(fun () -> f base) ~finally:(fun () -> remove base)
;;

let mkdir_p path = Core_unix.mkdir_p path ~perm:0o755
let touch path = Out_channel.write_all path ~data:"(lang dune 3.22)\n"
let discover start = Project_discovery.discover ~start ~explicit_flag:"--project-root" ()

let discover_exn start =
  match discover start with
  | Ok discovered -> discovered
  | Error message -> failwith message
;;

let expect_error start ~containing =
  match discover start with
  | Ok discovered ->
    raise_s
      [%message
        "expected discovery failure" (discovered : Project_discovery.Discovered.t)]
  | Error message ->
    List.iter containing ~f:(fun fragment ->
      if not (String.is_substring message ~substring:fragment)
      then raise_s [%message "diagnostic lacks fragment" message fragment])
;;

let%test_unit "starting at a root selects it, matching the explicit canonical root" =
  with_tree (fun base ->
    let root = base ^/ "project" in
    mkdir_p root;
    touch (root ^/ "dune-project");
    let discovered = discover_exn root in
    [%test_eq: string] discovered.root root;
    [%test_eq: string] discovered.start root;
    [%test_eq: string option] discovered.enclosing None;
    [%test_eq: (string, string) Result.t] (Project_discovery.explicit_root root) (Ok root))
;;

let%test_unit "subdirectories with only dune files resolve to the enclosing project" =
  with_tree (fun base ->
    let root = base ^/ "project" in
    let deep = root ^/ "src" ^/ "rtl" in
    mkdir_p deep;
    touch (root ^/ "dune-project");
    Out_channel.write_all (root ^/ "src" ^/ "dune") ~data:"(library (name x))\n";
    Out_channel.write_all (deep ^/ "dune") ~data:"";
    let discovered = discover_exn deep in
    [%test_eq: string] discovered.root root;
    [%test_eq: string] discovered.start deep;
    (* The explicit opener keeps rejecting the dune-only subdirectory. *)
    assert (Result.is_error (Project_discovery.explicit_root deep));
    assert (
      String.is_substring
        (Project_discovery.describe discovered ~explicit_flag:"--project-root")
        ~substring:("discovered project root " ^ root)))
;;

let%test_unit "nested projects: the nearest root wins and the outer one is reported" =
  with_tree (fun base ->
    let outer = base ^/ "outer" in
    let inner = outer ^/ "vendor" ^/ "inner" in
    let deep = inner ^/ "lib" in
    mkdir_p deep;
    touch (outer ^/ "dune-project");
    touch (inner ^/ "dune-project");
    for _ = 1 to 3 do
      let discovered = discover_exn deep in
      [%test_eq: string] discovered.root inner;
      [%test_eq: string option] discovered.enclosing (Some outer)
    done;
    let report =
      Project_discovery.describe (discover_exn deep) ~explicit_flag:"--project-root"
    in
    assert (String.is_substring report ~substring:("--project-root " ^ outer));
    (* Between the two projects, the outer root is the nearest. *)
    [%test_eq: string] (discover_exn (outer ^/ "vendor")).root outer)
;;

let%test_unit "a non-regular dune-project is not a marker" =
  with_tree (fun base ->
    let outer = base ^/ "outer" in
    let inner = outer ^/ "inner" in
    mkdir_p (inner ^/ "dune-project");
    touch (outer ^/ "dune-project");
    [%test_eq: string] (discover_exn inner).root outer;
    assert (Result.is_error (Project_discovery.explicit_root inner)))
;;

let%test_unit "no marker yields a bounded diagnostic naming the start and the escape \
               hatch"
  =
  with_tree (fun base ->
    let deep = base ^/ "plain" ^/ "dir" in
    mkdir_p (deep ^/ "dune-project-not");
    mkdir_p (base ^/ "plain" ^/ "dune-project");
    Out_channel.write_all (deep ^/ "dune") ~data:"";
    expect_error
      deep
      ~containing:
        [ "no Dune project found"
        ; deep
        ; "up to /"
        ; "only a dune file"
        ; "--project-root DIR"
        ; "ignored non-regular dune-project: " ^ base ^/ "plain" ^/ "dune-project"
        ])
;;

let%test_unit "symlinked directories are resolved before walking physical ancestors" =
  with_tree (fun base ->
    let project = base ^/ "project" in
    let target = project ^/ "src" in
    mkdir_p target;
    touch (project ^/ "dune-project");
    (* A link to a project subdirectory, placed outside any project. *)
    let link = base ^/ "shortcut" in
    Core_unix.symlink ~target ~link_name:link;
    let discovered = discover_exn link in
    [%test_eq: string] discovered.start target;
    [%test_eq: string] discovered.root project;
    (* A link inside a project to a directory outside it: its logical parent is the
       project, but discovery follows the target's physical ancestry. *)
    let outside = base ^/ "outside" in
    mkdir_p outside;
    let inner_link = project ^/ "outside-link" in
    Core_unix.symlink ~target:outside ~link_name:inner_link;
    expect_error inner_link ~containing:[ "no Dune project found"; outside ];
    (* A symlinked dune-project file pointing at a regular file counts, as for the
       daemon's opener; a dangling one does not. *)
    let linked = base ^/ "linked" in
    mkdir_p linked;
    Core_unix.symlink
      ~target:(project ^/ "dune-project")
      ~link_name:(linked ^/ "dune-project");
    [%test_eq: string] (discover_exn linked).root linked;
    let dangling = base ^/ "dangling" in
    mkdir_p dangling;
    Core_unix.symlink ~target:(base ^/ "missing") ~link_name:(dangling ^/ "dune-project");
    expect_error dangling ~containing:[ "no Dune project found" ])
;;

let%test_unit "an unsearchable directory stops discovery instead of being skipped" =
  (* Permission bits do not restrict root, so the check is meaningless there. *)
  if Core_unix.geteuid () <> 0
  then
    with_tree (fun base ->
      let project = base ^/ "project" in
      let locked = project ^/ "locked" in
      mkdir_p locked;
      touch (project ^/ "dune-project");
      Core_unix.chmod locked ~perm:0o600;
      expect_error
        locked
        ~containing:[ "stopped at " ^ locked; "Permission denied"; "--project-root DIR" ])
;;

let%test_unit "missing or non-directory starts are reported" =
  with_tree (fun base ->
    expect_error (base ^/ "missing") ~containing:[ "cannot resolve"; "--project-root" ];
    touch (base ^/ "file");
    expect_error (base ^/ "file") ~containing:[ "is not a directory" ])
;;

let%test_unit "resolve: explicit roots bypass discovery unchanged; both flags conflict" =
  let resolve ~explicit ~discover =
    Project_discovery.resolve
      ~explicit
      ~discover
      ~explicit_flag:"--project-root"
      ~discover_flag:"--discover-project"
  in
  (* Not validated here: the explicit path keeps its existing (daemon) validation. *)
  [%test_eq: (string option * string option, string) Result.t]
    (resolve ~explicit:(Some "relative/not-a-project") ~discover:false)
    (Ok (Some "relative/not-a-project", None));
  [%test_eq: (string option * string option, string) Result.t]
    (resolve ~explicit:None ~discover:false)
    (Ok (None, None));
  assert (Result.is_error (resolve ~explicit:(Some "/") ~discover:true))
;;

let%test_unit "discovery reads metadata only" =
  with_tree (fun base ->
    let root = base ^/ "project" in
    let deep = root ^/ "a" ^/ "b" in
    mkdir_p deep;
    touch (root ^/ "dune-project");
    let listing () =
      List.map
        [ base; root; root ^/ "a"; deep ]
        ~f:(fun dir -> List.sort (Sys_unix.ls_dir dir) ~compare:String.compare)
    in
    let before = listing () in
    ignore (discover_exn deep : Project_discovery.Discovered.t);
    [%test_eq: string list list] (listing ()) before)
;;
