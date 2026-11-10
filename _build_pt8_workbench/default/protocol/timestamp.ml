(** Wall-clock instants in protocol values.

    [Time_ns.Alternate_sexp] is the representation because its sexp conversion needs no
    zone database, and protocol values are also compiled to JavaScript. Timestamps are
    recorded by the daemon; a client must not treat them as local time without converting
    them itself. *)

open! Core

type t = Time_ns.Alternate_sexp.t [@@deriving bin_io, compare, equal, hash, sexp]

let of_time_ns = Fn.id
let to_time_ns = Fn.id
