open! Core
open! Async
open Hardcaml_workbench_protocol
module Http = Hardcaml_workbench_native_http
module Baseline_fixture = Terminal_presentation.Baseline_fixture
module Presentation = Terminal_presentation.Presentation
module State = Terminal_presentation.State
module Host = Terminal_presentation.Workspace_host
module Host_view = Terminal_presentation.Host_view
module Appearance = Terminal_presentation.Appearance
module Indicator = Terminal_presentation.Indicator
module Synthesis_view = Terminal_presentation.Synthesis_view
module Terminal_result_view = Terminal_presentation.Terminal_result_view
module Plain_rpc = Terminal_presentation.Plain_rpc
module Launch_preferences = Terminal_presentation.Launch_preferences
module Presentation_preferences = Terminal_presentation.Presentation_preferences

let timing_preload_override = ref None

module Asic_intents = Terminal_presentation.Asic_intents
module Artifact_view = Terminal_presentation.Artifact_view
module Artifact_export = Terminal_presentation.Artifact_export
module Artifact_binary_export = Terminal_presentation.Artifact_binary_export
module Inspection_view = Terminal_presentation.Inspection_view
module Timing_workspace = Terminal_presentation.Timing_workspace
module Fs0_fixture = Terminal_presentation.Fs0_fixture
module Simulation_view = Terminal_presentation.Simulation_view
module Testing_workspace = Terminal_presentation.Testing_workspace
module Simulation_catalog = Terminal_presentation.Simulation_catalog
module Simulation_export = Terminal_presentation.Simulation_export
module Waveform_data = Terminal_presentation.Waveform_data
module Waveform_view = Terminal_presentation.Waveform_view
module Waveform_preferences = Terminal_presentation.Waveform_preferences
module Waveforms = Hardcaml_workbench_workspaces.Waveforms
module Resources_view = Terminal_presentation.Resources_view
module Workloads_view = Terminal_presentation.Workloads_view
module Planned_run = Terminal_presentation.Planned_run
module Stage_action = Terminal_presentation.Stage_action

let console_limit = 500
let minimum_width = 68
let minimum_height = 20
let take_end values count = List.rev values |> Fn.flip List.take count |> List.rev

let bounded_waveform_logs records =
  List.rev records
  |> List.fold ~init:([], 0) ~f:(fun (kept, bytes) record ->
    let size = String.length record.V1.Read_log.Record.data in
    if bytes + size > 128 * 1024 || List.length kept >= console_limit
    then kept, 128 * 1024
    else record :: kept, bytes + size)
  |> fst
;;

type log_state =
  { mutable next_offset : int
  ; mutable records : V1.Read_log.Record.t list
  ; mutable fetch : Presentation.Log_fetch.t
  }

type artifact_view =
  { artifact : Artifact_id.t
  ; content : string
  ; truncated : bool
  }

type hierarchy_view =
  { hierarchy : Hierarchy.t
  ; nodes : Hierarchy.Node.t String.Table.t
  ; children : Hierarchy.Node.t list String.Table.t
  ; mutable selected_key : string
  ; mutable expanded : String.Set.t
  ; mutable scroll : int
  ; mutable pane_scroll : int
  }

type waveform_runtime =
  { pin : Waveforms.pin
  ; token : unit ref
  ; mutable epoch : unit ref
  ; mutable view : Waveform_view.t
  ; mutable loading : bool
  ; mutable restore_navigation : bool
  ; mutable artifacts : Simulation.Artifact.t list
  ; mutable picker_index : int
  ; mutable picker_status : string
  ; mutable metadata_loaded : bool
  ; mutable metadata_busy : bool
  ; logs : log_state
  ; mutable log_busy : bool
  }

type session =
  { requested_endpoint : string option
  ; project_root : string option
  ; environment_selection : V1.Environment_selection.t
  ; environment_label : string
  ; diagnostics_file : string option
  ; mutable client : Http.Client.t
  ; mutable hello : V1.Hello.Response.t
  ; mutable opened : V1.Open_project.Payload.t option
  ; mutable snapshot : V1.Snapshot.Payload.t
  ; mutable selected : int
  ; mutable selected_target : Target_id.t option
  ; mutable selected_configuration : Configuration_id.t option
  ; mutable selected_artifact : Artifact_id.t option
  ; mutable artifact_view : artifact_view option
  ; mutable hierarchy_view : hierarchy_view option
  ; mutable hierarchy_intent : unit ref
  ; hierarchy_errors : string Artifact_id.Table.t
  ; hierarchy_reads :
      (string
      * (Terminal_presentation.Hierarchy_view.evidence, string) Result.t Deferred.t)
        list
        ref
  ; logs : log_state Job_id.Table.t
  ; mutable status : string
  ; mutable polling : bool
  ; mutable hydration : Terminal_presentation.Retained_hydration.Coordinator.t
  ; mutable retained_reads : Terminal_presentation.Retained_hydration.t
  ; navigation_loaded : Terminal_presentation.Retained_hydration.Load.t
  ; mutable navigation_pending : Terminal_presentation.Navigation_preferences.t option
  ; mutable navigation_saved : string option
  ; mutable navigation_failed : bool
  ; mutable navigation_revision : int
  ; mutable navigation_restore_revision : int
  ; mutable navigation_touched : string list
  ; mutable navigation_focus_touched : string list
  ; mutable reconnect_delay_ms : int
  ; mutable last_dimensions : Bonsai_term.Dimensions.t option
  ; mutable show_connection_details : bool
  ; mutable connection_details_scroll : int
  ; mutable host : Host.t
  ; mutable workspace_config : Workspace_config.Resolved.t option
  ; mutable registry_busy : bool
  ; mutable asic : Asic.Snapshot.t option
  ; mutable asic_request_id : int
  ; mutable resource_navigation_intent : unit ref
  ; mutable preparation_request_id : int
  ; mutable asic_applied_id : int
  ; mutable timing_demand :
      (Workspace.Tile.t * Http.Client.t * Terminal_presentation.Timing_demand.t ref)
        option
  ; mutable timing_preload : Terminal_presentation.Timing_preload.t
  ; mutable timing_index_inflight : (string * unit Deferred.t) list
  ; mutable timing_preload_receipt : (string * string * int) option
  ; mutable view_on_allocation : (string * Host.launch_target) option
  ; mutable remembered_selection : Asic.Selection.t option
  ; mutable preferences_loaded : bool
  ; mutable presentation_preferences_loaded : string option
      (* Pending first-registry restoration only; consumed before ordinary polling. *)
  ; mutable presentation_preferences : Presentation_preferences.t option
  ; mutable presentation_preference_notice : string option
  ; mutable preference_saves : unit Deferred.t
  ; mutable asic_reads : Asic_intents.t
  ; mutable remembered_acceptance : string
  ; mutable artifact_viewer : string option
  ; mutable artifact_binary_viewer : string option
  ; mutable artifact_export_busy : bool
  ; mutable waveform : Waveform_view.t option
  ; mutable waveform_visible : bool
  ; mutable waveform_generation : int
  ; mutable waveform_history : Waveform_view.t list
  ; mutable waveform_workspaces : (string * waveform_runtime) list
  ; mutable waveform_preferences_loaded : string option
  ; mutable waveform_preferences_pending : Host.waveform_preferences option
  ; mutable waveform_preferences_saved : string option
  ; mutable waveform_preferences_failed : bool
  ; mutable waveform_open_generation : int
  ; mutable waveform_value_layout : Waveform_view.value_layout
  ; mutable waveform_display_loaded : string option
  ; mutable waveform_display_revision : int
  }

let append_diagnostic file message =
  Option.iter file ~f:(fun file ->
    try
      Out_channel.with_file file ~append:true ~f:(fun channel ->
        Out_channel.fprintf
          channel
          "%s %s\n"
          (Time_ns.to_string_utc (Time_ns.now ()))
          message)
    with
    | _ -> ())
;;

let error_message error = Error.to_string_hum error

let protocol_error (error : V1.Error.t) =
  sprintf "%s: %s" (Sexp.to_string_hum (V1.Error.Kind.sexp_of_t error.kind)) error.message
;;

let request diagnostics thunk =
  Monitor.try_with_or_error thunk
  >>| Or_error.join
  >>| function
  | Error error ->
    append_diagnostic diagnostics ("request error: " ^ error_message error);
    Error (error_message error)
  | Ok (Error error) ->
    let message = protocol_error error in
    append_diagnostic diagnostics ("protocol error: " ^ message);
    Error message
  | Ok (Ok value) -> Ok value
;;

let hello_request diagnostics thunk =
  Monitor.try_with_or_error thunk
  >>| Or_error.join
  >>| Result.map_error ~f:(fun error ->
    let message = error_message error in
    append_diagnostic diagnostics ("connection error: " ^ message);
    message)
;;

let explicit_client endpoint =
  let uri = Uri.of_string endpoint in
  match Uri.scheme uri, Uri.host uri with
  | Some scheme, Some host
    when String.Caseless.equal scheme "http"
         && (String.Caseless.equal host "localhost"
             || String.equal host "127.0.0.1"
             || String.equal host "::1") -> Ok (Http.Client.create endpoint)
  | _ ->
    Or_error.error_string
      "--connect must be an http://localhost, http://127.0.0.1, or http://[::1] endpoint"
;;

let connect_client ~endpoint ~diagnostics =
  match endpoint with
  | Some endpoint ->
    (match explicit_client endpoint with
     | Error error -> return (Error (error_message error))
     | Ok client ->
       let%map hello = hello_request diagnostics (fun () -> Http.Client.hello client) in
       Result.map hello ~f:(fun hello -> client, hello))
  | None ->
    Monitor.try_with_or_error Http.Runtime.connect_or_start
    >>| Or_error.join
    >>| Result.map_error ~f:(fun error ->
      let message = error_message error in
      append_diagnostic diagnostics ("startup error: " ^ message);
      message)
;;

let check_version hello =
  if List.mem hello.V1.Hello.Response.protocol_versions V1.version ~equal:Int.equal
  then Ok ()
  else
    Or_error.error_s
      [%message
        "daemon does not support this client's protocol version"
          (V1.version : int)
          (hello.protocol_versions : int list)]
;;

let load_state ~endpoint ~project_root ~environment_selection ~diagnostics =
  let%bind connected = connect_client ~endpoint ~diagnostics in
  match connected with
  | Error _ as error -> return error
  | Ok (client, hello) ->
    (match check_version hello with
     | Error error -> return (Error (error_message error))
     | Ok () ->
       let instance_id = hello.instance_id in
       let%bind opened =
         match project_root with
         | None -> return (Ok None)
         | Some root ->
           request diagnostics (fun () ->
             Http.Client.open_project
               client
               { instance_id; root; environment = environment_selection })
           >>| Result.map ~f:Option.some
       in
       (match opened with
        | Error _ as error -> return error
        | Ok opened ->
          let%map snapshot =
            request diagnostics (fun () -> Http.Client.snapshot client { instance_id })
          in
          Result.map snapshot ~f:(fun snapshot -> client, hello, opened, snapshot)))
;;

let create_session
  ~endpoint
  ~project_root
  ~environment_selection
  ~environment_label
  ~diagnostics_file
  =
  let%map loaded =
    load_state
      ~endpoint
      ~project_root
      ~environment_selection
      ~diagnostics:diagnostics_file
  in
  Result.map loaded ~f:(fun (client, hello, opened, snapshot) ->
    let session =
      { requested_endpoint = endpoint
      ; project_root
      ; environment_selection
      ; environment_label
      ; diagnostics_file
      ; client
      ; hello
      ; opened
      ; snapshot
      ; selected = 0
      ; selected_target = None
      ; selected_configuration = None
      ; selected_artifact = None
      ; artifact_view = None
      ; hierarchy_view = None
      ; hierarchy_intent = ref ()
      ; hierarchy_errors = Artifact_id.Table.create ()
      ; hierarchy_reads = ref []
      ; logs = Job_id.Table.create ()
      ; status = "connected"
      ; polling = false
      ; hydration = Terminal_presentation.Retained_hydration.Coordinator.create ()
      ; retained_reads = Terminal_presentation.Retained_hydration.create ()
      ; navigation_loaded = Terminal_presentation.Retained_hydration.Load.create ()
      ; navigation_pending = None
      ; navigation_saved = None
      ; navigation_failed = false
      ; navigation_revision = 0
      ; navigation_restore_revision = 0
      ; navigation_touched = []
      ; navigation_focus_touched = []
      ; reconnect_delay_ms = 250
      ; last_dimensions = None
      ; show_connection_details = false
      ; connection_details_scroll = 0
      ; host = Host.empty
      ; workspace_config = None
      ; registry_busy = false
      ; asic = None
      ; asic_request_id = 0
      ; resource_navigation_intent = ref ()
      ; preparation_request_id = 0
      ; asic_applied_id = 0
      ; timing_demand = None
      ; timing_preload = Terminal_presentation.Timing_preload.empty
      ; timing_index_inflight = []
      ; timing_preload_receipt = None
      ; view_on_allocation = None
      ; remembered_selection = None
      ; preferences_loaded = false
      ; presentation_preferences_loaded = None
      ; presentation_preferences = None
      ; presentation_preference_notice = None
      ; preference_saves = Deferred.unit
      ; asic_reads = Asic_intents.empty
      ; remembered_acceptance = ""
      ; artifact_viewer = None
      ; artifact_binary_viewer = None
      ; artifact_export_busy = false
      ; waveform = None
      ; waveform_visible = false
      ; waveform_generation = 0
      ; waveform_history = []
      ; waveform_workspaces = []
      ; waveform_preferences_loaded = None
      ; waveform_preferences_pending = None
      ; waveform_preferences_saved = None
      ; waveform_preferences_failed = false
      ; waveform_open_generation = 0
      ; waveform_value_layout = Inline
      ; waveform_display_loaded = None
      ; waveform_display_revision = 0
      }
    in
    session)
;;

let project_jobs session =
  let jobs =
    match session.opened with
    | None -> session.snapshot.jobs
    | Some opened ->
      List.filter session.snapshot.jobs ~f:(fun job ->
        Project_id.equal job.project opened.project.id)
  in
  List.sort jobs ~compare:(fun a b -> Timestamp.compare b.created_at a.created_at)
;;

let current_project session =
  State.current_project ~opened:session.opened session.snapshot
;;

let plan_scope session (project : Project.t) =
  Sexp.to_string_mach
    (Sexp.List
       [ V1.Daemon_instance_id.sexp_of_t session.hello.instance_id
       ; Project_id.sexp_of_t project.id
       ])
;;

let project_artifacts session =
  match current_project session with
  | None -> []
  | Some project ->
    List.filter session.snapshot.artifacts ~f:(fun artifact ->
      Project_id.equal artifact.project project.id)
    |> List.sort ~compare:(fun a b ->
      Timestamp.compare b.metadata.provenance.created_at a.metadata.provenance.created_at)
;;

let reconcile_selection session =
  match current_project session with
  | None ->
    session.host
    <- { session.host with
         planned_run = Planned_run.reset session.host.planned_run ~scope:""
       ; preparation_rtl_scope = None
       };
    session.asic <- None;
    session.selected_target <- None;
    session.selected_configuration <- None;
    session.selected_artifact <- None;
    session.artifact_view <- None;
    session.hierarchy_view <- None
  | Some project ->
    let planned_run =
      Planned_run.reset session.host.planned_run ~scope:(plan_scope session project)
    in
    if not (phys_equal planned_run session.host.planned_run) then session.asic <- None;
    session.host <- { session.host with planned_run };
    let target, configuration =
      State.reconcile_selection
        project
        ~target:session.selected_target
        ~configuration:session.selected_configuration
    in
    session.selected_target <- target;
    session.selected_configuration <- configuration;
    session.host
    <- { session.host with
         preparation_rtl_scope =
           Terminal_presentation.Preparation_view.Rtl_scope.create
             ~project:(Some project)
             ~target
             ~configuration
       };
    let artifacts = project_artifacts session in
    let selected_artifact =
      Option.first_some
        (Option.bind session.selected_artifact ~f:(fun id ->
           List.find artifacts ~f:(fun artifact -> Artifact_id.equal artifact.id id)))
        (List.hd artifacts)
    in
    session.selected_artifact
    <- Option.map selected_artifact ~f:(fun artifact -> artifact.id);
    Option.iter session.artifact_view ~f:(fun view ->
      if not
           (Option.value_map session.selected_artifact ~default:false ~f:(fun id ->
              Artifact_id.equal id view.artifact))
      then session.artifact_view <- None);
    Option.iter session.hierarchy_view ~f:(fun view ->
      if not
           (List.exists artifacts ~f:(fun artifact ->
              Artifact_id.equal artifact.id view.hierarchy.artifact))
      then session.hierarchy_view <- None)
;;

let selected_target session =
  match current_project session, session.selected_target with
  | Some project, Some id ->
    List.find project.targets ~f:(fun target -> Target_id.equal target.id id)
  | _ -> None
;;

let selected_configuration session =
  match current_project session, session.selected_configuration with
  | Some project, Some id ->
    List.find project.configurations ~f:(fun configuration ->
      Configuration_id.equal configuration.id id)
  | _ -> None
;;

let selected_artifact session =
  Option.bind session.selected_artifact ~f:(fun id ->
    List.find (project_artifacts session) ~f:(fun artifact ->
      Artifact_id.equal artifact.id id))
;;

let selected_job session = List.nth (project_jobs session) session.selected

let preserve_selected_job session selected_job_id =
  let jobs = project_jobs session in
  session.selected
  <- State.preserve_job_selection
       jobs
       ~selected_job:selected_job_id
       ~fallback_index:session.selected
;;

let is_hierarchy_artifact (artifact : Artifact.t) =
  String.equal artifact.kind.namespace "hardcaml"
  && String.equal artifact.kind.name "elaboration-hierarchy"
  && Artifact.Role.equal artifact.kind.role Report
  && Option.equal
       String.equal
       artifact.kind.media
       (Some "application/x-hardcaml-workbench-hierarchy-sexp")
;;

let hierarchy_artifact_for_job session job =
  List.find_map job.Job.artifacts ~f:(fun id ->
    List.find session.snapshot.artifacts ~f:(fun artifact ->
      Artifact_id.equal artifact.id id && is_hierarchy_artifact artifact))
;;

let current_generation session =
  match
    current_project session, session.selected_target, session.selected_configuration
  with
  | Some project, Some target, Some configuration ->
    State.latest_generation
      session.snapshot.jobs
      ~project:project.id
      ~target
      ~configuration
  | _ -> None
;;

let log_state session job =
  Hashtbl.find_or_add session.logs job ~default:(fun () ->
    { next_offset = 0; records = []; fetch = Presentation.Log_fetch.Not_requested })
;;

let read_job_log_id session (job : Job_id.t option) =
  match job with
  | None -> return ()
  | Some job ->
    let state = log_state session job in
    (match state.fetch with
     | Presentation.Log_fetch.Received { eof = true } -> return ()
     | _ ->
       let requested_instance = session.hello.instance_id in
       state.fetch <- Presentation.Log_fetch.Fetching;
       let%map response =
         request session.diagnostics_file (fun () ->
           Http.Client.read_log
             session.client
             { instance_id = session.hello.instance_id
             ; job
             ; offset = state.next_offset
             ; max_records = 128
             ; max_bytes = V1.max_log_bytes
             })
       in
       (match response with
        | _
          when not
                 (V1.Daemon_instance_id.equal
                    requested_instance
                    session.hello.instance_id) -> ()
        | Error message -> state.fetch <- Presentation.Log_fetch.Error message
        | Ok payload ->
          let records =
            List.filter payload.records ~f:(fun record ->
              record.offset >= state.next_offset)
          in
          state.next_offset <- payload.next_offset;
          state.records <- take_end (state.records @ records) console_limit;
          state.fetch <- Presentation.Log_fetch.Received { eof = payload.eof }))
;;

let read_job_log session job =
  read_job_log_id session (Option.map job ~f:(fun (j : Job.t) -> j.id))
;;

let read_selected_log session = read_job_log session (selected_job session)

let updates_request diagnostics thunk =
  Monitor.try_with_or_error thunk
  >>| Or_error.join
  >>| function
  | Error error -> Error (`Transport (error_message error))
  | Ok (Error error) -> Error (`Protocol error)
  | Ok (Ok payload) -> Ok payload
;;

let snapshot_request session ~instance_id =
  request session.diagnostics_file (fun () ->
    Http.Client.snapshot session.client { instance_id })
;;

let preference_context session =
  let opened = Option.value_exn session.opened in
  let project_key =
    Sexp.to_string_mach
      (Sexp.List
         [ Atom (Project_root.to_absolute_path opened.project.root)
         ; V1.Environment_selection.sexp_of_t opened.environment.selection
         ])
  in
  let state_directory =
    match Sys.getenv "XDG_STATE_HOME", Sys.getenv "HOME" with
    | Some directory, _ when not (String.is_empty directory) -> directory
    | _, Some home -> Filename.concat home ".local/state"
    | _ -> failwith "No XDG_STATE_HOME or HOME for terminal preferences"
  in
  let state_directory = Filename.concat state_directory "hardcaml-workbench/terminal" in
  project_key, state_directory
;;

let preference_location session =
  let project_key, state_directory = preference_context session in
  project_key, Launch_preferences.path ~state_directory ~project_key
;;

let presentation_preference_error session message error =
  let message = message ^ ": " ^ Error.to_string_hum error in
  session.presentation_preference_notice <- Some message;
  append_diagnostic session.diagnostics_file message
;;

let load_presentation_preferences session =
  if Option.is_none session.opened
  then return ()
  else (
    match Or_error.try_with (fun () -> preference_context session) with
    | Error error ->
      presentation_preference_error
        session
        "Could not load presentation preferences; using defaults (file left untouched)"
        error;
      return ()
    | Ok (project_key, state_directory) ->
      if Option.equal
           String.equal
           session.presentation_preferences_loaded
           (Some project_key)
      then return ()
      else (
        session.host <- Host.invalidate_layout_intent session.host;
        (* Reopening a changed canonical project/environment must not carry the previous
           context's presentation into the new registry. *)
        if Option.is_some session.presentation_preferences_loaded
        then
          session.host
          <- { session.host with
               appearance = Appearance.default
             ; layout_mode = Fit
             ; chrome = true
             ; main_hints = true
             ; palette_hints = true
             ; timing_preload = true
             ; quick_launch_view = true
             ; planned_preparation = true
             ; locals = []
             };
        session.presentation_preferences_loaded <- Some project_key;
        session.presentation_preferences <- None;
        session.presentation_preference_notice <- None;
        let%map result =
          In_thread.run (fun () ->
            Or_error.try_with (fun () ->
              Presentation_preferences.load ~state_directory ~project_key))
        in
        (match result with
         | Ok preferences ->
           session.presentation_preferences
           <- (if Option.is_none session.host.registry then preferences else None);
           Option.iter preferences ~f:(fun preferences ->
             session.host <- Presentation_preferences.apply preferences session.host)
         | Error error ->
           presentation_preference_error
             session
             "Could not load presentation preferences; using defaults (file left \
              untouched)"
             error);
        Option.iter !timing_preload_override ~f:(fun timing_preload ->
          session.host <- { session.host with timing_preload })))
;;

let save_presentation_preferences session =
  (* Capture before yielding, so polling and later keypresses cannot change this save. *)
  match Or_error.try_with (fun () -> preference_context session) with
  | Error error ->
    presentation_preference_error session "Could not save presentation preferences" error;
    return ()
  | Ok (project_key, state_directory) ->
    let preferences = Presentation_preferences.capture ~project_key session.host in
    session.presentation_preferences <- None;
    let previous = session.preference_saves in
    let finished = Ivar.create () in
    session.preference_saves <- Ivar.read finished;
    Monitor.protect
      ~finally:(fun () ->
        Ivar.fill_exn finished ();
        Deferred.unit)
      (fun () ->
        let%bind () = previous in
        let%map result =
          In_thread.run (fun () ->
            Or_error.try_with (fun () ->
              Presentation_preferences.save ~state_directory preferences))
        in
        if Option.equal
             String.equal
             session.presentation_preferences_loaded
             (Some project_key)
        then (
          match result with
          | Ok () -> session.presentation_preference_notice <- None
          | Error error ->
            presentation_preference_error
              session
              "Could not save presentation preferences"
              error))
;;

let apply_waveform_preferences session =
  if Option.is_some session.host.registry
  then (
    Option.iter session.waveform_preferences_pending ~f:(fun saved ->
      session.host <- Host.restore_waveform_preferences saved session.host);
    session.waveform_preferences_pending <- None)
;;

let load_waveform_display_preferences session =
  match Or_error.try_with (fun () -> preference_context session) with
  | Error _ -> return ()
  | Ok (project_key, state_directory) ->
    if Option.equal String.equal session.waveform_display_loaded (Some project_key)
    then return ()
    else (
      session.waveform_display_loaded <- Some project_key;
      session.waveform_value_layout <- Inline;
      let revision = session.waveform_display_revision in
      let%map result =
        In_thread.run (fun () ->
          Or_error.try_with (fun () ->
            Waveform_preferences.load ~state_directory ~project_key))
      in
      if session.waveform_display_revision = revision
         && Option.equal String.equal session.waveform_display_loaded (Some project_key)
         &&
         match Or_error.try_with (fun () -> fst (preference_context session)) with
         | Ok current -> String.equal current project_key
         | Error _ -> false
      then (
        match result with
        | Ok saved ->
          session.waveform_value_layout
          <- Option.value_map saved ~default:Waveform_view.Inline ~f:(fun saved ->
               saved.Waveform_preferences.value_layout)
        | Error e ->
          presentation_preference_error
            session
            "Could not load waveform display preferences (file left untouched)"
            e))
;;

let save_waveform_display_preferences session =
  match Or_error.try_with (fun () -> preference_context session) with
  | Error e ->
    presentation_preference_error session "Could not save waveform display preferences" e;
    return ()
  | Ok (project_key, state_directory) ->
    let saved = Waveform_preferences.create ~project_key session.waveform_value_layout in
    let previous = session.preference_saves in
    let finished = Ivar.create () in
    session.preference_saves <- Ivar.read finished;
    Monitor.protect
      ~finally:(fun () ->
        Ivar.fill_exn finished ();
        return ())
      (fun () ->
        let%bind () = previous in
        let%map result =
          In_thread.run (fun () ->
            Or_error.try_with (fun () -> Waveform_preferences.save ~state_directory saved))
        in
        match result with
        | Ok () -> ()
        | Error e ->
          presentation_preference_error
            session
            "Could not save waveform display preferences"
            e)
;;

let load_waveform_preferences session =
  match Or_error.try_with (fun () -> preference_context session) with
  | Error _ -> return ()
  | Ok (project_key, state_directory) ->
    if Option.equal String.equal session.waveform_preferences_loaded (Some project_key)
    then return ()
    else (
      session.waveform_preferences_loaded <- Some project_key;
      session.waveform_preferences_pending <- None;
      session.waveform_preferences_saved <- None;
      session.waveform_preferences_failed <- false;
      let%map result =
        In_thread.run (fun () ->
          Or_error.try_with (fun () ->
            Host.load_waveform_preferences ~state_directory ~project_key))
      in
      if Option.equal String.equal session.waveform_preferences_loaded (Some project_key)
      then (
        match result with
        | Ok saved ->
          session.waveform_preferences_pending <- saved;
          session.waveform_preferences_saved
          <- Option.map saved ~f:Host.encode_waveform_preferences
        | Error e ->
          session.waveform_preferences_failed <- true;
          presentation_preference_error session "Could not load Waveforms pins" e))
;;

let save_waveform_preferences session =
  match Or_error.try_with (fun () -> preference_context session) with
  | Error _ -> return ()
  | Ok (project_key, state_directory) ->
    if session.waveform_preferences_failed
       || Option.is_none session.host.registry
       || not
            (Option.equal
               String.equal
               session.waveform_preferences_loaded
               (Some project_key))
    then return ()
    else (
      let saved = Host.waveform_preferences ~project_key session.host in
      let encoded = Host.encode_waveform_preferences saved in
      if Option.is_none session.waveform_preferences_saved
         && List.is_empty session.host.waveforms
      then (
        session.waveform_preferences_saved <- Some encoded;
        return ())
      else if Option.equal String.equal session.waveform_preferences_saved (Some encoded)
      then return ()
      else (
        session.waveform_preferences_saved <- Some encoded;
        let previous = session.preference_saves in
        let finished = Ivar.create () in
        session.preference_saves <- Ivar.read finished;
        Monitor.protect
          ~finally:(fun () ->
            Ivar.fill_exn finished ();
            return ())
          (fun () ->
            let%bind () = previous in
            let%map result =
              In_thread.run (fun () ->
                Or_error.try_with (fun () ->
                  Host.save_waveform_preferences ~state_directory saved))
            in
            match result with
            | Ok () -> ()
            | Error e ->
              presentation_preference_error session "Could not save Waveforms pins" e)))
;;

let load_navigation_preferences session =
  let module N = Terminal_presentation.Navigation_preferences in
  if Option.is_none session.opened
  then return ()
  else (
    match Or_error.try_with (fun () -> preference_context session) with
    | Error error ->
      session.navigation_failed <- true;
      presentation_preference_error session "Could not load navigation preferences" error;
      return ()
    | Ok (project_key, state_directory) ->
      if Terminal_presentation.Retained_hydration.Load.loaded
           session.navigation_loaded
           project_key
      then return ()
      else (
        let ticket =
          Terminal_presentation.Retained_hydration.Load.begin_load
            session.navigation_loaded
        in
        session.navigation_failed <- false;
        let client = session.client in
        let%map result =
          In_thread.run (fun () ->
            Or_error.try_with (fun () -> N.load ~state_directory ~project_key))
        in
        if phys_equal client session.client
           && Terminal_presentation.Retained_hydration.Load.complete
                session.navigation_loaded
                ticket
                project_key
        then (
          match result with
          | Error error ->
            session.navigation_failed <- true;
            presentation_preference_error
              session
              "Could not load navigation preferences (file left untouched)"
              error
          | Ok saved ->
            session.navigation_saved <- Option.map saved ~f:N.encode;
            session.navigation_pending <- saved)))
;;

let apply_navigation_preferences session =
  match session.navigation_pending, session.host.registry, current_project session with
  | Some saved, Some _, Some project ->
    session.navigation_pending <- None;
    session.host
    <- Host.restore_navigation_focus
         saved
         session.host
         ~restore_active:
           (session.navigation_revision = session.navigation_restore_revision)
         ~preserve_focus:session.navigation_focus_touched;
    let saved =
      { saved with
        workspaces =
          List.filter saved.workspaces ~f:(fun workspace ->
            not (List.mem session.navigation_touched workspace.id ~equal:String.equal))
      }
    in
    session.host
    <- Host.restore_navigation_selections
         saved
         session.host
         ~scope:(Project_id.to_string project.id)
  | _ -> ()
;;

let save_navigation_preferences session =
  let module N = Terminal_presentation.Navigation_preferences in
  if session.navigation_failed
     || Option.is_some session.navigation_pending
     || Terminal_presentation.Retained_hydration.Coordinator.busy session.hydration
     || not
          (Terminal_presentation.Retained_hydration.Load.ready session.navigation_loaded)
  then return ()
  else (
    match
      Or_error.try_with (fun () ->
        let project_key, state_directory = preference_context session in
        let saved = Host.navigation_preferences ~project_key session.host in
        state_directory, saved)
    with
    | Error error ->
      presentation_preference_error session "Could not save navigation preferences" error;
      return ()
    | Ok (_, None) -> return ()
    | Ok (state_directory, Some saved) ->
      (* Inactive or not-yet-hydrated panes must not erase saved investigation intent. *)
      let baseline =
        Option.bind session.navigation_saved ~f:(fun encoded ->
          Or_error.try_with (fun () -> N.decode ~project_key:saved.project_key encoded)
          |> Result.ok)
      in
      let valid =
        Option.value_map baseline ~default:[] ~f:(fun baseline ->
          Host.valid_navigation_workspaces baseline session.host)
      in
      let saved =
        { saved with
          workspaces =
            List.map saved.workspaces ~f:(fun workspace ->
              match List.find valid ~f:(fun old -> String.equal old.id workspace.id) with
              | None -> workspace
              | Some old ->
                { workspace with
                  testing = Option.first_some workspace.testing old.testing
                ; timing = Option.first_some workspace.timing old.timing
                })
        }
      in
      let encoded = N.encode saved in
      if Option.equal String.equal session.navigation_saved (Some encoded)
      then return ()
      else (
        session.navigation_saved <- Some encoded;
        let previous = session.preference_saves in
        let finished = Ivar.create () in
        session.preference_saves <- Ivar.read finished;
        Monitor.protect
          ~finally:(fun () ->
            Ivar.fill_exn finished ();
            return ())
          (fun () ->
            let%bind () = previous in
            let%map result =
              In_thread.run (fun () ->
                Or_error.try_with (fun () -> N.save ~state_directory saved))
            in
            match result with
            | Ok () -> ()
            | Error error ->
              session.navigation_failed <- true;
              presentation_preference_error
                session
                "Could not save navigation preferences"
                error)))
;;

let load_preferences session =
  if session.preferences_loaded || Option.is_none session.opened
  then return ()
  else (
    session.preferences_loaded <- true;
    let%map result =
      In_thread.run (fun () ->
        Or_error.try_with (fun () ->
          let project_key, path = preference_location session in
          match Sys_unix.file_exists path with
          | `No -> None
          | `Unknown -> failwith ("Cannot inspect terminal preferences: " ^ path)
          | `Yes ->
            let content = In_channel.read_all path in
            if String.length content > 64 * 1024
            then failwith "Terminal preference size limit exceeded";
            Some (Launch_preferences.decode ~project_key (Sexp.of_string content))))
    in
    match result with
    | Ok selection ->
      session.remembered_selection <- selection;
      session.host <- { session.host with remembered_selection = selection }
    | Error error ->
      append_diagnostic
        session.diagnostics_file
        ("preference load: " ^ Error.to_string_hum error))
;;

let save_preferences session selection =
  session.remembered_selection <- Some selection;
  session.host <- { session.host with remembered_selection = Some selection };
  let previous = session.preference_saves in
  let finished = Ivar.create () in
  session.preference_saves <- Ivar.read finished;
  Monitor.protect
    ~finally:(fun () ->
      Ivar.fill_exn finished ();
      Deferred.unit)
    (fun () ->
      let%bind () = previous in
      let%map result =
        In_thread.run (fun () ->
          Or_error.try_with (fun () ->
            let project_key, path = preference_location session in
            let directory = Filename.dirname path in
            Core_unix.mkdir_p directory ~perm:0o700;
            let temp = Filename_unix.temp_file ~in_dir:directory ".launch-" ".tmp" in
            Exn.protect
              ~finally:(fun () ->
                if Poly.equal (Sys_unix.file_exists temp) `Yes then Core_unix.unlink temp)
              ~f:(fun () ->
                Out_channel.write_all
                  temp
                  ~data:
                    (Sexp.to_string_hum
                       (Launch_preferences.sexp_of_t
                          (Launch_preferences.create ~project_key selection))
                     ^ "\n");
                Core_unix.rename ~src:temp ~dst:path)))
      in
      match result with
      | Ok () -> ()
      | Error error ->
        session.host
        <- { session.host with
             notice = "Could not save launch preferences: " ^ Error.to_string_hum error
           })
;;

let synthesis_summary session tile =
  Option.bind session.host.registry ~f:(fun registry ->
    Workspace.resolve_tile registry tile.Workspace.Tile.id
    |> Result.ok
    |> Option.bind ~f:(fun reference -> reference.run)
    |> Option.bind ~f:(fun run ->
      Option.bind session.asic ~f:(fun asic ->
        List.find asic.summaries ~f:(fun summary ->
          Run_ref.equal summary.Asic.Summary.run run))))
;;

let terminal_result_context session tile =
  Option.bind session.host.registry ~f:(fun registry ->
    Workspace.resolve_tile registry tile.Workspace.Tile.id
    |> Result.ok
    |> Option.bind ~f:(fun reference -> reference.run)
    |> Option.map ~f:(fun run -> run, synthesis_summary session tile))
;;

