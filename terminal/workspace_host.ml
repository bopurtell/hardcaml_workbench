open! Core
open Hardcaml_workbench_protocol
module W = Workspace
module P = Hardcaml_workbench_workspaces
module T = Tile_presentation

(** Only presentation state lives here. Registry writes are effects returned to the
    transport owner; a keypress never optimistically mutates the registry. *)
type local =
  { (* Lifetime token: numeric request counters may restart after removal/retyping. *)
    identity : unit ref
  ; cursor : string option
  ; stage_run : Run_ref.t option
  ; filter : string
  ; scroll : int
  ; follow : bool
  ; presentation : T.overrides
  ; metrics_scope : (Run_ref.t * string) option
  ; utility_detail : bool
  ; synthesis : Synthesis_view.State.t
  ; resources : Resources_view.t
  ; workloads : Workloads_view.t
  ; terminal_result : Terminal_result_view.State.t
  ; artifacts : Artifact_view.t option
  ; artifact_generation : int
  ; inspection : Inspection_view.t option
  ; inspection_generation : int
  ; simulation : Simulation_view.t
  ; hierarchy : Hierarchy_view.t option
  ; hierarchy_request : unit ref
  ; hierarchy_status : string
  }

type layout_mode =
  | Fit
  | Preferred
[@@deriving equal, sexp]

type testing_inputs =
  { suite : Simulation.Suite.t
  ; selection : Simulation.Selection.t
  ; digest : string
  }

type testing_launch =
  { identity : unit ref
  ; scope : string
  ; workspace : W.Workspace_id.t
  ; inputs : testing_inputs
  }

type action =
  | Registry of W.Mutation.t
  | Switch of W.Workspace_id.t
  | Build
  | Test
  | Cancel of Job_id.t
  | Refresh_integration
  | Generate_rtl of Target_id.t * Configuration_id.t
  | Inspect_artifact
  | Inspect_hierarchy
  | Load_hierarchy of W.Tile_id.t
  | Hierarchy_detail of W.Tile_id.t
  | Discover_asic
  | Open_resources
  | Open_workloads
  | Workload_import
  | Workload_result of string * string option
  | Workload_input of Workloads_view.input
  | Workload_capture of bool
  | Workload_reference of W.Tile_id.t * Simulation.Artifact.t
  | Workload_testing
  | Resource_target of Asic_resources.Target.t option
  | Resource_import of bool
  | Resource_import_path of bool * string
  | Resource_input of Resources_view.input
  | Prepare_project
  | Quick_prepare_project
  | Launch_preparation of string
  | Quick_prepare_stage of Asic.Stage.t * Run_ref.t
  | Quick_prepare_endpoint of string * Run_ref.t
  | Launch_stage_and_view of Stage_action.intent * Run_ref.t option * Asic.Selection.t
  | Quick_launch_selected of Overview_tiles.checklist_item * Run_ref.t
  | Launch_elaboration_bundle of Preparation.Selection.t
  | Set_quick_launch_view of bool
  | Edit_preparation of string * string
  | Select_preparation of Asic.Selection.t
  | Cancel_preparation
  | Preparation_artifact
  | Preparation_open_artifact of Artifact_id.t
  | Asic of Asic.Operation.t
  | Edit_plan of string * string
  | Edit_finalization of Run_ref.t
  | Edit_acceptance of Run_ref.t * string
  | Finalize_collect of Run_ref.t * string
  | Browse_artifacts of Run_ref.t
  | Browse_inspection of Run_ref.t * string * string
  | Browse_default_timing of Run_ref.t
  | Browse_analysis of Run_ref.t * Asic_inspection.Analysis_target.t
  | Browse_separate_timing of Run_ref.t
  | Inspect_overview_analysis of W.Tile_id.t
  | Launch_asic of Asic.Preview.t * bool
  | Launch_fresh_intent of Asic.Fresh.Intent.t * bool
  | Unavailable_launch
  | Prepare_stage of Asic.Stage.t * Run_ref.t
  | Prepare_endpoint of string * Run_ref.t
  | Apply_default_layout
  | Restore_default_layout of W.Workspace_id.t * P.Definition.t
  | Restore_default_layout_unavailable
  | Create_testing_workspace
  | Create_blank_workspace
  | Local_headers
  | Set_presentation of W.Tile_id.t * T.overrides
  | Set_global_compression of bool option
  | Set_workspace_compression of W.Workspace_id.t * bool option
  | Resume_log
  | Toggle_chrome
  | Toggle_main_hints
  | Toggle_palette_hints
  | Set_timing_preload of bool
  | Set_appearance of Appearance.t
  | Set_layout_mode of layout_mode
  | Synthesis_mode of Synthesis_view.Mode.t
  | Synthesis_sort of Synthesis.Sort.t
  | Synthesis_cycle_sort
  | Synthesis_clear_filter
  | Exit
  | Simulation of W.Tile_id.t * Simulation.Operation.t
  | Simulation_form of W.Tile_id.t * string * Simulation.Suite.t * string
  | Simulation_edit of W.Tile_id.t * string * string * Simulation_view.Form.t
  | Simulation_case of W.Tile_id.t * string
  | Simulation_logs of W.Tile_id.t
  | Simulation_export of Simulation.Artifact.t * bool
  | Simulation_waveform of Simulation.Artifact.t
  | Simulation_waveform_workspace of Simulation.Artifact.t
  | Waveform_control of string * Simulation.Artifact.t
  | Testing_launch of W.Tile_id.t * testing_launch
  | Testing_launch_unavailable of string
  | Testing_accept of W.Tile_id.t
  (* WB-054: close the focused tile's inspector; replay one existing inspector key; or
     explain why a contextual action that exists is unavailable right now. *)
  | Close_inspector
  | Inspector_input of W.Tile_id.t * Inspection_view.input
  | Unavailable of string

type command =
  { id : string
  ; title : string
  ; aliases : string
  ; action : action
  ; unavailable : string option
  }

type capture =
  { session : W.Session_id.t
  ; revision : int
  ; workspace : W.Workspace_id.t
  }

type argument =
  | Plan_endpoint of string * string
  | Preparation_inputs of string * string
  | Finalization_attempt of Run_ref.t
  | Resource_path of bool
  | Workload_path
  | Workload_bundle of bool * Workloads_view.capture_token
  | Acceptance of Run_ref.t * string * string
  | Simulation_selection of W.Tile_id.t * string * string * Simulation_view.Form.t

type restore_ticket =
  { intent : unit ref
  ; capture : capture
  }

type palette =
  { capture : capture
  ; commands : command list
  ; query : string
  ; index : int
  ; argument : argument option
  }

type t =
  { registry : W.Snapshot.t option
  ; active : W.Workspace_id.t option
  ; focus : W.Tile_id.t option
  ; locals : (string * local) list
  ; palette : palette option
  ; prefix : int
  ; paste : bool
  ; inspection_paste : W.Tile_id.t option
  ; chrome : bool
  ; main_hints : bool
  ; palette_hints : bool
  ; timing_preload : bool
  ; quick_launch_view : bool
  ; planned_preparation : bool
  ; notice : string
  ; editing_filter : bool
  ; workspace_focus : (string * W.Tile_id.t option) list
  ; appearance : Appearance.t
  ; layout_mode : layout_mode
  ; layout_intent : unit ref
  ; presentation : T.overrides
  ; workspace_presentation : (string * T.overrides) list
  ; timing : (string * Timing_workspace.t) list
  ; timing_restore : (string * Navigation_preferences.timing) list
  ; timing_rejected : (string * string) list
  ; testing : (string * (unit ref * string * Testing_workspace.t)) list
  ; waveforms : (string * (unit ref * P.Waveforms.pin)) list
  ; planned_run : Planned_run.t
  ; stage_preparation : string option
  ; timing_navigation_notice : string option
  ; stage_generation : int
  ; remembered_selection : Asic.Selection.t option
  ; preparation : Preparation.Snapshot.t option
  ; preparation_rtl_scope : Preparation_view.Rtl_scope.t option
  }

let empty =
  { registry = None
  ; active = None
  ; focus = None
  ; locals = []
  ; palette = None
  ; prefix = 0
  ; paste = false
  ; inspection_paste = None
  ; chrome = true
  ; main_hints = true
  ; palette_hints = true
  ; timing_preload = true
  ; quick_launch_view = true
  ; planned_preparation = true
  ; notice = "Loading workspace registry"
  ; editing_filter = false
  ; workspace_focus = []
  ; appearance = Appearance.default
  ; layout_mode = Fit
  ; layout_intent = ref ()
  ; presentation = T.inherit_
  ; workspace_presentation = []
  ; timing = []
  ; timing_restore = []
  ; timing_rejected = []
  ; testing = []
  ; waveforms = []
  ; planned_run = Planned_run.empty
  ; stage_preparation = None
  ; timing_navigation_notice = None
  ; stage_generation = 0
  ; remembered_selection = None
  ; preparation = None
  ; preparation_rtl_scope = None
  }
;;

let default_local =
  { identity = ref ()
  ; cursor = None
  ; stage_run = None
  ; filter = ""
  ; scroll = 0
  ; follow = true
  ; presentation = T.inherit_
  ; metrics_scope = None
  ; utility_detail = false
  ; synthesis = Synthesis_view.State.empty
  ; resources = Resources_view.empty
  ; workloads = Workloads_view.empty
  ; terminal_result = Terminal_result_view.State.empty
  ; artifacts = None
  ; artifact_generation = 0
  ; inspection = None
  ; inspection_generation = 0
  ; simulation = Simulation_view.empty
  ; hierarchy = None
  ; hierarchy_request = ref ()
  ; hierarchy_status =
      "No hierarchy loaded; r loads current selection (generate RTL first if missing)"
  }
;;

let invalidate_layout_intent t = { t with layout_intent = ref () }
let set_layout_mode t layout_mode = { (invalidate_layout_intent t) with layout_mode }

let begin_restore t capture =
  let t = invalidate_layout_intent t in
  t, { intent = t.layout_intent; capture }
;;

(** A receipt permits a local Fit only for the still-current intent. The registry may
    already have applied to the captured workspace after client navigation. *)
let finish_restore t ticket ~acknowledged =
  let current =
    phys_equal t.layout_intent ticket.intent
    && Option.equal W.Workspace_id.equal t.active (Some ticket.capture.workspace)
    && Option.exists t.registry ~f:(fun registry ->
      W.Session_id.equal registry.session_id ticket.capture.session)
  in
  if not current
  then t, false
  else (
    let t = invalidate_layout_intent t in
    if acknowledged then { t with layout_mode = Fit }, true else t, false)
;;

let local t id =
  List.Assoc.find t.locals (W.Tile_id.to_string id) ~equal:String.equal
  |> Option.value_or_thunk ~default:(fun () -> { default_local with identity = ref () })
;;

let set_local t id value =
  { t with
    locals = List.Assoc.add t.locals ~equal:String.equal (W.Tile_id.to_string id) value
  }
;;

let hierarchy_request_current t id ~identity ~request =
  let l = local t id in
  phys_equal l.identity identity && phys_equal l.hierarchy_request request
;;

let missing_hierarchy_guidance ~(project : Project.t option) ~target ~configuration =
  match project with
  | None -> "open a project with hardware driver integration"
  | Some project ->
    (match project.integration.driver with
     | Absent ->
       "no hardware driver integration; configure a project-side hardware driver, then \
        refresh hardware integration"
     | Unusable { reason } ->
       "hardware driver unavailable: "
       ^ reason
       ^ "; fix it, then refresh hardware integration"
     | Available _ ->
       (match Option.bind target ~f:(Project.target project) with
        | None ->
          if List.is_empty project.targets
          then "no hardware targets discovered; refresh hardware integration"
          else "select a discovered hardware target and configuration"
        | Some target ->
          let configurations = Project.configurations_for_target project target.id in
          if Option.exists configuration ~f:(fun id ->
               List.exists configurations ~f:(fun config ->
                 Configuration_id.equal id config.id))
          then "generate RTL for selected target/configuration, then r"
          else if List.is_empty configurations
          then
            "no hardware configurations discovered for selected target; refresh hardware \
             integration"
          else "select a discovered configuration for the selected hardware target"))
;;

let%test_unit "missing hierarchy guidance requires a usable driver and matching \
               discovered target/configuration"
  =
  let project = Baseline_fixture.project in
  let target = List.hd_exn project.targets in
  let configuration = List.hd_exn (Project.configurations_for_target project target.id) in
  let guidance ?(target = Some target.id) ?(configuration = Some configuration.id) project
    =
    missing_hierarchy_guidance ~project ~target ~configuration
  in
  assert (
    String.equal
      (guidance (Some project))
      "generate RTL for selected target/configuration, then r");
  let unavailable project =
    let message = guidance project in
    assert (not (String.is_substring message ~substring:"generate RTL"));
    message
  in
  ignore (unavailable None : string);
  let absent =
    { project with integration = { project.integration with driver = Absent } }
  in
  assert (String.is_substring (unavailable (Some absent)) ~substring:"no hardware driver");
  let unusable =
    { project with
      integration =
        { project.integration with
          driver = Unusable { reason = "typed discovery failure" }
        }
    }
  in
  assert (
    String.is_substring (unavailable (Some unusable)) ~substring:"typed discovery failure");
  assert (
    String.is_substring
      (unavailable (Some { project with targets = []; configurations = [] }))
      ~substring:"no hardware targets discovered");
  assert (
    String.is_substring
      (unavailable (Some { project with configurations = [] }))
      ~substring:"no hardware configurations discovered");
  List.iter
    [ guidance ~target:None (Some project)
    ; guidance ~target:(Some (Target_id.of_string "removed-target")) (Some project)
    ; guidance ~configuration:None (Some project)
    ; guidance
        ~configuration:(Some (Configuration_id.of_string "removed-configuration"))
        (Some project)
    ]
    ~f:(fun message ->
      assert (not (String.is_substring message ~substring:"generate RTL")));
  let other =
    List.find_exn project.configurations ~f:(fun config ->
      not (Target_id.equal config.target target.id))
  in
  assert (
    String.equal
      (guidance ~configuration:(Some other.id) (Some project))
      "select a discovered configuration for the selected hardware target")
;;

let waveform_pin t workspace =
  List.Assoc.find t.waveforms (W.Workspace_id.to_string workspace) ~equal:String.equal
  |> Option.map ~f:snd
;;

let waveform_identity t workspace =
  List.Assoc.find t.waveforms (W.Workspace_id.to_string workspace) ~equal:String.equal
  |> Option.map ~f:fst
;;

let set_waveform_pin t workspace pin =
  if not
       (Option.exists t.registry ~f:(fun registry ->
          List.exists registry.workspaces ~f:(fun w ->
            W.Workspace_id.equal w.id workspace)
          && not (List.is_empty (P.Waveforms.members registry workspace))))
  then t
  else if Option.equal P.Waveforms.equal_pin (waveform_pin t workspace) (Some pin)
  then t
  else
    { t with
      waveforms =
        List.Assoc.add
          t.waveforms
          ~equal:String.equal
          (W.Workspace_id.to_string workspace)
          (ref (), pin)
    }
;;

type waveform_preference =
  { workspace : W.Workspace_id.t
  ; members : (string * string) list
  ; pin : P.Waveforms.pin
  }
[@@deriving sexp]

type waveform_preferences =
  { schema_version : int
  ; project_key : string
  ; session : W.Session_id.t option
  ; pins : waveform_preference list
  }
[@@deriving sexp]

let waveform_preferences ~project_key t =
  { schema_version = 1
  ; project_key
  ; session = Option.map t.registry ~f:(fun registry -> registry.session_id)
  ; pins =
      Option.value_map t.registry ~default:[] ~f:(fun registry ->
        List.filter_map registry.workspaces ~f:(fun workspace ->
          Option.bind (waveform_pin t workspace.id) ~f:(fun pin ->
            if not (String.equal pin.project_key project_key)
            then None
            else
              Some
                { workspace = workspace.id
                ; members = P.Waveforms.members registry workspace.id
                ; pin
                })))
  }
;;

(** Apply once after registry restoration. Membership and session fences prevent removed
    or reused workspace/tile IDs from resurrecting an old pin. Parsed data/logs are never
    restored as verified: the transport owner reloads the exact recorded artifact. *)
let restore_waveform_preferences saved t =
  match t.registry with
  | Some registry
    when Option.equal W.Session_id.equal saved.session (Some registry.session_id) ->
    List.fold saved.pins ~init:t ~f:(fun t pref ->
      let members = P.Waveforms.members registry pref.workspace in
      if String.equal pref.pin.project_key saved.project_key
         && (not (List.is_empty members))
         && List.equal [%equal: string * string] pref.members members
         && Option.is_none (waveform_pin t pref.workspace)
      then set_waveform_pin t pref.workspace pref.pin
      else t)
  | _ -> t
;;

let decode_waveform_preferences ~project_key content =
  if String.length content > 1024 * 1024
  then failwith "Waveforms preference size limit exceeded";
  let saved = waveform_preferences_of_sexp (Sexp.of_string content) in
  if saved.schema_version <> 1 then failwith "Unsupported Waveforms preference schema";
  if not (String.equal project_key saved.project_key)
  then failwith "Waveforms preference project/environment mismatch";
  if List.length saved.pins > 128 then failwith "Too many retained Waveforms pins";
  if Option.is_none saved.session && not (List.is_empty saved.pins)
  then failwith "Waveforms pins require a registry session";
  if List.contains_dup saved.pins ~compare:(fun a b ->
       W.Workspace_id.compare a.workspace b.workspace)
  then failwith "Duplicate Waveforms workspace pin";
  List.iter saved.pins ~f:(fun pref ->
    if not (String.equal pref.pin.project_key project_key)
    then failwith "Waveforms pin project/environment mismatch";
    if List.is_empty pref.members || List.length pref.members > 256
    then failwith "Invalid Waveforms pane membership";
    if List.contains_dup pref.members ~compare:(fun (a, _) (b, _) -> String.compare a b)
    then failwith "Duplicate Waveforms pane identity";
    if not (List.for_all pref.members ~f:(fun (_, kind) -> P.Waveforms.is_pane kind))
    then failwith "Unknown Waveforms pane kind");
  saved
;;

let encode_waveform_preferences saved =
  Sexp.to_string_hum (sexp_of_waveform_preferences saved) ^ "\n"
;;

let waveform_preferences_path ~state_directory ~project_key =
  Filename.concat state_directory ("waveforms-" ^ Plain_rpc.digest project_key ^ ".sexp")
;;

(** Match existing terminal preference conventions: bounded files, same-directory atomic
    rename, caller-owned I/O worker. Workspace layout remains authoritative in daemon. *)
let load_waveform_preferences ~state_directory ~project_key =
  let path = waveform_preferences_path ~state_directory ~project_key in
  match Sys_unix.file_exists path with
  | `No -> None
  | `Unknown -> failwith ("Cannot inspect Waveforms preferences: " ^ path)
  | `Yes ->
    if Int64.((Core_unix.stat path).st_size > 1048576L)
    then failwith "Waveforms preference size limit exceeded";
    Some (decode_waveform_preferences ~project_key (In_channel.read_all path))
;;

let save_waveform_preferences ~state_directory saved =
  let data = encode_waveform_preferences saved in
  ignore
    (decode_waveform_preferences ~project_key:saved.project_key data
     : waveform_preferences);
  Core_unix.mkdir_p state_directory ~perm:0o700;
  let temp = Filename_unix.temp_file ~in_dir:state_directory ".waveforms-" ".tmp" in
  Exn.protect
    ~finally:(fun () ->
      if Poly.equal (Sys_unix.file_exists temp) `Yes then Core_unix.unlink temp)
    ~f:(fun () ->
      Out_channel.write_all temp ~data;
      Core_unix.rename
        ~src:temp
        ~dst:(waveform_preferences_path ~state_directory ~project_key:saved.project_key))
;;

let simulation_tile t id =
  Option.bind t.registry ~f:(fun registry ->
    List.find registry.tiles ~f:(fun tile -> W.Tile_id.equal tile.id id))
;;

let testing t id =
  Option.bind (simulation_tile t id) ~f:(fun tile ->
    if Testing_workspace.is_pane tile.kind
    then
      List.Assoc.find
        t.testing
        (W.Workspace_id.to_string tile.workspace)
        ~equal:String.equal
    else None)
;;

let set_testing t id value =
  match simulation_tile t id with
  | Some tile when Testing_workspace.is_pane tile.kind ->
    { t with
      testing =
        List.Assoc.add
          t.testing
          ~equal:String.equal
          (W.Workspace_id.to_string tile.workspace)
          value
    }
  | _ -> t
;;

let testing_state t id =
  Option.value_map
    (testing t id)
    ~default:Testing_workspace.empty
    ~f:(fun (_, _, state) -> state)
;;

let update_testing t id f =
  let identity, scope, state =
    Option.value_or_thunk (testing t id) ~default:(fun () ->
      ref (), "", Testing_workspace.empty)
  in
  set_testing t id (identity, scope, f state)
;;

let establish_testing_scope t id ~scope =
  match testing t id with
  | Some (_, previous, _) when String.equal previous scope -> t
  | _ -> set_testing t id (ref (), scope, Testing_workspace.empty)
;;

let simulation t id =
  match simulation_tile t id with
  | Some tile when Testing_workspace.is_pane tile.kind ->
    Testing_workspace.view (testing_state t id)
  | _ -> (local t id).simulation
;;

let set_simulation t id view =
  match simulation_tile t id with
  | Some tile when Testing_workspace.is_pane tile.kind ->
    update_testing t id (fun state -> Testing_workspace.set_view state view)
  | _ -> set_local t id { (local t id) with simulation = view }
;;

let simulation_kind kind =
  String.equal kind "simulation" || Testing_workspace.is_pane kind
;;

let simulation_identity t id =
  match testing t id with
  | Some (identity, _, _) -> identity
  | None -> (local t id).identity
;;

let capture_testing_inputs catalog =
  Or_error.map (Simulation_catalog.launch catalog) ~f:(fun (suite, selection, digest) ->
    { suite; selection; digest })
;;

let validate_testing_inputs catalog captured =
  match capture_testing_inputs catalog with
  | Error error ->
    Or_error.error_string (Error.to_string_hum error ^ "; reopen the launch command")
  | Ok current ->
    if Simulation.Suite.equal captured.suite current.suite
       && Simulation.Selection.equal captured.selection current.selection
       && String.equal captured.digest current.digest
    then Ok ()
    else
      Or_error.error_string
        "Catalog choices or discovery changed; reopen the launch command"
;;

let testing_launch_action t id =
  match simulation_tile t id, testing t id with
  | Some tile, Some (identity, scope, state) ->
    (match capture_testing_inputs (Testing_workspace.catalog state) with
     | Error error -> Testing_launch_unavailable (Error.to_string_hum error)
     | Ok inputs ->
       Testing_launch (id, { identity; scope; workspace = tile.workspace; inputs }))
  | _ ->
    Testing_launch_unavailable "No current Testing catalog; reopen the launch command"
;;

let validate_testing_launch t id captured =
  match simulation_tile t id, testing t id with
  | Some tile, Some (identity, scope, state)
    when phys_equal captured.identity identity
         && String.equal captured.scope scope
         && W.Workspace_id.equal captured.workspace tile.workspace ->
    validate_testing_inputs (Testing_workspace.catalog state) captured.inputs
  | _ ->
    Or_error.error_string "Testing workspace identity changed; reopen the launch command"
;;

let set_filter t id filter =
  let l = local t id in
  let t = set_local t id { l with filter; scroll = 0 } in
  match simulation_tile t id with
  | Some tile when String.equal tile.kind "simulation-catalog" ->
    let t = set_local t id { (local t id) with follow = true } in
    update_testing t id (fun state ->
      Testing_workspace.update_catalog state (fun catalog ->
        Simulation_catalog.set_filter catalog filter))
  | _ -> t
;;

(** The catalog captures sparse overrides. A change to any persisted appearance field
    ([T.persisted]) is durable; run reference/freshness remain local even when they travel
    in the same action. *)
let set_presentation t id (presentation : T.overrides) =
  if not
       (Option.exists t.registry ~f:(fun registry ->
          List.exists registry.tiles ~f:(fun tile -> W.Tile_id.equal tile.id id)))
  then t, false
  else (
    let previous = local t id in
    let compression_only =
      T.equal_overrides
        { previous.presentation with
          string_compression = presentation.string_compression
        }
        presentation
    in
    ( set_local
        t
        id
        { previous with
          presentation
        ; scroll = (if compression_only then previous.scroll else 0)
        }
    , not
        (T.equal_overrides (T.persisted previous.presentation) (T.persisted presentation))
    ))
;;

let set_global_compression t string_compression =
  { t with presentation = { t.presentation with string_compression } }
;;

let set_workspace_compression t workspace string_compression =
  if not
       (Option.exists t.registry ~f:(fun registry ->
          List.exists registry.workspaces ~f:(fun w ->
            W.Workspace_id.equal w.id workspace)))
  then t
  else (
    let key = W.Workspace_id.to_string workspace in
    let previous =
      List.Assoc.find t.workspace_presentation key ~equal:String.equal
      |> Option.value ~default:T.inherit_
    in
    let overrides = { previous with string_compression } in
    let remaining = List.Assoc.remove t.workspace_presentation key ~equal:String.equal in
    { t with
      workspace_presentation =
        (if T.equal_overrides overrides T.inherit_
         then remaining
         else (key, overrides) :: remaining)
    })
;;

let timing_epoch registry workspace =
  let arrangement = W.workspace registry workspace in
  let context = W.context registry arrangement.context in
  let bindings =
    List.filter registry.W.Snapshot.tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace workspace
      && Option.is_some (Timing_workspace.pane tile.kind))
    |> List.map ~f:(fun tile ->
      W.Tile_id.to_string tile.id
      ^ ":"
      ^ tile.kind
      ^ ":"
      ^ Sexp.to_string_mach (W.Binding.sexp_of_t tile.binding))
    |> List.sort ~compare:String.compare
  in
  String.concat
    ~sep:"|"
    (W.Workspace_id.to_string workspace
     :: W.Context_id.to_string context.id
     :: Int.to_string arrangement.binding_revision
     :: Int.to_string context.selection_revision
     :: bindings)
;;

let timing t (tile : W.Tile.t) =
  Option.bind (Timing_workspace.pane tile.kind) ~f:(fun _ ->
    List.Assoc.find t.timing (W.Workspace_id.to_string tile.workspace) ~equal:String.equal
    |> Option.filter ~f:(fun view ->
      Option.exists t.registry ~f:(fun registry ->
        match W.resolve_tile registry tile.id with
        | Ok reference ->
          Option.equal Run_ref.equal reference.run (Some view.run)
          && Option.equal
               String.equal
               view.workspace_epoch
               (Some (timing_epoch registry tile.workspace))
        | Error _ -> false)))
;;

let set_timing t (tile : W.Tile.t) (view : Timing_workspace.t) =
  let view =
    { view with
      Inspection_view.workspace_epoch =
        Option.map t.registry ~f:(fun registry -> timing_epoch registry tile.workspace)
    }
  in
  { t with
    timing =
      List.Assoc.add
        t.timing
        ~equal:String.equal
        (W.Workspace_id.to_string tile.workspace)
        view
  }
;;

let timing_pane t (tile : W.Tile.t) =
  let local = local t tile.id in
  if Option.is_some local.inspection || Option.is_some local.artifacts
  then None
  else Timing_workspace.pane tile.kind
;;

let inspection t id =
  let tile =
    Option.bind t.registry ~f:(fun s ->
      List.find s.tiles ~f:(fun tile -> W.Tile_id.equal tile.id id))
  in
  match tile with
  | Some tile when Option.is_some (timing_pane t tile) ->
    if Option.is_some (local t id).artifacts then None else timing t tile
  | _ -> (local t id).inspection
;;

let set_inspection t id view =
  let tile =
    Option.bind t.registry ~f:(fun s ->
      List.find s.tiles ~f:(fun tile -> W.Tile_id.equal tile.id id))
  in
  match tile, view with
  | Some tile, Some view when Option.is_some (timing_pane t tile) ->
    set_timing t tile view
  | _ -> set_local t id { (local t id) with inspection = view }
;;

(** A stage ID is meaningful only within its exact run. Reordering observations keeps
    selection; changing runs or removing the selected ID falls back to the first row. *)
let stage_cursor local ~run ~(stages : Asic.Stage.t list) =
  let selected =
    if Option.equal Run_ref.equal local.stage_run (Some run)
    then
      Option.bind local.cursor ~f:(fun id ->
        List.find stages ~f:(fun stage -> String.equal stage.id id))
    else None
  in
  Option.first_some selected (List.hd stages)
;;

let checklist_cursor local ~run ~items =
  let selected =
    if Option.equal Run_ref.equal local.stage_run (Some run)
    then
      Option.bind local.cursor ~f:(fun id ->
        List.find items ~f:(fun item ->
          String.equal (Overview_tiles.checklist_id item) id))
    else None
  in
  Option.first_some selected (List.hd items)
;;

let reconcile_checklist local ~run ~items =
  let cursor =
    Option.bind run ~f:(fun run ->
      Option.map (checklist_cursor local ~run ~items) ~f:Overview_tiles.checklist_id)
  in
  if Option.equal Run_ref.equal local.stage_run run
     && Option.equal String.equal local.cursor cursor
  then local
  else { local with cursor; stage_run = run; scroll = 0; utility_detail = false }
;;

let browse_checklist t id ~run ~items ~delta =
  let l = local t id in
  let pos =
    Option.bind (checklist_cursor l ~run ~items) ~f:(fun selected ->
      List.findi items ~f:(fun _ item ->
        String.equal
          (Overview_tiles.checklist_id item)
          (Overview_tiles.checklist_id selected))
      |> Option.map ~f:fst)
    |> Option.value ~default:0
  in
  let cursor =
    List.nth items (Int.max 0 (Int.min (List.length items - 1) (pos + delta)))
    |> Option.map ~f:Overview_tiles.checklist_id
  in
  set_local t id { l with cursor; stage_run = Some run; scroll = 0 }
;;

let reconcile_stages local ~run ~stages =
  let cursor =
    Option.bind run ~f:(fun run ->
      stage_cursor local ~run ~stages |> Option.map ~f:(fun stage -> stage.id))
  in
  if Option.equal Run_ref.equal local.stage_run run
     && Option.equal String.equal local.cursor cursor
  then local
  else { local with cursor; stage_run = run; scroll = 0; utility_detail = false }
;;

let browse_stages t id ~run ~stages ~delta =
  let l = local t id in
  let index =
    Option.bind (stage_cursor l ~run ~stages) ~f:(fun selected ->
      List.findi stages ~f:(fun _ stage -> String.equal stage.Asic.Stage.id selected.id)
      |> Option.map ~f:fst)
    |> Option.value ~default:0
  in
  let index = Int.max 0 (Int.min (List.length stages - 1) (index + delta)) in
  let cursor = Option.map (List.nth stages index) ~f:(fun stage -> stage.Asic.Stage.id) in
  set_local t id { l with cursor; stage_run = Some run; scroll = 0 }
;;

let stage_plan = function
  | None -> Error "Stage action unavailable: no explicit stage observation"
  | Some (stage : Asic.Stage.t) ->
    (match stage.status, stage.action with
     | Unsupported, _ ->
       Error
         ("Stage action unavailable: unsupported — "
          ^ Option.value stage.reason ~default:stage.name)
     | _, None ->
       Error
         ("Stage action unavailable: "
          ^ Option.value stage.reason ~default:"no advertised stage selection")
     | _, Some selection -> Ok (Asic.Operation.Plan selection))
;;

