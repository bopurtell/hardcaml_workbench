open! Core
open! Async
module Invocation = Hardcaml_workbench_adapters.Dune_adapter.Invocation

let stop ?(grace_seconds = 5.) process =
  (* Force Async's owned wait before signalling. Completed children need no signal;
     send_signal itself also guards the wait/PID-reuse race (process.ml). Never replace it
     with a raw PID signal or reap through a second waitpid API. *)
  let waited = Process.wait process in
  if Deferred.is_determined waited
  then Deferred.unit
  else (
    Process.send_signal process Signal.term;
    match%bind Clock.with_timeout (Time_float.Span.of_sec grace_seconds) waited with
    | `Result _ -> Deferred.unit
    | `Timeout ->
      if not (Deferred.is_determined waited) then Process.send_signal process Signal.kill;
      waited >>| fun _ -> ())
;;

(** All output is drained incrementally. A query/launcher has a hard total stdout budget
     and a per-record budget; stderr is drained but only 4KiB retained. *)
module Output = struct
  type t = { stdout : string; exit_code : int }
end

let run_with_status ?(accept_evidence_failure = false) ?(max_stdout_bytes = 16 * 1024 * 1024)
  ?(max_record_bytes = 8 * 1024 * 1024) ?(stop_grace_seconds = 5.) ~seconds ~cancel ~on_process ~on_line invocation =
  if max_stdout_bytes < 1 || max_stdout_bytes > 16 * 1024 * 1024
     || max_record_bytes < 1 || max_record_bytes > 8 * 1024 * 1024
  then invalid_arg "ASIC process output limits";
  if Deferred.is_determined cancel then failwith "ASIC operation cancelled";
  let%bind process =
    Process.create_exn
      ~working_dir:invocation.Invocation.cwd
      ~prog:invocation.executable
      ~args:(List.tl_exn invocation.argv)
      ()
  in
  let waited = Process.wait process in
  let stdout = Buffer.create 4096
  and stderr = Buffer.create 1024 in
  let drain_stderr () =
    let bytes = Bytes.create 4096 in
    let rec loop () =
      match%bind Reader.read (Process.stderr process) bytes with
      | `Eof -> Deferred.unit
      | `Ok n ->
        Buffer.add_string
          stderr
          (Bytes.sub bytes ~pos:0 ~len:(Int.min n (4096 - Buffer.length stderr))
           |> Bytes.to_string);
        loop ()
    in
    loop ()
  in
  let drain_stdout () =
    let bytes = Bytes.create 4096
    and line = Buffer.create 4096 in
    let total = ref 0 in
    let rec consume chunk pos =
      if pos = String.length chunk
      then Deferred.unit
      else (
        match String.index_from chunk pos '\n' with
        | None ->
          Buffer.add_substring line chunk ~pos ~len:(String.length chunk - pos);
           if Buffer.length line > max_record_bytes
          then failwith "ASIC JSON record too large";
          Deferred.unit
        | Some i ->
          Buffer.add_substring line chunk ~pos ~len:(i - pos);
           if Buffer.length line > max_record_bytes
          then failwith "ASIC JSON record too large";
          let value = Buffer.contents line in
          Buffer.clear line;
          let%bind () = on_line value in
          consume chunk (i + 1))
    in
    let rec loop () =
      match%bind Reader.read (Process.stdout process) bytes with
      | `Eof ->
        if Buffer.length line = 0 then Deferred.unit else on_line (Buffer.contents line)
      | `Ok n ->
        total := !total + n;
         if !total > max_stdout_bytes then failwith "ASIC stdout budget exceeded";
        let chunk = Bytes.sub bytes ~pos:0 ~len:n |> Bytes.to_string in
        (* Query output is bounded; launchers need no retained transcript. *)
        Buffer.add_string stdout chunk;
        let%bind () = consume chunk 0 in
        loop ()
    in
    loop ()
  in
  Monitor.protect
    ~finally:(fun () ->
      let%bind () = stop ~grace_seconds:stop_grace_seconds process in
      let%bind () = Writer.close (Process.stdin process) in
      let%bind () = Reader.close (Process.stdout process) in
      Reader.close (Process.stderr process))
    (fun () ->
      on_process process;
      let work =
        Monitor.try_with (fun () ->
          let%bind () = Writer.close (Process.stdin process) in
          let%bind () = Deferred.all_unit [ drain_stdout (); drain_stderr () ] in
          let%map status = waited in
          match status with
            | Ok () -> { Output.stdout = Buffer.contents stdout; exit_code = 0 }
            | Error (`Exit_non_zero 1) when accept_evidence_failure ->
              { Output.stdout = Buffer.contents stdout; exit_code = 1 }
          | Error _ ->
            failwith
              ("ASIC command failed ("
               ^ Unix.Exit_or_signal.to_string_hum status
               ^ "): "
               ^ Buffer.contents stderr))
      in
      match%bind
        Deferred.any
          [ (work >>| fun value -> `Result value)
          ; (Clock.after (Time_float.Span.of_sec seconds) >>| fun () -> `Timeout)
          ; (cancel >>| fun () -> `Cancelled)
          ]
      with
      | `Result (Ok value) -> return value
      | `Result (Error exn) -> raise exn
      | `Timeout -> failwith "ASIC command timeout"
      | `Cancelled -> failwith "ASIC operation cancelled")
;;

(** Ordinary callers retain their existing string result and process-failure policy.
    Resource evidence readers use [run_with_status] and validate the accepted code
    against the public verdict before publishing either indexes or pages. *)
let run ?accept_evidence_failure ?max_stdout_bytes ?max_record_bytes ?stop_grace_seconds
  ~seconds ~cancel ~on_process ~on_line invocation =
  let%map output =
    run_with_status ?accept_evidence_failure ?max_stdout_bytes ?max_record_bytes
      ?stop_grace_seconds ~seconds ~cancel ~on_process ~on_line invocation
  in
  output.Output.stdout
;;
