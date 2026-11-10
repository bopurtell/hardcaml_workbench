open! Core
module Simulation_setup = Hardcaml_workbench_setup.Simulation_setup
module Config = Simulation_setup.Config
module Outcome = Simulation_setup.Outcome

let rec remove path =
  match (Core_unix.lstat path).st_kind with
  | S_DIR ->
    List.iter (Sys_unix.ls_dir path) ~f:(fun name -> remove (Filename.concat path name));
    Core_unix.rmdir path
  | _ -> Core_unix.unlink path
;;

(* [base/project] is a Dune project; [base/bin] holds fixture providers; [base/calls]
   records every provider invocation so tests can prove what was (not) executed. *)
let with_project f =
  let base =
    Filename_unix.realpath (Filename_unix.temp_dir ~in_dir:"/tmp" "wb-simulation-" "")
  in
  Exn.protect
    ~f:(fun () ->
      let root = base ^/ "project" in
      Core_unix.mkdir root;
      Core_unix.mkdir (base ^/ "bin");
      Out_channel.write_all (root ^/ "dune-project") ~data:"(lang dune 3.22)\n";
      f ~base ~root)
    ~finally:(fun () -> remove base)
;;

let provider ~base name ~body =
  let path = base ^/ "bin" ^/ name in
  Out_channel.write_all
    path
    ~data:
      (sprintf
         "#!/bin/sh\necho \"$PWD $*\" >> %s\n%s\n"
         (Filename.quote (base ^/ "calls"))
         body);
  Core_unix.chmod path ~perm:0o755;
  path
;;

let calls ~base =
  match In_channel.read_lines (base ^/ "calls") with
  | lines -> lines
  | exception Sys_error _ -> []
;;

let listing root = List.sort (Sys_unix.ls_dir root) ~compare:String.compare

let prepare_exn ~root ?(args = []) ?discovery_timeout_seconds executable =
  match
    Simulation_setup.prepare
      ~root
      ~provider_executable:executable
      ~provider_args:args
      ?discovery_timeout_seconds
      ()
  with
  | Ok plan -> plan
  | Error message -> failwith message
;;

let contains text fragment = String.is_substring text ~substring:fragment

let assert_contains text fragments =
  List.iter fragments ~f:(fun fragment ->
    if not (contains text fragment) then raise_s [%message "missing" fragment text])
;;

let catalog =
  "((protocol_version 1)(suites(((id counter)(label Counter)(cases(((id \
   increments)(label Increments))((id wraps)(label \\\"Wraps \
   around\\\"))))(parameters(((key cycles)(label Cycles)(default \
   100)(choices()))))(default_seed 42)))))"
;;

let%test_unit "generated configuration round-trips through the strict parser" =
  with_project (fun ~base:_ ~root ->
    List.iter
      [ []
      ; [ "--counter"; "/abs/counter.exe" ]
      ; [ "with space"; "quote\"d"; "(paren)"; ""; "semi;colon"; "caf\xc3\xa9" ]
      ; List.init 32 ~f:Int.to_string
      ]
      ~f:(fun args ->
        let plan =
          prepare_exn ~root ~args ~discovery_timeout_seconds:60 "/opt/provider dir/p.exe"
        in
        let expected : Config.t =
          { schema_version = 1
          ; provider_executable = "/opt/provider dir/p.exe"
          ; provider_args = args
          ; discovery_timeout_seconds = 60
          ; run_timeout_seconds = Simulation_setup.default_run_timeout_seconds
          }
        in
        [%test_eq: Config.t] (Simulation_setup.config plan) expected;
        [%test_eq: Config.t]
          (Config.parse_string (Simulation_setup.contents plan) |> Or_error.ok_exn)
          expected);
    [%test_eq: string list] (listing root) [ "dune-project" ])
;;

