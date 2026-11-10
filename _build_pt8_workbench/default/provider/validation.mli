open! Core

(** Pure FS2 validators shared verbatim by the daemon and provider runner.
    [validate_discovery] and [validate_event] raise on invalid values; parsers and
    selection validation return structured errors. Selection is normalized to discovery
    case order and sorted parameter keys. *)
val validate_discovery : Wire.Discovery.t -> Wire.Discovery.t

val parse_discovery : string -> Wire.Discovery.t Or_error.t

val validate_selection
  :  Wire.Discovery.t
  -> Wire.Selection.t
  -> Wire.Selection.t Or_error.t

val validate_event : Wire.Provider.Event.t -> Wire.Provider.Event.t
val parse_event_line : string -> Wire.Provider.Event.t Or_error.t

(** Basic bounded field validators. These raise on invalid input. *)
val check : bool -> string -> unit

val text : string -> unit
val key : string -> unit
val seed : string -> unit
val unique : 'a list -> f:('a -> string) -> unit

module Driver_protocol : sig
  val valid_key : string -> bool
  val valid_relative_path : string -> bool
end
