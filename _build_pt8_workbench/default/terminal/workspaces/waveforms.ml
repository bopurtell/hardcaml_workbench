open! Core
open Hardcaml_workbench_protocol
module W = Workspace

type pane =
  | Session
  | Signals
  | Waves
  | Picker
  | Logs
[@@deriving equal, sexp]

let kind = function
  | Session -> "waveform-session"
  | Signals -> "waveform-signals"
  | Waves -> "waveform-waves"
  | Picker -> "waveform-picker"
  | Logs -> "waveform-logs"
;;

let pane = function
  | "waveform-session" -> Some Session
  | "waveform-signals" -> Some Signals
  | "waveform-waves" -> Some Waves
  | "waveform-picker" -> Some Picker
  | "waveform-logs" -> Some Logs
  | _ -> None
;;

let is_pane kind = Option.is_some (pane kind)

let title = function
  | Session -> "Session"
  | Signals -> "Signals"
  | Waves -> "Waves"
  | Picker -> "VCD picker"
  | Logs -> "Logs"
;;

(** A job ID alone is not durable provenance: IDs may be reused by another daemon. Never
    substitute the current execution when these logs have expired. *)
type log_source =
  | Unavailable of string
  | Job of
      { instance_id : V1.Daemon_instance_id.t
      ; job : Job_id.t
      }
[@@deriving equal, sexp]

type pin =
  { project_key : string
  ; project : Project_id.t
  ; artifact : Simulation.Artifact.t
  ; log : log_source
  }
[@@deriving equal, sexp]

let log_job pin ~instance_id =
  match pin.log with
  | Job source when V1.Daemon_instance_id.equal source.instance_id instance_id ->
    Ok source.job
  | Job _ -> Or_error.error_string "Pinned attempt logs unavailable after daemon restart"
  | Unavailable reason -> Or_error.error_string reason
;;

let definition = Definition.of_spec (Stock.find "waveforms")

(** Waveforms is explicit, not a bootstrap starter. Template instantiation allocates a
    real daemon-owned workspace and its tiles in one revision. *)
let create ~window =
  W.Mutation.Instantiate_template { window; template = (Stock.find "waveforms").template }
;;

let find (registry : W.Snapshot.t) =
  List.find registry.workspaces ~f:(fun workspace ->
    Option.equal String.equal workspace.preset (Some definition.id))
;;

let created ~(before : W.Snapshot.t) ~(after : W.Snapshot.t) =
  if not (W.Session_id.equal before.session_id after.session_id)
  then None
  else
    List.filter after.workspaces ~f:(fun workspace ->
      Option.equal String.equal workspace.preset (Some definition.id)
      && not
           (List.exists before.workspaces ~f:(fun old ->
              W.Workspace_id.equal old.id workspace.id)))
    |> function
    | [ workspace ] -> Some workspace
    | _ -> None
;;

(** Membership is identity-bearing, including hidden coordinated panes. Session is
    metadata-only: adding it to a legacy arrangement must preserve the original pin and
    sidecar membership. Hide/zoom/reorder/resize also preserve pins. *)
let members (registry : W.Snapshot.t) workspace =
  List.filter registry.tiles ~f:(fun tile ->
    W.Workspace_id.equal tile.workspace workspace
    && Option.exists (pane tile.kind) ~f:(fun pane -> not (equal_pane pane Session)))
  |> List.map ~f:(fun tile -> W.Tile_id.to_string tile.id, tile.kind)
  |> List.sort ~compare:[%compare: string * string]
;;
