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
  (* Capture through the actual FS2 public namespace boundary, then drive the production
     selectors/catalog with mixed and adversarial observations. *)
  let vcd_text =
    "$timescale 1 ns $end\n$scope module top $end\n$var wire 1 ! clk $end\n"
    ^ "$upscope $end\n$enddefinitions $end\n#0\n0!\n#5\n1!\n#10\n0!\n"
  in
  let waves =
    List.map [ "flops256"; "exact256" ] ~f:(fun case_id ->
      let path = case_id ^ ".vcd" in
      Out_channel.write_all (Filename.concat source path) ~data:vcd_text;
      Backend.capture_artifact
        project
        entry
        { id = case_id ^ "-waveform"
        ; case_id = Some case_id
        ; label = case_id ^ " waves"
        ; kind = "trace"
        ; media_type = "text/vcd"
        ; path
        })
  in
  List.iter [ "flops256"; "exact256" ] ~f:(fun case_id ->
    let json_only = state detail case_id in
    assert (Option.is_none (T.waveform_artifact json_only));
    assert (Option.is_some (T.waveform_unavailable json_only));
    assert (Option.is_some (T.workload_artifact json_only));
    let wave =
      List.find_exn waves ~f:(fun a -> Option.equal String.equal a.case_id (Some case_id))
    in
    assert (String.equal wave.id (attempt.id ^ "-" ^ case_id ^ "-waveform"));
    let mixed_detail = { detail with artifacts = artifacts @ List.rev waves } in
    let mixed = state mixed_detail case_id in
    assert (Option.equal S.Artifact.equal (T.waveform_artifact mixed) (Some wave));
    let reference = Option.value_exn (T.workload_artifact mixed) in
    let mixed = T.select_artifact mixed reference.id in
    assert (Option.equal S.Artifact.equal (T.waveform_artifact mixed) (Some wave));
    assert (Option.equal S.Artifact.equal (T.artifact mixed) (Some reference));
    let other = List.find_exn waves ~f:(fun a -> not (S.Artifact.equal a wave)) in
    List.iter
      [ { wave with attempt_id = "another-attempt" }
      ; { wave with case_id = other.case_id }
      ; { wave with case_id = None }
      ; { wave with media_type = "application/json" }
      ; { wave with media_type = "application/not-vcd-json" }
      ; { wave with availability = Missing }
      ; { wave with availability = Changed }
      ; { wave with availability = Rejected "bad declaration" }
      ; { wave with size = None }
      ; { wave with size = Some 0 }
      ; { wave with size = Some ((8 * 1024 * 1024) + 1) }
      ; { wave with sha256 = None }
      ; { wave with sha256 = Some (String.make 64 'A') }
      ]
      ~f:(fun bad ->
        let t = state { detail with artifacts = artifacts @ [ other; bad ] } case_id in
        assert (Option.is_none (T.waveform_artifact t)));
    let restored =
      T.restore_selection
        T.empty
        ~attempt:attempt.id
        ~case_id:(Some case_id)
        ~artifact:(Some { id = wave.id; size = wave.size; sha256 = wave.sha256 })
    in
    let restored = T.set_view restored (T.view mixed) in
    assert (Option.is_some (T.waveform_artifact restored));
    let changed = { wave with sha256 = Some (String.make 64 'b') } in
    let changed_view =
      T.view (state { detail with artifacts = [ changed; other ] } case_id)
    in
    assert (Option.is_none (T.waveform_artifact (T.set_view restored changed_view)));
    let waiting = T.select_attempt mixed "new-attempt" |> T.begin_request in
    let late =
      T.receive
        waiting
        ~ticket:(T.view mixed).request
        ~selected:(Some attempt.id)
        (Observe attempt.id)
        (Ok (Option.value_exn (T.view mixed).snapshot))
    in
    assert (Option.is_none (T.waveform_artifact late));
    let module H = Terminal_presentation.Workspace_host in
    let module HV = Terminal_presentation.Host_view in
    let host, _, find =
      HV.refinement_fixture Hardcaml_workbench_workspaces.Testing.definition
    in
    let tile = find "simulation-artifacts" in
    let host =
      H.set_simulation { host with focus = Some tile.id } tile.id (T.view mixed)
    in
    let host =
      H.update_testing host tile.id (fun t -> T.select_artifact t reference.id)
    in
    let commands =
      H.simulation_selection_commands host tile ~submission_key:(fun _ -> "key")
    in
    let waveform_commands =
      List.filter_map commands ~f:(fun c ->
        match c.H.action with
        | Simulation_waveform a | Simulation_waveform_workspace a -> Some a
        | _ -> None)
    in
    assert (List.length waveform_commands = 2);
    assert (List.for_all waveform_commands ~f:(S.Artifact.equal wave));
    assert (
      Option.equal
        String.equal
        (H.testing_shortcut host 'w')
        (Some ("simulation.waveform." ^ wave.id)));
    assert (
      Option.equal
        String.equal
        (H.testing_shortcut host 'e')
        (Some ("simulation.export." ^ reference.id)));
    let sibling =
      { wave with id = wave.id ^ "-later"; sha256 = Some (String.make 64 'b') }
    in
    let commands_for t =
      let host = H.update_testing host tile.id (fun _ -> t) in
      H.simulation_selection_commands host tile ~submission_key:(fun _ -> "key")
      |> List.filter ~f:(fun c ->
        match c.H.action with
        | Simulation_waveform _ | Simulation_waveform_workspace _ -> true
        | _ -> false)
    in
    List.iter [ None; Some wave ] ~f:(fun metadata ->
      List.iter
        [ { wave with case_id = None }
        ; { wave with case_id = other.case_id }
        ; { wave with media_type = "application/json" }
        ]
        ~f:(fun drift ->
          let saved =
            T.restore_selection
              ?metadata
              T.empty
              ~attempt:attempt.id
              ~case_id:(Some case_id)
              ~artifact:(Some { id = wave.id; sha256 = wave.sha256; size = wave.size })
          in
          let view =
            T.view (state { detail with artifacts = [ drift; sibling ] } case_id)
          in
          let t = T.set_view saved view in
          assert (Option.is_none (T.waveform_artifact t));
          assert (Option.is_some (T.waveform_unavailable t));
          assert (List.is_empty (commands_for t));
          assert (Option.equal String.equal (T.selected_artifact t) (Some wave.id));
          assert (String.equal (Option.value_exn (T.artifact_identity t)).id wave.id)));
    let multiple =
      state { detail with artifacts = [ wave; sibling; reference ] } case_id
    in
    assert (List.length (commands_for multiple) = 4);
    let selection = detail.captured.selection in
    List.iter
      [ { detail with
          captured =
            { detail.captured with
              selection =
                { selection with
                  cases =
                    List.filter selection.cases ~f:(fun c -> not (String.equal c case_id))
                }
            }
        ; artifacts = [ wave ]
        }
      ; { detail with
          cases =
            List.filter detail.cases ~f:(fun c -> not (String.equal c.case_id case_id))
        ; artifacts = [ wave ]
        }
      ]
      ~f:(fun malformed ->
        let t = state malformed case_id in
        assert (Option.is_none (T.waveform_artifact t));
        assert (List.is_empty (commands_for t)));
    let module N = Terminal_presentation.Navigation_preferences in
    let selected = H.update_testing host tile.id (fun t -> T.select_artifact t wave.id) in
    let saved =
      H.navigation_preferences ~project_key:"metadata-test" selected |> Option.value_exn
    in
    let saved = N.decode ~project_key:"metadata-test" (N.encode saved) in
    let restored_host =
      H.restore_navigation_selections
        saved
        { selected with testing = [] }
        ~scope:"metadata-test"
    in
    let drift = { wave with media_type = "application/json" } in
    let restored_host =
      H.set_simulation
        restored_host
        tile.id
        (T.view (state { detail with artifacts = [ drift; sibling ] } case_id))
    in
    let t = H.testing_state restored_host tile.id in
    assert (Option.is_none (T.artifact t));
    assert (Option.is_none (T.waveform_artifact t));
    assert (List.is_empty (commands_for t));
    assert (Option.equal S.Artifact.equal (T.artifact_metadata t) (Some wave));
    let explicit = T.select_artifact t sibling.id in
    assert (Option.equal S.Artifact.equal (T.waveform_artifact explicit) (Some sibling));
    (* Legitimately saved JSON retains its separate cursor and same-case VCD action. *)
    let json =
      T.restore_selection
        ~metadata:reference
        T.empty
        ~attempt:attempt.id
        ~case_id:(Some case_id)
        ~artifact:
          (Some { id = reference.id; sha256 = reference.sha256; size = reference.size })
    in
    let json = T.set_view json (T.view multiple) in
    assert (Option.is_some (T.waveform_artifact json)));
  let%bind () =
    Deferred.List.iter waves ~how:`Sequential ~f:(fun wave ->
      entry.record
      <- { entry.record with attempt = { detail with artifacts = artifacts @ waves } };
      let%map page =
        Backend.read_artifact
          project
          entry
          ~artifact_id:wave.id
          ~sha256:(Option.value_exn wave.sha256)
          ~offset:0
          ~limit:16384
      in
      let bytes =
        Terminal_presentation.Simulation_export.validate wave ~offset:0 page
        |> Or_error.ok_exn
      in
      assert (String.equal bytes vcd_text);
      assert (Or_error.is_ok (Terminal_presentation.Waveform_data.parse bytes)))
  in
  printf
    "Waveform handoff: real FS2 prefix/read/parse, JSON-only, mixed, exact case/attempt, \
     bad metadata, restored digest, late replies and production catalog/shortcuts passed\n\
     %!";
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
