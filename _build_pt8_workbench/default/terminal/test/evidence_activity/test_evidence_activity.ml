open! Core
open! Async
open Hardcaml_workbench_protocol
open Terminal_presentation
module Service = Hardcaml_workbench_backend.Asic_service
module Public = Hardcaml_workbench_backend.Asic_public
module Config = Hardcaml_workbench_project_integration.Asic_config
module H = Workspace_host

let environment = V1.Environment_selection.Inherit_daemon
let run = Fs0_fixture.run_a
let has text substring = String.is_substring text ~substring

let handle service root operation =
  Service.handle service ~root ~environment operation
  >>| function
  | Ok snapshot -> snapshot
  | Error error -> raise_s [%sexp (error : V1.Error.t)]
;;

let wait_started file =
  let rec loop () =
    if Poly.equal (Sys_unix.file_exists file) `Yes
    then Deferred.unit
    else Clock.after (Time_float.Span.of_ms 10.) >>= loop
  in
  match%map Clock.with_timeout (Time_float.Span.of_sec 5.) (loop ()) with
  | `Result () -> ()
  | `Timeout -> failwith "Held summary provider never started"
;;

let summary_refresh () =
  let root = Core_unix.mkdtemp "/tmp/workbench-evidence-activity-" in
  let file name = Filename.concat root name in
  let executable = file "provider" in
  Out_channel.write_all executable ~data:(In_channel.read_all "refresh_provider.py");
  Core_unix.chmod executable ~perm:0o700;
  let config : Config.t =
    { schema_version = 1
    ; project_executable = executable
    ; provider_executable = executable
    ; results_root = file "results"
    ; toolchain = file "toolchain"
    ; python = None
    ; support_tools = None
    ; pdk_root = None
    ; stage_timeout_seconds = None
    }
  in
  Out_channel.write_all
    (file Config.filename)
    ~data:(Sexp.to_string_mach (Config.sexp_of_t config));
  let identity =
    Sexp.to_string_mach
      [%sexp
        (root : string)
        , (environment : V1.Environment_selection.t)
        , (Some config : Config.t option)]
  in
  let state_dir = file "state" in
  Core_unix.mkdir_p state_dir ~perm:0o700;
  let registered =
    { (Fs0_fixture.run run) with execution_file = Some (file "execution.json") }
  in
  let summary =
    { (Fs0_fixture.summary run 50 [ "NAND2", 50 ]) with
      execution_file = Option.value_exn registered.execution_file
    }
  in
  let registry =
    Sexp.List
      [ [%sexp "version", (1 : int)]
      ; [%sexp "identity", (identity : string)]
      ; [%sexp "runs", ([ registered ] : Asic.Run.t list)]
      ; [%sexp "submissions", ([] : (string * Asic.Preview.t * string option) list)]
      ; [%sexp "index", ([ run.id, summary.source_digest ] : (string * string) list)]
      ]
  in
  let prefix = Filename.concat state_dir ("asic-" ^ Public.digest identity) in
  Out_channel.write_all (prefix ^ ".sexp") ~data:(Sexp.to_string_mach registry);
  let blob =
    Sexp.List
      [ [%sexp "version", (4 : int)]
      ; [%sexp
          "normalized_digest"
          , (Public.digest (Sexp.to_string_mach (Asic.Summary.sexp_of_t summary))
             : string)]
      ; [%sexp "summary", (summary : Asic.Summary.t)]
      ]
  in
  Out_channel.write_all
    (prefix ^ "-summary-v1-" ^ Public.digest summary.source_digest ^ ".summary.sexp")
    ~data:(Sexp.to_string_mach blob);
  Hardcaml_workbench_backend.Asic_inspection.save
    ~state_dir
    ~identity
    { (Evidence_activity.Test.index ()) with execution_file = summary.execution_file };
  let service = Service.create ~state_dir in
  let release () =
    if Poly.equal (Sys_unix.file_exists (file "hold")) `Yes
    then Core_unix.unlink (file "hold")
  in
  Monitor.protect
    ~finally:(fun () ->
      release ();
      Service.shutdown service)
    (fun () ->
      let%bind (_ : Asic.Snapshot.t) = handle service root (Load_summary run) in
      let%bind () = Service.completion service in
      let%bind cached = handle service root Get in
      assert (List.length cached.summaries = 1);
      assert (
        List.for_all cached.operations ~f:(fun op ->
          not (Asic.Pending.Activity.equal op.activity Evidence_read)));
      Out_channel.write_all (file "hold") ~data:"hold";
      let%bind (_ : Asic.Snapshot.t) = handle service root (Refresh run) in
      let%bind () = wait_started (file "started") in
      let host, data, find =
        Host_view.refinement_fixture Hardcaml_workbench_workspaces.Timing.definition
      in
      let session = find "live-status" in
      let render snapshot =
        Host_view.tile_view
          host
          { data with asic = Some snapshot }
          session
          ~width:80
          ~height:7
        |> Host_view.plain_text
      in
      let%bind () =
        Deferred.List.iter [ (); (); () ] ~how:`Sequential ~f:(fun () ->
          let%bind snapshot = handle service root Get in
          let pending =
            List.find_exn snapshot.operations ~f:(fun op ->
              String.equal op.kind "refresh")
          in
          assert (Option.equal Run_ref.equal pending.run (Some run));
          assert (Plain_rpc.active pending);
          assert (Asic.Pending.Activity.equal pending.activity Evidence_read);
          assert (has (render snapshot) "updating evidence · summary fixture-A");
          assert (Asic.Summary.equal (List.hd_exn snapshot.summaries) summary);
          assert (
            match
              Evidence_activity.summarize
                ~views:[]
                ~runs:[ Fs0_fixture.run_b ]
                (Some snapshot)
            with
            | Idle -> true
            | _ -> false);
          Clock.after (Time_float.Span.of_ms 20.))
      in
      release ();
      let%bind () = Service.completion service in
      let%bind failed = handle service root Get in
      let projection =
        Evidence_activity.summarize ~views:[] ~runs:[ run ] (Some failed)
      in
      let row = Evidence_activity.row projection in
      assert (
        match projection with
        | Not_updated [ _ ] -> true
        | _ -> false);
      assert (has (render failed) "Evidence: not updated:");
      assert (
        List.exists row.details ~f:(fun text ->
          has text "WB003 held summary provider failed"
          && has text "prior evidence kept: REFRESH FAILED"));
      assert (
        Option.equal
          Int.equal
          (List.hd_exn failed.summaries).cell_count
          summary.cell_count);
      printf
        "PASS: held backend summary refresh -> Session renderer -> failure/freshness\n";
      let%bind lookup =
        handle
          service
          root
          (Inspect { run; domain = "timing"; stage = "routing"; refresh = false })
      in
      let projection =
        Evidence_activity.summarize
          ~views:[ Evidence_activity.Test.view () ]
          ~runs:[ run ]
          (Some lookup)
      in
      assert (
        match projection with
        | Cache_lookup { lookups = 1; failures = [ _ ]; _ } -> true
        | _ -> false);
      assert (
        List.exists (Evidence_activity.row projection).details ~f:(fun text ->
          has text "WB003 held summary provider failed"
          && has text "prior evidence kept: REFRESH FAILED"));
      let%bind () = Service.completion service in
      let%map reopened = handle service root Get in
      let operation =
        List.find_exn reopened.operations ~f:(fun op -> String.equal op.kind "inspection")
      in
      assert (String.equal operation.state "completed");
      assert (Asic.Pending.Activity.equal operation.activity Evidence_cache_lookup);
      printf "PASS: backend warm lookup coexists with summary failure/freshness\n")
;;

(* Exercise the same receipt callback used by main.ml after a genuinely deferred result.
   Mutate the host while transport is outstanding, then deliver the old error. *)
let asynchronous_receipts () =
  let initial, _, find =
    Host_view.refinement_fixture Hardcaml_workbench_workspaces.Timing.definition
  in
  let tile = find "timing-detail" in
  let view =
    Inspection_view.create ~generation:1 ~run ~domain:"timing" ~stage:"routing" ()
  in
  let initial =
    H.set_local initial tile.id { (H.local initial tile.id) with inspection = Some view }
  in
  let ticket = Inspection_view.capture view (Inspection_view.operation view) in
  let identity = (H.local initial tile.id).identity in
  let check ~publish_notice ~accepted mutate =
    let host = ref { initial with notice = "newer notice" } in
    let response = Ivar.create () in
    let callback =
      let%map response = Ivar.read response in
      host
      := Evidence_activity.inspection_receipt
           !host
           ~tile_id:tile.id
           ~identity
           ~ticket
           ~publish_notice
           response
    in
    host := mutate !host;
    Ivar.fill_exn response (Error "late transport failure");
    let%map () = callback in
    assert (
      String.equal
        !host.notice
        (if accepted && publish_notice
         then "ASIC: late transport failure"
         else "newer notice"));
    Option.iter (H.inspection !host tile.id) ~f:(fun view ->
      assert (Bool.equal (Option.is_some view.error) accepted))
  in
  let replace f host = H.set_inspection host tile.id (Some (f view)) in
  let%bind () = check ~publish_notice:true ~accepted:true Fn.id in
  let%bind () = check ~publish_notice:false ~accepted:true Fn.id in
  let%bind () =
    check ~publish_notice:true ~accepted:false (fun host ->
      H.set_inspection host tile.id None)
  in
  let%bind () =
    check
      ~publish_notice:true
      ~accepted:false
      (replace (fun view -> { view with generation = view.generation + 1 }))
  in
  let%bind () =
    check
      ~publish_notice:true
      ~accepted:false
      (replace (fun view -> { view with stage = "signoff" }))
  in
  let%bind () =
    check
      ~publish_notice:true
      ~accepted:false
      (replace (fun view -> { view with workspace_epoch = Some "new epoch" }))
  in
  let%bind () =
    check ~publish_notice:true ~accepted:false (fun host ->
      H.set_local host tile.id { (H.local host tile.id) with identity = ref () })
  in
  printf
    "PASS: deferred inspection receipts fence close/reopen, generation, selection, epoch \
     and notice order\n";
  Deferred.unit
;;

let () =
  Command.async
    ~summary:"WB003 backend-to-Session and asynchronous receipt regressions"
    (Command.Param.return (fun () -> summary_refresh () >>= asynchronous_receipts))
  |> Command_unix.run
;;