let%test_unit "invalid inputs are rejected before anything is written" =
  with_project (fun ~base:_ ~root ->
    let rejected ?(args = []) ?discovery ?run ?(root = root) executable fragment =
      match
        Simulation_setup.prepare
          ~root
          ~provider_executable:executable
          ~provider_args:args
          ?discovery_timeout_seconds:discovery
          ?run_timeout_seconds:run
          ()
      with
      | Ok _ -> raise_s [%message "accepted" executable]
      | Error message -> assert_contains message [ fragment ]
    in
    rejected "provider.exe" "must be an absolute path";
    rejected "./bin/provider.exe" "must be an absolute path";
    rejected "/p" ~discovery:0 "1..60";
    rejected "/p" ~discovery:61 "1..60";
    rejected "/p" ~run:0 "1..86400";
    rejected "/p" ~run:86_401 "1..86400";
    rejected "/p" ~args:(List.init 33 ~f:Int.to_string) "32 arguments";
    rejected "/p" ~args:[ "nul\000byte" ] "Invalid simulation provider argument";
    rejected "/p" ~root:(root ^/ "missing") "No such file";
    Core_unix.mkdir (root ^/ "sub");
    Out_channel.write_all (root ^/ "sub" ^/ "dune") ~data:"";
    rejected "/p" ~root:(root ^/ "sub") "must directly contain a regular dune-project";
    Core_unix.unlink (root ^/ "sub" ^/ "dune");
    Core_unix.rmdir (root ^/ "sub");
    [%test_eq: string list] (listing root) [ "dune-project" ])
;;

let%test_unit "preview names the destination, fields and provider state; prepare runs \
               nothing"
  =
  with_project (fun ~base ~root ->
    let executable = provider ~base "p.sh" ~body:"exit 0" in
    let plan = prepare_exn ~root ~args:[ "--flag"; "a b" ] executable in
    let preview = Simulation_setup.preview plan in
    assert_contains
      preview
      [ "Destination:               " ^ root ^/ Config.filename
      ; "never overwritten"
      ; "provider_executable:       " ^ executable
      ; "exists and is executable"
      ; "provider_args:             --flag 'a b'"
      ; "discovery_timeout_seconds: 10"
      ; "run_timeout_seconds:       300"
      ; Simulation_setup.contents plan
      ];
    let missing = prepare_exn ~root (base ^/ "bin" ^/ "not-built.exe") in
    assert_contains (Simulation_setup.preview missing) [ "does not exist yet" ];
    Core_unix.chmod executable ~perm:0o644;
    assert_contains
      (Simulation_setup.preview (prepare_exn ~root executable))
      [ "not executable" ];
    [%test_eq: string list] (calls ~base) [];
    [%test_eq: string list] (listing root) [ "dune-project" ])
;;