let reconcile_synthesis session =
  session.host <- Host.reconcile_builtin_timing session.host session.asic;
  Option.iter session.host.registry ~f:(fun registry ->
    (* A fresh terminal has no local Timing state. Resolve the exact tile binding and
       choose only a retained index for that run; activation never asks a provider. *)
    List.iter registry.tiles ~f:(fun tile ->
      if Option.is_some (Timing_workspace.pane tile.kind)
         && (not
               (List.exists (Host.builtin_timing_workspaces registry) ~f:(fun w ->
                  Workspace.Workspace_id.equal w.id tile.workspace)))
         && Option.is_none (Host.timing session.host tile)
      then
        Option.iter session.asic ~f:(fun snapshot ->
          Workspace.resolve_tile registry tile.id
          |> Result.ok
          |> Option.bind ~f:(fun reference -> reference.run)
          |> Option.iter ~f:(fun run ->
            List.find snapshot.inspections ~f:(fun index ->
              Run_ref.equal index.run run && String.equal index.domain "timing")
            |> Option.iter ~f:(fun index ->
              let view = Timing_workspace.create ~generation:0 ~run ~stage:index.stage in
              session.host <- Host.set_timing session.host tile view))));
    let timing =
      List.filter_map session.host.timing ~f:(fun (id, view) ->
        let workspace =
          List.find registry.workspaces ~f:(fun w ->
            String.equal id (Workspace.Workspace_id.to_string w.id))
        in
        Option.bind workspace ~f:(fun workspace ->
          let resolved_run =
            List.find registry.tiles ~f:(fun tile ->
              Workspace.Workspace_id.equal tile.workspace workspace.id
              && String.equal tile.kind "timing-paths")
            |> Option.bind ~f:(fun tile ->
              Workspace.resolve_tile registry tile.id |> Result.ok)
            |> Option.bind ~f:(fun reference -> reference.run)
          in
          Option.map resolved_run ~f:(fun run ->
            let view =
              if Run_ref.equal run view.Inspection_view.run
                 && Option.equal
                      String.equal
                      view.workspace_epoch
                      (Some (Host.timing_epoch registry workspace.id))
              then view
              else
                Timing_workspace.create
                  ~generation:(view.generation + 1)
                  ~run
                  ~stage:view.stage
            in
            let view =
              { view with
                Inspection_view.workspace_epoch =
                  Some (Host.timing_epoch registry workspace.id)
              }
            in
            ( id
            , Option.value_map session.asic ~default:view ~f:(fun snapshot ->
                if Option.is_none view.index
                then Timing_workspace.attach_retained view snapshot
                else Inspection_view.reconcile view snapshot) ))))
    in
    session.host <- { session.host with timing };
    List.iter registry.tiles ~f:(fun tile ->
      let local = Host.local session.host tile.id in
      let artifacts =
        Option.bind local.artifacts ~f:(fun view ->
          Workspace.resolve_tile registry tile.id
          |> Result.ok
          |> Option.bind ~f:(fun reference ->
            Artifact_view.reconcile_scope view ~scope:reference.run)
          |> Option.map ~f:(fun view ->
            let view =
              Option.value_map
                session.asic
                ~default:view
                ~f:(Artifact_view.reconcile view)
            in
            Option.value_map session.last_dimensions ~default:view ~f:(fun dimensions ->
              Artifact_view.clamp view ~width:dimensions.width ~height:dimensions.height)))
      in
      let inspection =
        Option.bind local.inspection ~f:(fun view ->
          Workspace.resolve_tile registry tile.id
          |> Result.ok
          |> Option.bind ~f:(fun reference ->
            Inspection_view.reconcile_scope view ~scope:reference.run)
          |> Option.map ~f:(fun view ->
            let view =
              Option.value_map
                session.asic
                ~default:view
                ~f:(Inspection_view.reconcile view)
            in
            Option.value_map session.last_dimensions ~default:view ~f:(fun dimensions ->
              let width, height = Host_view.inspection_viewport dimensions in
              Inspection_view.clamp view ~width ~height)))
      in
      session.host
      <- Host.set_local session.host tile.id { local with artifacts; inspection };
      if Resources_view.is_kind tile.kind
      then (
        let local = Host.local session.host tile.id in
        let resources =
          Resources_view.reconcile
            ~revision:session.asic_applied_id
            local.resources
            ~run:(Host.tile_run session.host tile)
            ~filter:local.filter
            session.asic
        in
        session.host <- Host.set_local session.host tile.id { local with resources });
      if String.equal tile.kind "workloads"
      then (
        let local = Host.local session.host tile.id in
        let workloads =
          Workloads_view.reconcile
            ~revision:session.asic_applied_id
            local.workloads
            session.asic
        in
        session.host <- Host.set_local session.host tile.id { local with workloads });
      if String.equal tile.kind "synthesis"
      then (
        let local = Host.local session.host tile.id in
        let synthesis =
          Synthesis_view.State.reconcile
            local.synthesis
            ~summary:(synthesis_summary session tile)
            ~filter:local.filter
        in
        session.host <- Host.set_local session.host tile.id { local with synthesis })
      else if String.equal tile.kind "stage-checklist"
      then (
        let local = Host.local session.host tile.id in
        let run =
          Workspace.resolve_tile registry tile.id
          |> Result.ok
          |> Option.bind ~f:(fun reference -> reference.run)
        in
        let stages =
          Option.value_map run ~default:[] ~f:(fun run ->
            Terminal_presentation.Overview_tiles.checklist_items ~asic:session.asic ~run)
        in
        session.host
        <- Host.set_local
             session.host
             tile.id
             (Host.reconcile_checklist local ~run ~items:stages))
      else if Terminal_result_view.supports tile.kind
      then (
        let local = Host.local session.host tile.id in
        let terminal_result =
          match terminal_result_context session tile with
          | None -> Terminal_result_view.State.empty
          | Some (run, summary) ->
            Terminal_result_view.State.reconcile local.terminal_result ~run ~summary
        in
        session.host <- Host.set_local session.host tile.id { local with terminal_result })));
  session.host <- Host.reconcile_navigation_timing session.host session.asic
;;

let change_terminal_result session f =
  reconcile_synthesis session;
  Option.iter (Host.focused session.host) ~f:(fun tile ->
    if Terminal_result_view.supports tile.kind
    then (
      let local = Host.local session.host tile.id in
      session.host
      <- Host.set_local
           session.host
           tile.id
           { local with terminal_result = f local.terminal_result }))
;;

let change_synthesis session f =
  reconcile_synthesis session;
  Option.iter (Host.focused session.host) ~f:(fun tile ->
    if String.equal tile.kind "synthesis"
    then (
      let local = Host.local session.host tile.id in
      let (next : Host.local) = f tile local in
      let next =
        if Synthesis_view.Mode.equal
             (Synthesis_view.State.mode local.synthesis)
             (Synthesis_view.State.mode next.synthesis)
        then next
        else { next with scroll = 0; metrics_scope = None }
      in
      session.host <- Host.set_local session.host tile.id next))
;;

let workspace_request ?(on_snapshot = fun _ -> ()) session operation =
  match current_project session with
  | None -> return ()
  | Some project ->
    let instance_id = session.hello.instance_id in
    let client = session.client in
    let%map response =
      request session.diagnostics_file (fun () ->
        Http.Client.workspace client { instance_id; project = project.id; operation })
    in
    if phys_equal client session.client
       && V1.Daemon_instance_id.equal instance_id session.hello.instance_id
       && Option.value_map (current_project session) ~default:false ~f:(fun p ->
         Project_id.equal p.id project.id)
    then (
      match response with
      | Error message ->
        session.host <- { session.host with notice = "Workspace: " ^ message }
      | Ok snapshot ->
        if Option.exists session.host.registry ~f:(fun previous ->
             not (Workspace.Session_id.equal previous.session_id snapshot.session_id))
        then (
          Terminal_presentation.Retained_hydration.Load.reconnect
            session.navigation_loaded
            ~replacement:true;
          session.navigation_pending <- None;
          session.navigation_restore_revision <- session.navigation_revision;
          session.navigation_touched <- [];
          session.navigation_focus_touched <- [];
          session.waveform_preferences_loaded <- None;
          session.waveform_preferences_pending <- None;
          session.retained_reads <- Terminal_presentation.Retained_hydration.create ();
          Terminal_presentation.Retained_hydration.Coordinator.invalidate
            session.hydration);
        let host, pending =
          Presentation_preferences.receive
            session.presentation_preferences
            session.host
            snapshot
        in
        session.host <- host;
        session.presentation_preferences <- pending;
        apply_waveform_preferences session;
        reconcile_synthesis session;
        on_snapshot snapshot)
;;

let mutate_workspace ?on_snapshot session mutation =
  match session.host.registry with
  | None -> return ()
  | Some snapshot ->
    if session.registry_busy
    then (
      session.host
      <- { session.host with notice = "Workspace update pending; retry deliberately" };
      return ())
    else (
      session.registry_busy <- true;
      Monitor.protect
        ~finally:(fun () ->
          session.registry_busy <- false;
          return ())
        (fun () ->
          let%bind () =
            workspace_request
              ?on_snapshot
              session
              (Mutate { expected_revision = snapshot.revision; mutation })
          in
          (* Refresh after a conflict, but never silently retry the captured mutation. *)
          let notice = session.host.notice in
          let%map () = workspace_request session Get in
          if not (String.is_empty notice)
          then session.host <- { session.host with notice }))
;;

let restore_default_layout session (captured : Host.capture) ticket workspace definition =
  match current_project session with
  | None -> return ()
  | Some project ->
    if (not (Host.current session.host captured))
       || not (Workspace.Workspace_id.equal workspace captured.workspace)
    then return ()
    else if session.registry_busy
    then (
      session.host
      <- { session.host with notice = "Workspace update pending; retry deliberately" };
      return ())
    else (
      let instance_id = session.hello.instance_id in
      let client = session.client in
      session.registry_busy <- true;
      Monitor.protect
        ~finally:(fun () ->
          session.registry_busy <- false;
          return ())
        (fun () ->
          let%bind response =
            request session.diagnostics_file (fun () ->
              Http.Client.workspace
                client
                { instance_id
                ; project = project.id
                ; operation =
                    Mutate
                      { expected_revision = captured.revision
                      ; mutation =
                          Hardcaml_workbench_workspaces.Definition.restore
                            definition
                            ~workspace
                      }
                })
          in
          if not
               (phys_equal client session.client
                && V1.Daemon_instance_id.equal instance_id session.hello.instance_id
                && Option.value_map (current_project session) ~default:false ~f:(fun p ->
                  Project_id.equal p.id project.id))
          then return ()
          else (
            let acknowledged =
              match response with
              | Error message ->
                session.host <- { session.host with notice = "Workspace: " ^ message };
                false
              | Ok snapshot ->
                let host, pending =
                  Presentation_preferences.receive
                    session.presentation_preferences
                    session.host
                    snapshot
                in
                session.host <- host;
                session.presentation_preferences <- pending;
                reconcile_synthesis session;
                Workspace.Session_id.equal snapshot.session_id captured.session
            in
            let host, save = Host.finish_restore session.host ticket ~acknowledged in
            session.host <- host;
            if save then save_presentation_preferences session else return ())))
;;

let capture_artifact_request session (tile : Workspace.Tile.t) view operation =
  Option.bind (current_project session) ~f:(fun project ->
    Artifact_view.capture
      view
      ~instance_id:session.hello.instance_id
      ~project:project.id
      operation
    |> Option.map ~f:(fun ticket -> tile.id, ticket))
;;

let timing_preload_scope session =
  Sexp.to_string
    ([%sexp_of: V1.Daemon_instance_id.t * Project_id.t option]
       (session.hello.instance_id, Option.map (current_project session) ~f:(fun p -> p.id)))
;;

let rec asic_request
  ?artifact_request
  ?inspection_request
  ?plan_request
  ?timing_receipt
  ?fresh_receipt
  session
  operation
  =
  let key =
    match operation with
    | Asic.Operation.Inspect_analysis { run; target; _ } ->
      Some (timing_preload_scope session ^ Asic_inspection.analysis_index_key ~run ~target)
    | _ -> None
  in
  match
    Option.bind key ~f:(fun key ->
      List.Assoc.find session.timing_index_inflight key ~equal:String.equal)
  with
  | Some pending -> pending
  | None ->
    let finished = Ivar.create () in
    Option.iter key ~f:(fun key ->
      session.timing_index_inflight
      <- (key, Ivar.read finished) :: session.timing_index_inflight);
    let%map () =
      perform_asic_request
        ?artifact_request
        ?inspection_request
        ?plan_request
        ?timing_receipt
        ?fresh_receipt
        session
        operation
    in
    Option.iter key ~f:(fun key ->
      session.timing_index_inflight
      <- List.Assoc.remove session.timing_index_inflight key ~equal:String.equal);
    Ivar.fill_exn finished ();
    drive_timing_preload session

and perform_asic_request
  ?artifact_request
  ?inspection_request
  ?plan_request
  ?timing_receipt
  ?fresh_receipt
  session
  operation
  =
  match current_project session with
  | None -> return ()
  | Some project ->
    let instance_id = session.hello.instance_id in
    let client = session.client in
    let artifact_identity =
      Option.map artifact_request ~f:(fun (id, _) ->
        (Host.local session.host id).identity)
    in
    let inspection_identity =
      Option.map inspection_request ~f:(fun (id, _) ->
        (Host.local session.host id).identity)
    in
    session.asic_request_id <- session.asic_request_id + 1;
    let request_id = session.asic_request_id in
    let scope = plan_scope session project in
    let planned_run = Planned_run.reset session.host.planned_run ~scope in
    let planned_run, plan_ticket =
      match operation with
      | Asic.Operation.Plan _ when Option.is_some plan_request ->
        planned_run, plan_request
      | Asic.Operation.Plan selection ->
        let planned_run, ticket = Planned_run.begin_plan planned_run selection in
        planned_run, Some ticket
      | Asic.Operation.Stage_fresh { selection; elaboration_only; _ } ->
        let planned_run, ticket =
          Planned_run.begin_fresh planned_run ~elaboration_only selection
        in
        planned_run, Some ticket
      | _ -> planned_run, None
    in
    let planned_run, launch_ticket =
      match operation with
      | Asic.Operation.Run { key; preview } ->
        let planned_run, ticket = Planned_run.begin_launch planned_run ~key preview in
        planned_run, Some ticket
      | Asic.Operation.Launch_fresh { key; intent_id } ->
        (match Planned_run.fresh_intent planned_run with
         | Some intent when String.equal intent.id intent_id ->
           let planned_run, ticket =
             Planned_run.begin_fresh_launch planned_run ~key intent
           in
           planned_run, Some ticket
         | _ -> planned_run, None)
      | _ -> planned_run, None
    in
    session.host <- { session.host with planned_run };
    let%map response =
      request session.diagnostics_file (fun () ->
        Http.Client.asic client { instance_id; project = project.id; operation })
    in
    let current =
      phys_equal client session.client
      && V1.Daemon_instance_id.equal instance_id session.hello.instance_id
      && Option.value_map (current_project session) ~default:false ~f:(fun p ->
        Project_id.equal p.id project.id)
    in
    let plan_current =
      Option.value_map plan_ticket ~default:true ~f:(fun ticket ->
        Planned_run.current_ticket session.host.planned_run ticket)
    in
    if current && plan_current then Option.iter fresh_receipt ~f:(fun f -> f response);
    if current
    then
      Option.iter launch_ticket ~f:(fun ticket ->
        session.host
        <- { session.host with
             planned_run =
               Planned_run.launch_receipt
                 session.host.planned_run
                 ticket
                 ~floor:(session.asic_request_id + 1)
                 (Result.map response ~f:(fun _ -> ()))
           });
    if current
    then
      Option.iter plan_ticket ~f:(fun ticket ->
        (* IDs order request issuance, not daemon snapshot capture. A higher-ID Get can
           still have read the old same-selection completed task before Plan reached the
           daemon. Require a request issued after the receipt. *)
        let floor = session.asic_request_id + 1 in
        session.host
        <- { session.host with
             planned_run =
               (match operation with
                | Stage_fresh _ ->
                  Planned_run.fresh_receipt
                    session.host.planned_run
                    ticket
                    ~floor
                    (Result.bind response ~f:(fun s ->
                       Option.value_map
                         s.Asic.Snapshot.fresh_intent
                         ~default:
                           (Error "Successful staging response omitted its input intent")
                         ~f:Result.return))
                | _ ->
                  Planned_run.receipt
                    session.host.planned_run
                    ticket
                    ~floor
                    (Result.map response ~f:(fun _ -> ())))
           });
    (* A rejected/timed-out launch must release its pending view even when a newer Get
       snapshot has already arrived. Never retry a potentially accepted launch. *)
    if current
    then (
      match operation, response, session.view_on_allocation with
      | ( (Asic.Operation.Run { key; _ } | Launch_fresh { key; _ })
        , Error message
        , Some (pending, _) )
        when String.equal key pending ->
        session.view_on_allocation <- None;
        session.host
        <- { session.host with notice = "ASIC launch not confirmed: " ^ message }
      | _ -> ());
    (* Artifact receipts belong to a tile-local intention, not the newest Get request. A
       later poll must not suppress a matching transport failure or acknowledge a
       different retry/reopened inspector. *)
    if current
    then
      Option.iter artifact_request ~f:(fun (tile_id, ticket) ->
        reconcile_synthesis session;
        let local = Host.local session.host tile_id in
        if Option.exists artifact_identity ~f:(phys_equal local.identity)
        then
          Option.iter local.artifacts ~f:(fun view ->
            let artifacts =
              Artifact_view.apply_response
                view
                ticket
                ~instance_id:session.hello.instance_id
                ~project:project.id
                (Result.map response ~f:(fun _ -> ()))
            in
            session.host
            <- Host.set_local
                 session.host
                 tile_id
                 { local with artifacts = Some artifacts }));
    if current
    then
      Option.iter inspection_request ~f:(fun (tile_id, ticket) ->
        reconcile_synthesis session;
        Option.iter inspection_identity ~f:(fun identity ->
          session.host
          <- Terminal_presentation.Evidence_activity.inspection_receipt
               session.host
               ~tile_id
               ~identity
               ~ticket
               ~publish_notice:(request_id >= session.asic_applied_id)
               (Result.map response ~f:(fun _ -> ()))));
    if request_id >= session.asic_applied_id && current
    then (
      match response with
      | Error message ->
        if Option.is_none artifact_request
           && Option.is_none inspection_request
           && Option.is_none timing_receipt
           && plan_current
        then session.host <- { session.host with notice = "ASIC: " ^ message }
      | Ok snapshot ->
        session.asic_applied_id <- request_id;
        session.asic <- Some snapshot;
        session.host
        <- { session.host with
             planned_run =
               Planned_run.receive session.host.planned_run ~revision:request_id snapshot
           };
        reconcile_synthesis session);
    if current && Option.is_some artifact_request then reconcile_synthesis session;
    Option.iter timing_receipt ~f:(fun receipt ->
      receipt (Result.map response ~f:(fun _ -> ())));
    if current then drive_timing_demand session

and drive_timing_demand session =
  match session.timing_demand with
  | None -> ()
  | Some (tile, client, demand) ->
    let view = Host.inspection session.host tile.id in
    let active =
      phys_equal client session.client
      && Option.exists session.host.registry ~f:(fun registry ->
        List.exists registry.tiles ~f:(fun current ->
          Workspace.Tile_id.equal current.id tile.id && not current.hidden))
      && Option.exists (Host.active session.host) ~f:(fun workspace ->
        Workspace.Workspace_id.equal workspace.id tile.workspace)
    in
    (match active, view, session.asic with
     | true, Some view, Some snapshot ->
       let next, view, request =
         Terminal_presentation.Timing_demand.step
           ~revision:session.asic_applied_id
           !demand
           ~view
           snapshot
       in
       (match next with
        | None -> session.timing_demand <- None
        | Some next ->
          demand := next;
          session.host <- Host.set_inspection session.host tile.id (Some view);
          Option.iter request ~f:(fun request ->
            let inspection_request =
              if request.selected
              then Some (tile.id, Inspection_view.capture view request.operation)
              else None
            in
            let timing_receipt response =
              if Option.exists session.timing_demand ~f:(fun (_, _, current) ->
                   phys_equal current demand)
              then
                demand
                := Terminal_presentation.Timing_demand.receipt
                     ~floor:(session.asic_request_id + 1)
                     !demand
                     ~ticket:request.ticket
                     response
            in
            don't_wait_for
              (asic_request ?inspection_request ~timing_receipt session request.operation)))
     | _ -> session.timing_demand <- None)

and drive_timing_preload session =
  let scope = timing_preload_scope session in
  (* The HTTP receipt only acknowledges queued work. Keep the speculative lane occupied
     until a later snapshot publishes the index or a terminal failure. *)
  Option.iter session.timing_preload_receipt ~f:(fun (flight_scope, key, floor) ->
    if not (String.equal scope flight_scope)
    then session.timing_preload_receipt <- None
    else if session.asic_applied_id >= floor
    then
      Option.iter session.asic ~f:(fun snapshot ->
        let operation =
          List.find snapshot.operations ~f:(fun op -> String.equal op.key key)
        in
        let terminal =
          Option.value_map operation ~default:true ~f:(fun op ->
            not (List.mem [ "pending"; "executing" ] op.state ~equal:String.equal))
        in
        if terminal
        then (
          session.timing_preload_receipt <- None;
          session.timing_preload
          <- Terminal_presentation.Timing_preload.finish
               session.timing_preload
               ~scope
               ~key;
          session.host
          <- { session.host with
               timing =
                 List.map session.host.timing ~f:(fun (id, view) ->
                   if String.equal (Inspection_view.index_key view) key
                   then
                     ( id
                     , { view with
                         index_loading = false
                       ; error =
                           (if Option.is_some view.index
                            then None
                            else
                              Some
                                (Option.bind operation ~f:(fun op -> op.error)
                                 |> Option.value
                                      ~default:
                                        "Timing index unavailable · Inspect/refresh to \
                                         retry"))
                       } )
                   else id, view)
             })));
  let candidates =
    Option.value_map session.host.registry ~default:[] ~f:(fun registry ->
      Host.builtin_timing_workspaces registry
      |> List.filter_map ~f:(fun workspace ->
        List.find registry.tiles ~f:(fun tile ->
          Workspace.Workspace_id.equal tile.workspace workspace.id
          && String.equal tile.kind "timing-paths"
          && not tile.hidden)
        |> Option.bind ~f:(fun tile ->
          Host.timing session.host tile
          |> Option.bind ~f:(fun view ->
            let completed =
              Option.exists session.asic ~f:(fun snapshot ->
                List.exists snapshot.summaries ~f:(fun summary ->
                  Run_ref.equal summary.run view.run
                  && Option.exists summary.timing_analysis ~f:(fun analysis ->
                    Asic.Timing_analysis.Status.equal analysis.status Completed
                    && Option.equal
                         Asic_inspection.Analysis_target.equal
                         (Some analysis.target)
                         view.analysis)))
            in
            if (not completed) || Option.is_some view.index
            then None
            else Some (Inspection_view.index_key view, (tile, view))))))
  in
  let planner, next =
    Terminal_presentation.Timing_preload.step
      session.timing_preload
      ~scope
      ~enabled:
        (session.host.timing_preload
         && Option.is_some session.presentation_preferences_loaded)
      ~interactive:
        ((not (List.is_empty session.timing_index_inflight))
         || Option.is_some session.timing_demand
         || Option.exists session.asic ~f:(fun snapshot ->
           List.exists snapshot.operations ~f:(fun op ->
             List.mem [ "inspection"; "inspection-detail" ] op.kind ~equal:String.equal
             && List.mem [ "pending"; "executing" ] op.state ~equal:String.equal)))
      ~candidates:(List.map candidates ~f:fst)
  in
  session.timing_preload <- planner;
  Option.iter next ~f:(fun key ->
    let client = session.client in
    let tile, view = List.Assoc.find_exn candidates key ~equal:String.equal in
    let epoch = view.workspace_epoch in
    session.host
    <- Host.set_timing session.host tile { view with index_loading = true; error = None };
    let timing_receipt response =
      (match response with
       | Ok () ->
         session.timing_preload_receipt <- Some (scope, key, session.asic_request_id + 1)
       | Error _ ->
         session.timing_preload
         <- Terminal_presentation.Timing_preload.finish session.timing_preload ~scope ~key);
      if phys_equal client session.client
         && String.equal scope (timing_preload_scope session)
      then
        Option.iter (Host.timing session.host tile) ~f:(fun current ->
          if String.equal (Inspection_view.index_key current) key
             && Option.equal String.equal epoch current.workspace_epoch
          then (
            let error =
              match response, current.index with
              | Error message, _ -> Some message
              | Ok (), None -> None
              | Ok (), Some _ -> None
            in
            session.host
            <- Host.set_timing
                 session.host
                 tile
                 { current with
                   index_loading = Result.is_ok response && Option.is_none current.index
                 ; error
                 }))
    in
    don't_wait_for
      (asic_request
         ~timing_receipt
         session
         (Inspection_view.operation ~refresh:false view)))
;;

let artifact_export_notice session tile_id message =
  let message = Artifact_view.safe message in
  session.host <- { session.host with notice = message };
  let local = Host.local session.host tile_id in
  Option.iter local.artifacts ~f:(fun view ->
    session.host
    <- Host.set_local
         session.host
         tile_id
         { local with artifacts = Some { view with external_notice = Some message } });
  append_diagnostic session.diagnostics_file message
;;

let export_artifact_text session tile_id ~viewer (reference : Asic_artifact.Reference.t) =
  let target =
    Host_view.run_label reference.run ^ " / " ^ Artifact_view.safe reference.label
  in
  let notice message =
    artifact_export_notice session tile_id (message ^ " — " ^ target)
  in
  if session.artifact_export_busy
  then (
    notice "Another external text export is in progress";
    return ())
  else (
    match current_project session with
    | None ->
      notice "Export requires an open project";
      return ()
    | Some project ->
      session.artifact_export_busy <- true;
      let client = session.client in
      let instance_id = session.hello.instance_id in
      let project_id = project.id in
      notice "Exporting sanitized text (≤16 MiB, ≤120 seconds)";
      Monitor.protect
        ~finally:(fun () ->
          session.artifact_export_busy <- false;
          return ())
        (fun () ->
          let call operation =
            let%map response =
              request session.diagnostics_file (fun () ->
                Http.Client.asic client { instance_id; project = project_id; operation })
            in
            Result.map_error response ~f:Error.of_string
          in
          let fetch ~(reference : Asic_artifact.Reference.t) ~offset ~limit ~check =
            let key =
              Asic_artifact.read_key
                ~run:reference.run
                ~artifact_id:reference.id
                ~offset
                ~limit
            in
            let rec poll remaining response =
              check ();
              let owner_current =
                V1.Daemon_instance_id.equal instance_id session.hello.instance_id
                && Option.value_map (current_project session) ~default:false ~f:(fun p ->
                  Project_id.equal p.id project_id)
              in
              if not owner_current
              then return (Or_error.error_string "Export daemon/project changed")
              else (
                match response with
                | Error error -> return (Error error)
                | Ok (snapshot : Asic.Snapshot.t) ->
                  if not
                       (List.exists
                          snapshot.artifacts
                          ~f:(Artifact_export.same_reference reference))
                  then
                    return
                      (Or_error.error_string
                         "Export artifact reference changed or expired")
                  else (
                    match Plain_rpc.progress ~wait:true [ key ] snapshot with
                    | Failed error -> return (Or_error.error_string error)
                    | Complete ->
                      return
                        (List.find snapshot.artifact_pages ~f:(fun page ->
                           Run_ref.equal page.run reference.run
                           && String.equal page.artifact_id reference.id
                           && String.equal
                                page.terminal_attempt
                                reference.terminal_attempt
                           && String.equal page.sha256 reference.sha256
                           && page.offset = offset
                           && page.limit = limit)
                         |> Or_error.of_option
                              ~error:
                                (Error.of_string
                                   "Export page expired or identity changed; retry \
                                    explicitly"))
                    | Pending ->
                      if remaining = 0
                      then
                        return
                          (Or_error.error_string
                             "Export read observation budget exhausted")
                      else (
                        let%bind () = Clock.after (Time_float.Span.of_ms 100.) in
                        check ();
                        let%bind response = call Get in
                        poll (remaining - 1) response)))
            in
            check ();
            let%bind response =
              call
                (Read_artifact
                   { run = reference.run; artifact_id = reference.id; offset; limit })
            in
            poll 1200 response
          in
          let publish payload =
            let%map result = Artifact_export.publish_private payload in
            Result.iter result ~f:(fun path ->
              notice
                ("Sanitized text saved: " ^ path ^ " (retained; metadata.sexp alongside)"));
            result
          in
          let%map result =
            Artifact_export.run
              ~viewer
              ~reference
              ~fetch
              ~publish
              ~launch:Artifact_export.launch_viewer
          in
          match result with
          | Ok path ->
            notice ("Sanitized text: " ^ path ^ " (retained; metadata.sexp alongside)")
          | Error error ->
            notice
              ("External text export failed: "
               ^ Artifact_view.safe (Error.to_string_hum error))))
;;

let export_artifact_binary session tile_id ~viewer (reference : Asic_artifact.Reference.t)
  =
  let notice = artifact_export_notice session tile_id in
  if session.artifact_export_busy
  then (
    notice "Another artifact export is in progress";
    return ())
  else (
    match current_project session with
    | None ->
      notice "Binary export requires an open project";
      return ()
    | Some project ->
      session.artifact_export_busy <- true;
      let instance_id = session.hello.instance_id in
      let client = session.client in
      let owner_current () =
        V1.Daemon_instance_id.equal instance_id session.hello.instance_id
        && Option.value_map (current_project session) ~default:false ~f:(fun p ->
          Project_id.equal p.id project.id)
      in
      Monitor.protect
        ~finally:(fun () ->
          session.artifact_export_busy <- false;
          return ())
        (fun () ->
          let call operation =
            let%map result =
              request session.diagnostics_file (fun () ->
                Http.Client.asic client { instance_id; project = project.id; operation })
            in
            Result.map_error result ~f:Error.of_string
          in
          let fetch ~(reference : Asic_artifact.Reference.t) ~offset ~limit ~check =
            let key =
              Asic_artifact.byte_read_key
                ~run:reference.run
                ~artifact_id:reference.id
                ~offset
                ~limit
            in
            let rec poll remaining response =
              check ();
              if not (owner_current ())
              then return (Or_error.error_string "Binary export owner changed")
              else (
                match response with
                | Error e -> return (Error e)
                | Ok (snapshot : Asic.Snapshot.t) ->
                  if not
                       (List.exists
                          snapshot.artifacts
                          ~f:(Artifact_export.same_reference reference))
                  then
                    return
                      (Or_error.error_string "Binary export reference changed or expired")
                  else (
                    match Plain_rpc.progress ~wait:true [ key ] snapshot with
                    | Failed e -> return (Or_error.error_string e)
                    | Complete ->
                      return
                        (List.find snapshot.artifact_byte_pages ~f:(fun p ->
                           Run_ref.equal p.run reference.run
                           && String.equal p.artifact_id reference.id
                           && String.equal p.terminal_attempt reference.terminal_attempt
                           && String.equal p.sha256 reference.sha256
                           && p.offset = offset
                           && p.limit = limit)
                         |> Or_error.of_option
                              ~error:
                                (Error.of_string
                                   "Exact binary page expired; retry explicitly"))
                    | Pending ->
                      if remaining = 0
                      then
                        return
                          (Or_error.error_string
                             "Binary page observation budget exhausted")
                      else (
                        let%bind () = Clock.after (Time_float.Span.of_ms 100.) in
                        check ();
                        let%bind response = call Get in
                        poll (remaining - 1) response)))
            in
            check ();
            let%bind response =
              call
                (Read_artifact_bytes
                   { run = reference.run; artifact_id = reference.id; offset; limit })
            in
            poll 1200 response
          in
          notice "Exporting exact binary (≤16 MiB); verifying SHA256 before launch";
          let%map result =
            Artifact_binary_export.run
              ~viewer
              ~reference
              ~fetch
              ~publish:Artifact_binary_export.publish_private
              ~launch:(fun ~prog ~args ->
                if owner_current ()
                then Artifact_export.launch_viewer ~prog ~args
                else
                  return
                    (Or_error.error_string "Binary export owner changed before launch"))
          in
          match result with
          | Ok path ->
            notice ("Verified binary retained: " ^ path ^ " (metadata.sexp alongside)")
          | Error e -> notice ("Binary export failed: " ^ Error.to_string_hum e)))
;;

let add_default_tiles session (registry : Workspace.Snapshot.t) workspace =
  ignore (registry : Workspace.Snapshot.t);
  match Host.definition workspace with
  | None -> return ()
  | Some definition ->
    mutate_workspace
      session
      (Hardcaml_workbench_workspaces.Definition.apply definition ~workspace:workspace.id)
;;

let initialize_host_layout session =
  let operation =
    Option.bind session.host.registry ~f:(fun snapshot ->
      Hardcaml_workbench_workspaces.Presets.startup_operation
        ?selected:session.workspace_config
        snapshot)
  in
  match operation with
  | Some operation -> workspace_request session operation
  | None -> return ()
;;

let simulation_request session tile_id (operation : Simulation.Operation.t) =
  match current_project session with
  | None -> return ()
  | Some project ->
    let instance_id = session.hello.instance_id in
    let local = Host.local session.host tile_id in
    let client = session.client in
    let shared =
      Option.exists (Host.simulation_tile session.host tile_id) ~f:(fun tile ->
        Testing_workspace.is_pane tile.kind)
    in
    if shared
    then (
      let scope = Project_id.to_string project.id in
      session.host <- Host.establish_testing_scope session.host tile_id ~scope;
      let identity, _, state = Option.value_exn (Host.testing session.host tile_id) in
      let state =
        match operation with
        | Discover ->
          Testing_workspace.update_catalog state Simulation_catalog.begin_discovery
        | _ -> state
      in
      session.host
      <- Host.set_testing
           session.host
           tile_id
           (identity, scope, Testing_workspace.begin_request state))
    else
      session.host
      <- Host.set_simulation
           session.host
           tile_id
           (Simulation_view.begin_request (Host.simulation session.host tile_id));
    let shared_identity =
      Option.map (Host.testing session.host tile_id) ~f:(fun (identity, _, _) -> identity)
    in
    let view = Host.simulation session.host tile_id in
    let%bind response =
      request session.diagnostics_file (fun () ->
        Http.Client.simulation client { instance_id; project = project.id; operation })
    in
    if phys_equal client session.client
       && (if shared
           then
             Option.equal
               phys_equal
               shared_identity
               (Option.map (Host.testing session.host tile_id) ~f:(fun (identity, _, _) ->
                  identity))
           else phys_equal local.identity (Host.local session.host tile_id).identity)
       && V1.Daemon_instance_id.equal instance_id session.hello.instance_id
       && Option.value_map (current_project session) ~default:false ~f:(fun p ->
         Project_id.equal p.id project.id)
    then (
      let response =
        if shared
        then
          Result.map response ~f:(fun (snapshot : Simulation.Snapshot.t) ->
            { snapshot with
              discovery_job =
                Option.filter snapshot.discovery_job ~f:(fun id ->
                  not
                    (List.exists (project_jobs session) ~f:(fun job ->
                       Job_id.equal job.id id
                       &&
                       match job.state with
                       | Complete | Failed | Cancelled -> true
                       | _ -> false)))
            })
        else response
      in
      session.host
      <- (if shared
          then
            Host.update_testing session.host tile_id (fun state ->
              Testing_workspace.receive
                state
                ~ticket:view.request
                ~selected:view.attempt
                operation
                response)
          else
            Host.set_simulation
              session.host
              tile_id
              (Simulation_view.receive
                 (Host.simulation session.host tile_id)
                 ~ticket:view.request
                 ~selected:view.attempt
                 operation
                 response));
      let simulation = Host.simulation session.host tile_id in
      match Simulation_view.detail simulation with
      | Some d when simulation.logs || shared ->
        (match List.find (project_jobs session) ~f:(fun j -> Job_id.equal j.id d.job) with
         | Some job ->
           don't_wait_for (read_job_log session (Some job));
           return ()
         | None ->
           (log_state session d.job).fetch
           <- Presentation.Log_fetch.Error
                "Job logs unavailable in this daemon; normalized historical results \
                 remain readable";
           return ())
      | _ -> return ())
    else return ()
;;

let refresh_simulation session =
  let reads = session.retained_reads in
  let client = session.client in
  Host.tiles session.host
  |> List.filter ~f:(fun tile -> Host.simulation_kind tile.kind)
  |> List.fold ~init:[] ~f:(fun acc tile ->
    if Testing_workspace.is_pane tile.kind
       && List.exists acc ~f:(fun old ->
         Testing_workspace.is_pane old.Workspace.Tile.kind
         && Workspace.Workspace_id.equal old.workspace tile.workspace)
    then acc
    else acc @ [ tile ])
  |> Deferred.List.iter ~how:`Parallel ~f:(fun tile ->
    Option.iter (current_project session) ~f:(fun project ->
      session.host
      <- Host.establish_testing_scope
           session.host
           tile.id
           ~scope:(Project_id.to_string project.id));
    let identity = Host.simulation_identity session.host tile.id in
    let project = Option.map (current_project session) ~f:(fun p -> p.id) in
    Terminal_presentation.Retained_hydration.run
      reads
      ~key:
        (Sexp.to_string_mach
           ([%sexp_of: string * string * string * string option]
              ( "simulation"
              , Workspace.Workspace_id.to_string tile.workspace
              , (if Testing_workspace.is_pane tile.kind
                 then ""
                 else Workspace.Tile_id.to_string tile.id)
              , (Host.simulation session.host tile.id).attempt )))
      (fun () ->
        Terminal_presentation.Retained_hydration.refresh_simulation
          ~current:(fun () ->
            if phys_equal client session.client
               && phys_equal identity (Host.simulation_identity session.host tile.id)
               && Option.equal
                    Project_id.equal
                    project
                    (Option.map (current_project session) ~f:(fun p -> p.id))
            then Some (Host.simulation session.host tile.id)
            else None)
          ~request:(simulation_request session tile.id)))
;;

(** This retained-state lane never waits on Updates, waveform or log I/O. *)
let preparation_request
  ?(accept = fun () -> true)
  ?(on_snapshot = fun _ -> Deferred.unit)
  session
  operation
  =
  if (not (accept ()))
     || not
          (List.mem session.hello.capabilities Preparation.capability ~equal:String.equal)
  then return ()
  else (
    match current_project session with
    | None -> return ()
    | Some project ->
      let client = session.client in
      session.preparation_request_id <- session.preparation_request_id + 1;
      let request_id = session.preparation_request_id in
      let instance_id = session.hello.instance_id in
      let%bind result =
        request session.diagnostics_file (fun () ->
          Http.Client.preparation
            client
            { Preparation.Request.instance_id; project = project.id; operation })
      in
      if (not (accept ()))
         || (not (phys_equal client session.client))
         || (not (V1.Daemon_instance_id.equal instance_id session.hello.instance_id))
         || not
              (Option.exists (current_project session) ~f:(fun p ->
                 Project_id.equal p.id project.id))
      then return ()
      else (
        match result with
        | Error message ->
          session.host
          <- { session.host with
               notice = message
             ; stage_preparation =
                 (match operation with
                  | Stage _ | Launch_staged _ ->
                    Some ("PREPARATION stage/launch unavailable: " ^ message)
                  | _ -> session.host.stage_preparation)
             };
          return ()
        | Ok snapshot ->
          if request_id = session.preparation_request_id
          then session.host <- { session.host with preparation = Some snapshot };
          let%bind () = on_snapshot snapshot in
          let jobs =
            Terminal_presentation.Preparation_view.attempts (Some snapshot)
            |> List.concat_map ~f:(fun a ->
              Option.to_list a.build_job @ Option.to_list a.emission_job)
          in
          let jobs =
            jobs
            @ List.filter (project_jobs session) ~f:(fun j ->
              String.equal j.kind.namespace "dune"
              && List.mem [ "test"; "build" ] j.kind.name ~equal:String.equal)
          in
          Deferred.List.iter jobs ~how:`Sequential ~f:(fun j ->
            read_job_log_id session (Some j.id))))
;;

