open! Core
open! Async
open Hardcaml_workbench_protocol
open Preparation
module Config = Hardcaml_workbench_project_integration.Preparation_config
module Adapter = Hardcaml_workbench_adapters.Preparation_adapter

type attempt =
  { mutable value : Attempt.t
  ; mutable cancelled : bool
  ; is_cancelled : unit -> bool
  ; finished : unit Ivar.t
  ; config : Config.t
  ; exclusive : bool
  }

type staged =
  { receipt : Staged.t
  ; config : Config.t
  ; mutable launch_key : string option
  }

type project =
  { mutable attempts : attempt list
  ; submissions : (string, string * attempt) Hashtbl.t
  ; mutable staged : staged option
  }

type t =
  { projects : (string, project) Hashtbl.t
  ; mutable next_id : int
  ; source_tails : unit Deferred.t String.Table.t
  ; leased_roots : String.Hash_set.t
  ; build :
      Config.t
      -> root:string
      -> environment:V1.Environment_selection.t
      -> Hardcaml_workbench_adapters.Dune_adapter.Invocation.t
  ; emit :
      Config.t
      -> root:string
      -> environment:V1.Environment_selection.t
      -> selection:Selection.t
      -> expected_plan_identity:string option
      -> Hardcaml_workbench_adapters.Dune_adapter.Invocation.t
  }

let create ?(build = Adapter.build) ?(emit = Adapter.emit) () =
  { projects = Hashtbl.create (module String)
  ; next_id = 0
  ; source_tails = String.Table.create ()
  ; leased_roots = String.Hash_set.create ()
  ; build
  ; emit
  }
;;

exception Rpc_error of V1.Error.t

let rpc_error kind message = raise (Rpc_error (V1.Error.create kind message))

