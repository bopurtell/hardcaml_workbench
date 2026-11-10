open! Core
open Hardcaml_workbench_provider
module W = Wire
module F = Frozen_wire

module type Codec = sig
  type t [@@deriving bin_io, sexp]
end

let same
  (type a b)
  (module A : Codec with type t = a)
  (module B : Codec with type t = b)
  sexp
  =
  let old = A.t_of_sexp sexp
  and current = B.t_of_sexp sexp in
  assert (Sexp.equal (A.sexp_of_t old) (B.sexp_of_t current));
  let old_bytes = Bin_prot.Utils.bin_dump A.bin_writer_t old in
  let current_bytes = Bin_prot.Utils.bin_dump B.bin_writer_t current in
  assert (String.equal (Bigstring.to_string old_bytes) (Bigstring.to_string current_bytes));
  let pos_ref = ref 0 in
  let decoded = B.bin_read_t old_bytes ~pos_ref in
  assert (!pos_ref = Bigstring.length old_bytes);
  assert (Sexp.equal (B.sexp_of_t decoded) sexp)
;;

let () =
  let check a b text = same a b (Sexp.of_string text) in
  check (module F.Backend_id) (module W.Backend_id) "asic";
  let build = "((backend asic)(id build)(label (RTL)))" in
  let run = "((backend asic)(id run)(build (" ^ build ^ "))(label ()))" in
  check (module F.Build_ref) (module W.Build_ref) build;
  check (module F.Run_ref) (module W.Run_ref) run;
  let parameter = "((key mode)(label Mode)(default fast)(choices (fast slow)))" in
  let case = "((id first)(label First))" in
  let suite =
    "((id suite)(label Suite)(cases ("
    ^ case
    ^ "))(parameters ("
    ^ parameter
    ^ "))(default_seed 18446744073709551615))"
  in
  let discovery = "((protocol_version 1)(suites (" ^ suite ^ ")))" in
  let input =
    "((run "
    ^ run
    ^ ")(attempt attempt)(artifact_id artifact)(sha256 "
    ^ String.make 64 'a'
    ^ "))"
  in
  let selection =
    "((suite suite)(cases (first))(seed 18446744073709551615)(parameters ((mode \
     fast)))(asic_inputs ("
    ^ input
    ^ ")))"
  in
  let request = "((protocol_version 1)(attempt_id sim-1)(selection " ^ selection ^ "))" in
  let progress =
    "((case_id (first))(completed 1000000)(total (2000000))(unit_ cycles))"
  in
  let artifact =
    "((id wave)(case_id (first))(label Wave)(kind waveform)(media_type \
     application/vnd.gtkwave.vcd)(path nested/trace.vcd))"
  in
  check (module F.Parameter) (module W.Parameter) parameter;
  check (module F.Case) (module W.Case) case;
  same
    (module F.Case)
    (module W.Case)
    (W.Case.sexp_of_t { id = "unicode"; label = "é 中文 🧪\n\r\t\001" });
  check (module F.Suite) (module W.Suite) suite;
  check (module F.Discovery) (module W.Discovery) discovery;
  check (module F.Asic_input) (module W.Asic_input) input;
  check (module F.Selection) (module W.Selection) selection;
  check (module F.Provider.Request) (module W.Provider.Request) request;
  check (module F.Progress) (module W.Progress) progress;
  check
    (module F.Progress)
    (module W.Progress)
    "((case_id ())(completed 0)(total ())(unit_ cycles))";
  check (module F.Provider.Artifact) (module W.Provider.Artifact) artifact;
  List.iter
    [ "Pending"; "Running"; "Passed"; "Failed"; "Skipped"; "Incomplete" ]
    ~f:(check (module F.Case_status) (module W.Case_status));
  List.iter
    [ "Unknown"; "Passed"; "Failed"; "Incomplete" ]
    ~f:(check (module F.Outcome) (module W.Outcome));
  let message = Sexp.to_string_mach (Sexp.Atom "é 中文 🧪\n\r\t\001\\\"") in
  let completion = "((case_id first)(status Failed)(message (" ^ message ^ ")))" in
  check
    (module F.Provider.Event.Case_finished)
    (module W.Provider.Event.Case_finished)
    completion;
  List.iter
    [ "Started"
    ; "(Case_started first)"
    ; "(Progress " ^ progress ^ ")"
    ; "(Case_finished " ^ completion ^ ")"
    ; "(Artifact " ^ artifact ^ ")"
    ; "(Finished Passed)"
    ; "(Finished Failed)"
    ]
    ~f:(fun payload ->
      let line =
        "((protocol_version 1)(attempt_id sim-1)(sequence 42)(payload " ^ payload ^ "))"
      in
      check (module F.Provider.Event) (module W.Provider.Event) line;
      let event = Validation.parse_event_line line |> Or_error.ok_exn in
      let emitted = W.Provider.Event.sexp_of_t event |> Sexp.to_string_mach in
      assert (not (String.contains emitted '\n' || String.contains emitted '\r'));
      assert (
        W.Provider.Event.equal
          event
          (Validation.parse_event_line emitted |> Or_error.ok_exn)));
  let request : W.Provider.Request.t =
    W.Provider.Request.t_of_sexp (Sexp.of_string request)
  in
  let discovery = Validation.parse_discovery discovery |> Or_error.ok_exn in
  let valid =
    Validation.validate_selection discovery request.selection |> Or_error.ok_exn
  in
  List.iter [ "00"; "+1"; "-1"; "18446744073709551616"; "1.0" ] ~f:(fun seed ->
    assert (
      Or_error.is_error (Validation.validate_selection discovery { valid with seed })));
  assert (
    Or_error.is_error
      (Validation.validate_selection
         discovery
         { valid with parameters = [ "mode", "absent" ] }));
  List.iter
    [ ""; ";comment"; "#; ignored"; "Started\n"; String.make W.Limits.event_bytes 'x' ]
    ~f:(fun line -> assert (Or_error.is_error (Validation.parse_event_line line)));
  print_endline "wire frozen sexp/bin_io and validation conformance: passed"
;;
