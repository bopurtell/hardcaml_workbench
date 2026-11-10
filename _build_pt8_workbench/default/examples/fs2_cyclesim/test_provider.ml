open! Core
open Hardcaml_workbench_provider
module W = Wire

let discovery : W.Discovery.t =
  { protocol_version = 1
  ; suites =
      [ { id = "counter"
        ; label = "counter"
        ; cases =
            List.map [ "wrap"; "reset"; "seeded" ] ~f:(fun id ->
              { W.Case.id; label = id })
        ; parameters =
            List.map
              [ "cycles", "64", []
              ; "step", "1", [ "1"; "3"; "7" ]
              ; "inject_failure", "false", [ "false"; "true" ]
              ]
              ~f:(fun (key, default, choices) ->
                { W.Parameter.key; label = key; default; choices })
        ; default_seed = "42"
        }
      ]
  }
;;

let parameter (selection : W.Selection.t) key =
  List.Assoc.find_exn selection.parameters key ~equal:String.equal
;;

let validate_selection (selection : W.Selection.t) =
  Or_error.try_with (fun () ->
    if not (List.is_empty selection.asic_inputs)
    then failwith "counter takes no ASIC inputs";
    let cycles = Int.of_string (parameter selection "cycles") in
    if cycles < 32 || cycles > 100000 then failwith "cycles must be 32..100000")
;;

(* Decimal accumulation modulo 2^64 preserves the original Python adapter's
   unsigned-to-signed bit-pattern mapping, including the maximum uint64 seed. *)
let signed_seed seed =
  String.fold seed ~init:0L ~f:(fun acc digit ->
    let value = Char.to_int digit - Char.to_int '0' in
    Int64.((acc * 10L) + of_int value))
  |> Int64.to_string
;;

let json_string value =
  let buffer = Buffer.create 32 in
  Buffer.add_char buffer '"';
  String.iter value ~f:(function
    | '"' -> Buffer.add_string buffer "\\\""
    | '\\' -> Buffer.add_string buffer "\\\\"
    | c when Char.to_int c < 32 ->
      Buffer.add_string buffer (sprintf "\\u%04x" (Char.to_int c))
    | c -> Buffer.add_char buffer c);
  Buffer.add_char buffer '"';
  Buffer.contents buffer
;;

let run counter (context : Runner.context) =
  Or_error.try_with (fun () ->
    let selection = context.request.selection in
    let emit = context.emit in
    emit Started;
    let failed = ref false in
    List.iter selection.cases ~f:(fun case ->
      emit (Case_started case);
      let trace = case ^ ".vcd" in
      let report = Buffer.create 1024 in
      let outcome = ref None in
      Runner.run_child
        ~prog:counter
        ~args:
          [ case
          ; signed_seed selection.seed
          ; parameter selection "cycles"
          ; parameter selection "step"
          ; Runner.artifact_path context trace
          ; parameter selection "inject_failure"
          ]
        ~on_stdout_line:(fun line ->
          Buffer.add_string report line;
          Buffer.add_char report '\n';
          if String.is_prefix line ~prefix:"PROGRESS "
          then (
            match String.split line ~on:' ' with
            | [ _; completed; total ] ->
              emit
                (Progress
                   { case_id = Some case
                   ; completed = Int.of_string completed
                   ; total = Some (Int.of_string total)
                   ; unit_ = "cycles"
                   })
            | _ -> failwith "invalid child progress");
          if String.is_prefix line ~prefix:"RESULT "
          then (
            if Option.is_some !outcome then failwith "duplicate child result";
            outcome := List.nth (String.split line ~on:' ') 1))
      |> Or_error.ok_exn;
      let is_failed =
        match !outcome with
        | Some "Passed" -> false
        | Some "Failed" -> true
        | _ -> failwith "Cyclesim checker exited without valid result"
      in
      let artifact id kind media_type path =
        emit (Artifact { id; case_id = Some case; label = id; kind; media_type; path })
      in
      artifact (case ^ "-vcd") "waveform" "application/vnd.gtkwave.vcd" trace;
      let report_path = case ^ "-report.txt" in
      let parameters =
        List.sort selection.parameters ~compare:(fun (a, _) (b, _) -> String.compare a b)
        |> List.map ~f:(fun (key, value) -> json_string key ^ ": " ^ json_string value)
        |> String.concat ~sep:", "
      in
      Out_channel.write_all
        (Runner.artifact_path context report_path)
        ~data:
          ("seed="
           ^ selection.seed
           ^ "\nparameters={"
           ^ parameters
           ^ "}\n"
           ^ Buffer.contents report);
      artifact
        (case ^ "-report")
        (if is_failed then "failure-report" else "report")
        "text/plain"
        report_path;
      failed := !failed || is_failed;
      emit
        (Case_finished
           { case_id = case
           ; status = (if is_failed then Failed else Passed)
           ; message =
               (if is_failed
                then Some "Counter reference-model mismatch; see report"
                else None)
           }));
    emit (Finished (if !failed then Failed else Passed)))
;;

let () =
  let argv = Sys.get_argv () in
  let counter, argv =
    if Array.length argv >= 3 && String.equal argv.(1) "--counter"
    then
      ( argv.(2)
      , Array.append [| argv.(0) |] (Array.sub argv ~pos:3 ~len:(Array.length argv - 3)) )
    else Filename.concat (Filename.dirname argv.(0)) "counter.exe", argv
  in
  Runner.main ~argv ~discovery ~validate_selection ~run:(run counter) ()
;;