let load_config root =
  let%map result =
    Monitor.try_with_or_error (fun () ->
      In_thread.run (fun () ->
        let path = Filename.concat root Config.filename in
        match Sys_unix.file_exists path with
        | `No -> None
        | `Yes | `Unknown ->
          Some (Config.parse_string (In_channel.read_all path) |> Or_error.ok_exn)))
  in
  match result with
  | Ok None -> Availability.Unavailable Not_configured, None
  | Ok (Some config) -> Available, Some config
  | Error error -> Unavailable (Invalid_configuration (Error.to_string_hum error)), None
;;

let active a =
  match a.value.outcome with
  | Building | Emitting -> true
  | _ -> false
;;

let cancelled a = a.cancelled || a.is_cancelled ()

let job_failure (job : Job.t) =
  Option.first_some
    job.failure
    (Some
       (sprintf
          "%s process %s (%s)"
          job.kind.name
          (Sexp.to_string_hum (Job.State.sexp_of_t job.state))
          (Sexp.to_string_hum ([%sexp_of: Job.Exit_status.t option] job.exit_status))))
;;

let handle
  ?(unique = false)
  ?(is_cancelled = fun () -> false)
  ?(on_release = fun () -> ())
  t
  ~root
  ~project_key
  ~environment
  ~schedule
  ~wait
  ~get_job
  ~cancel
  ~import
  operation
  =
  let project =
    Hashtbl.find_or_add t.projects project_key ~default:(fun () ->
      { attempts = []; submissions = Hashtbl.create (module String); staged = None })
  in
  let snapshot ?requested_attempt availability =
    let history =
      List.map project.attempts ~f:(fun a ->
        let refresh job = Option.bind job ~f:(fun job -> get_job job.Job.id) in
        { a.value with
          build_job = refresh a.value.build_job
        ; emission_job = refresh a.value.emission_job
        })
    in
    { Snapshot.availability
    ; session_only = true
    ; requested_attempt
    ; latest = List.hd history
    ; history
    ; staged = Option.map project.staged ~f:(fun s -> s.receipt)
    }
  in
  let%map handled =
    Monitor.try_with (fun () ->
      let%bind availability, config = load_config root in
      let validate selection expected_plan_identity =
        match
          Or_error.try_with (fun () ->
            Preparation_receipt.validate_selection selection expected_plan_identity)
        with
        | Error error -> rpc_error Invalid_request (Error.to_string_hum error)
        | Ok () -> ()
      in
      let require_config () =
        match config with
        | Some config -> config
        | None ->
          rpc_error Unsupported_operation "Source bundle preparation is not configured"
      in
      (* Normalize an explicit launch only after checking its captured scope. A successful
         submission replay is allowed even after supersession/drift: it observes the
         original attempt and never launches more work. *)
      let operation, launching =
        match operation with
        | Operation.Launch_staged { stage_id; submission_key } ->
          if String.is_empty submission_key
          then rpc_error Invalid_request "Empty submission key";
          let payload = "stage:" ^ stage_id in
          (match Hashtbl.find project.submissions submission_key with
           | Some (previous, _) when not (String.equal previous payload) ->
             rpc_error Conflict "Submission key already used for different inputs"
           | Some (_, a) ->
             ( Operation.Prepare
                 { submission_key
                 ; selection = a.value.selection
                 ; expected_plan_identity = a.value.expected_plan_identity
                 }
             , Some (payload, None) )
           | None ->
             let s =
               match project.staged with
               | Some s when String.equal s.receipt.id stage_id -> s
               | _ -> rpc_error Conflict "Unknown or superseded preparation stage"
             in
             if not
                  (String.equal s.receipt.source_root root
                   && V1.Environment_selection.equal s.receipt.environment environment
                   && Option.equal Config.equal config (Some s.config))
             then
               rpc_error
                 Conflict
                 "Preparation stage scope/configuration changed; stage again";
             if Option.is_some s.launch_key
             then
               rpc_error
                 Conflict
                 "Preparation stage already launched with another submission key";
             ( Operation.Prepare
                 { submission_key
                 ; selection = s.receipt.selection
                 ; expected_plan_identity = s.receipt.expected_plan_identity
                 }
             , Some (payload, Some s) ))
        | operation -> operation, None
      in
      match operation with
      | Operation.Get -> return (snapshot availability)
      | Stage { selection; expected_plan_identity } ->
        validate selection expected_plan_identity;
        let config = require_config () in
        t.next_id <- t.next_id + 1;
        let receipt : Staged.t =
          { id =
              "stage-"
              ^ Preparation_receipt.sha256
                  (sprintf
                     "%s:%d:%s"
                     project_key
                     t.next_id
                     (Time_ns.to_string (Time_ns.now ())))
          ; selection
          ; expected_plan_identity
          ; source_root = root
          ; build_target = config.build_target
          ; source_executable = Config.source_executable config ~root
          ; results_root = config.results_root
          ; timeout_seconds = config.timeout_seconds
          ; environment
          ; created_at = Timestamp.of_time_ns (Time_ns.now ())
          }
        in
        project.staged <- Some { receipt; config; launch_key = None };
        return (snapshot availability)
      | Launch_staged _ -> assert false
      | Cancel id ->
        let a =
          match List.find project.attempts ~f:(fun a -> String.equal a.value.id id) with
          | None -> rpc_error Not_found "Unknown preparation attempt"
          | Some a -> a
        in
        if not (active a)
        then return (snapshot ~requested_attempt:id availability)
        else (
          a.cancelled <- true;
          let%bind () =
            Deferred.List.iter
              (List.filter_opt [ a.value.build_job; a.value.emission_job ])
              ~how:`Sequential
              ~f:(fun job -> cancel job.Job.id)
          in
          a.value <- { a.value with outcome = Cancelled; bundle = None };
          return (snapshot ~requested_attempt:id availability))
      | Prepare { submission_key; selection; expected_plan_identity } ->
        if String.is_empty submission_key
        then rpc_error Invalid_request "Empty submission key";
        validate selection expected_plan_identity;
        let selection_payload =
          Sexp.to_string_mach
            ([%sexp_of: Selection.t * string option] (selection, expected_plan_identity))
        in
        let payload =
          match launching with
          | Some (payload, _) -> payload
          | None -> selection_payload
        in
        (match Hashtbl.find project.submissions submission_key with
         | Some (previous, a) ->
           if not (String.equal previous payload)
           then rpc_error Conflict "Submission key already used for a different selection";
           return (snapshot ~requested_attempt:a.value.id availability)
         | None ->
           (match
              List.find project.attempts ~f:(fun a ->
                (not unique)
                && (not a.exclusive)
                && Option.is_none launching
                && active a
                && (not (cancelled a))
                && Selection.equal a.value.selection selection
                && Option.value_map config ~default:false ~f:(Config.equal a.config)
                && Option.equal
                     String.equal
                     a.value.expected_plan_identity
                     expected_plan_identity)
            with
            | Some a ->
              Hashtbl.set project.submissions ~key:submission_key ~data:(payload, a);
              return (snapshot ~requested_attempt:a.value.id availability)
            | None ->
              let config =
                match launching with
                | Some (_, Some s) -> s.config
                | _ -> require_config ()
              in
              Option.iter launching ~f:(fun (_, stage) ->
                Option.iter stage ~f:(fun s -> s.launch_key <- Some submission_key));
              t.next_id <- t.next_id + 1;
              let a =
                { value =
                    { Attempt.id =
                        (if unique
                         then
                           "preparation-"
                           ^ Preparation_receipt.sha256
                               (project_key ^ "\000" ^ submission_key)
                         else sprintf "preparation-%d" t.next_id)
                    ; selection
                    ; selection_identity =
                        Preparation_receipt.sha256
                          (project_key ^ "\000" ^ selection_payload)
                    ; expected_plan_identity
                    ; source_root = root
                    ; build_target = config.build_target
                    ; source_executable = Config.source_executable config ~root
                    ; environment
                    ; results_root = config.results_root
                    ; timeout_seconds = config.timeout_seconds
                    ; created_at = Timestamp.of_time_ns (Time_ns.now ())
                    ; outcome = Building
                    ; build_job = None
                    ; emission_job = None
                    ; bundle = None
                    ; diagnostic = None
                    }
                ; cancelled = false
                ; is_cancelled
                ; finished = Ivar.create ()
                ; config
                ; exclusive = unique
                }
              in
              project.attempts <- a :: project.attempts;
              Hashtbl.set project.submissions ~key:submission_key ~data:(payload, a);
              let task invocation ~stdout ~drain ~finish : Simulation_task.t =
                { invocation
                ; timeout_seconds = config.timeout_seconds
                ; start = (fun () -> ())
                ; preflight =
                    (fun () ->
                      let%map _, current = load_config root in
                      if cancelled a then failwith "Preparation cancelled before launch";
                      if not (Option.equal Config.equal current (Some config))
                      then
                        failwith
                          "Preparation configuration changed before launch; submit a new \
                           attempt")
                ; stdout
                ; drain
                ; finish
                ; poll = (fun () -> true)
                ; fail =
                    (fun message -> a.value <- { a.value with diagnostic = Some message })
                }
              in
              (* Hold the source lease before enqueueing either job. Acquiring it in a job
                 preflight would deadlock an earlier emission behind that job. *)
              let previous =
                Hashtbl.find t.source_tails root |> Option.value ~default:Deferred.unit
              in
              let released = Ivar.create () in
              Hashtbl.set t.source_tails ~key:root ~data:(Ivar.read released);
              let release () =
                Hash_set.remove t.leased_roots root;
                Ivar.fill_if_empty a.finished ();
                Ivar.fill_if_empty released ();
                on_release ()
              in
              don't_wait_for
                (let%bind () = previous in
                 Hash_set.add t.leased_roots root;
                 if cancelled a
                 then (
                   a.value <- { a.value with outcome = Cancelled };
                   release ();
                   return ())
                 else (
                   let%bind scheduled =
                     Monitor.try_with_or_error (fun () ->
                       let build_task =
                         task
                           (t.build config ~root ~environment)
                           ~stdout:ignore
                           ~drain:(fun () -> return ())
                           ~finish:(fun ~cancelled:_ _ -> a.value.diagnostic)
                       in
                       schedule
                         ~name:"build"
                         ~cancelled:(fun () -> cancelled a)
                         build_task)
                   in
                   match scheduled with
                   | Error error ->
                     a.value
                     <- { a.value with
                          outcome = Build_failed
                        ; diagnostic = Some (Error.to_string_hum error)
                        };
                     release ();
                     return ()
                   | Ok build ->
                     a.value <- { a.value with build_job = Some build };
                     don't_wait_for
                       (let%map result =
                          Monitor.try_with (fun () ->
                            let%bind () =
                              if cancelled a then cancel build.id else return ()
                            in
                            let%bind built = wait build.id in
                            a.value <- { a.value with build_job = Some built };
                            if cancelled a || Job.State.equal built.state Cancelled
                            then (
                              a.value <- { a.value with outcome = Cancelled };
                              return ())
                            else if not (Job.State.equal built.state Complete)
                            then (
                              a.value
                              <- { a.value with
                                   outcome = Build_failed
                                 ; diagnostic =
                                     Option.first_some
                                       a.value.diagnostic
                                       (job_failure built)
                                 };
                              return ())
                            else (
                              a.value
                              <- { a.value with outcome = Emitting; diagnostic = None };
                              let buffer = Buffer.create 4096 in
                              let overflow = ref false in
                              let validation_error = ref None in
                              let pending_bundle = ref None in
                              let emission =
                                task
                                  (t.emit
                                     config
                                     ~root
                                     ~environment
                                     ~selection
                                     ~expected_plan_identity)
                                  ~stdout:(fun data ->
                                    if Buffer.length buffer + String.length data
                                       > 16 * 1024 * 1024
                                    then overflow := true
                                    else Buffer.add_string buffer data)
                                  ~drain:(fun () -> return ())
                                  ~finish:(fun ~cancelled:_ _ ->
                                    Option.first_some !validation_error a.value.diagnostic)
                              in
                              (* The supervisor calls drain after reaping and before
                                 marking Complete. *)
                              let emission =
                                { emission with
                                  drain =
                                    (fun () ->
                                      if !overflow
                                      then (
                                        validation_error
                                        := Some "Emission receipt exceeded byte budget";
                                        return ())
                                      else if cancelled a
                                              || Option.is_some a.value.diagnostic
                                      then return ()
                                      else (
                                        let%bind validated =
                                          In_thread.run (fun () ->
                                            Preparation_receipt.validate
                                              config
                                              ~selection
                                              ~expected_plan_identity
                                              (Buffer.contents buffer))
                                        in
                                        match validated with
                                        | Error error ->
                                          validation_error
                                          := Some (Error.to_string_hum error);
                                          return ()
                                        | Ok _
                                          when cancelled a
                                               || Option.is_some a.value.diagnostic ->
                                          return ()
                                        | Ok validated ->
                                          let%map imported =
                                            import
                                              ~job:
                                                (Option.value_exn a.value.emission_job).id
                                              ~valid:(fun () ->
                                                (not (cancelled a))
                                                && Option.is_none a.value.diagnostic)
                                              ~output_dir:validated.bundle.output_dir
                                              ~files:validated.files
                                          in
                                          (match imported with
                                           | Error error ->
                                             validation_error
                                             := Some (Error.to_string_hum error)
                                           | Ok artifacts ->
                                             pending_bundle
                                             := Some { validated.bundle with artifacts })))
                                }
                              in
                              let%bind emitted =
                                schedule
                                  ~name:"emit"
                                  ~cancelled:(fun () -> cancelled a)
                                  emission
                              in
                              a.value <- { a.value with emission_job = Some emitted };
                              let%bind () =
                                if cancelled a then cancel emitted.id else return ()
                              in
                              let%map emitted = wait emitted.id in
                              let outcome =
                                if cancelled a || Job.State.equal emitted.state Cancelled
                                then Outcome.Cancelled
                                else if Job.State.equal emitted.state Complete
                                        && Option.is_some !pending_bundle
                                then Completed
                                else Emission_failed
                              in
                              a.value
                              <- { a.value with
                                   emission_job = Some emitted
                                 ; outcome
                                 ; bundle =
                                     (if Outcome.equal outcome Completed
                                      then !pending_bundle
                                      else None)
                                 ; diagnostic =
                                     (if Outcome.equal outcome Completed
                                      then None
                                      else
                                        Option.first_some
                                          !validation_error
                                          (Option.first_some
                                             a.value.diagnostic
                                             (job_failure emitted)))
                                 }))
                        in
                        match result with
                        | Ok () -> release ()
                        | Error exn ->
                          release ();
                          a.value
                          <- { a.value with
                               outcome =
                                 (if cancelled a then Cancelled else Emission_failed)
                             ; diagnostic = Some (Exn.to_string exn)
                             });
                     return ()));
              return (snapshot ~requested_attempt:a.value.id availability))))
  in
  match handled with
  | Ok value -> Ok value
  | Error exn ->
    (match Monitor.extract_exn exn with
     | Rpc_error error -> Error error
     | exn -> Error (V1.Error.create Internal_failure (Exn.to_string exn)))
;;

let stop t =
  Hashtbl.iter t.projects ~f:(fun project ->
    List.iter project.attempts ~f:(fun a -> if active a then a.cancelled <- true))
;;

let source_leased t root = Hash_set.mem t.leased_roots root

let completion t =
  Deferred.all_unit
    (Hashtbl.data t.projects
     |> List.concat_map ~f:(fun project ->
       List.map project.attempts ~f:(fun a -> Ivar.read a.finished)))
;;
