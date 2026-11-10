open! Core

type context =
  { request : Wire.Provider.Request.t
  ; artifact_dir : string
  ; emit : Wire.Provider.Event.payload -> unit
  }

(** Both callbacks receive the original validated selection, preserving case and parameter
    order. Daemon submissions are already normalized upstream. *)
val main
  :  ?argv:string array
  -> discovery:Wire.Discovery.t
  -> validate_selection:(Wire.Selection.t -> unit Or_error.t)
  -> run:(context -> unit Or_error.t)
  -> unit
  -> unit

val run_child
  :  prog:string
  -> args:string list
  -> on_stdout_line:(string -> unit)
  -> unit Or_error.t

val artifact_path : context -> string -> string