let%test_unit "stage cursor uses stable IDs within exact runs and resets stale inspection"
  =
  let stage id : Asic.Stage.t =
    { id
    ; name = "Same label"
    ; status = Pending
    ; requested = true
    ; reason = None
    ; action = None
    ; execution_timing = None
    }
  in
  let a = stage "a"
  and b = stage "b" in
  let registry = W.initial ~session_id:(W.Session_id.of_string "stage-cursor") in
  let tile = List.hd_exn registry.tiles in
  let host = { empty with registry = Some registry } in
  let host =
    browse_stages host tile.id ~run:Fs0_fixture.run_a ~stages:[ a; b ] ~delta:1
  in
  let local = local host tile.id in
  assert (Option.equal String.equal local.cursor (Some "b"));
  let selected stages run = Option.value_exn (stage_cursor local ~run ~stages) in
  assert (String.equal (selected [ b; a ] Fs0_fixture.run_a).id "b");
  assert (String.equal (selected [ a; b ] Fs0_fixture.run_b).id "a");
  assert (String.equal (selected [ a ] Fs0_fixture.run_a).id "a");
  let detailed = { local with utility_detail = true; scroll = 99 } in
  let refreshed =
    reconcile_stages detailed ~run:(Some Fs0_fixture.run_a) ~stages:[ b; a ]
  in
  assert (refreshed.utility_detail && refreshed.scroll = 99);
  let changed =
    reconcile_stages detailed ~run:(Some Fs0_fixture.run_b) ~stages:[ a; b ]
  in
  assert ((not changed.utility_detail) && changed.scroll = 0);
  assert (Option.equal String.equal changed.cursor (Some "a"));
  let removed = reconcile_stages detailed ~run:(Some Fs0_fixture.run_a) ~stages:[] in
  assert (Option.is_none removed.cursor && not removed.utility_detail)
;;

let%test_unit "stage planning uses only advertised selection and never resumes a run" =
  let selection : Asic.Selection.t =
    { flow = "ordinary-flow"
    ; profile = "profile"
    ; endpoint = "through-placement"
    ; assignments = [ "parameter=value with spaces" ]
    }
  in
  let stage : Asic.Stage.t =
    { id = "placement"
    ; name = "Placement"
    ; status = Failed
    ; requested = true
    ; reason = Some "provider reason"
    ; action = Some selection
    ; execution_timing = None
    }
  in
  (match stage_plan (Some stage) with
   | Ok (Plan actual) -> assert (Asic.Selection.equal actual selection)
   | _ -> assert false);
  List.iter
    [ None; Some { stage with action = None }; Some { stage with status = Unsupported } ]
    ~f:(fun stage ->
      match stage_plan stage with
      | Error reason -> assert (String.is_substring reason ~substring:"unavailable")
      | Ok _ -> assert false)
;;

let active t =
  Option.bind t.registry ~f:(fun s ->
    Option.bind t.active ~f:(fun id ->
      List.find s.workspaces ~f:(fun w -> W.Workspace_id.equal w.id id)))
;;

let tiles t =
  match t.registry, active t with
  | Some s, Some w ->
    List.filter s.tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace w.id
      && (not tile.hidden)
      && Option.value_map w.zoomed_tile ~default:true ~f:(W.Tile_id.equal tile.id))
  | _ -> []
;;

let focused t =
  Option.bind t.focus ~f:(fun id ->
    List.find (tiles t) ~f:(fun tile -> W.Tile_id.equal tile.id id))
;;

