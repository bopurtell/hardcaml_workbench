open! Core
open Wire

type context =
  { request : Provider.Request.t
  ; artifact_dir : string
  ; emit : Provider.Event.payload -> unit
  }

let artifact_path context path =
  Validation.check
    (Validation.Driver_protocol.valid_relative_path path
     && not (String.contains path '\000'))
    "Artifact path must be normalized and relative";
  Filename.concat context.artifact_dir path
;;

let run_child ~prog ~args ~on_stdout_line =
  Or_error.try_with (fun () ->
    let input, output = Core_unix.pipe ~close_on_exec:true () in
    let pid =
      try
        (Core_unix.create_process_with_fds
           ~prog
           ~args
           ~stdin:(Use_this Core_unix.stdin)
           ~stdout:(Use_this output)
           ~stderr:(Use_this Core_unix.stderr)
           ())
          .pid
      with
      | exn ->
        Core_unix.close input;
        Core_unix.close output;
        raise exn
    in
    Core_unix.close output;
    let channel = Core_unix.in_channel_of_descr input in
    let callback_error = ref None in
    let read_result =
      Or_error.try_with (fun () ->
        Exn.protect
          ~f:(fun () ->
            In_channel.iter_lines channel ~f:(fun line ->
              Out_channel.output_string stdout (line ^ "\n");
              Out_channel.flush stdout;
              if Option.is_none !callback_error
              then (
                try on_stdout_line line with
                | exn -> callback_error := Some exn)))
          ~finally:(fun () -> In_channel.close channel))
    in
    let status = Core_unix.waitpid pid in
    Or_error.ok_exn read_result;
    Option.iter !callback_error ~f:raise;
    match status with
    | Ok () -> ()
    | Error _ ->
      failwith
        ("Child simulator exited unsuccessfully: "
         ^ Sexp.to_string_hum [%sexp (status : Core_unix.Exit_or_signal.t)]))
;;

let read_request path =
  In_channel.with_file path ~f:(fun channel ->
    let buffer = Buffer.create 4096 in
    let rec loop remaining =
      match In_channel.input_char channel with
      | None -> Buffer.contents buffer
      | Some char ->
        Validation.check (remaining > 0) "Provider request exceeds 1 MiB";
        Buffer.add_char buffer char;
        loop (remaining - 1)
    in
    loop Limits.discovery_bytes)
  |> Sexp.of_string
  |> Provider.Request.t_of_sexp
;;