let hydrate_retained ?(reschedule = false) session =
  let client = session.client in
  Terminal_presentation.Retained_hydration.Coordinator.request
    session.hydration
    ~reschedule
    ~idle:(fun () ->
      if phys_equal client session.client
      then save_navigation_preferences session
      else return ())
    (fun () ->
      if not (phys_equal client session.client)
      then return ()
      else
        Deferred.all_unit
          [ Terminal_presentation.Retained_hydration.run
              session.retained_reads
              ~key:"preparation"
              (fun () -> preparation_request session Get)
          ; Terminal_presentation.Retained_hydration.run
              session.retained_reads
              ~key:"asic"
              (fun () -> asic_request session Get)
          ; (let%bind () = load_preferences session in
             let%bind () = load_presentation_preferences session in
             let%bind () = load_waveform_display_preferences session in
             let%bind () = load_waveform_preferences session in
             let%bind () = load_navigation_preferences session in
             let%bind () =
               if phys_equal client session.client
               then workspace_request session Get
               else return ()
             in
             if not (phys_equal client session.client)
             then return ()
             else (
               apply_navigation_preferences session;
               reconcile_synthesis session;
               refresh_simulation session))
          ])
;;

let activate_workspace session id =
  session.navigation_revision <- session.navigation_revision + 1;
  session.timing_demand <- None;
  session.waveform_visible <- false;
  session.waveform_generation <- session.waveform_generation + 1;
  session.host <- Host.switch session.host id;
  reconcile_synthesis session;
  Option.iter session.asic ~f:(fun snapshot ->
    List.iter (Host.tiles session.host) ~f:(fun tile ->
      Option.iter (Host.timing session.host tile) ~f:(fun view ->
        session.host
        <- Host.set_timing
             session.host
             tile
             (Timing_workspace.attach_retained view snapshot))));
  session.host <- Host.reconcile_navigation_timing session.host session.asic;
  don't_wait_for (refresh_simulation session);
  don't_wait_for (hydrate_retained ~reschedule:true session)
;;

let new_waveform_runtime pin token previous =
  let view, restore_navigation =
    match previous with
    | Some old when Waveforms.equal_pin old.pin pin ->
      Waveform_view.remember old.view, true
    | _ ->
      ( Waveform_view.create
          ~project:(Project_id.to_string pin.Waveforms.project)
          pin.artifact
      , false )
  in
  { pin
  ; token
  ; epoch = ref ()
  ; view
  ; loading = false
  ; restore_navigation
  ; artifacts = []
  ; picker_index = 0
  ; picker_status = "Reading artifacts of pinned attempt"
  ; metadata_loaded = false
  ; metadata_busy = false
  ; logs = { next_offset = 0; records = []; fetch = Presentation.Log_fetch.Not_requested }
  ; log_busy = false
  }
;;

let reconcile_waveform_workspaces session =
  session.waveform_workspaces
  <- List.map session.host.waveforms ~f:(fun (key, (token, pin)) ->
       let previous =
         List.Assoc.find session.waveform_workspaces key ~equal:String.equal
       in
       let rt =
         match previous with
         | Some old when phys_equal old.token token && Waveforms.equal_pin old.pin pin ->
           old
         | _ -> new_waveform_runtime pin token previous
       in
       key, rt)
;;

let waveform_current session workspace rt =
  let epoch = rt.epoch in
  let client = session.client
  and instance_id = session.hello.instance_id in
  let project = Option.map (current_project session) ~f:(fun p -> p.id) in
  fun () ->
    phys_equal epoch rt.epoch
    && phys_equal client session.client
    && V1.Daemon_instance_id.equal instance_id session.hello.instance_id
    && Option.equal
         Project_id.equal
         project
         (Option.map (current_project session) ~f:(fun p -> p.id))
    && Option.value_map
         (Host.waveform_identity session.host workspace)
         ~default:false
         ~f:(phys_equal rt.token)
    && Option.value_map
         (Host.waveform_pin session.host workspace)
         ~default:false
         ~f:(Waveforms.equal_pin rt.pin)
    &&
    match Or_error.try_with (fun () -> fst (preference_context session)) with
    | Ok key -> String.equal key rt.pin.project_key
    | Error _ -> false
;;

let read_waveform_bytes session artifact ~current =
  match current_project session with
  | None -> return (Or_error.error_string "Project unavailable")
  | Some project ->
    let client = session.client
    and instance_id = session.hello.instance_id in
    let parsed = ref None in
    let%map result =
      match Simulation_export.identity artifact with
      | Error e -> return (Error e)
      | Ok (size, _) when size > Waveform_data.default_limits.max_bytes ->
        return
          (Or_error.error_string "Embedded VCD limit: 8 MiB; export remains available")
      | Ok _ when not (String.equal (Simulation_export.suffix artifact) ".vcd") ->
        return (Or_error.error_string "Embedded viewer supports VCD only")
      | Ok _ ->
        Simulation_export.run
          ~artifact
          ~current
          ~viewer:None
          ~fetch:(fun ~offset ~limit ->
            let%map r =
              request session.diagnostics_file (fun () ->
                Http.Client.simulation
                  client
                  { instance_id
                  ; project = project.id
                  ; operation =
                      Read_artifact_bytes
                        { attempt_id = artifact.attempt_id
                        ; artifact_id = artifact.id
                        ; sha256 = Option.value artifact.sha256 ~default:""
                        ; offset
                        ; limit
                        }
                  })
            in
            match r with
            | Error e -> Or_error.error_string e
            | Ok s ->
              Or_error.of_option
                s.byte_page
                ~error:(Error.of_string "Missing waveform byte page"))
          ~publish:(fun _ chunks ->
            In_thread.run (fun () ->
              let open Or_error.Let_syntax in
              let%map data = Waveform_data.parse (String.concat chunks) in
              parsed := Some data;
              "verified embedded VCD"))
          ~launch:(fun ~prog:_ ~args:_ -> return (Ok ()))
    in
    Result.bind result ~f:(fun _ ->
      Or_error.of_option !parsed ~error:(Error.of_string "No parsed waveform"))
;;

let refresh_waveform_runtime session workspace rt =
  let current = waveform_current session workspace rt in
  if not (current ())
  then (
    rt.view
    <- Waveform_view.receive
         rt.view
         (Or_error.error_string
            "Pinned project context unavailable; reopen from its project");
    rt.logs.fetch <- Error "Pinned project context unavailable")
  else (
    (match rt.view.loaded with
     | Loading when not rt.loading ->
       rt.loading <- true;
       don't_wait_for
         (let%map result = read_waveform_bytes session rt.pin.artifact ~current in
          if current ()
          then (
            rt.loading <- false;
            rt.view
            <- Waveform_view.receive
                 ~restore_navigation:rt.restore_navigation
                 rt.view
                 result;
            (* At most four parsed workspace models. Keep navigation for evicted runtime
               models; returning verifies bytes again. *)
            let count = ref 0 in
            List.iter session.waveform_workspaces ~f:(fun (_, other) ->
              if not (phys_equal other rt)
              then (
                match other.view.loaded with
                | Ready _ ->
                  incr count;
                  if !count > 3
                  then (
                    other.view <- Waveform_view.remember other.view;
                    other.restore_navigation <- true)
                | _ -> ()))))
     | _ -> ());
    if (not rt.metadata_loaded) && not rt.metadata_busy
    then (
      rt.metadata_busy <- true;
      Option.iter (current_project session) ~f:(fun project ->
        let client = session.client
        and instance_id = session.hello.instance_id in
        don't_wait_for
          (let%map result =
             request session.diagnostics_file (fun () ->
               Http.Client.simulation
                 client
                 { instance_id
                 ; project = project.id
                 ; operation = Observe rt.pin.artifact.attempt_id
                 })
           in
           if current ()
           then (
             rt.metadata_busy <- false;
             rt.metadata_loaded <- true;
             match result with
             | Ok snapshot ->
               (match snapshot.detail with
                | Some detail when String.equal detail.id rt.pin.artifact.attempt_id ->
                  rt.artifacts
                  <- Waveform_view.picker_candidates ~attempt:detail.id detail.artifacts;
                  rt.picker_index
                  <- Waveform_view.picker_initial_index
                       ~pinned:rt.pin.artifact
                       rt.artifacts;
                  rt.picker_status
                  <- (if List.is_empty rt.artifacts
                      then "No VCD artifacts in the pinned attempt"
                      else "")
                | _ ->
                  rt.picker_status
                  <- "Pinned attempt detail unavailable; artifact pin retained")
             | Error e -> rt.picker_status <- "Pinned attempt artifacts unavailable: " ^ e))));
    if not rt.log_busy
    then (
      match Waveforms.log_job rt.pin ~instance_id:session.hello.instance_id with
      | Error e -> rt.logs.fetch <- Error ("Logs unavailable: " ^ Error.to_string_hum e)
      | Ok job ->
        if not (List.exists session.snapshot.jobs ~f:(fun j -> Job_id.equal j.id job))
        then
          rt.logs.fetch
          <- Error "Pinned attempt job/log has expired; no current-job substitution"
        else (
          match rt.logs.fetch with
          | Received { eof = true } | Error _ -> ()
          | _ ->
            rt.log_busy <- true;
            rt.logs.fetch <- Fetching;
            let client = session.client
            and instance_id = session.hello.instance_id in
            let offset = rt.logs.next_offset in
            don't_wait_for
              (let%map result =
                 request session.diagnostics_file (fun () ->
                   Http.Client.read_log
                     client
                     { instance_id
                     ; job
                     ; offset
                     ; max_records = 128
                     ; max_bytes = V1.max_log_bytes
                     })
               in
               if current ()
               then (
                 rt.log_busy <- false;
                 match result with
                 | Error e ->
                   rt.logs.fetch <- Error ("Pinned attempt logs unavailable: " ^ e)
                 | Ok page when page.next_offset < offset ->
                   rt.logs.fetch <- Error "Invalid pinned log page offset"
                 | Ok page ->
                   rt.logs.next_offset <- page.next_offset;
                   rt.logs.records
                   <- bounded_waveform_logs (rt.logs.records @ page.records);
                   rt.logs.fetch <- Received { eof = page.eof })))))
;;

let refresh_waveforms session =
  reconcile_waveform_workspaces session;
  Option.iter (Host.active session.host) ~f:(fun workspace ->
    Option.iter
      (List.Assoc.find
         session.waveform_workspaces
         (Workspace.Workspace_id.to_string workspace.id)
         ~equal:String.equal)
      ~f:(refresh_waveform_runtime session workspace.id));
  save_waveform_preferences session
;;

