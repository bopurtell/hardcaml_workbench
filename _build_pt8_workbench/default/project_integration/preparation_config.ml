open! Core

(** Deliberately independent of ASIC/provider configuration. The executable is derived
    from the target in this checkout, never from the pinned ASIC project executable. *)
type t =
  { schema_version : int
  ; build_target : string
  ; results_root : string
  ; timeout_seconds : int
  }
[@@deriving compare, equal, sexp]

let filename = "hardcaml-workbench-preparation.sexp"

let validate t =
  if t.schema_version <> 1 then failwith "Unsupported preparation configuration schema";
  if (not (Manifest.valid_components t.build_target))
     || (not (String.is_suffix t.build_target ~suffix:".exe"))
     || String.is_prefix t.build_target ~prefix:"-"
     || String.is_prefix t.build_target ~prefix:"_build/"
     || String.contains t.build_target '@'
     || String.contains t.build_target '\000'
  then failwith "build_target must be a source-relative Dune .exe target";
  if (not (Filename.is_absolute t.results_root)) || String.contains t.results_root '\000'
  then failwith "results_root must be absolute";
  if t.timeout_seconds <= 0 then failwith "timeout_seconds must be positive";
  t
;;

let source_executable t ~root = Filename.concat root ("_build/default/" ^ t.build_target)

let parse_string text =
  Or_error.try_with (fun () -> t_of_sexp (Sexp.of_string text) |> validate)
;;
