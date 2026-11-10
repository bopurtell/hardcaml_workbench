open! Core
open Hardcaml_workbench_protocol
module T = Terminal_presentation.Testing_workspace
module V = Terminal_presentation.Simulation_view
module E = Terminal_presentation.Simulation_export
module W = Terminal_presentation.Waveform_view
module S = Simulation
module Pins = Hardcaml_workbench_workspaces.Waveforms
module H = Terminal_presentation.Workspace_host
module HV = Terminal_presentation.Host_view

let checks = ref []
let check name passed = checks := (name, passed) :: !checks

let wave : S.Artifact.t =
  { id = "attempt-flops256-waveform"; attempt_id = "attempt"; case_id = Some "flops256"
  ; label = "flops"; kind = "trace"; media_type = "text/vcd"
  ; size = Some 100; sha256 = Some (String.make 64 'a'); availability = Available }
;;

let attempt artifacts : S.Attempt.t =
  { id = "attempt"; job = Job_id.of_string "job-attempt"; project_root = "/private"
  ; created_at = "now"; parent = None
  ; captured = { selection = { suite = "pt8-memory-workloads"
      ; cases = ["flops256"; "exact256"]; seed = "34097"; parameters = []; asic_inputs = [] }
      ; discovery_digest = "discovery"; provider_executable = "/fixture"; provider_args = []
      ; environment = Inherit_daemon }
  ; lifecycle = Finished; outcome = Passed; exit_code = Some 0; diagnostic = None
  ; progress = None
  ; cases = List.map ["flops256"; "exact256"] ~f:(fun case_id ->
      { S.Case_result.case_id; status = Passed; message = None; progress = None })
  ; artifacts; next_sequence = 0; recent_events = []; execution_timing = None }
;;

let snapshot artifacts : S.Snapshot.t =
  { configured = true; discovery = None; discovery_digest = None; discovery_job = None
  ; discovery_error = None; attempts = []; next_before = None
  ; detail = Some (attempt artifacts); byte_page = None; history_error = None }
;;

let view artifacts =
  { V.empty with snapshot = Some (snapshot artifacts); attempt = Some "attempt"
  ; case_id = Some "flops256" }
;;
let state artifacts = T.set_view T.empty (view artifacts)
let chooses t a = Option.equal S.Artifact.equal (T.waveform_artifact t) (Some a)
let no_wave t = Option.is_none (T.waveform_artifact t)

