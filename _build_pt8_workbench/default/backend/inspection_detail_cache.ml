open! Core
open Hardcaml_workbench_protocol

type entry =
  { identity : string
  ; detail : Asic_inspection.Detail.t
  ; bytes : int
  }

type t =
  { max_entries : int
  ; max_bytes : int
  ; mutable entries : entry list
  }

let validate_limits ~entries ~bytes =
  if entries < 0 || entries > 4096
  then invalid_arg "inspection detail cache entries must be between 0 and 4096";
  if bytes < 0 || bytes > 256 * 1024 * 1024
  then invalid_arg "inspection detail cache bytes must be between 0 and 268435456"
;;

let create ~entries ~bytes =
  validate_limits ~entries ~bytes;
  { max_entries = entries; max_bytes = bytes; entries = [] }
;;

let retain t ~f =
  t.entries <- List.filter t.entries ~f:(fun e -> f ~identity:e.identity e.detail)
;;

let find t identity =
  match List.find t.entries ~f:(fun e -> String.equal e.identity identity) with
  | None -> None
  | Some entry ->
    t.entries
    <- entry :: List.filter t.entries ~f:(fun e -> not (String.equal e.identity identity));
    Some entry.detail
;;

let add t ~identity detail =
  (* The budget counts the complete successful wire payload, not OCaml heap overhead. Keys
     and list/record overhead are additionally bounded by the entry limit. *)
  let bytes =
    String.length (Sexp.to_string_mach (Asic_inspection.Detail.sexp_of_t detail))
  in
  if Option.is_none detail.error && t.max_entries > 0 && bytes <= t.max_bytes
  then (
    let candidates =
      { identity; detail; bytes }
      :: List.filter t.entries ~f:(fun e -> not (String.equal e.identity identity))
    in
    let rec trim remaining count = function
      | [] -> []
      | e :: rest ->
        if count = 0 || e.bytes > remaining
        then []
        else e :: trim (remaining - e.bytes) (count - 1) rest
    in
    t.entries <- trim t.max_bytes t.max_entries candidates)
;;
