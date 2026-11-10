(** Typed evidence timestamps.

    A time is meaningful only together with what it measures and who recorded it, so no
    evidence time is a bare float or string. The meanings are deliberately not
    interchangeable:

    - production is what the producer reports about when it produced its evidence;
    - a Workbench validation is when the daemon last read these bytes through a bounded
      read-only provider query (an explicit refresh or a cold read);
    - a file modification time is a filesystem observation of the bytes Workbench read.

    Refreshing unchanged evidence moves only the validation time. Neither a validation, a
    cache reopen, a job's lifecycle time nor a file modification time is ever used as a
    production time; missing production time stays [Unknown]. *)

open! Core

module Production = struct
  type t =
    | Unknown
    (** The producer supplied no production time. Rendered as unknown, never guessed. *)
    | Supplied of { at : Timestamp.t }
    (** The instant the producer reported for this producer's evidence. *)
    | Rejected of
        { raw : string
        ; reason : string
        }
    (** The producer supplied a value Workbench could not interpret. Treated as unknown,
        with the bounded raw value retained for diagnosis. *)
  [@@deriving bin_io, compare, equal, sexp]
end

module Observation = struct
  type t =
    | Workbench_validated of { at : Timestamp.t }
    (** The daemon read and validated these bytes with a bounded provider query. *)
    | File_modified of
        { at : Timestamp.t
        ; path : string
        }
    (** The modification time of [path] as Workbench observed it while reading. It says
        when the file last changed, not when its evidence was produced. *)
  [@@deriving bin_io, compare, equal, sexp]
end

module Index = struct
  (** [production] is keyed by the exact row producer attribution, so evidence carried
      forward from an earlier producer keeps that producer's time. Producers absent from
      the list have [Unknown] production time. *)
  type t =
    { production : (string * Production.t) list
    ; observations : Observation.t list
    }
  [@@deriving bin_io, compare, equal, sexp]

  let empty = { production = []; observations = [] }

  let production t ~producer =
    List.Assoc.find t.production producer ~equal:String.equal
    |> Option.value ~default:Production.Unknown
  ;;

  let validated t =
    List.find_map t.observations ~f:(function
      | Observation.Workbench_validated { at } -> Some at
      | File_modified _ -> None)
  ;;

  let file_modified t =
    List.find_map t.observations ~f:(function
      | Observation.File_modified { at; path } -> Some (path, at)
      | Workbench_validated _ -> None)
  ;;

  (** Replace only the Workbench validation time; production and file observations are
      left untouched. *)
  let with_validated t ~at =
    { t with
      observations =
        Observation.Workbench_validated { at }
        :: List.filter t.observations ~f:(function
          | Observation.Workbench_validated _ -> false
          | File_modified _ -> true)
    }
  ;;
end
