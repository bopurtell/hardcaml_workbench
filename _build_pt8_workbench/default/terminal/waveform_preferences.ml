open! Core

(* Client-only presentation. This deliberately has no artifact, workspace, pin or request
   lifetime fields, and does not change any existing preference schema. *)
type value_layout =
  | Inline
  | Stacked
[@@deriving equal, sexp]

type t =
  { schema_version : int
  ; project_key : string
  ; value_layout : value_layout [@sexp.default Inline]
  }
[@@deriving sexp]

let create ~project_key value_layout = { schema_version = 1; project_key; value_layout }

let path ~state_directory ~project_key =
  Filename.concat
    state_directory
    ("waveform-display-" ^ Plain_rpc.digest project_key ^ ".sexp")
;;

let decode ~project_key text =
  if String.length text > 4096
  then failwith "Waveform display preference size limit exceeded";
  let saved = t_of_sexp (Sexp.of_string text) in
  if saved.schema_version <> 1
  then failwith "Unsupported waveform display preference schema";
  if not (String.equal saved.project_key project_key)
  then failwith "Waveform display preference project/environment mismatch";
  saved
;;

let encode t = Sexp.to_string_hum (sexp_of_t t) ^ "\n"

let load ~state_directory ~project_key =
  let file = path ~state_directory ~project_key in
  match Sys_unix.file_exists file with
  | `No -> None
  | `Unknown -> failwith "Cannot inspect waveform display preferences"
  | `Yes ->
    if Int64.((Core_unix.stat file).st_size > 4096L)
    then failwith "Waveform display preference size limit exceeded";
    Some (decode ~project_key (In_channel.read_all file))
;;

let save ~state_directory t =
  let text = encode t in
  ignore (decode ~project_key:t.project_key text : t);
  Core_unix.mkdir_p state_directory ~perm:0o700;
  let temp =
    Filename_unix.temp_file ~in_dir:state_directory ".waveform-display-" ".tmp"
  in
  Exn.protect
    ~finally:(fun () ->
      if Poly.equal (Sys_unix.file_exists temp) `Yes then Core_unix.unlink temp)
    ~f:(fun () ->
      Out_channel.write_all temp ~data:text;
      Core_unix.rename ~src:temp ~dst:(path ~state_directory ~project_key:t.project_key))
;;

let%test_unit "display preference defaults, roundtrip and project isolation" =
  let old = decode ~project_key:"root/env" "((schema_version 1)(project_key root/env))" in
  assert (equal_value_layout old.value_layout Inline);
  let saved = create ~project_key:"root/env" Stacked in
  assert (
    equal_value_layout
      (decode ~project_key:"root/env" (encode saved)).value_layout
      Stacked);
  assert (
    Result.is_error
      (Or_error.try_with (fun () -> decode ~project_key:"other/env" (encode saved))));
  assert (
    Result.is_error
      (Or_error.try_with (fun () -> decode ~project_key:"root/env" (String.make 4097 ' '))));
  let dir = Filename_unix.temp_dir "waveform-display-test-" "" in
  Exn.protect
    ~finally:(fun () ->
      Core_unix.unlink (path ~state_directory:dir ~project_key:"root/env");
      Core_unix.rmdir dir)
    ~f:(fun () ->
      assert (Option.is_none (load ~state_directory:dir ~project_key:"root/env"));
      save ~state_directory:dir saved;
      assert (
        equal_value_layout
          (Option.value_exn (load ~state_directory:dir ~project_key:"root/env"))
            .value_layout
          Stacked);
      assert (Option.is_none (load ~state_directory:dir ~project_key:"other/env")))
;;
