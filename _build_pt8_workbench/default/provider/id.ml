(** Opaque string identifiers for the shared protocol.

    Every protocol identifier is an abstract type produced by {!Make}, so the compiler
    rejects passing a project identifier where a target identifier is expected. The
    representation is a string because identifiers cross the daemon/client boundary and
    are minted by the daemon; clients treat them as opaque handles. *)

open! Core

module type S = Identifiable.S

module Make (M : sig
    val module_name : string
  end) : S = struct
  module T = struct
    type t = string [@@deriving bin_io, compare ~localize, hash, sexp]

    let of_string = Fn.id
    let to_string = Fn.id
    let module_name = M.module_name
  end

  include T
  include Identifiable.Make (T)
end
