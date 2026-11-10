open! Core
open Hardcaml_workbench_provider
open Wire

let discovery : Discovery.t =
  { protocol_version = 1
  ; suites =
      [ { id = "suite"
        ; label = "λ 🧪\n\t\001"
        ; cases =
            [ { id = "first"; label = "First" }; { id = "second"; label = "Second" } ]
        ; parameters =
            [ { key = "mode"; label = "Mode"; default = "good"; choices = [] } ]
        ; default_seed = "18446744073709551615"
        }
      ; { id = "ordered"
        ; label = "Order-sensitive standalone adapter"
        ; cases =
            [ { id = "first"; label = "First" }; { id = "second"; label = "Second" } ]
        ; parameters =
            [ { key = "alpha"; label = "Alpha"; default = "a"; choices = [] }
            ; { key = "zeta"; label = "Zeta"; default = "z"; choices = [] }
            ]
        ; default_seed = "42"
        }
      ]
  }
;;

let report_order stage (selection : Selection.t) =
  Out_channel.output_string
    stdout
    (stage
     ^ ": "
     ^ String.concat ~sep:"," selection.cases
     ^ ";"
     ^ String.concat ~sep:"," (List.map selection.parameters ~f:fst)
     ^ "\n");
  Out_channel.flush stdout
;;

let () =
  Runner.main
    ~discovery
    ~validate_selection:(fun selection ->
      if String.equal selection.suite "ordered"
      then (
        report_order "validate" selection;
        Ok ())
      else if not (List.is_empty selection.asic_inputs)
      then Or_error.error_string "Unexpected ASIC inputs"
      else if String.equal
                (List.Assoc.find_exn selection.parameters ~equal:String.equal "mode")
                "domain-error"
      then Or_error.error_string "Invalid domain parameter"
      else Ok ())
    ~run:(fun context ->
      let emit = context.emit in
      let mode =
        if String.equal context.request.selection.suite "ordered"
        then (
          report_order "run" context.request.selection;
          "good")
        else
          List.Assoc.find_exn
            context.request.selection.parameters
            ~equal:String.equal
            "mode"
      in
      if String.equal mode "exception" then failwith "project exception";
      emit Started;
      if String.equal mode "flush"
      then (
        let path = (Sys.get_argv ()).(7) in
        let live = In_channel.read_all path in
        assert (String.is_suffix live ~suffix:"\n");
        assert (String.is_substring live ~substring:"Started"));
      if List.mem [ "event-count"; "stream-limit" ] mode ~equal:String.equal
      then
        for completed = 0 to Limits.events do
          emit
            (Progress
               { case_id = None
               ; completed
               ; total = None
               ; unit_ =
                   (if String.equal mode "stream-limit" then String.make 4096 'x' else "")
               })
        done;
      if List.mem
           [ "artifact-limit"; "duplicate-artifact"; "artifact-path" ]
           mode
           ~equal:String.equal
      then
        for i = 0 to Limits.artifacts do
          emit
            (Artifact
               { id =
                   (if String.equal mode "duplicate-artifact"
                    then "same"
                    else "a" ^ Int.to_string i)
               ; case_id = None
               ; label = "Artifact"
               ; kind = "report"
               ; media_type = "text/plain"
               ; path =
                   (if String.equal mode "artifact-path"
                    then "../outside"
                    else "report.txt")
               })
        done;
      if String.equal mode "duplicate-start" then emit Started;
      if String.equal mode "swallowed"
      then (
        try emit Started with
        | _ -> ());
      if String.equal mode "unselected" then emit (Case_started "unknown");
      if String.equal mode "finish-early" then emit (Finished Passed);
      List.iter context.request.selection.cases ~f:(fun id ->
        emit (Case_started id);
        let total = if String.equal mode "unknown-total" then None else Some 2 in
        emit (Progress { case_id = Some id; completed = 1; total; unit_ = "λ\n\r\t" });
        if String.equal mode "regress"
        then
          emit (Progress { case_id = Some id; completed = 0; total; unit_ = "λ\n\r\t" });
        if String.equal mode "change-total"
        then
          emit
            (Progress
               { case_id = Some id; completed = 2; total = Some 3; unit_ = "λ\n\r\t" });
        if String.equal mode "oversized"
        then
          emit
            (Case_finished
               { case_id = id; status = Passed; message = Some (String.make 4096 '\001') });
        emit
          (Case_finished
             { case_id = id
             ; status = (if String.equal mode "failed" then Failed else Passed)
             ; message = Some "é 中文 🧪\n\r\t\001\\\""
             }));
      if String.equal mode "child"
      then
        Runner.run_child
          ~prog:"/usr/bin/printf"
          ~args:[ "%s\n"; "child λ" ]
          ~on_stdout_line:(fun line -> assert (String.equal line "child λ"))
        |> Or_error.ok_exn;
      if String.equal mode "child-error"
      then
        Runner.run_child ~prog:"/usr/bin/false" ~args:[] ~on_stdout_line:ignore
        |> Or_error.ok_exn;
      if not (String.equal mode "missing-finish")
      then emit (Finished (if String.equal mode "failed" then Failed else Passed));
      if String.equal mode "post-finish" then emit Started;
      Ok ())
    ()
;;