let () =
  let json = { wave with id = "attempt-flops256-result-reference"; kind = "json"
                      ; media_type = "application/json" } in
  let exact = { wave with id = "attempt-exact256-waveform"; case_id = Some "exact256" } in
  let mixed = T.select_artifact (state [json; wave; exact]) json.id in
  check "JSON cursor opens same-case sibling VCD" (chooses mixed wave);
  check "JSON cursor remains unchanged" (Option.equal String.equal (T.selected_artifact mixed) (Some json.id));
  let host t =
    let h, _, find = HV.refinement_fixture Hardcaml_workbench_workspaces.Testing.definition in
    let tile = find "simulation-artifacts" in
    let h = H.set_simulation {h with focus = Some tile.id} tile.id (T.view t) in
    H.update_testing h tile.id (fun _ -> t), tile
  in
  let commands t =
    let h, tile = host t in
    H.simulation_selection_commands h tile ~submission_key:(fun _ -> "review")
    |> List.filter_map ~f:(fun c -> match c.H.action with
       | Simulation_waveform a | Simulation_waveform_workspace a -> Some a
       | _ -> None)
  in
  check "host actions only selected-case VCD" (List.length (commands mixed) = 2
    && List.for_all (commands mixed) ~f:(S.Artifact.equal wave));
  let h, _ = host mixed in
  check "host w uses sibling VCD while e uses JSON"
    (Option.equal String.equal (H.testing_shortcut h 'w') (Some ("simulation.waveform." ^ wave.id))
     && Option.equal String.equal (H.testing_shortcut h 'e') (Some ("simulation.export." ^ json.id)));
  check "JSON independently inspectable" (Option.equal S.Artifact.equal (T.workload_artifact mixed) (Some json));
  check "JSON-only unavailable" (no_wave (state [json]));
  check "JSON-only truthful reason" (Option.exists (T.waveform_unavailable (state [json]))
    ~f:(fun s -> String.is_substring s ~substring:"No available supported VCD"));
  check "other case never changes default" (no_wave (state [json; exact]));
  check "explicit case switch routes exact" (chooses (T.select_case mixed "exact256") exact);
  let variants =
    [ "wrong attempt same artifact id", {wave with attempt_id = "other"}
    ; "wrong case same artifact id", {wave with case_id = Some "exact256"}
    ; "missing case metadata same artifact id", {wave with case_id = None}
    ; "missing size", {wave with size = None}
    ; "negative size", {wave with size = Some (-1)}
    ; "zero size", {wave with size = Some 0}
    ; "oversize", {wave with size = Some (8 * 1024 * 1024 + 1)}
    ; "missing digest", {wave with sha256 = None}
    ; "uppercase digest", {wave with sha256 = Some (String.make 64 'A')}
    ; "short digest", {wave with sha256 = Some "a"}
    ; "nonhex digest", {wave with sha256 = Some (String.make 64 'g')}
    ; "missing availability", {wave with availability = Missing}
    ; "changed availability", {wave with availability = Changed}
    ; "misleading MIME", {wave with media_type = "application/not-vcd-json"}
    ; "JSON suffix illusion", {wave with id = "looks.vcd"; media_type = "application/json"}
    ; "FST", {wave with media_type = "application/fst"}
    ] in
  List.iter variants ~f:(fun (name, a) ->
    check name (no_wave (state [json; a]));
    check ("host action rejects " ^ name) (List.is_empty (commands (state [json; a]))));
  let uncaptured = attempt [wave] in
  let uncaptured = {uncaptured with captured = {uncaptured.captured with
      selection = {uncaptured.captured.selection with cases = ["exact256"]}}} in
  let inconsistent_view = { (view [wave]) with snapshot = Some {(snapshot [wave]) with detail = Some uncaptured}} in
  let inconsistent = T.set_view T.empty inconsistent_view in
  check "selector rejects case absent from captured selection" (no_wave inconsistent);
  check "host action must reject case absent from captured selection" (List.is_empty (commands inconsistent));
  List.iter ["text/vcd"; "application/vcd"; "application/x-vcd"; "TEXT/VCD"] ~f:(fun media_type ->
    let a = {wave with media_type; id = "no-filename-suffix"} in
    check ("MIME allowed: " ^ media_type) (chooses (state [a]) a));
  List.iter ["text/vcd; charset=utf-8"; "text/vcd "; "application/vnd.gtkwave.vcd"] ~f:(fun media_type ->
    check ("MIME deliberately unsupported: " ^ media_type)
      (Or_error.is_error (E.embedded_vcd {wave with media_type})));
  check "8MiB boundary admitted" (Or_error.is_ok (E.embedded_vcd {wave with size = Some (8 * 1024 * 1024)}));
  check "general export suffix separate from admission"
    (String.equal (E.suffix {wave with media_type = "application/not-vcd-json"}) ".vcd"
     && Or_error.is_error (E.embedded_vcd {wave with media_type = "application/not-vcd-json"}));
  let restore artifacts =
    T.restore_selection T.empty ~attempt:"attempt" ~case_id:(Some "flops256")
      ~artifact:(Some {id = wave.id; sha256 = wave.sha256; size = wave.size})
    |> fun t -> T.set_view t (view artifacts)
  in
  let later = {wave with id = "later-generation"; sha256 = Some (String.make 64 'b')} in
  List.iter
    ["restored missing", [later]
    ; "restored digest changed", [{wave with sha256 = later.sha256}; later]
    ; "restored size changed", [{wave with size = Some 101}; later]
    ; "restored unavailable", [{wave with availability = Changed}; later]]
    ~f:(fun (name, artifacts) -> check name (no_wave (restore artifacts)));
  check "restored exact identity remains usable" (chooses (restore [wave; later]) wave);
  (* Independent metadata-only drift probes: bytes/id/size unchanged. These must
     not silently replace the saved artifact with another generation. *)
  List.iter
    [ "restored case drift must not retarget", {wave with case_id = Some "exact256"}
    ; "restored missing case must not retarget", {wave with case_id = None}
    ; "restored MIME drift must not retarget", {wave with media_type = "application/json"} ]
    ~f:(fun (name, changed) -> check name (no_wave (restore [changed; later])));
  let picker = W.picker_candidates ~attempt:"attempt" ~case_id:(Some "flops256")
    [wave; exact; {wave with attempt_id = "other"}; {wave with case_id = None}; json] in
  check "picker exact attempt/case/MIME" (List.equal S.Artifact.equal picker [wave]);
  check "picker bounded128" (List.length (W.picker_candidates ~attempt:"attempt"
    ~case_id:(Some "flops256") (List.init 200 ~f:(fun _ -> wave))) = 128);
  let changed_hash = {wave with sha256 = later.sha256} in
  check "changed digest does not mark old picker pin" (not (W.picker_matches_pin ~pinned:wave changed_hash));
  check "case metadata drift does not mark old picker pin"
    (not (W.picker_matches_pin ~pinned:wave {wave with case_id = Some "exact256"}));
  let pending = T.begin_request mixed in
  let next = T.select_attempt pending "new-attempt" in
  let received = T.receive next ~ticket:(T.view pending).request ~selected:(Some "attempt")
    (Observe "attempt") (Ok (snapshot [wave])) in
  check "late old attempt receipt ignored"
    (Option.equal String.equal (T.view received).attempt (Some "new-attempt") && no_wave received);
  let data = "abc" in
  let a = {wave with size = Some 3; sha256 = Some (Terminal_presentation.Plain_rpc.digest data)} in
  let page : S.Byte_page.t = {attempt_id = a.attempt_id; artifact_id = a.id
    ; sha256 = Option.value_exn a.sha256; offset = 0; next_offset = 3; total_size = 3
    ; eof = true; bytes_hex = "616263"} in
  check "exact byte page accepted" (Or_error.is_ok (E.validate a ~offset:0 page));
  List.iter ["page wrong attempt", {page with attempt_id = "other"}
    ; "page wrong id", {page with artifact_id = "other"}
    ; "page digest drift", {page with sha256 = String.make 64 'b'}
    ; "page wrong size", {page with total_size = 4}]
    ~f:(fun (name, p) -> check name (Or_error.is_error (E.validate a ~offset:0 p)));
  let instance = V1.Daemon_instance_id.of_string "instance-a" in
  let pin : Pins.pin = { project_key = "private"; project = Project_id.of_string "project"
    ; artifact = wave; log = Job {instance_id = instance; job = Job_id.of_string "job-attempt"}} in
  check "logs remain attempt-wide exact job" (Result.equal Job_id.equal Error.equal
    (Pins.log_job pin ~instance_id:instance) (Ok (Job_id.of_string "job-attempt")));
  check "logs never substitute restarted daemon job" (Or_error.is_error
    (Pins.log_job pin ~instance_id:(V1.Daemon_instance_id.of_string "instance-b")));
  List.iter (List.rev !checks) ~f:(fun (name, passed) ->
    printf "%s %s\n" (if passed then "PASS" else "FINDING") name);
  printf "TOTAL %d FINDINGS %d\n" (List.length !checks)
    (List.count !checks ~f:(fun (_, passed) -> not passed))
;;