let execute ~argv ~discovery ~validate_selection ~run =
  let discovery = Validation.validate_discovery discovery in
  let absolute path =
    Validation.check (Filename.is_absolute path) "Expected absolute provider path";
    path
  in
  match Array.to_list argv with
  | [ _; "discover"; "--protocol-version"; "1" ] ->
    let output = Sexp.to_string_mach (Discovery.sexp_of_t discovery) ^ "\n" in
    Validation.check
      (String.length output <= Limits.discovery_bytes)
      "Discovery exceeds 1 MiB";
    Out_channel.output_string stdout output;
    Out_channel.flush stdout
  | [ _
    ; "run"
    ; "--protocol-version"
    ; "1"
    ; "--request"
    ; request_path
    ; "--events"
    ; events
    ; "--artifact-dir"
    ; artifact_dir
    ] ->
    let request = read_request (absolute request_path) in
    Validation.check (request.protocol_version = version) "Unsupported request version";
    Validation.key request.attempt_id;
    (* Validation also offers daemon-side normalization. Standalone adapters must observe
       the request's original order, just like foreign-language providers. *)
    Validation.validate_selection discovery request.selection |> Or_error.ok_exn |> ignore;
    let selection = request.selection in
    validate_selection selection |> Or_error.ok_exn;
    let artifact_dir = absolute artifact_dir in
    let events = absolute events in
    Out_channel.with_file ~append:true events ~f:(fun channel ->
      let sequence = ref 0 in
      let bytes = ref 0 in
      let finished = ref false in
      let cases = Hashtbl.create (module String) in
      let artifacts = Hash_set.create (module String) in
      let progress = Hashtbl.Poly.create () in
      let poisoned = ref false in
      let active id =
        Validation.check
          (match Hashtbl.find cases id with
           | Some `Active -> true
           | _ -> false)
          "Case must be active"
      in
      let emit_unchecked payload =
        Validation.check (not !poisoned) "Emitter previously failed";
        Validation.check (not !finished) "Event after Finished";
        Validation.check (!sequence < Limits.events) "Too many events";
        Validation.check
          (if !sequence = 0
           then Provider.Event.equal_payload payload Started
           else not (Provider.Event.equal_payload payload Started))
          "Started must occur exactly once as first event";
        let event =
          { Provider.Event.protocol_version = version
          ; attempt_id = request.attempt_id
          ; sequence = !sequence
          ; payload
          }
          |> Validation.validate_event
        in
        let line = Sexp.to_string_mach (Provider.Event.sexp_of_t event) in
        Validation.parse_event_line line |> Or_error.ok_exn |> ignore;
        Validation.check
          (!bytes + String.length line + 1 <= Limits.stream_bytes)
          "Event stream exceeds 16 MiB";
        (match payload with
         | Started -> ()
         | Case_started id ->
           Validation.check
             (List.mem selection.cases id ~equal:String.equal)
             "Unselected case";
           Validation.check (not (Hashtbl.mem cases id)) "Case started twice";
           Hashtbl.set cases ~key:id ~data:`Active
         | Case_finished result ->
           active result.case_id;
           Hashtbl.set cases ~key:result.case_id ~data:(`Done result.status)
         | Progress value ->
           Option.iter value.case_id ~f:active;
           Option.iter (Hashtbl.find progress value.case_id) ~f:(fun previous ->
             Validation.check
               (value.completed >= previous.Progress.completed
                && String.equal value.unit_ previous.unit_
                && (Option.is_none previous.total
                    || Option.equal Int.equal previous.total value.total))
               "Nonmonotone or inconsistent progress");
           Hashtbl.set progress ~key:value.case_id ~data:value
         | Artifact artifact ->
           Validation.check
             (not (Hash_set.mem artifacts artifact.id))
             "Duplicate artifact";
           Validation.check
             (Hash_set.length artifacts < Limits.artifacts)
             "Too many artifacts";
           Option.iter artifact.case_id ~f:(fun id ->
             Validation.check (Hashtbl.mem cases id) "Artifact case has not started");
           Hash_set.add artifacts artifact.id
         | Finished outcome ->
           let failed = ref false in
           List.iter selection.cases ~f:(fun id ->
             match Hashtbl.find cases id with
             | Some (`Done status) ->
               if Case_status.equal status Failed then failed := true
             | _ -> failwith "Finished before all selected cases completed");
           Validation.check
             (Bool.equal !failed (Outcome.equal outcome Failed))
             "Finished outcome disagrees with cases";
           finished := true);
        Out_channel.output_string channel (line ^ "\n");
        Out_channel.flush channel;
        incr sequence;
        bytes := !bytes + String.length line + 1
      in
      let emit payload =
        try emit_unchecked payload with
        | exn ->
          poisoned := true;
          raise exn
      in
      run { request; artifact_dir; emit } |> Or_error.ok_exn;
      Validation.check (not !poisoned) "Emitter failed";
      Validation.check !finished "Provider returned without Finished")
  | _ -> failwith "Expected discover/run --protocol-version 1 with exact FS2 arguments"
;;

let main ?(argv = Sys.get_argv ()) ~discovery ~validate_selection ~run () =
  match
    Or_error.try_with (fun () -> execute ~argv ~discovery ~validate_selection ~run)
  with
  | Ok () -> ()
  | Error error ->
    Out_channel.output_string
      stderr
      ("Provider error: " ^ Error.to_string_hum error ^ "\n");
    Out_channel.flush stderr;
    Stdlib.exit 1
;;