let receive t (s : W.Snapshot.t) =
  match t.registry with
  | Some previous
    when W.Session_id.equal previous.session_id s.session_id
         && previous.revision > s.revision -> t
  | _ ->
    let t =
      match t.registry with
      | Some previous when not (W.Session_id.equal previous.session_id s.session_id) ->
        { (invalidate_layout_intent t) with
          active = None
        ; focus = None
        ; locals = []
        ; workspace_focus = []
        ; workspace_presentation = []
        ; timing = []
        ; timing_restore = []
        ; timing_rejected = []
        ; testing = []
        ; waveforms = []
        ; palette = None
        ; prefix = 0
        ; editing_filter = false
        }
      | _ -> t
    in
    let active =
      Option.filter t.active ~f:(fun id ->
        List.exists s.workspaces ~f:(fun w -> W.Workspace_id.equal w.id id))
      |> fun selected ->
      Option.first_some selected (Option.map (List.hd s.workspaces) ~f:(fun w -> w.id))
    in
    (* Tile IDs may be reused by a replacement registry session. Drop old local state on
       replacement and prune removed/retyped tiles on ordinary refresh. *)
    let locals =
      match t.registry with
      | Some previous when W.Session_id.equal previous.session_id s.session_id ->
        List.filter t.locals ~f:(fun (id, _) ->
          List.exists s.tiles ~f:(fun tile ->
            String.equal id (W.Tile_id.to_string tile.id)
            && List.exists previous.tiles ~f:(fun old ->
              W.Tile_id.equal old.id tile.id
              && W.Workspace_id.equal old.workspace tile.workspace
              && String.equal old.kind tile.kind)))
      | _ -> []
    in
    let locals =
      List.map locals ~f:(fun (id, local) ->
        let scope snapshot =
          Result.ok (W.resolve_tile snapshot (W.Tile_id.of_string id))
          |> Option.map ~f:(fun r -> r.context, r.selection_revision, r.run)
        in
        if Option.is_none local.resources.explicit
           && Option.exists t.registry ~f:(fun previous ->
             not
               ([%equal: (W.Context_id.t option * int option * Run_ref.t option) option]
                  (scope previous)
                  (scope s)))
        then
          id, { local with resources = Resources_view.select_target local.resources None }
        else id, local)
    in
    let notice =
      match t.palette with
      | Some { argument = Some (Simulation_selection _); _ } -> t.notice
      | _ ->
        (* Stage preparation finishes asynchronously, between registry polls and draws.
           Its current progress/failure must survive those polls until the user clears it
           or starts another action. Other transient notices retain their existing refresh
           behavior. *)
        Option.value_map
          (Option.first_some t.timing_navigation_notice t.stage_preparation)
          ~default:""
          ~f:(fun preparation ->
            if String.equal t.notice preparation then preparation else "")
    in
    (* Invalidate at every received transition, not only when a reader happens to
       reconcile. A pin A→B→A must never resurrect the first A's pending ticket. *)
    let timing =
      List.filter_map t.timing ~f:(fun (id, view) ->
        List.find s.workspaces ~f:(fun w ->
          String.equal id (W.Workspace_id.to_string w.id))
        |> Option.map ~f:(fun workspace ->
          let view =
            if Option.equal
                 String.equal
                 view.Inspection_view.workspace_epoch
                 (Some (timing_epoch s workspace.id))
            then view
            else
              { view with
                workspace_epoch = None
              ; generation = view.generation + 1
              ; requested = None
              ; detail = None
              ; index = None
              ; selected = None
              ; cache = None
              ; detail_cache = None
              ; error = None
              ; pending_error = None
              ; operation_key = None
              }
          in
          id, view))
    in
    let workspace_exists id =
      List.exists s.workspaces ~f:(fun workspace ->
        String.equal id (W.Workspace_id.to_string workspace.id))
    in
    let workspace_focus =
      List.filter_map t.workspace_focus ~f:(fun (workspace, focus) ->
        if not (workspace_exists workspace)
        then None
        else
          Some
            ( workspace
            , Option.filter focus ~f:(fun id ->
                List.exists s.tiles ~f:(fun tile ->
                  W.Tile_id.equal tile.id id
                  && String.equal workspace (W.Workspace_id.to_string tile.workspace))) ))
    in
    let workspace_presentation =
      List.filter t.workspace_presentation ~f:(fun (id, _) -> workspace_exists id)
    in
    let t =
      { t with
        registry = Some s
      ; layout_intent =
          (if Option.equal W.Workspace_id.equal active t.active
           then t.layout_intent
           else ref ())
      ; active
      ; locals
      ; notice
      ; timing
      ; workspace_focus
      ; workspace_presentation
      ; waveforms =
          List.filter t.waveforms ~f:(fun (id, _) ->
            match t.registry with
            | Some previous ->
              List.exists s.workspaces ~f:(fun workspace ->
                String.equal id (W.Workspace_id.to_string workspace.id)
                && (not (List.is_empty (P.Waveforms.members s workspace.id)))
                && List.equal
                     [%equal: string * string]
                     (P.Waveforms.members previous workspace.id)
                     (P.Waveforms.members s workspace.id))
            | None -> false)
      ; testing =
          List.filter t.testing ~f:(fun (id, _) ->
            let members registry =
              List.filter registry.W.Snapshot.tiles ~f:(fun tile ->
                String.equal id (W.Workspace_id.to_string tile.workspace)
                && Testing_workspace.is_pane tile.kind)
              |> List.map ~f:(fun tile -> W.Tile_id.to_string tile.id, tile.kind)
              |> List.sort ~compare:[%compare: string * string]
            in
            match t.registry with
            | Some previous ->
              workspace_exists id
              && (not (List.is_empty (members s)))
              && List.for_all (members previous) ~f:(fun member ->
                List.mem (members s) member ~equal:[%equal: string * string])
            | None -> false)
      }
    in
    let focus =
      Option.filter t.focus ~f:(fun id ->
        List.exists (tiles t) ~f:(fun tile -> W.Tile_id.equal tile.id id))
      |> fun selected ->
      Option.first_some selected (Option.map (List.hd (tiles t)) ~f:(fun tile -> tile.id))
    in
    { t with focus }
;;

(** A new transport invalidates receipts even if the daemon/session survives. Retain
    registry identity until [receive] can validate the next snapshot. *)
let reconnect t ~replacement =
  let invalidate_inspection (view : Inspection_view.t) =
    { view with
      generation = view.generation + 1
    ; requested = None
    ; operation_key = None
    ; pending_error = None
    ; detail_cache = None
    }
  in
  let t =
    { t with
      palette = None
    ; layout_intent = ref ()
    ; prefix = 0
    ; paste = false
    ; inspection_paste = None
    ; editing_filter = false
    ; stage_generation = t.stage_generation + 1
    ; stage_preparation = None
    ; timing_navigation_notice = None
    ; planned_run = Planned_run.reset t.planned_run ~scope:""
    ; timing = List.map t.timing ~f:(fun (id, view) -> id, invalidate_inspection view)
    ; testing =
        List.map t.testing ~f:(fun (id, (identity, scope, state)) ->
          id, (identity, scope, Testing_workspace.reconnect state))
    ; waveforms = List.map t.waveforms ~f:(fun (id, (_, pin)) -> id, (ref (), pin))
    ; locals =
        List.map t.locals ~f:(fun (id, local) ->
          ( id
          , { local with
              artifact_generation = local.artifact_generation + 1
            ; resources = Resources_view.reconnect local.resources
            ; workloads = Workloads_view.reconnect local.workloads
            ; artifacts =
                Option.map local.artifacts ~f:(fun view ->
                  { view with
                    generation = view.generation + 1
                  ; acknowledged = false
                  ; transport_error = None
                  })
            ; inspection_generation = local.inspection_generation + 1
            ; hierarchy_request = ref ()
            ; inspection = Option.map local.inspection ~f:invalidate_inspection
            ; simulation =
                { local.simulation with
                  snapshot = None
                ; busy = false
                ; request = local.simulation.request + 1
                }
            } ))
    }
  in
  if replacement
  then
    { t with
      registry = None
    ; active = None
    ; focus = None
    ; locals = []
    ; workspace_focus = []
    ; workspace_presentation = []
    ; timing = []
    ; timing_restore = []
    ; timing_rejected = []
    ; testing = []
    ; waveforms = []
    }
  else t
;;

let%test_unit "cooperative simulation state is workspace-local and legacy isolated" =
  let apply s mutation =
    W.apply s (Mutate { expected_revision = s.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let s = W.initial ~session_id:(W.Session_id.of_string "testing-shared") in
  let first = List.hd_exn s.workspaces
  and second = List.last_exn s.workspaces in
  let s = apply s (P.Definition.apply P.Testing.definition ~workspace:first.id) in
  let s = apply s (P.Definition.apply P.Testing.definition ~workspace:second.id) in
  let s =
    apply
      s
      (Create_tile
         { workspace = first.id
         ; kind = "simulation"
         ; geometry = { x = 0; y = 0; width = 80; height = 20 }
         })
  in
  let find workspace kind =
    List.find_exn s.tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace workspace && String.equal tile.kind kind)
  in
  let catalog = find first.id "simulation-catalog" in
  let detail = find first.id "simulation-detail" in
  let other = find second.id "simulation-detail" in
  let legacy = find first.id "simulation" in
  let host = receive empty s in
  let host =
    update_testing host catalog.id (fun state ->
      Testing_workspace.select_attempt state "chosen")
  in
  assert (Option.equal String.equal (simulation host detail.id).attempt (Some "chosen"));
  assert (Option.is_none (simulation host other.id).attempt);
  assert (Option.is_none (simulation host legacy.id).attempt);
  let host = set_local host catalog.id { (local host catalog.id) with scroll = 9 } in
  assert ((local host detail.id).scroll = 0);
  let host = receive host { s with revision = s.revision + 1 } in
  assert (Option.equal String.equal (simulation host detail.id).attempt (Some "chosen"));
  let host = reconnect host ~replacement:false in
  assert (Option.equal String.equal (simulation host detail.id).attempt (Some "chosen"));
  let host =
    receive
      host
      { s with
        revision = s.revision + 2
      ; tiles =
          List.filter s.tiles ~f:(fun tile -> not (W.Tile_id.equal tile.id catalog.id))
      }
  in
  assert (Option.is_none (simulation host detail.id).attempt)
;;

let capture t =
  match t.registry, active t with
  | Some s, Some w ->
    Some { session = s.session_id; revision = s.revision; workspace = w.id }
  | _ -> None
;;

let%test_unit "local tile state survives refresh but not replacement identities" =
  let registry = W.initial ~session_id:(W.Session_id.of_string "local-state-session") in
  let tile = List.hd_exn registry.tiles in
  let host = receive empty registry in
  let host =
    set_local
      host
      tile.id
      { default_local with
        presentation = { default_local.presentation with header = Some false }
      ; filter = "browsing"
      }
  in
  let refreshed = receive host { registry with revision = registry.revision + 1 } in
  assert (
    Option.equal Bool.equal (local refreshed tile.id).presentation.header (Some false));
  assert (String.equal (local refreshed tile.id).filter "browsing");
  let replacement =
    receive host { registry with session_id = W.Session_id.of_string "new-local-session" }
  in
  assert (Option.is_none (local replacement tile.id).presentation.header);
  assert (String.is_empty (local replacement tile.id).filter);
  let removed = receive host { registry with tiles = [] } in
  assert (List.is_empty removed.locals);
  let retyped =
    receive
      host
      { registry with
        tiles =
          List.map registry.tiles ~f:(fun tile -> { tile with kind = "different-kind" })
      }
  in
  assert (Option.is_none (local retyped tile.id).presentation.header);
  let moved =
    receive
      host
      { registry with
        tiles =
          List.map registry.tiles ~f:(fun tile ->
            { tile with workspace = (List.last_exn registry.workspaces).id })
      }
  in
  assert (String.is_empty (local moved tile.id).filter);
  assert (not (phys_equal (local moved tile.id).identity (local host tile.id).identity));
  let readded = receive removed { registry with revision = registry.revision + 1 } in
  assert (String.is_empty (local readded tile.id).filter);
  assert (not (phys_equal (local readded tile.id).identity (local host tile.id).identity))
;;

let%test_unit "hierarchy read receipts reject superseding loads, removal, retyping and \
               reconnect"
  =
  let registry = W.initial ~session_id:(W.Session_id.of_string "hierarchy-receipts") in
  let tile = List.hd_exn registry.tiles in
  let registry =
    { registry with
      tiles =
        List.map registry.tiles ~f:(fun t ->
          if W.Tile_id.equal t.id tile.id then { t with kind = "hierarchy" } else t)
    }
  in
  let host = receive empty registry in
  let l = local host tile.id in
  let host = set_local host tile.id l in
  let accepts host =
    hierarchy_request_current
      host
      tile.id
      ~identity:l.identity
      ~request:l.hierarchy_request
  in
  assert (accepts (receive host { registry with revision = registry.revision + 1 }));
  assert (not (accepts (set_local host tile.id { l with hierarchy_request = ref () })));
  assert (not (accepts (reconnect host ~replacement:false)));
  let removed = receive host { registry with tiles = [] } in
  assert (not (accepts removed));
  assert (not (accepts (receive removed registry)));
  let retyped =
    receive
      host
      { registry with
        tiles = List.map registry.tiles ~f:(fun t -> { t with kind = "logs" })
      }
  in
  assert (not (accepts retyped))
;;

let%test_unit "same-session reconnect retains browsing and rejects old response tickets" =
  let registry = W.initial ~session_id:(W.Session_id.of_string "reconnect-browsing") in
  let tile = List.hd_exn registry.tiles in
  let host = receive empty registry in
  let view =
    { (Inspection_view.create
         ~generation:7
         ~run:Fs0_fixture.run_a
         ~domain:"timing"
         ~stage:"signoff"
         ())
      with
      filter = "endpoint/Q"
    ; selected = Some "row"
    ; scroll = 12
    }
  in
  let inspection_ticket = Inspection_view.capture view (Inspection_view.operation view) in
  let artifacts = Artifact_view.create ~generation:4 Fs0_fixture.run_a in
  let instance_id = V1.Daemon_instance_id.of_string "reconnect-instance" in
  let project = Project_id.of_string "reconnect-project" in
  let artifact_ticket =
    Artifact_view.capture
      artifacts
      ~instance_id
      ~project
      (List_artifacts Fs0_fixture.run_a)
    |> Option.value_exn
  in
  let simulation =
    Simulation_view.select Simulation_view.empty "historical-attempt"
    |> Simulation_view.begin_request
    |> fun (view : Simulation_view.t) ->
    { view with case_id = Some "case"; older = true; logs = true }
  in
  let selection : Asic.Selection.t =
    { flow = "flow"; profile = "profile"; endpoint = "signoff"; assignments = [] }
  in
  let planned_run, plan_ticket =
    Planned_run.begin_plan
      (Planned_run.reset host.planned_run ~scope:"daemon/project")
      selection
  in
  let preview : Asic.Preview.t =
    { selection; plan_identity = "plan"; plan_json = "{}" }
  in
  let planned_run, launch_ticket =
    Planned_run.begin_launch planned_run ~key:"launch" preview
  in
  let host =
    set_local
      host
      tile.id
      { (local host tile.id) with
        filter = "local browsing"
      ; scroll = 23
      ; presentation = { T.inherit_ with header = Some false }
      ; artifacts = Some artifacts
      ; artifact_generation = artifacts.generation
      ; inspection = Some view
      ; inspection_generation = view.generation
      ; simulation
      }
    |> fun host ->
    { host with
      planned_run
    ; timing = [ W.Workspace_id.to_string tile.workspace, view ]
    ; stage_generation = 9
    ; stage_preparation = Some "Preparing"
    }
  in
  let reconnected = reconnect host ~replacement:false in
  assert (Option.equal W.Snapshot.equal host.registry reconnected.registry);
  assert (Option.equal W.Tile_id.equal host.focus reconnected.focus);
  assert (Option.equal W.Workspace_id.equal host.active reconnected.active);
  let current = local reconnected tile.id in
  assert (String.equal current.filter "local browsing" && current.scroll = 23);
  assert (Option.equal Bool.equal current.presentation.header (Some false));
  assert (Option.equal String.equal current.simulation.attempt (Some "historical-attempt"));
  assert (Option.equal String.equal current.simulation.case_id (Some "case"));
  assert (
    current.simulation.older && current.simulation.logs && not current.simulation.busy);
  let late =
    Simulation_view.receive
      current.simulation
      ~ticket:simulation.request
      ~selected:simulation.attempt
      (Observe "historical-attempt")
      (Error "stale transport")
  in
  assert (Option.is_none late.error);
  let inspected = Option.value_exn current.inspection in
  assert (String.equal inspected.filter view.filter && inspected.scroll = 12);
  assert (Option.equal String.equal inspected.selected view.selected);
  assert (
    Option.is_none
      (Inspection_view.apply_response inspected inspection_ticket (Error "late")).error);
  let timing =
    List.Assoc.find_exn
      reconnected.timing
      ~equal:String.equal
      (W.Workspace_id.to_string tile.workspace)
  in
  assert (String.equal timing.filter view.filter && timing.generation > view.generation);
  assert (
    Option.is_none
      (Inspection_view.apply_response timing inspection_ticket (Error "late")).error);
  let artifacts = Option.value_exn current.artifacts in
  assert (
    Option.is_none
      (Artifact_view.apply_response
         artifacts
         artifact_ticket
         ~instance_id
         ~project
         (Error "late"))
        .error);
  assert (not (Planned_run.current_ticket reconnected.planned_run plan_ticket));
  let late_launch =
    Planned_run.launch_receipt
      reconnected.planned_run
      launch_ticket
      ~floor:1
      (Error "late launch")
  in
  assert (Option.is_none (Planned_run.model late_launch).launch.key);
  assert (reconnected.stage_generation > host.stage_generation);
  assert (Option.is_none reconnected.stage_preparation);
  let refreshed =
    receive reconnected { registry with revision = registry.revision + 1 }
  in
  assert (String.equal (local refreshed tile.id).filter "local browsing");
  let replaced =
    receive
      reconnected
      { registry with session_id = W.Session_id.of_string "replacement-session" }
  in
  assert (List.is_empty replaced.locals && List.is_empty replaced.timing);
  let new_daemon = reconnect host ~replacement:true in
  assert (Option.is_none new_daemon.registry && List.is_empty new_daemon.locals)
;;

let switch t id =
  if not
       (Option.exists t.registry ~f:(fun s ->
          List.exists s.workspaces ~f:(fun w -> W.Workspace_id.equal w.id id)))
  then t
  else (
    let workspace_focus =
      Option.value_map t.active ~default:t.workspace_focus ~f:(fun old ->
        List.Assoc.add
          t.workspace_focus
          ~equal:String.equal
          (W.Workspace_id.to_string old)
          t.focus)
    in
    let focus =
      List.Assoc.find workspace_focus ~equal:String.equal (W.Workspace_id.to_string id)
      |> Option.join
    in
    let changed = not (Option.equal W.Workspace_id.equal t.active (Some id)) in
    let t =
      { t with
        active = Some id
      ; layout_intent = (if changed then ref () else t.layout_intent)
      ; focus
      ; workspace_focus
      ; stage_generation = (t.stage_generation + if changed then 1 else 0)
      ; stage_preparation =
          (if changed && Option.is_some t.stage_preparation
           then Some "Stage preparation context changed; press r again"
           else t.stage_preparation)
      }
    in
    Option.value_map t.registry ~default:t ~f:(receive t))
;;

let blank_workspace_mutation (registry : W.Snapshot.t) ~window =
  let rec available n =
    let name = "Workspace " ^ Int.to_string n in
    if List.exists registry.workspaces ~f:(fun w -> String.equal w.name name)
    then available (n + 1)
    else name
  in
  W.Mutation.Create_workspace
    { window; name = available 1; context = registry.main_context }
;;

(** Only an acknowledged single mutation may drive creation navigation. A refresh after a
    conflict is not a creation receipt, even if another client added a workspace. *)
let created_workspace ~(before : W.Snapshot.t) ~(after : W.Snapshot.t) =
  if (not (W.Session_id.equal before.session_id after.session_id))
     || after.revision <> before.revision + 1
  then None
  else (
    match
      List.filter after.workspaces ~f:(fun w ->
        not
          (List.exists before.workspaces ~f:(fun old -> W.Workspace_id.equal old.id w.id)))
    with
    | [ workspace ] -> Some workspace.id
    | _ -> None)
;;

(** Registry membership, not labels or preset names, fences local navigation. *)
let navigation_members registry workspace =
  List.filter registry.W.Snapshot.tiles ~f:(fun tile ->
    W.Workspace_id.equal tile.workspace workspace)
  |> List.map ~f:(fun tile ->
    { Navigation_preferences.tile = W.Tile_id.to_string tile.id; kind = tile.kind })
  |> List.sort ~compare:(fun a b -> String.compare a.tile b.tile)
;;

let navigation_preferences ~project_key t =
  Option.map t.registry ~f:(fun registry ->
    let workspaces =
      List.map registry.workspaces ~f:(fun workspace ->
        let id = W.Workspace_id.to_string workspace.id in
        let focus =
          if Option.equal W.Workspace_id.equal t.active (Some workspace.id)
          then t.focus
          else List.Assoc.find t.workspace_focus id ~equal:String.equal |> Option.join
        in
        let testing =
          List.Assoc.find t.testing id ~equal:String.equal
          |> Option.map ~f:(fun (_, _, state) ->
            let view = Testing_workspace.view state in
            let artifact =
              Testing_workspace.artifact_identity state
              |> Option.map ~f:(fun artifact ->
                { Navigation_preferences.id = artifact.Testing_workspace.id
                ; sha256 = artifact.sha256
                ; size = artifact.size
                })
            in
            { Navigation_preferences.attempt = view.attempt
            ; case_id = view.case_id
            ; artifact
            })
        in
        let timing =
          match List.Assoc.find t.timing_restore id ~equal:String.equal with
          | Some saved -> Some saved
          | None ->
            List.Assoc.find t.timing id ~equal:String.equal
            |> Option.map ~f:(fun view ->
              { Navigation_preferences.stage = view.Inspection_view.stage
              ; filter = view.filter
              ; row_id = view.selected
              ; run = Some (Sexp.to_string_mach (Run_ref.sexp_of_t view.run))
              ; source_digest =
                  Option.map view.index ~f:(fun index -> index.source_digest)
              ; analysis = view.analysis
              })
        in
        { Navigation_preferences.id
        ; members = navigation_members registry workspace.id
        ; focus = Option.map focus ~f:W.Tile_id.to_string
        ; testing
        ; timing
        })
    in
    let saved =
      Navigation_preferences.create
        ~project_key
        ~session:(W.Session_id.to_string registry.session_id)
        ~active:(Option.map t.active ~f:W.Workspace_id.to_string)
        ~workspaces
    in
    Navigation_preferences.with_workloads
      saved
      (List.filter_map registry.tiles ~f:(fun tile ->
         if String.equal tile.kind "workloads"
         then
           Some
             ( W.Tile_id.to_string tile.id
             , Workloads_view.remember (local t tile.id).workloads )
         else None)))
;;

let valid_navigation_workspaces (saved : Navigation_preferences.t) t =
  Option.value_map t.registry ~default:[] ~f:(fun registry ->
    if not (String.equal saved.session (W.Session_id.to_string registry.session_id))
    then []
    else
      List.filter saved.workspaces ~f:(fun pref ->
        List.exists registry.workspaces ~f:(fun workspace ->
          String.equal pref.id (W.Workspace_id.to_string workspace.id)
          && List.equal
               (fun a b ->
                 String.equal a.Navigation_preferences.tile b.tile
                 && String.equal a.kind b.kind)
               pref.members
               (navigation_members registry workspace.id))))
;;

let restore_navigation_focus ?(restore_active = true) ?(preserve_focus = []) saved t =
  let valid = valid_navigation_workspaces saved t in
  let workspace_focus =
    List.fold valid ~init:t.workspace_focus ~f:(fun focus pref ->
      if List.mem preserve_focus pref.Navigation_preferences.id ~equal:String.equal
      then focus
      else
        List.Assoc.add
          focus
          ~equal:String.equal
          pref.id
          (Option.map pref.focus ~f:W.Tile_id.of_string))
  in
  let t = { t with workspace_focus } in
  match if restore_active then saved.Navigation_preferences.active else None with
  | Some id when List.exists valid ~f:(fun pref -> String.equal pref.id id) ->
    switch { t with focus = None; active = None } (W.Workspace_id.of_string id)
  | _ -> t
;;

(** Only actual navigation transitions fence a pending preference read. Repaint, unknown
    keys and palette query editing do not acquire navigation ownership. *)
let navigation_input_changes before after =
  let active = not (Option.equal W.Workspace_id.equal before.active after.active) in
  let focus =
    if (not active) && not (Option.equal W.Tile_id.equal before.focus after.focus)
    then Option.map after.active ~f:W.Workspace_id.to_string
    else None
  in
  let testing =
    List.filter_map after.testing ~f:(fun (id, (_, _, state)) ->
      Option.bind
        (List.Assoc.find before.testing id ~equal:String.equal)
        ~f:(fun (_, _, old) ->
          let before = Testing_workspace.view old
          and after = Testing_workspace.view state in
          if (not (Option.equal String.equal before.attempt after.attempt))
             || (not (Option.equal String.equal before.case_id after.case_id))
             || not
                  (Option.equal
                     String.equal
                     (Testing_workspace.selected_artifact old)
                     (Testing_workspace.selected_artifact state))
          then Some id
          else None))
  in
  let timing =
    List.filter_map after.timing ~f:(fun (id, state) ->
      Option.bind (List.Assoc.find before.timing id ~equal:String.equal) ~f:(fun old ->
        if (not (String.equal old.stage state.stage))
           || (not (String.equal old.filter state.filter))
           || not (Option.equal String.equal old.selected state.selected)
        then Some id
        else None))
  in
  active, focus, testing @ timing
;;

let restore_navigation_selections saved t ~scope =
  let t =
    List.fold saved.Navigation_preferences.workloads ~init:t ~f:(fun t (id, saved_view) ->
      let valid = valid_navigation_workspaces saved t in
      if List.exists valid ~f:(fun pref ->
           List.exists pref.members ~f:(fun m ->
             String.equal m.tile id && String.equal m.kind "workloads"))
      then (
        let id = W.Tile_id.of_string id in
        let l = local t id in
        set_local t id { l with workloads = Workloads_view.restore saved_view })
      else t)
  in
  List.fold (valid_navigation_workspaces saved t) ~init:t ~f:(fun t pref ->
    let workspace = W.Workspace_id.of_string pref.id in
    let members =
      Option.value_map t.registry ~default:[] ~f:(fun registry ->
        List.filter registry.tiles ~f:(fun tile ->
          W.Workspace_id.equal tile.workspace workspace))
    in
    let t =
      match
        ( pref.testing
        , List.find members ~f:(fun tile -> Testing_workspace.is_pane tile.kind) )
      with
      | Some saved, Some tile ->
        let t = establish_testing_scope t tile.id ~scope in
        let identity, _, state = Option.value_exn (testing t tile.id) in
        let state =
          Option.value_map saved.attempt ~default:state ~f:(fun attempt ->
            Testing_workspace.restore_selection
              state
              ~attempt
              ~case_id:saved.case_id
              ~artifact:
                (Option.map saved.artifact ~f:(fun artifact ->
                   { Testing_workspace.id = artifact.id
                   ; sha256 = artifact.sha256
                   ; size = artifact.size
                   })))
        in
        set_testing t tile.id (identity, scope, state)
      | _ -> t
    in
    match
      ( pref.timing
      , List.find members ~f:(fun tile ->
          Option.is_some (Timing_workspace.pane tile.kind)) )
    with
    | Some saved, Some tile ->
      Option.value_map t.registry ~default:t ~f:(fun registry ->
        Workspace.resolve_tile registry tile.id
        |> Result.ok
        |> Option.bind ~f:(fun reference -> reference.run)
        |> Option.value_map ~default:t ~f:(fun run ->
          let view =
            Timing_workspace.create ~generation:0 ~run ~stage:saved.stage
            |> fun view -> Timing_workspace.with_analysis view saved.analysis
          in
          let t =
            set_timing t tile { view with filter = saved.filter; selected = None }
          in
          { t with
            timing_restore =
              List.Assoc.add t.timing_restore ~equal:String.equal pref.id saved
          }))
    | _ -> t)
;;

let cancel_navigation_timing t id =
  { t with
    timing_restore = List.Assoc.remove t.timing_restore id ~equal:String.equal
  ; timing_rejected = List.Assoc.remove t.timing_rejected id ~equal:String.equal
  ; timing =
      List.map t.timing ~f:(fun (workspace, view) ->
        if String.equal workspace id
           && List.Assoc.mem t.timing_rejected id ~equal:String.equal
        then workspace, { view with error = None }
        else workspace, view)
  }
;;

(** Saved rows are evidence identities, not merely equal-looking row labels. Keep
    unresolved intent through read-only Gets, and keep rejected evidence visibly
    unselected until the user makes a new choice. *)
let reconcile_navigation_timing t snapshot =
  let find t id =
    Option.bind t.registry ~f:(fun registry ->
      List.find registry.tiles ~f:(fun tile ->
        String.equal id (W.Workspace_id.to_string tile.workspace)
        && Option.is_some (Timing_workspace.pane tile.kind)))
    |> Option.bind ~f:(fun tile -> Option.map (timing t tile) ~f:(fun view -> tile, view))
  in
  let reject t id message =
    { t with
      timing_restore = List.Assoc.remove t.timing_restore id ~equal:String.equal
    ; timing_rejected = List.Assoc.add t.timing_rejected ~equal:String.equal id message
    ; notice = message
    }
  in
  let t =
    List.fold t.timing_restore ~init:t ~f:(fun t (id, saved) ->
      match find t id with
      | None -> cancel_navigation_timing t id
      | Some (tile, view) ->
        if Option.is_none saved.row_id
        then cancel_navigation_timing t id
        else if (not
                   (Option.equal
                      String.equal
                      saved.run
                      (Some (Sexp.to_string_mach (Run_ref.sexp_of_t view.run)))))
                || Option.is_none saved.source_digest
                || (not (String.equal saved.stage view.stage))
                || not
                     (Option.equal
                        Asic_inspection.Analysis_target.equal
                        saved.analysis
                        view.analysis)
        then
          reject
            t
            id
            "Saved Timing path not restored: run/source identity changed or was not \
             recorded; select a path explicitly"
        else (
          let index =
            Option.bind snapshot ~f:(fun snapshot ->
              List.find
                snapshot.Asic.Snapshot.inspections
                ~f:(Inspection_view.matches_index view))
          in
          match index with
          | None -> t
          | Some index ->
            if (not
                  (Option.equal
                     String.equal
                     saved.source_digest
                     (Some index.source_digest)))
               || not
                    (List.exists index.rows ~f:(fun row ->
                       Option.equal String.equal saved.row_id (Some row.id)))
            then
              reject
                t
                id
                "Saved Timing path not restored: source digest or path changed; select a \
                 path explicitly"
            else (
              let view = { view with selected = saved.row_id; error = None } in
              let view =
                Option.value_map
                  snapshot
                  ~default:view
                  ~f:(Timing_workspace.attach_retained view)
              in
              set_timing (cancel_navigation_timing t id) tile view)))
  in
  let t =
    List.fold t.timing_restore ~init:t ~f:(fun t (id, _) ->
      match find t id with
      | None -> t
      | Some (tile, view) ->
        set_timing t tile { view with selected = None; requested = None; detail = None })
  in
  List.fold t.timing_rejected ~init:t ~f:(fun t (id, message) ->
    match find t id with
    | None -> t
    | Some (tile, view) ->
      set_timing
        t
        tile
        { view with
          selected = None
        ; requested = None
        ; detail = None
        ; error = Some message
        })
;;

let%test_unit "workspace roundtrip cannot revive a pending stage preparation" =
  let registry = W.initial ~session_id:(W.Session_id.of_string "stage-roundtrip") in
  let host = receive empty registry in
  let original = Option.value_exn host.active in
  let other =
    List.find_exn registry.workspaces ~f:(fun workspace ->
      not (W.Workspace_id.equal workspace.id original))
  in
  let host =
    { host with stage_preparation = Some "Preparing routing"; stage_generation = 3 }
  in
  let switched = switch host other.id in
  let restored = switch switched original in
  assert (Option.equal W.Workspace_id.equal restored.active host.active);
  assert (restored.stage_generation > host.stage_generation);
  assert (
    String.is_substring
      (Option.value_exn restored.stage_preparation)
      ~substring:"context changed")
;;

let%test_unit "Timing reconnect keeps investigation until pane or session identity \
               changes"
  =
  let apply snapshot mutation =
    W.apply
      snapshot
      (Mutate { expected_revision = snapshot.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let registry = W.initial ~session_id:(W.Session_id.of_string "timing-reconnect") in
  let workspace = List.last_exn registry.workspaces in
  let context = W.context registry workspace.context in
  let registry =
    apply
      registry
      (Select_run
         { workspace = workspace.id
         ; context = context.id
         ; expected_selection_revision = context.selection_revision
         ; run = Some Fs0_fixture.run_a
         })
    |> fun registry ->
    apply registry (P.Definition.apply P.Timing.definition ~workspace:workspace.id)
  in
  let tile =
    List.find_exn registry.tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace workspace.id
      && String.equal tile.kind "timing-paths")
  in
  let host = switch (receive empty registry) workspace.id in
  let view =
    { (Timing_workspace.create ~generation:5 ~run:Fs0_fixture.run_a ~stage:"signoff") with
      filter = "critical endpoint"
    ; selected = Some "chosen-row"
    ; scroll = 7
    }
  in
  let host = set_timing host tile view in
  let reconnected = reconnect host ~replacement:false in
  let refreshed =
    receive reconnected { registry with revision = registry.revision + 1 }
  in
  let view = Option.value_exn (timing refreshed tile) in
  assert (String.equal view.filter "critical endpoint" && view.scroll = 7);
  assert (Option.equal String.equal view.selected (Some "chosen-row"));
  assert (view.generation > 5);
  let retyped =
    receive
      refreshed
      { registry with
        revision = registry.revision + 2
      ; tiles =
          List.map registry.tiles ~f:(fun candidate ->
            if W.Tile_id.equal candidate.id tile.id
            then { candidate with kind = "timing-detail" }
            else candidate)
      }
  in
  let invalidated =
    List.Assoc.find_exn
      retyped.timing
      ~equal:String.equal
      (W.Workspace_id.to_string workspace.id)
  in
  assert (invalidated.generation > view.generation);
  assert (
    Option.is_none invalidated.selected && Option.is_none invalidated.workspace_epoch)
;;

(** Cursor identity is a registry ID, never a display name or an ordinal. An unset or
    removed cursor starts from the active workspace. Browsing is client-local. *)
let workspace_choices t id =
  let filter = String.lowercase (local t id).filter in
  Option.value_map t.registry ~default:[] ~f:(fun s ->
    List.filter s.workspaces ~f:(fun w ->
      String.is_substring
        (String.lowercase (w.name ^ " " ^ W.Workspace_id.to_string w.id))
        ~substring:filter))
;;

let workspace_cursor t id =
  let choices = workspace_choices t id in
  let selected =
    Option.bind (local t id).cursor ~f:(fun cursor ->
      List.find choices ~f:(fun w -> String.equal cursor (W.Workspace_id.to_string w.id)))
  in
  Option.first_some
    selected
    (Option.bind t.active ~f:(fun active ->
       List.find choices ~f:(fun w -> W.Workspace_id.equal active w.id)))
;;

let browse_workspaces t id ~delta =
  let choices = workspace_choices t id in
  let index =
    Option.bind (workspace_cursor t id) ~f:(fun selected ->
      List.findi choices ~f:(fun _ w -> W.Workspace_id.equal selected.id w.id)
      |> Option.map ~f:fst)
    |> Option.value ~default:(if delta > 0 then -1 else 1)
  in
  let index = Int.max 0 (Int.min (List.length choices - 1) (index + delta)) in
  let cursor =
    Option.map (List.nth choices index) ~f:(fun w -> W.Workspace_id.to_string w.id)
  in
  let l = local t id in
  set_local t id { l with cursor; scroll = index }
;;

let current t (c : capture) =
  match capture t with
  | None -> false
  | Some now ->
    W.Session_id.equal c.session now.session
    && c.revision = now.revision
    && W.Workspace_id.equal c.workspace now.workspace
;;

let command ?unavailable id title aliases action =
  { id; title; aliases; action; unavailable }
;;

let testing_launch_command t id =
  let action = testing_launch_action t id in
  let unavailable =
    match action with
    | Testing_launch_unavailable reason -> Some reason
    | _ -> None
  in
  command
    ?unavailable
    "simulation.catalog-launch"
    "Simulation: Launch selected catalog subset"
    "suite seed parameters cases"
    action
;;

let simulation_log_commands (tile : W.Tile.t) =
  if Testing_workspace.is_pane tile.kind
  then []
  else
    [ command
        "simulation.logs"
        "Simulation: Toggle stream-labelled job logs"
        "stdout stderr"
        (Simulation_logs tile.id)
    ]
;;

let asic_launch_commands t ~preview ~view_pending =
  let model = Planned_run.model t.planned_run in
  let unavailable =
    Option.first_some
      t.stage_preparation
      (match preview with
       | None ->
         Some
           ("No preview: "
            ^ model.message
            ^ "; focus checklist and press r to prepare; reopen palette when ready")
       | Some preview when Planned_run.launchable t.planned_run preview -> None
       | Some _ ->
         Some
           (model.message
            ^ "; "
            ^ model.launch.message
            ^ "; prepare again if failed/stale; reopen palette when ready"))
  in
  List.map
    [ "asic.launch", "Launch planned run without view", false
    ; "asic.launch-view", "Launch and view planned run in captured context", true
    ]
    ~f:(fun (id, title, view) ->
      let title, action =
        match preview with
        | None -> title, Unavailable_launch
        | Some preview ->
          ( sprintf
              "%s %s / %s → %s [%s]"
              title
              preview.selection.flow
              preview.selection.profile
              preview.selection.endpoint
              preview.plan_identity
            |> Artifact_view.safe
          , Launch_asic (preview, view) )
      in
      command
        ?unavailable:
          (if view && view_pending
           then Some "Another launch-and-view is awaiting allocation"
           else unavailable)
        id
        title
        "run synth launch"
        action)
;;

let legacy_launch_commands t ~preview ~view_pending =
  match
    Option.bind t.preparation ~f:(fun s ->
      if t.planned_preparation then Preparation_view.staged_available s else None)
  with
  | Some staged ->
    let unavailable =
      Option.first_some
        t.stage_preparation
        (if Option.exists t.preparation ~f:(fun s ->
              Option.exists s.latest ~f:Preparation_view.active)
         then Some "Preparation already active; staging does not submit another producer"
         else None)
    in
    List.map
      [ "asic.launch", "Launch planned PREPARATION without view"
      ; ( "asic.launch-view"
        , "Launch and view planned PREPARATION (context retained; no ASIC allocation)" )
      ]
      ~f:(fun (id, title) ->
        command
          ?unavailable
          id
          (title ^ " [" ^ staged.id ^ "]")
          "launch staged preparation input plan"
          (Launch_preparation staged.id))
  | None
    when t.planned_preparation
         && Option.exists t.preparation ~f:(fun s -> Option.is_some s.staged) ->
    List.map
      [ "asic.launch", "Launch planned PREPARATION without view"
      ; "asic.launch-view", "Launch and view planned PREPARATION"
      ]
      ~f:(fun (id, title) ->
        command
          ~unavailable:"PREPARATION input plan consumed/stale; stage again with r"
          id
          (title ^ " (consumed/stale)")
          "launch"
          Unavailable_launch)
  | None -> asic_launch_commands t ~preview ~view_pending
;;

let launch_commands t ~preview ~view_pending =
  match Planned_run.fresh_intent t.planned_run with
  | None -> legacy_launch_commands t ~preview ~view_pending
  | Some intent ->
    List.map
      [ "asic.launch", "Launch planned run without view", false
      ; "asic.launch-view", "Launch and view planned run in captured context", true
      ]
      ~f:(fun (id, title, view) ->
        command
          ?unavailable:
            (if view && view_pending
             then Some "Another launch-and-view is awaiting allocation"
             else if Option.is_some t.stage_preparation
             then t.stage_preparation
             else if Planned_run.fresh_launchable t.planned_run intent
             then None
             else Some (Planned_run.model t.planned_run).message)
          id
          (title
           ^ " — "
           ^ if intent.elaboration_only then "Elaboration" else intent.selection.endpoint
          )
          "fresh source build emit workflow"
          (Launch_fresh_intent (intent, view)))
;;

let%test_unit "Launch remains searchable without preview and preserves captured disabled \
               reasons"
  =
  let commands = launch_commands empty ~preview:None ~view_pending:false in
  assert (List.length commands = 2);
  List.iter commands ~f:(fun command ->
    assert (Option.is_some command.unavailable);
    match command.action with
    | Unavailable_launch -> ()
    | _ -> assert false);
  let reason = "Preparing NEW run through routing; reopen palette when ready" in
  let pending =
    launch_commands
      { empty with stage_preparation = Some reason }
      ~preview:None
      ~view_pending:false
  in
  assert (
    List.for_all pending ~f:(fun command ->
      Option.equal String.equal command.unavailable (Some reason)));
  (* A palette captures availability. It cannot silently promote an unavailable command to
     a newly arrived preview on Enter. *)
  assert (
    List.for_all pending ~f:(fun command ->
      String.is_substring (Option.value_exn command.unavailable) ~substring:"reopen"));
  let ranked =
    Palette_search.rank
      ~query:"launch"
      (List.map commands ~f:(fun command ->
         command, [ { Palette_search.text = command.title; weight = 100 } ]))
  in
  assert (List.length ranked = 2)
;;

let%test_unit "launch catalog captures exact ready preview and explains pending failed \
               stale states"
  =
  let selection : Asic.Selection.t =
    { flow = "standard"
    ; profile = "balanced"
    ; endpoint = "routing"
    ; assignments = [ "CLK=9" ]
    }
  in
  let preview : Asic.Preview.t =
    { selection; plan_identity = "exact-routing-plan"; plan_json = "{}" }
  in
  let key = List.hd_exn (Plain_rpc.keys (Plan selection) Fs0_fixture.snapshot) in
  let snapshot =
    { Fs0_fixture.snapshot with
      preview = Some preview
    ; operations =
        [ { key
          ; kind = "plan"
          ; state = "completed"
          ; run = None
          ; error = None
          ; activity = Unreported
          }
        ]
    }
  in
  let ready =
    { empty with
      planned_run = Planned_run.receive empty.planned_run ~revision:1 snapshot
    }
  in
  let commands host = launch_commands host ~preview:(Some preview) ~view_pending:false in
  List.iter (commands ready) ~f:(fun command ->
    assert (Option.is_none command.unavailable);
    match command.action with
    | Launch_asic (actual, _) -> assert (Asic.Preview.equal preview actual)
    | _ -> assert false);
  let planned_run, ticket =
    Planned_run.begin_plan ready.planned_run { selection with endpoint = "signoff" }
  in
  let pending = { ready with planned_run } in
  let failed =
    { pending with
      planned_run =
        Planned_run.receipt
          planned_run
          ticket
          ~floor:2
          (Error "provider rejected captured plan")
    }
  in
  let stale =
    { ready with
      planned_run =
        Planned_run.receive
          ready.planned_run
          ~revision:2
          { snapshot with operations = [] }
    }
  in
  List.iter
    [ pending
    ; failed
    ; stale
    ; { ready with stage_preparation = Some "Preparing routing" }
    ]
    ~f:(fun host ->
      List.iter (commands host) ~f:(fun command ->
        assert (Option.is_some command.unavailable)))
;;

let set_appearance t appearance = { t with appearance }

let appearance_commands t =
  let make key label selected appearance =
    command
      ("appearance." ^ key)
      ("Appearance: " ^ label ^ if selected then " [active]" else "")
      "theme style skin colors icons density preset"
      (Set_appearance appearance)
  in
  List.map Appearance.Scheme.all ~f:(fun scheme ->
    command
      ("appearance.scheme." ^ Appearance.Scheme.key scheme)
      ("Color scheme: "
       ^ Appearance.Scheme.label scheme
       ^ if Appearance.Scheme.equal scheme t.appearance.scheme then " [active]" else "")
      "theme palette background colors client local"
      (Set_appearance { t.appearance with scheme }))
  @ List.map Appearance.Preset.all ~f:(fun preset ->
    make
      ("preset." ^ Appearance.Preset.key preset)
      (Appearance.Preset.label preset)
      (Appearance.Preset.equal preset t.appearance.preset)
      { t.appearance with preset })
  @ List.map Appearance.Color.all ~f:(fun color ->
    make
      ("color." ^ Appearance.Color.key color)
      ("Color " ^ Appearance.Color.label color)
      (Appearance.Color.equal color t.appearance.color)
      { t.appearance with color })
  @ List.map Appearance.Icons.all ~f:(fun icons ->
    make
      ("icons." ^ Appearance.Icons.key icons)
      ("Icons " ^ Appearance.Icons.label icons)
      (Appearance.Icons.equal icons t.appearance.icons)
      { t.appearance with icons })
  @ List.map Appearance.Density.all ~f:(fun density ->
    make
      ("density." ^ Appearance.Density.key density)
      ("Density " ^ Appearance.Density.label density)
      (Appearance.Density.equal density t.appearance.density)
      { t.appearance with density })
;;

let%test_unit "appearance commands change only client-local style" =
  let registry = W.initial ~session_id:(W.Session_id.of_string "appearance-test") in
  let host = receive empty registry in
  let host =
    { host with
      appearance = { host.appearance with color = Restrained; icons = Unicode }
    }
  in
  let tile = List.hd_exn registry.tiles in
  let host =
    set_local host tile.id { default_local with scroll = 7; filter = "retained" }
  in
  let commands = appearance_commands host in
  let command =
    List.find_exn commands ~f:(fun c -> String.equal c.id "appearance.preset.studio")
  in
  match command.action with
  | Set_appearance appearance ->
    let changed = set_appearance host appearance in
    assert (Appearance.Preset.equal changed.appearance.preset Studio);
    assert (Appearance.Color.equal changed.appearance.color Restrained);
    assert (Appearance.Icons.equal changed.appearance.icons Unicode);
    assert (phys_equal changed.registry host.registry);
    assert (phys_equal changed.active host.active);
    assert (phys_equal changed.focus host.focus);
    assert (phys_equal changed.locals host.locals)
  | _ -> assert false
;;

let asic_cancel_commands (snapshot : Asic.Snapshot.t) =
  List.filter_map snapshot.operations ~f:(fun operation ->
    if Asic_intents.cancellable operation
    then
      Some
        (command
           ("asic.cancel." ^ operation.key)
           ("Cancel ASIC operation " ^ operation.key)
           "stop"
           (Asic (Cancel operation.key)))
    else None)
;;

let project_scoped_kind kind =
  Testing_workspace.is_pane kind
  || P.Waveforms.is_pane kind
  || List.mem
       [ "simulation"
       ; "workloads"
       ; "hierarchy"
       ; "execution"
       ; "project-tests"
       ; "logs"
       ; "project"
       ; "navigation"
       ; "asic"
       ; "live-status"
       ; "workspace-tabs"
       ; "planned-run"
       ]
       kind
       ~equal:String.equal
;;

let job_attempt_kind kind =
  List.mem [ "execution"; "project-tests"; "logs" ] kind ~equal:String.equal
;;

let evidence_runs t =
  match t.registry with
  | None -> []
  | Some registry ->
    tiles t
    |> List.filter ~f:(fun tile ->
      (not (project_scoped_kind tile.kind))
      && (not (Resources_view.is_kind tile.kind))
      && not (String.equal tile.kind "run-selector"))
    |> List.filter_map ~f:(fun tile ->
      W.resolve_tile registry tile.id
      |> Result.ok
      |> Option.bind ~f:(fun reference -> reference.run))
    |> List.dedup_and_sort ~compare:Run_ref.compare
;;

let definition = P.Presets.for_arrangement

let provenance t workspace =
  Option.bind t.registry ~f:(fun registry ->
    List.find registry.config_workspaces ~f:(fun p ->
      W.Workspace_id.equal p.workspace workspace
      && (not p.policy_detached)
      &&
      match p.reference, (W.workspace registry workspace).preset with
      | Custom _, None -> true
      | Builtin key, Some preset -> String.equal key preset
      | _ -> false))
;;

let render_definition t (workspace : W.Arrangement.t) =
  match provenance t workspace.id with
  | Some p -> Some (P.Definition.of_spec p.definition)
  | None -> definition workspace
;;

let configured_tile (p : W.Config_workspace.t) (tile : W.Tile.t) =
  List.find_map p.tiles ~f:(fun (key, id) ->
    if W.Tile_id.equal id tile.id && W.Workspace_id.equal p.workspace tile.workspace
    then
      List.find_map
        (List.zip_exn p.definition.tiles p.definition.template.views)
        ~f:(fun (keyed, view) ->
          if String.equal keyed.Workspace_config.Tile.key key
             && String.equal view.Workspace_template.View.kind tile.kind
          then Some keyed
          else None)
    else None)
;;

(** Runtime identities, never display order or kind, select configured leaves. Extra tiles
    use an unclaimable label and remain visible through the normal extras path. *)
let layout_keys t (tiles : W.Tile.t list) =
  let claimed = Hash_set.create (module String) in
  List.map tiles ~f:(fun tile ->
    let key =
      match provenance t tile.workspace with
      | Some p -> Option.map (configured_tile p tile) ~f:(fun keyed -> keyed.key)
      | None ->
        (* Legacy builtin instances have no authoring IDs. Adapt their first visible
           occurrences by kind; the stock author is still free to choose any keys. *)
        Option.bind t.registry ~f:(fun registry ->
          let workspace = W.workspace registry tile.workspace in
          Option.bind workspace.preset ~f:(fun preset ->
            P.Presets.builtins preset
            |> Result.ok
            |> Option.bind ~f:(fun d ->
              List.find_map
                (List.zip_exn d.tiles d.template.views)
                ~f:(fun (keyed, view) ->
                  let claim = W.Workspace_id.to_string tile.workspace ^ ":" ^ keyed.key in
                  if String.equal view.Workspace_template.View.kind tile.kind
                     && not (Hash_set.mem claimed claim)
                  then (
                    Hash_set.add claimed claim;
                    Some keyed.Workspace_config.Tile.key)
                  else None))))
    in
    Option.value key ~default:("extra:" ^ W.Tile_id.to_string tile.id))
;;

(** Fit follows semantic tree order even when placement falls back to a grid or Compact.
    Preferred packs in registry order. Keep [tiles] unchanged for callers that associate
    its indices with rendered geometry. *)
let navigation_tiles t =
  let eligible = tiles t in
  match t.layout_mode, active t with
  | Fit, Some workspace ->
    (match render_definition t workspace with
     | None -> eligible
     | Some definition ->
       let indexed = Array.of_list eligible in
       P.Layout.navigation_order definition ~kinds:(layout_keys t eligible)
       |> List.map ~f:(fun index -> indexed.(index)))
  | _ -> eligible
;;

let restore_commands (workspace : W.Arrangement.t) =
  let make ?unavailable id title action =
    command ?unavailable id title "restore default preset layout hide extras fit" action
  in
  List.map P.Presets.all ~f:(fun d ->
    make
      ("workspace.restore-default-layout." ^ d.P.Definition.id)
      ("Restore default layout: " ^ d.name ^ " (hide extras)")
      (Restore_default_layout (workspace.id, d)))
  @ [ make
        ?unavailable:
          (if Option.is_none (definition workspace)
           then
             Some
               "No built-in preset for this workspace; create a built-in workspace or \
                explicitly select a named built-in Restore (not a reset to custom \
                defaults)"
           else None)
        "workspace.restore-default-layout"
        "Restore default layout (current preset; hide extras)"
        (Option.value_map
           (definition workspace)
           ~default:Restore_default_layout_unavailable
           ~f:(fun d -> Restore_default_layout (workspace.id, d)))
    ]
;;

let%test_unit "restore commands capture named definitions and stable current preset, \
               never names"
  =
  let registry = W.initial ~session_id:(W.Session_id.of_string "restore-commands") in
  let workspace =
    { (List.hd_exn registry.workspaces) with name = "Testing"; preset = Some "timing" }
  in
  let commands = restore_commands workspace in
  assert (List.length commands = List.length P.Presets.all + 1);
  List.iter P.Presets.all ~f:(fun definition ->
    let command =
      List.find_exn commands ~f:(fun command ->
        String.equal
          command.id
          ("workspace.restore-default-layout." ^ definition.P.Definition.id))
    in
    assert (Option.is_none command.unavailable);
    assert (
      String.equal
        command.title
        ("Restore default layout: " ^ definition.name ^ " (hide extras)"));
    match command.action with
    | Restore_default_layout (id, captured) ->
      assert (W.Workspace_id.equal id workspace.id);
      assert (phys_equal captured definition)
    | _ -> assert false);
  let current commands = List.last_exn commands in
  (match (current commands).action with
   | Restore_default_layout (id, definition) ->
     assert (W.Workspace_id.equal id workspace.id);
     assert (String.equal definition.id "timing")
   | _ -> assert false);
  List.iter [ None; Some "unknown" ] ~f:(fun preset ->
    let commands = restore_commands { workspace with name = "Overview"; preset } in
    assert (Option.is_some (current commands).unavailable);
    assert (
      List.for_all
        (List.take commands (List.length P.Presets.all))
        ~f:(fun command -> Option.is_none command.unavailable));
    match (current commands).action with
    | Restore_default_layout_unavailable -> ()
    | _ -> assert false)
;;

let%test_unit "restore Fit requires acknowledgement and current local intent, preserving \
               preferences"
  =
  let registry = W.initial ~session_id:(W.Session_id.of_string "restore-receipts") in
  let host = receive empty registry |> fun host -> set_layout_mode host Preferred in
  let tile = List.hd_exn registry.tiles in
  let host =
    set_local
      host
      tile.id
      { (local host tile.id) with presentation = { T.inherit_ with header = Some false } }
  in
  let host =
    { host with
      chrome = false
    ; appearance = { host.appearance with icons = Unicode }
    ; presentation = { T.inherit_ with header = Some false }
    ; workspace_presentation =
        [ W.Workspace_id.to_string (Option.value_exn host.active), T.inherit_ ]
    }
  in
  let captured = Option.value_exn (capture host) in
  let pending, ticket = begin_restore host captured in
  let failed, save = finish_restore pending ticket ~acknowledged:false in
  assert ((not save) && equal_layout_mode failed.layout_mode Preferred);
  let late, save = finish_restore failed ticket ~acknowledged:true in
  assert ((not save) && equal_layout_mode late.layout_mode Preferred);
  let success, save =
    finish_restore
      (receive pending { registry with revision = registry.revision + 1 })
      ticket
      ~acknowledged:true
  in
  assert (save && equal_layout_mode success.layout_mode Fit);
  assert (Appearance.equal success.appearance host.appearance);
  assert (Bool.equal success.chrome host.chrome);
  assert (phys_equal success.presentation host.presentation);
  assert (
    List.equal
      [%equal: string * T.overrides]
      success.workspace_presentation
      host.workspace_presentation);
  assert (phys_equal (local success tile.id) (local host tile.id));
  let other =
    List.find_exn registry.workspaces ~f:(fun workspace ->
      not (W.Workspace_id.equal workspace.id captured.workspace))
  in
  let superseded, _ = begin_restore pending captured in
  List.iter
    [ set_layout_mode pending Preferred (* Even choosing the same value supersedes. *)
    ; set_layout_mode (set_layout_mode pending Fit) Preferred
    ; superseded
    ; switch (switch pending other.id) captured.workspace
    ; reconnect pending ~replacement:false
    ; invalidate_layout_intent pending (* canonical project change *)
    ; receive pending { registry with session_id = W.Session_id.of_string "replacement" }
    ]
    ~f:(fun host ->
      let completed, save = finish_restore host ticket ~acknowledged:true in
      assert (not save);
      assert (equal_layout_mode completed.layout_mode host.layout_mode));
  let _, save = finish_restore success ticket ~acknowledged:true in
  assert (not save)
;;

let%test_unit "restore capture rejects revision and workspace changes without \
               retargeting definitions"
  =
  let registry = W.initial ~session_id:(W.Session_id.of_string "restore-capture") in
  let host = receive empty registry in
  let captured = Option.value_exn (capture host) in
  let workspace = Option.value_exn (active host) in
  let command = List.hd_exn (restore_commands workspace) in
  let other =
    List.find_exn registry.workspaces ~f:(fun workspace ->
      not (W.Workspace_id.equal workspace.id captured.workspace))
  in
  assert (current host captured);
  assert (not (current (switch host other.id) captured));
  assert (
    not
      (current (receive host { registry with revision = registry.revision + 1 }) captured));
  assert (
    not
      (current
         (receive
            host
            { registry with session_id = W.Session_id.of_string "new-session" })
         captured));
  match command.action with
  | Restore_default_layout (workspace, definition) ->
    assert (W.Workspace_id.equal workspace captured.workspace);
    assert (String.equal definition.id "overview");
    (match P.Definition.restore definition ~workspace with
     | Restore_default_layout { workspace; preset; tiles } ->
       assert (W.Workspace_id.equal workspace captured.workspace);
       assert (String.equal preset "overview");
       assert (
         List.equal [%equal: string * W.Geometry.t] tiles (P.Definition.specs definition))
     | _ -> assert false)
  | _ -> assert false
;;

let matching_timing ?workspace:expected_workspace (registry : W.Snapshot.t) ~run =
  List.find registry.workspaces ~f:(fun workspace ->
    Option.value_map
      expected_workspace
      ~default:true
      ~f:(W.Workspace_id.equal workspace.id)
    && Option.value_map workspace.zoomed_tile ~default:true ~f:(fun id ->
      List.exists registry.tiles ~f:(fun tile ->
        W.Tile_id.equal tile.id id
        && String.equal tile.kind "timing-paths"
        && not tile.hidden))
    && (let paths =
          List.filter registry.tiles ~f:(fun tile ->
            W.Workspace_id.equal tile.workspace workspace.id
            && String.equal tile.kind "timing-paths")
        in
        List.exists paths ~f:(fun tile -> not tile.hidden))
    && List.for_all registry.tiles ~f:(fun tile ->
      (not (W.Workspace_id.equal tile.workspace workspace.id))
      || Option.is_none (Timing_workspace.pane tile.kind)
      ||
      match W.resolve_tile registry tile.id with
      | Ok reference -> Option.equal Run_ref.equal reference.run (Some run)
      | Error _ -> false))
;;

let matching_timing_analysis t registry ~run ~analysis =
  List.find_map registry.W.Snapshot.workspaces ~f:(fun workspace ->
    matching_timing ~workspace:workspace.id registry ~run
    |> Option.filter ~f:(fun w ->
      Option.equal
        Asic_inspection.Analysis_target.equal
        analysis
        (List.Assoc.find t.timing (W.Workspace_id.to_string w.id) ~equal:String.equal
         |> Option.bind ~f:(fun view -> view.Inspection_view.analysis))))
;;

(** Config identity survives renaming. Legacy saved stock workspaces have no mapping. *)
let builtin_timing_workspaces (registry : W.Snapshot.t) =
  List.filter registry.workspaces ~f:(fun workspace ->
    List.exists registry.config_workspaces ~f:(fun origin ->
      W.Workspace_id.equal origin.workspace workspace.id
      && String.equal origin.config_id "stock"
      && String.equal origin.workspace_key "timing")
    || ((not
           (List.exists registry.config_workspaces ~f:(fun origin ->
              W.Workspace_id.equal origin.workspace workspace.id)))
        && String.equal workspace.name "Timing"
        && Option.equal String.equal workspace.preset (Some "timing")))
;;

let builtin_timing_in_window registry ~window =
  List.find (builtin_timing_workspaces registry) ~f:(fun workspace ->
    W.Window_id.equal workspace.window window)
;;

(** Pure, provider-free hidden hydration. Only coherent pane bindings may share state. No
    activation, focus, registry selection or pin mutation. Exact target changes reset all
    source-local state; unchanged targets retain filters/selection and cached rows. *)
let reconcile_builtin_timing t snapshot =
  match t.registry with
  | None -> t
  | Some _ when Option.is_none snapshot -> t
  | Some registry ->
    List.fold (builtin_timing_workspaces registry) ~init:t ~f:(fun t workspace ->
      let panes =
        List.filter registry.tiles ~f:(fun tile ->
          W.Workspace_id.equal tile.workspace workspace.id
          && Option.is_some (Timing_workspace.pane tile.kind))
      in
      match List.find panes ~f:(fun tile -> String.equal tile.kind "timing-paths") with
      | None -> t
      | Some tile ->
        let run =
          W.resolve_tile registry tile.id
          |> Result.ok
          |> Option.bind ~f:(fun reference -> reference.run)
        in
        (match run with
         | None -> t
         | Some run ->
           if not
                (List.for_all panes ~f:(fun pane ->
                   match W.resolve_tile registry pane.id with
                   | Ok reference -> Option.equal Run_ref.equal reference.run (Some run)
                   | Error _ -> false))
           then t
           else (
             let stage, analysis =
               Overview_tiles.timing_inspection_target ~asic:snapshot ~run
             in
             let previous =
               List.Assoc.find
                 t.timing
                 (W.Workspace_id.to_string workspace.id)
                 ~equal:String.equal
             in
             let view =
               timing t tile
               |> Option.filter ~f:(fun view ->
                 String.equal view.stage stage
                 && Option.equal
                      Asic_inspection.Analysis_target.equal
                      view.analysis
                      analysis)
               |> Option.value
                    ~default:
                      (Timing_workspace.with_analysis
                         (Timing_workspace.create
                            ~generation:
                              (Option.value_map previous ~default:0 ~f:(fun v ->
                                 v.generation + 1))
                            ~run
                            ~stage)
                         analysis)
             in
             let view =
               Option.value_map snapshot ~default:view ~f:(fun snapshot ->
                 if Option.is_none view.index
                 then Timing_workspace.attach_retained view snapshot
                 else Inspection_view.reconcile view snapshot)
             in
             set_timing t tile view)))
;;

let%test_unit "Timing exact-run reuse preserves pins and independent investigations" =
  let apply s mutation =
    W.apply s (Mutate { expected_revision = s.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let choose s workspace run =
    let w = W.workspace s workspace in
    let c = W.context s w.context in
    apply
      s
      (Select_run
         { workspace
         ; context = c.id
         ; expected_selection_revision = c.selection_revision
         ; run = Some run
         })
  in
  let s = W.initial ~session_id:(W.Session_id.of_string "timing-investigations") in
  let main = List.hd_exn s.workspaces in
  let timing_workspace = List.last_exn s.workspaces in
  let s =
    apply s (P.Definition.apply P.Timing.definition ~workspace:timing_workspace.id)
  in
  let s = choose s main.id Fs0_fixture.run_a in
  assert (Option.is_some (matching_timing s ~run:Fs0_fixture.run_a));
  assert (Option.is_none (matching_timing s ~run:Fs0_fixture.run_b));
  let path =
    List.find_exn s.tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace timing_workspace.id
      && String.equal tile.kind "timing-paths")
  in
  let s =
    apply s (Set_tile_binding { tile = path.id; binding = Pin_run Fs0_fixture.run_b })
  in
  assert (Option.is_none (matching_timing s ~run:Fs0_fixture.run_a));
  let s =
    apply
      s
      (Create_workspace
         { window = main.window; name = "Captured B"; context = main.context })
  in
  let independent = List.last_exn s.workspaces in
  let s = apply s (Make_independent independent.id) in
  let s = choose s independent.id Fs0_fixture.run_b in
  let s = apply s (P.Definition.apply P.Timing.definition ~workspace:independent.id) in
  assert (
    Option.equal
      Run_ref.equal
      (W.context s main.context).selected_run
      (Some Fs0_fixture.run_a));
  assert (
    W.Binding.equal
      (List.find_exn s.tiles ~f:(fun tile -> W.Tile_id.equal path.id tile.id)).binding
      (Pin_run Fs0_fixture.run_b));
  let second =
    List.find_exn s.tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace independent.id
      && String.equal tile.kind "timing-paths")
  in
  let host = receive empty s in
  let host =
    set_timing
      host
      path
      (Timing_workspace.create ~generation:1 ~run:Fs0_fixture.run_a ~stage:"signoff")
  in
  let host =
    set_timing
      host
      second
      (Timing_workspace.create ~generation:1 ~run:Fs0_fixture.run_b ~stage:"routing")
  in
  assert (Option.is_none (timing host path));
  assert (String.equal (Option.value_exn (timing host second)).stage "routing");
  let view = Option.value_exn (timing host second) in
  let view = { view with requested = Some ("digest", "row") } in
  let host = set_timing host second view in
  let ticket =
    Inspection_view.capture
      view
      (Inspect_detail
         { run = Fs0_fixture.run_b
         ; domain = "timing"
         ; stage = "routing"
         ; source_digest = "digest"
         ; row_id = "row"
         })
  in
  let pinned =
    apply s (Set_tile_binding { tile = second.id; binding = Pin_run Fs0_fixture.run_b })
  in
  let invalid = receive host pinned in
  assert (Option.is_none (timing invalid second));
  let unpinned = apply pinned (Set_tile_binding { tile = second.id; binding = Follow }) in
  let invalid = receive invalid unpinned in
  assert (Option.is_none (timing invalid second));
  let old_view =
    List.Assoc.find_exn
      invalid.timing
      (W.Workspace_id.to_string independent.id)
      ~equal:String.equal
  in
  assert (Option.is_none old_view.requested);
  assert (
    Option.is_none
      (Inspection_view.apply_response old_view ticket (Error "late before pin roundtrip"))
        .error);
  assert (Option.is_some (timing (receive host s) second));
  let hidden = apply s (Set_tile_hidden { tile = second.id; hidden = true }) in
  assert (Option.is_none (matching_timing hidden ~run:Fs0_fixture.run_b));
  let detail =
    List.find_exn s.tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace independent.id
      && String.equal tile.kind "timing-detail")
  in
  let zoomed = apply s (Set_zoom { workspace = independent.id; tile = Some detail.id }) in
  assert (Option.is_none (matching_timing zoomed ~run:Fs0_fixture.run_b));
  let host = set_local host second.id { default_local with scroll = 9 } in
  assert ((local host path.id).scroll = 0);
  assert ((local host second.id).scroll = 9);
  let switched = choose s independent.id Fs0_fixture.run_a in
  let changed = receive host switched in
  assert (Option.is_none (timing changed second));
  let switched_back = choose switched independent.id Fs0_fixture.run_b in
  assert (Option.is_none (timing (receive changed switched_back) second))
;;

let default_tile_specs ~workspace_name =
  List.find P.Presets.all ~f:(fun d -> String.equal d.P.Definition.name workspace_name)
  |> Option.value_map ~default:[] ~f:(fun d ->
    P.Definition.specs d
    |> List.map ~f:(fun (kind, g) -> kind, g.W.Geometry.width, g.height))
;;

(** Additive preset: hidden tiles count as existing. Never rewrite a saved binding,
    selection, requested geometry, ordering, zoom, or context to install a preset. *)
let missing_default_tiles (snapshot : W.Snapshot.t) (workspace : W.Arrangement.t) =
  Option.value_map (definition workspace) ~default:[] ~f:P.Definition.specs
  |> List.filter_map ~f:(fun (kind, geometry) ->
    if List.exists snapshot.tiles ~f:(fun tile ->
         W.Workspace_id.equal tile.workspace workspace.id && String.equal tile.kind kind)
    then None
    else Some (W.Mutation.Create_tile { workspace = workspace.id; kind; geometry }))
;;

let preset_presentation (p : P.Common.presentation) : T.overrides =
  { T.inherit_ with
    title = p.title
  ; run_reference = p.run_reference
  ; freshness = p.freshness
  ; hints = p.hints
  ; frame = p.frame
  ; padding = p.padding
  ; run_selector_rows = p.visible_rows
  ; string_compression = p.string_compression
  ; decimal_places = p.decimal_places
  ; badge =
      Option.bind p.binding_badge ~f:(function
        | "hidden" -> Some T.Badge.Hidden
        | "always" -> Some T.Badge.Always
        | "exceptions" -> Some T.Badge.Exceptions
        | _ -> None)
  }
;;

(** Neutral composition modes are sparse preset policy, independent of chrome. *)
let composition_policy t (tile : W.Tile.t) =
  let presentation =
    match provenance t tile.workspace with
    | Some p -> Option.bind (configured_tile p tile) ~f:(fun keyed -> keyed.presentation)
    | None ->
      Option.bind t.registry ~f:(fun registry ->
        List.find registry.workspaces ~f:(fun w ->
          W.Workspace_id.equal w.id tile.workspace))
      |> Option.bind ~f:definition
      |> Option.bind ~f:(fun d -> P.Definition.presentation d ~kind:tile.kind)
  in
  Option.value presentation ~default:P.Common.inherit_presentation
;;

let compact_summary t tile =
  Option.value (composition_policy t tile).compact_summary ~default:false
;;

let horizontal_stages t tile =
  Option.value (composition_policy t tile).horizontal_stages ~default:false
;;

let%test_unit "persisted config keys survive reorder, hide and duplicate tile kinds" =
  let config =
    P.Presets.custom_example () |> Or_error.ok_exn |> P.Presets.resolve |> Or_error.ok_exn
  in
  let registry = W.initial ~session_id:(W.Session_id.of_string "keyed-layout") in
  let registry =
    W.apply registry (Initialize_config config) |> Result.ok |> Option.value_exn
  in
  let workspace = List.hd_exn registry.workspaces in
  let p = List.hd_exn registry.config_workspaces in
  let tile key = W.tile registry (List.Assoc.find_exn p.tiles key ~equal:String.equal) in
  let left = tile "left"
  and right = tile "right" in
  let host = receive empty registry in
  assert (compact_summary host left);
  assert (not (compact_summary host right));
  assert (Option.equal Int.equal (composition_policy host right).padding (Some 1));
  assert (Option.equal Int.equal (composition_policy host left).padding None);
  assert (List.equal String.equal (layout_keys host [ right; left ]) [ "right"; "left" ]);
  let registry =
    { registry with
      tiles =
        List.rev_map registry.tiles ~f:(fun tile ->
          if W.Tile_id.equal tile.id left.id then { tile with hidden = true } else tile)
    }
  in
  let restored = W.Snapshot.t_of_sexp (W.Snapshot.sexp_of_t registry) in
  let host = receive empty restored in
  assert (List.equal String.equal (layout_keys host (tiles host)) [ "right"; "choose" ]);
  assert (Option.is_some (render_definition host workspace));
  assert (compact_summary host left)
;;

let%test_unit "moved and retyped config tiles remain extras rather than claiming keys" =
  let config =
    P.Presets.custom_example () |> Or_error.ok_exn |> P.Presets.resolve |> Or_error.ok_exn
  in
  let window = List.hd_exn config.windows in
  let instance = List.hd_exn window.workspaces in
  let config =
    { config with
      windows =
        [ { window with workspaces = [ instance; { instance with key = "second" } ] } ]
    }
  in
  let initial = W.initial ~session_id:(W.Session_id.of_string "moved-key-layout") in
  let registry =
    W.apply initial (Initialize_config config) |> Result.ok |> Option.value_exn
  in
  let origin = List.hd_exn registry.config_workspaces
  and target = List.last_exn registry.workspaces in
  let left =
    W.tile registry (List.Assoc.find_exn origin.tiles "left" ~equal:String.equal)
  in
  let moved =
    W.apply
      registry
      (Mutate
         { expected_revision = registry.revision
         ; mutation = Move_tile { tile = left.id; workspace = target.id }
         })
    |> Result.ok
    |> Option.value_exn
  in
  let host = receive empty moved in
  let moved_left = W.tile moved left.id in
  assert (not (compact_summary host moved_left));
  assert (
    List.equal
      String.equal
      (layout_keys host [ moved_left ])
      [ "extra:" ^ W.Tile_id.to_string left.id ]);
  (* Retyping an original identity must not retain the original kind's leaf or defaults. *)
  let retyped =
    { registry with
      tiles =
        List.map registry.tiles ~f:(fun tile ->
          if W.Tile_id.equal tile.id left.id then { tile with kind = "timing" } else tile)
    }
  in
  let host = receive empty retyped in
  let tile = W.tile retyped left.id in
  assert (not (compact_summary host tile));
  assert (
    List.equal
      String.equal
      (layout_keys host [ tile ])
      [ "extra:" ^ W.Tile_id.to_string tile.id ]);
  (* Returning an unchanged tile to its origin legitimately recovers the same key. *)
  assert (
    List.equal String.equal (layout_keys (receive empty registry) [ left ]) [ "left" ])
;;

(** Presentation preferences are client-local, keyed by stable workspace/tile IDs. They
    survive polling/workspace switches; tile appearance overrides also survive client
    restart via [Presentation_preferences]. No daemon writes. *)
let policy t (tile : W.Tile.t) =
  let density_defaults : T.t =
    { T.defaults with
      padding =
        (match t.appearance.density with
         | Compact -> 0
         | Comfortable -> 1)
    }
  in
  let base =
    if String.equal tile.kind "workspace-tabs"
    then
      T.apply density_defaults { T.navigation with frame = Some false; padding = Some 0 }
    else density_defaults
  in
  let defaults = preset_presentation (composition_policy t tile) in
  (* Most compiled settings are defaults under client settings. Compression's authored
     tile choice instead has tile specificity, resolved separately below. *)
  let app = T.apply (T.apply base defaults) t.presentation in
  let workspace =
    List.Assoc.find
      t.workspace_presentation
      (W.Workspace_id.to_string tile.workspace)
      ~equal:String.equal
    |> Option.value ~default:T.inherit_
  in
  let local = local t tile.id in
  let resolved = T.apply (T.apply app workspace) local.presentation in
  (* Compression alone gives authored tile settings tile specificity. *)
  { resolved with
    string_compression =
      Option.first_some
        local.presentation.string_compression
        (Option.first_some
           defaults.string_compression
           (Option.first_some
              workspace.string_compression
              t.presentation.string_compression))
      |> Option.value ~default:true
  }
;;

let compression_hint t =
  Option.value_map (focused t) ~default:"" ~f:(fun tile ->
    let source =
      if Option.is_some (local t tile.id).presentation.string_compression
      then "tile override"
      else if Option.is_some (composition_policy t tile).string_compression
      then "configured tile override"
      else if Option.exists
                (List.Assoc.find
                   t.workspace_presentation
                   (W.Workspace_id.to_string tile.workspace)
                   ~equal:String.equal)
                ~f:(fun o -> Option.is_some o.T.string_compression)
      then "workspace"
      else if Option.is_some t.presentation.string_compression
      then "global"
      else "built-in default"
    in
    sprintf
      "Focused tile: %s (%s); tile overrides take precedence"
      (if (policy t tile).string_compression then "compressed" else "full")
      source)
;;

let compression_commands t =
  let choices =
    [ "compact", "Compress identifiers", Some true
    ; "full", "Show full identifiers", Some false
    ; "reset", "Reset compression (inherit)", None
    ]
  in
  let make scope action =
    List.map choices ~f:(fun (key, label, value) ->
      command
        (scope ^ ".strings." ^ key)
        ("Strings (" ^ scope ^ "): " ^ label ^ " — " ^ compression_hint t)
        "compression presentation identifiers global project workspace inherit reset"
        (action value))
  in
  make "global" (fun v -> Set_global_compression v)
  @ Option.value_map t.active ~default:[] ~f:(fun workspace ->
    make "workspace" (fun v -> Set_workspace_compression (workspace, v)))
;;

let%test_unit "scoped compression actions preserve loaded data and navigation" =
  let registry =
    W.initial ~session_id:(W.Session_id.of_string "compression-local-only")
  in
  let tile = List.hd_exn registry.tiles in
  let host = receive empty registry in
  let original =
    { default_local with
      cursor = Some "raw-selection"
    ; filter = "keep-filter"
    ; scroll = 17
    ; presentation = { T.inherit_ with decimal_places = Some 7; hints = Some false }
    }
  in
  let host = set_local host tile.id original in
  let actions = compression_commands host in
  List.iter actions ~f:(fun c ->
    let changed =
      match c.action with
      | Set_global_compression value -> set_global_compression host value
      | Set_workspace_compression (workspace, value) ->
        set_workspace_compression host workspace value
      | _ -> assert false
    in
    assert (phys_equal changed.locals host.locals);
    assert (phys_equal changed.registry host.registry);
    assert (phys_equal changed.timing host.timing);
    assert (phys_equal changed.testing host.testing);
    assert (phys_equal changed.waveforms host.waveforms);
    assert (phys_equal changed.planned_run host.planned_run));
  List.iter [ Some true; Some false; None ] ~f:(fun string_compression ->
    let changed, _ =
      set_presentation host tile.id { original.presentation with string_compression }
    in
    let local = local changed tile.id in
    assert (local.scroll = original.scroll);
    assert (Option.equal String.equal local.cursor original.cursor);
    assert (String.equal local.filter original.filter);
    assert (phys_equal local.simulation original.simulation);
    assert (phys_equal local.inspection original.inspection);
    assert (phys_equal changed.registry host.registry);
    assert (phys_equal changed.planned_run host.planned_run))
;;

let binding_kind (tile : W.Tile.t) : T.Binding.t =
  if Testing_workspace.is_pane tile.kind
     || P.Waveforms.is_pane tile.kind
     || String.equal tile.kind "hierarchy"
  then Project
  else (
    match tile.binding with
    | Pin_run _ -> Pinned
    | Follow -> if project_scoped_kind tile.kind then Project else Follow)
;;

let%test_unit "configured compression has tile specificity over workspace and global" =
  List.iter [ true; false ] ~f:(fun configured ->
    let config = P.Presets.custom_example () |> Or_error.ok_exn in
    let config =
      { config with
        definitions =
          List.map config.definitions ~f:(fun d ->
            { d with
              tiles =
                List.map d.tiles ~f:(fun tile ->
                  let p =
                    Option.value
                      tile.presentation
                      ~default:Workspace_config.Presentation.inherit_defaults
                  in
                  { tile with
                    presentation = Some { p with string_compression = Some configured }
                  })
            })
      }
      |> P.Presets.resolve
      |> Or_error.ok_exn
    in
    let registry =
      W.initial ~session_id:(W.Session_id.of_string "configured-compression")
    in
    let registry =
      W.apply registry (Initialize_config config) |> Result.ok |> Option.value_exn
    in
    let p = List.hd_exn registry.config_workspaces in
    let tile = W.tile registry (List.Assoc.find_exn p.tiles "left" ~equal:String.equal) in
    let host =
      receive empty registry
      |> fun h ->
      set_global_compression h (Some (not configured))
      |> fun h -> set_workspace_compression h tile.workspace (Some (not configured))
    in
    assert (Bool.equal (policy host tile).string_compression configured);
    let overridden, _ =
      set_presentation
        host
        tile.id
        { T.inherit_ with string_compression = Some (not configured) }
    in
    assert (Bool.equal (policy overridden tile).string_compression (not configured));
    let reset, _ = set_presentation overridden tile.id T.inherit_ in
    assert (Bool.equal (policy reset tile).string_compression configured);
    let destination = W.Workspace_id.of_string "moved-destination" in
    let moved =
      { registry with
        tiles =
          List.map registry.tiles ~f:(fun t ->
            if W.Tile_id.equal t.id tile.id then { t with workspace = destination } else t)
      }
    in
    let host = receive overridden moved in
    assert (Option.is_none (local host tile.id).presentation.string_compression);
    let retyped =
      { registry with
        tiles =
          List.map registry.tiles ~f:(fun t ->
            if W.Tile_id.equal t.id tile.id then { t with kind = "log" } else t)
      }
    in
    let host = receive overridden retyped in
    assert (Option.is_none (local host tile.id).presentation.string_compression))
;;

let presentation_commands t (tile : W.Tile.t) =
  let p = policy t tile
  and o = (local t tile.id).presentation in
  let set id title overrides =
    command
      (if String.equal id "header" then "tile.headers" else "tile.presentation." ^ id)
      title
      "appearance presentation focused tile local inherit"
      (Set_presentation (tile.id, overrides))
  in
  [ set "header" "Toggle focused tile header" { o with header = Some (not p.header) }
  ; set "title" "Toggle focused tile title" { o with title = Some (not p.title) }
  ; set
      "badge.exceptions"
      "Binding badge: Exceptions (pins only)"
      { o with badge = Some Exceptions }
  ; set "badge.always" "Binding badge: Always" { o with badge = Some Always }
  ; set "badge.hidden" "Binding badge: Hidden" { o with badge = Some Hidden }
  ; set
      "run-reference"
      "Toggle focused tile run reference"
      { o with run_reference = Some (not p.run_reference) }
  ; set
      "freshness"
      "Toggle focused tile freshness"
      { o with freshness = Some (not p.freshness) }
  ; set "hints" "Toggle focused tile hints" { o with hints = Some (not p.hints) }
  ; set "frame" "Toggle focused tile frame" { o with frame = Some (not p.frame) }
  ; set
      "padding"
      "Toggle focused tile padding"
      { o with padding = Some (if p.padding = 0 then 1 else 0) }
  ; set
      "rows.more"
      "Run selector: More visible rows (+1)"
      { o with run_selector_rows = Some (p.run_selector_rows + 1) }
  ; set
      "rows.fewer"
      "Run selector: Fewer visible rows (-1)"
      { o with run_selector_rows = Some (Int.max 1 (p.run_selector_rows - 1)) }
  ; set "reset" "Reset presentation overrides (inherit)" T.inherit_
  ; set
      "strings.compact"
      "Strings (focused tile): Compress identifiers and source paths"
      { o with string_compression = Some true }
  ; set
      "strings.full"
      "Strings (focused tile): Show full identifiers and source paths"
      { o with string_compression = Some false }
  ; set
      "strings.reset"
      "Strings (focused tile): Reset compression (inherit)"
      { o with string_compression = None }
  ]
  @ List.init 10 ~f:(fun places ->
    set
      ("decimals." ^ Int.to_string places)
      (sprintf "Timing: Truncate to %d decimal places" places)
      { o with decimal_places = Some places })
;;

let catalog t ~(project : Project.t option) ~(jobs : Job.t list) =
  let needs_project =
    if Option.is_none project then Some "Open a project first" else None
  in
  let base =
    [ command
        ?unavailable:needs_project
        "preparation.prepare"
        "Plan PREPARATION inputs for manual launch (r; no processes)"
        "build flow emit"
        Prepare_project
    ; command
        "launch.quick.view"
        ("Quick-launch behavior: view launched run"
         ^ if t.quick_launch_view then " (selected)" else "")
        "preference setting default follow context"
        (Set_quick_launch_view true)
    ; command
        "launch.quick.no-view"
        ("Quick-launch behavior: keep current context"
         ^ if t.quick_launch_view then "" else " (selected)")
        "preference setting stay context"
        (Set_quick_launch_view false)
    ; command
        ?unavailable:needs_project
        "preparation.cancel"
        "Cancel preparation"
        "stop build emission"
        Cancel_preparation
    ; command
        "preparation.artifact"
        "Inspect preparation bundle artifact"
        "publication output"
        Preparation_artifact
    ; command
        ?unavailable:needs_project
        "project.build"
        "Build project"
        "dune build"
        Build
    ; command
        ?unavailable:needs_project
        "project.test"
        "Run project tests"
        "simulation dune test"
        Test
    ; command
        ?unavailable:needs_project
        "project.discover"
        "Refresh hardware integration"
        "driver discover"
        Refresh_integration
    ; command
        ?unavailable:needs_project
        "asic.discover"
        "Discover ASIC flows and runs"
        "synthesis provider"
        Discover_asic
    ; command
        "artifact.inspect"
        "Inspect selected RTL artifact"
        "read output"
        Inspect_artifact
    ; command "hierarchy.inspect" "Inspect hardware hierarchy" "tree" Inspect_hierarchy
    ; command
        "resources.open"
        "Inspect resources (open Resources workspace)"
        "resource inventory table memory macro"
        Open_resources
    ; command
        "workloads.open"
        "Open Workloads workspace"
        "PT8 retained inspection comparison"
        Open_workloads
    ; command
        "workloads.import"
        "Workloads: Import exact retained result.json"
        "absolute path read only"
        Workload_import
    ; command
        "workloads.launch"
        "Workloads: Launch fresh PT.8 workload… (Testing)"
        "simulation suite discovery form"
        Workload_testing
    ; command
        "resources.import-coarse"
        "Resources: Import retained resource evidence"
        "exact coarse source absolute path no run allocation"
        (Resource_import false)
    ; command
        "resources.import-bundle"
        "Resources: Import emitted bundle"
        "exact bundle inventory pre-run absolute path"
        (Resource_import true)
    ; command "host.chrome" "Toggle host chrome" "header footer" Toggle_chrome
    ; command
        "host.hints.main"
        ((if t.main_hints then "Hide" else "Show")
         ^ " main window control hints (Space c h)")
        "toggle bottom footer keys help hints show restore"
        Toggle_main_hints
    ; command
        "host.hints.palette"
        ((if t.palette_hints then "Hide" else "Show")
         ^ " command palette control hints (Space c p)")
        "toggle bottom footer keys help hints show restore"
        Toggle_palette_hints
    ; command
        "timing.preload.background-index"
        ("Timing preload: Background index"
         ^ if t.timing_preload then " (selected)" else "")
        "project persistent completed hidden cache warm loading"
        (Set_timing_preload true)
    ; command
        "timing.preload.explicit-only"
        ("Timing preload: Explicit only" ^ if t.timing_preload then "" else " (selected)")
        "project persistent no speculative provider reads"
        (Set_timing_preload false)
    ; command
        "layout.fit"
        "Layout: Fit tiles to window"
        "dashboard fill screen grid"
        (Set_layout_mode Fit)
    ; command
        "layout.preferred"
        "Layout: Requested tile sizes"
        "shelf preferred geometry"
        (Set_layout_mode Preferred)
    ; command "host.exit" "Exit client" "quit" Exit
    ]
    @ appearance_commands t
    @ compression_commands t
    @ List.filter_map jobs ~f:(fun job ->
      if Job.is_terminal job
      then None
      else
        Some
          (command
             ("job.cancel." ^ Job_id.to_string job.id)
             ("Cancel job " ^ Job_id.to_string job.id)
             "stop attempt"
             (Cancel job.id)))
    @ Option.value_map project ~default:[] ~f:(fun project ->
      List.concat_map project.targets ~f:(fun target ->
        List.filter_map project.configurations ~f:(fun config ->
          if not (Target_id.equal config.target target.id)
          then None
          else
            Some
              (command
                 ("rtl." ^ Configuration_id.to_string config.id)
                 ("Generate RTL: " ^ target.name ^ " / " ^ config.name)
                 "hardware"
                 (Generate_rtl (target.id, config.id))))))
  in
  match t.registry, active t with
  | Some s, Some w ->
    let mutation id title action =
      command id title "workspace tile layout" (Registry action)
    in
    let geometry : W.Geometry.t = { x = 0; y = 0; width = 40; height = 10 } in
    base
    @ [ command
          "workspace.create-blank"
          "Create blank workspace"
          "new empty workspace window tmux"
          Create_blank_workspace
      ]
    @ restore_commands w
    @ (if String.is_prefix w.name ~prefix:"Timing · captured "
       then
         [ mutation
             "workspace.close-separate-timing"
             "Close separate investigation"
             (Close_separate_investigation w.id)
         ]
       else [])
    @ List.map P.Presets.all ~f:(fun d ->
      mutation
        ("workspace.create-builtin." ^ d.P.Definition.id)
        ("Create built-in workspace: " ^ d.name)
        (W.Mutation.Instantiate_template
           { window = w.window
           ; template = (P.Presets.builtins d.id |> Or_error.ok_exn).template
           }))
    @ List.map s.workspaces ~f:(fun w ->
      command
        ("workspace." ^ W.Workspace_id.to_string w.id)
        ("Switch to " ^ w.name)
        "workspace navigation tabs"
        (Switch w.id))
    @ (if List.exists s.tiles ~f:(fun tile -> Testing_workspace.is_pane tile.kind)
       then []
       else
         [ command
             "workspace.create-testing"
             "Create Testing workspace"
             "tests simulation layout"
             Create_testing_workspace
         ])
    @ [ mutation
          "context.independent"
          "Make workspace independent"
          (Make_independent w.id)
      ; mutation
          "context.main"
          "Relink workspace to Main"
          (Link_context { workspace = w.id; context = s.main_context })
      ; mutation
          "tile.unzoom"
          "Unzoom workspace"
          (Set_zoom { workspace = w.id; tile = None })
      ; command
          ?unavailable:
            (if Option.is_none (definition w)
             then
               Some
                 "Choose Apply preset: Overview, Timing, Testing or Waveforms for this \
                  custom workspace"
             else None)
          "workspace.default-layout"
          "Apply default layout (add missing tiles)"
          "preset synthesis"
          Apply_default_layout
      ]
    @ List.concat_map P.Presets.all ~f:(fun d ->
      [ mutation
          ("workspace.apply-preset." ^ d.P.Definition.id)
          ("Apply preset: " ^ d.name ^ " (add missing tiles)")
          (P.Definition.apply d ~workspace:w.id)
      ; mutation
          ("workspace.reset-arrangement." ^ d.id)
          ("Reset arrangement: " ^ d.name ^ " (preserve extras and pins)")
          (P.Definition.reset d ~workspace:w.id)
      ])
    @ Option.value_map (definition w) ~default:[] ~f:(fun d ->
      [ mutation
          "workspace.reset-arrangement"
          "Reset arrangement (current preset; preserve extras and pins)"
          (P.Definition.reset d ~workspace:w.id)
      ])
    @ List.map
        [ "live-status"
        ; "hierarchy"
        ; "workspace-tabs"
        ; "preparation"
        ; "stage-checklist"
        ; "planned-run"
        ; "run-selector"
        ; "placement"
        ; "cts"
        ; "routing"
        ; "checks"
        ; "finalization"
        ; "execution"
        ; "project-tests"
        ; "simulation"
        ; "simulation-catalog"
        ; "simulation-attempts"
        ; "simulation-cases"
        ; "simulation-detail"
        ; "simulation-artifacts"
        ; "waveform-session"
        ; "waveform-signals"
        ; "waveform-waves"
        ; "waveform-picker"
        ; "waveform-logs"
        ; "simulation-logs"
        ; "logs"
        ; "timing"
        ; "synthesis"
        ; "resources"
        ; "workloads"
        ; "resource-summary"
        ; "asic"
        ; "project"
        ; "navigation"
        ]
        ~f:(fun kind ->
          mutation
            ("tile.add." ^ kind)
            ("Add " ^ kind ^ " tile")
            (Create_tile { workspace = w.id; kind; geometry }))
    @ List.filter_map s.tiles ~f:(fun tile ->
      if not (W.Workspace_id.equal tile.workspace w.id && tile.hidden)
      then None
      else
        Some
          (mutation
             ("tile.restore." ^ W.Tile_id.to_string tile.id)
             ("Restore " ^ tile.kind ^ " " ^ W.Tile_id.to_string tile.id)
             (Set_tile_hidden { tile = tile.id; hidden = false })))
    @ Option.value_map (focused t) ~default:[] ~f:(fun tile ->
      let id = tile.id in
      let g = tile.requested_geometry in
      let run = Result.ok (W.resolve_tile s id) |> Option.bind ~f:(fun r -> r.run) in
      (if String.equal tile.kind "hierarchy"
       then
         [ command
             "hierarchy.load-current"
             "Load current hierarchy"
             "reload tree"
             (Load_hierarchy id)
         ; command
             "hierarchy.detail"
             "Inspect hierarchy tile node"
             "ports metadata"
             (Hierarchy_detail id)
         ]
       else [])
      @ [ mutation
            "tile.hide"
            "Hide focused tile"
            (Set_tile_hidden { tile = id; hidden = true })
        ; mutation
            "tile.zoom"
            "Zoom focused tile"
            (Set_zoom { workspace = w.id; tile = Some id })
        ; mutation
            "tile.follow"
            "Unpin tile (follow context)"
            (Set_tile_binding { tile = id; binding = Follow })
        ; command
            ?unavailable:
              (if project_scoped_kind tile.kind || String.equal tile.kind "run-selector"
               then Some "This tile does not display run-scoped evidence"
               else if Option.is_none run
               then Some "No selected run to pin"
               else None)
            "tile.pin"
            "Pin tile to selected run (live reference)"
            "reference"
            (Registry
               (Set_tile_binding
                  { tile = id
                  ; binding =
                      Option.value_map run ~default:W.Binding.Follow ~f:(fun r ->
                        Pin_run r)
                  }))
        ; mutation
            "tile.wider"
            "Resize tile wider"
            (Resize_tile { tile = id; geometry = { g with width = g.width + 8 } })
        ; mutation
            "tile.narrower"
            "Resize tile narrower"
            (Resize_tile
               { tile = id; geometry = { g with width = Int.max 8 (g.width - 8) } })
        ; mutation
            "tile.taller"
            "Resize tile taller"
            (Resize_tile { tile = id; geometry = { g with height = g.height + 4 } })
        ; mutation
            "tile.shorter"
            "Resize tile shorter"
            (Resize_tile
               { tile = id; geometry = { g with height = Int.max 3 (g.height - 4) } })
        ; mutation
            "tile.last"
            "Reorder tile to end"
            (Reorder_tile { tile = id; before = None })
        ; command "logs.follow" "Resume log follow" "tail" Resume_log
        ]
      @ presentation_commands t tile
      @ (if not (String.equal tile.kind "workloads")
         then []
         else
           List.map
             [ "results", "Retained result list (Esc)", Workloads_view.Show_results
             ; "detail", "Open selected result (Enter)", Open
             ; "refresh", "Refresh exact source/pair (r)", Refresh
             ; "provenance", "Inspect controls and provenance (d)", Show_provenance
             ; "compare", "Compare captured A / B (c)", Show_compare
             ; "swap", "Swap A / B and query provider", Swap
             ]
             ~f:(fun (id, title, input) ->
               command
                 ("workloads." ^ id)
                 ("Workloads: " ^ title)
                 "PT8 evidence"
                 (Workload_input input))
           @ (let unavailable =
                if Workloads_view.capture_ready (local t tile.id).workloads
                then None
                else Some "Open the selected result's validated detail before capture"
              in
              [ command
                  ?unavailable
                  "workloads.capture-a"
                  "Workloads: Capture A left result"
                  "source digest verified bundle locator legacy exact path"
                  (Workload_capture true)
              ; command
                  ?unavailable
                  "workloads.capture-b"
                  "Workloads: Capture B right result"
                  "source digest verified bundle locator legacy exact path"
                  (Workload_capture false)
              ])
           @ List.map Workloads_view.axes ~f:(fun axis ->
             command
               ("workloads.axis." ^ axis)
               ("Workloads: Axis " ^ axis)
               "explicit comparison intent"
               (Workload_input (Axis axis))))
      @ (if not (String.equal tile.kind "resources")
         then []
         else
           [ command
               "resources.follow"
               "Resources: Follow tile run binding"
               "selected execution pin Main"
               (Resource_target None)
           ; command
               "resources.refresh"
               "Resources: Refresh exact evidence (r)"
               "read only no EDA"
               (Resource_input Refresh)
           ; command
               "resources.table"
               "Resources: Resource table"
               "inventory summary"
               (Resource_input Show_table)
           ; command
               "resources.detail"
               "Resources: Open selected resource (Enter)"
               "contract policy selection reason actual role stages"
               (Resource_input Open)
           ; command
               "resources.sources"
               "Resources: Authorized sources (a)"
               "artifacts catalog paged text"
               (Resource_input Show_sources)
           ; command
               "resources.context"
               "Resources: Full source provenance (d)"
               "scope digest identity"
               (Resource_input Show_context)
           ; command
               "resources.next-page"
               "Resources: Next page (n)"
               "detail sources bytes"
               (Resource_input Next_page)
           ; command
               "resources.previous-page"
               "Resources: Previous page (p)"
               "detail sources bytes"
               (Resource_input Previous_page)
           ; command
               "resources.compare-left"
               "Resources: Capture comparison A"
               "explicit baseline source digest"
               (Resource_input Capture_left)
           ; command
               "resources.compare-right"
               "Resources: Capture comparison B"
               "explicit candidate source digest"
               (Resource_input Capture_right)
           ; command
               "resources.compare"
               "Resources: Compare captured A / B (c)"
               "compatible measurements deltas"
               (Resource_input Show_compare)
           ; command
               "resources.swap"
               "Resources: Swap comparison A / B"
               "reverse delta"
               (Resource_input Swap_compare)
           ; command
               "resources.back"
               "Resources: Back to table (Esc)"
               "close detail"
               (Resource_input Back)
           ]
           @ List.map Resources_view.sections ~f:(fun section ->
             command
               ("resources.section." ^ section)
               ("Resources: Inspect " ^ section)
               "geometry area ratios sampled timing electrical contract provenance"
               (Resource_input (Section section))))
      @ (if not (String.equal tile.kind "synthesis")
         then []
         else
           [ command
               "synthesis.summary"
               "Synthesis: Summary"
               "cells overview"
               (Synthesis_mode Summary)
           ; command
               "synthesis.cells"
               "Synthesis: Browse cell table"
               "resources breakdown inspect"
               (Synthesis_mode Cells)
           ; command
               "synthesis.details"
               "Synthesis: Inspect selected cell"
               "resource row detail"
               (Synthesis_mode Details)
           ; command
               "synthesis.metrics"
               "Synthesis: Inspect metrics"
               "resources diagnostics counters checkpoint boundary m"
               (Synthesis_mode Metrics)
           ; command
               "synthesis.evidence"
               "Synthesis: Inspect full evidence"
               "producer source provenance report path json"
               (Synthesis_mode Evidence)
           ; command
               "synthesis.clear-filter"
               "Synthesis: Clear cell filter"
               "reset search"
               Synthesis_clear_filter
           ; command
               "synthesis.cycle-sort"
               "Synthesis: Cycle table sort"
               "order count name"
               Synthesis_cycle_sort
           ]
           @ List.map Synthesis.Sort.all ~f:(fun sort ->
             let key, title =
               match sort with
               | Count_desc -> "count-desc", "count descending"
               | Count_asc -> "count-asc", "count ascending"
               | Name_asc -> "name-asc", "name ascending"
               | Name_desc -> "name-desc", "name descending"
             in
             command
               ("synthesis.sort." ^ key)
               ("Synthesis: Sort " ^ title)
               "cells table order"
               (Synthesis_sort sort)))
      @ List.filter_map s.workspaces ~f:(fun destination ->
        if W.Workspace_id.equal destination.id w.id
        then None
        else
          Some
            (mutation
               ("tile.move." ^ W.Workspace_id.to_string destination.id)
               ("Move focused tile to " ^ destination.name)
               (Move_tile { tile = id; workspace = destination.id }))))
  | _ -> base
;;

(* WB-054: contextual actions, explicit inspector close and breadcrumbs. Everything here
   is derived from the focused tile's typed host state; nothing creates new routing. *)

type inspector =
  | Explorer of Inspection_view.t
  | Artifact_browser of Artifact_view.t
  | Timing_detail of Timing_workspace.pane * Inspection_view.t

let tile_run t (tile : W.Tile.t) =
  Option.bind t.registry ~f:(fun s ->
    Result.ok (W.resolve_tile s tile.id) |> Option.bind ~f:(fun r -> r.run))
;;

(** The inspector the focused tile currently shows. Explorer/artifact views whose run
    scope no longer matches the tile are hidden by the renderer, so they are not open. A
    Timing pane counts only while its Detail/provenance reader is open. *)
let open_inspector t =
  Option.bind (focused t) ~f:(fun tile ->
    let l = local t tile.id
    and scope = tile_run t tile in
    match
      ( Option.bind l.inspection ~f:(fun v -> Inspection_view.reconcile_scope v ~scope)
      , Option.bind l.artifacts ~f:(fun v -> Artifact_view.reconcile_scope v ~scope) )
    with
    | Some view, _ -> Some (tile, Explorer view)
    | None, Some view -> Some (tile, Artifact_browser view)
    | None, None ->
      (match Timing_workspace.pane tile.kind, timing_pane t tile with
       | Some pane, Some _ ->
         Option.bind (timing t tile) ~f:(fun view ->
           if Inspection_view.detail_mode view
           then Some (tile, Timing_detail (pane, view))
           else None)
       | _ -> None))
;;

let no_inspector = "no inspector open on the focused tile"

(** Close the focused tile's inspector in one step (Esc keeps its step-by-step behavior).
    Return focus: an explorer or artifact browser belongs to the focused tile, so focus
    stays there; a Timing reader returns focus to the workspace's [timing-paths] tile when
    visible. The selected row/artifact cursor, tile bindings and run selection are never
    changed; pending detail responses are fenced by the existing generation counters. *)
let close_inspector t =
  match open_inspector t with
  | None -> Error no_inspector
  | Some (tile, Explorer view) ->
    let l = local t tile.id in
    Ok
      ( set_local
          t
          tile.id
          { l with
            inspection = None
          ; inspection_generation = Int.max l.inspection_generation view.generation
          }
      , sprintf "Closed %s inspector; focus stays on %s" view.domain tile.kind )
  | Some (tile, Artifact_browser view) ->
    let l = local t tile.id in
    Ok
      ( set_local
          t
          tile.id
          { l with
            artifacts = None
          ; artifact_generation = Int.max l.artifact_generation view.generation
          }
      , "Closed reports/artifacts browser; focus stays on " ^ tile.kind )
  | Some (tile, Timing_detail (pane, view)) ->
    let closed, _, _ =
      Timing_workspace.input
        ~pane
        ~scroll:(local t tile.id).scroll
        ~width:1
        ~height:1
        view
        Inspection_view.Back
    in
    let t = set_timing t tile closed in
    let paths =
      List.find (tiles t) ~f:(fun candidate ->
        W.Workspace_id.equal candidate.workspace tile.workspace
        && Option.equal
             Timing_workspace.equal_pane
             (Timing_workspace.pane candidate.kind)
             (Some Paths))
    in
    Ok
      ( { t with
          focus = Some (Option.value_map paths ~default:tile.id ~f:(fun p -> p.id))
        }
      , if Option.is_some paths
        then "Closed path detail; focus returned to timing · paths (selection kept)"
        else "Closed path detail; selection kept" )
;;

(* Inspector keys that the explorer and Timing panes already route. *)
let inspector_key_commands t (tile : W.Tile.t) =
  let view, missing =
    match open_inspector t with
    | Some (_, Explorer view) -> Some view, None
    | Some (_, Artifact_browser _) -> None, None
    | Some (_, Timing_detail (_, view)) -> Some view, None
    | None ->
      if Option.is_none (Timing_workspace.pane tile.kind)
      then None, None
      else (
        match timing t tile with
        | Some view -> Some view, None
        | None ->
          ( None
          , Some
              (if Option.is_none (tile_run t tile)
               then "no run selected"
               else "no timing paths opened for this run; use Inspect timing paths") ))
  in
  let key id title aliases input reason =
    let unavailable = Option.first_some missing reason in
    command
      ?unavailable
      ("inspector." ^ id)
      title
      ("inspect explorer timing paths " ^ aliases)
      (match unavailable with
       | Some reason -> Unavailable reason
       | None -> Inspector_input (tile.id, input))
  in
  let reason f = Option.bind view ~f in
  match view, missing with
  | None, None -> []
  | _ ->
    [ key
        "open-detail"
        "Inspector: Open selected row detail (Enter)"
        "row path detail"
        Open
        (reason (fun v ->
           if Option.is_none v.index
           then Some "index not loaded yet"
           else if Inspection_view.detail_mode v
           then Some "detail already open; Space c x closes it"
           else if List.is_empty (Inspection_view.visible v)
           then Some "no rows match the current filter"
           else if Option.is_none v.selected
           then Some "no row selected"
           else None))
    ; key "refresh" "Inspector: Refresh current evidence (r)" "reload" Refresh None
    ; key
        "stage"
        "Inspector: Next inspection stage (t)"
        "stage cycle"
        Stage
        (reason (fun v ->
           if Option.is_some v.analysis
           then Some "captured analysis stage is fixed"
           else None))
    ; key
        "near"
        "Inspector: Toggle near/violated rows (v)"
        "slack threshold"
        Near
        (reason (fun v ->
           if String.equal v.domain "timing"
           then None
           else Some "near/violated applies to timing paths only"))
    ; key
        "source"
        "Inspector: Source metadata and diagnostics (d)"
        "provenance info"
        Info
        (reason (fun v -> if v.info then Some "source view already open" else None))
    ]
;;

(* Run-scoped tiles: reuse the existing Browse_* actions for the tile's own run. *)
let run_context_commands t (tile : W.Tile.t) =
  if project_scoped_kind tile.kind || String.equal tile.kind "run-selector"
  then []
  else (
    let run = tile_run t tile in
    let unavailable = if Option.is_none run then Some "no run selected" else None in
    let action f =
      match run with
      | Some run -> f run
      | None -> Unavailable "no run selected"
    in
    [ command
        ?unavailable
        "context.inspect-timing"
        "Context: Inspect timing paths for this tile's run"
        "investigate slack signoff"
        (if String.equal tile.kind "timing" || String.equal tile.kind "stage-checklist"
         then Inspect_overview_analysis tile.id
         else action (fun run -> Browse_default_timing run))
    ; command
        ?unavailable
        "context.artifacts"
        "Context: Browse reports/artifacts for this tile's run"
        "catalog report"
        (action (fun run -> Browse_artifacts run))
    ])
;;

(* Testing panes: actions whose real command exists only while a selection allows it. *)
let testing_context_commands t (tile : W.Tile.t) =
  if not (Testing_workspace.is_pane tile.kind)
  then []
  else (
    let v = simulation t tile.id in
    let detail = Simulation_view.detail v in
    let attempt_reason =
      if Option.is_none v.attempt
      then Some "no attempt selected"
      else if Option.is_none detail
      then Some "attempt detail not loaded"
      else None
    in
    let placeholder id title reason =
      Option.map reason ~f:(fun reason ->
        command ~unavailable:reason id title "rerun testing" (Unavailable reason))
    in
    let artifact_reason =
      match Testing_workspace.artifact (testing_state t tile.id) with
      | Some _ -> None
      | None -> Some (Option.value attempt_reason ~default:"no artifact selected")
    in
    List.filter_opt
      [ placeholder
          "simulation.rerun-case"
          "Simulation: Rerun selected case (r)"
          (Option.first_some
             attempt_reason
             (if Option.is_none v.case_id then Some "no case selected" else None))
      ; placeholder
          "simulation.rerun-failed"
          "Simulation: Rerun all failed cases (f)"
          (Option.first_some
             attempt_reason
             (Option.bind detail ~f:(fun d ->
                if List.exists d.cases ~f:(fun c ->
                     Simulation.Case_status.equal c.status Failed)
                then None
                else Some "no failed cases in this attempt")))
      ]
    @
    match Testing_workspace.pane tile.kind with
    | Some Artifacts ->
      List.filter_opt
        [ placeholder
            "testing.artifact.export"
            "Simulation: Export selected artifact (e)"
            artifact_reason
        ; placeholder
            "testing.artifact.waveform"
            "Simulation: Open selected artifact as embedded waveform (w)"
            artifact_reason
        ]
    | _ -> [])
;;

(* Production selection commands, shared with catalog/keyboard regression seams. The
   caller supplies the existing submission-key allocator; promotion retains these exact
   command records and their captured identities. *)
let simulation_selection_commands t (tile : W.Tile.t) ~submission_key =
  let v = simulation t tile.id in
  Option.value_map (Simulation_view.detail v) ~default:[] ~f:(fun d ->
    let rerun id title cases =
      command
        ("simulation." ^ id)
        ("Simulation: " ^ title)
        "suite cases seed history"
        (Simulation
           ( tile.id
           , Rerun
               { submission_key = submission_key "simulation-rerun"
               ; attempt_id = d.id
               ; cases
               } ))
    in
    let failed =
      List.filter_map d.cases ~f:(fun c ->
        if Simulation.Case_status.equal c.status Failed then Some c.case_id else None)
    in
    (if List.is_empty failed
     then []
     else
       [ rerun "rerun-failed" "Rerun all failed (original inputs; current project)" failed
       ])
    @ Option.value_map v.case_id ~default:[] ~f:(fun id ->
      [ rerun
          "rerun-case"
          ("Rerun case " ^ id ^ " (original inputs; current project)")
          [ id ]
      ])
    @ List.concat_map d.artifacts ~f:(fun a ->
      [ command
          ("simulation.export." ^ a.id)
          ("Simulation: Export exact bytes " ^ a.label)
          "trace waveform"
          (Simulation_export (a, false))
      ; command
          ("simulation.viewer." ^ a.id)
          ("Simulation: Open external viewer " ^ a.label)
          "trace waveform"
          (Simulation_export (a, true))
      ; command
          ("simulation.waveform." ^ a.id)
          ("Simulation: Open embedded waveform " ^ a.label)
          "vcd wave retained full-area"
          (Simulation_waveform a)
      ; command
          ("simulation.waveform-workspace." ^ a.id)
          ("Simulation: Open Waveforms workspace " ^ a.label)
          "vcd dedicated signals waves picker logs"
          (Simulation_waveform_workspace a)
      ]))
;;

(* Shared by production keyboard routing and contextual catalog ordering. *)
let testing_shortcut t key =
  Option.bind (focused t) ~f:(fun tile ->
    if not (Testing_workspace.is_pane tile.kind)
    then None
    else (
      match key with
      | 'r' -> Some "simulation.rerun-case"
      | 'f' -> Some "simulation.rerun-failed"
      | ('e' | 'v' | 'w' | 'W') when String.equal tile.kind "simulation-artifacts" ->
        (match Testing_workspace.artifact (testing_state t tile.id) with
         | Some artifact ->
           Some
             ((match key with
               | 'e' -> "simulation.export."
               | 'w' -> "simulation.waveform."
               | 'W' -> "simulation.waveform-workspace."
               | _ -> "simulation.viewer.")
              ^ artifact.id)
         | None ->
           (match key with
            | 'e' -> Some "testing.artifact.export"
            | 'w' -> Some "testing.artifact.waveform"
            | _ -> None))
      | _ -> None))
;;

(** Contextual actions for the focused view, listed first. A contextual entry never
    replaces an existing command with the same ID. *)
let contextual t commands =
  let close =
    command
      ?unavailable:(Result.error (close_inspector t))
      "inspector.close"
      "Close inspector (Space c x)"
      "dismiss leave back explorer reader artifacts detail esc"
      Close_inspector
  in
  let extras =
    close
    :: Option.value_map (focused t) ~default:[] ~f:(fun tile ->
      inspector_key_commands t tile
      @ run_context_commands t tile
      @ testing_context_commands t tile)
  in
  let existing id = List.find commands ~f:(fun c -> String.equal c.id id) in
  let promoted =
    List.map extras ~f:(fun extra -> Option.value (existing extra.id) ~default:extra)
    @ (List.filter_map [ 'r'; 'f'; 'e'; 'w' ] ~f:(fun key ->
         Option.bind (testing_shortcut t key) ~f:existing)
       |> List.filter ~f:(fun c ->
         not (List.exists extras ~f:(fun extra -> String.equal extra.id c.id))))
  in
  promoted
  @ List.filter commands ~f:(fun c ->
    not (List.exists promoted ~f:(fun extra -> String.equal extra.id c.id)))
;;

let testing_dispatch t key ~commands =
  Option.bind (testing_shortcut t key) ~f:(fun id ->
    Option.bind (capture t) ~f:(fun capture ->
      Option.map
        (List.find commands ~f:(fun command -> String.equal command.id id))
        ~f:(fun command -> capture, command.action)))
;;

let ranked_matches p =
  Palette_search.rank
    ~query:p.query
    (List.map p.commands ~f:(fun c ->
       ( c
       , [ { Palette_search.text = c.title; weight = 100 }
         ; { text = c.aliases; weight = 85 }
         ; { text = c.id; weight = 75 }
         ] )))
;;

let matches p = List.map (ranked_matches p) ~f:(fun result -> result.Palette_search.item)

(* Edits start a new search and follow its best result. Arrow/Tab choices remain selected
   until the next edit; an unchanged query does not undo navigation. *)
let palette_query p query =
  if String.equal p.query query then p else { p with query; index = 0 }
;;

type input =
  | Character of char
  | Text of string
  | Enter
  | Escape
  | Backspace
  | Clear_filter
  | Next
  | Previous
  | Focus
  | Focus_previous
  | Paste_start
  | Paste_end

type effect =
  | Execute of capture * action
  | Activate
  | No_effect

(* Notty's raw mode disables ISIG. This escape route must run BEFORE any modal or
   bracketed-paste capture, including capture waiting for a missing end marker. *)
let is_interrupt (event : Bonsai_term.Event.t) =
  match event with
  | Key_press { key; mods } ->
    List.exists mods ~f:(function
      | Ctrl -> true
      | _ -> false)
    &&
      (match key with
      | ASCII ('c' | 'C') -> true
      | Uchar value ->
        Uchar.equal value (Uchar.of_char 'c') || Uchar.equal value (Uchar.of_char 'C')
      | _ -> false)
  | _ -> false
;;

let%test_unit "interrupt is independent of filter/palette/paste state and key encoding" =
  let open Bonsai_term.Event in
  List.iter
    [ Key.ASCII 'c'; ASCII 'C'; Uchar (Uchar.of_char 'c') ]
    ~f:(fun key -> assert (is_interrupt (Key_press { key; mods = [ Ctrl ] })));
  assert (not (is_interrupt (Key_press { key = ASCII 'c'; mods = [] })));
  assert (not (is_interrupt (Paste `Start)))
;;

let decode_event (event : Bonsai_term.Event.t) : input option =
  match event with
  | Paste `Start -> Some Paste_start
  | Paste `End -> Some Paste_end
  | Key_press { key = Tab; mods = [ Shift ] } -> Some Focus_previous
  | Key_press { key = ASCII ('r' | 'R'); mods = [ Shift ] } -> Some (Character 'R')
  | Key_press { key = Uchar value; mods = [ Shift ] }
    when Uchar.equal value (Uchar.of_char 'r') || Uchar.equal value (Uchar.of_char 'R') ->
    Some (Character 'R')
  | Key_press { key = ASCII ('u' | 'U'); mods = [ Ctrl ] } -> Some Clear_filter
  | Key_press { key = Uchar value; mods = [ Ctrl ] }
    when Uchar.equal value (Uchar.of_char 'u') || Uchar.equal value (Uchar.of_char 'U') ->
    Some Clear_filter
  | Key_press { key; mods = [] } ->
    (match key with
     | ASCII ch -> Some (Character ch)
     | Uchar u when Uchar.to_scalar u < 128 ->
       Some (Character (Char.of_int_exn (Uchar.to_scalar u)))
     | Uchar u -> Some (Text (Uchar.Utf8.to_string u))
     | Enter -> Some Enter
     | Escape -> Some Escape
     | Backspace -> Some Backspace
     | Tab -> Some Focus
     | Arrow `Down -> Some Next
     | Arrow `Up -> Some Previous
     | _ -> None)
  | _ -> None
;;

let%test_unit "Shift-R decodes to quick-launch character" =
  let open Bonsai_term.Event.Key in
  List.iter
    [ ASCII 'R'; Uchar (Uchar.of_char 'R'); ASCII 'r'; Uchar (Uchar.of_char 'r') ]
    ~f:(fun key ->
      assert (
        Poly.equal
          (decode_event (Key_press { key; mods = [ Shift ] }))
          (Some (Character 'R'))))
;;

let%test_unit "Shift-R decoder preserves legacy keys and modifier boundaries" =
  List.iter [ 'r'; 'R' ] ~f:(fun ch ->
    List.iter
      [ Bonsai_term.Event.Key.ASCII ch; Uchar (Uchar.of_char ch) ]
      ~f:(fun key ->
        assert (
          Poly.equal (decode_event (Key_press { key; mods = [] })) (Some (Character ch)));
        List.iter
          [ [ Bonsai_term.Event.Modifier.Ctrl ]
          ; [ Meta ]
          ; [ Ctrl; Shift ]
          ; [ Meta; Shift ]
          ]
          ~f:(fun mods ->
            assert (Option.is_none (decode_event (Key_press { key; mods }))))));
  assert (
    Poly.equal
      (decode_event (Key_press { key = Tab; mods = [ Shift ] }))
      (Some Focus_previous))
;;

let finalization_form t =
  Option.exists t.palette ~f:(fun p ->
    match p.argument with
    | Some
        ( Finalization_attempt _
        | Resource_path _
        | Workload_path
        | Workload_bundle _
        | Acceptance _
        | Simulation_selection _ ) -> true
    | _ -> false)
;;

let reference_limit t =
  match Option.bind t.palette ~f:(fun p -> p.argument) with
  | Some (Simulation_selection (_, _, _, form)) when form.field = 0 -> 256 * 1024
  | _ -> 4096
;;

let printable_utf8 text =
  let rec loop offset =
    if offset >= String.length text
    then true
    else (
      let decoded = Stdlib.String.get_utf_8_uchar text offset in
      let scalar = Stdlib.Uchar.to_int (Stdlib.Uchar.utf_decode_uchar decoded) in
      Stdlib.Uchar.utf_decode_is_valid decoded
      && scalar >= 32
      && (not (scalar >= 127 && scalar < 160))
      && scalar <> 0x2028
      && scalar <> 0x2029
      && loop (offset + Stdlib.Uchar.utf_decode_length decoded))
  in
  loop 0
;;

let reject_reference_text t =
  ( { t with
      notice = "Finalization reference rejects newline/control or invalid UTF-8 text"
    }
  , No_effect )
;;

let append_reference t text =
  if not (printable_utf8 text)
  then reject_reference_text t
  else (
    match t.palette with
    | None -> t, No_effect
    | Some p ->
      let remaining = Int.max 0 (reference_limit t - String.length p.query) in
      let rec prefix offset =
        if offset >= String.length text
        then offset
        else (
          let length =
            Stdlib.Uchar.utf_decode_length (Stdlib.String.get_utf_8_uchar text offset)
          in
          if offset + length > remaining then offset else prefix (offset + length))
      in
      let length = prefix 0 in
      let query = p.query ^ String.prefix text length in
      ( { t with
          palette = Some { p with query; index = 0 }
        ; notice =
            (if length < String.length text
             then
               "Finalization reference limited to 4096 bytes; excess text rejected at \
                UTF-8 boundary"
             else t.notice)
        }
      , No_effect ))
;;

let drop_last_codepoint text =
  let rec loop offset previous =
    if offset >= String.length text
    then String.prefix text previous
    else (
      let length =
        Stdlib.Uchar.utf_decode_length (Stdlib.String.get_utf_8_uchar text offset)
      in
      loop (offset + length) offset)
  in
  loop 0 0
;;

type inspection_filter_result =
  | Filter_interrupt
  | Filter_handled of t
  | Filter_pass

(** This gate runs before global paste/command handling. The starting tile owns the entire
    bracketed paste, including when polling changes focus or removes its view. No result
    from this gate carries a command or provider operation. *)
let route_inspection_filter_event t (event : Bonsai_term.Event.t) =
  if is_interrupt event
  then Filter_interrupt
  else (
    let target =
      match t.inspection_paste with
      | Some id -> Some (id, inspection t id)
      | None
        when (not t.paste)
             && Option.is_none t.palette
             && (not t.editing_filter)
             && t.prefix = 0 ->
        Option.bind (focused t) ~f:(fun tile ->
          Option.bind (inspection t tile.id) ~f:(fun view ->
            if view.editing then Some (tile.id, Some view) else None))
      | None -> None
    in
    match target with
    | None -> Filter_pass
    | Some (id, view) ->
      let decoded = decode_event event in
      let captured = Option.is_some t.inspection_paste in
      let t, view =
        match decoded, view with
        | Some Paste_end, view ->
          ( { t with paste = false; inspection_paste = None }
          , Option.map view ~f:(fun view -> { view with Inspection_view.pasting = false })
          )
        | _, None ->
          ( { t with
              notice =
                "Inspection filter paste owner changed; payload ignored until end marker"
            }
          , None )
        | Some Paste_start, Some view when not captured ->
          ( { t with paste = true; inspection_paste = Some id; prefix = 0 }
          , Some { view with pasting = true; filter_notice = None } )
        | Some (Character c), Some view ->
          t, Some (Inspection_view.append_filter_text view (String.of_char c))
        | Some (Text text), Some view ->
          t, Some (Inspection_view.append_filter_text view text)
        | _, Some view when captured -> t, Some (Inspection_view.reject_filter_text view)
        | Some (Enter | Escape), Some view -> t, Some { view with editing = false }
        | Some Clear_filter, Some view ->
          t, Some { view with filter = ""; filter_notice = None }
        | Some Backspace, Some view ->
          t, Some { view with filter = drop_last_codepoint view.filter }
        | _, Some view ->
          (match event with
           | Key_press _ -> t, Some (Inspection_view.reject_filter_text view)
           | _ -> t, Some view)
      in
      let t =
        match view with
        | None -> t
        | Some view -> set_inspection t id (Some (Inspection_view.normalize view))
      in
      Filter_handled t)
;;

let%test_unit "production inspection filter gate captures bracketed endpoint paste \
               without dispatching hotkeys"
  =
  let open Bonsai_term.Event in
  let registry =
    W.initial ~session_id:(W.Session_id.of_string "inspection-paste-events")
  in
  let tile = List.hd_exn registry.tiles in
  let view =
    { (Inspection_view.create ~run:Fs0_fixture.run_a ~domain:"timing" ~stage:"signoff" ()) with
      editing = true
    }
  in
  let host = receive empty registry in
  let host =
    set_local
      { host with focus = Some tile.id; chrome = false }
      tile.id
      { default_local with inspection = Some view }
  in
  let send host event =
    match route_inspection_filter_event host event with
    | Filter_handled host -> host
    | Filter_interrupt | Filter_pass -> assert false
  in
  let key key = Key_press { key; mods = [] } in
  let view host = Option.value_exn (local host tile.id).inspection in
  let host = send host (Paste `Start) in
  assert (host.paste && Option.is_some host.inspection_paste && (view host).pasting);
  let payload = "endpoint/out[3]/Q jtr / ; q b (Inspect refresh)" in
  let host =
    String.fold payload ~init:host ~f:(fun host c -> send host (key (ASCII c)))
  in
  let host = send host (key (Uchar (Uchar.of_scalar_exn 0x754c))) in
  assert (String.equal (view host).filter (payload ^ "界"));
  assert (String.equal (view host).stage "signoff");
  assert ((view host).generation = 0 && Option.is_none (view host).requested);
  assert (Option.is_none host.palette && host.prefix = 0);
  let previous = (view host).filter in
  let host =
    List.fold
      [ key Enter
      ; key (ASCII '\n')
      ; key (ASCII '\r')
      ; key (ASCII '\000')
      ; key Escape
      ; key Backspace
      ; key Tab
      ; Key_press { key = ASCII 'r'; mods = [ Ctrl ] }
      ]
      ~init:host
      ~f:send
  in
  assert (
    String.equal (view host).filter previous && (view host).editing && (view host).pasting);
  assert (Option.is_some (view host).filter_notice);
  List.iter
    [ Key.ASCII 'c'; ASCII 'C'; Uchar (Uchar.of_char 'c') ]
    ~f:(fun key ->
      match route_inspection_filter_event host (Key_press { key; mods = [ Ctrl ] }) with
      | Filter_interrupt -> ()
      | _ -> assert false);
  let owner_changed = { host with focus = None } in
  let owner_changed = send owner_changed (key (ASCII 'j')) in
  assert (String.equal (view owner_changed).filter (previous ^ "j"));
  let host = send host (Paste `End) in
  assert (
    (not host.paste) && Option.is_none host.inspection_paste && not (view host).pasting);
  let host = send host (key Backspace) in
  assert (String.equal (view host).filter payload);
  let host = send host (key Enter) in
  assert ((not (view host).editing) && Option.is_none (view host).requested);
  assert (String.equal (view host).stage "signoff" && (view host).generation = 0);
  match route_inspection_filter_event host (key (ASCII 'r')) with
  | Filter_pass -> ()
  | _ -> assert false
;;

let%test_unit "inspection filter paste enforces 4096 UTF-8 bytes and consumes orphaned \
               paste until end"
  =
  let open Bonsai_term.Event in
  let registry =
    W.initial ~session_id:(W.Session_id.of_string "inspection-paste-boundary")
  in
  let tile = List.hd_exn registry.tiles in
  let view =
    { (Inspection_view.create ~run:Fs0_fixture.run_a ~domain:"timing" ~stage:"signoff" ()) with
      editing = true
    ; filter = String.make 4094 'a'
    }
  in
  let host = receive empty registry in
  let host =
    set_local
      { host with focus = Some tile.id }
      tile.id
      { default_local with inspection = Some view }
  in
  let send host event =
    match route_inspection_filter_event host event with
    | Filter_handled host -> host
    | _ -> assert false
  in
  let key key = Key_press { key; mods = [] } in
  let current host = Option.value_exn (local host tile.id).inspection in
  let host = send host (Paste `Start) in
  let host = send host (key (Uchar (Uchar.of_scalar_exn 0x754c))) in
  assert (String.length (current host).filter = 4094);
  assert (Option.is_some (current host).filter_notice);
  let host = send host (key (Uchar (Uchar.of_scalar_exn 0xe9))) in
  assert (String.length (current host).filter = 4096);
  assert (String.is_suffix (current host).filter ~suffix:"é");
  let host = send host (key (ASCII 'r')) in
  assert (String.length (current host).filter = 4096 && (current host).generation = 0);
  let host = send host (Paste `End) |> fun host -> send host (key Backspace) in
  assert (String.length (current host).filter = 4094);
  let appended = Inspection_view.append_filter_text (current host) "é界" in
  assert (
    String.length appended.filter = 4096 && String.is_suffix appended.filter ~suffix:"é");
  let rejected = Inspection_view.append_filter_text (current host) "\255" in
  assert (
    String.equal rejected.filter (current host).filter
    && Option.is_some rejected.filter_notice);
  let host = send host (Paste `Start) in
  let host = set_local host tile.id default_local in
  let host = send host (key (ASCII 'r')) in
  assert (
    host.paste
    && Option.is_none (local host tile.id).inspection
    && Option.is_none host.palette);
  let host = send host (Paste `End) in
  assert ((not host.paste) && Option.is_none host.inspection_paste)
;;

let%test_unit "Timing workspace filter paste is literal and shared only within its \
               workspace"
  =
  let apply s mutation =
    W.apply s (Mutate { expected_revision = s.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let s = W.initial ~session_id:(W.Session_id.of_string "timing-paste") in
  let workspace = List.last_exn s.workspaces in
  let context = W.context s workspace.context in
  let s =
    apply
      s
      (Select_run
         { workspace = workspace.id
         ; context = context.id
         ; expected_selection_revision = context.selection_revision
         ; run = Some Fs0_fixture.run_a
         })
  in
  let s = apply s (P.Definition.apply P.Timing.definition ~workspace:workspace.id) in
  let tile =
    List.find_exn s.tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace workspace.id
      && String.equal tile.kind "timing-paths")
  in
  let host = switch (receive empty s) workspace.id in
  let host =
    set_timing
      { host with focus = Some tile.id }
      tile
      { (Timing_workspace.create ~generation:7 ~run:Fs0_fixture.run_a ~stage:"signoff") with
        editing = true
      }
  in
  let send host event =
    match route_inspection_filter_event host event with
    | Filter_handled host -> host
    | _ -> assert false
  in
  let host = send host (Paste `Start) in
  let host =
    String.fold "endpoint/Q ; r t j q" ~init:host ~f:(fun host ch ->
      send host (Key_press { key = ASCII ch; mods = [] }))
  in
  assert ((Option.value_exn (timing host tile)).generation = 7);
  assert (String.equal (Option.value_exn (timing host tile)).filter "endpoint/Q ; r t j q");
  assert (Option.is_none host.palette);
  let host = send host (Paste `End) in
  let host = send host (Key_press { key = Escape; mods = [] }) in
  assert (not (Option.value_exn (timing host tile)).editing);
  assert (not host.paste);
  match
    route_inspection_filter_event host (Key_press { key = ASCII 'c'; mods = [ Ctrl ] })
  with
  | Filter_interrupt -> ()
  | _ -> assert false
;;

let input t event ~commands : t * effect =
  match event with
  | Paste_start -> { t with paste = true; prefix = 0 }, No_effect
  | Paste_end -> { t with paste = false }, No_effect
  | _ when t.paste ->
    if not (finalization_form t)
    then t, No_effect
    else (
      match event with
      | Character ch -> append_reference t (String.of_char ch)
      | Text text -> append_reference t text
      | _ -> reject_reference_text t)
  | Character ch when finalization_form t -> append_reference t (String.of_char ch)
  | Text text when finalization_form t -> append_reference t text
  | Backspace when finalization_form t ->
    ( { t with
        palette =
          Option.map t.palette ~f:(fun p ->
            { p with query = drop_last_codepoint p.query; index = 0 })
      }
    , No_effect )
  | _ when t.editing_filter ->
    (match event, t.focus with
     | (Escape | Enter), _ -> { t with editing_filter = false }, No_effect
     | Clear_filter, Some id -> set_filter t id "", No_effect
     | Character ch, Some id ->
       let l = local t id in
       set_filter t id (l.filter ^ String.of_char ch), No_effect
     | Backspace, Some id ->
       let l = local t id in
       set_filter t id (String.drop_suffix l.filter 1), No_effect
     | _ -> t, No_effect)
  | _ ->
    (match t.palette with
     | Some p ->
       (match event with
        | Clear_filter -> { t with palette = Some (palette_query p "") }, No_effect
        | Escape -> { t with palette = None; prefix = 0 }, No_effect
        | Character _
          when match p.argument with
               | Some
                   ( Finalization_attempt _
                   | Resource_path _
                   | Workload_path
                   | Workload_bundle _
                   | Acceptance _
                   | Simulation_selection _ ) -> String.length p.query >= 4096
               | None | Some (Plan_endpoint _ | Preparation_inputs _) -> false ->
          { t with notice = "Finalization reference is limited to 4096 bytes" }, No_effect
        | Character ch ->
          ( { t with palette = Some (palette_query p (p.query ^ String.of_char ch)) }
          , No_effect )
        | Text text ->
          if printable_utf8 text && String.length p.query + String.length text <= 4096
          then { t with palette = Some (palette_query p (p.query ^ text)) }, No_effect
          else t, No_effect
        | Backspace ->
          ( { t with palette = Some (palette_query p (drop_last_codepoint p.query)) }
          , No_effect )
        | Next | Focus ->
          ( { t with
              palette =
                Some
                  { p with
                    index = Int.min (Int.max 0 (List.length (matches p) - 1)) (p.index + 1)
                  }
            }
          , No_effect )
        | Previous | Focus_previous ->
          { t with palette = Some { p with index = Int.max 0 (p.index - 1) } }, No_effect
        | Enter when Option.is_some p.argument ->
          if not (current t p.capture)
          then
            ( { t with palette = None; notice = "Command target changed; reopen palette" }
            , No_effect )
          else if finalization_form t && not (printable_utf8 p.query)
          then reject_reference_text t
          else if String.is_empty (String.strip p.query)
                  && not
                       (Option.exists p.argument ~f:(function
                         | Simulation_selection _ -> true
                         | _ -> false))
          then
            ( { t with
                notice = "An explicit endpoint or exact finalization attempt is required"
              }
            , No_effect )
          else if match p.argument with
                  | Some
                      ( Finalization_attempt _
                      | Resource_path _
                      | Workload_path
                      | Workload_bundle _
                      | Acceptance _
                      | Simulation_selection _ ) ->
                    String.length p.query > reference_limit t
                  | None | Some (Plan_endpoint _ | Preparation_inputs _) -> false
          then
            ( { t with notice = "Finalization reference is limited to 4096 bytes" }
            , No_effect )
          else (
            let operation =
              Or_error.try_with (fun () ->
                match Option.value_exn p.argument with
                | Resource_path bundle -> Resource_import_path (bundle, p.query)
                | Workload_path -> Workload_result (p.query, None)
                | Workload_bundle (left, generation) ->
                  Workload_input (Workloads_view.Capture (left, p.query, generation))
                | Finalization_attempt run ->
                  Asic (Asic.Operation.Inspect_finalization { run; attempt = p.query })
                | Acceptance (run, execution_file, key) ->
                  let acceptance = Asic.Acceptance.t_of_sexp (Sexp.of_string p.query) in
                  Asic
                    (Asic.Operation.Finalize
                       { key; run; execution_file; acceptance = Some acceptance })
                | Simulation_selection (tile, discovery_digest, submission_key, form) ->
                  (match Simulation_view.Form.accept form p.query |> Or_error.ok_exn with
                   | `Next form ->
                     Simulation_edit (tile, discovery_digest, submission_key, form)
                   | `Launch selection ->
                     Simulation
                       (tile, Launch { submission_key; discovery_digest; selection }))
                | (Plan_endpoint (flow, profile) | Preparation_inputs (flow, profile)) as
                  argument ->
                  let args =
                    String.split (String.strip p.query) ~on:' '
                    |> List.filter ~f:(Fn.non String.is_empty)
                  in
                  let endpoint = List.hd_exn args
                  and assignments = List.tl_exn args in
                  let selection =
                    { Asic.Selection.flow; profile; endpoint; assignments }
                  in
                  (match argument with
                   | Preparation_inputs _ -> Select_preparation selection
                   | _ -> Asic (Asic.Operation.Plan selection)))
            in
            match operation with
            | Ok operation -> { t with palette = None }, Execute (p.capture, operation)
            | Error error ->
              ( { t with notice = "Invalid typed input: " ^ Error.to_string_hum error }
              , No_effect ))
        | Enter ->
          (match List.nth (matches p) p.index with
           | None -> t, No_effect
           | Some _ when not (current t p.capture) ->
             ( { t with palette = None; notice = "Command target changed; reopen palette" }
             , No_effect )
           | Some { unavailable = Some reason; _ } ->
             { t with notice = reason }, No_effect
           | Some c -> { t with palette = None }, Execute (p.capture, c.action))
        | _ -> t, No_effect)
     | None ->
       (match event, t.prefix with
        | Clear_filter, _ ->
          let t =
            Option.value_map t.focus ~default:t ~f:(fun id ->
              let l = local t id in
              set_local t id { l with filter = ""; scroll = 0 })
          in
          { t with prefix = 0 }, No_effect
        | Character ' ', _ -> { t with prefix = 1 }, No_effect
        | Enter, 0
          when Option.exists (focused t) ~f:(fun tile ->
                 String.equal tile.kind "resource-summary") ->
          (match capture t with
           | None -> t, No_effect
           | Some capture -> t, Execute (capture, Open_resources))
        | ( ( Enter | Escape
            | Character
                ( 'j'
                | 'k'
                | 'r'
                | 'a'
                | 'd'
                | 'n'
                | 'p'
                | 'c'
                | 't'
                | 'g'
                | 'e'
                | '['
                | ']' )
            | Next | Previous )
          , 0 )
          when Option.exists (focused t) ~f:(fun tile ->
                 String.equal tile.kind "resources") ->
          let action =
            Resource_input
              (match event with
               | Enter -> Open
               | Escape -> Back
               | Character 'r' -> Refresh
               | Character 'a' -> Show_sources
               | Character 'd' -> Show_context
               | Character 'n' -> Next_page
               | Character 'p' -> Previous_page
               | Character 'c' -> Show_compare
               | Character 't' -> Section "timing"
               | Character 'g' -> Section "geometry"
               | Character 'e' -> Section "electrical"
               | Character 'k' | Previous -> Move (-1)
               | Character '[' -> Scroll (-8)
               | Character ']' -> Scroll 8
               | _ -> Move 1)
          in
          (match capture t with
           | None -> t, No_effect
           | Some capture -> t, Execute (capture, action))
        | ( ( Character ('j' | 'k' | 'r' | 'd' | 'c' | '[' | ']')
            | Next | Previous | Enter | Escape )
          , 0 )
          when Option.exists (focused t) ~f:(fun tile ->
                 String.equal tile.kind "workloads") ->
          let input =
            match event with
            | Enter -> Workloads_view.Open
            | Escape -> Back
            | Character 'r' -> Refresh
            | Character 'd' -> Show_provenance
            | Character 'c' -> Show_compare
            | Character '[' -> Scroll (-8)
            | Character ']' -> Scroll 8
            | Character 'k' | Previous -> Move (-1)
            | _ -> Move 1
          in
          (match capture t with
           | None -> t, No_effect
           | Some capture -> t, Execute (capture, Workload_input input))
        | (Character ('j' | 'k' | 'r' | 'i') | Next | Previous | Enter), 0
          when Option.exists (focused t) ~f:(fun tile ->
                 String.equal tile.kind "hierarchy") ->
          let tile = Option.value_exn (focused t) in
          let l = local t tile.id in
          (match event with
           | Character ('r' | 'i') ->
             (match capture t with
              | None -> t, No_effect
              | Some capture ->
                ( t
                , Execute
                    ( capture
                    , if Poly.equal event (Character 'r')
                      then Load_hierarchy tile.id
                      else Hierarchy_detail tile.id ) ))
           | _ ->
             let hierarchy =
               Option.map l.hierarchy ~f:(fun view ->
                 match event with
                 | Enter -> Hierarchy_view.toggle view
                 | Character 'k' | Previous -> Hierarchy_view.move view (-1)
                 | _ -> Hierarchy_view.move view 1)
             in
             set_local t tile.id { l with hierarchy }, No_effect)
        | Character 'c', 1 -> { t with prefix = 2 }, No_effect
        | Character 'c', 2 ->
          let palette =
            Option.map (capture t) ~f:(fun capture ->
              { capture; commands; query = ""; index = 0; argument = None })
          in
          { t with prefix = 0; palette }, No_effect
        (* Hint chords stay available while every hint area is hidden; they route through
           the same captured command path as the palette entries. *)
        | Character (('h' | 'p') as key), 2 ->
          let t = { t with prefix = 0 } in
          (match capture t with
           | None -> t, No_effect
           | Some capture ->
             ( t
             , Execute
                 ( capture
                 , if Char.equal key 'h' then Toggle_main_hints else Toggle_palette_hints
                 ) ))
        (* WB-054: explicit inspector close; also reachable over the explorer, whose key
           routing lets the Space prefix through. *)
        | Character 'x', 2 ->
          let t = { t with prefix = 0 } in
          (match capture t with
           | None -> t, No_effect
           | Some capture -> t, Execute (capture, Close_inspector))
        | Character '/', _ ->
          ( { t with
              editing_filter = true
            ; prefix = 0
            ; notice = "Filter: type text; Enter/Esc returns to browsing"
            }
          , No_effect )
        | (Focus | Focus_previous), _ ->
          let visible = navigation_tiles t in
          let index =
            List.findi visible ~f:(fun _ tile ->
              Option.value_map t.focus ~default:false ~f:(W.Tile_id.equal tile.id))
            |> Option.value_map
                 ~default:
                   (match event with
                    | Focus_previous -> 0
                    | _ -> -1)
                 ~f:fst
          in
          let focus =
            if List.is_empty visible
            then None
            else
              Option.map
                (List.nth
                   visible
                   ((index
                     + List.length visible
                     +
                     match event with
                     | Focus_previous -> -1
                     | _ -> 1)
                    mod List.length visible))
                ~f:(fun tile -> tile.id)
          in
          { t with focus; prefix = 0 }, No_effect
        | (Character 'j' | Next | Character 'k' | Previous), _
          when Option.exists (focused t) ~f:(fun tile ->
                 String.equal tile.kind "workspace-tabs") ->
          let tile = Option.value_exn (focused t) in
          let delta =
            match event with
            | Character 'k' | Previous -> -1
            | _ -> 1
          in
          browse_workspaces { t with prefix = 0 } tile.id ~delta, No_effect
        | (Character 'j' | Next | Character 'k' | Previous), _
          when Option.exists (focused t) ~f:(fun tile ->
                 String.equal tile.kind "preparation") ->
          let tile = Option.value_exn (focused t) in
          let l = local t tile.id in
          let all = Preparation_view.attempts t.preparation in
          let index =
            Option.bind l.cursor ~f:(fun id ->
              List.findi all ~f:(fun _ a -> String.equal a.id id))
            |> Option.value_map ~default:0 ~f:fst
          in
          let delta =
            match event with
            | Character 'k' | Previous -> -1
            | _ -> 1
          in
          let cursor =
            List.nth all (Int.max 0 (Int.min (List.length all - 1) (index + delta)))
            |> Option.map ~f:(fun a -> a.Preparation.Attempt.id)
          in
          ( set_local t tile.id { l with cursor; utility_detail = true; scroll = 0 }
          , No_effect )
        | Character 'x', _
          when Option.exists (focused t) ~f:(fun tile ->
                 String.equal tile.kind "planned-run") ->
          (match Planned_run.workflow t.planned_run, capture t with
           | Some w, Some captured when Planned_run.workflow_active w ->
             t, Execute (captured, Asic (Cancel_workflow w.id))
           | _ -> { t with notice = "No active fresh workflow" }, No_effect)
        | Character (('r' | 'x' | 'a') as key), _
          when Option.exists (focused t) ~f:(fun tile ->
                 String.equal tile.kind "preparation") ->
          let action =
            match key with
            | 'r' -> Prepare_project
            | 'x' -> Cancel_preparation
            | _ -> Preparation_artifact
          in
          (match capture t with
           | Some captured -> t, Execute (captured, action)
           | None -> t, No_effect)
        | Enter, _
          when Option.exists (focused t) ~f:(fun tile ->
                 String.equal tile.kind "preparation") ->
          let tile = Option.value_exn (focused t) in
          let l = local t tile.id in
          set_local t tile.id { l with utility_detail = true; scroll = 0 }, No_effect
        | Enter, _
          when Option.exists (focused t) ~f:(fun tile ->
                 String.equal tile.kind "workspace-tabs") ->
          let tile = Option.value_exn (focused t) in
          let t = { t with prefix = 0 } in
          (match workspace_cursor t tile.id, capture t with
           | Some workspace, Some capture -> t, Execute (capture, Switch workspace.id)
           | _ -> t, No_effect)
        | (Character ('j' | 'k' | 'n' | 'p' | 'x' | 'a') | Next | Previous), _
          when Option.exists (focused t) ~f:(fun tile ->
                 Testing_workspace.is_pane tile.kind) ->
          let tile = Option.value_exn (focused t) in
          let delta =
            match event with
            | Character ('k' | 'p') | Previous -> -1
            | _ -> 1
          in
          let state = testing_state t tile.id in
          let state =
            match Testing_workspace.pane tile.kind with
            | Some Catalog ->
              Testing_workspace.update_catalog state (fun catalog ->
                match event with
                | Character 'x' -> Simulation_catalog.toggle_current catalog
                | Character 'a' -> Simulation_catalog.select_all catalog
                | Character ('n' | 'p') -> Simulation_catalog.move_suite catalog delta
                | _ -> Simulation_catalog.move_case catalog delta)
            | Some Cases -> Testing_workspace.move_case state delta
            | Some Artifacts -> Testing_workspace.move_artifact state delta
            | Some Attempts ->
              let view = Testing_workspace.view state in
              let attempts =
                Option.value_map view.snapshot ~default:[] ~f:(fun s -> s.attempts)
              in
              let index =
                Option.bind view.attempt ~f:(fun id ->
                  List.findi attempts ~f:(fun _ a ->
                    String.equal id a.Simulation.Summary.id)
                  |> Option.map ~f:fst)
                |> Option.value ~default:(if delta > 0 then -1 else 1)
              in
              (match
                 List.nth
                   attempts
                   (Int.max 0 (Int.min (List.length attempts - 1) (index + delta)))
               with
               | None -> state
               | Some a when Option.equal String.equal view.attempt (Some a.id) -> state
               | Some a ->
                 let state = Testing_workspace.select_attempt state a.id in
                 (* Selection invalidates the previous receipt. Let the next shared
                    observation start even when the superseded request is in flight. *)
                 Testing_workspace.set_view
                   state
                   { (Testing_workspace.view state) with busy = false })
            | _ -> state
          in
          let t = update_testing t tile.id (fun _ -> state) in
          let local = local t tile.id in
          set_local t tile.id { local with follow = true }, No_effect
        | Enter, _
          when Option.exists (focused t) ~f:(fun tile ->
                 String.equal tile.kind "simulation-catalog") ->
          let tile = Option.value_exn (focused t) in
          (match capture t with
           | None -> t, No_effect
           | Some capture -> t, Execute (capture, testing_launch_action t tile.id))
        | Enter, _ -> { t with prefix = 0 }, Activate
        | _, _ -> { t with prefix = 0 }, No_effect))
;;

let%test_unit "hierarchy controls are focused, local and yield to palette and prefix" =
  let registry = W.initial ~session_id:(W.Session_id.of_string "hierarchy-controls") in
  let first = List.hd_exn registry.tiles in
  let second =
    { first with id = W.Tile_id.of_string "hierarchy-second"; kind = "hierarchy" }
  in
  let registry =
    { registry with
      tiles =
        [ { first with kind = "hierarchy"; binding = Pin_run Fs0_fixture.run_a }; second ]
    }
  in
  let host = receive empty registry in
  let evidence = Hierarchy_view.evidence Baseline_fixture.hierarchy in
  let host =
    List.fold [ first.id; second.id ] ~init:host ~f:(fun host id ->
      set_local
        host
        id
        { (local host id) with hierarchy = Some (Hierarchy_view.create evidence) })
  in
  let key host id =
    Hierarchy_view.selected_key (Option.value_exn (local host id).hierarchy)
  in
  let initial = key host first.id in
  let moved, effect = input host Next ~commands:[] in
  (match effect with
   | No_effect -> ()
   | _ -> assert false);
  assert (not (String.equal (key moved first.id) initial));
  assert (String.equal (key moved second.id) initial);
  let prefixed, _ = input { host with prefix = 1 } Next ~commands:[] in
  assert (String.equal (key prefixed first.id) initial);
  let palette =
    { capture = Option.value_exn (capture host)
    ; commands = []
    ; query = ""
    ; index = 0
    ; argument = None
    }
  in
  let modal, _ =
    input { host with palette = Some palette } (Character 'j') ~commands:[]
  in
  assert (String.equal (key modal first.id) initial);
  List.iter [ Character 'r'; Character 'i' ] ~f:(fun event ->
    match snd (input host event ~commands:[]) with
    | Execute (_, Load_hierarchy id) -> assert (W.Tile_id.equal id first.id)
    | Execute (_, Hierarchy_detail id) -> assert (W.Tile_id.equal id first.id)
    | _ -> assert false);
  let commands = catalog host ~project:None ~jobs:[] in
  assert (project_scoped_kind "hierarchy");
  assert (List.is_empty (evidence_runs host));
  assert (T.Binding.equal (binding_kind (Option.value_exn (focused host))) Project);
  let pin = List.find_exn commands ~f:(fun c -> String.equal c.id "tile.pin") in
  assert (
    Option.equal
      String.equal
      pin.unavailable
      (Some "This tile does not display run-scoped evidence"));
  assert (List.exists commands ~f:(fun c -> String.equal c.title "Add hierarchy tile"));
  assert (List.exists commands ~f:(fun c -> String.equal c.title "Load current hierarchy"))
;;

let%test_unit "catalog reducer browses filters and captures subset without launching" =
  let s = W.initial ~session_id:(W.Session_id.of_string "testing-keys") in
  let workspace = List.hd_exn s.workspaces in
  let s =
    W.apply
      s
      (Mutate
         { expected_revision = s.revision
         ; mutation = P.Definition.apply P.Testing.definition ~workspace:workspace.id
         })
    |> Result.ok
    |> Option.value_exn
  in
  let tile =
    List.find_exn s.tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace workspace.id
      && String.equal tile.kind "simulation-catalog")
  in
  let host = { (receive empty s) with focus = Some tile.id } in
  let suite : Simulation.Suite.t =
    { id = "fifo"
    ; label = "FIFO"
    ; cases = [ { id = "first"; label = "First" }; { id = "second"; label = "Second" } ]
    ; default_seed = "42"
    ; parameters = []
    }
  in
  let snapshot : Simulation.Snapshot.t =
    { configured = true
    ; discovery = Some { protocol_version = 1; suites = [ suite ] }
    ; discovery_digest = Some "exact-digest"
    ; discovery_job = None
    ; discovery_error = None
    ; attempts =
        [ { Simulation.Summary.id = "attempt"
          ; job = Job_id.of_string "job"
          ; suite = "fifo"
          ; seed = "42"
          ; execution_timing = None
          ; created_at = "now"
          ; parent = None
          ; lifecycle = Finished
          ; outcome = Passed
          }
        ]
    ; next_before = None
    ; history_error = None
    ; detail = None
    ; byte_page = None
    }
  in
  let host =
    update_testing host tile.id (fun state ->
      Testing_workspace.receive state ~ticket:0 ~selected:None Get (Ok snapshot))
  in
  let press host key =
    let host, effect = input host key ~commands:[] in
    (match effect with
     | No_effect -> ()
     | _ -> assert false);
    host
  in
  let host = press host (Character 'x') in
  let host =
    press host (Character '/')
    |> fun host -> press host (Character 's') |> fun host -> press host Enter
  in
  let catalog = Testing_workspace.catalog (testing_state host tile.id) in
  assert (List.equal String.equal (Simulation_catalog.selected_cases catalog) [ "second" ]);
  assert (String.equal (Simulation_catalog.filter catalog) "s");
  let host, effect = input host Enter ~commands:[] in
  (match effect with
   | Execute (_, Testing_launch (id, captured)) ->
     assert (W.Tile_id.equal id tile.id);
     assert (List.equal String.equal captured.inputs.selection.cases [ "second" ]);
     assert (Or_error.is_ok (validate_testing_launch host id captured))
   | _ -> assert false);
  (* Initial retained history now defaults to its newest attempt, independently of catalog
     filtering/launch capture. No execution or extra request was issued. *)
  assert (Option.equal String.equal (simulation host tile.id).attempt (Some "attempt"));
  assert ((simulation host tile.id).request = 0);
  let attempts =
    List.find_exn s.tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace workspace.id
      && String.equal tile.kind "simulation-attempts")
  in
  let host = { host with focus = Some attempts.id } in
  let host =
    update_testing host attempts.id (fun state ->
      Testing_workspace.select_attempt state "outside-history")
  in
  let pending = Simulation_view.begin_request (simulation host attempts.id) in
  let host = set_simulation host attempts.id pending in
  let host = press host (Character 'j') in
  assert (Option.equal String.equal (simulation host attempts.id).attempt (Some "attempt"));
  assert (not (simulation host attempts.id).busy);
  let late =
    Testing_workspace.receive
      (testing_state host attempts.id)
      ~ticket:pending.request
      ~selected:pending.attempt
      Get
      (Error "obsolete observation")
  in
  assert (Option.is_none (Testing_workspace.view late).error)
;;

let%test_unit "catalog launch captures exact inputs and rejects changed catalog choices" =
  let suite : Simulation.Suite.t =
    { id = "fifo"
    ; label = "FIFO"
    ; cases = [ { id = "a"; label = "A" }; { id = "b"; label = "B" } ]
    ; parameters = []
    ; default_seed = "42"
    }
  in
  let snapshot : Simulation.Snapshot.t =
    { configured = true
    ; discovery =
        Some { protocol_version = 1; suites = [ suite; { suite with id = "other" } ] }
    ; discovery_digest = Some "captured-digest"
    ; discovery_job = None
    ; discovery_error = None
    ; attempts = []
    ; next_before = None
    ; history_error = None
    ; detail = None
    ; byte_page = None
    }
  in
  let catalog = Simulation_catalog.update Simulation_catalog.empty snapshot in
  let captured = capture_testing_inputs catalog |> Or_error.ok_exn in
  assert (String.equal captured.suite.id "fifo");
  assert (String.equal captured.digest "captured-digest");
  assert (List.equal String.equal captured.selection.cases [ "a"; "b" ]);
  assert (Or_error.is_ok (validate_testing_inputs catalog captured));
  assert (
    Or_error.is_ok
      (validate_testing_inputs
         (Simulation_catalog.move_case catalog 1
          |> fun catalog -> Simulation_catalog.set_filter catalog "b")
         captured));
  let reject catalog =
    match validate_testing_inputs catalog captured with
    | Ok () -> assert false
    | Error error ->
      assert (String.is_substring (Error.to_string_hum error) ~substring:"reopen")
  in
  reject (Simulation_catalog.toggle_case catalog "a");
  reject (Simulation_catalog.select_suite catalog "other");
  reject
    (Simulation_catalog.update
       catalog
       { snapshot with discovery_digest = Some "new-digest" }
     |> Simulation_catalog.accept);
  reject
    (Simulation_catalog.update
       catalog
       { snapshot with
         discovery =
           Some { protocol_version = 1; suites = [ { suite with default_seed = "99" } ] }
       }
     |> Simulation_catalog.accept);
  reject (Simulation_catalog.begin_discovery catalog);
  reject (Simulation_catalog.discovery_failed catalog "authoritative discovery failed")
;;

let%test_unit "launch palette retains captured subset across model refresh and fences \
               workspace lifetime"
  =
  let registry =
    W.initial ~session_id:(W.Session_id.of_string "captured-testing-command")
  in
  let workspace = List.hd_exn registry.workspaces in
  let registry =
    W.apply
      registry
      (Mutate
         { expected_revision = registry.revision
         ; mutation = P.Definition.apply P.Testing.definition ~workspace:workspace.id
         })
    |> Result.ok
    |> Option.value_exn
  in
  let tile =
    List.find_exn registry.tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace workspace.id
      && String.equal tile.kind "simulation-catalog")
  in
  let suite : Simulation.Suite.t =
    { id = "fifo"
    ; label = "FIFO"
    ; cases = [ { id = "a"; label = "A" }; { id = "b"; label = "B" } ]
    ; default_seed = "42"
    ; parameters = []
    }
  in
  let snapshot : Simulation.Snapshot.t =
    { configured = true
    ; discovery = Some { protocol_version = 1; suites = [ suite ] }
    ; discovery_digest = Some "digest"
    ; discovery_job = None
    ; discovery_error = None
    ; attempts = []
    ; next_before = None
    ; history_error = None
    ; detail = None
    ; byte_page = None
    }
  in
  let host =
    receive empty registry
    |> fun host ->
    update_testing host tile.id (fun state ->
      Testing_workspace.receive state ~ticket:0 ~selected:None Get (Ok snapshot))
  in
  let command = testing_launch_command host tile.id in
  assert (Option.is_none command.unavailable);
  let captured =
    match command.action with
    | Testing_launch (_, captured) -> captured
    | _ -> assert false
  in
  assert (Or_error.is_ok (validate_testing_launch host tile.id captured));
  let palette =
    { capture = Option.value_exn (capture host)
    ; commands = [ command ]
    ; query = ""
    ; index = 0
    ; argument = None
    }
  in
  let host = { host with palette = Some palette; focus = Some tile.id } in
  let host =
    update_testing host tile.id (fun state ->
      Testing_workspace.update_catalog state (fun catalog ->
        Simulation_catalog.toggle_case catalog "a"))
  in
  let host, effect = input host Enter ~commands:[ testing_launch_command host tile.id ] in
  (match effect with
   | Execute (_, Testing_launch (id, actual)) ->
     assert (W.Tile_id.equal id tile.id);
     assert (List.equal String.equal actual.inputs.selection.cases [ "a"; "b" ]);
     assert (Or_error.is_error (validate_testing_launch host id actual))
   | _ -> assert false);
  let host =
    update_testing host tile.id (fun state ->
      Testing_workspace.update_catalog state (fun catalog ->
        Simulation_catalog.toggle_case catalog "a"))
  in
  (* Restore exact ordering so only the lifetime fence differs. *)
  let host =
    update_testing host tile.id (fun state ->
      Testing_workspace.update_catalog state Simulation_catalog.select_all)
  in
  assert (Or_error.is_ok (validate_testing_launch host tile.id captured));
  let _, scope, state = Option.value_exn (testing host tile.id) in
  let replaced = set_testing host tile.id (ref (), scope, state) in
  assert (Or_error.is_error (validate_testing_launch replaced tile.id captured));
  let disabled =
    update_testing host tile.id (fun state ->
      Testing_workspace.update_catalog state (fun catalog ->
        Simulation_catalog.discovery_failed catalog "exact failure"))
  in
  let command = testing_launch_command disabled tile.id in
  (match command.action with
   | Testing_launch_unavailable reason ->
     assert (Option.equal String.equal command.unavailable (Some reason));
     assert (String.is_substring reason ~substring:"exact failure")
   | _ -> assert false);
  assert (List.is_empty (simulation_log_commands tile));
  assert (List.length (simulation_log_commands { tile with kind = "simulation" }) = 1)
;;

let%test_unit "simulation palette paste captures cases without launching or losing \
               identity"
  =
  let host =
    receive empty (W.initial ~session_id:(W.Session_id.of_string "simulation-form"))
  in
  let capture = Option.value_exn (capture host) in
  let tile = (Option.value_exn (focused host)).id in
  let suite : Simulation.Suite.t =
    { id = "suite"
    ; label = "Suite"
    ; cases = [ { id = "a"; label = "A" } ]
    ; parameters = []
    ; default_seed = "42"
    }
  in
  let form = Simulation_view.Form.create suite in
  let host =
    { host with
      palette =
        Some
          { capture
          ; commands = []
          ; query = ""
          ; index = 0
          ; argument =
              Some (Simulation_selection (tile, "exact-digest", "exact-key", form))
          }
    }
  in
  let step host event =
    let host, effect = input host event ~commands:[] in
    (match effect with
     | No_effect -> ()
     | _ -> assert false);
    host
  in
  let host = List.fold [ Paste_start; Text "a"; Paste_end ] ~init:host ~f:step in
  let _, effect = input host Enter ~commands:[] in
  match effect with
  | Execute (_, Simulation_edit (actual_tile, digest, key, next)) ->
    assert (
      W.Tile_id.equal tile actual_tile
      && String.equal digest "exact-digest"
      && String.equal key "exact-key");
    assert (next.field = 1 && List.equal String.equal next.selection.cases [ "a" ])
  | _ -> assert false
;;

let select_run t run =
  match t.registry, active t with
  | Some s, Some w ->
    let c = W.context s w.context in
    Some
      (W.Mutation.Select_run
         { workspace = w.id
         ; context = c.id
         ; expected_selection_revision = c.selection_revision
         ; run
         })
  | _ -> None
;;

let%test_unit "persisted Runs-last Overview traverses the complete tree and wraps both \
               ways"
  =
  let registry = W.initial ~session_id:(W.Session_id.of_string "layout-focus-order") in
  let workspace = List.hd_exn registry.workspaces in
  let registry =
    W.apply
      registry
      (Mutate
         { expected_revision = registry.revision
         ; mutation = P.Definition.apply P.Overview.definition ~workspace:workspace.id
         })
    |> Result.ok
    |> Option.value_exn
  in
  let runs, others =
    List.partition_tf registry.tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace workspace.id
      && String.equal tile.kind "run-selector")
  in
  let registry = { registry with tiles = others @ runs } in
  let registry = W.Snapshot.t_of_sexp (W.Snapshot.sexp_of_t registry) in
  let host = receive empty registry in
  let expected =
    [ "workspace-tabs"
    ; "live-status"
    ; "run-selector"
    ; "resource-summary"
    ; "stage-checklist"
    ; "planned-run"
    ; "preparation"
    ; "synthesis"
    ; "timing"
    ; "placement"
    ; "routing"
    ; "checks"
    ; "finalization"
    ]
  in
  assert (String.equal (List.last_exn (tiles host)).kind "run-selector");
  assert (
    List.equal
      String.equal
      (List.map (navigation_tiles host) ~f:(fun tile -> tile.kind))
      expected);
  let step host event expected =
    let next, effect = input { host with prefix = 2 } event ~commands:[] in
    (match effect with
     | No_effect -> ()
     | _ -> assert false);
    assert (next.prefix = 0);
    assert (String.equal (Option.value_exn (focused next)).kind expected);
    assert (phys_equal next.registry host.registry);
    next
  in
  let host = { host with focus = None } in
  let forward = List.fold expected ~init:host ~f:(fun h kind -> step h Focus kind) in
  let wrapped = step forward Focus "workspace-tabs" in
  let backward =
    List.fold (List.rev expected) ~init:wrapped ~f:(fun h kind ->
      step h Focus_previous kind)
  in
  ignore (step backward Focus_previous "finalization" : t);
  List.iter
    [ None; Some (W.Tile_id.of_string "missing-focus") ]
    ~f:(fun focus ->
      ignore (step { host with focus } Focus "workspace-tabs" : t);
      ignore (step { host with focus } Focus_previous "finalization" : t));
  let preferred = { host with layout_mode = Preferred } in
  assert (List.equal W.Tile.equal (navigation_tiles preferred) (tiles preferred));
  ignore (step preferred Focus_previous "run-selector" : t);
  let unconfigured =
    { registry with
      workspaces = List.map registry.workspaces ~f:(fun w -> { w with preset = None })
    ; config_workspaces = []
    }
  in
  let host = receive empty unconfigured in
  assert (List.equal W.Tile.equal (navigation_tiles host) (tiles host))
;;

let%test_unit "keyed focus order distinguishes duplicate kinds and appends stable extras" =
  let config =
    P.Presets.custom_example () |> Or_error.ok_exn |> P.Presets.resolve |> Or_error.ok_exn
  in
  let registry = W.initial ~session_id:(W.Session_id.of_string "custom-focus-order") in
  let registry =
    W.apply registry (Initialize_config config) |> Result.ok |> Option.value_exn
  in
  let origin = List.hd_exn registry.config_workspaces in
  let tile key =
    W.tile registry (List.Assoc.find_exn origin.tiles key ~equal:String.equal)
  in
  let choose = tile "choose"
  and left = tile "left"
  and right = tile "right" in
  let extra_a = { left with id = W.Tile_id.of_string "extra-a" } in
  let extra_b = { right with id = W.Tile_id.of_string "extra-b" } in
  let registry =
    { registry with tiles = [ extra_b; left; choose; extra_a; right ] }
    |> W.Snapshot.sexp_of_t
    |> W.Snapshot.t_of_sexp
  in
  let host = receive empty registry in
  let ids tiles = List.map tiles ~f:(fun (tile : W.Tile.t) -> tile.id) in
  let expected = [ choose; right; left; extra_b; extra_a ] in
  assert (List.equal W.Tile_id.equal (ids (navigation_tiles host)) (ids expected));
  let step host event (tile : W.Tile.t) =
    let next, effect = input host event ~commands:[] in
    (match effect with
     | No_effect -> ()
     | _ -> assert false);
    assert (Option.equal W.Tile_id.equal next.focus (Some tile.id));
    next
  in
  let forward =
    List.fold expected ~init:{ host with focus = None } ~f:(fun h tile ->
      step h Focus tile)
  in
  let wrapped = step forward Focus choose in
  let backward =
    List.fold (List.rev expected) ~init:wrapped ~f:(fun h tile ->
      step h Focus_previous tile)
  in
  ignore (step backward Focus_previous extra_a : t);
  let hidden =
    { registry with
      tiles =
        List.map registry.tiles ~f:(fun tile ->
          if W.Tile_id.equal tile.id right.id then { tile with hidden = true } else tile)
    }
  in
  let host = receive empty hidden in
  assert (
    List.equal
      W.Tile_id.equal
      (ids (navigation_tiles host))
      (ids [ choose; left; extra_b; extra_a ]));
  ignore (step { host with focus = Some right.id } Focus choose : t);
  ignore (step { host with focus = Some right.id } Focus_previous extra_a : t)
;;

let%test_unit "Tab and Shift-Tab wrap only visible tiles and honor zoom and modals" =
  let s = W.initial ~session_id:(W.Session_id.of_string "reverse-focus") in
  let first = List.hd_exn s.tiles in
  let extra = { first with id = W.Tile_id.of_string "extra"; kind = "live-status" } in
  let hidden = { extra with id = W.Tile_id.of_string "hidden"; hidden = true } in
  let s = { s with tiles = s.tiles @ [ hidden; extra ] } in
  let host = receive empty s in
  let reverse =
    decode_event (Key_press { key = Tab; mods = [ Shift ] }) |> Option.value_exn
  in
  let step t event =
    let next, effect = input t event ~commands:[] in
    (match effect with
     | No_effect -> ()
     | _ -> assert false);
    next
  in
  let previous = step host reverse in
  assert (Option.equal W.Tile_id.equal previous.focus (Some extra.id));
  assert (Option.equal W.Tile_id.equal (step previous Focus).focus host.focus);
  let modal = step { host with editing_filter = true } reverse in
  assert (Option.equal W.Tile_id.equal modal.focus host.focus);
  let pasted = step { host with paste = true } reverse in
  assert (Option.equal W.Tile_id.equal pasted.focus host.focus);
  let workspace = List.hd_exn s.workspaces in
  let zoomed =
    { s with
      workspaces =
        List.map s.workspaces ~f:(fun w ->
          if W.Workspace_id.equal workspace.id w.id
          then { w with zoomed_tile = Some first.id }
          else w)
    }
  in
  let zoomed = step (receive host zoomed) reverse in
  assert (Option.equal W.Tile_id.equal zoomed.focus (Some first.id));
  assert (Option.equal W.Tile_id.equal (step zoomed Focus).focus (Some first.id));
  List.iter [ Focus; Focus_previous ] ~f:(fun event ->
    let no_tiles = step { (receive host { s with tiles = [] }) with prefix = 2 } event in
    assert (Option.is_none no_tiles.focus && no_tiles.prefix = 0))
;;

let%test_unit "palette similar commands capture Tab arrows aliases stable identity and \
               target"
  =
  let registry = W.initial ~session_id:(W.Session_id.of_string "fuzzy-palette") in
  let host = receive empty registry in
  let command id title aliases unavailable =
    { id; title; aliases; action = Toggle_chrome; unavailable }
  in
  let commands =
    [ command "inspect" "Inspect finalization" "reconnect evidence" None
    ; command "accept" "Finalize and accept" "acceptance" (Some "fixture unavailable")
    ; command "refresh" "Refresh finalization" "reload" None
    ]
  in
  let step host event = fst (input host event ~commands) in
  let opened =
    List.fold [ ' '; 'c'; 'c' ] ~init:host ~f:(fun host c -> step host (Character c))
  in
  let query host text =
    { host with palette = Option.map host.palette ~f:(fun p -> palette_query p text) }
  in
  let selected host =
    let p = Option.value_exn host.palette in
    (List.nth_exn (matches p) p.index).id
  in
  let narrowed = query opened "fn" in
  assert (List.length (matches (Option.value_exn narrowed.palette)) = 3);
  let next = step narrowed Focus in
  assert (not (String.equal (selected next) (selected narrowed)));
  assert (String.equal (selected (step next Focus_previous)) (selected narrowed));
  assert (String.equal (selected (step narrowed Next)) (selected next));
  assert (String.equal (selected (step next Previous)) (selected narrowed));
  assert (Option.equal W.Tile_id.equal next.focus host.focus);
  assert (phys_equal next.registry host.registry);
  let alias = query next "reconnect" in
  assert (String.equal (selected alias) "inspect");
  let _, effect = input alias Enter ~commands:[] in
  (match effect with
   | Execute (target, Toggle_chrome) ->
     assert (String.equal (W.Session_id.to_string target.session) "fuzzy-palette")
   | _ -> assert false);
  let accept = query next "accept" in
  let unavailable, effect = input accept Enter ~commands:[] in
  assert (
    Option.is_some unavailable.palette
    && String.equal unavailable.notice "fixture unavailable");
  (match effect with
   | No_effect -> ()
   | _ -> assert false);
  let edited = query next "final" in
  assert ((Option.value_exn edited.palette).index = 0);
  let unicode = step (query opened "界é") Backspace in
  assert (String.equal (Option.value_exn unicode.palette).query "界");
  assert (Option.is_none (step opened Escape).palette)
;;

let%test_unit "workspace tabs browse registry IDs and switch without mutating contexts" =
  let s = W.initial ~session_id:(W.Session_id.of_string "workspace-tabs") in
  let overview = List.hd_exn s.workspaces
  and timing = List.last_exn s.workspaces in
  let tile = { (List.hd_exn s.tiles) with kind = "workspace-tabs" } in
  (* Duplicate labels must not merge destinations; registry ordering is authoritative. *)
  let s =
    { s with
      tiles = tile :: List.tl_exn s.tiles
    ; workspaces = [ overview; { timing with name = overview.name } ]
    }
  in
  let host = receive empty s in
  let step t key = fst (input t key ~commands:[]) in
  assert (
    W.Workspace_id.equal (Option.value_exn (workspace_cursor host tile.id)).id overview.id);
  let browsed = step host (Character 'j') in
  assert (phys_equal browsed.registry host.registry);
  assert (Option.equal W.Workspace_id.equal browsed.active host.active);
  assert (
    W.Workspace_id.equal
      (Option.value_exn (workspace_cursor browsed tile.id)).id
      timing.id);
  let pending, effect = input browsed Enter ~commands:[] in
  assert (Option.equal W.Workspace_id.equal pending.active browsed.active);
  let selected =
    match effect with
    | Execute (_, Switch id) -> switch pending id
    | _ -> failwith "Sidebar Enter must use the host activation effect"
  in
  assert (Option.equal W.Workspace_id.equal selected.active (Some timing.id));
  assert (Option.equal W.Snapshot.equal selected.registry host.registry);
  let returned = switch selected overview.id in
  assert (Option.equal W.Tile_id.equal returned.focus (Some tile.id));
  assert (
    W.Workspace_id.equal
      (Option.value_exn (workspace_cursor returned tile.id)).id
      timing.id);
  assert (phys_equal (switch returned (W.Workspace_id.of_string "missing")) returned);
  let removed = receive browsed { s with workspaces = [ overview ] } in
  assert (
    W.Workspace_id.equal
      (Option.value_exn (workspace_cursor removed tile.id)).id
      overview.id);
  let renewed =
    receive browsed { s with session_id = W.Session_id.of_string "replacement" }
  in
  assert (List.is_empty renewed.locals && List.is_empty renewed.workspace_focus);
  assert (
    W.Workspace_id.equal
      (Option.value_exn (workspace_cursor renewed tile.id)).id
      overview.id)
;;

let%test_unit "overview utilities and explicit Testing creation are available additively" =
  let s = W.initial ~session_id:(W.Session_id.of_string "overview-commands") in
  let host = receive empty s in
  let commands = catalog host ~project:None ~jobs:[] in
  List.iter [ "live-status"; "workspace-tabs"; "stage-checklist" ] ~f:(fun kind ->
    assert (List.exists commands ~f:(fun c -> String.equal c.id ("tile.add." ^ kind)));
    assert (
      List.exists
        (missing_default_tiles s (List.hd_exn s.workspaces))
        ~f:(function
          | Create_tile spec -> String.equal spec.kind kind
          | _ -> false)));
  assert (project_scoped_kind "live-status" && project_scoped_kind "workspace-tabs");
  assert (not (project_scoped_kind "stage-checklist"));
  assert (project_scoped_kind "planned-run");
  assert (List.exists commands ~f:(fun c -> String.equal c.id "tile.add.planned-run"));
  assert (List.exists commands ~f:(fun c -> String.equal c.id "workspace.create-testing"));
  (* A preset label without panes is not a Testing capability. *)
  let testing = { (List.last_exn s.workspaces) with preset = Some "testing" } in
  let s = { s with workspaces = [ List.hd_exn s.workspaces; testing ] } in
  assert (
    List.exists
      (catalog (receive host s) ~project:None ~jobs:[])
      ~f:(fun c -> String.equal c.id "workspace.create-testing"));
  let s =
    { s with
      workspaces = List.map s.workspaces ~f:(fun w -> { w with preset = None })
    ; tiles =
        { (List.hd_exn s.tiles) with kind = "simulation-detail" } :: List.tl_exn s.tiles
    }
  in
  assert (
    not
      (List.exists
         (catalog (receive host s) ~project:None ~jobs:[])
         ~f:(fun c -> String.equal c.id "workspace.create-testing")))
;;

let%test_unit "planned-run browsing and scheme commands have no producer effect or run \
               binding"
  =
  let registry = W.initial ~session_id:(W.Session_id.of_string "planned-run-commands") in
  let tile = { (List.hd_exn registry.tiles) with kind = "planned-run" } in
  let registry = { registry with tiles = tile :: List.tl_exn registry.tiles } in
  let host = receive empty registry in
  let host = { host with focus = Some tile.id } in
  assert (T.Binding.equal (binding_kind tile) Project);
  let _, effect = input host Enter ~commands:[] in
  (match effect with
   | Activate -> ()
   | _ -> assert false);
  let selection : Asic.Selection.t =
    { flow = "flow"; profile = "profile"; endpoint = "endpoint"; assignments = [] }
  in
  let planned_run, ticket = Planned_run.begin_plan host.planned_run selection in
  let pending =
    set_local
      { host with planned_run }
      tile.id
      { default_local with utility_detail = true; scroll = 7 }
  in
  let escaped, effect = input pending Escape ~commands:[] in
  (match effect with
   | No_effect -> ()
   | _ -> assert false);
  assert (phys_equal escaped.planned_run pending.planned_run);
  assert (Planned_run.current_ticket escaped.planned_run ticket);
  let second = { tile with id = W.Tile_id.of_string "second-plan-tile" } in
  let pending = set_local pending second.id default_local in
  assert (phys_equal pending.planned_run planned_run);
  let host = pending in
  let changed =
    receive
      host
      { registry with
        revision = registry.revision + 1
      ; contexts =
          List.map registry.contexts ~f:(fun context ->
            { context with selected_run = Some Fs0_fixture.run_b })
      }
  in
  assert (phys_equal changed.planned_run host.planned_run);
  List.iter Appearance.Scheme.all ~f:(fun scheme ->
    let command =
      List.find_exn (appearance_commands host) ~f:(fun c ->
        String.equal c.id ("appearance.scheme." ^ Appearance.Scheme.key scheme))
    in
    match command.action with
    | Set_appearance appearance ->
      let changed = set_appearance host appearance in
      assert (Appearance.Scheme.equal changed.appearance.scheme scheme);
      assert (
        Appearance.equal
          { changed.appearance with scheme = host.appearance.scheme }
          host.appearance);
      assert (phys_equal changed.planned_run host.planned_run);
      assert (phys_equal changed.registry host.registry);
      assert (phys_equal changed.locals host.locals)
    | _ -> assert false)
;;

let%test_unit "finalization form dispatches only an explicit exact attempt and captured \
               run"
  =
  let snapshot = W.initial ~session_id:(W.Session_id.of_string "finalization-form") in
  let host = receive empty snapshot in
  let capture = Option.value_exn (capture host) in
  let run = Fs0_fixture.run_a in
  let form query =
    { host with
      palette =
        Some
          { capture
          ; commands = []
          ; query
          ; index = 0
          ; argument = Some (Finalization_attempt run)
          }
    }
  in
  let blank, effect = input (form "") Enter ~commands:[] in
  assert (Option.is_some blank.palette);
  (match effect with
   | No_effect -> ()
   | _ -> assert false);
  let bounded, effect =
    input (form (String.make 4096 'x')) (Character 'x') ~commands:[]
  in
  assert (String.length (Option.value_exn bounded.palette).query = 4096);
  (match effect with
   | No_effect -> ()
   | _ -> assert false);
  let _, effect = input (form (String.make 4097 'x')) Enter ~commands:[] in
  (match effect with
   | No_effect -> ()
   | _ -> assert false);
  let exact_attempt = "/private/returned operation attempt/operation.json" in
  let submitted, effect = input (form exact_attempt) Enter ~commands:[] in
  assert (Option.is_none submitted.palette);
  (match effect with
   | Execute (_, Asic (Inspect_finalization { run = actual; attempt })) ->
     assert (Run_ref.equal actual run);
     assert (String.equal attempt exact_attempt)
   | _ -> assert false);
  let stale =
    { (form "returned-operation-attempt") with
      registry = Some { snapshot with revision = snapshot.revision + 1 }
    }
  in
  let _, effect = input stale Enter ~commands:[] in
  (match effect with
   | No_effect -> ()
   | _ -> assert false);
  let escaped, effect = input (form "returned-operation-attempt") Escape ~commands:[] in
  assert (Option.is_none escaped.palette);
  match effect with
  | No_effect -> ()
  | _ -> assert false
;;

let%test_unit "acceptance form is typed bounded collateral captured with run and \
               execution"
  =
  let snapshot = W.initial ~session_id:(W.Session_id.of_string "acceptance-form") in
  let host = receive empty snapshot in
  let capture = Option.value_exn (capture host) in
  let run = Fs0_fixture.run_a in
  let execution_file = "/daemon/captured execution.json" in
  let acceptance : Asic.Acceptance.t =
    { support_tools = "/tools/界"
    ; precheck_python = "/python"
    ; testbench = "/explicit/tb with spaces.sv"
    ; testbench_top = "tb"
    ; replay_trace = "/explicit/trace"
    }
  in
  let query = Sexp.to_string_mach (Asic.Acceptance.sexp_of_t acceptance) in
  let form query =
    { host with
      palette =
        Some
          { capture
          ; commands = []
          ; query
          ; index = 0
          ; argument = Some (Acceptance (run, execution_file, "captured-key"))
          }
    }
  in
  let step t event = fst (input t event ~commands:[]) in
  let pasted = List.fold [ Paste_start; Text query; Paste_end ] ~init:(form "") ~f:step in
  assert (String.equal (Option.value_exn pasted.palette).query query);
  (match snd (input pasted Enter ~commands:[]) with
   | Execute
       ( _
       , Asic
           (Finalize
             { key
             ; run = actual
             ; execution_file = actual_file
             ; acceptance = Some actual_acceptance
             }) ) ->
     assert (String.equal key "captured-key" && Run_ref.equal run actual);
     assert (String.equal execution_file actual_file);
     assert (Asic.Acceptance.equal acceptance actual_acceptance)
   | _ -> assert false);
  List.iter
    [ ""; "((testbench /tb))"; String.make 4097 'x' ]
    ~f:(fun bad ->
      let after, effect = input (form bad) Enter ~commands:[] in
      assert (Option.is_some after.palette);
      match effect with
      | No_effect -> ()
      | _ -> assert false);
  let stale =
    { pasted with registry = Some { snapshot with revision = snapshot.revision + 1 } }
  in
  (match snd (input stale Enter ~commands:[]) with
   | No_effect -> ()
   | _ -> assert false);
  let first = List.hd_exn snapshot.tiles in
  let second = List.nth_exn snapshot.tiles 1 in
  let host =
    set_local
      host
      first.id
      { default_local with artifacts = Some (Artifact_view.create run) }
  in
  assert (Option.is_some (local host first.id).artifacts);
  assert (Option.is_none (local host second.id).artifacts)
;;

let%test_unit "finalization paths accept UTF-8 and bracketed paste without command \
               effects"
  =
  let snapshot = W.initial ~session_id:(W.Session_id.of_string "utf8-finalization") in
  let host = receive empty snapshot in
  let capture = Option.value_exn (capture host) in
  let form =
    { host with
      palette =
        Some
          { capture
          ; commands = []
          ; query = ""
          ; index = 0
          ; argument = Some (Finalization_attempt Fs0_fixture.run_a)
          }
    }
  in
  let commands = [ command "danger" "Build" "" Build ] in
  let step host event =
    let host, effect = input host event ~commands in
    (match effect with
     | No_effect -> ()
     | _ -> assert false);
    host
  in
  let query host = (Option.value_exn host.palette).query in
  let unicode =
    decode_event (Key_press { key = Uchar (Uchar.of_scalar_exn 0x754c); mods = [] })
    |> Option.value_exn
  in
  let typed = step (step form (Text "/tmp/")) unicode in
  assert (String.equal (query typed) "/tmp/界");
  let erased = step typed Backspace in
  assert (String.equal (query erased) "/tmp/");
  let typed = step (step erased unicode) (Text "/résultat.json") in
  let _, effect = input typed Enter ~commands in
  (match effect with
   | Execute (_, Asic (Inspect_finalization { attempt; _ })) ->
     assert (String.equal attempt "/tmp/界/résultat.json")
   | _ -> assert false);
  let pasted =
    List.fold
      [ Paste_start; Text "/tmp/界/"; Character 'b'; Text " c c/résultat.json" ]
      ~init:form
      ~f:step
  in
  assert pasted.paste;
  assert (Option.is_some pasted.palette);
  assert (is_interrupt (Key_press { key = ASCII 'c'; mods = [ Ctrl ] }));
  let rejected = step pasted Enter in
  assert (String.equal (query rejected) (query pasted));
  assert (String.is_substring rejected.notice ~substring:"newline/control");
  let pasted = step rejected Paste_end in
  assert (not pasted.paste);
  let _, effect = input pasted Enter ~commands in
  (match effect with
   | Execute (_, Asic (Inspect_finalization { attempt; _ })) ->
     assert (String.equal attempt "/tmp/界/b c c/résultat.json")
   | _ -> assert false);
  let ignored =
    List.fold
      [ Paste_start; Text "/tmp/界/"; Character 'b'; Enter; Paste_end ]
      ~init:host
      ~f:step
  in
  assert (Option.is_none ignored.palette);
  assert (ignored.prefix = 0)
;;

let%test_unit "finalization text rejects controls and truncates only at UTF-8 boundaries" =
  let host =
    receive empty (W.initial ~session_id:(W.Session_id.of_string "bounded-unicode"))
  in
  let capture = Option.value_exn (capture host) in
  let form query =
    { host with
      palette =
        Some
          { capture
          ; commands = []
          ; query
          ; index = 0
          ; argument = Some (Finalization_attempt Fs0_fixture.run_a)
          }
    }
  in
  let query host = (Option.value_exn host.palette).query in
  List.iter
    [ "bad\npath"; "bad\rpath"; "bad\tpath"; "bad\000path"; "\255" ]
    ~f:(fun text ->
      let after, effect = input (form "/safe/") (Text text) ~commands:[] in
      assert (String.equal (query after) "/safe/");
      assert (String.is_substring after.notice ~substring:"newline/control");
      match effect with
      | No_effect -> ()
      | _ -> assert false);
  let after, _ = input (form (String.make 4094 'x')) (Text "界") ~commands:[] in
  assert (String.length (query after) = 4094);
  assert (printable_utf8 (query after));
  let after, _ = input (form (String.make 4093 'x')) (Text "界é") ~commands:[] in
  assert (String.length (query after) = 4096);
  assert (String.is_suffix (query after) ~suffix:"界");
  assert (printable_utf8 (query after));
  assert (String.is_substring after.notice ~substring:"UTF-8 boundary");
  let erased, _ = input after Backspace ~commands:[] in
  assert (String.length (query erased) = 4093);
  let _, effect = input (form "/bad\npath") Enter ~commands:[] in
  match effect with
  | No_effect -> ()
  | _ -> assert false
;;

let%test_unit "metrics palette mode and scroll state belong to one synthesis tile" =
  let snapshot = W.initial ~session_id:(W.Session_id.of_string "metrics-local") in
  let snapshot =
    W.apply
      snapshot
      (Mutate
         { expected_revision = snapshot.revision
         ; mutation =
             Create_tile
               { workspace = (List.hd_exn snapshot.workspaces).id
               ; kind = "synthesis"
               ; geometry = { x = 0; y = 0; width = 64; height = 10 }
               }
         })
    |> Result.ok
    |> Option.value_exn
  in
  let host = receive empty snapshot in
  let synthesis =
    List.find_exn snapshot.tiles ~f:(fun tile -> String.equal tile.kind "synthesis")
  in
  let other =
    List.find_exn snapshot.tiles ~f:(fun tile ->
      not (W.Tile_id.equal tile.id synthesis.id))
  in
  let host = { host with focus = Some synthesis.id } in
  let commands = catalog host ~project:None ~jobs:[] in
  let command =
    List.find_exn commands ~f:(fun command -> String.equal command.id "synthesis.metrics")
  in
  (match command.action with
   | Synthesis_mode Metrics -> ()
   | _ -> assert false);
  let state = Synthesis_view.State.set_mode (local host synthesis.id).synthesis Metrics in
  let state = Synthesis_view.State.scroll state ~delta:7 ~max_offset:7 in
  let updated =
    set_local host synthesis.id { (local host synthesis.id) with synthesis = state }
  in
  assert (
    Synthesis_view.Mode.equal
      (Synthesis_view.State.mode (local updated synthesis.id).synthesis)
      Metrics);
  assert (
    Synthesis_view.Mode.equal
      (Synthesis_view.State.mode (local updated other.id).synthesis)
      Summary);
  assert (phys_equal host.registry updated.registry);
  let other_commands =
    catalog { host with focus = Some other.id } ~project:None ~jobs:[]
  in
  assert (
    not
      (List.exists other_commands ~f:(fun command ->
         String.equal command.id "synthesis.metrics")))
;;

let%test_unit "Ctrl-U clears focused filters without submitting or touching other tiles" =
  let snapshot = W.initial ~session_id:(W.Session_id.of_string "filter-recovery") in
  let host = receive empty snapshot in
  let first = List.hd_exn snapshot.tiles
  and other = List.last_exn snapshot.tiles in
  let host = set_local host first.id { default_local with filter = "no-match" } in
  let host = set_local host other.id { default_local with filter = "keep" } in
  let recover editing_filter =
    let before = { host with editing_filter } in
    let after, effect = input before Clear_filter ~commands:[] in
    assert (String.is_empty (local after first.id).filter);
    assert (String.equal (local after other.id).filter "keep");
    assert (phys_equal before.registry after.registry);
    assert (Bool.equal after.editing_filter editing_filter);
    match effect with
    | No_effect -> ()
    | _ -> assert false
  in
  recover true;
  recover false;
  match decode_event (Key_press { key = ASCII 'u'; mods = [ Ctrl ] }) with
  | Some Clear_filter -> ()
  | _ -> assert false
;;

type launch_target =
  { session_id : W.Session_id.t
  ; workspace_id : W.Workspace_id.t
  ; context_id : W.Context_id.t
  ; binding_revision : int
  ; selection_revision : int
  }

let launch_target t =
  match t.registry, active t with
  | Some s, Some w ->
    let c = W.context s w.context in
    Some
      { session_id = s.session_id
      ; workspace_id = w.id
      ; context_id = c.id
      ; binding_revision = w.binding_revision
      ; selection_revision = c.selection_revision
      }
  | _ -> None
;;

let selection_after_allocation (s : W.Snapshot.t) target run =
  let w =
    List.find s.workspaces ~f:(fun w -> W.Workspace_id.equal w.id target.workspace_id)
  in
  let c = List.find s.contexts ~f:(fun c -> W.Context_id.equal c.id target.context_id) in
  match w, c with
  | Some w, Some c
    when W.Session_id.equal s.session_id target.session_id
         && W.Context_id.equal w.context c.id
         && w.binding_revision = target.binding_revision
         && c.selection_revision = target.selection_revision ->
    Some
      (W.Mutation.Select_run
         { workspace = w.id
         ; context = c.id
         ; expected_selection_revision = c.selection_revision
         ; run = Some run
         })
  | _ -> None
;;

let%test_unit "focus with no visible tiles returns an option and a distinct no-effect" =
  let s = W.initial ~session_id:(W.Session_id.of_string "empty-focus") in
  let s = { s with tiles = [] } in
  let t = receive empty s in
  let t, effect = input t Focus ~commands:[] in
  let focus : W.Tile_id.t option = t.focus in
  assert (Option.is_none focus);
  assert (
    match effect with
    | No_effect -> true
    | _ -> false);
  let reference : W.Mutation.t option = select_run empty None in
  assert (Option.is_none reference)
;;

let%test_unit "actual catalog and palette can cancel an allocated owned launch but not \
               history"
  =
  let run : Run_ref.t =
    { backend = Backend_id.of_string "asic"
    ; id = "allocated"
    ; build = None
    ; label = None
    }
  in
  let active : Asic.Pending.t =
    { key = "run:allocated"
    ; kind = "run"
    ; state = "executing"
    ; run = Some run
    ; error = None
    ; activity = Unreported
    }
  in
  let snapshot : Asic.Snapshot.t =
    { configured = true
    ; launches = []
    ; fresh_intent = None
    ; workflows = []
    ; resources = None
    ; workloads = None
    ; flows = []
    ; catalog_default = None
    ; description_json = None
    ; preview = None
    ; runs = []
    ; operations =
        [ active
        ; { active with key = "run:completed"; state = "completed" }
        ; { active with key = "run:detached"; state = "detached" }
        ; { active with
            key = "run:failed"
          ; state = "failed"
          ; error = Some "fixture failure"
          }
        ; { active with key = "run:queued"; state = "pending"; run = None }
        ]
    ; summaries = []
    ; cache_error = None
    ; finalizations = []
    ; artifacts = []
    ; artifact_pages = []
    ; artifact_byte_pages = []
    ; inspections = []
    ; inspection_details = []
    }
  in
  let commands = asic_cancel_commands snapshot in
  assert (List.length commands = 2);
  let t =
    receive
      empty
      (W.initial ~session_id:(W.Session_id.of_string "cancel-after-allocation"))
  in
  let press t key = input t key ~commands in
  let t, _ = press t (Character ' ') in
  let t, _ = press t (Character 'c') in
  let t, _ = press t (Character 'c') in
  let t =
    List.fold (String.to_list "run:allocated") ~init:t ~f:(fun t ch ->
      fst (press t (Character ch)))
  in
  let _, effect = press t Enter in
  assert (
    match effect with
    | Execute (_, Asic (Cancel key)) -> String.equal key active.key
    | _ -> false)
;;

let%test_unit "selectors and project-scoped tiles do not acquire ASIC evidence interest" =
  let s = W.initial ~session_id:(W.Session_id.of_string "evidence-interest") in
  let workspace = (List.hd_exn s.workspaces).id in
  let run : Run_ref.t =
    { backend = Backend_id.of_string "asic"; id = "selected"; build = None; label = None }
  in
  let apply s mutation =
    W.apply s (Mutate { expected_revision = s.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let s =
    apply
      s
      (Select_run
         { workspace
         ; context = s.main_context
         ; expected_selection_revision = 0
         ; run = Some run
         })
  in
  let geometry : W.Geometry.t = { x = 0; y = 0; width = 40; height = 8 } in
  let s = apply s (Create_tile { workspace; kind = "project-tests"; geometry }) in
  assert (List.is_empty (evidence_runs (receive empty s)));
  let s = apply s (Create_tile { workspace; kind = "timing"; geometry }) in
  let timing = List.last_exn s.tiles in
  assert (List.equal Run_ref.equal (evidence_runs (receive empty s)) [ run ]);
  let s = apply s (Set_tile_hidden { tile = timing.id; hidden = true }) in
  assert (List.is_empty (evidence_runs (receive empty s)))
;;

let%test_unit "blank workspaces have unique names and IDs, share Main, and accept tiles \
               through the palette without a focused tile"
  =
  let apply s mutation =
    W.apply s (Mutate { expected_revision = s.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let invoke host query =
    let commands = catalog host ~project:None ~jobs:[] in
    let press host event = input host event ~commands in
    let host =
      List.fold [ ' '; 'c'; 'c' ] ~init:host ~f:(fun host ch ->
        fst (press host (Character ch)))
    in
    assert (Option.is_some host.palette);
    let host, _ = press host (Text query) in
    let palette = Option.value_exn host.palette in
    let index, _ =
      List.findi_exn (matches palette) ~f:(fun _ command ->
        String.equal command.title query)
    in
    let host = { host with palette = Some { palette with index } } in
    press host Enter
  in
  let initial = W.initial ~session_id:(W.Session_id.of_string "blank-workspaces") in
  let original = List.hd_exn initial.workspaces in
  let registry = apply initial (Make_independent original.id) in
  let host = receive empty registry in
  let host, effect = invoke host "Create blank workspace" in
  (match effect with
   | Execute (_, Create_blank_workspace) -> ()
   | _ -> assert false);
  assert (W.Snapshot.equal (Option.value_exn host.registry) registry);
  let first =
    apply registry (blank_workspace_mutation registry ~window:original.window)
  in
  let id = Option.value_exn (created_workspace ~before:registry ~after:first) in
  let workspace = W.workspace first id in
  assert (String.equal workspace.name "Workspace 1");
  assert (W.Window_id.equal workspace.window original.window);
  assert (W.Context_id.equal workspace.context first.main_context);
  assert (Option.is_none workspace.preset && Option.is_none workspace.zoomed_tile);
  assert (List.equal W.Tile.equal registry.tiles first.tiles);
  let host = switch (receive host first) id in
  assert (Option.equal W.Workspace_id.equal host.active (Some id));
  assert (Option.is_none host.focus && List.is_empty (tiles host));
  let host, effect = invoke host "Add logs tile" in
  let populated =
    match effect with
    | Execute (capture, Registry (Create_tile args as mutation)) ->
      assert (W.Workspace_id.equal capture.workspace id);
      assert (W.Workspace_id.equal args.workspace id);
      apply first mutation
    | _ -> assert false
  in
  let host = receive host populated in
  let tile = Option.value_exn (focused host) in
  assert (String.equal tile.kind "logs" && W.Binding.equal tile.binding Follow);
  let second =
    apply populated (blank_workspace_mutation populated ~window:original.window)
  in
  let second_id = Option.value_exn (created_workspace ~before:populated ~after:second) in
  assert (not (W.Workspace_id.equal id second_id));
  assert (String.equal (W.workspace second second_id).name "Workspace 2");
  let host = switch (switch (receive host second) second_id) id in
  assert (Option.equal W.Tile_id.equal host.focus (Some tile.id));
  let renamed =
    apply second (Rename_workspace { workspace = id; name = "Workspace 3" })
  in
  let third = apply renamed (blank_workspace_mutation renamed ~window:original.window) in
  let third_id = Option.value_exn (created_workspace ~before:renamed ~after:third) in
  assert (String.equal (W.workspace third third_id).name "Workspace 1");
  assert (not (W.Workspace_id.equal id third_id));
  assert (Option.is_none (created_workspace ~before:third ~after:third));
  assert (
    Option.is_none
      (created_workspace
         ~before:renamed
         ~after:{ third with session_id = W.Session_id.of_string "replacement" }));
  let saved = navigation_preferences ~project_key:"blank" (switch host second_id) in
  let restored =
    restore_navigation_focus
      (Option.value_exn saved)
      (receive empty second)
      ~restore_active:true
      ~preserve_focus:[]
  in
  assert (Option.equal W.Workspace_id.equal restored.active (Some second_id));
  assert (Option.is_none restored.focus)
;;

let%test_unit "palette captures text and revalidates registry target" =
  let s = W.initial ~session_id:(W.Session_id.of_string "test") in
  let t = receive empty s in
  let commands = [ command "test" "Run project tests" "" Test ] in
  let press t key = input t key ~commands in
  let t, _ = press t (Character ' ') in
  let t, _ = press t (Character 'c') in
  let t, _ = press t (Character 'c') in
  let t, effect = press t (Character 't') in
  assert (Option.is_some t.palette);
  assert (
    match effect with
    | No_effect -> true
    | _ -> false);
  let changed =
    W.apply
      s
      (Mutate
         { expected_revision = 0
         ; mutation = Make_independent (List.last_exn s.workspaces).id
         })
    |> Result.ok
    |> Option.value_exn
  in
  let t = receive t changed in
  let t, effect = press t Enter in
  assert (Option.is_none t.palette);
  assert (
    match effect with
    | No_effect -> true
    | _ -> false)
;;

let%test_unit "linked contexts and pins use registry semantics; local state survives" =
  let s = W.initial ~session_id:(W.Session_id.of_string "test") in
  let t = receive empty s in
  let tile = List.hd_exn s.tiles in
  let t = set_local t tile.id { default_local with scroll = 7; filter = "old" } in
  let run : Run_ref.t =
    { backend = Backend_id.of_string "asic"; id = "A"; build = None; label = None }
  in
  let mutation = select_run t (Some run) |> Option.value_exn in
  let s =
    W.apply s (Mutate { expected_revision = s.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let t = receive t s in
  assert ((local t tile.id).scroll = 7);
  List.iter s.tiles ~f:(fun tile ->
    let r = W.resolve_tile s tile.id |> Result.ok |> Option.value_exn in
    assert (Option.equal Run_ref.equal r.run (Some run)))
;;

let%test_unit "frontend events capture modal shortcuts, bracketed paste and focus" =
  let s = W.initial ~session_id:(W.Session_id.of_string "events") in
  let commands = [ command "test" "Run project tests" "" Test ] in
  let send t event =
    match decode_event event with
    | None -> t, No_effect
    | Some event -> input t event ~commands
  in
  let key ch : Bonsai_term.Event.t = Key_press { key = ASCII ch; mods = [] } in
  let t = receive empty s in
  let t, _ = send t (key ' ') in
  let t, _ = send t (key 'c') in
  let t, _ = send t (key 'c') in
  let focus = t.focus in
  let t, effect = send t (key 'q') in
  assert (
    match effect with
    | No_effect -> true
    | _ -> false);
  assert (String.equal (Option.value_exn t.palette).query "q");
  let t, _ = send t (Paste `Start) in
  let t, _ = send t (key 't') in
  let t, _ = send t (Paste `End) in
  assert (String.equal (Option.value_exn t.palette).query "q");
  let t, _ = send t (Key_press { key = Escape; mods = [] }) in
  assert (Option.equal W.Tile_id.equal t.focus focus);
  assert (Option.is_none t.palette)
;;

let%test_unit "pin, unlink and relink fence delayed reads without sharing local \
               navigation"
  =
  let s = W.initial ~session_id:(W.Session_id.of_string "fences") in
  let overview = List.hd_exn s.workspaces
  and timing = List.last_exn s.workspaces in
  let a : Run_ref.t =
    { backend = Backend_id.of_string "asic"; id = "A"; build = None; label = None }
  in
  let b = { a with id = "B" } in
  let apply s mutation =
    W.apply s (Mutate { expected_revision = s.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let choose s workspace run =
    let w = W.workspace s workspace in
    let c = W.context s w.context in
    apply
      s
      (Select_run
         { workspace
         ; context = c.id
         ; expected_selection_revision = c.selection_revision
         ; run = Some run
         })
  in
  let s = choose s overview.id a in
  let selector = List.last_exn s.tiles in
  let old = W.resolve_tile s selector.id |> Result.ok |> Option.value_exn in
  let s = apply s (Make_independent timing.id) in
  assert (not (W.view_is_current s old));
  let s = choose s overview.id b in
  let resolved = W.resolve_tile s selector.id |> Result.ok |> Option.value_exn in
  assert (Option.equal Run_ref.equal resolved.run (Some a));
  let s = apply s (Set_tile_binding { tile = selector.id; binding = Pin_run a }) in
  let s = apply s (Link_context { workspace = timing.id; context = s.main_context }) in
  let pinned = W.resolve_tile s selector.id |> Result.ok |> Option.value_exn in
  assert (Option.equal Run_ref.equal pinned.run (Some a));
  let s = apply s (Set_tile_binding { tile = selector.id; binding = Follow }) in
  let following = W.resolve_tile s selector.id |> Result.ok |> Option.value_exn in
  assert (Option.equal Run_ref.equal following.run (Some b));
  let t = receive empty s in
  let t = set_local t selector.id { default_local with filter = "A"; scroll = 9 } in
  let t = switch (switch t timing.id) overview.id in
  assert ((local t selector.id).scroll = 9);
  assert (String.equal (local t selector.id).filter "A");
  assert (not (W.view_is_current s pinned))
;;

let%test_unit "additive default preset exposes synthesis and preserves saved contexts, \
               hidden tiles and geometry"
  =
  let s = W.initial ~session_id:(W.Session_id.of_string "additive-layout") in
  let workspace = List.hd_exn s.workspaces in
  let apply s mutation =
    W.apply s (Mutate { expected_revision = s.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let s = apply s (Make_independent workspace.id) in
  let context = W.context s (W.workspace s workspace.id).context in
  let s =
    apply
      s
      (Select_run
         { workspace = workspace.id
         ; context = context.id
         ; expected_selection_revision = context.selection_revision
         ; run = Some Fs0_fixture.run_b
         })
  in
  let selector = List.hd_exn s.tiles in
  let s = apply s (Set_tile_hidden { tile = selector.id; hidden = true }) in
  let original_contexts = s.contexts
  and original_workspaces = s.workspaces in
  let workspace = W.workspace s workspace.id in
  let pending = missing_default_tiles s workspace in
  assert (
    List.exists pending ~f:(function
      | Create_tile { kind = "synthesis"; _ } -> true
      | _ -> false));
  let s =
    apply
      s
      (P.Definition.apply
         (Option.value_exn (definition workspace))
         ~workspace:workspace.id)
  in
  assert (List.equal W.Context.equal original_contexts s.contexts);
  assert (List.equal W.Arrangement.equal original_workspaces s.workspaces);
  assert (W.Tile.equal (W.tile s selector.id) { selector with hidden = true });
  assert (List.is_empty (missing_default_tiles s workspace));
  let commands = catalog (receive empty s) ~project:None ~jobs:[] in
  assert (
    List.exists commands ~f:(fun command -> String.equal command.id "tile.add.synthesis"));
  assert (
    List.exists commands ~f:(fun command ->
      match command.action with
      | Apply_default_layout -> true
      | _ -> false))
;;

let%test_unit "presentation inherits by stable IDs and palette captures exact tile \
               overrides"
  =
  let registry = W.initial ~session_id:(W.Session_id.of_string "presentation-policy") in
  let tile = List.hd_exn registry.tiles in
  let host = receive empty registry in
  assert (T.Badge.equal (policy host tile).badge Exceptions);
  assert ((policy host tile).run_selector_rows = 4);
  let global =
    { host with
      presentation = { T.inherit_ with run_selector_rows = Some 7; header = Some false }
    }
  in
  assert ((policy global tile).run_selector_rows = 7);
  let workspace_override =
    { global with
      workspace_presentation =
        [ ( W.Workspace_id.to_string tile.workspace
          , { T.inherit_ with run_selector_rows = Some 6 } )
        ]
    }
  in
  assert ((policy workspace_override tile).run_selector_rows = 6);
  let tile_override =
    set_local
      workspace_override
      tile.id
      { default_local with
        presentation = { T.inherit_ with run_selector_rows = Some 5; header = Some true }
      }
  in
  assert (
    (policy tile_override tile).run_selector_rows = 5
    && (policy tile_override tile).header);
  let reset_tile = set_local tile_override tile.id default_local in
  assert (
    (policy reset_tile tile).run_selector_rows = 6 && not (policy reset_tile tile).header);
  let host =
    { host with
      presentation = { T.inherit_ with padding = Some 2; hints = Some false }
    ; workspace_presentation =
        [ W.Workspace_id.to_string tile.workspace, { T.inherit_ with padding = Some 1 } ]
    }
  in
  assert ((policy host tile).padding = 1 && not (policy host tile).hints);
  let host =
    set_local
      host
      tile.id
      { default_local with
        presentation = { T.inherit_ with padding = Some 0; hints = Some true }
      }
  in
  assert ((policy host tile).padding = 0 && (policy host tile).hints);
  let reset =
    List.find_exn (presentation_commands host tile) ~f:(fun c ->
      String.equal c.id "tile.presentation.reset")
  in
  (match reset.action with
   | Set_presentation (id, overrides) ->
     assert (W.Tile_id.equal id tile.id && T.equal_overrides overrides T.inherit_)
   | _ -> assert false);
  let renamed =
    { registry with
      workspaces =
        List.map registry.workspaces ~f:(fun w -> { w with name = "User name" })
    }
  in
  let host = receive host renamed in
  assert ((policy host tile).padding = 0 && (policy host tile).hints);
  assert (Option.is_some (definition (List.hd_exn renamed.workspaces)));
  let fresh = receive host { renamed with session_id = W.Session_id.of_string "other" } in
  assert (List.is_empty fresh.locals && List.is_empty fresh.workspace_presentation);
  assert ((policy fresh tile).padding = 2 && not (policy fresh tile).hints);
  let commands = catalog host ~project:None ~jobs:[] in
  List.iter P.Presets.all ~f:(fun d ->
    let command =
      List.find_exn commands ~f:(fun c ->
        String.equal c.id ("workspace.apply-preset." ^ d.P.Definition.id))
    in
    match command.action with
    | Registry (Apply_preset { workspace; preset; tiles }) ->
      assert (W.Workspace_id.equal workspace tile.workspace && String.equal preset d.id);
      assert (
        List.equal
          (fun (a, g) (b, h) -> String.equal a b && W.Geometry.equal g h)
          tiles
          (P.Definition.specs d))
    | _ -> assert false)
;;

let%test_unit "allocation selects only an unchanged captured context" =
  let s = W.initial ~session_id:(W.Session_id.of_string "allocation") in
  let t = receive empty s in
  let target = launch_target t |> Option.value_exn in
  let run : Run_ref.t =
    { backend = Backend_id.of_string "asic"
    ; id = "allocated"
    ; build = None
    ; label = None
    }
  in
  assert (Option.is_some (selection_after_allocation s target run));
  let s =
    W.apply
      s
      (Mutate { expected_revision = 0; mutation = Make_independent target.workspace_id })
    |> Result.ok
    |> Option.value_exn
  in
  assert (Option.is_none (selection_after_allocation s target run));
  let s =
    W.apply
      s
      (Mutate
         { expected_revision = s.revision
         ; mutation =
             Link_context { workspace = target.workspace_id; context = target.context_id }
         })
    |> Result.ok
    |> Option.value_exn
  in
  assert (Option.is_none (selection_after_allocation s target run))
;;

let%test_unit "Waveforms pins survive navigation and restore but reject reused identities"
  =
  let apply snapshot mutation =
    W.apply
      snapshot
      (Mutate { expected_revision = snapshot.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let before = W.initial ~session_id:(W.Session_id.of_string "waveform-pins") in
  let registry =
    apply before (P.Waveforms.create ~window:(List.hd_exn before.windows).id)
  in
  let workspace = Option.value_exn (P.Waveforms.find registry) in
  let artifact : Simulation.Artifact.t =
    { id = "trace"
    ; attempt_id = "attempt"
    ; case_id = Some "failed-case"
    ; label = "retained trace"
    ; kind = "waveform"
    ; media_type = "text/x-vcd"
    ; size = Some 40
    ; sha256 = Some "exact-digest"
    ; availability = Available
    }
  in
  let pin : P.Waveforms.pin =
    { project_key = "root/env"
    ; project = Project_id.of_string "p"
    ; artifact
    ; log =
        Job
          { instance_id = V1.Daemon_instance_id.of_string "daemon"
          ; job = Job_id.of_string "job"
          }
    }
  in
  let host = set_waveform_pin (receive empty registry) workspace.id pin in
  let token host = Option.value_exn (waveform_identity host workspace.id) in
  let identity = token host in
  assert (phys_equal identity (token (set_waveform_pin host workspace.id pin)));
  let host = switch (switch host workspace.id) (List.hd_exn before.workspaces).id in
  assert (phys_equal identity (token host));
  let changed =
    set_waveform_pin
      host
      workspace.id
      { pin with artifact = { artifact with id = "other" } }
  in
  assert (not (phys_equal identity (token changed)));
  let again = set_waveform_pin changed workspace.id pin in
  assert (not (phys_equal identity (token again)));
  let same_transport = reconnect host ~replacement:false in
  assert (
    Option.equal
      P.Waveforms.equal_pin
      (waveform_pin same_transport workspace.id)
      (Some pin));
  assert (not (phys_equal identity (token same_transport)));
  let saved = waveform_preferences ~project_key:pin.project_key host in
  let data = encode_waveform_preferences saved in
  let decoded = decode_waveform_preferences ~project_key:pin.project_key data in
  let state_directory = Filename_unix.temp_dir ~perm:0o700 "waveform-preferences-" "" in
  let path = waveform_preferences_path ~state_directory ~project_key:pin.project_key in
  Exn.protect
    ~finally:(fun () ->
      if Poly.equal (Sys_unix.file_exists path) `Yes then Core_unix.unlink path;
      Core_unix.rmdir state_directory)
    ~f:(fun () ->
      assert (
        Option.is_none
          (load_waveform_preferences ~state_directory ~project_key:pin.project_key));
      save_waveform_preferences ~state_directory saved;
      let loaded =
        load_waveform_preferences ~state_directory ~project_key:pin.project_key
        |> Option.value_exn
      in
      assert (String.equal data (encode_waveform_preferences loaded));
      save_waveform_preferences ~state_directory { saved with pins = [] };
      let loaded =
        load_waveform_preferences ~state_directory ~project_key:pin.project_key
        |> Option.value_exn
      in
      assert (List.is_empty loaded.pins));
  let restored = restore_waveform_preferences decoded (receive empty registry) in
  assert (
    Option.equal P.Waveforms.equal_pin (waveform_pin restored workspace.id) (Some pin));
  assert (not (phys_equal identity (token restored)));
  let pane =
    List.find_exn registry.tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace workspace.id
      && String.equal tile.kind (P.Waveforms.kind Signals))
  in
  let legacy_registry =
    { registry with
      tiles =
        List.filter registry.tiles ~f:(fun tile ->
          not (String.equal tile.kind (P.Waveforms.kind Session)))
    }
  in
  let legacy_host = receive host legacy_registry in
  assert (phys_equal identity (token legacy_host));
  assert (
    Option.equal
      P.Waveforms.equal_pin
      (waveform_pin
         (restore_waveform_preferences decoded (receive empty legacy_registry))
         workspace.id)
      (Some pin));
  let upgraded =
    apply
      legacy_registry
      (P.Definition.apply P.Waveforms.definition ~workspace:workspace.id)
  in
  assert (phys_equal identity (token (receive legacy_host upgraded)));
  assert (
    Option.equal
      P.Waveforms.equal_pin
      (waveform_pin
         (restore_waveform_preferences decoded (receive empty upgraded))
         workspace.id)
      (Some pin));
  let hidden = apply registry (Set_tile_hidden { tile = pane.id; hidden = true }) in
  assert (phys_equal identity (token (receive host hidden)));
  let retyped =
    { registry with
      revision = registry.revision + 1
    ; tiles =
        List.map registry.tiles ~f:(fun tile ->
          if W.Tile_id.equal tile.id pane.id then { tile with kind = "custom" } else tile)
    }
  in
  assert (Option.is_none (waveform_pin (receive host retyped) workspace.id));
  assert (
    Option.is_none
      (waveform_pin
         (restore_waveform_preferences decoded (receive empty retyped))
         workspace.id));
  let replaced = { registry with session_id = W.Session_id.of_string "new-session" } in
  assert (Option.is_none (waveform_pin (receive host replaced) workspace.id));
  assert (
    Option.is_none
      (waveform_pin
         (restore_waveform_preferences decoded (receive empty replaced))
         workspace.id));
  assert (
    Result.is_error
      (Or_error.try_with (fun () ->
         decode_waveform_preferences ~project_key:"other/env" data)));
  assert (
    Result.is_error
      (Or_error.try_with (fun () ->
         decode_waveform_preferences
           ~project_key:pin.project_key
           (encode_waveform_preferences { saved with pins = saved.pins @ saved.pins }))));
  let removed =
    { registry with
      revision = registry.revision + 1
    ; workspaces = before.workspaces
    ; tiles = before.tiles
    }
  in
  assert (List.is_empty (receive host removed).waveforms);
  assert (List.is_empty (reconnect host ~replacement:true).waveforms)
;;

let%test_unit "custom-only sessions can create every builtin without replacing custom \
               tiles"
  =
  let config =
    P.Presets.custom_example () |> Or_error.ok_exn |> P.Presets.resolve |> Or_error.ok_exn
  in
  let initial = W.initial ~session_id:(W.Session_id.of_string "builtin-recovery") in
  let registry =
    W.apply initial (Initialize_config config) |> Result.ok |> Option.value_exn
  in
  let host = receive empty registry in
  let commands = catalog host ~project:None ~jobs:[] in
  let current_restore =
    List.find_exn commands ~f:(fun c ->
      String.equal c.id "workspace.restore-default-layout")
  in
  assert (Option.is_some current_restore.unavailable);
  List.iter P.Presets.all ~f:(fun d ->
    let command =
      List.find_exn commands ~f:(fun c ->
        String.equal c.id ("workspace.create-builtin." ^ d.P.Definition.id))
    in
    match command.action with
    | Registry mutation ->
      let created =
        W.apply registry (Mutate { expected_revision = registry.revision; mutation })
        |> Result.ok
        |> Option.value_exn
      in
      assert (List.length created.workspaces = List.length registry.workspaces + 1);
      List.iter registry.tiles ~f:(fun tile ->
        assert (W.Tile.equal tile (W.tile created tile.id)));
      let builtin = List.last_exn created.workspaces in
      assert (Option.equal String.equal builtin.preset (Some d.id));
      assert (Option.is_some (render_definition (receive host created) builtin))
    | _ -> assert false)
;;

let%test_unit "named builtin Restore from custom explicitly replaces policy without \
               rebinding"
  =
  let config =
    P.Presets.custom_example () |> Or_error.ok_exn |> P.Presets.resolve |> Or_error.ok_exn
  in
  let initial = W.initial ~session_id:(W.Session_id.of_string "custom-named-restore") in
  let registry =
    W.apply initial (Initialize_config config) |> Result.ok |> Option.value_exn
  in
  let workspace = List.hd_exn registry.workspaces in
  let host = receive empty registry in
  let custom = List.hd_exn registry.config_workspaces in
  let left =
    W.tile registry (List.Assoc.find_exn custom.tiles "left" ~equal:String.equal)
  in
  assert (compact_summary host left);
  let command =
    List.find_exn (restore_commands workspace) ~f:(fun c ->
      String.equal c.id "workspace.restore-default-layout.timing")
  in
  match command.action with
  | Restore_default_layout (id, d) ->
    let restored =
      W.apply
        registry
        (Mutate
           { expected_revision = registry.revision
           ; mutation = P.Definition.restore d ~workspace:id
           })
      |> Result.ok
      |> Option.value_exn
    in
    let host = receive host restored in
    assert (Option.is_none (provenance host id));
    assert (
      String.equal
        (Option.value_exn (render_definition host (W.workspace restored id))).id
        "timing");
    assert (not (compact_summary host (W.tile restored left.id)));
    List.iter registry.tiles ~f:(fun tile ->
      assert (W.Binding.equal tile.binding (W.tile restored tile.id).binding));
    assert (List.equal W.Context.equal registry.contexts restored.contexts)
  | _ -> assert false
;;

let%test_unit "same-builtin Restore detaches frozen policy across restart and additive \
               apply"
  =
  let stock = P.Presets.builtins "timing" |> Or_error.ok_exn in
  let archived : Workspace_config.Definition.t =
    { stock with
      tiles =
        List.map stock.tiles ~f:(fun tile ->
          if String.equal tile.Workspace_config.Tile.key "timing-paths"
          then
            { Workspace_config.Tile.key = "archived-paths"
            ; presentation =
                Some
                  { Workspace_config.Presentation.inherit_defaults with
                    compact_summary = Some true
                  }
            }
          else tile)
    ; layout =
        Some
          (Leaf { tile = "archived-paths"; min_width = 24; min_height = 6; weight = 1 })
    }
  in
  let config : Workspace_config.Resolved.t =
    { version = Workspace_config.version
    ; id = "archived-stock"
    ; definitions = [ archived ]
    ; windows =
        [ { key = "main"
          ; name = "Main"
          ; workspaces =
              [ { key = "timing"; name = "Timing"; definition = Builtin "timing" } ]
          }
        ]
    }
  in
  let initial = W.initial ~session_id:(W.Session_id.of_string "same-builtin-restore") in
  let registry =
    W.apply initial (Initialize_config config) |> Result.ok |> Option.value_exn
  in
  let p = List.hd_exn registry.config_workspaces in
  let path =
    W.tile registry (List.Assoc.find_exn p.tiles "archived-paths" ~equal:String.equal)
  in
  let host = receive empty registry in
  assert (compact_summary host path);
  assert (List.equal String.equal (layout_keys host [ path ]) [ "archived-paths" ]);
  let restored =
    W.apply
      registry
      (Mutate
         { expected_revision = registry.revision
         ; mutation = P.Definition.restore P.Timing.definition ~workspace:p.workspace
         })
    |> Result.ok
    |> Option.value_exn
  in
  let check snapshot =
    let retained = List.hd_exn snapshot.W.Snapshot.config_workspaces in
    assert retained.policy_detached;
    assert (List.equal [%equal: string * W.Tile_id.t] retained.tiles p.tiles);
    assert (Workspace_config.Definition.equal retained.definition archived);
    let host = receive empty snapshot in
    let path = W.tile snapshot path.id in
    assert (Option.is_none (provenance host p.workspace));
    assert (not (compact_summary host path));
    assert (List.equal String.equal (layout_keys host [ path ]) [ "timing-paths" ]);
    let definition =
      render_definition host (W.workspace snapshot p.workspace) |> Option.value_exn
    in
    assert (
      Sexp.equal
        (P.Common.sexp_of_tree definition.layout)
        (P.Common.sexp_of_tree P.Timing.definition.layout))
  in
  check restored;
  check (W.Snapshot.t_of_sexp (W.Snapshot.sexp_of_t restored));
  let reapplied =
    W.apply
      restored
      (Mutate { expected_revision = restored.revision; mutation = Apply_config config })
    |> Result.ok
    |> Option.value_exn
  in
  assert (List.length reapplied.tiles = List.length restored.tiles);
  check reapplied
;;

let%test_unit "mixed spec restores domain navigation and hierarchy without builtin \
               identity"
  =
  let config =
    P.Presets.custom_example () |> Or_error.ok_exn |> P.Presets.resolve |> Or_error.ok_exn
  in
  let kinds =
    [ "hierarchy"
    ; "simulation-catalog"
    ; "simulation-detail"
    ; "timing-paths"
    ; "timing-detail"
    ; "stage-checklist"
    ; "synthesis"
    ]
  in
  let config =
    { config with
      definitions =
        List.map config.definitions ~f:(fun definition ->
          { definition with
            template =
              { definition.template with
                preset = None
              ; views =
                  List.map kinds ~f:(fun kind ->
                    { Workspace_template.View.kind
                    ; hidden = false
                    ; geometry = { x = 0; y = 0; width = 80; height = 12 }
                    })
              }
          ; tiles =
              List.map kinds ~f:(fun kind ->
                { Workspace_config.Tile.key = kind
                ; presentation =
                    Some
                      { Workspace_config.Presentation.inherit_defaults with
                        hints = Some false
                      }
                })
          ; layout = None
          })
    }
  in
  let registry = W.initial ~session_id:(W.Session_id.of_string "mixed-spec-navigation") in
  let registry =
    W.apply registry (Initialize_config config) |> Result.ok |> Option.value_exn
  in
  let workspace = List.hd_exn registry.workspaces in
  let apply registry mutation =
    W.apply
      registry
      (Mutate { expected_revision = registry.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let context = W.context registry workspace.context in
  let registry =
    apply
      registry
      (Select_run
         { workspace = workspace.id
         ; context = context.id
         ; expected_selection_revision = context.selection_revision
         ; run = Some Fs0_fixture.run_a
         })
  in
  let find kind =
    List.find_exn registry.tiles ~f:(fun tile -> String.equal tile.kind kind)
  in
  let synthesis = find "synthesis" in
  let registry =
    apply
      registry
      (Set_tile_binding { tile = synthesis.id; binding = Pin_run Fs0_fixture.run_b })
  in
  assert (Option.is_none workspace.preset);
  assert (Option.is_some (matching_timing registry ~run:Fs0_fixture.run_a));
  let paths = find "timing-paths" in
  let catalog_tile = find "simulation-catalog" in
  let hierarchy_tile = find "hierarchy" in
  let host = receive empty registry in
  let host = establish_testing_scope host catalog_tile.id ~scope:"mixed-project" in
  let host =
    update_testing host catalog_tile.id (fun state ->
      Testing_workspace.select_attempt state "chosen-attempt")
  in
  let host =
    set_timing
      host
      paths
      { (Timing_workspace.create ~generation:0 ~run:Fs0_fixture.run_a ~stage:"routing") with
        filter = "endpoint/Q"
      }
  in
  let saved =
    navigation_preferences ~project_key:"mixed-project" host |> Option.value_exn
  in
  let restored =
    W.Snapshot.t_of_sexp (W.Snapshot.sexp_of_t registry)
    |> receive empty
    |> restore_navigation_selections saved ~scope:"mixed-project"
  in
  assert (
    Option.equal
      String.equal
      (simulation restored (find "simulation-detail").id).attempt
      (Some "chosen-attempt"));
  let timing = Option.value_exn (timing restored (find "timing-detail")) in
  assert (String.equal timing.stage "routing" && String.equal timing.filter "endpoint/Q");
  let restored = { restored with focus = Some hierarchy_tile.id } in
  assert (not (policy restored hierarchy_tile).hints);
  let restored, _ =
    set_presentation restored hierarchy_tile.id { T.inherit_ with hints = Some true }
  in
  assert (policy restored hierarchy_tile).hints;
  (match snd (input restored (Character 'r') ~commands:[]) with
   | Execute (_, Load_hierarchy id) -> assert (W.Tile_id.equal id hierarchy_tile.id)
   | _ -> assert false);
  let commands = catalog restored ~project:None ~jobs:[] in
  assert (
    List.exists commands ~f:(fun command ->
      String.equal command.id "hierarchy.load-current"));
  let no_paths =
    { registry with
      tiles =
        List.filter registry.tiles ~f:(fun tile -> not (W.Tile_id.equal tile.id paths.id))
    }
  in
  assert (Option.is_none (matching_timing no_paths ~run:Fs0_fixture.run_a))
;;