let refresh_host session =
  let%bind () = hydrate_retained session in
  let%bind () = initialize_host_layout session in
  let%bind () = refresh_waveforms session in
  let%bind () = save_navigation_preferences session in
  let%bind () =
    match session.view_on_allocation, session.host.registry, session.asic with
    | Some (key, target), Some registry, Some asic ->
      (match Asic_intents.allocation ~key asic with
       | Allocated run ->
         session.view_on_allocation <- None;
         (match Host.selection_after_allocation registry target run with
          | Some mutation -> mutate_workspace session mutation
          | _ ->
            session.host
            <- { session.host with
                 notice = "Run allocated; launch-and-view skipped because context changed"
               };
            return ())
       | Allocation_failed error ->
         session.view_on_allocation <- None;
         session.host <- { session.host with notice = error };
         return ()
       | Awaiting -> return ())
    | _ -> return ()
  in
  (* Visible evidence and active runs share the same bounded read-intent scheduler. *)
  let runs =
    Host.evidence_runs session.host
    @ Option.value_map session.asic ~default:[] ~f:(fun snapshot ->
      List.filter_map snapshot.runs ~f:(fun run ->
        if Asic_intents.live_status run.status then Some run.run else None))
  in
  match session.asic with
  | None -> return ()
  | Some snapshot ->
    let state, intents =
      Asic_intents.plan session.asic_reads ~now:(Time_ns.now ()) snapshot ~visible:runs
    in
    session.asic_reads <- state;
    Deferred.List.iter intents ~how:`Sequential ~f:(asic_request session)
;;

let apply_updates session ~instance_id updates =
  if not (V1.Daemon_instance_id.equal instance_id session.hello.instance_id)
  then Ok `Stale
  else (
    let selected_job_id = Option.map (selected_job session) ~f:(fun job -> job.id) in
    State.apply_updates session.snapshot updates
    |> Result.map ~f:(fun snapshot ->
      session.snapshot <- snapshot;
      reconcile_selection session;
      preserve_selected_job session selected_job_id;
      `Applied))
;;

let resync session ~instance_id =
  let selected_job_id = Option.map (selected_job session) ~f:(fun job -> job.id) in
  let%map snapshot = snapshot_request session ~instance_id in
  match snapshot with
  | _ when not (V1.Daemon_instance_id.equal instance_id session.hello.instance_id) ->
    Ok ()
  | Error _ as error -> error
  | Ok snapshot ->
    session.snapshot <- snapshot;
    reconcile_selection session;
    preserve_selected_job session selected_job_id;
    Ok ()
;;

let poll_updates session ~timeout_ms =
  let instance_id = session.hello.instance_id in
  let request : V1.Updates.Request.t =
    { instance_id
    ; cursor = session.snapshot.cursor
    ; max_events = V1.max_update_events
    ; timeout_ms
    }
  in
  let%bind response =
    updates_request session.diagnostics_file (fun () ->
      Http.Client.updates session.client request)
  in
  match response with
  | Ok updates ->
    (match apply_updates session ~instance_id updates with
     | Ok result -> return (Ok result)
     | Error error ->
       let%map resynced = resync session ~instance_id in
       Result.map resynced ~f:(fun () -> `Resynced)
       |> Result.map_error ~f:(fun message ->
         sprintf "%s; snapshot resync failed: %s" (Error.to_string_hum error) message))
  | Error (`Protocol error) when V1.Error.Kind.equal error.kind Resync_required ->
    let%map resynced = resync session ~instance_id in
    Result.map resynced ~f:(fun () -> `Resynced)
  | Error (`Protocol error) when V1.Error.Kind.equal error.kind Instance_changed ->
    return (Error (protocol_error error))
  | Error (`Protocol error) -> return (Error (protocol_error error))
  | Error (`Transport message) -> return (Error message)
;;

let rec refresh session =
  if session.polling
  then return ()
  else (
    session.polling <- true;
    Monitor.protect
      ~finally:(fun () ->
        session.polling <- false;
        return ())
      (fun () ->
        don't_wait_for (hydrate_retained session);
        let sequence_before = session.snapshot.cursor.sequence in
        let%bind updates = poll_updates session ~timeout_ms:200 in
        match updates with
        | Error message ->
          session.status <- "disconnected: " ^ message ^ "; reconnecting...";
          session.timing_demand <- None;
          let%bind () =
            Clock.after (Time_float.Span.of_ms (Float.of_int session.reconnect_delay_ms))
          in
          reconnect session
        | Ok update ->
          let%bind () =
            if Option.is_none session.host.preparation
               || session.snapshot.cursor.sequence <> sequence_before
               || Option.exists session.host.preparation ~f:(fun s ->
                 Option.exists s.latest ~f:Terminal_presentation.Preparation_view.active)
            then preparation_request session Get
            else return ()
          in
          session.status
          <- (match update with
              | `Resynced -> "connected; update cursor recovered from snapshot"
              | `Applied | `Stale -> "connected");
          let%bind () = refresh_host session in
          let%bind () = read_selected_log session in
          let%bind () = read_job_log session (current_generation session) in
          Host.tiles session.host
          |> List.filter ~f:(fun tile ->
            String.equal tile.kind "logs" || String.equal tile.kind "project-tests")
          |> List.filter_map ~f:(fun tile -> (Host.local session.host tile.id).cursor)
          |> List.dedup_and_sort ~compare:String.compare
          |> Deferred.List.iter ~how:`Sequential ~f:(fun id ->
            read_job_log
              session
              (List.find (project_jobs session) ~f:(fun job ->
                 String.equal (Job_id.to_string job.id) id)))))

and reconnect session =
  session.timing_demand <- None;
  let selected_job_id = Option.map (selected_job session) ~f:(fun job -> job.id) in
  session.status <- "reconnecting...";
  let%map loaded =
    load_state
      ~endpoint:session.requested_endpoint
      ~project_root:session.project_root
      ~environment_selection:session.environment_selection
      ~diagnostics:session.diagnostics_file
  in
  match loaded with
  | Error message ->
    session.status <- "reconnect failed: " ^ message;
    session.reconnect_delay_ms <- Int.min 5_000 (session.reconnect_delay_ms * 2)
  | Ok (client, hello, opened, snapshot) ->
    let instance_changed =
      not
        (String.equal
           (V1.Daemon_instance_id.to_string session.hello.instance_id)
           (V1.Daemon_instance_id.to_string hello.instance_id))
    in
    let project_changed =
      not
        (Option.equal
           Project_id.equal
           (Option.map session.opened ~f:(fun opened -> opened.project.id))
           (Option.map opened ~f:(fun opened -> opened.project.id)))
    in
    session.client <- client;
    session.hello <- hello;
    session.opened <- opened;
    session.snapshot <- snapshot;
    session.host
    <- Host.reconnect session.host ~replacement:(instance_changed || project_changed);
    session.hydration <- Terminal_presentation.Retained_hydration.Coordinator.create ();
    Terminal_presentation.Retained_hydration.Load.reconnect
      session.navigation_loaded
      ~replacement:(instance_changed || project_changed);
    session.retained_reads <- Terminal_presentation.Retained_hydration.create ();
    (* The same project's authoritative evidence remains valid while the first new
       transport poll is pending; dropping it would reset stage/result browsing. *)
    if instance_changed || project_changed
    then (
      session.asic <- None;
      session.host <- { session.host with preparation = None });
    if instance_changed || project_changed
    then (
      session.navigation_restore_revision <- session.navigation_revision;
      session.navigation_touched <- [];
      session.navigation_focus_touched <- [];
      session.navigation_pending <- None;
      session.navigation_saved <- None;
      session.waveform_preferences_loaded <- None;
      session.waveform_preferences_pending <- None;
      session.waveform_preferences_saved <- None;
      session.view_on_allocation <- None;
      session.asic_reads <- Asic_intents.empty);
    if instance_changed || project_changed
    then (
      session.hierarchy_view <- None;
      Hashtbl.clear session.hierarchy_errors);
    reconcile_selection session;
    if instance_changed
    then session.selected <- 0
    else preserve_selected_job session selected_job_id;
    Hashtbl.clear session.logs;
    session.reconnect_delay_ms <- 250;
    session.status
    <- (if instance_changed
        then "reconnected to new daemon instance; no jobs were resubmitted"
        else "reconnected; no jobs were resubmitted");
    don't_wait_for (hydrate_retained session)
;;

let submission_key action =
  sprintf
    "terminal-%s-%s-%06x"
    action
    (Time_ns.now () |> Time_ns.to_int63_ns_since_epoch |> Int63.to_string)
    (Random.bits ())
;;

let submit session action =
  match session.opened with
  | None ->
    session.status <- "build/test requires --project-root";
    return ()
  | Some opened ->
    let action_name, protocol_action =
      match action with
      | `Build -> "build", V1.Dune_action.Build
      | `Test -> "test", V1.Dune_action.Test
    in
    let key = submission_key action_name in
    session.status <- sprintf "submitting %s..." action_name;
    let%map response =
      request session.diagnostics_file (fun () ->
        Http.Client.submit_job
          session.client
          { instance_id = session.hello.instance_id
          ; project = opened.project.id
          ; action = protocol_action
          ; submission_key = key
          })
    in
    (match response with
     | Error message ->
       session.status <- sprintf "%s submission failed: %s" action_name message
     | Ok payload ->
       session.snapshot <- State.add_job_if_absent session.snapshot payload.job;
       session.selected <- 0;
       session.status
       <- sprintf "submitted %s as %s" action_name (Job_id.to_string payload.job.id))
;;

let refresh_integration session =
  match current_project session with
  | None ->
    session.status <- "integration refresh requires --project-root";
    return ()
  | Some project ->
    session.status <- "requesting integration refresh...";
    let%bind response =
      request session.diagnostics_file (fun () ->
        Http.Client.refresh_integration
          session.client
          { instance_id = session.hello.instance_id; project = project.id })
    in
    (match response with
     | Error message ->
       session.status <- "integration refresh failed: " ^ message;
       return ()
     | Ok { job = None } ->
       let%map result = resync session ~instance_id:session.hello.instance_id in
       session.status
       <- (match result with
           | Ok () -> "integration manifest reloaded (no driver declared)"
           | Error message -> "integration refresh resync failed: " ^ message)
     | Ok { job = Some job } ->
       session.snapshot <- State.add_job_if_absent session.snapshot job;
       session.selected <- 0;
       session.status <- "integration refresh queued as " ^ Job_id.to_string job.id;
       return ())
;;

let next_after values current ~equal =
  match values with
  | [] -> None
  | first :: _ ->
    (match current with
     | None -> Some first
     | Some current ->
       (match List.findi values ~f:(fun _ value -> equal current value) with
        | None -> Some first
        | Some (index, _) ->
          Some (List.nth_exn values ((index + 1) mod List.length values))))
;;

let cycle_target session =
  match current_project session with
  | None -> session.status <- "no project target is available"
  | Some project ->
    let current = selected_target session in
    let next = next_after project.targets current ~equal:Target.equal in
    session.selected_target <- Option.map next ~f:(fun target -> target.id);
    session.selected_configuration <- None;
    reconcile_selection session;
    session.status
    <- Option.value_map next ~default:"no project target is available" ~f:(fun target ->
         "selected target " ^ target.name)
;;

let cycle_configuration session =
  match current_project session, selected_target session with
  | Some project, Some target ->
    let configurations =
      List.filter project.configurations ~f:(fun configuration ->
        Target_id.equal configuration.target target.id)
    in
    let current = selected_configuration session in
    let next = next_after configurations current ~equal:Configuration.equal in
    session.selected_configuration
    <- Option.map next ~f:(fun configuration -> configuration.id);
    session.status
    <- Option.value_map
         next
         ~default:"selected target has no configuration"
         ~f:(fun config -> "selected configuration " ^ config.name)
  | None, _ | _, None -> session.status <- "no target is selected"
;;

let cycle_artifact session =
  let artifacts = project_artifacts session in
  let current = selected_artifact session in
  let next = next_after artifacts current ~equal:Artifact.equal in
  session.selected_artifact <- Option.map next ~f:(fun artifact -> artifact.id);
  session.artifact_view <- None;
  session.status
  <- Option.value_map
       next
       ~default:"no generated artifact is available"
       ~f:(fun artifact -> "selected artifact " ^ artifact.metadata.display_name)
;;

let generate_rtl session =
  match
    current_project session, selected_target session, selected_configuration session
  with
  | Some project, Some target, Some configuration ->
    let key = submission_key "generate-rtl" in
    session.status
    <- sprintf "generating RTL for %s / %s..." target.name configuration.name;
    let%map response =
      request session.diagnostics_file (fun () ->
        Http.Client.generate_rtl
          session.client
          { instance_id = session.hello.instance_id
          ; project = project.id
          ; target = target.id
          ; configuration = configuration.id
          ; submission_key = key
          })
    in
    (match response with
     | Error message -> session.status <- "RTL generation failed: " ^ message
     | Ok payload ->
       session.snapshot <- State.add_job_if_absent session.snapshot payload.job;
       session.selected <- 0;
       session.status
       <- sprintf
            "submitted RTL for %s / %s as %s"
            target.name
            configuration.name
            (Job_id.to_string payload.job.id))
  | None, _, _ ->
    session.status <- "RTL generation requires an open project";
    return ()
  | _, None, _ ->
    session.status <- "RTL generation requires a discovered target";
    return ()
  | _, _, None ->
    session.status <- "RTL generation requires a configuration for the selected target";
    return ()
;;

let inspect_artifact session =
  match session.selected_artifact with
  | None ->
    session.status <- "no artifact is selected";
    return ()
  | Some artifact_id ->
    (match session.artifact_view with
     | Some view when Artifact_id.equal view.artifact artifact_id ->
       session.artifact_view <- None;
       session.status <- "closed artifact view";
       return ()
     | _ ->
       let limit = 1024 * 1024 in
       let requested_instance = session.hello.instance_id in
       let requested_client = session.client in
       let rec read offset parts bytes =
         if bytes >= limit
         then return (Ok (String.concat (List.rev parts), true))
         else (
           let max_bytes = Int.min V1.max_artifact_bytes (limit - bytes) in
           let%bind page =
             request session.diagnostics_file (fun () ->
               Http.Client.read_artifact
                 requested_client
                 { instance_id = requested_instance
                 ; artifact = artifact_id
                 ; offset
                 ; max_bytes
                 })
           in
           match page with
           | Error message -> return (Error message)
           | Ok page when page.eof ->
             return (Ok (String.concat (List.rev (page.data :: parts)), false))
           | Ok page ->
             read page.next_offset (page.data :: parts) (bytes + String.length page.data))
       in
       session.status <- "fetching artifact " ^ Artifact_id.to_string artifact_id ^ "...";
       let%map result = read 0 [] 0 in
       if V1.Daemon_instance_id.equal requested_instance session.hello.instance_id
          && Option.value_map session.selected_artifact ~default:false ~f:(fun id ->
            Artifact_id.equal id artifact_id)
       then (
         match result with
         | Error message -> session.status <- "artifact retrieval failed: " ^ message
         | Ok (content, truncated) ->
           session.artifact_view <- Some { artifact = artifact_id; content; truncated };
           session.status
           <- (if truncated then "artifact view truncated at 1 MiB" else "artifact loaded")))
;;

let hierarchy_candidate session =
  match selected_job session with
  | Some job when State.is_generation_job job -> Some job
  | Some _ | None -> current_generation session
;;

let index_hierarchy (hierarchy : Hierarchy.t) =
  let nodes = Hashtbl.create (module String) in
  let children = Hashtbl.create (module String) in
  List.iter hierarchy.nodes ~f:(fun node ->
    Hashtbl.set nodes ~key:node.key ~data:node;
    Option.iter node.parent ~f:(fun parent ->
      Hashtbl.add_multi children ~key:parent ~data:node));
  Hashtbl.to_alist children
  |> List.iter ~f:(fun (parent, entries) ->
    Hashtbl.set
      children
      ~key:parent
      ~data:
        (List.sort entries ~compare:(fun a b ->
           Option.compare String.compare a.instance_name b.instance_name)));
  nodes, children
;;

let hierarchy_children children parent =
  Hashtbl.find children parent |> Option.value ~default:[]
;;

(* One transport owner for both inspector and tile consumers. Keep all in-flight reads and
   at most sixteen completed immutable evidence values. Errors retry. *)
let read_hierarchy_shared session (job : Job.t) (artifact : Artifact.t) =
  let instance_id = session.hello.instance_id in
  let key =
    Sexp.to_string_mach
      [%sexp
        (instance_id : V1.Daemon_instance_id.t)
        , (artifact.project : Project_id.t)
        , (artifact.id : Artifact_id.t)]
  in
  match List.Assoc.find !(session.hierarchy_reads) key ~equal:String.equal with
  | Some response -> response
  | None
    when List.count !(session.hierarchy_reads) ~f:(fun (_, d) ->
           not (Deferred.is_determined d))
         >= 16 ->
    return (Error "Hierarchy reader busy (16 in-flight artifacts); retry with r")
  | None ->
    let response =
      let%map response =
        request session.diagnostics_file (fun () ->
          Http.Client.read_hierarchy
            session.client
            { instance_id; artifact = artifact.id })
      in
      Result.bind response ~f:(fun payload ->
        let h = payload.V1.Read_hierarchy.Payload.hierarchy in
        if Artifact_id.equal h.artifact artifact.id
           && Project_id.equal h.project artifact.project
           && Job_id.equal h.generating_job job.id
        then Ok (Terminal_presentation.Hierarchy_view.evidence h)
        else Error "Hierarchy response identity did not match request")
    in
    let pending, completed =
      List.partition_tf !(session.hierarchy_reads) ~f:(fun (_, d) ->
        not (Deferred.is_determined d))
    in
    session.hierarchy_reads := ((key, response) :: pending) @ List.take completed 15;
    upon response (fun result ->
      (match result with
       | Ok _ -> ()
       | Error _ ->
         session.hierarchy_reads
         := List.Assoc.remove !(session.hierarchy_reads) key ~equal:String.equal);
      let pending, completed =
        List.partition_tf !(session.hierarchy_reads) ~f:(fun (_, d) ->
          not (Deferred.is_determined d))
      in
      session.hierarchy_reads := pending @ List.take completed 16);
    response
;;

let missing_hierarchy_guidance session =
  Host.missing_hierarchy_guidance
    ~project:(current_project session)
    ~target:session.selected_target
    ~configuration:session.selected_configuration
;;

let load_tile_hierarchy session id =
  let local = Host.local session.host id in
  let ticket = ref () in
  let instance = session.hello.instance_id in
  let client = session.client in
  let project = Option.map (current_project session) ~f:(fun p -> p.Project.id) in
  let finish hierarchy status =
    let now = Host.local session.host id in
    if Host.hierarchy_request_current
         session.host
         id
         ~identity:local.identity
         ~request:ticket
       && V1.Daemon_instance_id.equal instance session.hello.instance_id
       && phys_equal client session.client
       && Option.equal
            Project_id.equal
            project
            (Option.map (current_project session) ~f:(fun p -> p.Project.id))
    then
      session.host
      <- Host.set_local
           session.host
           id
           { now with
             hierarchy = Option.first_some hierarchy now.hierarchy
           ; hierarchy_status = status
           }
  in
  session.host
  <- Host.set_local
       session.host
       id
       { local with
         hierarchy_request = ticket
       ; hierarchy_status = "Loading current hierarchy…"
       };
  match current_generation session with
  | None ->
    finish None ("Missing hierarchy: " ^ missing_hierarchy_guidance session);
    return ()
  | Some job when not (Job.State.equal job.state Complete) ->
    finish
      None
      ("Hierarchy "
       ^ Job.State.to_string job.state
       ^ " in "
       ^ Job_id.to_string job.id
       ^ "; "
       ^
       if Job.is_terminal job
       then missing_hierarchy_guidance session
       else "wait for generation to finish, then r");
    return ()
  | Some job ->
    (match hierarchy_artifact_for_job session job with
     | None ->
       finish
         None
         "Unsupported: completed generation has no structured hierarchy; generate with a \
          supporting provider, then r";
       return ()
     | Some artifact ->
       let%map response = read_hierarchy_shared session job artifact in
       (match response with
        | Error message -> finish None ("Hierarchy read error: " ^ message ^ "; r retries")
        | Ok evidence ->
          let module V = Terminal_presentation.Hierarchy_view in
          let view = V.create evidence in
          let view =
            match (Host.local session.host id).hierarchy with
            | Some previous
              when Artifact_id.equal
                     (V.hierarchy previous).artifact
                     (V.hierarchy view).artifact -> previous
            | _ -> view
          in
          finish (Some view) "Loaded hierarchy; r loads current selection"))
;;

let detail_tile_hierarchy session id =
  session.hierarchy_intent <- ref ();
  Option.iter (Host.local session.host id).hierarchy ~f:(fun view ->
    let module V = Terminal_presentation.Hierarchy_view in
    let hierarchy = V.hierarchy view in
    let nodes, children = index_hierarchy hierarchy in
    let expanded =
      List.fold
        (V.visible view)
        ~init:(String.Set.singleton hierarchy.root)
        ~f:(fun expanded (_, node) ->
          Option.value_map
            node.Hierarchy.Node.parent
            ~default:expanded
            ~f:(Set.add expanded))
    in
    session.hierarchy_view
    <- Some
         { hierarchy
         ; nodes
         ; children
         ; selected_key = V.selected_key view
         ; expanded
         ; scroll = 0
         ; pane_scroll = 0
         });
  return ()
;;

let inspect_hierarchy session =
  let intent = ref () in
  session.hierarchy_intent <- intent;
  match hierarchy_candidate session with
  | None ->
    session.status <- "no RTL generation result is available for hierarchy inspection";
    return ()
  | Some job when not (Job.State.equal job.state Complete) ->
    session.status
    <- (match job.state with
        | Queued | Starting | Running -> "hierarchy pending in " ^ Job_id.to_string job.id
        | Failed ->
          "hierarchy unavailable because generation failed in " ^ Job_id.to_string job.id
        | Cancelled ->
          "hierarchy unavailable because generation was cancelled in "
          ^ Job_id.to_string job.id
        | Complete -> assert false);
    return ()
  | Some job ->
    (match hierarchy_artifact_for_job session job with
     | None ->
       session.status
       <- "structured hierarchy unsupported for generation " ^ Job_id.to_string job.id;
       return ()
     | Some artifact ->
       (match session.hierarchy_view with
        | Some view when Artifact_id.equal view.hierarchy.artifact artifact.id ->
          session.hierarchy_view <- None;
          session.status <- "closed hierarchy view";
          return ()
        | _ ->
          let requested_instance = session.hello.instance_id in
          session.status <- "fetching hierarchy for " ^ Job_id.to_string job.id ^ "...";
          let requested_project =
            Option.map (current_project session) ~f:(fun p -> p.Project.id)
          in
          let%map response = read_hierarchy_shared session job artifact in
          if not
               (V1.Daemon_instance_id.equal requested_instance session.hello.instance_id
                && phys_equal intent session.hierarchy_intent
                && Option.equal
                     Project_id.equal
                     requested_project
                     (Option.map (current_project session) ~f:(fun p -> p.Project.id)))
          then ()
          else (
            match response with
            | Error message ->
              Hashtbl.set session.hierarchy_errors ~key:artifact.id ~data:message;
              session.status <- "hierarchy retrieval failed: " ^ message
            | Ok evidence ->
              let hierarchy =
                Terminal_presentation.Hierarchy_view.hierarchy
                  (Terminal_presentation.Hierarchy_view.create evidence)
              in
              if not
                   (Artifact_id.equal hierarchy.artifact artifact.id
                    && Job_id.equal hierarchy.generating_job job.id)
              then
                session.status <- "hierarchy response identity did not match the request"
              else (
                Hashtbl.remove session.hierarchy_errors artifact.id;
                let nodes, children = index_hierarchy hierarchy in
                session.hierarchy_view
                <- Some
                     { hierarchy
                     ; nodes
                     ; children
                     ; selected_key = hierarchy.root
                     ; expanded = String.Set.singleton hierarchy.root
                     ; scroll = 0
                     ; pane_scroll = 0
                     };
                session.status <- "hierarchy loaded"))))
;;

let visible_hierarchy_nodes view =
  let rec visit depth key =
    match Hashtbl.find view.nodes key with
    | None -> []
    | Some node ->
      let children =
        if Set.mem view.expanded key
        then
          hierarchy_children view.children key
          |> List.concat_map ~f:(fun child -> visit (depth + 1) child.key)
        else []
      in
      (depth, node) :: children
  in
  visit 0 view.hierarchy.root
;;

let move_hierarchy_selection session delta =
  Option.iter session.hierarchy_view ~f:(fun view ->
    let nodes = visible_hierarchy_nodes view in
    let current =
      List.findi nodes ~f:(fun _ (_, node) -> String.equal node.key view.selected_key)
      |> Option.value_map ~default:0 ~f:fst
    in
    let next = Int.max 0 (Int.min (List.length nodes - 1) (current + delta)) in
    Option.iter (List.nth nodes next) ~f:(fun (_, node) ->
      view.selected_key <- node.key;
      view.pane_scroll <- 0))
;;

let toggle_hierarchy_expansion session =
  Option.iter session.hierarchy_view ~f:(fun view ->
    if not (List.is_empty (hierarchy_children view.children view.selected_key))
    then
      view.expanded
      <- (if Set.mem view.expanded view.selected_key
          then Set.remove view.expanded view.selected_key
          else Set.add view.expanded view.selected_key))
;;

let cancel_selected session =
  match selected_job session with
  | None ->
    session.status <- "no selected job to cancel";
    return ()
  | Some job when Job.is_terminal job ->
    session.status <- "selected job is already terminal";
    return ()
  | Some job ->
    session.status <- "cancelling " ^ Job_id.to_string job.id ^ "...";
    let%map response =
      request session.diagnostics_file (fun () ->
        Http.Client.cancel_job
          session.client
          { instance_id = session.hello.instance_id; job = job.id })
    in
    (match response with
     | Error message -> session.status <- "cancel failed: " ^ message
     | Ok payload ->
       session.snapshot <- State.add_job_if_absent session.snapshot payload.job;
       session.status <- "cancellation requested")
;;

let fit width text =
  if width <= 0
  then ""
  else if String.length text <= width
  then text
  else if width <= 3
  then String.prefix text width
  else String.prefix text (width - 3) ^ "..."
;;

let environment_lines session =
  match session.opened with
  | None ->
    [ "Project: none (use --project-root ROOT)"
    ; "Environment request: " ^ session.environment_label
    ; "Generic Dune workspace: no project opened"
    ]
  | Some opened ->
    let environment = opened.environment in
    let contexts =
      match opened.workspace.contexts with
      | [] -> "none reported"
      | contexts -> String.concat contexts ~sep:", "
    in
    let item_summary =
      if List.is_empty opened.workspace.items
      then "no workspace items reported"
      else
        sprintf
          "%d inspected item%s"
          (List.length opened.workspace.items)
          (if List.length opened.workspace.items = 1 then "" else "s")
    in
    [ sprintf
        "Project: %s  root=%s"
        opened.project.name
        (Project_root.to_absolute_path opened.project.root)
    ; sprintf
        "Environment request: %s  resolved=%s  dune=%s"
        session.environment_label
        environment.provenance
        environment.dune_version
    ; sprintf "Generic Dune workspace: contexts=%s; %s" contexts item_summary
    ]
;;

let project_lines session ~width =
  match session.opened, current_project session with
  | None, _ ->
    [ "Project: none"
    ; "Open one with --project-root ROOT"
    ; "Generic Dune workspace: unavailable"
    ]
  | Some opened, Some project ->
    let contexts =
      match opened.workspace.contexts with
      | [] -> "none reported"
      | contexts -> String.concat contexts ~sep:", "
    in
    let root_label = "Root: " in
    [ "Project: " ^ project.name
    ; root_label
      ^ Presentation.middle_truncate
          ~width:(width - String.length root_label)
          (Project_root.to_absolute_path opened.project.root)
    ; sprintf
        "Environment: %s (Dune %s)"
        session.environment_label
        opened.environment.dune_version
    ; "Contexts: " ^ contexts
    ]
  | Some _, None -> [ "Project state unavailable; reconnect to resync" ]
;;

let integration_lines session =
  match current_project session with
  | None -> [ "Integration: unavailable" ]
  | Some project ->
    let component = function
      | Project_integration.Component_status.Absent -> "absent"
      | Available { version = None } -> "available"
      | Available { version = Some version } -> sprintf "available v%d" version
      | Unusable { reason } -> "unusable: " ^ reason
    in
    let discovery =
      project_jobs session
      |> List.find ~f:(fun job ->
        String.equal job.Job.kind.namespace "project-driver"
        && String.equal job.kind.name "describe")
      |> Option.value_map ~default:"not requested" ~f:(fun job ->
        Job.State.to_string job.state ^ " (" ^ Job_id.to_string job.id ^ ")")
    in
    let targets =
      if List.is_empty project.targets
      then [ "  Targets: none" ]
      else
        List.map project.targets ~f:(fun target ->
          sprintf
            "%s Target: %s (top %s) [%s]"
            (if Option.value_map session.selected_target ~default:false ~f:(fun id ->
                  Target_id.equal id target.id)
             then ">"
             else " ")
            target.name
            target.top
            (Target_id.to_string target.id))
    in
    let configurations =
      if List.is_empty project.configurations
      then [ "  Configurations: none" ]
      else
        List.map project.configurations ~f:(fun config ->
          sprintf
            "%s Configuration: %s [%s]"
            (if Option.value_map
                  session.selected_configuration
                  ~default:false
                  ~f:(fun id -> Configuration_id.equal id config.id)
             then ">"
             else " ")
            config.name
            (Configuration_id.to_string config.id))
    in
    [ sprintf
        "Integration: %s  manifest=%s  driver=%s"
        (Project_integration.Level.to_string project.integration.level)
        (component project.integration.manifest)
        (component project.integration.driver)
    ; "Discovery: " ^ discovery
    ]
    @ targets
    @ configurations
;;

let hierarchy_status_lines session =
  match current_generation session with
  | None -> [ "Hardware hierarchy: unavailable; " ^ missing_hierarchy_guidance session ]
  | Some job ->
    (match job.state with
     | Queued | Starting | Running ->
       [ sprintf
           "Hardware hierarchy: pending (%s, %s)"
           (Job_id.to_string job.id)
           (Job.State.to_string job.state)
       ]
     | Failed ->
       [ "Hardware hierarchy: latest generation failed (" ^ Job_id.to_string job.id ^ ")"
       ]
     | Cancelled ->
       [ "Hardware hierarchy: latest generation was cancelled ("
         ^ Job_id.to_string job.id
         ^ ")"
       ]
     | Complete ->
       (match hierarchy_artifact_for_job session job with
        | None -> [ "Hardware hierarchy: unsupported for this completed result" ]
        | Some artifact ->
          (match Hashtbl.find session.hierarchy_errors artifact.id with
           | Some message -> [ "Hardware hierarchy: unavailable: " ^ message ]
           | None ->
             [ "Hardware hierarchy output from "
               ^ Job_id.to_string job.id
               ^ " (h inspect)"
             ])))
;;

let hierarchy_view_lines session view ~height =
  let hierarchy = view.hierarchy in
  let current =
    Option.exists (current_project session) ~f:(fun p ->
      Project_id.equal p.id hierarchy.project)
    && State.hierarchy_is_current
         hierarchy
         ~latest:(current_generation session)
         ~target:session.selected_target
         ~configuration:session.selected_configuration
  in
  let project = current_project session in
  let target =
    Option.bind project ~f:(fun project ->
      List.find project.targets ~f:(fun target ->
        Target_id.equal target.id hierarchy.target))
    |> Option.value_map ~default:(Target_id.to_string hierarchy.target) ~f:(fun target ->
      target.name)
  in
  let configuration =
    Option.bind project ~f:(fun project ->
      List.find project.configurations ~f:(fun configuration ->
        Configuration_id.equal configuration.id hierarchy.configuration))
    |> Option.value_map
         ~default:(Configuration_id.to_string hierarchy.configuration)
         ~f:(fun configuration -> configuration.name)
  in
  let visible = visible_hierarchy_nodes view in
  let selected_index =
    List.findi visible ~f:(fun _ (_, node) -> String.equal node.key view.selected_key)
    |> Option.value_map ~default:0 ~f:fst
  in
  let tree ~tree_height =
    if selected_index < view.scroll
    then view.scroll <- selected_index
    else if selected_index >= view.scroll + tree_height
    then view.scroll <- selected_index - tree_height + 1;
    visible
    |> Fn.flip List.drop view.scroll
    |> Fn.flip List.take tree_height
    |> List.map ~f:(fun (depth, node) ->
      let children = hierarchy_children view.children node.key in
      let marker =
        if List.is_empty children
        then " "
        else if Set.mem view.expanded node.key
        then "-"
        else "+"
      in
      let name = Option.value node.instance_name ~default:"<root>" in
      sprintf
        "%s%s%s %s : %s"
        (if String.equal node.key view.selected_key then ">" else " ")
        (String.make (depth * 2) ' ')
        marker
        name
        node.circuit_name)
  in
  let inspector =
    match Hashtbl.find view.nodes view.selected_key with
    | None -> [ "Node: unavailable" ]
    | Some node ->
      let ports ports =
        match ports with
        | [] -> "none"
        | ports ->
          List.map ports ~f:(fun port ->
            sprintf "%s[%d]" port.Hierarchy.Port.name port.width)
          |> String.concat ~sep:", "
      in
      let metadata =
        match node.metadata with
        | [] -> "none"
        | metadata ->
          List.map metadata ~f:(fun item -> item.name ^ "=" ^ item.value)
          |> String.concat ~sep:", "
      in
      [ "Node instance: " ^ Option.value node.instance_name ~default:"<root>"
      ; "Circuit: " ^ node.circuit_name
      ; "Key: " ^ node.key
      ; "Inputs: " ^ ports node.input_ports
      ; "Outputs: " ^ ports node.output_ports
      ; "Metadata: " ^ metadata
      ; "Signals/source: unavailable in structural hierarchy"
      ]
  in
  let header =
    [ sprintf "HARDWARE HIERARCHY [%s]" (if current then "current" else "historical")
    ; sprintf "Result: job %s" (Job_id.to_string hierarchy.generating_job)
    ; sprintf "Target: %s" target
    ; sprintf "Configuration: %s" configuration
    ; "Artifact: " ^ Artifact_id.to_string hierarchy.artifact
    ; "Project: " ^ Project_id.to_string hierarchy.project
    ; "Exact target/configuration: "
      ^ Target_id.to_string hierarchy.target
      ^ " / "
      ^ Configuration_id.to_string hierarchy.configuration
    ; "Tested top / DUT: unknown (no provider association)"
    ; "Provenance: " ^ Sexp.to_string_mach (Provenance.sexp_of_t hierarchy.provenance)
    ; "RTL artifacts: "
      ^ String.concat
          ~sep:", "
          (List.map hierarchy.rtl_artifacts ~f:Artifact_id.to_string)
    ]
  in
  (* Reserve the actual provenance and selected-node rows. On short screens retain one
     tree row; existing pane scrolling reaches every remaining detail row. *)
  let tree_height = Int.max 1 (height - List.length header - 1 - List.length inspector) in
  let tree = tree ~tree_height in
  let lines =
    header
    @ [ sprintf "Tree [%d/%d]" view.scroll (Int.max 0 (List.length visible - tree_height))
      ]
    @ tree
    @ inspector
  in
  view.pane_scroll <- Int.min view.pane_scroll (Int.max 0 (List.length lines - height));
  List.drop lines view.pane_scroll
;;

let artifact_lines session =
  let artifacts = project_artifacts session in
  match current_project session, artifacts with
  | _, [] -> [ "Artifacts: none" ]
  | None, _ -> [ "Artifacts: unavailable" ]
  | Some project, artifacts ->
    "ARTIFACTS"
    :: List.map artifacts ~f:(fun artifact ->
      let target =
        Option.bind artifact.target ~f:(fun id ->
          List.find project.targets ~f:(fun target -> Target_id.equal target.id id))
        |> Option.value_map ~default:"no target" ~f:(fun target -> target.name)
      in
      let configuration =
        Option.bind artifact.configuration ~f:(fun id ->
          List.find project.configurations ~f:(fun config ->
            Configuration_id.equal config.id id))
        |> Option.value_map ~default:"no configuration" ~f:(fun config -> config.name)
      in
      sprintf
        "%s %s (%s) | %s / %s | job %s | [%s]"
        (if Option.value_map session.selected_artifact ~default:false ~f:(fun id ->
              Artifact_id.equal id artifact.id)
         then ">"
         else " ")
        artifact.metadata.display_name
        (Artifact.Kind.to_string artifact.kind)
        target
        configuration
        (Job_id.to_string artifact.generating_job)
        (Artifact_id.to_string artifact.id))
;;

let connection_detail_lines session ~width =
  let field label value = label :: Presentation.wrap_value ~width ~indent:"  " value in
  let root value = "Root:" :: Presentation.wrap_path ~width ~indent:"  " value in
  field "Endpoint:" (Http.Client.endpoint session.client)
  @ field "Daemon instance:" (V1.Daemon_instance_id.to_string session.hello.instance_id)
  @ field "Protocol:" (sprintf "v%d" V1.version)
  @ field "Connection:" session.status
  @
  match session.opened with
  | None ->
    field "Project:" "none" @ field "Requested environment:" session.environment_label
  | Some opened ->
    let project = Option.value (current_project session) ~default:opened.project in
    let component = function
      | Project_integration.Component_status.Absent -> "absent"
      | Available { version = None } -> "available"
      | Available { version = Some version } -> sprintf "available v%d" version
      | Unusable { reason } -> "unusable: " ^ reason
    in
    field "Project:" project.name
    @ root (Project_root.to_absolute_path opened.project.root)
    @ field "Requested environment:" session.environment_label
    @ field "Resolved environment:" opened.environment.provenance
    @ field "Dune version:" opened.environment.dune_version
    @ field "Manifest integration:" (component project.integration.manifest)
    @ field "Driver integration:" (component project.integration.driver)
;;

let render_legacy session ({ Bonsai_term.Dimensions.width; height } as dimensions) =
  let open Bonsai_term in
  if not (Option.equal Dimensions.equal session.last_dimensions (Some dimensions))
  then (
    session.last_dimensions <- Some dimensions;
    append_diagnostic
      session.diagnostics_file
      (sprintf "dimensions width=%d height=%d" width height));
  let background = View.rectangle ~width ~height () in
  let content =
    if width < minimum_width || height < minimum_height
    then
      View.center
        (View.vcat
           [ View.text ~attrs:[ Attr.bold ] "Hardcaml Workbench"
           ; View.text
               (sprintf
                  "Terminal too small (%dx%d); need at least %dx%d"
                  width
                  height
                  minimum_width
                  minimum_height)
           ; View.text "Resize to continue. q exits."
           ])
        ~within:dimensions
    else (
      let jobs = project_jobs session in
      let header =
        [ sprintf
            "Hardcaml Workbench | %s | %s"
            session.status
            (Http.Client.endpoint session.client)
        ]
      in
      let workspace_rows =
        match session.opened with
        | None -> [ "  (no project opened)" ]
        | Some opened ->
          if List.is_empty opened.workspace.items
          then [ "  (no local items reported)" ]
          else
            List.map opened.workspace.items ~f:(fun item ->
              sprintf
                "  %-12s %s%s"
                item.kind
                (if List.is_empty item.names
                 then "(unnamed)"
                 else String.concat item.names ~sep:",")
                (Option.value_map item.source_path ~default:"" ~f:(fun path ->
                   "  " ^ path)))
      in
      let job_rows =
        if List.is_empty jobs
        then [ "  (no jobs)" ]
        else
          List.mapi jobs ~f:(fun index job ->
            sprintf
              "%s %-24s %-12s %-16s %s"
              (if index = session.selected then ">" else " ")
              (Job_id.to_string job.id)
              (Job.State.to_string job.state)
              (Job.Kind.to_string job.kind)
              (Option.value job.phase ~default:""))
      in
      let detail =
        match selected_job session with
        | None -> [ ""; "SELECTED JOB"; "  none" ]
        | Some job ->
          [ ""; "SELECTED JOB"; "  " ^ Job_id.to_string job.id ]
          @ List.map (Presentation.job_outcome_lines job) ~f:(fun line -> "  " ^ line)
      in
      let controls =
        if session.show_connection_details
        then
          "d project | [/] details | b/t jobs | n/m select | g RTL | a/v artifact | h \
           hierarchy | i refresh | j/k job | c cancel | r reconnect | q exit"
        else
          "b/t jobs | n/m select | g RTL | a/v artifact | h hierarchy | u/o node | e \
           expand | [/] pane | i refresh | j/k job | c cancel | d details | r reconnect \
           | q exit"
      in
      let top_height = Int.max 8 ((height - List.length header - 3) / 2) in
      let console_height = Int.max 1 (height - List.length header - top_height - 3) in
      let left_width = width / 3 in
      let right_width = width - left_width - 1 in
      let pane ~width ~height lines =
        let lines = List.take lines height in
        let lines = lines @ List.init (height - List.length lines) ~f:(fun _ -> "") in
        lines
        |> List.map ~f:(fun line ->
          let line = fit width line in
          View.text (line ^ String.make (width - String.length line) ' '))
        |> View.vcat
      in
      let project_pane =
        let lines =
          if session.show_connection_details
          then (
            let lines = connection_detail_lines session ~width:left_width in
            let visible_lines = Int.max 1 (top_height - 1) in
            let maximum_scroll = Int.max 0 (List.length lines - visible_lines) in
            session.connection_details_scroll
            <- Int.min maximum_scroll session.connection_details_scroll;
            [ sprintf
                "CONNECTION DETAILS [%d/%d]"
                session.connection_details_scroll
                maximum_scroll
            ]
            @ (lines
               |> Fn.flip List.drop session.connection_details_scroll
               |> Fn.flip List.take visible_lines))
          else (
            match session.hierarchy_view with
            | Some view -> hierarchy_view_lines session view ~height:top_height
            | None ->
              [ "PROJECT / GENERIC DUNE WORKSPACE" ]
              @ project_lines session ~width:left_width
              @ [ ""; "WORKBENCH INTEGRATION" ]
              @ integration_lines session
              @ [ "" ]
              @ hierarchy_status_lines session
              @ [ "" ]
              @ artifact_lines session
              @ [ ""; "DUNE ITEMS" ]
              @ workspace_rows)
        in
        pane ~width:left_width ~height:top_height lines
      in
      let jobs_pane =
        pane
          ~width:right_width
          ~height:top_height
          ([ "JOBS" ] @ detail @ [ "" ] @ job_rows)
      in
      let upper =
        View.hcat
          [ project_pane
          ; View.rectangle ~fill:'|' ~width:1 ~height:top_height ()
          ; jobs_pane
          ]
      in
      let console_title, console =
        match session.artifact_view with
        | Some view ->
          let label =
            selected_artifact session
            |> Option.value_map
                 ~default:(Artifact_id.to_string view.artifact)
                 ~f:(fun artifact -> artifact.metadata.display_name)
          in
          let preparation_artifact =
            Terminal_presentation.Preparation_view.attempts session.host.preparation
            |> List.exists ~f:(fun a ->
              Option.exists a.bundle ~f:(fun b ->
                List.mem b.artifacts view.artifact ~equal:Artifact_id.equal))
          in
          ( (if preparation_artifact
             then "PREPARATION BUNDLE ARTIFACT (Esc returns): "
             else "RTL ARTIFACT: ")
            ^ label
          , (String.split_lines view.content
             @ if view.truncated then [ "[artifact view truncated at 1 MiB]" ] else [])
            |> Fn.flip List.take console_height )
        | None ->
          ( "LIVE STDOUT / STDERR"
          , (match selected_job session with
             | None -> [ "  (select a job to read logs)" ]
             | Some job ->
               let state = log_state session job.id in
               let records =
                 List.concat_map state.records ~f:(fun record ->
                   let tag =
                     match record.stream with
                     | V1.Read_log.Stream.Stdout -> "[stdout] "
                     | Stderr -> "[stderr] "
                   in
                   String.split_lines record.data |> List.map ~f:(fun line -> tag ^ line))
               in
               (match state.fetch with
                | Presentation.Log_fetch.Error message when not (List.is_empty records) ->
                  records @ [ "[log retrieval failed] " ^ message ]
                | _ when not (List.is_empty records) -> records
                | fetch ->
                  Presentation.empty_log_notice ~job_state:job.state ~fetch
                  |> Option.to_list
                  |> List.map ~f:(fun line -> "  " ^ line))
               |> Fn.flip take_end console_height) )
      in
      View.vcat
        [ View.vcat (List.map header ~f:(fun line -> View.text (fit width line)))
        ; upper
        ; View.text (String.make width '-')
        ; View.text console_title
        ; pane ~width ~height:console_height console
        ; View.text (fit width controls)
        ])
  in
  View.zcat [ content; background ]
;;

let host_data session : Host_view.data =
  let runs =
    Option.value_map session.asic ~default:[] ~f:(fun asic ->
      List.map asic.runs ~f:(fun run -> run.run, run.status))
  in
  let log_lines id =
    let state = log_state session id in
    let rows =
      List.concat_map state.records ~f:(fun record ->
        let tag =
          match record.stream with
          | V1.Read_log.Stream.Stdout -> "[stdout] "
          | Stderr -> "[stderr] "
        in
        String.split_lines record.data |> List.map ~f:(fun line -> tag ^ line))
    in
    if not (List.is_empty rows)
    then (
      match state.fetch with
      | Presentation.Log_fetch.Error error -> rows @ [ "[log retrieval failed] " ^ error ]
      | _ -> rows)
    else (
      let job_state =
        List.find (project_jobs session) ~f:(fun job -> Job_id.equal job.id id)
        |> Option.value_map ~default:Job.State.Queued ~f:(fun job -> job.state)
      in
      Presentation.empty_log_notice ~job_state ~fetch:state.fetch |> Option.to_list)
  in
  let run_lines = Host_view.run_lines session.asic in
  let asic_lines =
    match session.asic with
    | None -> [ "ASIC provider not loaded — palette: Discover ASIC" ]
    | Some asic ->
      [ (if asic.configured
         then "Project-owned ASIC flows (Space c c: discover / describe / plan / launch)"
         else "No ASIC provider configured for this project")
      ]
      @ List.map asic.operations ~f:(fun op ->
        sprintf
          "%s: %s %s%s"
          op.kind
          op.state
          (Option.value_map
             op.run
             ~default:
               (if String.equal op.kind "run"
                then
                  if String.equal op.state "executing" || String.equal op.state "queued"
                  then "(awaiting allocation — no run ID yet)"
                  else "(no allocated run reference)"
                else "(project/read operation)")
             ~f:Host_view.run_label)
          (Option.value_map op.error ~default:"" ~f:(fun e -> " — " ^ e)))
      @ List.concat_map asic.finalizations ~f:Host_view.finalization_lines
      @ Option.value_map asic.preview ~default:[] ~f:(fun p ->
        [ "PREVIEW " ^ p.plan_identity
        ; "Selection: " ^ Sexp.to_string_hum (Asic.Selection.sexp_of_t p.selection)
        ]
        @ String.split_lines p.plan_json)
      @ Option.value_map asic.description_json ~default:[] ~f:(fun json ->
        "FLOW CAPABILITIES" :: String.split_lines json)
      @ Option.to_list asic.cache_error
  in
  { project = current_project session
  ; jobs = project_jobs session
  ; runs
  ; log_lines
  ; run_lines
  ; run_context = Host_view.request_context session.asic
  ; summary =
      (fun run ->
        Option.bind session.asic ~f:(fun asic ->
          List.find asic.summaries ~f:(fun summary ->
            Run_ref.equal summary.Asic.Summary.run run)))
  ; status = session.status
  ; environment = session.environment_label
  ; asic_lines
  ; asic = session.asic
  }
;;

let hierarchy_pane session (tile : Workspace.Tile.t) ~width ~height =
  if not (String.equal tile.kind "hierarchy")
  then None
  else
    let module V = Terminal_presentation.Hierarchy_view in
    let local = Host.local session.host tile.id in
    let header, tree =
      match local.hierarchy with
      | None ->
        ( [ "HIERARCHY — not loaded"; local.hierarchy_status; "Tested top / DUT: unknown" ]
        , [] )
      | Some view ->
        let h = V.hierarchy view in
        let current =
          Option.exists (current_project session) ~f:(fun p ->
            Project_id.equal p.id h.project)
          && State.hierarchy_is_current
               h
               ~latest:(current_generation session)
               ~target:session.selected_target
               ~configuration:session.selected_configuration
        in
        let top =
          List.find h.nodes ~f:(fun n -> String.equal n.key h.root)
          |> Option.value_map ~default:"unknown" ~f:(fun n -> n.circuit_name)
        in
        ( [ "HIERARCHY [" ^ (if current then "current" else "historical") ^ "] Top: " ^ top
          ; "Job: "
            ^ Host_view.fit_label
                ~width:(Int.max 4 ((width - 17) / 2))
                (Job_id.to_string h.generating_job)
            ^ " Artifact: "
            ^ Host_view.fit_label
                ~width:(Int.max 4 ((width - 17) / 2))
                (Artifact_id.to_string h.artifact)
          ; "Target/config: "
            ^ Target_id.to_string h.target
            ^ " / "
            ^ Configuration_id.to_string h.configuration
          ; "DUT: unknown | " ^ local.hierarchy_status
          ]
        , V.rows view ~height:(Int.max 1 (height - 5)) )
    in
    let hints =
      if (Host.policy session.host tile).hints
      then [ "j/k ↑↓ browse | Enter expand | i detail | r load current" ]
      else []
    in
    let rows =
      if height <= 3
      then List.take header 1 @ if List.is_empty tree then List.drop header 1 else tree
      else header @ tree @ hints
    in
    Some
      (Host_view.lines
         ~appearance:session.host.appearance
         ~width
         ~height
         (List.map rows ~f:Terminal_presentation.Artifact_view.safe))
;;

let waveform_pane session (tile : Workspace.Tile.t) ~width ~height =
  Option.map (Waveforms.pane tile.kind) ~f:(fun pane ->
    let appearance = session.host.appearance in
    let hints = (Host.policy session.host tile).hints in
    let lines ?(role = Host_view.Role.Foreground) rows =
      Host_view.lines ~appearance ~role ~width ~height rows
    in
    match
      List.Assoc.find
        session.waveform_workspaces
        (Workspace.Workspace_id.to_string tile.workspace)
        ~equal:String.equal
    with
    | None ->
      lines [ "No retained waveform pinned"; "Select a VCD in Testing and press W" ]
    | Some rt ->
      (match pane with
       | Session ->
         let project_label =
           match Or_error.try_with (fun () -> Sexp.of_string rt.pin.project_key) with
           | Ok (List (Atom root :: _)) -> Filename.basename root
           | _ -> Project_id.to_string rt.pin.project
         in
         Waveform_view.render_session
           ~appearance
           ~hints
           ~string_compression:(Host.policy session.host tile).string_compression
           rt.view
           ~project_label
           ~width
           ~height
       | Signals ->
         rt.view
         <- Waveform_view.prepare_signals
              ~value_layout:session.waveform_value_layout
              rt.view
              ~width;
         Waveform_view.render_signals
           ~appearance
           ~hints
           ~value_layout:session.waveform_value_layout
           rt.view
           ~width
           ~height
       | Waves ->
         (match rt.view.identity_scroll with
          | Some scroll ->
            let rows =
              Waveform_view.identity_lines rt.view ~width:(Int.max 1 width)
              @ Artifact_view.wrap
                  ~width:(Int.max 1 width)
                  (Artifact_view.safe ("Project context " ^ rt.pin.project_key))
              @ Artifact_view.wrap
                  ~width:(Int.max 1 width)
                  (Artifact_view.safe
                     ("Captured logs "
                      ^ Sexp.to_string_hum (Waveforms.sexp_of_log_source rt.pin.log)))
            in
            let visible = Int.max 1 (height - 1) in
            let scroll = Int.min scroll (Int.max 0 (List.length rows - visible)) in
            (if hints
             then "Exact identity · Esc/i return · j/k scroll"
             else "Exact identity · Esc/i return")
            :: (List.drop rows scroll |> Fn.flip List.take visible)
            |> lines
          | None ->
            rt.view <- Waveform_view.prepare_waves rt.view ~width;
            Waveform_view.render_waves ~appearance ~hints rt.view ~width ~height)
       | Picker ->
         let visible = Int.max 1 (height - 2) in
         let first = Int.max 0 (rt.picker_index - visible + 1) in
         ([ "Pinned: "
            ^ Waveform_view.shorten ~width:(Int.max 8 (width - 8)) rt.pin.artifact.label
          ]
          @ (List.drop rt.artifacts first
             |> Fn.flip List.take visible
             |> List.mapi ~f:(fun i a ->
               sprintf
                 "%s%s %s · %s"
                 (if first + i = rt.picker_index then ">" else " ")
                 (if Waveform_view.picker_matches_pin ~pinned:rt.pin.artifact a
                  then "*"
                  else " ")
                 a.label
                 (Option.value a.case_id ~default:"attempt")))
          @
          if not (String.is_empty rt.picker_status)
          then [ rt.picker_status ]
          else if hints
          then [ "j/k browse · Enter retargets all panes" ]
          else [])
         |> lines
       | Logs ->
         let local = Host.local session.host tile.id in
         let status =
           match rt.logs.fetch with
           | Not_requested -> "Pinned logs not yet requested"
           | Fetching -> "Reading pinned attempt logs"
           | Error e -> e
           | Received { eof } ->
             if List.is_empty rt.logs.records
             then
               if eof
               then "Pinned job produced no stdout/stderr"
               else "Waiting for pinned job output"
             else if eof
             then "End of retained pinned log"
             else "Pinned log continues"
         in
         let rows =
           rt.logs.records
           |> Fn.flip take_end 128
           |> List.concat_map ~f:(fun r -> String.split_lines r.V1.Read_log.Record.data)
           |> List.concat_map ~f:(fun s ->
             Artifact_view.wrap ~width:(Int.max 1 width) (Artifact_view.safe s))
         in
         let visible = Int.max 1 (height - 2) in
         let offset =
           if local.follow
           then Int.max 0 (List.length rows - visible)
           else Int.min local.scroll (Int.max 0 (List.length rows - visible))
         in
         ("Pinned attempt output" :: (List.drop rows offset |> Fn.flip List.take visible))
         @ [ status ]
         |> lines))
;;

let render ?(now = Time_ns.now ()) ?indicator_frames session dimensions =
  let render_host () =
    session.last_dimensions <- Some dimensions;
    reconcile_synthesis session;
    let data = host_data session in
    session.host <- Host_view.reconcile_simulation_viewports session.host data dimensions;
    let host =
      match session.presentation_preference_notice with
      | None -> session.host
      | Some notice ->
        { session.host with
          chrome = true
        ; notice =
            String.concat
              ~sep:" | "
              (List.filter [ notice; session.host.notice ] ~f:(Fn.non String.is_empty))
        }
    in
    reconcile_waveform_workspaces session;
    Host_view.render
      ~now
      ?indicator_frames
      ~render_pane:(fun tile ~width ~height ->
        match hierarchy_pane session tile ~width ~height with
        | Some pane -> Some pane
        | None -> waveform_pane session tile ~width ~height)
      host
      data
      dimensions
  in
  match session.waveform_visible, session.waveform with
  | true, Some view ->
    session.last_dimensions <- Some dimensions;
    let appearance = session.host.appearance in
    let view =
      Waveform_view.prepare_quick
        ~appearance
        ~value_layout:session.waveform_value_layout
        view
        dimensions
    in
    session.waveform <- Some view;
    Host_view.render_palette
      session.host
      dimensions
      (Waveform_view.render
         ~appearance
         ~value_layout:session.waveform_value_layout
         ~string_compression:
           (Option.value_map
              (Host.focused session.host)
              ~default:
                (Option.value session.host.presentation.string_compression ~default:true)
              ~f:(fun tile -> (Host.policy session.host tile).string_compression))
         view
         dimensions)
  | _ ->
    (match session.host.registry with
     | None
       when Option.is_some session.opened
            && List.mem session.hello.capabilities "workspace" ~equal:String.equal ->
       render_host ()
     | None -> render_legacy session dimensions
     | Some _
       when Option.is_some session.hierarchy_view
            || Option.is_some session.artifact_view
            || session.show_connection_details -> render_legacy session dimensions
     | Some _ -> render_host ())
;;

(* Baseline capture.

   This is a development hook, not a second UI. It builds a [session] directly from a
   deterministic fixture and calls the same [render] the interactive client calls, then
   serialises the resulting [View.t] with Notty. Nothing above this point changes, so the
   captures show the production layout rather than a reimplementation of it. *)

let session_of_baseline_fixture (fixture : Baseline_fixture.t) =
  let session =
    { requested_endpoint = Some fixture.endpoint
    ; project_root = Some (Project_root.to_absolute_path fixture.opened.project.root)
    ; environment_selection = fixture.opened.environment.selection
    ; environment_label = fixture.environment_label
    ; diagnostics_file = None
    ; client = Http.Client.create fixture.endpoint
    ; hello = fixture.hello
    ; opened = Some fixture.opened
    ; snapshot = fixture.snapshot
    ; selected = 0
    ; selected_target = fixture.selected_target
    ; selected_configuration = fixture.selected_configuration
    ; selected_artifact = fixture.selected_artifact
    ; artifact_view = None
    ; hierarchy_view = None
    ; hierarchy_intent = ref ()
    ; hierarchy_errors = Artifact_id.Table.create ()
    ; hierarchy_reads = ref []
    ; logs = Job_id.Table.create ()
    ; status = fixture.status
    ; polling = false
    ; hydration = Terminal_presentation.Retained_hydration.Coordinator.create ()
    ; retained_reads = Terminal_presentation.Retained_hydration.create ()
    ; navigation_loaded = Terminal_presentation.Retained_hydration.Load.create ()
    ; navigation_pending = None
    ; navigation_saved = None
    ; navigation_failed = false
    ; navigation_revision = 0
    ; navigation_restore_revision = 0
    ; navigation_touched = []
    ; navigation_focus_touched = []
    ; reconnect_delay_ms = 250
    ; last_dimensions = None
    ; show_connection_details = fixture.show_connection_details
    ; connection_details_scroll = 0
    ; host = Host.empty
    ; workspace_config = None
    ; registry_busy = false
    ; asic = None
    ; asic_request_id = 0
    ; resource_navigation_intent = ref ()
    ; preparation_request_id = 0
    ; asic_applied_id = 0
    ; timing_demand = None
    ; timing_preload = Terminal_presentation.Timing_preload.empty
    ; timing_index_inflight = []
    ; timing_preload_receipt = None
    ; view_on_allocation = None
    ; remembered_selection = None
    ; preferences_loaded = true
    ; presentation_preferences_loaded = Some "fixture"
    ; presentation_preferences = None
    ; presentation_preference_notice = None
    ; preference_saves = Deferred.unit
    ; asic_reads = Asic_intents.empty
    ; remembered_acceptance = ""
    ; artifact_viewer = None
    ; artifact_binary_viewer = None
    ; artifact_export_busy = false
    ; waveform = None
    ; waveform_visible = false
    ; waveform_generation = 0
    ; waveform_history = []
    ; waveform_workspaces = []
    ; waveform_preferences_loaded = None
    ; waveform_preferences_pending = None
    ; waveform_preferences_saved = None
    ; waveform_preferences_failed = false
    ; waveform_open_generation = 0
    ; waveform_value_layout = Inline
    ; waveform_display_loaded = None
    ; waveform_display_revision = 0
    }
  in
  reconcile_selection session;
  preserve_selected_job session fixture.selected_job;
  List.iter fixture.logs ~f:(fun { job; records; fetch } ->
    let state = log_state session job in
    state.records <- records;
    state.next_offset
    <- List.fold records ~init:0 ~f:(fun offset record ->
         Int.max offset (record.offset + 1));
    state.fetch <- fetch);
  Option.iter fixture.artifact_view ~f:(fun { artifact; content; truncated } ->
    session.artifact_view <- Some { artifact; content; truncated });
  Option.iter fixture.hierarchy ~f:(fun (hierarchy, state) ->
    let nodes, children = index_hierarchy hierarchy in
    session.hierarchy_view
    <- Some
         { hierarchy
         ; nodes
         ; children
         ; selected_key = state.selected_key
         ; expanded = String.Set.of_list state.expanded
         ; scroll = 0
         ; pane_scroll = 0
         });
  session
;;

let capture_dimensions =
  [ { Bonsai_term.Dimensions.width = 80; height = 24 }
  ; { Bonsai_term.Dimensions.width = 120; height = 40 }
  ]
;;

let render_to_string session dimensions ~cap =
  let { Bonsai_term.Dimensions.width; height } = dimensions in
  let buffer = Buffer.create (width * height * 2) in
  Notty.Render.to_buffer
    buffer
    cap
    (0, 0)
    (width, height)
    (Bonsai_term.View.Private.notty_image (render session dimensions));
  Buffer.contents buffer
;;

let capture_baseline_frames ~directory =
  Core_unix.mkdir_p directory;
  let written =
    List.concat_map Baseline_fixture.all ~f:(fun fixture ->
      List.concat_map capture_dimensions ~f:(fun dimensions ->
        let { Bonsai_term.Dimensions.width; height } = dimensions in
        let stem = sprintf "%s.%dx%d" fixture.name width height in
        (* A fresh session per capture: [render] reconciles scroll offsets in place, so a
           reused session would carry the previous size's state into the next capture. *)
        [ ( stem ^ ".txt"
          , render_to_string
              (session_of_baseline_fixture fixture)
              dimensions
              ~cap:Notty.Cap.dumb
            ^ "\n" )
        ; ( stem ^ ".ansi"
          , render_to_string
              (session_of_baseline_fixture fixture)
              dimensions
              ~cap:Notty.Cap.ansi )
        ]))
  in
  List.iter written ~f:(fun (name, contents) ->
    Out_channel.write_all (Filename.concat directory name) ~data:contents);
  List.iter Baseline_fixture.all ~f:(fun fixture ->
    printf "%s: %s\n" fixture.name fixture.summary);
  printf "wrote %d files to %s\n" (List.length written) directory
;;

let key_is char = function
  | Bonsai_term.Event.Key.ASCII value -> Char.equal char value
  | Uchar value -> Uchar.equal value (Uchar.of_char char)
  | _ -> false
;;

let active_waveform_runtime session =
  Option.bind (Host.active session.host) ~f:(fun workspace ->
    Option.map
      (List.Assoc.find
         session.waveform_workspaces
         (Workspace.Workspace_id.to_string workspace.id)
         ~equal:String.equal)
      ~f:(fun rt -> workspace.id, rt))
;;

let waveform_context session =
  if session.waveform_visible
  then
    Option.map session.waveform ~f:(fun v -> v, fun view -> session.waveform <- Some view)
  else
    Option.map (active_waveform_runtime session) ~f:(fun (_, rt) ->
      rt.view, fun view -> rt.view <- view)
;;

let host_catalog_base session =
  Host.catalog
    session.host
    ~project:(current_project session)
    ~jobs:(project_jobs session)
  @ Option.value_map (waveform_context session) ~default:[] ~f:(fun (view, _) ->
    List.map
      [ "toggle", "Toggle focused signal (Enter)"
      ; "in", "Zoom in"
      ; "out", "Zoom out"
      ; "first", "First timestamp"
      ; "last", "Last timestamp"
      ; "identity", "Inspect exact identity"
      ; "refresh", "Reload pinned bytes and artifact list"
      ; "values-inline", "Signal values: Inline (aligned columns; default)"
      ; "values-stacked", "Signal values: Stacked (two rows per signal)"
      ; "back", "Return from quick inspection"
      ]
      ~f:(fun (id, title) ->
        Host.command
          ("waveform." ^ id)
          ("Waveform: " ^ title)
          "wave vcd cursor signal"
          (Waveform_control (id, view.artifact)))
    @ [ Host.command
          "waveform.workspace"
          "Waveform: Open dedicated Waveforms workspace"
          "signals waves picker logs"
          (Simulation_waveform_workspace view.artifact)
      ])
  @ Option.value_map (active_waveform_runtime session) ~default:[] ~f:(fun (_, rt) ->
    List.map rt.artifacts ~f:(fun artifact ->
      Host.command
        ("waveform.pick." ^ artifact.id)
        ("Waveform: Select VCD " ^ artifact.label)
        "explicit retarget pinned attempt"
        (Simulation_waveform_workspace artifact)))
  @ (match Host.focused session.host with
     | Some tile when Host.simulation_kind tile.kind ->
       let v = Host.simulation session.host tile.id in
       let cmd id title operation =
         Host.command
           ("simulation." ^ id)
           ("Simulation: " ^ title)
           "suite cases seed history"
           (Host.Simulation (tile.id, operation))
       in
       [ cmd "discover" "Discover suites explicitly" Discover
       ; cmd "history" "Newest history page" (History { before = None; limit = 25 })
       ]
       @ Option.value_map v.snapshot ~default:[] ~f:(fun s ->
         Option.value_map s.next_before ~default:[] ~f:(fun before ->
           [ cmd
               "older"
               "Older history page"
               (History { before = Some before; limit = 25 })
           ])
         @ List.map s.attempts ~f:(fun a ->
           cmd ("open." ^ a.id) ("Reopen " ^ a.id ^ " " ^ a.suite) (Observe a.id))
         @
         if Testing_workspace.is_pane tile.kind
         then []
         else
           Option.value_map s.discovery ~default:[] ~f:(fun d ->
             List.map d.suites ~f:(fun suite ->
               Host.command
                 ("simulation.launch." ^ suite.id)
                 ("Simulation: Launch form " ^ suite.label)
                 "seed parameters cases"
                 (Simulation_form
                    ( tile.id
                    , Option.value s.discovery_digest ~default:""
                    , suite
                    , submission_key "simulation" )))))
       @ (if Testing_workspace.is_pane tile.kind
          then
            [ Host.testing_launch_command session.host tile.id
            ; Host.command
                "simulation.catalog-accept"
                "Simulation: Accept current discovery for selected subset"
                "stale catalog"
                (Testing_accept tile.id)
            ]
          else [])
       @ Option.value_map
           (Host.testing session.host tile.id)
           ~default:[]
           ~f:(fun (_, _, state) ->
             Option.value_map
               (Testing_workspace.workload_artifact state)
               ~default:[]
               ~f:(fun artifact ->
                 [ Host.command
                     "workloads.inspect-result"
                     "Inspect workload result (selected Testing case)"
                     "PT8 retained result reference"
                     (Host.Workload_reference (tile.id, artifact))
                 ]))
       @ Option.value_map (Simulation_view.detail v) ~default:[] ~f:(fun d ->
         [ cmd "cancel" ("Cancel " ^ d.id) (Cancel d.id) ]
         @ Host.simulation_log_commands tile
         @ List.map d.cases ~f:(fun c ->
           Host.command
             ("simulation.case." ^ c.case_id)
             ("Simulation: Select case " ^ c.case_id)
             "detail failure"
             (Simulation_case (tile.id, c.case_id)))
         @ Host.simulation_selection_commands session.host tile ~submission_key)
     | _ -> [])
  @ Option.value_map (current_generation session) ~default:[] ~f:(fun job ->
    List.map job.artifacts ~f:(fun id ->
      Host.command
        ("preparation.generic-rtl-artifact." ^ Artifact_id.to_string id)
        ("Generic RTL "
         ^ Job_id.to_string job.id
         ^ ": artifact "
         ^ Artifact_id.to_string id)
        "generate-rtl current target configuration read-only output"
        (Preparation_open_artifact id)))
  @ (Terminal_presentation.Preparation_view.attempts session.host.preparation
     |> List.concat_map ~f:(fun a ->
       Option.value_map a.bundle ~default:[] ~f:(fun b ->
         List.map b.artifacts ~f:(fun id ->
           Host.command
             ("preparation.artifact." ^ Artifact_id.to_string id)
             ("Preparation " ^ a.id ^ ": artifact " ^ Artifact_id.to_string id)
             "bundle published inspect read-only"
             (Preparation_open_artifact id)))))
  @ Option.value_map session.remembered_selection ~default:[] ~f:(fun selection ->
    let available =
      Option.value_map session.asic ~default:false ~f:(fun asic ->
        Launch_preferences.available selection asic.flows)
    in
    [ Host.command
        ?unavailable:
          (if available
           then None
           else
             Some
               "Remembered flow/profile is not currently discovered; discover it \
                explicitly")
        "asic.plan-remembered"
        (sprintf
           "Plan remembered inputs: %s / %s → %s"
           selection.flow
           selection.profile
           selection.endpoint)
        "run synth last used"
        (Asic (Plan selection))
    ])
  @ Terminal_presentation.Stage_launch_commands.commands
      session.host
      ~asic:session.asic
      ~remembered:session.remembered_selection
  @ Host.launch_commands
      session.host
      ~preview:(Option.bind session.asic ~f:(fun asic -> asic.preview))
      ~view_pending:(Option.is_some session.view_on_allocation)
  @ Option.value_map session.asic ~default:[] ~f:(fun asic ->
    List.concat_map asic.flows ~f:(fun flow ->
      (Host.command
         ("asic.describe." ^ flow.id)
         ("Describe ASIC flow " ^ flow.id)
         "endpoints parameters"
         (Asic (Describe flow.id))
       :: List.map flow.profiles ~f:(fun profile ->
         Host.command
           ("asic.plan." ^ flow.id ^ "." ^ profile)
           ("Plan ASIC " ^ flow.id ^ " / " ^ profile ^ " (enter endpoint)")
           "run synth preview"
           (Edit_plan (flow.id, profile))))
      @ List.map flow.profiles ~f:(fun profile ->
        Host.command
          ("preparation.inputs." ^ flow.id ^ "." ^ profile)
          ("Preparation inputs: " ^ flow.id ^ " / " ^ profile)
          "selected flow endpoint overrides EDA-less no launch"
          (Edit_preparation (flow.id, profile))))
    @ Host.asic_cancel_commands asic
    @ List.map asic.finalizations ~f:(fun finalization ->
      Host.command
        ("asic.finalize-observe." ^ finalization.key)
        ("Reconnect finalization " ^ finalization.key ^ " (read-only)")
        "observe phase acceptance status"
        (Asic (Observe_finalization finalization.key)))
    @ List.concat_map asic.runs ~f:(fun run ->
      [ Host.command
          ("asic.refresh." ^ Host_view.run_label run.run)
          ("Refresh evidence " ^ Host_view.run_label run.run)
          "validate source"
          (Asic (Refresh run.run))
      ; Host.command
          ("asic.inspect-finalization." ^ Host_view.run_label run.run)
          ("Inspect finalization for "
           ^ Host_view.run_label run.run
           ^ " (enter exact attempt)")
          "import terminal results timing physical checks read-only"
          (Edit_finalization run.run)
      ; Host.command
          ("asic.artifacts." ^ Host_view.run_label run.run)
          ("Browse reports/artifacts " ^ Host_view.run_label run.run)
          "catalog report bounded text"
          (Browse_artifacts run.run)
      ]
      @ (let stage, analysis =
           Terminal_presentation.Overview_tiles.timing_inspection_target
             ~asic:session.asic
             ~run:run.run
         in
         [ Host.command
             ("asic.inspection.timing." ^ Host_view.run_label run.run)
             ("Inspect timing paths " ^ Host_view.run_label run.run ^ " · " ^ stage)
             "typed rows endpoints corner group producer exact captured analysis"
             (match analysis with
              | Some target -> Browse_analysis (run.run, target)
              | None -> Browse_inspection (run.run, "timing", stage))
         ; Host.command
             ("asic.inspection.separate-timing." ^ Host_view.run_label run.run)
             ("Separate Timing investigation " ^ Host_view.run_label run.run)
             "explicit captured independent workspace exact source"
             (Browse_separate_timing run.run)
         ])
      @ List.map Inspection_view.defaults ~f:(fun (domain, stage) ->
        Host.command
          ("asic.inspection." ^ domain ^ "." ^ Host_view.run_label run.run)
          ("Inspect "
           ^ (if String.equal domain "timing" then "timing paths" else domain)
           ^ " "
           ^ Host_view.run_label run.run
           ^ " · "
           ^ stage)
          "typed rows endpoints corner group producer"
          (Browse_inspection (run.run, domain, stage)))
      @ Option.value_map run.execution_file ~default:[] ~f:(fun execution_file ->
        [ Host.command
            ("asic.finalize." ^ Host_view.run_label run.run)
            ("Finalize (collect) " ^ Host_view.run_label run.run)
            "collect terminal reports"
            (Finalize_collect (run.run, execution_file))
        ; Host.command
            ("asic.finalize-accept." ^ Host_view.run_label run.run)
            ("Finalize and accept " ^ Host_view.run_label run.run)
            "explicit collateral testbench replay"
            (Edit_acceptance (run.run, execution_file))
        ])))
;;

(* WB-054: contextual actions for the focused view lead the palette and key dispatch. *)
let host_catalog session =
  let resource_commands =
    Option.value_map session.asic ~default:[] ~f:(fun asic ->
      let select label target =
        Host.command
          ("resources.select."
           ^ Plain_rpc.digest
               (Sexp.to_string_mach (Asic_resources.Target.sexp_of_t target)))
          ("Resources: Select " ^ label)
          "exact source inventory read only"
          (Resource_target (Some target))
      in
      List.map (Resources_view.snapshot session.asic).sources ~f:(fun s ->
        select ("source " ^ s.Asic_resources.Source.label ^ " · " ^ s.id) s.target)
      @ List.map asic.workflows ~f:(fun w ->
        let command =
          select ("workflow bundle " ^ w.Asic.Fresh.Workflow.id) (Workflow_bundle w.id)
        in
        if Option.is_some w.prepared
        then command
        else
          { command with
            unavailable = Some ("Workflow has no emitted bundle: " ^ w.elaboration_status)
          })
      @ List.map asic.runs ~f:(fun r ->
        select ("execution " ^ r.Asic.Run.run.id) (Run r.run))
      @ List.filter_map asic.finalizations ~f:(fun f ->
        Option.map f.Asic.Finalization.attempt ~f:(fun attempt ->
          select ("finalization " ^ attempt) (Finalization { run = f.run; attempt }))))
  in
  let workload_commands =
    Workloads_view.results (Workloads_view.snapshot session.asic)
    |> List.map ~f:(fun (result, _) ->
      let view =
        Option.value_map
          (Host.focused session.host)
          ~default:Workloads_view.empty
          ~f:(fun tile -> (Host.local session.host tile.id).workloads)
      in
      let expected_digest =
        match
          Workloads_view.inspection_query
            view
            result
            (Workloads_view.snapshot session.asic)
        with
        | Some (Inspect q) -> q.expected_digest
        | _ -> None
      in
      Host.command
        ("workloads.select." ^ Terminal_presentation.Plain_rpc.digest result)
        ("Workloads: Select " ^ result)
        "retained result source"
        (Workload_result (result, expected_digest)))
  in
  Host.contextual
    session.host
    (host_catalog_base session @ resource_commands @ workload_commands)
;;

let timing_prefetch_neighbors = ref 2

let activate_timing_demand session tile view =
  match session.timing_demand with
  | Some (previous, client, demand)
    when Workspace.Tile_id.equal previous.id tile.Workspace.Tile.id
         && phys_equal client session.client ->
    demand := Terminal_presentation.Timing_demand.restart !demand ~view
  | _ ->
    session.timing_demand
    <- Some
         ( tile
         , session.client
         , ref
             (Terminal_presentation.Timing_demand.create
                ~neighbors:!timing_prefetch_neighbors
                view) )
;;

let open_timing_workspace ?analysis ?(separate = false) session ~(run : Run_ref.t) ~stage =
  let instance = session.hello.instance_id in
  let client = session.client in
  let project = Option.map (current_project session) ~f:(fun p -> p.Project.id) in
  match session.host.registry, Host.active session.host with
  | Some initial, Some active ->
    let name = "Timing · captured " ^ run.id ^ " · " ^ submission_key "inspect" in
    let valid () =
      V1.Daemon_instance_id.equal instance session.hello.instance_id
      && phys_equal client session.client
      && Option.equal
           Project_id.equal
           project
           (Option.map (current_project session) ~f:(fun p -> p.Project.id))
      && Option.exists session.host.registry ~f:(fun s ->
        Workspace.Session_id.equal initial.session_id s.session_id)
    in
    let%bind workspace =
      match
        if separate
        then
          Host.matching_timing_analysis
            session.host
            { initial with
              workspaces =
                List.filter initial.workspaces ~f:(fun w ->
                  String.is_prefix w.name ~prefix:"Timing · captured ")
            }
            ~run
            ~analysis
        else
          Host.builtin_timing_in_window initial ~window:active.window
          |> Option.bind ~f:(fun w -> Host.matching_timing ~workspace:w.id initial ~run)
      with
      | Some workspace -> return (Some workspace.id)
      | None when not separate ->
        let notice =
          "Built-in Timing has a different selected run / pin, or hidden panes. Fix \
           bindings/visibility; Separate Timing investigation."
        in
        session.host
        <- { session.host with notice; timing_navigation_notice = Some notice };
        return None
      | None ->
        let template =
          (Hardcaml_workbench_workspaces.Presets.builtins "timing" |> Or_error.ok_exn)
            .template
        in
        let%bind () =
          mutate_workspace
            session
            (Instantiate_template
               { window = active.window; template = { template with name } })
        in
        if not (valid ())
        then return None
        else (
          match session.host.registry with
          | None -> return None
          | Some current ->
            (match
               List.find current.workspaces ~f:(fun w ->
                 String.equal w.name name
                 && not
                      (List.exists initial.workspaces ~f:(fun old ->
                         Workspace.Workspace_id.equal old.id w.id)))
             with
             | None -> return None
             | Some workspace ->
               let%bind () = mutate_workspace session (Make_independent workspace.id) in
               if not (valid ())
               then return None
               else (
                 match session.host.registry with
                 | None -> return None
                 | Some registry ->
                   if not
                        (List.exists registry.workspaces ~f:(fun current ->
                           Workspace.Workspace_id.equal current.id workspace.id))
                   then return None
                   else (
                     let workspace = Workspace.workspace registry workspace.id in
                     let context = Workspace.context registry workspace.context in
                     (* Never select through a shared context if independence was
                        rejected. *)
                     if Workspace.Context_id.equal context.id registry.main_context
                        || List.exists initial.contexts ~f:(fun old ->
                          Workspace.Context_id.equal old.id context.id)
                        || List.count registry.workspaces ~f:(fun w ->
                             Workspace.Context_id.equal w.context context.id)
                           <> 1
                     then return None
                     else (
                       let%map () =
                         mutate_workspace
                           session
                           (Select_run
                              { workspace = workspace.id
                              ; context = context.id
                              ; expected_selection_revision = context.selection_revision
                              ; run = Some run
                              })
                       in
                       Some workspace.id)))))
    in
    (match workspace with
     | None -> return ()
     | Some workspace when valid () ->
       (match session.host.registry with
        | None -> return ()
        | Some registry ->
          (match Host.matching_timing ~workspace registry ~run with
           | Some matching when Workspace.Workspace_id.equal matching.id workspace ->
             (match
                List.find registry.tiles ~f:(fun tile ->
                  Workspace.Workspace_id.equal tile.workspace workspace
                  && String.equal tile.kind "timing-paths"
                  && Option.value_map
                       matching.zoomed_tile
                       ~default:true
                       ~f:(Workspace.Tile_id.equal tile.id)
                  && not tile.hidden)
              with
              | None -> return ()
              | Some tile ->
                let generation =
                  List.Assoc.find
                    session.host.timing
                    (Workspace.Workspace_id.to_string workspace)
                    ~equal:String.equal
                  |> Option.value_map ~default:1 ~f:(fun view ->
                    view.Inspection_view.generation + 1)
                in
                let view =
                  Host.timing session.host tile
                  |> Option.filter ~f:(fun view ->
                    String.equal view.stage stage
                    && Run_ref.equal view.run run
                    && Option.equal
                         Asic_inspection.Analysis_target.equal
                         view.analysis
                         analysis)
                  |> Option.value
                       ~default:
                         (Timing_workspace.with_analysis
                            (Timing_workspace.create ~generation ~run ~stage)
                            analysis)
                in
                let view =
                  { view with
                    Inspection_view.workspace_epoch =
                      Some (Host.timing_epoch registry workspace)
                  }
                in
                let view =
                  Option.value_map
                    session.asic
                    ~default:view
                    ~f:(Inspection_view.reconcile view)
                in
                activate_workspace session workspace;
                session.host <- Host.set_timing session.host tile view;
                session.host
                <- Host.set_local
                     session.host
                     tile.id
                     { (Host.local session.host tile.id) with
                       artifacts = None
                     ; inspection = None
                     };
                session.host
                <- { session.host with
                     focus = Some tile.id
                   ; notice = "Timing investigation · captured run " ^ run.id
                   ; timing_navigation_notice = None
                   };
                activate_timing_demand session tile view;
                drive_timing_demand session;
                if Option.is_some view.index
                then return ()
                else (
                  let operation = Inspection_view.operation ~refresh:false view in
                  asic_request
                    ~inspection_request:(tile.id, Inspection_view.capture view operation)
                    session
                    operation))
           | _ -> return ()))
     | Some _ -> return ())
  | _ -> return ()
;;

let open_waveform session (artifact : Simulation.Artifact.t) =
  match current_project session with
  | None -> return ()
  | Some project ->
    let project_name = Project_id.to_string project.id in
    (* Retain navigation for eight identities without retaining eight parsed traces. Only
       the current viewer owns a model; revisiting another trace re-verifies its bytes
       before restoring its navigation. *)
    Option.iter session.waveform ~f:(fun view ->
      match view.loaded with
      | Ready _ ->
        let saved = Waveform_view.remember view in
        session.waveform_history
        <- saved
           :: List.filter session.waveform_history ~f:(fun previous ->
             not (Waveform_view.same previous ~project:view.project view.artifact))
           |> Fn.flip List.take 8
      | _ -> ());
    let saved =
      List.find session.waveform_history ~f:(fun view ->
        Waveform_view.same view ~project:project_name artifact)
    in
    let previous =
      Option.filter session.waveform ~f:(fun v ->
        Waveform_view.same v ~project:project_name artifact
        &&
        match v.loaded with
        | Ready _ -> true
        | _ -> false)
    in
    session.waveform_generation <- session.waveform_generation + 1;
    let generation = session.waveform_generation in
    let view =
      Option.first_some previous saved
      |> Option.value ~default:(Waveform_view.create ~project:project_name artifact)
    in
    session.waveform <- Some view;
    session.waveform_visible <- true;
    if Option.is_some previous
    then return ()
    else (
      let client = session.client in
      let instance_id = session.hello.instance_id in
      let current () =
        generation = session.waveform_generation
        && session.waveform_visible
        && phys_equal client session.client
        && V1.Daemon_instance_id.equal instance_id session.hello.instance_id
        && Option.value_map (current_project session) ~default:false ~f:(fun p ->
          Project_id.equal p.id project.id)
      in
      let parsed = ref None in
      let%map result =
        match Simulation_export.identity artifact with
        | Error e -> return (Error e)
        | Ok (size, _) when size > Waveform_data.default_limits.max_bytes ->
          return
            (Or_error.error_string
               "Embedded VCD limit: 8 MiB; use export/external viewer")
        | Ok _ when not (String.equal (Simulation_export.suffix artifact) ".vcd") ->
          return
            (Or_error.error_string
               "Embedded viewer supports VCD only; use export/external viewer")
        | Ok _ ->
          Simulation_export.run
            ~artifact
            ~current
            ~viewer:None
            ~fetch:(fun ~offset ~limit ->
              let%map r =
                request session.diagnostics_file (fun () ->
                  Http.Client.simulation
                    client
                    { instance_id
                    ; project = project.id
                    ; operation =
                        Read_artifact_bytes
                          { attempt_id = artifact.attempt_id
                          ; artifact_id = artifact.id
                          ; sha256 = Option.value artifact.sha256 ~default:""
                          ; offset
                          ; limit
                          }
                    })
              in
              match r with
              | Error e -> Or_error.error_string e
              | Ok s ->
                Or_error.of_option
                  s.byte_page
                  ~error:(Error.of_string "Missing simulation byte page"))
            ~publish:(fun _ chunks ->
              In_thread.run (fun () ->
                let open Or_error.Let_syntax in
                let%map data = Waveform_data.parse (String.concat chunks) in
                parsed := Some data;
                "embedded verified VCD"))
            ~launch:(fun ~prog:_ ~args:_ -> return (Ok ()))
      in
      (* A closed/replaced viewer cannot be resurrected by an old request. The view's
         frozen identity never follows the polling Testing selection. *)
      if current ()
      then (
        let result =
          Result.bind result ~f:(fun _ ->
            Or_error.of_option !parsed ~error:(Error.of_string "No parsed waveform"))
        in
        let view = Option.value session.waveform ~default:view in
        let received =
          Waveform_view.receive ~restore_navigation:(Option.is_some saved) view result
        in
        session.waveform <- Some received)
      else if generation = session.waveform_generation && session.waveform_visible
      then
        session.waveform
        <- Some
             (Waveform_view.receive
                (Option.value session.waveform ~default:view)
                (Or_error.error_string
                   "Waveform load invalidated by project/connection change; return and \
                    reopen")))
;;

let waveform_pin_for_artifact session (artifact : Simulation.Artifact.t) =
  Or_error.try_with (fun () ->
    let project = Option.value_exn (current_project session) in
    let project_key, _ = preference_context session in
    let existing =
      Option.bind (active_waveform_runtime session) ~f:(fun (_, rt) ->
        if String.equal rt.pin.project_key project_key
           && String.equal rt.pin.artifact.attempt_id artifact.attempt_id
           && List.exists
                (rt.pin.artifact :: rt.artifacts)
                ~f:(Simulation.Artifact.equal artifact)
        then Some rt.pin.log
        else None)
    in
    let observed =
      Option.bind session.host.registry ~f:(fun registry ->
        List.find_map registry.tiles ~f:(fun tile ->
          if not (Host.simulation_kind tile.kind)
          then None
          else
            Option.bind
              (Simulation_view.detail (Host.simulation session.host tile.id))
              ~f:(fun detail ->
                if String.equal detail.id artifact.attempt_id
                   && List.exists detail.artifacts ~f:(Simulation.Artifact.equal artifact)
                then
                  Some
                    (Waveforms.Job
                       { instance_id = session.hello.instance_id; job = detail.job })
                else None)))
    in
    { Waveforms.project_key
    ; project = project.id
    ; artifact
    ; log =
        Option.first_some existing observed
        |> Option.value
             ~default:
               (Unavailable
                  "No exact observed attempt job was available when this artifact was \
                   pinned")
    })
;;

let open_waveform_workspace session artifact =
  session.waveform_open_generation <- session.waveform_open_generation + 1;
  let generation = session.waveform_open_generation in
  (* Capture provenance before preference I/O or registry creation can yield. *)
  match
    ( waveform_pin_for_artifact session artifact
    , session.host.registry
    , Host.active session.host )
  with
  | Ok pin, Some before, Some active ->
    let client = session.client
    and instance_id = session.hello.instance_id in
    let current () =
      generation = session.waveform_open_generation
      && phys_equal client session.client
      && V1.Daemon_instance_id.equal instance_id session.hello.instance_id
      && Option.equal Workspace.Workspace_id.equal session.host.active (Some active.id)
      && (match Or_error.try_with (fun () -> fst (preference_context session)) with
          | Ok key -> String.equal key pin.project_key
          | Error _ -> false)
      && Option.value_map session.host.registry ~default:false ~f:(fun registry ->
        Workspace.Session_id.equal registry.session_id before.session_id)
    in
    let%bind () = load_waveform_preferences session in
    if not (current ())
    then return ()
    else (
      let%bind () =
        if Option.is_some session.waveform_preferences_pending
        then workspace_request session Get
        else return ()
      in
      if not (current ())
      then return ()
      else (
        let before = Option.value session.host.registry ~default:before in
        let%bind target =
          match Waveforms.find before with
          | Some workspace -> return (Some workspace)
          | None ->
            let%map () =
              mutate_workspace session (Waveforms.create ~window:active.window)
            in
            Option.bind session.host.registry ~f:(fun after ->
              Waveforms.created ~before ~after)
        in
        match target with
        | Some workspace when current () ->
          session.timing_demand <- None;
          session.host <- Host.set_waveform_pin session.host workspace.id pin;
          session.waveform_preferences_failed <- false;
          session.host <- Host.switch session.host workspace.id;
          let has_session =
            Option.value_map session.host.registry ~default:false ~f:(fun registry ->
              List.exists registry.tiles ~f:(fun tile ->
                Workspace.Workspace_id.equal tile.workspace workspace.id
                && String.equal tile.kind (Waveforms.kind Session)))
          in
          if not has_session
          then
            session.host
            <- { session.host with
                 notice =
                   "Session missing: Apply preset: Waveforms, then Layout: Fit tiles to \
                    window (Unzoom if needed); custom layout retained"
               };
          session.waveform_visible <- false;
          session.waveform_generation <- session.waveform_generation + 1;
          reconcile_waveform_workspaces session;
          let%bind () = save_waveform_preferences session in
          refresh_waveforms session
        | _ ->
          session.host
          <- { session.host with
               notice =
                 "Waveforms workspace creation was not acknowledged for the captured \
                  registry; reopen explicitly"
             };
          return ()))
  | Error error, _, _ ->
    session.host <- { session.host with notice = Error.to_string_hum error };
    return ()
  | _ ->
    session.host <- { session.host with notice = "Workspace registry is not ready" };
    return ()
;;

(* One explorer/Timing inspector input step. The key handler and the WB-054 contextual
   palette actions share it, so both reach exactly the same routing. *)
let inspection_step session tile view action =
  let operation =
    let width, height =
      Option.value_map session.last_dimensions ~default:(80, 24) ~f:(fun dimensions ->
        if Option.is_none (Host.timing_pane session.host tile)
        then Host_view.inspection_viewport dimensions
        else (
          let _, _, layout = Host_view.tile_layout session.host dimensions in
          List.find layout ~f:(fun (candidate, _) ->
            Workspace.Tile_id.equal candidate.id tile.id)
          |> Option.value_map ~default:(80, 24) ~f:(fun (_, geometry) ->
            let _, _, _, width, height =
              Host_view.body_geometry
                session.host
                tile
                ~width:geometry.width
                ~height:geometry.height
            in
            width, height)))
    in
    let inspection, operation =
      match Host.timing_pane session.host tile with
      | None -> Inspection_view.input ~width ~height view action
      | Some pane ->
        let local = Host.local session.host tile.id in
        let view, scroll, operation =
          Timing_workspace.input
            ~presentation:(Host.policy session.host tile)
            ~pane
            ~scroll:local.scroll
            ~width
            ~height
            view
            action
        in
        let view =
          Option.value_map session.asic ~default:view ~f:(Inspection_view.reconcile view)
        in
        let operation =
          match action, operation with
          | Inspection_view.Back, _ ->
            session.timing_demand <- None;
            operation
          | _, Some (Asic.Operation.Inspect_detail _ | Inspect_analysis_detail _) ->
            (* Enter is an explicit retry, including after a failed finite demand. *)
            activate_timing_demand session tile view;
            None
          | _ -> operation
        in
        session.host <- Host.set_local session.host tile.id { local with scroll };
        Some view, operation
    in
    let local = Host.local session.host tile.id in
    let inspection_generation =
      Option.value_map inspection ~default:local.inspection_generation ~f:(fun v ->
        v.generation)
    in
    session.host <- Host.set_inspection session.host tile.id inspection;
    drive_timing_demand session;
    if Option.is_none (Host.timing_pane session.host tile)
    then
      session.host
      <- Host.set_local
           session.host
           tile.id
           { (Host.local session.host tile.id) with inspection_generation };
    Option.bind operation ~f:(fun operation ->
      Option.map inspection ~f:(fun view ->
        operation, (tile.id, Inspection_view.capture view operation)))
  in
  Option.value_map
    operation
    ~default:Bonsai_term.Effect.Ignore
    ~f:(fun (operation, inspection_request) ->
      Bonsai_term.Effect.of_deferred_thunk (fun () ->
        asic_request ~inspection_request session operation))
;;

(* Explicit navigation may instantiate the new builtin, never reset an existing layout.
   Capture client/project/session across that acknowledgement before touching local state. *)
(** Wrappers must retain their live validator when lowering to a preparation action.
    Tile-local selection and provider capabilities can change without a registry edit. *)
let resource_tile ?(kind = "resources") session ~current =
  let tile_kind = if String.equal kind "testing" then "simulation-catalog" else kind in
  let client = session.client in
  let instance = session.hello.instance_id in
  let project = Option.map (current_project session) ~f:(fun p -> p.Project.id) in
  match Host.focused session.host with
  | Some tile when String.equal tile.kind tile_kind -> return (Some tile)
  | _ ->
    (match session.host.registry, Host.active session.host with
     | Some initial, Some active ->
       let valid () =
         phys_equal client session.client
         && current ()
         && V1.Daemon_instance_id.equal instance session.hello.instance_id
         && Option.equal
              Project_id.equal
              project
              (Option.map (current_project session) ~f:(fun p -> p.Project.id))
         && Option.exists session.host.registry ~f:(fun s ->
           Workspace.Session_id.equal initial.session_id s.session_id)
         && Option.exists (Host.active session.host) ~f:(fun w ->
           Workspace.Workspace_id.equal w.id active.id)
       in
       let existing registry =
         List.find registry.Workspace.Snapshot.workspaces ~f:(fun w ->
           Workspace.Window_id.equal w.window active.window
           && Option.equal String.equal w.preset (Some kind))
       in
       let%bind () =
         if Option.is_some (existing initial)
         then return ()
         else
           mutate_workspace
             session
             (Instantiate_template
                { window = active.window
                ; template =
                    (Hardcaml_workbench_workspaces.Presets.builtins kind
                     |> Or_error.ok_exn)
                      .template
                })
       in
       if not (valid ())
       then return None
       else (
         match Option.bind session.host.registry ~f:existing with
         | None -> return None
         | Some workspace ->
           let tile =
             Option.bind session.host.registry ~f:(fun registry ->
               List.find registry.tiles ~f:(fun tile ->
                 Workspace.Workspace_id.equal tile.workspace workspace.id
                 && String.equal tile.kind tile_kind
                 && (not tile.hidden)
                 && Option.value_map
                      workspace.zoomed_tile
                      ~default:true
                      ~f:(Workspace.Tile_id.equal tile.id)))
           in
           Option.iter tile ~f:(fun tile ->
             activate_workspace session workspace.id;
             session.host <- { session.host with focus = Some tile.id });
           if Option.is_none tile
           then
             session.host
             <- { session.host with
                  notice =
                    String.capitalize kind
                    ^ " tile hidden/zoomed out; restore it explicitly from the palette"
                };
           return tile)
     | _ -> return None)
;;

let resource_request session tile operation =
  let local = Host.local session.host tile.Workspace.Tile.id in
  let identity = local.identity in
  let view = local.resources in
  let generation = view.generation in
  let resources =
    Resources_view.admit view ~generation ~request_floor:(session.asic_request_id + 1)
  in
  session.host <- Host.set_local session.host tile.id { local with resources };
  let binding =
    Option.bind session.host.registry ~f:(fun s ->
      Result.ok (Workspace.resolve_tile s tile.id))
  in
  asic_request session (Resources operation) ~fresh_receipt:(fun response ->
    let local = Host.local session.host tile.id in
    let binding_current =
      Option.is_some view.explicit
      || Option.equal
           Workspace.View_reference.equal
           binding
           (Option.bind session.host.registry ~f:(fun s ->
              Result.ok (Workspace.resolve_tile s tile.id)))
    in
    if phys_equal identity local.identity
       && binding_current
       && Option.equal Asic_resources.Target.equal view.target local.resources.target
    then
      session.host
      <- Host.set_local
           session.host
           tile.id
           { local with
             resources =
               Resources_view.receipt
                 ~floor:(session.asic_request_id + 1)
                 local.resources
                 ~generation
                 (Result.map response ~f:(fun _ -> ()))
           })
;;

let resource_input session tile input =
  reconcile_synthesis session;
  let local = Host.local session.host tile.Workspace.Tile.id in
  let resources, operation =
    Resources_view.input local.resources ~filter:local.filter ~asic:session.asic input
  in
  session.host <- Host.set_local session.host tile.id { local with resources };
  Option.value_map operation ~default:(return ()) ~f:(resource_request session tile)
;;

let workload_request session tile operation =
  let local = Host.local session.host tile.Workspace.Tile.id in
  let identity = local.identity in
  let generation = local.workloads.generation in
  let workloads =
    Workloads_view.admit
      local.workloads
      ~generation
      ~request_floor:(session.asic_request_id + 1)
  in
  session.host <- Host.set_local session.host tile.id { local with workloads };
  asic_request session (Workloads operation) ~fresh_receipt:(fun response ->
    let local = Host.local session.host tile.id in
    if phys_equal identity local.identity
    then
      session.host
      <- Host.set_local
           session.host
           tile.id
           { local with
             workloads =
               Workloads_view.receipt
                 local.workloads
                 ~generation
                 ~floor:(session.asic_request_id + 1)
                 (Result.map response ~f:(fun _ -> ()))
           })
;;

let workload_input session tile input =
  let workspace = Workspace.Workspace_id.to_string tile.Workspace.Tile.workspace in
  session.navigation_touched
  <- List.dedup_and_sort ~compare:String.compare (workspace :: session.navigation_touched);
  reconcile_synthesis session;
  let local = Host.local session.host tile.Workspace.Tile.id in
  let workloads, operation =
    Workloads_view.input local.workloads ~asic:session.asic ~filter:local.filter input
  in
  session.host <- Host.set_local session.host tile.id { local with workloads };
  Option.value_map operation ~default:(return ()) ~f:(workload_request session tile)
;;

let import_workload session ~current result digest =
  let%bind tile = resource_tile ~kind:"workloads" session ~current in
  match tile with
  | None -> return ()
  | Some tile ->
    let workspace = Workspace.Workspace_id.to_string tile.Workspace.Tile.workspace in
    session.navigation_touched
    <- List.dedup_and_sort
         ~compare:String.compare
         (workspace :: session.navigation_touched);
    let local = Host.local session.host tile.id in
    let workloads, operation =
      Workloads_view.inspect local.workloads result digest ~refresh:false
    in
    session.host <- Host.set_local session.host tile.id { local with workloads };
    Option.value_map operation ~default:(return ()) ~f:(workload_request session tile)
;;

let rec execute_host ?(validate = fun () -> Ok ()) session captured action ~exit =
  let open Bonsai_term in
  let captured_client = session.client in
  let captured_project = Option.map (current_project session) ~f:(fun p -> p.id) in
  let async ?(on_rejected = ignore) f =
    Effect.of_deferred_thunk (fun () ->
      if Host.current session.host captured
         && phys_equal captured_client session.client
         && Option.equal
              Project_id.equal
              captured_project
              (Option.map (current_project session) ~f:(fun p -> p.id))
         && Result.is_ok (validate ())
      then f ()
      else (
        on_rejected ();
        session.host
        <- { session.host with
             notice =
               Option.value
                 (Result.error (validate ()))
                 ~default:"Command target changed before dispatch; reopen palette"
           };
        return ()))
  in
  let launch_fresh ~current ~target ~view (intent : Asic.Fresh.Intent.t) =
    if (not (current ()))
       || Option.is_some session.host.stage_preparation
       || not (Planned_run.fresh_launchable session.host.planned_run intent)
    then (
      session.host
      <- { session.host with
           notice = "Fresh input intent changed or launch unresolved; stage again"
         };
      return ())
    else if view
            && (not intent.elaboration_only)
            && Option.is_some session.view_on_allocation
    then (
      session.host
      <- { session.host with notice = "Another launch-and-view is awaiting allocation" };
      return ())
    else (
      let key = submission_key "fresh-run" in
      if view && not intent.elaboration_only
      then
        Option.iter target ~f:(fun target ->
          session.view_on_allocation <- Some (key, target));
      asic_request session (Launch_fresh { key; intent_id = intent.id }))
  in
  let stage_fresh ~current ~selection ~elaboration_only ~quick ~view =
    let generation = session.host.stage_generation + 1 in
    let target = Host.launch_target session.host in
    session.host
    <- { session.host with
         stage_generation = generation
       ; planned_preparation = false
       ; stage_preparation = Some "Staging fresh source inputs; no processes"
       };
    let instance = session.hello.instance_id in
    let current () =
      current ()
      && generation = session.host.stage_generation
      && phys_equal captured_client session.client
      && V1.Daemon_instance_id.equal instance session.hello.instance_id
      && Option.equal
           Project_id.equal
           captured_project
           (Option.map (current_project session) ~f:(fun p -> p.id))
    in
    fun () ->
      let staged = ref None in
      let%bind () =
        if not (current ())
        then return ()
        else
          asic_request
            ~fresh_receipt:(function
              | Ok s -> staged := s.Asic.Snapshot.fresh_intent
              | Error _ -> ())
            session
            (Stage_fresh { selection; elaboration_only; expected_plan_identity = None })
      in
      let%bind () = if current () then asic_request session Get else return () in
      if not (current ())
      then return ()
      else (
        session.host <- { session.host with stage_preparation = None };
        match !staged with
        | Some intent when Planned_run.fresh_launchable session.host.planned_run intent ->
          session.host
          <- { session.host with
               notice = "Fresh input intent staged; launch runs Elaboration first"
             };
          let%bind () =
            if quick then launch_fresh ~current ~target ~view intent else return ()
          in
          if current () then save_preferences session selection else return ()
        | _ ->
          session.host
          <- { session.host with
               stage_preparation =
                 Some
                   ("Fresh intent unavailable or superseded; stage again: "
                    ^ (Planned_run.model session.host.planned_run).message)
             };
          return ())
  in
  if (not (Host.current session.host captured)) || Result.is_error (validate ())
  then (
    session.host
    <- { session.host with
         notice =
           Option.value
             (Result.error (validate ()))
             ~default:"Command target changed; reopen palette"
       };
    Effect.Ignore)
  else (
    match action with
    | Host.Launch_elaboration_bundle selection ->
      let validate () =
        Result.bind (validate ()) ~f:(fun () ->
          Terminal_presentation.Stage_launch_commands.validate_elaboration
            ~asic:session.asic
            ~remembered:session.remembered_selection
            selection)
      in
      (match validate () with
       | Error notice ->
         session.host <- { session.host with notice };
         Effect.Ignore
       | Ok () -> execute_host ~validate session captured Host.Quick_prepare_project ~exit)
    | Host.Quick_launch_selected (item, run) ->
      let validate () =
        Result.bind (validate ()) ~f:(fun () ->
          Terminal_presentation.Stage_launch_commands.validate_selected
            session.host
            ~asic:session.asic
            ~item
            ~run)
      in
      (match validate () with
       | Error notice ->
         session.host <- { session.host with notice };
         Effect.Ignore
       | Ok () ->
         let action =
           match item with
           | Elaboration_preparation -> Host.Quick_prepare_project
           | Physical_stage stage -> Quick_prepare_stage (stage, run)
           | Timing_analysis _ -> Quick_prepare_endpoint ("timing", run)
         in
         execute_host ~validate session captured action ~exit)
    | Host.Simulation (tile, operation) ->
      (match operation with
       | Observe id ->
         session.host
         <- Host.set_simulation
              session.host
              tile
              (Simulation_view.select (Host.simulation session.host tile) id);
         (match Host.simulation_tile session.host tile with
          | Some tile_info when Host_view.simulation_cursor_pane tile_info.kind ->
            let local = Host.local session.host tile in
            session.host <- Host.set_local session.host tile { local with follow = true }
          | _ -> ())
       | _ -> ());
      async (fun () -> simulation_request session tile operation)
    | Simulation_case (tile, case_id) ->
      let view = Host.simulation session.host tile in
      session.host
      <- (match Host.simulation_tile session.host tile with
          | Some tile_info when Testing_workspace.is_pane tile_info.kind ->
            Host.update_testing session.host tile (fun state ->
              Testing_workspace.select_case state case_id)
          | _ ->
            Host.set_simulation session.host tile { view with case_id = Some case_id });
      Effect.Ignore
    | Simulation_logs tile ->
      let view = Host.simulation session.host tile in
      session.host
      <- Host.set_simulation session.host tile { view with logs = not view.logs };
      Effect.Ignore
    | Testing_accept tile ->
      session.host
      <- Host.update_testing session.host tile (fun state ->
           Testing_workspace.update_catalog state Simulation_catalog.accept);
      Effect.Ignore
    | Testing_launch_unavailable reason ->
      session.host <- { session.host with notice = reason };
      Effect.Ignore
    | Testing_launch (tile, launch) ->
      (match Host.validate_testing_launch session.host tile launch with
       | Error error ->
         session.host <- { session.host with notice = Error.to_string_hum error }
       | Ok () ->
         let { Host.suite; selection; digest } = launch.inputs in
         let form = Simulation_view.Form.create ~selection suite in
         session.host
         <- { session.host with
              palette =
                Some
                  { capture = captured
                  ; commands = []
                  ; query = Simulation_view.Form.query form
                  ; index = 0
                  ; argument =
                      Some
                        (Simulation_selection
                           (tile, digest, submission_key "simulation", form))
                  }
            });
      Effect.Ignore
    | Simulation_form (tile, digest, suite, key) ->
      let form = Simulation_view.Form.create suite in
      session.host
      <- { session.host with
           palette =
             Some
               { capture = captured
               ; commands = []
               ; query = Simulation_view.Form.query form
               ; index = 0
               ; argument = Some (Simulation_selection (tile, digest, key, form))
               }
         };
      Effect.Ignore
    | Simulation_edit (tile, digest, key, form) ->
      session.host
      <- { session.host with
           notice = ""
         ; palette =
             Some
               { capture = captured
               ; commands = []
               ; query = Simulation_view.Form.query form
               ; index = 0
               ; argument = Some (Simulation_selection (tile, digest, key, form))
               }
         };
      Effect.Ignore
    | Simulation_waveform artifact -> async (fun () -> open_waveform session artifact)
    | Simulation_waveform_workspace artifact ->
      async (fun () -> open_waveform_workspace session artifact)
    | Waveform_control (control, artifact) ->
      (match waveform_context session with
       | Some (view, set) when Simulation.Artifact.equal view.artifact artifact ->
         (match control with
          | "values-inline" | "values-stacked" ->
            session.waveform_value_layout
            <- (if String.equal control "values-inline" then Inline else Stacked);
            session.waveform_display_revision <- session.waveform_display_revision + 1;
            (match Or_error.try_with (fun () -> fst (preference_context session)) with
             | Ok key -> session.waveform_display_loaded <- Some key
             | Error _ -> ());
            don't_wait_for (save_waveform_display_preferences session)
          | "back" ->
            session.waveform_visible <- false;
            session.waveform_generation <- session.waveform_generation + 1
          | "refresh" ->
            if session.waveform_visible
            then (
              session.waveform_history
              <- Waveform_view.remember view :: session.waveform_history
                 |> Fn.flip List.take 8;
              session.waveform <- None;
              don't_wait_for (open_waveform session artifact))
            else
              Option.iter (active_waveform_runtime session) ~f:(fun (workspace, rt) ->
                rt.epoch <- ref ();
                rt.loading <- false;
                rt.metadata_busy <- false;
                rt.log_busy <- false;
                rt.view <- Waveform_view.remember rt.view;
                rt.restore_navigation <- true;
                rt.metadata_loaded <- false;
                rt.logs.fetch <- Not_requested;
                refresh_waveform_runtime session workspace rt)
          | _ ->
            let key =
              match control with
              | "toggle" -> Waveform_view.Enter
              | "in" -> Char '+'
              | "out" -> Char '-'
              | "first" -> Char 'g'
              | "last" -> Char 'G'
              | _ -> Char 'i'
            in
            set (Waveform_view.input view key))
       | _ ->
         session.host
         <- { session.host with notice = "Waveform pin changed; reopen palette" });
      Effect.Ignore
    | Simulation_export (artifact, open_viewer) ->
      let tile = Option.map (Host.focused session.host) ~f:(fun t -> t.id) in
      let identity = Option.map tile ~f:(Host.simulation_identity session.host) in
      let owner_current () =
        Option.value_map tile ~default:false ~f:(fun id ->
          Option.equal
            phys_equal
            identity
            (Some (Host.simulation_identity session.host id))
          && Option.equal
               String.equal
               (Host.simulation session.host id).attempt
               (Some artifact.attempt_id))
      in
      let notice message =
        let message =
          Artifact_view.safe
            (sprintf "Simulation %s / %s: %s" artifact.attempt_id artifact.id message)
        in
        if owner_current ()
        then (
          session.host <- { session.host with notice = message };
          Option.iter tile ~f:(fun id ->
            let view = Host.simulation session.host id in
            session.host
            <- Host.set_simulation session.host id { view with notice = Some message }))
      in
      async (fun () ->
        if session.artifact_export_busy
        then (
          notice "Another artifact export is in progress";
          return ())
        else (
          session.artifact_export_busy <- true;
          Monitor.protect
            ~finally:(fun () ->
              session.artifact_export_busy <- false;
              return ())
            (fun () ->
              match current_project session with
              | None -> return ()
              | Some project ->
                let instance_id = session.hello.instance_id in
                let client = session.client in
                let current () =
                  owner_current ()
                  && phys_equal client session.client
                  && V1.Daemon_instance_id.equal instance_id session.hello.instance_id
                  && Option.value_map
                       (current_project session)
                       ~default:false
                       ~f:(fun p -> Project_id.equal p.id project.id)
                in
                let viewer =
                  if open_viewer then session.artifact_binary_viewer else None
                in
                if open_viewer && Option.is_none viewer
                then (
                  notice
                    "Configure --simulation-viewer /absolute/viewer for simulation traces";
                  return ())
                else (
                  notice
                    "Exporting simulation bytes (<=64 MiB); verifying identity and SHA256";
                  let%map result =
                    Simulation_export.run
                      ~artifact
                      ~current
                      ~viewer
                      ~fetch:(fun ~offset ~limit ->
                        let%map r =
                          request session.diagnostics_file (fun () ->
                            Http.Client.simulation
                              client
                              { instance_id
                              ; project = project.id
                              ; operation =
                                  Read_artifact_bytes
                                    { attempt_id = artifact.attempt_id
                                    ; artifact_id = artifact.id
                                    ; sha256 = Option.value artifact.sha256 ~default:""
                                    ; offset
                                    ; limit
                                    }
                              })
                        in
                        match r with
                        | Error e -> Or_error.error_string e
                        | Ok s ->
                          Or_error.of_option
                            s.byte_page
                            ~error:(Error.of_string "Missing simulation byte page"))
                      ~publish:Simulation_export.publish_private
                      ~launch:Artifact_export.launch_viewer
                  in
                  notice
                    (match result with
                     | Ok path -> "Verified simulation bytes retained: " ^ path
                     | Error e -> "Simulation export: " ^ Error.to_string_hum e)))))
    | Host.Registry mutation -> async (fun () -> mutate_workspace session mutation)
    | Restore_default_layout (workspace, definition) ->
      let host, ticket = Host.begin_restore session.host captured in
      let instance_id = session.hello.instance_id in
      session.host <- host;
      async (fun () ->
        if V1.Daemon_instance_id.equal instance_id session.hello.instance_id
        then restore_default_layout session captured ticket workspace definition
        else return ())
    | Restore_default_layout_unavailable -> Effect.Ignore
    | Switch id ->
      activate_workspace session id;
      Effect.Ignore
    | Create_blank_workspace ->
      async (fun () ->
        match session.host.registry, Host.active session.host with
        | Some registry, Some active when Host.current session.host captured ->
          mutate_workspace
            session
            (Host.blank_workspace_mutation registry ~window:active.window)
            ~on_snapshot:(fun snapshot ->
              Option.iter
                (Host.created_workspace ~before:registry ~after:snapshot)
                ~f:(activate_workspace session))
        | _ -> return ())
    | Create_testing_workspace ->
      async (fun () ->
        match session.host.registry, Host.active session.host with
        | Some registry, Some active
          when not
                 (List.exists registry.tiles ~f:(fun tile ->
                    Testing_workspace.is_pane tile.kind)) ->
          let%bind () =
            mutate_workspace
              session
              (Instantiate_template
                 { window = active.window
                 ; template =
                     (Hardcaml_workbench_workspaces.Presets.builtins "testing"
                      |> Or_error.ok_exn)
                       .template
                 })
          in
          (match session.host.registry with
           | Some current
             when Workspace.Session_id.equal current.session_id registry.session_id ->
             (match
                List.find current.workspaces ~f:(fun w ->
                  Option.equal String.equal w.preset (Some "testing")
                  && not
                       (List.exists registry.workspaces ~f:(fun old ->
                          Workspace.Workspace_id.equal old.id w.id)))
              with
              | None -> return ()
              | Some workspace ->
                activate_workspace session workspace.id;
                return ())
           | _ -> return ())
        | _ -> return ())
    | Apply_default_layout ->
      async (fun () ->
        match session.host.registry with
        | None -> return ()
        | Some registry ->
          add_default_tiles
            session
            registry
            (Workspace.workspace registry captured.workspace))
    | Build -> async (fun () -> submit session `Build)
    | Test -> async (fun () -> submit session `Test)
    | Cancel id ->
      async (fun () ->
        let requested_instance = session.hello.instance_id in
        let%map result =
          request session.diagnostics_file (fun () ->
            Http.Client.cancel_job
              session.client
              { instance_id = requested_instance; job = id })
        in
        if V1.Daemon_instance_id.equal requested_instance session.hello.instance_id
        then (
          match result with
          | Error message -> session.host <- { session.host with notice = message }
          | Ok payload ->
            session.snapshot <- State.add_job_if_absent session.snapshot payload.job))
    | Refresh_integration -> async (fun () -> refresh_integration session)
    | Generate_rtl (target, configuration) ->
      (* The captured IDs are revalidated against discovery, never replaced by the
         currently highlighted target or a first-flow fallback. *)
      let valid =
        Option.value_map (current_project session) ~default:false ~f:(fun project ->
          List.exists project.targets ~f:(fun t -> Target_id.equal t.id target)
          && List.exists project.configurations ~f:(fun c ->
            Configuration_id.equal c.id configuration && Target_id.equal c.target target))
      in
      if valid
      then (
        session.selected_target <- Some target;
        session.selected_configuration <- Some configuration;
        async (fun () ->
          match current_project session with
          | None -> return ()
          | Some project ->
            let instance_id = session.hello.instance_id in
            let%map result =
              request session.diagnostics_file (fun () ->
                Http.Client.generate_rtl
                  session.client
                  { instance_id
                  ; project = project.id
                  ; target
                  ; configuration
                  ; submission_key = submission_key "generate-rtl"
                  })
            in
            if V1.Daemon_instance_id.equal instance_id session.hello.instance_id
            then (
              match result with
              | Error message ->
                session.host
                <- { session.host with notice = "RTL generation failed: " ^ message }
              | Ok payload ->
                session.snapshot <- State.add_job_if_absent session.snapshot payload.job;
                session.host
                <- { session.host with
                     notice = "Submitted RTL as " ^ Job_id.to_string payload.job.id
                   })))
      else (
        session.host
        <- { session.host with notice = "Captured RTL target is no longer available" };
        Effect.Ignore)
    | Inspect_artifact -> async (fun () -> inspect_artifact session)
    | Inspect_hierarchy -> async (fun () -> inspect_hierarchy session)
    | Load_hierarchy id -> async (fun () -> load_tile_hierarchy session id)
    | Hierarchy_detail id -> async (fun () -> detail_tile_hierarchy session id)
    | Discover_asic -> async (fun () -> asic_request session Discover)
    | Open_workloads ->
      let intent = ref () in
      session.resource_navigation_intent <- intent;
      async (fun () ->
        let%bind tile =
          resource_tile ~kind:"workloads" session ~current:(fun () ->
            phys_equal intent session.resource_navigation_intent)
        in
        match tile with
        | None -> return ()
        | Some tile ->
          let local = Host.local session.host tile.id in
          (match local.workloads.query with
           | Some query
             when (not (Workloads_view.equal_mode local.workloads.mode Results))
                  && List.exists
                       (Workloads_view.snapshot session.asic).entries
                       ~f:(fun d ->
                         String.equal
                           d.Asic_workloads.Descriptor.key
                           (Workloads_view.key query)
                         && Option.is_some d.digest) ->
             let workloads, op =
               Workloads_view.begin_query local.workloads query ~refresh:false
             in
             session.host <- Host.set_local session.host tile.id { local with workloads };
             workload_request session tile op
           | _ -> return ()))
    | Workload_capture left ->
      session.resource_navigation_intent <- ref ();
      (match Host.focused session.host with
       | Some tile when String.equal tile.kind "workloads" ->
         let local = Host.local session.host tile.id in
         if not (Workloads_view.capture_ready local.workloads)
         then (
           session.host
           <- { session.host with
                notice = "Open the selected result's validated detail before capture"
              };
           Effect.Ignore)
         else (
           match Workloads_view.verified_bundle local.workloads with
           | Some bundle ->
             let workloads = Workloads_view.capture local.workloads ~left ~bundle in
             session.host <- Host.set_local session.host tile.id { local with workloads };
             session.host
             <- { session.host with
                  notice =
                    (if left then "Captured A" else "Captured B")
                    ^ " from verified bundle locator"
                };
             Effect.Ignore
           | None ->
             session.host
             <- { session.host with
                  palette =
                    Some
                      { capture = captured
                      ; commands = []
                      ; query = ""
                      ; index = 0
                      ; argument =
                          Some
                            (Host.Workload_bundle
                               (left, Workloads_view.capture_token local.workloads))
                      }
                ; notice =
                    "Legacy inspection: enter its exact absolute verified bundle \
                     directory"
                };
             Effect.Ignore)
       | _ -> Effect.Ignore)
    | Workload_import ->
      session.resource_navigation_intent <- ref ();
      let argument, notice =
        ( Host.Workload_path
        , "Enter exact absolute retained result.json; reads evidence only" )
      in
      session.host
      <- { session.host with
           palette =
             Some
               { capture = captured
               ; commands = []
               ; query = ""
               ; index = 0
               ; argument = Some argument
               }
         ; notice
         };
      Effect.Ignore
    | Workload_result (result, digest) ->
      let intent = ref () in
      session.resource_navigation_intent <- intent;
      async (fun () ->
        import_workload
          session
          ~current:(fun () -> phys_equal intent session.resource_navigation_intent)
          result
          digest)
    | Workload_input input ->
      (match Host.focused session.host with
       | Some tile when String.equal tile.kind "workloads" ->
         async (fun () -> workload_input session tile input)
       | _ -> Effect.Ignore)
    | Workload_testing ->
      let intent = ref () in
      session.resource_navigation_intent <- intent;
      async (fun () ->
        let%bind tile =
          resource_tile ~kind:"testing" session ~current:(fun () ->
            phys_equal intent session.resource_navigation_intent)
        in
        match tile with
        | None -> return ()
        | Some tile ->
          session.host
          <- { session.host with
               focus = Some tile.id
             ; notice =
                 "Testing: Discover suites; select pt8-memory-workloads, then Launch \
                  selected subset form"
             };
          simulation_request session tile.id Discover)
    | Workload_reference (tile_id, artifact) ->
      let intent = ref () in
      session.resource_navigation_intent <- intent;
      let identity = Host.simulation_identity session.host tile_id in
      let client = session.client
      and instance_id = session.hello.instance_id in
      let project = current_project session in
      let current () =
        phys_equal client session.client
        && phys_equal intent session.resource_navigation_intent
        && Option.equal
             Workspace.Workspace_id.equal
             session.host.active
             (Some captured.workspace)
        && Option.exists session.host.registry ~f:(fun registry ->
          Workspace.Session_id.equal registry.session_id captured.session)
        && V1.Daemon_instance_id.equal instance_id session.hello.instance_id
        && Option.equal
             Project_id.equal
             (Option.map project ~f:(fun p -> p.Project.id))
             (Option.map (current_project session) ~f:(fun p -> p.Project.id))
        && phys_equal identity (Host.simulation_identity session.host tile_id)
        && Option.value_map
             (Host.testing session.host tile_id)
             ~default:false
             ~f:(fun (_, _, state) ->
               Option.equal
                 Simulation.Artifact.equal
                 (Testing_workspace.workload_artifact state)
                 (Some artifact))
      in
      async (fun () ->
        match project, artifact.sha256, artifact.size with
        | Some project, Some sha256, Some size when size > 0 && size <= 16384 ->
          let%bind response =
            request session.diagnostics_file (fun () ->
              Http.Client.simulation
                client
                { instance_id
                ; project = project.id
                ; operation =
                    Read_artifact_bytes
                      { attempt_id = artifact.attempt_id
                      ; artifact_id = artifact.id
                      ; sha256
                      ; offset = 0
                      ; limit = 16384
                      }
                })
          in
          if not (current ())
          then return ()
          else (
            let reference =
              Result.bind response ~f:(fun s ->
                Or_error.try_with (fun () ->
                  let page = Option.value_exn s.Simulation.Snapshot.byte_page in
                  if not
                       (String.equal page.attempt_id artifact.attempt_id
                        && String.equal page.artifact_id artifact.id
                        && String.equal page.sha256 sha256
                        && page.offset = 0
                        && page.total_size = size
                        && page.next_offset = size
                        && page.eof)
                  then failwith "Result reference page identity/span mismatch";
                  let bytes =
                    Cryptokit.transform_string (Cryptokit.Hexa.decode ()) page.bytes_hex
                  in
                  if String.length bytes <> size
                     || not
                          (String.equal
                             (Terminal_presentation.Plain_rpc.digest bytes)
                             sha256)
                  then failwith "Result reference bytes changed";
                  Workloads_view.reference bytes |> Or_error.ok_exn)
                |> Result.map_error ~f:Error.to_string_hum)
            in
            match reference with
            | Error error ->
              session.host
              <- { session.host with notice = "Workload reference: " ^ error };
              return ()
            | Ok (result, digest) -> import_workload session ~current result (Some digest))
        | _ ->
          session.host
          <- { session.host with
               notice = "Workload result reference unavailable or exceeds 16KiB"
             };
          return ())
    | Open_resources ->
      let expected_run =
        Option.bind (Host.focused session.host) ~f:(Host.tile_run session.host)
      in
      let intent = ref () in
      session.resource_navigation_intent <- intent;
      async (fun () ->
        let%bind tile =
          resource_tile session ~current:(fun () ->
            phys_equal intent session.resource_navigation_intent)
        in
        match tile with
        | None -> return ()
        | Some tile ->
          reconcile_synthesis session;
          let local = Host.local session.host tile.id in
          if Option.is_none local.resources.explicit
             && not
                  (Option.equal
                     Run_ref.equal
                     expected_run
                     (Host.tile_run session.host tile))
          then (
            session.host
            <- { session.host with
                 notice =
                   "Resources has a different run/pin; use Resources: Select execution \
                    explicitly"
               };
            return ())
          else (
            match local.resources.target with
            | None ->
              session.host
              <- { session.host with
                   notice =
                     "Resources: select a workflow bundle or import exact retained \
                      evidence (Space c c)"
                 };
              return ()
            | Some target ->
              let resources, operation =
                Resources_view.begin_request
                  local.resources
                  (Load { target; refresh = false })
              in
              session.host <- Host.set_local session.host tile.id { local with resources };
              Option.value_map
                operation
                ~default:(return ())
                ~f:(resource_request session tile)))
    | Resource_target explicit ->
      let intent = ref () in
      session.resource_navigation_intent <- intent;
      async (fun () ->
        let%bind tile =
          resource_tile session ~current:(fun () ->
            phys_equal intent session.resource_navigation_intent)
        in
        match tile with
        | None -> return ()
        | Some tile ->
          let local = Host.local session.host tile.id in
          let resources =
            Resources_view.select_target local.resources explicit
            |> fun view ->
            Resources_view.reconcile
              view
              ~run:(Host.tile_run session.host tile)
              ~filter:local.filter
              session.asic
          in
          session.host <- Host.set_local session.host tile.id { local with resources };
          (match resources.target with
           | None -> return ()
           | Some target ->
             let resources, operation =
               Resources_view.begin_request resources (Load { target; refresh = false })
             in
             session.host <- Host.set_local session.host tile.id { local with resources };
             Option.value_map
               operation
               ~default:(return ())
               ~f:(resource_request session tile)))
    | Resource_import bundle ->
      session.host
      <- { session.host with
           palette =
             Some
               { capture = captured
               ; commands = []
               ; query = ""
               ; index = 0
               ; argument = Some (Host.Resource_path bundle)
               }
         ; notice =
             "Enter exact absolute source directory; import reads retained evidence and \
              creates no run"
         };
      Effect.Ignore
    | Resource_import_path (bundle, path) ->
      if Filename.is_relative path
      then (
        session.host
        <- { session.host with notice = "Resource import requires an absolute directory" };
        Effect.Ignore)
      else
        execute_host
          session
          captured
          (Resource_target (Some (if bundle then Bundle path else Coarse_run path)))
          ~exit
    | Resource_input input ->
      (match Host.focused session.host with
       | Some tile when Resources_view.is_kind tile.kind ->
         async (fun () -> resource_input session tile input)
       | _ -> Effect.Ignore)
    | Prepare_project | Quick_prepare_project ->
      let quick =
        match action with
        | Quick_prepare_project -> true
        | _ -> false
      in
      let captured_selection = session.remembered_selection in
      let selection =
        Terminal_presentation.Preparation_view.selection
          ~remembered:session.remembered_selection
          ~asic:session.asic
      in
      (match
         Terminal_presentation.Preparation_view.stage
           ~snapshot:session.host.preparation
           ~selection
             (* The ASIC preview belongs to its configured executable. Standalone
                preparation builds current source, so even identical selections do not
                establish ownership of that preview's methodology plan. *)
           ~expected_plan_identity:None
       with
       | Error notice ->
         session.host <- { session.host with notice; stage_preparation = Some notice };
         Effect.Ignore
       | Ok _ ->
         let input_validation () =
           Result.bind selection ~f:(fun selection ->
             Terminal_presentation.Stage_launch_commands.validate_elaboration
               ~asic:session.asic
               ~remembered:session.remembered_selection
               selection)
         in
         let current () =
           Host.current session.host captured
           && phys_equal captured_client session.client
           && Option.equal
                Asic.Selection.equal
                captured_selection
                session.remembered_selection
           && Result.is_ok (validate ())
           && Result.is_ok (input_validation ())
         in
         async
           (stage_fresh
              ~current
              ~selection:(Result.ok_or_failwith selection)
              ~elaboration_only:true
              ~quick
              ~view:false))
    | Launch_preparation _ ->
      session.host
      <- { session.host with
           notice = "Legacy preparation input plan; press r to stage a fresh workflow"
         };
      Effect.Ignore
    | Set_quick_launch_view view ->
      session.host <- { session.host with quick_launch_view = view };
      Effect.of_deferred_thunk (fun () -> save_presentation_preferences session)
    | Select_preparation selection ->
      async (fun () ->
        let%map () = save_preferences session selection in
        session.host
        <- { session.host with
             notice =
               "Preparation inputs selected; r stages inputs, Quick launch builds and \
                emits (EDA-less)"
           })
    | Edit_preparation (flow, profile) ->
      let query =
        Option.value_map session.remembered_selection ~default:"" ~f:(fun s ->
          if String.equal flow s.flow && String.equal profile s.profile
          then String.concat ~sep:" " (s.endpoint :: s.assignments)
          else "")
      in
      session.host
      <- { session.host with
           palette =
             Some
               { capture = captured
               ; commands = []
               ; query
               ; index = 0
               ; argument = Some (Host.Preparation_inputs (flow, profile))
               }
         ; notice = "Enter ENDPOINT [name=value ...]; captures preparation inputs only"
         };
      Effect.Ignore
    | Cancel_preparation ->
      (match Planned_run.workflow session.host.planned_run with
       | Some w when Planned_run.workflow_active w ->
         async (fun () -> asic_request session (Cancel_workflow w.id))
       | _ ->
         (match Option.bind session.host.preparation ~f:(fun s -> s.latest) with
          | Some a when Terminal_presentation.Preparation_view.active a ->
            async (fun () -> preparation_request session (Cancel a.id))
          | _ ->
            session.host <- { session.host with notice = "No active preparation" };
            Effect.Ignore))
    | Preparation_artifact ->
      let cursor =
        Option.bind (Host.focused session.host) ~f:(fun tile ->
          (Host.local session.host tile.id).cursor)
      in
      (match
         Terminal_presentation.Preparation_view.selected session.host.preparation cursor
         |> function
         | Some a ->
           Option.bind a.Preparation.Attempt.bundle ~f:(fun b -> List.hd b.artifacts)
         | None ->
           Option.bind (current_generation session) ~f:(fun j -> List.hd j.artifacts)
       with
       | None ->
         session.host
         <- { session.host with notice = "No published bundle artifact for this attempt" };
         Effect.Ignore
       | Some id ->
         session.selected_artifact <- Some id;
         async (fun () -> inspect_artifact session))
    | Preparation_open_artifact id ->
      session.selected_artifact <- Some id;
      async (fun () -> inspect_artifact session)
    | ( Prepare_stage _
      | Prepare_endpoint _
      | Quick_prepare_stage _
      | Quick_prepare_endpoint _
      | Launch_stage_and_view _ ) as preparation ->
      let quick =
        match preparation with
        | Quick_prepare_stage _ | Quick_prepare_endpoint _ | Launch_stage_and_view _ ->
          true
        | _ -> false
      in
      let view =
        match preparation with
        | Launch_stage_and_view _ -> true
        | _ -> session.host.quick_launch_view
      in
      let intent, run =
        match preparation with
        | Prepare_stage (stage, run) | Quick_prepare_stage (stage, run) ->
          (* The checklist may derive Timing's action from the fresh catalog. Such an
             action is not an observation-advertised capability: revalidate the fresh
             endpoint instead of requiring it in the raw observed stage. *)
          let catalog_timing =
            String.equal stage.id "timing"
            && not
                 (List.exists
                    (Terminal_presentation.Overview_tiles.observed_stages
                       ~asic:session.asic
                       ~run)
                    ~f:(fun observed ->
                      String.equal observed.id "timing" && Option.is_some observed.action))
          in
          ( (if catalog_timing
             then Stage_action.Fresh_endpoint "timing"
             else Stage_action.Physical_stage stage)
          , Some run )
        | Prepare_endpoint (endpoint, run) | Quick_prepare_endpoint (endpoint, run) ->
          Stage_action.Fresh_endpoint endpoint, Some run
        | Launch_stage_and_view (intent, run, _) -> intent, run
        | _ -> assert false
      in
      let endpoint = Stage_action.endpoint intent in
      let remembered = session.remembered_selection in
      let named_validation () =
        match preparation with
        | Launch_stage_and_view (_, _, selection) ->
          Terminal_presentation.Stage_launch_commands.validate_named
            ~asic:session.asic
            ~remembered:session.remembered_selection
            ~run
            ~intent
            ~selection
        | _ -> Ok ()
      in
      let observed =
        Option.bind run ~f:(fun run ->
          Option.bind session.asic ~f:(fun snapshot ->
            List.find snapshot.runs ~f:(fun execution -> Run_ref.equal execution.run run)
            |> Option.bind ~f:(fun execution -> execution.selection)))
      in
      let generation = session.host.stage_generation + 1 in
      let instance = session.hello.instance_id in
      let message =
        "Preparing NEW run through "
        ^ endpoint
        ^ "; discovering capabilities if needed; reopen palette when ready"
      in
      session.host
      <- { session.host with
           stage_generation = generation
         ; stage_preparation = Some message
         ; notice = message
         };
      let current () =
        Host.current session.host captured
        && phys_equal captured_client session.client
        && V1.Daemon_instance_id.equal instance session.hello.instance_id
        && Option.equal
             Project_id.equal
             captured_project
             (Option.map (current_project session) ~f:(fun p -> p.id))
        && generation = session.host.stage_generation
        && Option.equal Asic.Selection.equal remembered session.remembered_selection
        && Result.is_ok (named_validation ())
        && Result.is_ok (validate ())
      in
      let fail reason =
        if generation = session.host.stage_generation
        then
          session.host
          <- { session.host with stage_preparation = Some reason; notice = reason }
      in
      async
        ~on_rejected:(fun () -> fail "Stage preparation target changed; press r again")
        (fun () ->
          let missing () =
            Option.value_map session.asic ~default:true ~f:(fun snapshot ->
              let flow =
                match Option.first_some remembered observed with
                | Some selection -> Some selection.Asic.Selection.flow
                | None -> Option.map snapshot.catalog_default ~f:(fun pair -> pair.flow)
              in
              not
                (List.exists snapshot.flows ~f:(fun candidate ->
                   Option.equal String.equal flow (Some candidate.id)
                   && List.mem
                        candidate.fresh_stage_endpoints
                        endpoint
                        ~equal:String.equal)))
          in
          let rec discover remaining =
            if (not (current ())) || remaining = 0
            then return ()
            else if (not (missing ()))
                    && not
                         (Option.exists session.asic ~f:(fun snapshot ->
                            List.exists snapshot.operations ~f:(fun op ->
                              String.equal op.kind "discover" && Plain_rpc.active op)))
            then return ()
            else (
              let%bind () = Clock.after (Time_float.Span.of_ms 100.) in
              if not (current ())
              then return ()
              else (
                let%bind () = asic_request session Get in
                discover (remaining - 1)))
          in
          let%bind () =
            if Option.is_none (Stage_action.advertised_selection intent) && missing ()
            then (
              let%bind () = asic_request session Discover in
              discover 50)
            else return ()
          in
          if not (current ())
          then (
            fail
              (Result.error (named_validation ())
               |> Option.value
                    ~default:
                      "Stage preparation superseded or context changed; press r again");
            return ())
          else (
            match
              Stage_action.resolve_intent
                ~intent
                ~remembered
                ~observed
                ~snapshot:session.asic
            with
            | Error reason ->
              fail ("Stage preparation failed: " ^ reason ^ "; press r to retry");
              return ()
            | Ok selection ->
              (* Resolution authorizes this exact recipe only while its live action or
                 fresh endpoint remains available. Keep this in addition to the selected
                 checklist validator: tile-local cursor changes do not bump the registry. *)
              let resolved_validation () =
                Terminal_presentation.Stage_launch_commands.validate_named
                  ~asic:session.asic
                  ~remembered:session.remembered_selection
                  ~run
                  ~intent
                  ~selection
              in
              (* Source execution and physical chaining belong to the daemon. This
                 terminal phase captures only the authorized current input recipe. *)
              stage_fresh
                ~current:(fun () ->
                  Host.current session.host captured
                  && phys_equal captured_client session.client
                  && Option.equal
                       Asic.Selection.equal
                       remembered
                       session.remembered_selection
                  && Result.is_ok (validate ())
                  && Result.is_ok (resolved_validation ()))
                ~selection
                ~elaboration_only:false
                ~quick
                ~view
                ()))
    | Unavailable_launch ->
      session.host
      <- { session.host with
           notice =
             "Captured launch was unavailable; reopen palette to capture the ready \
              preview"
         };
      Effect.Ignore
    | Asic (Plan selection) ->
      async
        (stage_fresh
           ~current:(fun () ->
             Host.current session.host captured && Result.is_ok (validate ()))
           ~selection
           ~elaboration_only:false
           ~quick:false
           ~view:false)
    | Asic (Cancel key as operation) ->
      async (fun () ->
        if Option.value_map session.asic ~default:false ~f:(fun snapshot ->
             List.exists snapshot.operations ~f:(fun operation ->
               String.equal operation.key key && Asic_intents.cancellable operation))
        then asic_request session operation
        else (
          session.host
          <- { session.host with
               notice = "ASIC operation is no longer active and owned: " ^ key
             };
          return ()))
    | Asic (Finalize { acceptance = Some acceptance; _ } as operation) ->
      session.remembered_acceptance
      <- Sexp.to_string_mach (Asic.Acceptance.sexp_of_t acceptance);
      async (fun () -> asic_request session operation)
    | Asic operation -> async (fun () -> asic_request session operation)
    | Finalize_collect (run, execution_file) ->
      async (fun () ->
        let key = submission_key "finalize" in
        asic_request session (Finalize { key; run; execution_file; acceptance = None }))
    | Browse_artifacts run ->
      (match Host.focused session.host, session.host.registry with
       | Some tile, Some registry ->
         let scope =
           Workspace.resolve_tile registry tile.id
           |> Result.ok
           |> Option.bind ~f:(fun r -> r.run)
         in
         let local = Host.local session.host tile.id in
         let generation = local.artifact_generation + 1 in
         let view =
           Artifact_view.create
             ?scope
             ~generation
             ~viewer_configured:(Option.is_some session.artifact_viewer)
             ~binary_viewer_configured:(Option.is_some session.artifact_binary_viewer)
             run
         in
         let operation = Asic.Operation.List_artifacts run in
         let artifact_request = capture_artifact_request session tile view operation in
         session.host
         <- Host.set_local
              session.host
              tile.id
              { local with
                artifacts = Some view
              ; inspection = None
              ; artifact_generation = generation
              };
         async (fun () -> asic_request ?artifact_request session operation)
       | _ -> Effect.Ignore)
    | Browse_inspection (run, "timing", stage) ->
      async (fun () -> open_timing_workspace session ~run ~stage)
    | Browse_separate_timing run ->
      let stage, analysis =
        Terminal_presentation.Overview_tiles.timing_inspection_target
          ~asic:session.asic
          ~run
      in
      async (fun () -> open_timing_workspace ?analysis ~separate:true session ~run ~stage)
    | Browse_default_timing run ->
      let stage, analysis =
        Terminal_presentation.Overview_tiles.timing_inspection_target
          ~asic:session.asic
          ~run
      in
      async (fun () -> open_timing_workspace ?analysis session ~run ~stage)
    | Browse_analysis (run, target) ->
      async (fun () ->
        open_timing_workspace ~analysis:target session ~run ~stage:target.stage)
    | Inspect_overview_analysis id ->
      let target =
        Option.bind session.host.registry ~f:(fun registry ->
          Workspace.resolve_tile registry id
          |> Result.ok
          |> Option.bind ~f:(fun reference -> reference.run)
          |> Option.bind ~f:(fun run ->
            Terminal_presentation.Overview_tiles.timing_summary ~asic:session.asic ~run
            |> Option.bind ~f:(fun s -> s.Asic.Summary.timing_analysis)
            |> Option.map ~f:(fun a -> run, a.target)))
      in
      (match target with
       | Some (run, target) ->
         async (fun () ->
           open_timing_workspace ~analysis:target session ~run ~stage:target.stage)
       | None ->
         session.host
         <- { session.host with
              notice =
                "Timing analysis unavailable: no authoritative observation; no \
                 replacement selected"
            };
         Effect.Ignore)
    | Browse_inspection (run, domain, stage) ->
      (match Host.focused session.host, session.host.registry with
       | Some tile, Some registry ->
         let scope =
           Workspace.resolve_tile registry tile.id
           |> Result.ok
           |> Option.bind ~f:(fun r -> r.run)
         in
         let local = Host.local session.host tile.id in
         let generation = local.inspection_generation + 1 in
         let view = Inspection_view.create ?scope ~generation ~run ~domain ~stage () in
         session.host
         <- Host.set_local
              session.host
              tile.id
              { local with
                inspection = Some view
              ; inspection_generation = generation
              ; artifacts = None
              };
         let operation = Inspection_view.operation view in
         let inspection_request = tile.id, Inspection_view.capture view operation in
         async (fun () -> asic_request ~inspection_request session operation)
       | _ -> Effect.Ignore)
    | Edit_acceptance (run, execution_file) ->
      let key = submission_key "finalize-accept" in
      session.host
      <- { session.host with
           palette =
             Some
               { capture = captured
               ; commands = []
               ; query = session.remembered_acceptance
               ; index = 0
               ; argument = Some (Host.Acceptance (run, execution_file, key))
               }
         ; notice =
             "Explicit collateral required; Enter finalizes and accepts the captured \
              execution"
         };
      Effect.Ignore
    | Edit_plan (flow, profile) ->
      let query =
        Option.value_map session.remembered_selection ~default:"" ~f:(fun selection ->
          if String.equal selection.flow flow && String.equal selection.profile profile
          then String.concat (selection.endpoint :: selection.assignments) ~sep:" "
          else "")
      in
      session.host
      <- { session.host with
           palette =
             Some
               { capture = captured
               ; commands = []
               ; query
               ; index = 0
               ; argument = Some (Host.Plan_endpoint (flow, profile))
               }
         ; notice =
             "Enter ENDPOINT [name=value ...]; Describe flow lists capabilities. No \
              fallback."
         };
      Effect.Ignore
    | Edit_finalization run ->
      session.host
      <- { session.host with
           palette =
             Some
               { capture = captured
               ; commands = []
               ; query = ""
               ; index = 0
               ; argument = Some (Host.Finalization_attempt run)
               }
         ; notice =
             "Enter the exact returned finalization operation attempt; no reference is \
              guessed"
         };
      Effect.Ignore
    | Launch_asic (preview, view) ->
      async
        (stage_fresh
           ~current:(fun () ->
             Host.current session.host captured && Result.is_ok (validate ()))
           ~selection:preview.selection
           ~elaboration_only:false
           ~quick:true
           ~view)
    | Launch_fresh_intent (intent, view) ->
      let target = Host.launch_target session.host in
      async (fun () ->
        launch_fresh
          ~target
          ~view
          ~current:(fun () ->
            Host.current session.host captured && Result.is_ok (validate ()))
          intent)
    | Set_presentation (id, presentation) ->
      let host, save = Host.set_presentation session.host id presentation in
      session.host <- host;
      session.host
      <- { session.host with
           notice =
             (if save
              then "Presentation override saved; reset inherits defaults"
              else "Presentation override applied for this session")
         };
      if save
      then Effect.of_deferred_thunk (fun () -> save_presentation_preferences session)
      else Effect.Ignore
    | Local_headers | Resume_log ->
      Option.iter session.host.focus ~f:(fun id ->
        let local = Host.local session.host id in
        let local =
          match action with
          | Local_headers ->
            let tile = Option.value_exn (Host.focused session.host) in
            { local with
              presentation =
                { local.presentation with
                  header = Some (not (Host.policy session.host tile).header)
                }
            }
          | _ -> { local with follow = true; scroll = 0 }
        in
        session.host <- Host.set_local session.host id local);
      (match action with
       | Local_headers ->
         Effect.of_deferred_thunk (fun () -> save_presentation_preferences session)
       | _ -> Effect.Ignore)
    | Toggle_chrome ->
      session.host <- { session.host with chrome = not session.host.chrome };
      Effect.of_deferred_thunk (fun () -> save_presentation_preferences session)
    | Toggle_main_hints ->
      let main_hints = not session.host.main_hints in
      session.host
      <- { session.host with
           main_hints
         ; notice =
             (if main_hints
              then "Main window control hints shown"
              else "Main window control hints hidden; Space c h restores")
         };
      Effect.of_deferred_thunk (fun () -> save_presentation_preferences session)
    | Toggle_palette_hints ->
      let palette_hints = not session.host.palette_hints in
      session.host
      <- { session.host with
           palette_hints
         ; notice =
             (if palette_hints
              then "Command palette control hints shown"
              else "Command palette control hints hidden; Space c p restores")
         };
      Effect.of_deferred_thunk (fun () -> save_presentation_preferences session)
    | Set_timing_preload timing_preload ->
      session.host
      <- { session.host with
           timing_preload
         ; notice =
             (if timing_preload
              then "Timing preload: Background index"
              else "Timing preload: Explicit only")
         };
      drive_timing_preload session;
      Effect.of_deferred_thunk (fun () -> save_presentation_preferences session)
    | Set_global_compression value ->
      session.host <- Host.set_global_compression session.host value;
      session.host <- { session.host with notice = Host.compression_hint session.host };
      Effect.of_deferred_thunk (fun () -> save_presentation_preferences session)
    | Set_workspace_compression (workspace, value) ->
      session.host <- Host.set_workspace_compression session.host workspace value;
      session.host <- { session.host with notice = Host.compression_hint session.host };
      Effect.of_deferred_thunk (fun () -> save_presentation_preferences session)
    | Set_appearance appearance ->
      session.host <- Host.set_appearance session.host appearance;
      Effect.of_deferred_thunk (fun () -> save_presentation_preferences session)
    | Set_layout_mode layout_mode ->
      session.host <- Host.set_layout_mode session.host layout_mode;
      Effect.of_deferred_thunk (fun () -> save_presentation_preferences session)
    | Synthesis_mode mode ->
      change_synthesis session (fun _ local ->
        { local with synthesis = Synthesis_view.State.set_mode local.synthesis mode });
      Effect.Ignore
    | Synthesis_sort sort ->
      change_synthesis session (fun _ local ->
        { local with synthesis = Synthesis_view.State.set_sort local.synthesis sort });
      Effect.Ignore
    | Synthesis_cycle_sort ->
      change_synthesis session (fun _ local ->
        { local with synthesis = Synthesis_view.State.cycle_sort local.synthesis });
      Effect.Ignore
    | Synthesis_clear_filter ->
      change_synthesis session (fun _ local -> { local with filter = "" });
      reconcile_synthesis session;
      Effect.Ignore
    | Close_inspector ->
      (match Host.close_inspector session.host with
       | Ok (host, notice) -> session.host <- { host with notice }
       | Error reason -> session.host <- { session.host with notice = reason });
      Effect.Ignore
    | Inspector_input (id, input) ->
      (match Host.focused session.host with
       | Some tile when Workspace.Tile_id.equal tile.id id ->
         (match Host.inspection session.host tile.id with
          | Some view -> inspection_step session tile view input
          | None ->
            session.host <- { session.host with notice = Host.no_inspector };
            Effect.Ignore)
       | _ ->
         session.host
         <- { session.host with notice = "Command target changed; reopen palette" };
         Effect.Ignore)
    | Unavailable reason ->
      session.host <- { session.host with notice = reason };
      Effect.Ignore
    | Exit -> exit ())
;;

let scroll_host session delta =
  reconcile_synthesis session;
  match Host.focused session.host with
  | Some tile when String.equal tile.kind "planned-run" ->
    let local = Host.local session.host tile.id in
    Option.iter session.last_dimensions ~f:(fun dimensions ->
      let _, _, layout = Host_view.tile_layout session.host dimensions in
      Option.iter
        (List.find layout ~f:(fun (t, _) -> Workspace.Tile_id.equal t.id tile.id))
        ~f:(fun (_, geometry) ->
          let _, _, _, width, height =
            Host_view.body_geometry
              session.host
              tile
              ~width:geometry.width
              ~height:geometry.height
          in
          let count =
            Host_view.rows
              (Host.set_local session.host tile.id { local with scroll = 0 })
              (host_data session)
              tile
              ~width
              ~height
            |> List.length
          in
          let bound = Int.max 0 (count - height) in
          let scroll =
            Int64.(max zero (min (of_int bound) (of_int local.scroll + of_int delta)))
            |> Int64.to_int_exn
          in
          session.host <- Host.set_local session.host tile.id { local with scroll }))
  | _ ->
    Option.iter session.last_dimensions ~f:(fun dimensions ->
      session.host
      <- Host_view.scroll_focused session.host (host_data session) dimensions ~delta)
;;

let browse_host session delta =
  let checklist =
    Option.filter (Host.focused session.host) ~f:(fun tile ->
      String.equal tile.kind "stage-checklist")
  in
  (match checklist with
   | Some tile when not (Host.local session.host tile.id).utility_detail ->
     Option.iter session.host.registry ~f:(fun registry ->
       Workspace.resolve_tile registry tile.id
       |> Result.ok
       |> Option.bind ~f:(fun reference -> reference.run)
       |> Option.iter ~f:(fun run ->
         let stages =
           Terminal_presentation.Overview_tiles.checklist_items ~asic:session.asic ~run
         in
         session.host
         <- Host.browse_checklist session.host tile.id ~run ~items:stages ~delta))
   | _ -> scroll_host session delta);
  change_synthesis session (fun tile local ->
    let synthesis =
      match Synthesis_view.State.mode local.synthesis with
      | Details | Metrics | Evidence -> local.synthesis
      | Summary | Cells ->
        Synthesis_view.State.move
          local.synthesis
          ~summary:(synthesis_summary session tile)
          ~filter:local.filter
          ~delta
        |> fun state -> Synthesis_view.State.set_mode state Cells
    in
    { local with synthesis });
  Option.filter (Host.focused session.host) ~f:(fun tile ->
    String.equal tile.kind "run-selector" || Host.job_attempt_kind tile.kind)
  |> Option.iter ~f:(fun tile ->
    let local = Host.local session.host tile.id in
    let values =
      if String.equal tile.kind "run-selector"
      then
        (host_data session).runs
        |> List.filter ~f:(fun (r, label) ->
          String.is_substring
            (String.lowercase (Host_view.run_label r ^ " " ^ label))
            ~substring:(String.lowercase local.filter))
        |> List.map ~f:(fun (run, _) -> Host_view.run_label run)
      else
        project_jobs session
        |> List.filter ~f:(fun job ->
          (not (String.equal tile.kind "project-tests"))
          || (String.equal job.kind.namespace "dune" && String.equal job.kind.name "test"))
        |> List.map ~f:(fun job -> Job_id.to_string job.id)
    in
    let index =
      Option.bind local.cursor ~f:(fun cursor ->
        List.findi values ~f:(fun _ value -> String.equal cursor value)
        |> Option.map ~f:fst)
      |> Option.value ~default:(if delta > 0 then -1 else 1)
    in
    let index = Int.max 0 (Int.min (List.length values - 1) (index + delta)) in
    let cursor = List.nth values index in
    let visible =
      Option.bind session.last_dimensions ~f:(fun dimensions ->
        let _, _, layout = Host_view.tile_layout session.host dimensions in
        List.find layout ~f:(fun (t, _) -> Workspace.Tile_id.equal t.id tile.id)
        |> Option.map ~f:(fun (_, g) ->
          let _, _, _, _, height =
            Host_view.body_geometry session.host tile ~width:g.width ~height:g.height
          in
          if String.equal tile.kind "run-selector"
          then Int.min height (Host.policy session.host tile).run_selector_rows
          else height))
      |> Option.value ~default:(tile.requested_geometry.height - 2)
      |> (fun height ->
           if String.equal tile.kind "run-selector"
           then Int.min height (Host.policy session.host tile).run_selector_rows
           else height)
      |> Int.max 1
    in
    let scroll =
      if String.equal tile.kind "run-selector"
      then
        if index < local.scroll
        then index
        else if index >= local.scroll + visible
        then index - visible + 1
        else local.scroll
      else 0
    in
    session.host <- Host.set_local session.host tile.id { local with cursor; scroll })
;;

let host_handler_regular session event ~exit : unit Bonsai_term.Effect.t option =
  let open Bonsai_term in
  let modal =
    Option.is_some session.host.palette
    || session.host.editing_filter
    || session.host.paste
  in
  let input = Host.decode_event event in
  let workspace_navigation =
    Option.exists (Host.focused session.host) ~f:(fun tile ->
      String.equal tile.kind "workspace-tabs" || String.equal tile.kind "hierarchy")
    && Option.exists input ~f:(function
      | Host.Character ('j' | 'k') | Next | Previous | Enter -> true
      | _ -> false)
  in
  let prefix = session.host.prefix > 0 in
  let captured = Host.capture session.host in
  let host, effect =
    Option.value_map input ~default:(session.host, Host.No_effect) ~f:(fun input ->
      Host.input session.host input ~commands:(host_catalog session))
  in
  session.host <- host;
  if host.editing_filter
  then (
    change_synthesis session (fun _ local ->
      { local with synthesis = Synthesis_view.State.set_mode local.synthesis Cells });
    Option.iter (Host.focused session.host) ~f:(fun tile ->
      if String.equal tile.kind "resources"
      then (
        let local = Host.local session.host tile.id in
        if not (Resources_view.equal_mode local.resources.mode Table)
        then (
          let resources, _ =
            Resources_view.input
              local.resources
              ~filter:local.filter
              ~asic:session.asic
              Show_table
          in
          session.host <- Host.set_local session.host tile.id { local with resources }))));
  reconcile_synthesis session;
  match effect with
  | Host.Execute (capture, action) -> Some (execute_host session capture action ~exit)
  | Host.Activate
    when Option.exists (Host.focused host) ~f:(fun tile ->
           String.equal tile.kind "timing"
           || (String.equal tile.kind "stage-checklist"
               && Option.exists (Host.tile_run host tile) ~f:(fun run ->
                 Host.checklist_cursor
                   (Host.local host tile.id)
                   ~run
                   ~items:
                     (Terminal_presentation.Overview_tiles.checklist_items
                        ~asic:session.asic
                        ~run)
                 |> Option.exists ~f:(function
                   | Timing_analysis _ -> true
                   | Elaboration_preparation -> false
                   | Physical_stage stage -> String.equal stage.id "timing")))) ->
    (match Host.focused host, captured with
     | Some tile, Some capture ->
       Some (execute_host session capture (Inspect_overview_analysis tile.id) ~exit)
     | _ -> Some Effect.Ignore)
  | Host.Activate ->
    Option.iter (Host.focused host) ~f:(fun tile ->
      if List.mem
           [ "preparation"; "stage-checklist"; "live-status"; "planned-run" ]
           tile.kind
           ~equal:String.equal
      then
        session.host
        <- Host.set_local
             session.host
             tile.id
             { (Host.local session.host tile.id) with utility_detail = true; scroll = 0 });
    change_terminal_result session Terminal_result_view.State.inspect;
    change_synthesis session (fun _ local ->
      let mode =
        match Synthesis_view.State.mode local.synthesis with
        | Summary -> Synthesis_view.Mode.Cells
        | Cells -> Details
        | Details -> Details
        | Metrics -> Metrics
        | Evidence -> Evidence
      in
      { local with synthesis = Synthesis_view.State.set_mode local.synthesis mode });
    Option.iter (Host.focused host) ~f:(fun tile ->
      if String.equal tile.kind "run-selector"
      then (
        let local = Host.local host tile.id in
        let run =
          Option.bind session.asic ~f:(fun asic ->
            List.find asic.runs ~f:(fun r ->
              Option.equal String.equal local.cursor (Some (Host_view.run_label r.run))))
        in
        Option.iter run ~f:(fun r ->
          Option.iter (Host.select_run host (Some r.run)) ~f:(fun mutation ->
            don't_wait_for (mutate_workspace session mutation)))));
    Some Effect.Ignore
  | Host.No_effect
    when modal
         || prefix
         || Option.is_some host.palette
         || host.editing_filter
         || host.prefix > 0 -> Some Effect.Ignore
  | Host.No_effect when workspace_navigation -> Some Effect.Ignore
  | Host.No_effect
    when Option.exists (Host.focused session.host) ~f:(fun tile ->
           String.equal tile.kind "preparation")
         && Option.exists input ~f:(function
           | Character ('j' | 'k') | Next | Previous | Enter -> true
           | _ -> false) -> Some Effect.Ignore
  | Host.No_effect
    when Option.exists (Host.focused session.host) ~f:(fun tile ->
           Testing_workspace.is_pane tile.kind)
         && Option.exists input ~f:(function
           | Character ('j' | 'k' | 'n' | 'p' | 'x' | 'a') | Next | Previous -> true
           | _ -> false) -> Some Effect.Ignore
  | Host.No_effect ->
    let dispatch id =
      Option.bind captured ~f:(fun capture ->
        List.find (host_catalog session) ~f:(fun command -> String.equal command.id id)
        |> Option.map ~f:(fun command ->
          execute_host session capture command.action ~exit))
    in
    let dispatch_testing key =
      Host.testing_dispatch session.host key ~commands:(host_catalog session)
      |> Option.map ~f:(fun (capture, action) ->
        execute_host session capture action ~exit)
    in
    (match input with
     | Some (Character (('j' | 'k' | 'n' | 'p' | 'l') as key))
       when Option.value_map (Host.focused session.host) ~default:false ~f:(fun t ->
              String.equal t.kind "simulation") ->
       let tile = Option.value_exn (Host.focused session.host) in
       let local = Host.local session.host tile.id in
       let v = local.simulation in
       let choose values selected delta =
         let index =
           Option.bind selected ~f:(fun id ->
             List.findi values ~f:(fun _ s -> String.equal id s) |> Option.map ~f:fst)
           |> Option.value ~default:(if delta > 0 then -1 else 1)
         in
         List.nth values (Int.max 0 (Int.min (List.length values - 1) (index + delta)))
       in
       if Char.equal key 'j' || Char.equal key 'k'
       then (
         let values =
           Option.value_map v.snapshot ~default:[] ~f:(fun s ->
             List.map s.attempts ~f:(fun a -> a.id))
         in
         match
           choose values v.attempt (if Char.equal key 'j' then 1 else -1), captured
         with
         | Some id, Some capture ->
           Some (execute_host session capture (Simulation (tile.id, Observe id)) ~exit)
         | _ -> Some Effect.Ignore)
       else (
         let simulation =
           if Char.equal key 'l'
           then { v with logs = not v.logs }
           else (
             let values =
               Option.value_map (Simulation_view.detail v) ~default:[] ~f:(fun d ->
                 List.map d.cases ~f:(fun c -> c.case_id))
             in
             { v with
               case_id = choose values v.case_id (if Char.equal key 'n' then 1 else -1)
             })
         in
         session.host
         <- Host.set_local session.host tile.id { local with simulation; scroll = 0 };
         Some Effect.Ignore)
     | Some (Character 'b') -> dispatch "project.build"
     | Some (Character (('d' | 'e') as key))
       when Option.exists (Host.focused session.host) ~f:(fun tile ->
              String.equal tile.kind "timing"
              || (String.equal tile.kind "stage-checklist" && Char.equal key 'd')) ->
       Option.iter (Host.focused session.host) ~f:(fun tile ->
         session.host
         <- Host.set_local
              session.host
              tile.id
              { (Host.local session.host tile.id) with utility_detail = true; scroll = 0 });
       Some Effect.Ignore
     | Some (Character 'r')
       when Option.exists (Host.focused session.host) ~f:(fun tile ->
              String.equal tile.kind "timing") ->
       (match Host.focused session.host, captured with
        | Some tile, Some capture ->
          (match
             session.host.registry
             |> Option.bind ~f:(fun registry ->
               Workspace.resolve_tile registry tile.id
               |> Result.ok
               |> Option.bind ~f:(fun r -> r.run))
           with
           | Some run -> Some (execute_host session capture (Asic (Refresh run)) ~exit)
           | None -> Some Effect.Ignore)
        | _ -> Some Effect.Ignore)
     | Some (Character 'd')
       when Option.exists (Host.focused session.host) ~f:(fun tile ->
              Host.simulation_kind tile.kind) -> dispatch "simulation.discover"
     | Some (Character 'r')
       when Option.exists (Host.focused session.host) ~f:(fun tile ->
              String.equal tile.kind "simulation-catalog") ->
       dispatch "simulation.catalog-launch"
     | Some (Character 'u')
       when Option.exists (Host.focused session.host) ~f:(fun tile ->
              String.equal tile.kind "simulation-catalog") ->
       dispatch "simulation.catalog-accept"
     | Some (Character (('e' | 'v' | 'w' | 'W') as key))
       when Option.exists (Host.focused session.host) ~f:(fun tile ->
              String.equal tile.kind "simulation-artifacts") -> dispatch_testing key
     | Some (Character 'r')
       when Option.exists (Host.focused session.host) ~f:(fun tile ->
              Testing_workspace.is_pane tile.kind) -> dispatch_testing 'r'
     | Some (Character 'f')
       when Option.exists (Host.focused session.host) ~f:(fun tile ->
              Testing_workspace.is_pane tile.kind) -> dispatch_testing 'f'
     | Some (Character 'h')
       when Option.exists (Host.focused session.host) ~f:(fun tile ->
              Host.simulation_kind tile.kind) -> dispatch "simulation.history"
     | Some (Character (('r' | 'R') as key))
       when Option.exists (Host.focused session.host) ~f:(fun t ->
              String.equal t.kind "preparation") ->
       dispatch
         (if Char.equal key 'R' then "preparation.quick-launch" else "preparation.prepare")
     | Some (Character 'x')
       when Option.exists (Host.focused session.host) ~f:(fun t ->
              String.equal t.kind "preparation") -> dispatch "preparation.cancel"
     | Some (Character 'a')
       when Option.exists (Host.focused session.host) ~f:(fun t ->
              String.equal t.kind "preparation") -> dispatch "preparation.artifact"
     | Some (Character 't') -> dispatch "project.test"
     | Some (Character 'i') -> dispatch "project.discover"
     | Some (Character 's') -> dispatch "synthesis.cycle-sort"
     | Some (Character 'e') ->
       (match Host.focused session.host with
        | Some tile when Terminal_result_view.supports tile.kind ->
          change_terminal_result session Terminal_result_view.State.inspect;
          Some Effect.Ignore
        | _ -> dispatch "synthesis.evidence")
     | Some (Character 'm') -> dispatch "synthesis.metrics"
     | Some (Character (('r' | 'R') as key))
       when Option.exists (Host.focused session.host) ~f:(fun tile ->
              String.equal tile.kind "stage-checklist") ->
       let quick = Char.equal key 'R' in
       let selected =
         Option.bind (Host.focused session.host) ~f:(fun tile ->
           Option.bind session.host.registry ~f:(fun registry ->
             Workspace.resolve_tile registry tile.id
             |> Result.ok
             |> Option.bind ~f:(fun reference -> reference.run)
             |> Option.bind ~f:(fun run ->
               let stages =
                 Terminal_presentation.Overview_tiles.checklist_items
                   ~asic:session.asic
                   ~run
               in
               Host.checklist_cursor (Host.local session.host tile.id) ~run ~items:stages
               |> Option.map ~f:(fun stage -> stage, run))))
       in
       (match selected, captured with
        | Some (item, run), Some capture when quick ->
          Some (execute_host session capture (Quick_launch_selected (item, run)) ~exit)
        | Some (Elaboration_preparation, _), Some capture ->
          Some (execute_host session capture Prepare_project ~exit)
        | Some (Physical_stage stage, run), Some capture ->
          session.host
          <- { session.host with
               notice =
                 "Preparing NEW run; when preview ready: Space c c → Launch / Launch and \
                  view"
             };
          Some (execute_host session capture (Prepare_stage (stage, run)) ~exit)
        | Some (Timing_analysis _, run), Some capture ->
          Some (execute_host session capture (Prepare_endpoint ("timing", run)) ~exit)
        | None, _ ->
          session.host
          <- { session.host with notice = "No explicit stage observation selected" };
          Some Effect.Ignore
        | Some _, None ->
          session.host
          <- { session.host with
               notice = "Stage action unavailable: workspace not loaded"
             };
          Some Effect.Ignore)
     | Some Escape ->
       Option.iter (Host.focused session.host) ~f:(fun tile ->
         let local = Host.local session.host tile.id in
         if local.utility_detail
         then
           session.host
           <- Host.set_local
                session.host
                tile.id
                { local with utility_detail = false; scroll = 0 });
       change_terminal_result session Terminal_result_view.State.back;
       change_synthesis session (fun _ local ->
         { local with synthesis = Synthesis_view.State.back local.synthesis });
       Some Effect.Ignore
     | Some (Character 'g') ->
       Option.bind session.selected_configuration ~f:(fun id ->
         dispatch ("rtl." ^ Configuration_id.to_string id))
       |> Option.value ~default:Effect.Ignore
       |> Option.some
     | Some (Character 'h') ->
       Option.iter (Host.focused session.host) ~f:(fun tile ->
         Option.iter (Host.local session.host tile.id).cursor ~f:(fun id ->
           Option.iter
             (List.findi (project_jobs session) ~f:(fun _ job ->
                String.equal (Job_id.to_string job.id) id))
             ~f:(fun (index, _) -> session.selected <- index)));
       dispatch "hierarchy.inspect"
     | Some (Character 'c') ->
       (match Host.focused session.host with
        | None -> Some Effect.Ignore
        | Some tile when not (Host.job_attempt_kind tile.kind) -> Some Effect.Ignore
        | Some tile ->
          Option.bind (Host.local session.host tile.id).cursor ~f:(fun id ->
            dispatch ("job.cancel." ^ id))
          |> Option.value ~default:Effect.Ignore
          |> Option.some)
     | Some (Character 'j') | Some Next ->
       browse_host session 1;
       Some Effect.Ignore
     | Some (Character 'k') | Some Previous ->
       browse_host session (-1);
       Some Effect.Ignore
     | Some (Character ('1' .. '9' as ch)) ->
       let index = Char.to_int ch - Char.to_int '1' in
       Option.bind session.host.registry ~f:(fun s -> List.nth s.workspaces index)
       |> Option.iter ~f:(fun w -> activate_workspace session w.id);
       Some Effect.Ignore
     | Some (Character (('[' | ']') as ch)) ->
       (match Host.focused session.host with
        | Some tile
          when Terminal_result_view.supports tile.kind
               || Host.simulation_kind tile.kind
               || String.equal tile.kind "synthesis"
               || String.equal tile.kind "live-status"
               || String.equal tile.kind "preparation"
               || String.equal tile.kind "planned-run"
               || String.equal tile.kind "stage-checklist" ->
          scroll_host session (if Char.equal ch '[' then -1 else 1)
        | _ ->
          Option.iter session.host.focus ~f:(fun id ->
            let l = Host.local session.host id in
            session.host
            <- Host.set_local
                 session.host
                 id
                 { l with
                   follow = false
                 ; scroll = Int.max 0 (l.scroll + if Char.equal ch '[' then -1 else 1)
                 }));
       Some Effect.Ignore
     | Some (Focus | Focus_previous) -> Some Effect.Ignore
     | _ -> None)
;;

let host_handler_overlays session event ~exit =
  let focused =
    Option.bind (Host.focused session.host) ~f:(fun tile ->
      Option.map (Host.local session.host tile.id).artifacts ~f:(fun view -> tile, view))
  in
  let input = Host.decode_event event in
  let inspection =
    Option.bind (Host.focused session.host) ~f:(fun tile ->
      Option.map (Host.inspection session.host tile.id) ~f:(fun view -> tile, view))
  in
  let bypass =
    Option.is_some session.host.palette
    || session.host.editing_filter
    || session.host.paste
    || session.host.prefix > 0
    ||
    match input with
    | Some (Host.Focus | Focus_previous | Paste_start | Paste_end) -> true
    | Some (Character ' ') ->
      not (Option.exists inspection ~f:(fun (_, view) -> view.editing))
    | _ -> false
  in
  match inspection, focused with
  | Some (tile, view), _ when not bypass ->
    let action =
      if view.editing
      then (
        match input with
        | Some Host.Enter -> Some Inspection_view.Open
        | Some Escape -> Some Back
        | Some Backspace -> Some Backspace
        | Some (Character c) -> Some (Character c)
        | Some (Text text) -> Some (Text text)
        | _ -> None)
      else (
        match event, input with
        | _, Some Host.Enter -> Some Inspection_view.Open
        | _, Some Escape -> Some Back
        | _, Some (Next | Character 'j') -> Some Down
        | _, Some (Previous | Character 'k') -> Some Up
        | _, Some (Character 'n') -> Some Page_down
        | _, Some (Character 'N') -> Some Page_up
        | _, Some (Character '/') -> Some Filter
        | _, Some (Character 's') -> Some Sort
        | _, Some (Character 'c') -> Some (Cycle Corner)
        | _, Some (Character 'g') -> Some (Cycle Group)
        | _, Some (Character 'p') -> Some (Cycle Producer)
        | _, Some (Character 'v') -> Some Near
        | _, Some (Character 't') -> Some Stage
        | _, Some (Character 'r') -> Some Refresh
        | _, Some (Character 'd') -> Some Info
        | Key_press { key = Arrow `Right; mods = [] }, _ -> Some Page_down
        | Key_press { key = Arrow `Left; mods = [] }, _ -> Some Page_up
        | _ -> None)
    in
    Some
      (Option.value_map action ~default:Bonsai_term.Effect.Ignore ~f:(fun action ->
         inspection_step session tile view action))
  | _, Some (tile, view)
    when (not bypass)
         &&
         match input with
         | Some (Character 'b') -> true
         | _ -> false ->
    let reference =
      match view.reading with
      | Some r -> Some r.artifact
      | None -> List.nth view.catalog view.selected
    in
    let selected =
      let open Or_error.Let_syntax in
      let%bind viewer =
        Or_error.of_option
          session.artifact_binary_viewer
          ~error:
            (Error.of_string
               "Binary view disabled; configure --artifact-binary-viewer \
                ABSOLUTE_EXECUTABLE")
      in
      let%bind reference =
        Or_error.of_option
          reference
          ~error:(Error.of_string "Select a known physical file")
      in
      let%bind () =
        if List.exists view.catalog ~f:(Artifact_export.same_reference reference)
        then Ok ()
        else Or_error.error_string "Artifact reference changed"
      in
      let%map () = Artifact_binary_export.eligible reference in
      viewer, reference
    in
    (match selected with
     | Error e ->
       artifact_export_notice session tile.id (Error.to_string_hum e);
       Some Bonsai_term.Effect.Ignore
     | Ok (viewer, reference) ->
       Some
         (Bonsai_term.Effect.of_deferred_thunk (fun () ->
            export_artifact_binary session tile.id ~viewer reference)))
  | _, Some (tile, view)
    when (not bypass)
         &&
         match input with
         | Some (Character 'x') -> true
         | _ -> false ->
    (match Artifact_view.external_reference view ~viewer:session.artifact_viewer with
     | Error error ->
       artifact_export_notice session tile.id (Error.to_string_hum error);
       Some Bonsai_term.Effect.Ignore
     | Ok (viewer, reference) ->
       Some
         (Bonsai_term.Effect.of_deferred_thunk (fun () ->
            export_artifact_text session tile.id ~viewer reference)))
  | _, Some (tile, view) when not bypass ->
    let action =
      match event, input with
      | _, Some Host.Enter -> Some Artifact_view.Open
      | _, Some Escape -> Some Back
      | Key_press { key = Arrow `Right; mods = [] }, _ | _, Some (Character 'n') ->
        Some Next
      | Key_press { key = Arrow `Left; mods = [] }, _ | _, Some (Character 'p') ->
        Some Previous
      | _, Some (Next | Character 'j') -> Some Down
      | _, Some (Previous | Character 'k') -> Some Up
      | _ -> None
    in
    let operation =
      Option.bind action ~f:(fun action ->
        let width, height =
          Option.value_map session.last_dimensions ~default:(80, 24) ~f:(fun dimensions ->
            dimensions.width, dimensions.height)
        in
        let artifacts, operation = Artifact_view.input ~width ~height view action in
        let local = Host.local session.host tile.id in
        let artifact_generation =
          Option.value_map artifacts ~default:local.artifact_generation ~f:(fun view ->
            view.generation)
        in
        session.host
        <- Host.set_local
             session.host
             tile.id
             { local with artifacts; artifact_generation };
        Option.map operation ~f:(fun operation ->
          let artifact_request =
            Option.bind artifacts ~f:(fun view ->
              capture_artifact_request session tile view operation)
          in
          operation, artifact_request))
    in
    Some
      (Option.value_map
         operation
         ~default:Bonsai_term.Effect.Ignore
         ~f:(fun (operation, artifact_request) ->
           Bonsai_term.Effect.of_deferred_thunk (fun () ->
             asic_request ?artifact_request session operation)))
  | _ -> host_handler_regular session event ~exit
;;

let waveform_key event =
  match Waveform_view.edit_key event with
  | Some key -> Some key
  | None ->
    (match event with
     | Bonsai_term.Event.Key_press { key = Arrow `Left; mods = [] } ->
       Some Waveform_view.Left
     | Key_press { key = Arrow `Right; mods = [] } -> Some Waveform_view.Right
     | _ ->
       (match Host.decode_event event with
        | Some (Character c) -> Some (Waveform_view.Char c)
        | Some Enter -> Some Enter
        | Some Escape -> Some Escape
        | Some Backspace -> Some Backspace
        | Some Next -> Some Down
        | Some Previous -> Some Up
        | _ -> None))
;;

let host_handler session event ~exit =
  if Host.is_interrupt event
  then Some (exit ())
  else if session.waveform_visible
          || Option.exists (Host.focused session.host) ~f:(fun t ->
            Waveforms.is_pane t.kind)
  then (
    let context = waveform_context session in
    let editing_text =
      Option.exists context ~f:(fun (view, _) -> Option.is_some view.editing)
    in
    let global =
      Option.is_some session.host.palette
      || session.host.prefix > 0
      || session.host.paste
      || Option.exists (Host.decode_event event) ~f:(function
        | Character ' ' -> not editing_text
        | Focus | Focus_previous | Paste_start | Paste_end -> true
        | _ -> false)
    in
    if global
    then host_handler_regular session event ~exit
    else (
      let key = waveform_key event in
      match context with
      | None -> host_handler_regular session event ~exit
      | Some (view, set) ->
        let modal = Option.is_some view.editing || Option.is_some view.identity_scroll in
        if session.waveform_visible || modal
        then (
          (match key with
           | Some (Escape | Char 'q') when not modal ->
             session.waveform_visible <- false;
             session.waveform_generation <- session.waveform_generation + 1
           | Some key -> set (Waveform_view.input view key)
           | None -> ());
          Some Bonsai_term.Effect.Ignore)
        else (
          match Host.focused session.host, active_waveform_runtime session with
          | Some tile, Some (workspace, rt) ->
            (match Waveforms.pane tile.kind, key with
             | Some Picker, Some (Char ('j' | 'k') | Down | Up) ->
               let delta =
                 match key with
                 | Some (Char 'k' | Up) -> -1
                 | _ -> 1
               in
               rt.picker_index
               <- Int.max
                    0
                    (Int.min (List.length rt.artifacts - 1) (rt.picker_index + delta));
               Some Bonsai_term.Effect.Ignore
             | Some Picker, Some Enter ->
               let current = waveform_current session workspace rt in
               Some
                 (Bonsai_term.Effect.of_deferred_thunk (fun () ->
                    match List.nth rt.artifacts rt.picker_index with
                    | Some artifact
                      when current ()
                           && Option.equal
                                Workspace.Workspace_id.equal
                                session.host.active
                                (Some workspace) ->
                      open_waveform_workspace session artifact
                    | _ -> return ()))
             | Some Logs, Some (Char ('j' | 'k' | 'G') | Down | Up) ->
               let local = Host.local session.host tile.id in
               let delta =
                 match key with
                 | Some (Char 'k' | Up) -> -1
                 | _ -> 1
               in
               session.host
               <- Host.set_local
                    session.host
                    tile.id
                    { local with
                      scroll = Int.max 0 (local.scroll + delta)
                    ; follow =
                        (match key with
                         | Some (Char 'G') -> true
                         | _ -> false)
                    };
               Some Bonsai_term.Effect.Ignore
             | ( Some (Session | Signals | Waves)
               , Some
                   (( Char
                        ( 'j'
                        | 'k'
                        | 'h'
                        | 'l'
                        | '['
                        | ']'
                        | '+'
                        | '='
                        | '-'
                        | ':'
                        | '/'
                        | 'g'
                        | 'G'
                        | 'i'
                        | '{'
                        | '}' )
                    | Up | Down | Left | Right | Enter | Escape ) as key) ) ->
               set (Waveform_view.input view key);
               Some Bonsai_term.Effect.Ignore
             | _ -> host_handler_regular session event ~exit)
          | _ -> host_handler_regular session event ~exit)))
  else (
    reconcile_synthesis session;
    match Host.route_inspection_filter_event session.host event with
    | Filter_interrupt -> Some (exit ())
    | Filter_handled host ->
      session.host <- host;
      Some Bonsai_term.Effect.Ignore
    | Filter_pass -> host_handler_overlays session event ~exit)
;;

let fs0_fixture scenario =
  (* Explicit synthetic data, only reachable from the capture hook. Production startup
     always obtains both registry and runs from their daemon services. *)
  let session = session_of_baseline_fixture (List.hd_exn Baseline_fixture.all) in
  let a = Fs0_fixture.run_a
  and b = Fs0_fixture.run_b in
  session.asic <- Some Fs0_fixture.snapshot;
  let registry =
    Workspace.initial
      ~session_id:(Workspace.Session_id.of_string "explicit-synthetic-fs0")
  in
  let overview = List.hd_exn registry.workspaces
  and timing = List.last_exn registry.workspaces in
  let apply s mutation =
    Workspace.apply
      s
      (Mutate { expected_revision = s.Workspace.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let registry =
    List.fold registry.tiles ~init:registry ~f:(fun s tile ->
      let width, height =
        if Workspace.Workspace_id.equal tile.workspace timing.id then 28, 6 else 32, 8
      in
      apply s (Resize_tile { tile = tile.id; geometry = { x = 0; y = 0; width; height } }))
  in
  let registry =
    List.fold
      [ overview.id, "synthesis", 64, 10
      ; overview.id, "execution", 48, 8
      ; overview.id, "project-tests", 48, 8
      ; overview.id, "logs", 64, 8
      ; overview.id, "navigation", 64, 6
      ; timing.id, "timing", 64, 10
      ; timing.id, "logs", 64, 8
      ]
      ~init:registry
      ~f:(fun s (workspace, kind, width, height) ->
        apply
          s
          (Create_tile { workspace; kind; geometry = { x = 0; y = 0; width; height } }))
  in
  let registry =
    apply
      registry
      (Select_run
         { workspace = overview.id
         ; context = registry.main_context
         ; expected_selection_revision = 0
         ; run = Some a
         })
  in
  let registry =
    if String.equal scenario "independent"
    then apply registry (Make_independent timing.id)
    else registry
  in
  let registry =
    if String.equal scenario "pinned" || String.equal scenario "pinned-synthesis"
    then (
      let registry =
        List.filter registry.tiles ~f:(fun tile ->
          String.equal tile.kind "timing" || String.equal tile.kind "synthesis")
        |> List.fold ~init:registry ~f:(fun registry tile ->
          apply registry (Set_tile_binding { tile = tile.id; binding = Pin_run a }))
      in
      apply
        registry
        (Select_run
           { workspace = overview.id
           ; context = registry.main_context
           ; expected_selection_revision = 1
           ; run = Some b
           }))
    else if String.equal scenario "synthesis-b"
    then
      apply
        registry
        (Select_run
           { workspace = overview.id
           ; context = registry.main_context
           ; expected_selection_revision = 1
           ; run = Some b
           })
    else registry
  in
  session.host <- Host.receive Host.empty registry;
  if String.equal scenario "aesthetic-overview"
  then (
    let registry =
      apply
        registry
        (Create_workspace
           { window = overview.window; name = "Testing"; context = registry.main_context })
    in
    let registry =
      List.fold
        [ "live-status"; "workspace-tabs"; "stage-checklist" ]
        ~init:registry
        ~f:(fun registry kind ->
          apply
            registry
            (Create_tile
               { workspace = overview.id
               ; kind
               ; geometry = { x = 0; y = 0; width = 36; height = 12 }
               }))
    in
    session.host <- Host.receive session.host registry);
  List.iter registry.tiles ~f:(fun tile ->
    if String.equal tile.kind "logs"
       || String.equal tile.kind "project-tests"
       || String.equal tile.kind "execution"
    then
      session.host
      <- Host.set_local
           session.host
           tile.id
           { Host.default_local with
             cursor =
               Option.map (selected_job session) ~f:(fun job -> Job_id.to_string job.id)
           });
  if String.equal scenario "timing"
     || String.equal scenario "independent"
     || String.equal scenario "pinned"
  then session.host <- Host.switch session.host timing.id;
  let focus_kind =
    match scenario with
    | "timing" | "pinned" -> Some "timing"
    | "synthesis-a" | "synthesis-b" | "pinned-synthesis" -> Some "synthesis"
    | "tests" -> Some "project-tests"
    | "logs" -> Some "logs"
    | _ -> None
  in
  Option.iter focus_kind ~f:(fun kind ->
    Option.iter
      (List.find (Host.tiles session.host) ~f:(fun tile -> String.equal tile.kind kind))
      ~f:(fun tile -> session.host <- { session.host with focus = Some tile.id }));
  if String.equal scenario "palette"
  then
    List.iter [ ' '; 'c'; 'c' ] ~f:(fun ch ->
      let host, _ =
        Host.input session.host (Character ch) ~commands:(host_catalog session)
      in
      session.host <- host);
  session.status <- "SYNTHETIC FS0 FIXTURE — no tool evidence";
  session
;;

let capture_fs0_frames ~directory =
  Core_unix.mkdir_p directory;
  List.iter
    [ "overview"
    ; "timing"
    ; "independent"
    ; "pinned"
    ; "palette"
    ; "tests"
    ; "logs"
    ; "synthesis-a"
    ; "synthesis-b"
    ; "pinned-synthesis"
    ]
    ~f:(fun scenario ->
      List.iter
        (capture_dimensions @ [ { Bonsai_term.Dimensions.width = 32; height = 8 } ])
        ~f:(fun dimensions ->
          List.iter
            [ "txt", Notty.Cap.dumb; "ansi", Notty.Cap.ansi ]
            ~f:(fun (extension, cap) ->
              let file =
                sprintf
                  "fs0-%s.%dx%d.%s"
                  scenario
                  dimensions.width
                  dimensions.height
                  extension
              in
              Out_channel.write_all
                (Filename.concat directory file)
                ~data:(render_to_string (fs0_fixture scenario) dimensions ~cap ^ "\n"))))
;;

let capture_appearance_frames ~directory =
  Core_unix.mkdir_p directory;
  List.iter Appearance.Preset.all ~f:(fun preset ->
    List.iter
      [ "aesthetic-overview"; "synthesis-a"; "timing"; "pinned-synthesis"; "palette" ]
      ~f:(fun scenario ->
        List.iter Appearance.Density.all ~f:(fun density ->
          List.iter capture_dimensions ~f:(fun dimensions ->
            List.iter
              [ "txt", Notty.Cap.dumb; "ansi", Notty.Cap.ansi ]
              ~f:(fun (extension, cap) ->
                let session = fs0_fixture scenario in
                session.host
                <- Host.set_appearance
                     session.host
                     { Appearance.default with preset; density; icons = Unicode };
                let name =
                  sprintf
                    "%s-%s-%s.%dx%d.%s"
                    (Appearance.Preset.key preset)
                    (Appearance.Density.key density)
                    scenario
                    dimensions.width
                    dimensions.height
                    extension
                in
                Out_channel.write_all
                  (Filename.concat directory name)
                  ~data:(render_to_string session dimensions ~cap ^ "\n"))))));
  printf "Captured experimental A-E skins (synthetic data) in %s\n%!" directory
;;

let tui session ~exit ~dimensions graph =
  let open Bonsai_term in
  let open Bonsai.Let_syntax in
  (* Session navigation is currently mutable. Give those mutations a reactive invalidation
     edge instead of waiting for the display clock to repaint. The clock below remains for
     time-dependent displays, not input acknowledgement. *)
  let revision, update_revision = Bonsai.state' 0 graph in
  let invalidate update = update (fun revision -> revision + 1) in
  let poll =
    Bonsai.map update_revision ~f:(fun update ->
      Effect.bind
        (Effect.of_deferred_thunk (fun () -> refresh session))
        ~f:(fun () -> invalidate update))
  in
  Bonsai.Clock.every
    ~when_to_start_next_effect:`Wait_period_after_previous_effect_finishes_blocking
    ~trigger_on_activate:true
    (Bonsai.return (Time_ns.Span.of_ms 500.))
    poll
    graph;
  let display =
    Bonsai.map3
      dimensions
      (Bonsai.Clock.approx_now ~tick_every:(Time_ns.Span.of_ms 100.) graph)
      revision
      ~f:(fun (dimensions : Dimensions.t) now revision ->
        let animate =
          (not (Appearance.Icons.equal session.host.appearance.icons None_))
          && Option.is_some session.host.registry
          && Option.is_none session.hierarchy_view
          && Option.is_none session.artifact_view
          && (not session.show_connection_details)
          && dimensions.width >= minimum_width
          && dimensions.height >= minimum_height
        in
        (* Preserve both invalidation tokens through to rendering. With mutable session
           state, unchanged dimensions/gating do not mean an unchanged view. *)
        dimensions, animate, now, revision)
  in
  let animate = Bonsai.map display ~f:(fun (_, animate, _, _) -> animate) in
  (* One native pair for the client. Animation only invalidates the view; provider refresh
     remains exclusively on the independent polling edge above. *)
  let indicator_frames =
    match%sub animate with
    | false -> Bonsai.return None
    | true ->
      let dot = Bonsai_term_spinner.component ~kind:Dot graph in
      let line = Bonsai_term_spinner.component ~kind:Line graph in
      let%arr dot and line in
      Some { Indicator.dot; line }
  in
  let view =
    let%arr dimensions, _, now, _revision = display
    and indicator_frames in
    render ~now ?indicator_frames session dimensions
  in
  let handle (event : Event.t) =
    if Host.is_interrupt event
    then exit ()
    else if Option.is_some session.artifact_view
            && Option.exists (Host.decode_event event) ~f:(function
              | Host.Escape -> true
              | _ -> false)
    then (
      session.artifact_view <- None;
      Effect.Ignore)
    else (
      let hosted =
        if session.waveform_visible
           || (Option.is_some session.host.registry
               && Option.is_none session.hierarchy_view
               && Option.is_none session.artifact_view
               && not session.show_connection_details)
        then host_handler session event ~exit
        else None
      in
      match hosted with
      | Some effect -> effect
      | None ->
        (match event with
         | Key_press { key; mods = [] } when key_is 'q' key -> exit ()
         | Key_press { key; mods = [ Ctrl ] } when key_is 'c' key || key_is 'C' key ->
           exit ()
         | Key_press { key; mods = [] } when key_is 'b' key ->
           Effect.of_deferred_thunk (fun () -> submit session `Build)
         | Key_press { key; mods = [] } when key_is 't' key ->
           Effect.of_deferred_thunk (fun () -> submit session `Test)
         | Key_press { key; mods = [] } when key_is 'c' key ->
           Effect.of_deferred_thunk (fun () -> cancel_selected session)
         | Key_press { key; mods = [] } when key_is 'i' key ->
           Effect.of_deferred_thunk (fun () -> refresh_integration session)
         | Key_press { key; mods = [] } when key_is 'n' key ->
           cycle_target session;
           Effect.Ignore
         | Key_press { key; mods = [] } when key_is 'm' key ->
           cycle_configuration session;
           Effect.Ignore
         | Key_press { key; mods = [] } when key_is 'g' key ->
           Effect.of_deferred_thunk (fun () -> generate_rtl session)
         | Key_press { key; mods = [] } when key_is 'a' key ->
           cycle_artifact session;
           Effect.Ignore
         | Key_press { key; mods = [] } when key_is 'v' key ->
           Effect.of_deferred_thunk (fun () -> inspect_artifact session)
         | Key_press { key; mods = [] } when key_is 'h' key ->
           Effect.of_deferred_thunk (fun () -> inspect_hierarchy session)
         | Key_press { key; mods = [] } when key_is 'u' key ->
           move_hierarchy_selection session (-1);
           Effect.Ignore
         | Key_press { key; mods = [] } when key_is 'o' key ->
           move_hierarchy_selection session 1;
           Effect.Ignore
         | Key_press { key; mods = [] } when key_is 'e' key ->
           toggle_hierarchy_expansion session;
           Effect.Ignore
         | Key_press { key; mods = [] } when key_is 'j' key ->
           let count = List.length (project_jobs session) in
           session.selected <- Int.min (Int.max 0 (count - 1)) (session.selected + 1);
           Effect.Ignore
         | Key_press { key; mods = [] } when key_is 'k' key ->
           session.selected <- Int.max 0 (session.selected - 1);
           Effect.Ignore
         | Key_press { key; mods = [] } when key_is 'd' key ->
           session.show_connection_details <- not session.show_connection_details;
           session.connection_details_scroll <- 0;
           Effect.Ignore
         | Key_press { key; mods = [] } when key_is '[' key ->
           if session.show_connection_details
           then
             session.connection_details_scroll
             <- Int.max 0 (session.connection_details_scroll - 1)
           else
             Option.iter session.hierarchy_view ~f:(fun view ->
               view.pane_scroll <- Int.max 0 (view.pane_scroll - 1));
           Effect.Ignore
         | Key_press { key; mods = [] } when key_is ']' key ->
           if session.show_connection_details
           then session.connection_details_scroll <- session.connection_details_scroll + 1
           else
             Option.iter session.hierarchy_view ~f:(fun view ->
               view.pane_scroll <- view.pane_scroll + 1);
           Effect.Ignore
         | Key_press { key; mods = [] } when key_is 'r' key ->
           Effect.of_deferred_thunk (fun () -> reconnect session)
         | _ -> Effect.Ignore))
  in
  let handler =
    Bonsai.map update_revision ~f:(fun update event ->
      let previous = session.host in
      let effect = handle event in
      let active, focus, selections =
        Host.navigation_input_changes previous session.host
      in
      if active || Option.is_some focus
      then session.navigation_revision <- session.navigation_revision + 1;
      Option.iter focus ~f:(fun id ->
        if not (List.mem session.navigation_focus_touched id ~equal:String.equal)
        then session.navigation_focus_touched <- id :: session.navigation_focus_touched);
      let touched id =
        if not (List.mem session.navigation_touched id ~equal:String.equal)
        then session.navigation_touched <- id :: session.navigation_touched;
        session.host <- Host.cancel_navigation_timing session.host id
      in
      List.iter selections ~f:touched;
      (* Publish local state immediately; publish any deferred response when it completes
         too. Do not await a provider/HTTP read before local feedback. *)
      Effect.Many
        [ invalidate update
        ; Effect.bind effect ~f:(fun () ->
            Effect.bind
              (Effect.of_deferred_thunk (fun () -> save_navigation_preferences session))
              ~f:(fun () -> invalidate update))
        ])
  in
  ~view, ~handler
;;

let print_opened session =
  reconcile_selection session;
  printf "Hardcaml Workbench\n";
  printf "Daemon: %s\n" (Http.Client.endpoint session.client);
  printf "Instance: %s\n" (V1.Daemon_instance_id.to_string session.hello.instance_id);
  List.iter (environment_lines session) ~f:print_endline;
  let jobs = project_jobs session in
  printf "Jobs: %d\n" (List.length jobs);
  List.iter jobs ~f:(fun job ->
    printf
      "Job %s: %s (%s)\n"
      (Job_id.to_string job.id)
      (Job.State.to_string job.state)
      (Job.Kind.to_string job.kind));
  List.iter (integration_lines session) ~f:print_endline;
  List.iter (artifact_lines session) ~f:print_endline;
  List.iter (hierarchy_status_lines session) ~f:print_endline
;;

let print_log_record (record : V1.Read_log.Record.t) =
  let tag =
    match record.stream with
    | V1.Read_log.Stream.Stdout -> "stdout"
    | Stderr -> "stderr"
  in
  let lines = String.split_lines record.data in
  if List.is_empty lines
  then printf "[%s]\n%!" tag
  else List.iter lines ~f:(fun line -> printf "[%s] %s\n%!" tag line)
;;

let wait_for_job session initial_job =
  let rec loop job offset =
    let%bind logs =
      request session.diagnostics_file (fun () ->
        Http.Client.read_log
          session.client
          { instance_id = session.hello.instance_id
          ; job = job.Job.id
          ; offset
          ; max_records = V1.max_log_records
          ; max_bytes = V1.max_log_bytes
          })
    in
    match logs with
    | Error message -> return (Error message)
    | Ok logs ->
      List.iter logs.records ~f:print_log_record;
      let%bind updated = poll_updates session ~timeout_ms:200 in
      (match updated with
       | Error message -> return (Error message)
       | Ok (`Applied | `Resynced | `Stale) ->
         let current =
           List.find session.snapshot.jobs ~f:(fun candidate ->
             Job_id.equal candidate.id job.id)
         in
         (match current with
          | None -> return (Error "submitted job disappeared from daemon snapshot")
          | Some current when Job.is_terminal current && logs.eof -> return (Ok current)
          | Some current ->
            let%bind () = Clock_ns.after (Time_ns.Span.of_ms 200.) in
            loop current logs.next_offset))
  in
  loop initial_job 0
;;

let resolve_selection values selector ~name ~id ~kind =
  match selector with
  | None -> List.hd values |> Result.of_option ~error:(sprintf "no %s is available" kind)
  | Some selector ->
    let matches =
      List.filter values ~f:(fun value ->
        String.equal selector (name value) || String.equal selector (id value))
    in
    (match matches with
     | [ value ] -> Ok value
     | [] -> Error (sprintf "%s %S was not found" kind selector)
     | _ -> Error (sprintf "%s selector %S is ambiguous" kind selector))
;;

let wait_for_discovery_if_needed session =
  match current_project session with
  | Some project when not (List.is_empty project.targets) -> return (Ok ())
  | _ ->
    let discovery =
      project_jobs session
      |> List.find ~f:(fun job ->
        String.equal job.kind.namespace "project-driver"
        && String.equal job.kind.name "describe")
    in
    (match discovery with
     | None -> return (Error "project has no discovered targets")
     | Some job when Job.is_terminal job ->
       return (Error "project discovery did not produce a target")
     | Some job ->
       let%map result = wait_for_job session job in
       Result.bind result ~f:(fun job ->
         if Job.State.equal job.state Complete
         then Ok ()
         else
           Error (sprintf "discovery ended in state %s" (Job.State.to_string job.state))))
;;

let run_plain_generate session ~target_selector ~configuration_selector ~wait =
  let%bind discovered = wait_for_discovery_if_needed session in
  match discovered with
  | Error message -> return (Or_error.error_string message)
  | Ok () ->
    reconcile_selection session;
    (match current_project session with
     | None ->
       return (Or_error.error_string "--action generate-rtl requires --project-root")
     | Some project ->
       (match
          resolve_selection
            project.targets
            target_selector
            ~name:(fun target -> target.Target.name)
            ~id:(fun target -> Target_id.to_string target.id)
            ~kind:"target"
        with
        | Error message -> return (Or_error.error_string message)
        | Ok target ->
          let configurations =
            List.filter project.configurations ~f:(fun configuration ->
              Target_id.equal configuration.target target.id)
          in
          (match
             resolve_selection
               configurations
               configuration_selector
               ~name:(fun configuration -> configuration.Configuration.name)
               ~id:(fun configuration -> Configuration_id.to_string configuration.id)
               ~kind:"configuration"
           with
           | Error message -> return (Or_error.error_string message)
           | Ok configuration ->
             session.selected_target <- Some target.id;
             session.selected_configuration <- Some configuration.id;
             let key = submission_key "generate-rtl" in
             let%bind submitted =
               request session.diagnostics_file (fun () ->
                 Http.Client.generate_rtl
                   session.client
                   { instance_id = session.hello.instance_id
                   ; project = project.id
                   ; target = target.id
                   ; configuration = configuration.id
                   ; submission_key = key
                   })
             in
             (match submitted with
              | Error message -> return (Or_error.error_string message)
              | Ok payload ->
                session.snapshot <- State.add_job_if_absent session.snapshot payload.job;
                printf
                  "Submitted RTL job %s for target %s / configuration %s\n%!"
                  (Job_id.to_string payload.job.id)
                  target.name
                  configuration.name;
                if not wait
                then return (Ok ())
                else (
                  let%map finished = wait_for_job session payload.job in
                  match finished with
                  | Error message -> Or_error.error_string message
                  | Ok job when not (Job.State.equal job.state Complete) ->
                    Or_error.error_string
                      (sprintf "job ended in state %s" (Job.State.to_string job.state))
                  | Ok job ->
                    printf "Job %s: Complete\n" (Job_id.to_string job.id);
                    List.iter job.artifacts ~f:(fun id ->
                      match
                        List.find session.snapshot.artifacts ~f:(fun artifact ->
                          Artifact_id.equal artifact.id id)
                      with
                      | None ->
                        printf
                          "Artifact %s: metadata unavailable\n"
                          (Artifact_id.to_string id)
                      | Some artifact ->
                        printf
                          "Artifact %s: %s (%s, %s bytes)\n"
                          (Artifact_id.to_string artifact.id)
                          artifact.metadata.display_name
                          (Artifact.Kind.to_string artifact.kind)
                          (Option.value_map
                             artifact.metadata.size_in_bytes
                             ~default:"unknown"
                             ~f:Int.to_string));
                    Ok ())))))
;;

let run_plain_artifact session artifact_id =
  let artifact = Artifact_id.of_string artifact_id in
  let rec read offset =
    let%bind page =
      request session.diagnostics_file (fun () ->
        Http.Client.read_artifact
          session.client
          { instance_id = session.hello.instance_id
          ; artifact
          ; offset
          ; max_bytes = V1.max_artifact_bytes
          })
    in
    match page with
    | Error message -> return (Or_error.error_string message)
    | Ok page ->
      Out_channel.output_string stdout page.data;
      Out_channel.flush stdout;
      if page.eof then return (Ok ()) else read page.next_offset
  in
  read 0
;;

let run_plain_hierarchy session artifact_id =
  let artifact = Artifact_id.of_string artifact_id in
  let%map response =
    request session.diagnostics_file (fun () ->
      Http.Client.read_hierarchy
        session.client
        { instance_id = session.hello.instance_id; artifact })
  in
  match response with
  | Error message -> Or_error.error_string message
  | Ok payload ->
    let hierarchy = payload.hierarchy in
    let nodes, children = index_hierarchy hierarchy in
    printf "Hierarchy artifact: %s\n" (Artifact_id.to_string hierarchy.artifact);
    printf "Generating job: %s\n" (Job_id.to_string hierarchy.generating_job);
    printf "Target: %s\n" (Target_id.to_string hierarchy.target);
    printf "Configuration: %s\n" (Configuration_id.to_string hierarchy.configuration);
    let rec print_node depth key =
      match Hashtbl.find nodes key with
      | None -> ()
      | Some node ->
        printf
          "%s%s : %s [%s]\n"
          (String.make (depth * 2) ' ')
          (Option.value node.instance_name ~default:"<root>")
          node.circuit_name
          node.key;
        hierarchy_children children key
        |> List.iter ~f:(fun child -> print_node (depth + 1) child.key)
    in
    print_node 0 hierarchy.root;
    Ok ()
;;

let run_plain_action session action ~wait =
  match session.opened with
  | None -> return (Or_error.error_string "--action requires --project-root")
  | Some opened ->
    let name, protocol_action =
      match action with
      | `Build -> "build", V1.Dune_action.Build
      | `Test -> "test", V1.Dune_action.Test
    in
    let key = submission_key name in
    let%bind submitted =
      request session.diagnostics_file (fun () ->
        Http.Client.submit_job
          session.client
          { instance_id = session.hello.instance_id
          ; project = opened.project.id
          ; action = protocol_action
          ; submission_key = key
          })
    in
    (match submitted with
     | Error message -> return (Or_error.error_string message)
     | Ok payload ->
       session.snapshot <- State.add_job_if_absent session.snapshot payload.job;
       printf
         "Submitted %s job %s (submission-key=%s)\n%!"
         name
         (Job_id.to_string payload.job.id)
         key;
       if not wait
       then return (Ok ())
       else (
         let%map finished = wait_for_job session payload.job in
         match finished with
         | Error message -> Or_error.error_string message
         | Ok job ->
           printf
             "Job %s: %s\n%!"
             (Job_id.to_string job.id)
             (Job.State.to_string job.state);
           if Job.State.equal job.state Complete
           then Ok ()
           else
             Or_error.error_string
               (sprintf "job ended in state %s" (Job.State.to_string job.state))))
;;

let run_plain_refresh session ~wait =
  match current_project session with
  | None -> return (Or_error.error_string "--refresh-integration requires --project-root")
  | Some project ->
    let%bind refreshed =
      request session.diagnostics_file (fun () ->
        Http.Client.refresh_integration
          session.client
          { instance_id = session.hello.instance_id; project = project.id })
    in
    (match refreshed with
     | Error message -> return (Or_error.error_string message)
     | Ok { job = None } ->
       let%map result = resync session ~instance_id:session.hello.instance_id in
       (match result with
        | Error message -> Or_error.error_string message
        | Ok () ->
          printf "Integration manifest reloaded (no driver declared)\n%!";
          List.iter (integration_lines session) ~f:print_endline;
          Ok ())
     | Ok { job = Some job } ->
       session.snapshot <- State.add_job_if_absent session.snapshot job;
       printf "Submitted integration refresh job %s\n%!" (Job_id.to_string job.id);
       if not wait
       then return (Ok ())
       else (
         let%map finished = wait_for_job session job in
         match finished with
         | Error message -> Or_error.error_string message
         | Ok job ->
           printf
             "Job %s: %s\n%!"
             (Job_id.to_string job.id)
             (Job.State.to_string job.state);
           List.iter (integration_lines session) ~f:print_endline;
           if Job.State.equal job.state Complete
           then Ok ()
           else
             Or_error.error_string
               (sprintf "job ended in state %s" (Job.State.to_string job.state))))
;;

let parse_environment value =
  match value with
  | "inherited" ->
    Ok (V1.Environment_selection.Inherit_daemon, "inherited (daemon environment)")
  | value ->
    (match String.chop_prefix value ~prefix:"opam:" with
     | Some switch when not (String.is_empty switch) ->
       Ok (V1.Environment_selection.Opam_switch switch, "opam switch " ^ switch)
     | _ -> Or_error.error_string "--environment must be inherited or opam:SWITCH")
;;

let parse_action = function
  | None -> Ok None
  | Some "build" -> Ok (Some `Build)
  | Some "test" -> Ok (Some `Test)
  | Some "generate-rtl" -> Ok (Some `Generate_rtl)
  | Some _ -> Or_error.error_string "--action must be build, test, or generate-rtl"
;;

let run_legacy
  ~endpoint
  ~workspace_config
  ~project_root
  ~environment
  ~plain
  ~action
  ~target
  ~configuration
  ~artifact
  ~hierarchy
  ~refresh_integration:refresh_requested
  ~wait
  ~diagnostics_file
  ~artifact_viewer
  ~artifact_binary_viewer
  ()
  =
  let diagnostics_file =
    Option.first_some diagnostics_file (Sys.getenv "HARDCAML_WORKBENCH_DIAGNOSTICS")
  in
  match parse_environment environment, parse_action action with
  | Error error, _ | _, Error error -> return (Error error)
  | Ok (environment_selection, environment_label), Ok action ->
    if (Option.is_some action
        || Option.is_some artifact
        || Option.is_some hierarchy
        || refresh_requested)
       && not plain
    then
      return
        (Or_error.error_string
           "--action, --artifact, --hierarchy, and --refresh-integration are available \
            only with --plain")
    else if List.count
              [ Option.is_some action
              ; Option.is_some artifact
              ; Option.is_some hierarchy
              ; refresh_requested
              ]
              ~f:Fn.id
            > 1
    then
      return
        (Or_error.error_string
           "choose one of --action, --artifact, --hierarchy, or --refresh-integration")
    else if wait && Option.is_none action && not refresh_requested
    then
      return (Or_error.error_string "--wait requires --action or --refresh-integration")
    else if (Option.is_some action || refresh_requested) && Option.is_none project_root
    then
      return
        (Or_error.error_string
           "--action and --refresh-integration require --project-root")
    else if (Option.is_some target || Option.is_some configuration)
            && not (Option.equal Poly.equal action (Some `Generate_rtl))
    then
      return
        (Or_error.error_string "--target/--configuration require --action generate-rtl")
    else (
      let%bind created =
        create_session
          ~endpoint
          ~project_root
          ~environment_selection
          ~environment_label
          ~diagnostics_file
      in
      match created with
      | Error message -> return (Or_error.error_string message)
      | Ok session ->
        session.workspace_config <- workspace_config;
        session.artifact_viewer <- artifact_viewer;
        session.artifact_binary_viewer <- artifact_binary_viewer;
        reconcile_selection session;
        let%bind () =
          if Option.is_some workspace_config
          then (
            let%bind () = workspace_request session Get in
            initialize_host_layout session)
          else return ()
        in
        if plain || not (Core_unix.isatty Core_unix.stdout)
        then (
          print_opened session;
          match action, artifact, hierarchy, refresh_requested with
          | None, None, None, false -> return (Ok ())
          | Some ((`Build | `Test) as action), None, None, false ->
            run_plain_action session action ~wait
          | Some `Generate_rtl, None, None, false ->
            run_plain_generate
              session
              ~target_selector:target
              ~configuration_selector:configuration
              ~wait
          | None, Some artifact, None, false -> run_plain_artifact session artifact
          | None, None, Some hierarchy, false -> run_plain_hierarchy session hierarchy
          | None, None, None, true -> run_plain_refresh session ~wait
          | _ -> assert false)
        else
          Monitor.try_with_or_error (fun () ->
            let%bind result =
              Bonsai_term.start_with_exit
                ~dispose:true
                ~mouse:No_mouse_events
                (tui session)
            in
            let%map () = session.preference_saves in
            result)
          >>| Or_error.join
          >>| Result.map_error ~f:(fun error ->
            append_diagnostic diagnostics_file ("terminal error: " ^ error_message error);
            error))
;;

type plain_operation =
  | Asic_operation of Asic.Operation.t
  | Workspace_operation of Workspace.Operation.t

let rpc_call session thunk =
  Monitor.try_with_or_error thunk
  >>| Or_error.join
  >>| function
  | Ok response -> response
  | Error error ->
    let message = "Terminal transport failure: " ^ Error.to_string_hum error in
    append_diagnostic session.diagnostics_file message;
    Error (V1.Error.create Internal_failure message)
;;

let run_plain_asic session operation ~wait ~timeout_seconds =
  let project = (Option.value_exn session.opened).project.id in
  let instance_id = session.hello.instance_id in
  let call operation =
    rpc_call session (fun () ->
      Http.Client.asic session.client { instance_id; project; operation })
  in
  let last = ref None in
  let finish response failure = Asic.Response.sexp_of_t response, failure in
  let rec poll keys response =
    match response with
    | Error error -> return (finish response (Some (protocol_error error)))
    | Ok snapshot ->
      last := Some snapshot;
      let keys = Plain_rpc.watched_keys operation keys snapshot in
      (match Plain_rpc.progress ~wait keys snapshot with
       | Failed message -> return (finish response (Some message))
       | Complete ->
         let failure =
           match operation with
           | Asic.Operation.Plan selection when wait ->
             if Option.value_map snapshot.preview ~default:false ~f:(fun preview ->
                  Asic.Selection.equal preview.selection selection)
             then None
             else
               Some
                 "Requested ASIC plan completed but its preview is absent or superseded"
           | _ -> None
         in
         return (finish response failure)
       | Pending ->
         let%bind () = Clock.after (Time_float.Span.of_ms 200.) in
         let%bind response = call Get in
         poll keys response)
  in
  let perform () =
    let%bind response = call operation in
    let keys =
      Result.ok response |> Option.value_map ~default:[] ~f:(Plain_rpc.keys operation)
    in
    poll keys response
  in
  if not wait
  then perform ()
  else (
    match%map
      Clock.with_timeout (Time_float.Span.of_sec timeout_seconds) (perform ())
    with
    | `Result result -> result
    | `Timeout ->
      let message =
        sprintf
          "ASIC operation wait timed out after %g seconds; daemon work was not cancelled"
          timeout_seconds
      in
      let response =
        Option.value_map
          !last
          ~default:(Error (V1.Error.create Internal_failure message))
          ~f:(fun snapshot -> Ok snapshot)
      in
      finish response (Some message))
;;

let run_plain_workspace session operation =
  let project = (Option.value_exn session.opened).project.id in
  let%map response =
    rpc_call session (fun () ->
      Http.Client.workspace
        session.client
        { instance_id = session.hello.instance_id; project; operation })
  in
  ( Workspace.Response.sexp_of_t response
  , match response with
    | Ok _ -> None
    | Error error -> Some (protocol_error error) )
;;

let run
  ~endpoint
  ~workspace_config
  ~project_root
  ~environment
  ~plain
  ~api
  ~asic_operation
  ~workspace_operation
  ~wait_timeout_seconds
  ~action
  ~target
  ~configuration
  ~artifact
  ~hierarchy
  ~refresh_integration
  ~wait
  ~diagnostics_file
  ~artifact_viewer
  ~artifact_binary_viewer
  ()
  =
  let fail message =
    if api
    then
      printf
        "%s\n%!"
        (Sexp.to_string_mach
           (Workspace.Response.sexp_of_t
              (Error (V1.Error.create Invalid_request message))));
    return (Or_error.error_string message)
  in
  let has_operation =
    Option.is_some asic_operation || Option.is_some workspace_operation
  in
  if Option.is_some workspace_config && Option.is_none project_root
  then fail "--workspace-config requires --project-root or --discover-project"
  else if not has_operation
  then
    if api
    then fail "--api requires --asic-operation or --workspace-operation"
    else if Option.is_some wait_timeout_seconds
    then fail "--wait-timeout-seconds requires an ASIC operation and --wait"
    else
      run_legacy
        ~endpoint
        ~workspace_config
        ~project_root
        ~environment
        ~plain
        ~action
        ~target
        ~configuration
        ~artifact
        ~hierarchy
        ~refresh_integration
        ~wait
        ~diagnostics_file
        ~artifact_viewer
        ~artifact_binary_viewer
        ()
  else if Option.is_some workspace_config
  then fail "--workspace-config is a startup option; omit typed operations"
  else if List.count
            [ Option.is_some asic_operation
            ; Option.is_some workspace_operation
            ; Option.is_some action
            ; Option.is_some artifact
            ; Option.is_some hierarchy
            ; refresh_integration
            ]
            ~f:Fn.id
          <> 1
  then
    fail
      "Choose exactly one operation: --asic-operation, --workspace-operation, --action, \
       --artifact, --hierarchy, or --refresh-integration"
  else if not (plain || api)
  then fail "Typed operations require --plain or --api"
  else if Option.is_none project_root
  then fail "Typed operations require --project-root"
  else if Option.is_some target || Option.is_some configuration
  then fail "--target/--configuration apply only to --action generate-rtl"
  else if Option.is_some workspace_operation && wait
  then fail "Workspace operations are synchronous; omit --wait"
  else if Option.is_some wait_timeout_seconds
          && ((not wait) || Option.is_none asic_operation)
  then fail "--wait-timeout-seconds requires an ASIC operation and --wait"
  else (
    let timeout_seconds = Option.value wait_timeout_seconds ~default:60. in
    if not (Float.is_finite timeout_seconds && Float.(timeout_seconds > 0.))
    then fail "Wait timeout must be a finite positive number of seconds"
    else (
      let decoded =
        Or_error.try_with (fun () ->
          match asic_operation, workspace_operation with
          | Some sexp, None ->
            Asic_operation (Asic.Operation.t_of_sexp (Sexp.of_string sexp))
          | None, Some sexp ->
            Workspace_operation (Workspace.Operation.t_of_sexp (Sexp.of_string sexp))
          | _ -> assert false)
      in
      match decoded, parse_environment environment with
      | Error error, _ | _, Error error -> fail (Error.to_string_hum error)
      | Ok operation, Ok (environment_selection, environment_label) ->
        let diagnostics_file =
          Option.first_some diagnostics_file (Sys.getenv "HARDCAML_WORKBENCH_DIAGNOSTICS")
        in
        let%bind created =
          create_session
            ~endpoint
            ~project_root
            ~environment_selection
            ~environment_label
            ~diagnostics_file
        in
        (match created with
         | Error message ->
           if api
           then
             printf
               "%s\n%!"
               (Sexp.to_string_mach
                  (Workspace.Response.sexp_of_t
                     (Error (V1.Error.create Internal_failure message))));
           return (Or_error.error_string message)
         | Ok session ->
           if not api then print_opened session;
           let%map sexp, failure =
             match operation with
             | Asic_operation operation ->
               run_plain_asic session operation ~wait ~timeout_seconds
             | Workspace_operation operation -> run_plain_workspace session operation
           in
           printf "%s\n%!" (Sexp.to_string_mach sexp);
           (match failure with
            | None -> Ok ()
            | Some message -> Or_error.error_string message))))
;;

let command =
  Command.async_or_error
    ~summary:"Connect to Hardcaml Workbench"
    (let%map_open.Command endpoint =
       flag "--connect" (optional string) ~doc:"URL attach without automatic startup"
     and project_root =
       flag "--project-root" (optional string) ~doc:"ROOT open a Dune project"
     and workspace_config =
       flag
         "--workspace-config"
         (optional
            (Command.Arg_type.create (fun path ->
               let text =
                 In_channel.with_file path ~f:(fun channel ->
                   let buffer = Buffer.create 4096 in
                   match
                     In_channel.input_buffer
                       channel
                       buffer
                       ~len:(Workspace_config.max_encoded_bytes + 1)
                   with
                   | Some () -> failwith "Workspace configuration exceeds 4 MiB"
                   | None -> Buffer.contents buffer)
               in
               let module P = Hardcaml_workbench_workspaces.Presets in
               let config =
                 P.decode text |> Or_error.bind ~f:P.resolve |> Or_error.ok_exn
               in
               Workspace_config.Resolved.encode config |> Or_error.ok_exn |> ignore;
               config)))
         ~doc:"FILE read a workspace spec on this client; initialize fresh sessions once"
     and discover_project =
       flag
         "--discover-project"
         no_arg
         ~doc:
           " open the nearest ancestor of the current directory (symlinks resolved \
            first) containing a regular dune-project; reports the root; not with \
            --project-root"
     and environment =
       flag
         "--environment"
         (optional_with_default "inherited" string)
         ~doc:"inherited|opam:SWITCH project command environment (default: inherited)"
     and plain = flag "--plain" no_arg ~doc:" print status without terminal control"
     and timing_neighbors =
       flag
         "--timing-prefetch-neighbors"
         (optional_with_default
            2
            (Command.Arg_type.create (fun value ->
               let n = Int.of_string value in
               if n < 0 || n > 2 then failwith "expected 0..2";
               n)))
         ~doc:
           "0..2 speculative Timing neighbors (default 2; 0 keeps selected detail demand)"
     and timing_preload =
       flag
         "--timing-preload"
         (optional
            (Command.Arg_type.create (function
              | "background-index" -> true
              | "explicit-only" -> false
              | _ -> failwith "expected background-index|explicit-only")))
         ~doc:
           "background-index|explicit-only initial project policy override (saved \
            preference otherwise; palette changes persist)"
     and api =
       flag
         "--api"
         no_arg
         ~doc:" emit exactly one typed RPC response sexp; no status preamble"
     and asic_operation =
       flag
         "--asic-operation"
         (optional string)
         ~doc:"SEXP typed Asic.Operation; requires --project-root and --plain or --api"
     and workspace_operation =
       flag
         "--workspace-operation"
         (optional string)
         ~doc:
           "SEXP typed Workspace.Operation; requires --project-root and --plain or --api"
     and wait_timeout_seconds =
       flag
         "--wait-timeout-seconds"
         (optional float)
         ~doc:
           "SECONDS bounded ASIC --wait budget (default 60); does not cancel daemon work"
     and action =
       flag
         "--action"
         (optional string)
         ~doc:"build|test|generate-rtl submit one action in plain mode"
     and target = flag "--target" (optional string) ~doc:"NAME|ID target for generate-rtl"
     and configuration =
       flag
         "--configuration"
         (optional string)
         ~doc:"NAME|ID configuration for generate-rtl"
     and artifact =
       flag
         "--artifact"
         (optional string)
         ~doc:"ID retrieve artifact content in plain mode"
     and artifact_viewer =
       flag
         "--artifact-viewer"
         (optional
            (Command.Arg_type.create (fun path ->
               Artifact_export.executable path |> Or_error.ok_exn)))
         ~doc:
           "ABSOLUTE_EXECUTABLE enable x to export sanitized ASIC text to a private \
            local .txt and open it (no shell; disabled by default)"
     and artifact_binary_viewer =
       flag
         "--artifact-binary-viewer"
         ~aliases:[ "--simulation-viewer" ]
         (optional
            (Command.Arg_type.create (fun path ->
               Artifact_binary_export.executable path |> Or_error.ok_exn)))
         ~doc:
           "ABSOLUTE_EXECUTABLE external viewer for verified ASIC binary files (b) and \
            simulation traces (palette, <=64 MiB); alias --simulation-viewer; receives \
            one private terminal-host path, no shell; disabled by default"
     and hierarchy =
       flag
         "--hierarchy"
         (optional string)
         ~doc:"ARTIFACT_ID retrieve structured hierarchy in plain mode"
     and refresh_integration =
       flag
         "--refresh-integration"
         no_arg
         ~doc:" queue project-driver discovery refresh in plain mode"
     and wait =
       flag
         "--wait"
         no_arg
         ~doc:" wait for a plain action, or bounded typed ASIC operation completion"
     and diagnostics_file =
       flag
         "--diagnostics-file"
         (optional string)
         ~doc:"FILE append dimensions and caught errors outside the active terminal"
     and capture_baseline =
       flag
         "--capture-baseline"
         (optional string)
         ~doc:
           "DIR render the deterministic UI fixtures into DIR and exit (development \
            baseline capture; no daemon or project needed)"
     and capture_fs0 =
       flag
         "--capture-fs0"
         (optional string)
         ~doc:
           "DIR capture actual workspace renderer with explicitly synthetic FS0 fixtures"
     and capture_appearance =
       flag
         "--capture-appearance"
         (optional string)
         ~doc:"DIR capture experimental A-E skins over identical synthetic fixtures"
     in
     match capture_appearance, capture_fs0, capture_baseline with
     | (Some _, _, _ | _, Some _, _ | _, _, Some _) when api ->
       fun () ->
         let message = "--api cannot be combined with capture hooks" in
         printf
           "%s\n%!"
           (Sexp.to_string_mach
              (Workspace.Response.sexp_of_t
                 (Error (V1.Error.create Invalid_request message))));
         return (Or_error.error_string message)
     | Some directory, _, _ ->
       fun () ->
         capture_appearance_frames ~directory;
         return (Ok ())
     | None, Some directory, _ ->
       fun () ->
         capture_fs0_frames ~directory;
         return (Ok ())
     | None, None, Some directory ->
       (* The capture renders fixtures; it neither connects to a daemon nor opens a
          project, so it never enters [run] and none of the session flags apply. *)
       fun () ->
       capture_baseline_frames ~directory;
       return (Ok ())
     | None, None, None ->
       (match
          Hardcaml_workbench_setup.Project_discovery.resolve
            ~explicit:project_root
            ~discover:discover_project
            ~explicit_flag:"--project-root"
            ~discover_flag:"--discover-project"
        with
        | Error message ->
          fun () ->
            if api
            then
              printf
                "%s\n%!"
                (Sexp.to_string_mach
                   (Workspace.Response.sexp_of_t
                      (Error (V1.Error.create Invalid_request message))));
            return (Or_error.error_string message)
        | Ok (project_root, note) ->
          timing_prefetch_neighbors := timing_neighbors;
          timing_preload_override := timing_preload;
          if not api then Option.iter note ~f:(eprintf "hardcaml-workbench: %s\n%!");
          run
            ~endpoint
            ~workspace_config
            ~project_root
            ~environment
            ~plain
            ~api
            ~asic_operation
            ~workspace_operation
            ~wait_timeout_seconds
            ~action
            ~target
            ~configuration
            ~artifact
            ~hierarchy
            ~refresh_integration
            ~wait
            ~diagnostics_file
            ~artifact_viewer
            ~artifact_binary_viewer))
;;

let () = Command_unix.run command
