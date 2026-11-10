open! Core

(** Synchronous byte-bounded reads of local regular evidence files, called off the Async
    scheduler. Opens nonblocking before inspecting the descriptor, rejecting FIFOs/devices
    without waiting for a peer, then reads only that same descriptor. This
    local-filesystem interface does not provide a wall-clock deadline for stalled remote
    filesystem operations; those require process-isolated IO. *)
val read_bounded : string -> int -> string
