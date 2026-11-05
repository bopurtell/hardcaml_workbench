open! Core
open! Async
open Hardcaml_workbench_protocol
module Backend = Hardcaml_workbench_backend.Simulation_service
module T = Terminal_presentation.Testing_workspace
module V = Terminal_presentation.Simulation_view
module S = Simulation

let main () =
  let root = Core_unix.mkdtemp "/tmp/opencode/pt8-handoff-capture-" in
  let backend = Backend.create ~state_dir:(Filename.concat root "state") in
  let project = Backend.project backend root in
  let dir = Filename.concat project.dir "entry" in
  let source = Filename.concat dir "work/artifacts" in
  Core_unix.mkdir_p source;
  let attempt : S.Attempt.t =
    { id = "sim-handoff"
    ; job = Job_id.of_string "job"
    ; project_root = root
    ; created_at = "now"
    ; parent = None
    ; captured =
        { selection =
            { suite = "pt8-memory-workloads"
            ; cases = [ "flops256"; "exact256" ]
            ; seed = "34097"
            ; parameters = []
            ; asic_inputs = []
            }
        ; discovery_digest = "discovery"
        ; provider_executable = "/fixture"
        ; provider_args = []
        ; environment = Inherit_daemon
        }
    ; lifecycle = Finished
    ; outcome = Passed
    ; exit_code = Some 0
    ; diagnostic = None
    ; progress = None
    ; cases =
        List.map [ "flops256"; "exact256" ] ~f:(fun case_id ->
          { S.Case_result.case_id; status = Passed; message = None; progress = None })
    ; artifacts = []
    ; next_sequence = 0
    ; recent_events = []
    ; execution_timing = None
    }
  in
  let entry : Backend.entry =
    { record = { schema_version = 1; submission_key = "capture"; payload = ""; attempt }
    ; dir
    }
  in
  Hashtbl.set project.entries ~key:attempt.id ~data:entry;
  let artifacts =
    List.map [ "flops256"; "exact256" ] ~f:(fun case_id ->
      let path = case_id ^ ".json" in
      let bytes =
        sprintf
          {|{"contract":"hardcaml-workbench.pt8-result-reference","schema_version":1,"result":"/retained/%s/result.json","source_digest":"%s"}|}
          case_id
          (String.make 64 'a')
      in
      Out_channel.write_all (Filename.concat source path) ~data:bytes;
      Backend.capture_artifact
        project
        entry
        { id = case_id ^ "-result-reference"
        ; case_id = Some case_id
        ; label = case_id
        ; kind = "json"
        ; media_type = "application/json"
        ; path
        })
  in
  let detail = { attempt with artifacts } in
  entry.record <- { entry.record with attempt = detail };
  let state detail case_id =
    let snapshot : S.Snapshot.t =
      { configured = true
      ; discovery = None
      ; discovery_digest = None
      ; discovery_job = None
      ; discovery_error = None
      ; attempts = []
      ; next_before = None
      ; detail = Some detail
      ; byte_page = None
      ; history_error = None
      }
    in
    T.set_view
      T.empty
      { V.empty with
        snapshot = Some snapshot
      ; attempt = Some detail.S.Attempt.id
      ; case_id = Some case_id
      }
  in
  let%bind () =
    Deferred.List.iter [ "flops256"; "exact256" ] ~how:`Sequential ~f:(fun case_id ->
      let t = state detail case_id in
      let artifact = Option.value_exn (T.workload_artifact t) in
      assert (String.equal artifact.id (attempt.id ^ "-" ^ case_id ^ "-result-reference"));
      let sha256 = Option.value_exn artifact.sha256 in
      let%map page =
        Backend.read_artifact
          project
          entry
          ~artifact_id:artifact.id
          ~sha256
          ~offset:0
          ~limit:16384
      in
      let bytes =
        Terminal_presentation.Simulation_export.validate artifact ~offset:0 page
        |> Or_error.ok_exn
      in
      let result, digest =
        Terminal_presentation.Workloads_view.reference bytes |> Or_error.ok_exn
      in
      assert (String.equal result ("/retained/" ^ case_id ^ "/result.json"));
      assert (String.equal digest (String.make 64 'a'));
      let module Workload = Terminal_presentation.Workloads_view in
      let inspected, _ =
        Workload.inspect Workload.empty result (Some digest) ~refresh:false
      in
      let browsing, _ = Workload.input inspected ~asic:None ~filter:"" Back in
      let _, reopened = Workload.input browsing ~asic:None ~filter:"" Open in
      (match reopened with
       | Some (Asic_workloads.Operation.Load { query = Inspect q; _ }) ->
         assert (Option.equal String.equal q.expected_digest (Some digest))
       | _ -> assert false);
      assert (Option.is_some (T.workload_artifact (T.select_artifact t artifact.id)));
      List.iter
        [ { artifact with id = "other-attempt-" ^ case_id ^ "-result-reference" }
        ; { artifact with attempt_id = "other-attempt" }
        ; { artifact with
            id =
              attempt.id
              ^ "-"
              ^ (if String.equal case_id "flops256" then "exact256" else "flops256")
              ^ "-result-reference"
          }
        ; { artifact with case_id = None }
        ; { artifact with id = case_id ^ "-result-reference" }
        ]
        ~f:(fun forged ->
          assert (
            Option.is_none
              (T.workload_artifact (state { detail with artifacts = [ forged ] } case_id)))))
  in
  printf
    "PT8 handoff: actual FS2 capture/read, both cases and attempt/case namespace \
     negatives passed\n\
     %!";
  Deferred.unit
;;

let () =
  don't_wait_for
    (Monitor.try_with main
     >>= function
     | Ok () -> Shutdown.exit 0
     | Error exn ->
       eprintf "%s\n%!" (Exn.to_string exn);
       Shutdown.exit 1);
  never_returns (Scheduler.go ())
;;
