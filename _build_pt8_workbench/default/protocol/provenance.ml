(** Where an artifact came from and what produced it.

    Provenance is what makes two results comparable later, so it records the inputs, the
    tools, and the environment rather than only the outputs. Its rules are the ones that
    keep a comparison honest:

    - requested and actual tool versions are separate, because a flow that asked for one
      version and ran another is not reproducible from the request;
    - the execution environment is part of the identity, because two runs of the same
      build in different environments are not the same run;
    - an exact committed source identity is never claimed for dirty or non-Git inputs.

    Recording an environment is not provisioning one, and no credential or license secret
    belongs in any of these fields. *)

open! Core

module Working_tree = struct
  type t =
    | Clean
    | Dirty
    | Unknown of { reason : string }
  [@@deriving bin_io, compare, equal, sexp]
end

module Source_identity = struct
  (** What identifies the design inputs a job consumed.

      A commit identifies the inputs only when the working tree was clean. When it was
      dirty, or when the root is not version controlled, the commit is context and not an
      identity, which is why [preserved_inputs] exists: reproduction needs the input
      contents themselves, not only a hash of them. *)
  type t =
    { git_commit : string option
    ; working_tree : Working_tree.t
    ; design_hash : string option
    (** a digest of the design inputs, where one was taken *)
    ; preserved_inputs : Artifact_id.t list
    (** stored copies of the inputs needed to reproduce this result *)
    }
  [@@deriving bin_io, compare, equal, sexp]

  (** Whether [git_commit] identifies the inputs exactly. False for a dirty or unknown
      working tree, and for inputs that are not version controlled. *)
  let identifies_inputs_exactly t =
    match t.git_commit, t.working_tree with
    | Some _, Clean -> true
    | Some _, (Dirty | Unknown _) | None, _ -> false
  ;;

  let unknown ~reason =
    { git_commit = None
    ; working_tree = Unknown { reason }
    ; design_hash = None
    ; preserved_inputs = []
    }
  ;;
end

type t =
  { project_root : Project_root.t
  ; target : Target_id.t option
  ; configuration : Configuration_id.t option
  ; build : Build_ref.t option
  ; run : Run_ref.t option
  ; generating_job : Job_id.t
  ; requested_tools : Tool_version.t list
  ; actual_tools : Tool_version.t list
  ; environment : Environment_identity.t list
  ; source : Source_identity.t
  ; created_at : Timestamp.t
  }
[@@deriving bin_io, compare, equal, sexp]
