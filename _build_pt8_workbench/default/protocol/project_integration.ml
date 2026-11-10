(** How much the Workbench can do with an opened project.

    Integration has three levels, and each higher level is additive:

    - a generic Dune project is detected from [dune-project] and exposes ordinary build
      and test actions without any Workbench-specific file;
    - a versioned manifest ([hardcaml-workbench.sexp]) declares integration points that
      workspace inspection cannot infer safely;
    - a project-side driver, built and run through the project's own Dune, discovers
      targets, elaborates circuits, and performs other typed project operations.

    A project stays usable at the level it reaches. Missing or incompatible integration is
    reported as such and never prevents generic Dune use, so an unusable driver degrades a
    project to the manifest or generic level rather than failing to open it. *)

open! Core

module Level = struct
  type t =
    | Generic_dune
    | Manifest
    | Driver
  [@@deriving bin_io, compare, equal, enumerate, sexp]

  let to_string t = Sexp.to_string (sexp_of_t t)
end

module Component_status = struct
  (** The state of one optional integration component.

      [Unusable] carries the concrete reason, because "the driver did not work" is not
      actionable and a client must be able to show the user what to fix. An incompatible
      version is unusable with its own reason, not absent. *)
  type t =
    | Absent
    | Available of { version : int option }
    | Unusable of { reason : string }
  [@@deriving bin_io, compare, equal, sexp]

  let is_available = function
    | Available _ -> true
    | Absent | Unusable _ -> false
  ;;
end

type t =
  { level : Level.t
  ; manifest : Component_status.t
  ; driver : Component_status.t
  }
[@@deriving bin_io, compare, equal, sexp]

(** The level implied by the components that are actually usable. The daemon sets [level]
    from this; it is exposed so a client can check rather than infer. *)
let level_of_components ~manifest ~driver : Level.t =
  match Component_status.is_available manifest, Component_status.is_available driver with
  | true, true -> Driver
  | true, false -> Manifest
  | false, _ -> Generic_dune
;;

let generic_dune = { level = Generic_dune; manifest = Absent; driver = Absent }
