open! Core
open Hardcaml_workbench_protocol

module Role = struct
  type t =
    | Plain
    | Muted
    | Validated
    | Passed
    | Failed
    | Pending
    | Running
    | Stale
  [@@deriving equal, sexp]
end

module Field = struct
  type t =
    | Operation
    | Physical_completion
    | Verdict
    | Summary_completion
  [@@deriving equal, sexp]
end

module Status = struct
  type t =
    | Passed
    | Failed
    | Pending
    | Running
    | Unknown
  [@@deriving equal, sexp]
end

let normalize field value : Status.t =
  match (field : Field.t), value with
  | Operation, "completed"
  | Physical_completion, "full"
  | Verdict, ("pass" | "passed")
  | Summary_completion, "completed" -> Passed
  | Operation, "failed" | Physical_completion, "failed" | Verdict, ("fail" | "failed") ->
    Failed
  | Operation, ("running" | "starting") -> Running
  | Operation, ("interrupted" | "cancelled" | "queued" | "pending")
  | Physical_completion, ("partial" | "incomplete")
  | Verdict, ("not_evaluated" | "not_requested" | "skipped" | "pending") -> Pending
  | _ -> Unknown
;;

let status_role : Status.t -> Role.t = function
  | Passed -> Passed
  | Failed -> Failed
  | Pending -> Pending
  | Running -> Running
  | Unknown -> Muted
;;

let freshness_role : Asic.Summary.Freshness.t -> Role.t = function
  | Validated -> Validated
  | Cached_unverified | Missing_source | Refresh_failed _ -> Stale
;;

let stage_role : Asic.Stage.Status.t -> Role.t = function
  | Completed -> Passed
  | Failed -> Failed
  | Running -> Running
  | Pending | Skipped | Cancelled -> Pending
  | Not_requested | Unsupported | Unknown _ -> Muted
;;

type span =
  { text : string
  ; role : Role.t
  }
[@@deriving equal, sexp]

type row = span list [@@deriving equal, sexp]

let plain text = [ { text; role = Plain } ]
let text row = String.concat (List.map row ~f:(fun span -> span.text))

let fact ~label field value =
  [ { text = label; role = Plain }
  ; { text = value; role = status_role (normalize field value) }
  ]
;;

let freshness value =
  let label =
    match value with
    | Asic.Summary.Freshness.Validated -> "Validated"
    | Cached_unverified -> "Cached_unverified"
    | Missing_source -> "Missing_source"
    | Refresh_failed _ -> "Refresh_failed"
  in
  [ { text = "Freshness: "; role = Plain }
  ; { text = label; role = freshness_role value }
  ]
;;

let check (check : Asic.Check.t) =
  fact
    ~label:(check.name ^ ": ")
    Verdict
    (if String.is_empty check.status then "unknown (not reported)" else check.status)
  @ Option.value_map check.reason ~default:[] ~f:(fun reason ->
    [ { text = " — " ^ reason; role = Plain } ])
;;

let wrap ~width row =
  if width <= 0
  then []
  else (
    let rows = ref []
    and spans = ref []
    and cells = ref 0 in
    let flush () =
      let row =
        List.rev !spans
        |> List.group ~break:(fun a b -> not (Role.equal a.role b.role))
        |> List.map ~f:(fun group ->
          { text = String.concat (List.map group ~f:(fun span -> span.text))
          ; role = (List.hd_exn group).role
          })
      in
      rows := row :: !rows;
      spans := [];
      cells := 0
    in
    List.iter row ~f:(fun span ->
      let rec loop offset =
        if offset < String.length span.text
        then (
          let decoded = Stdlib.String.get_utf_8_uchar span.text offset in
          let uchar = Stdlib.Uchar.utf_decode_uchar decoded in
          let length = Stdlib.Uchar.utf_decode_length decoded in
          let scalar = Stdlib.Uchar.to_int uchar in
          if scalar = 10
          then flush ()
          else (
            let unsafe = scalar < 32 || (scalar >= 127 && scalar < 160) in
            let size =
              if unsafe then 1 else Int.max 0 (Bonsai_term.View.uchar_tty_width uchar)
            in
            if !cells + size > width && !cells > 0 then flush ();
            let text, size =
              if unsafe || size > width
              then "?", 1
              else String.sub span.text ~pos:offset ~len:length, size
            in
            spans := { text; role = span.role } :: !spans;
            cells := !cells + size);
          loop (offset + length))
      in
      loop 0);
    flush ();
    List.rev !rows)
;;

let clip ~width row = List.hd (wrap ~width row) |> Option.value ~default:[]

let page ~width ~height ~offset rows =
  if height <= 0
  then []
  else (
    let rows = List.concat_map rows ~f:(wrap ~width) in
    let offset =
      Int.clamp_exn offset ~min:0 ~max:(Int.max 0 (List.length rows - height))
    in
    List.take (List.drop rows offset) height)
;;

let render ~attrs rows =
  Bonsai_term.View.vcat
    (List.map rows ~f:(fun row ->
       Bonsai_term.View.hcat
         (List.map row ~f:(fun span ->
            Bonsai_term.View.text ~attrs:(attrs span.role) span.text))))
;;

let%test_unit "validated failing evidence retains independent roles" =
  assert (Role.equal (freshness_role Validated) Validated);
  assert (Role.equal (status_role (normalize Verdict "fail")) Failed);
  assert (Role.equal (status_role (normalize Verdict "completed")) Muted);
  assert (Role.equal (status_role (normalize Operation "completed")) Passed);
  assert (Role.equal (status_role (normalize Verdict "pending")) Pending);
  List.iter
    [ "not passed"; "failure in human log"; "pass later"; "Validated" ]
    ~f:(fun value -> assert (Status.equal (normalize Verdict value) Unknown));
  assert (Role.equal (freshness_role (Refresh_failed "pass")) Stale)
;;

let%test_unit "wrapping preserves Unicode roles and opaque log content" =
  let row = [ { text = "界é"; role = Validated }; { text = "failed"; role = Plain } ] in
  let wrapped = wrap ~width:3 row in
  assert (String.equal (text (List.hd_exn wrapped)) "界é");
  assert (String.equal (String.concat (List.map wrapped ~f:text)) "界éfailed");
  assert (
    List.for_all
      (List.concat (List.tl_exn wrapped))
      ~f:(fun span -> Role.equal span.role Plain));
  assert (String.equal (text (clip ~width:1 (plain "界a"))) "?");
  assert (List.is_empty (wrap ~width:0 row));
  assert (
    String.equal
      (text
         (List.hd_exn
            (page ~width:30 ~height:1 ~offset:Int.max_value [ plain "a"; plain "b" ])))
      "b")
;;