let%test_unit "existing destinations, including links and directories, are refused" =
  with_project (fun ~base ~root ->
    let path = root ^/ Config.filename in
    List.iter
      [ `File "user config\n"
      ; `File ""
      ; `Directory
      ; `Symlink (base ^/ "missing")
      ; `Symlink (root ^/ "dune-project")
      ]
      ~f:(fun occupant ->
        (match occupant with
         | `File data -> Out_channel.write_all path ~data
         | `Directory -> Core_unix.mkdir path
         | `Symlink target -> Core_unix.symlink ~target ~link_name:path);
        (match
           Simulation_setup.prepare ~root ~provider_executable:"/p" ~provider_args:[] ()
         with
         | Ok _ -> failwith "occupied destination accepted"
         | Error message -> assert_contains message [ "refusing to overwrite"; path ]);
        match occupant with
        | `File data ->
          [%test_eq: string] (In_channel.read_all path) data;
          Core_unix.unlink path
        | `Directory -> Core_unix.rmdir path
        | `Symlink target ->
          [%test_eq: string] (Core_unix.readlink path) target;
          Core_unix.unlink path);
    [%test_eq: string] (In_channel.read_all (root ^/ "dune-project")) "(lang dune 3.22)\n")
;;

let%test_unit "publication is no-clobber even against a writer racing after preview" =
  with_project (fun ~base ~root ->
    let plan = prepare_exn ~root "/p" in
    let path = Simulation_setup.path plan in
    Core_unix.symlink ~target:(base ^/ "elsewhere") ~link_name:path;
    assert (Result.is_error (Simulation_setup.publish plan));
    [%test_eq: string] (Core_unix.readlink path) (base ^/ "elsewhere");
    Core_unix.unlink path;
    assert (Result.is_ok (Simulation_setup.publish plan));
    [%test_eq: string] (In_channel.read_all path) (Simulation_setup.contents plan);
    assert (Result.is_error (Simulation_setup.publish plan));
    [%test_eq: string] (In_channel.read_all path) (Simulation_setup.contents plan);
    [%test_eq: string list] (listing root) [ "dune-project"; Config.filename ])
;;

let configure ~root executable ?args ?discovery_timeout_seconds () =
  let plan = prepare_exn ~root ?args ?discovery_timeout_seconds executable in
  Simulation_setup.publish plan |> Result.ok_or_failwith
;;

let check root = Simulation_setup.check ~root ~environment:Inherit_daemon

let%test_unit "check: timeout covers child exit and inherited output pipes independently" =
  List.iter [ `Closed_streams; `Inherited_pipes ] ~f:(fun scenario ->
    with_project (fun ~base ~root ->
      let pid_path = base ^/ "pid" in
      let body =
        sprintf
          "echo $$ > %s\n%s"
          (Filename.quote pid_path)
          (match scenario with
           | `Closed_streams -> "exec 1>&- 2>&-\nexec sleep 10"
           | `Inherited_pipes -> "sleep 10 &\nexit 0")
      in
      configure ~root (provider ~base "p.sh" ~body) ~discovery_timeout_seconds:1 ();
      let pid () = In_channel.read_all pid_path |> String.strip |> Pid.of_string in
      Exn.protect
        ~f:(fun () ->
          let started = Time_ns.now () in
          let outcome = check root in
          let elapsed = Time_ns.diff (Time_ns.now ()) started in
          (match outcome with
           | Discovery_failed { reason; _ } ->
             [%test_eq: string] reason "discovery timed out after 1s"
           | _ -> failwith "expected discovery timeout");
          (* Generous scheduler allowance, but well below the fixture's sleep. *)
          assert (Time_ns.Span.(elapsed >= of_int_sec 1 && elapsed < of_int_sec 5));
          (* The direct child must already have been reaped, including when it exited
             before its descendant released the pipes. *)
          (match Core_unix.wait_nohang (`Pid (pid ())) with
           | exception Core_unix.Unix_error (ECHILD, _, _) -> ()
           | _ -> failwith "discovery child was not reaped");
          match scenario with
          | `Closed_streams ->
            assert (
              Poly.equal (Signal_unix.send Signal.zero (`Pid (pid ()))) `No_such_process)
          | `Inherited_pipes -> ())
        ~finally:(fun () ->
          if Sys_unix.file_exists_exn pid_path
          then
            ignore
              (Signal_unix.send Signal.kill (`Group (pid ()))
               : [ `Ok | `No_such_process ]))))
;;

let%test_unit "check: not configured and invalid configuration run no provider" =
  with_project (fun ~base ~root ->
    let path = root ^/ Config.filename in
    (match check root with
     | Not_configured { path = reported } -> [%test_eq: string] reported path
     | _ -> failwith "expected Not_configured");
    let executable = provider ~base "p.sh" ~body:"exit 0" in
    List.iter
      [ `Text "((schema_version 1))"
      ; `Text
          (sprintf
             "((schema_version 2)(provider_executable \
              %s)(provider_args())(discovery_timeout_seconds 10)(run_timeout_seconds \
              300))"
             executable)
      ; `Text
          (sprintf
             "((schema_version 1)(provider_executable \
              %s)(provider_args())(discovery_timeout_seconds 10)(run_timeout_seconds \
              300)(extra 1))"
             executable)
      ; `Symlink
      ]
      ~f:(fun bad ->
        (match bad with
         | `Text data -> Out_channel.write_all path ~data
         | `Symlink ->
           let real = base ^/ "real.sexp" in
           configure ~root executable ();
           Core_unix.rename ~src:path ~dst:real;
           Core_unix.symlink ~target:real ~link_name:path);
        let outcome = check root in
        assert (not (Outcome.ok outcome));
        (match outcome with
         | Invalid_configuration _ -> ()
         | _ -> failwith "expected Invalid_configuration");
        assert_contains (Outcome.render outcome) [ path; "edit or remove it explicitly" ];
        Core_unix.unlink path);
    [%test_eq: string list] (calls ~base) [])
;;

let%test_unit "check: discovered catalog lists every suite and case; only discover runs" =
  with_project (fun ~base ~root ->
    let executable =
      provider ~base "p.sh" ~body:(sprintf "echo diagnostic >&2\necho \"%s\"" catalog)
    in
    configure ~root executable ~args:[ "--prefix"; "two words" ] ();
    let outcome = check root in
    assert (Outcome.ok outcome);
    (match outcome with
     | Discovered { discovery; run } ->
       [%test_eq: int] (List.length discovery.suites) 1;
       [%test_eq: string list]
         run.argv
         [ executable; "--prefix"; "two words"; "discover"; "--protocol-version"; "1" ];
       [%test_eq: string] run.cwd root
     | _ -> failwith "expected Discovered");
    assert_contains
      (Outcome.render outcome)
      [ "Discovery succeeded: 1 suite, 2 cases."
      ; "suite counter - Counter (2 cases, default seed 42)"
      ; "parameter cycles - Cycles (default 100; any string)"
      ; "case increments - Increments"
      ; "case wraps - Wraps around"
      ; "Provider stderr:\ndiagnostic"
      ; "No tests were run"
      ];
    [%test_eq: string list]
      (calls ~base)
      [ root ^ " --prefix two words discover --protocol-version 1" ];
    [%test_eq: string list] (listing root) [ "dune-project"; Config.filename ])
;;

let%test_unit "check: configured with zero suites is distinct and successful" =
  with_project (fun ~base ~root ->
    configure
      ~root
      (provider ~base "p.sh" ~body:"echo '((protocol_version 1)(suites()))'")
      ();
    let outcome = check root in
    assert (Outcome.ok outcome);
    (match outcome with
     | Configured_empty _ -> ()
     | _ -> failwith "expected Configured_empty");
    assert_contains (Outcome.render outcome) [ "zero suites"; "No tests were run" ])
;;

let%test_unit "check: provider failures are reported with the provider's error" =
  with_project (fun ~base ~root ->
    let failed ~body ?discovery_timeout_seconds fragments =
      let path = root ^/ Config.filename in
      if Sys_unix.file_exists_exn path then Core_unix.unlink path;
      configure ~root (provider ~base "p.sh" ~body) ?discovery_timeout_seconds ();
      let outcome = check root in
      assert (not (Outcome.ok outcome));
      (match outcome with
       | Discovery_failed _ -> ()
       | _ -> raise_s [%message "expected Discovery_failed" body]);
      assert_contains (Outcome.render outcome) ("Discovery FAILED" :: fragments)
    in
    failed
      ~body:"echo 'counter.exe missing: run dune build' >&2; exit 3"
      [ "exited with status 3"; "counter.exe missing: run dune build" ];
    failed ~body:"echo '(not a catalog)'" [ "invalid discovery output" ];
    failed ~body:"echo '((protocol_version 2)(suites()))'" [ "invalid discovery output" ];
    failed ~body:"kill -9 $$" [ "killed by signal" ];
    failed
      ~body:"exec sleep 30"
      ~discovery_timeout_seconds:1
      [ "discovery timed out after 1s" ];
    failed
      ~body:"head -c 1100000 /dev/zero | tr '\\000' a"
      [ "discovery stdout exceeds 1 MiB" ];
    (* A provider that is configured but not built yet. *)
    let path = root ^/ Config.filename in
    Core_unix.unlink path;
    configure ~root (base ^/ "bin" ^/ "not-built.exe") ();
    let outcome = check root in
    assert_contains
      (Outcome.render outcome)
      [ "could not start " ^ base ^/ "bin" ^/ "not-built.exe"; "No such file" ])
;;
