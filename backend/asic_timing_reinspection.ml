open! Core
module I = Asic_inspection
open Hardcaml_workbench_protocol
module P = Asic_public
module W = Hardcaml_workbench_protocol.Asic_inspection
module R = W.Reinspection
module Timing = Asic_timing_analysis

let canonical j = Yojson.Safe.to_string (P.canonical_json j)

let supported metadata =
  let c = P.field "timing_reinspection1" (P.field "capabilities" (P.field "cli_contract" metadata)) in
  match c with
  | `Null -> false
  | _ ->
    P.require
      (Poly.equal (P.field "schema_version" c) (`Int 1)
       && Poly.equal (P.field "read_only" c) (`Bool true)
       && Poly.equal (P.field "option" c) (`String "--refresh-timing")
       && Poly.equal (P.field "original_observation_mutated" c) (`Bool false))
      "Unsupported timing_reinspection1 capability";
    true
;;

let observation_path ~execution_file ~stage =
  let prefix = execution_file ^ ".timing-source.timing-analysis.json" in
  if String.equal stage "timing" && Poly.equal (Sys_unix.file_exists prefix) `Yes
  then prefix
  else execution_file ^ ".timing-analysis.json"
;;

let original ~registered ~execution_file ~execution_sha256 ~stage =
  let path = observation_path ~execution_file ~stage in
  P.require (String.equal (Filename_unix.realpath path) path) "Reinspection observation alias";
  let bytes = Asic_evidence_file.read_bounded path (1024 * 1024) in
  let raw = P.decode bytes in
  let analysis = Timing.parse ~registered ~execution_file ~execution_sha256
      (`Assoc [ "timing_analysis", raw; "execution", `Assoc [ "status", P.field "enclosing_status" raw ] ])
    |> Option.value_exn in
  P.require (String.equal analysis.target.stage stage) "Reinspection original stage mismatch";
  P.require (String.equal path
    (Option.value analysis.target.execution_file ~default:execution_file ^ ".timing-analysis.json"))
    "Reinspection original observation association";
  raw, analysis, path, P.digest bytes
;;

let marker (index : W.Index.t) = R.of_diagnostics index.diagnostics

let matches (index : W.Index.t) target =
  Option.equal W.Analysis_target.equal index.analysis (Some target)
  || Option.exists (marker index) ~f:(fun r ->
    W.Analysis_target.equal r.original target
    && Option.equal W.Analysis_target.equal index.analysis (Some r.recomputed))
;;

let validate ~registered ~execution_file ~execution_sha256 ~stage ~expected response =
  let old, original, path, observation_sha256 =
    original ~registered ~execution_file ~execution_sha256 ~stage in
  Option.iter expected ~f:(fun target ->
    P.require (W.Analysis_target.equal target original.target) "Reinspection original target mismatch");
  let lineage = P.field "reinspection" response in
  P.require (Poly.equal (P.field "mode" lineage) (`String "read_only_reinspection"))
    "Missing explicit timing reinspection lineage";
  let ref_ = P.field "original_observation" lineage in
  P.require
    (Poly.equal (P.field "path" ref_) (`String path)
     && Poly.equal (P.field "sha256" ref_) (`String observation_sha256)
     && Poly.equal (P.field "original_analysis_digest" lineage) (`String original.target.source_digest)
     && Poly.equal (P.field "original_status" lineage) (P.field "status" old)
     && Poly.equal (P.field "original_timing_goal" lineage) (P.field "timing_goal" old))
    "Timing reinspection original observation/digest lineage mismatch";
  let raw = P.field "recomputed_analysis" lineage in
  let inventory = P.list (P.field "inventory" raw) in
  List.iter (P.list (P.field "inventory" old)) ~f:(fun prior ->
    List.iter inventory ~f:(fun current ->
      if Poly.equal (P.field "path" prior) (P.field "path" current) then
        P.require (Poly.equal (P.field "sha256" prior) (P.field "sha256" current))
          "Reinspection changed a historically captured source hash"));
  List.iter [ "execution_file"; "execution_sha256"; "attempt_id"; "occurrence_id";
              "analysis_id"; "stage"; "request_id"; "request_sha256"; "request"; "transport_terminal" ]
    ~f:(fun key -> P.require (String.equal (canonical (P.field key raw)) (canonical (P.field key old)))
      ("Timing reinspection association mismatch: " ^ key));
  let analysis = Timing.parse ~registered ~execution_file ~execution_sha256
    (`Assoc [ "timing_analysis", raw; "execution", `Assoc [ "status", P.field "enclosing_status" raw ] ])
    |> Option.value_exn in
  let goal = match analysis.timing_goal with
    | Asic.Timing_analysis.Goal.Pass -> "pass" | Fail -> "fail" | Unknown -> "unknown" in
  P.require (Poly.equal (P.field "timing_goal" raw) (`String goal))
    "Reinspection timing goal contradicts validated metrics";
  P.require
    (Poly.equal (P.field "analysis_digest" response) (`String analysis.target.source_digest)
     && Poly.equal (P.field "analysis_id" response) (`String analysis.target.analysis_id))
    "Reinspection recomputed analysis digest mismatch";
  let label = sprintf "Reinspection recomputed %s/%s; original %s/%s unchanged"
    (P.text (P.field "status" raw)) (P.text (P.field "timing_goal" raw))
    (P.text (P.field "status" old)) (P.text (P.field "timing_goal" old)) in
  { R.original = original.target; recomputed = analysis.target; observation_path = path;
    observation_sha256; lineage_digest = P.digest (canonical lineage); label }
;;

let validate_live ~registered (index : W.Index.t) =
  Option.iter (marker index) ~f:(fun r ->
    I.validate_analysis_target r.original;
    I.validate_analysis_target r.recomputed;
    P.require (Option.equal W.Analysis_target.equal index.analysis (Some r.recomputed))
      "Cached reinspection target mismatch";
    let _, original, path, hash = original ~registered ~execution_file:index.execution_file
      ~execution_sha256:index.execution_sha256 ~stage:index.stage in
    P.require (W.Analysis_target.equal original.target r.original
      && String.equal path r.observation_path && String.equal hash r.observation_sha256)
      "Reinspection original source changed";
    Timing.validate_source ~execution_file:index.execution_file r.recomputed)
;;

let decorate (index : W.Index.t) r =
  P.require (not (List.exists index.diagnostics ~f:R.is_metadata)) "Provider supplied reserved reinspection cache metadata";
  { index with diagnostics = r.R.label :: R.encode r :: index.diagnostics }
;;

let validate_detail ~registered ~execution_sha256 (index : W.Index.t) response =
  Option.iter (marker index) ~f:(fun prior ->
    let current = validate ~registered ~execution_file:index.execution_file ~execution_sha256
      ~stage:index.stage ~expected:(Some prior.original) response in
    P.require (R.equal current prior) "Timing reinspection detail lineage changed")
;;
