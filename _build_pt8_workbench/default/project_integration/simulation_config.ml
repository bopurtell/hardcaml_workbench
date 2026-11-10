open! Core
module Simulation = Hardcaml_workbench_protocol.Simulation

type t =
  { schema_version : int
  ; provider_executable : string
  ; provider_args : string list
  ; discovery_timeout_seconds : int
  ; run_timeout_seconds : int
  }
[@@deriving compare, equal, sexp]

let filename = "hardcaml-workbench-simulation.sexp"

let validate t =
  if t.schema_version <> 1 then failwith "Unsupported simulation configuration schema";
  if (not (Filename.is_absolute t.provider_executable))
     || String.contains t.provider_executable '\000'
     || String.length t.provider_executable > Simulation.Limits.string_bytes
  then failwith "Simulation provider_executable must be an absolute path without NUL";
  if List.length t.provider_args > 32
  then failwith "Simulation provider_args exceeds 32 arguments";
  List.iter t.provider_args ~f:(fun arg ->
    if String.contains arg '\000' || String.length arg > Simulation.Limits.string_bytes
    then failwith "Invalid simulation provider argument");
  if t.discovery_timeout_seconds < 1 || t.discovery_timeout_seconds > 60
  then failwith "Simulation discovery timeout must be in 1..60 seconds";
  if t.run_timeout_seconds < 1 || t.run_timeout_seconds > 86_400
  then failwith "Simulation run timeout must be in 1..86400 seconds";
  t
;;

let parse_string text =
  Or_error.try_with (fun () ->
    if String.length text > Simulation.Limits.config_bytes
    then failwith "Simulation config exceeds 16384 bytes";
    t_of_sexp (Sexp.of_string text) |> validate)
;;
