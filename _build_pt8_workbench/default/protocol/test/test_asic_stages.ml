open! Core
open Hardcaml_workbench_protocol

let run : Asic.Run.t =
  { run =
      { backend = Backend_id.of_string "asic"
      ; id = "observed-run"
      ; build = None
      ; label = None
      }
  ; reference = { attempt = "/public/attempt"; stream_id = "observed-run" }
  ; selection = None
  ; cursor = 7
  ; status = "observing"
  ; execution_file = None
  ; error = None
  ; stages = []
  ; execution_timing = None
  }
;;

let%test_unit "stages preserve every status and new-run action through wire codecs" =
  let statuses : Asic.Stage.Status.t list =
    [ Pending
    ; Running
    ; Completed
    ; Failed
    ; Skipped
    ; Cancelled
    ; Not_requested
    ; Unsupported
    ; Unknown "provider_future_status"
    ]
  in
  let stages =
    List.mapi statuses ~f:(fun i status ->
      { Asic.Stage.id = "stage-" ^ Int.to_string i
      ; execution_timing = None
      ; name = "Stage " ^ Int.to_string i
      ; status
      ; requested = i < 6
      ; reason = Some "Explicit provider observation"
      ; action =
          (if i = 7
           then None
           else
             Some
               { Asic.Selection.flow = "synthetic"
               ; profile = "success"
               ; endpoint = "placement"
               ; assignments = [ "CLOCK_PERIOD=10" ]
               })
      })
  in
  let value = { run with stages } in
  assert (Asic.Run.equal value (Asic.Run.t_of_sexp (Asic.Run.sexp_of_t value)));
  let buffer = Bin_prot.Common.create_buf (Asic.Run.bin_size_t value) in
  let written = Asic.Run.bin_write_t buffer ~pos:0 value in
  let pos_ref = ref 0 in
  assert (Asic.Run.equal value (Asic.Run.bin_read_t buffer ~pos_ref));
  assert (!pos_ref = written);
  (* Preparing an advertised action uses the existing operation and selection shape. *)
  let selection = Option.value_exn (List.hd_exn stages).action in
  let operation = Asic.Operation.Plan selection in
  assert (
    Asic.Operation.equal
      operation
      (Asic.Operation.t_of_sexp (Asic.Operation.sexp_of_t operation)))
;;

let%test_unit "legacy persisted runs without stages decode to no observations" =
  let legacy =
    match Asic.Run.sexp_of_t run with
    | Sexp.List fields ->
      Sexp.List
        (List.filter fields ~f:(function
          | Sexp.List (Sexp.Atom "stages" :: _) -> false
          | _ -> true))
    | _ -> assert false
  in
  let restored = Asic.Run.t_of_sexp legacy in
  assert (List.is_empty restored.stages);
  assert (Asic.Run.equal run restored)
;;
