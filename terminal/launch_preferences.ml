open! Core
open Hardcaml_workbench_protocol

(** Client UI preference, deliberately separate from provider runs and the daemon
    workspace registry. The stable project/environment key is checked on load. *)
type t =
  { schema_version : int
  ; project_key : string
  ; selection : Asic.Selection.t
  }
[@@deriving sexp]

let create ~project_key selection = { schema_version = 1; project_key; selection }

let decode ~project_key sexp =
  let stored = t_of_sexp sexp in
  if stored.schema_version <> 1 then failwith "Unsupported terminal preference schema";
  if not (String.equal stored.project_key project_key)
  then failwith "Terminal preference project/environment mismatch";
  stored.selection
;;

let path ~state_directory ~project_key =
  Filename.concat state_directory ("launch-" ^ Plain_rpc.digest project_key ^ ".sexp")
;;

let available (selection : Asic.Selection.t) (flows : Asic.Flow.t list) =
  List.exists flows ~f:(fun flow ->
    String.equal flow.id selection.flow
    && List.mem flow.profiles selection.profile ~equal:String.equal)
;;

(* This is a UI initial choice, not a provider-declared endpoint default. Only advertised
   fresh-prefix endpoints may seed a new selection. *)
let default_endpoint (flow : Asic.Flow.t) =
  if List.mem flow.fresh_stage_endpoints "synthesis" ~equal:String.equal
  then Some "synthesis"
  else List.hd flow.fresh_stage_endpoints
;;

module Prompt = struct
  (* Data-only token grammar: spaces separate tokens; single/double quoted spans
     concatenate with bare spans. Inside double quotes only quote and backslash can be
     escaped with a backslash; elsewhere backslashes are literal. No shell expansion,
     substitution or command execution. *)
  let encode tokens =
    List.map tokens ~f:(fun token ->
      if (not (String.is_empty token))
         && not
              (String.exists token ~f:(fun c ->
                 List.mem [ ' '; '\''; '"'; '\\' ] c ~equal:Char.equal))
      then token
      else
        "\""
        ^ String.concat_map token ~f:(function
          | '"' -> "\\\""
          | '\\' -> "\\\\"
          | c -> String.of_char c)
        ^ "\"")
    |> String.concat ~sep:" "
  ;;

  let decode text =
    Or_error.try_with (fun () ->
      if String.exists text ~f:(fun c -> Char.to_int c < 32 || Char.equal c '\127')
      then failwith "Endpoint input must be one line; remove control characters";
      let token = Buffer.create (String.length text) in
      let finish tokens started =
        if not started then tokens else Buffer.contents token :: tokens
      in
      let rec loop i quote started tokens =
        if i = String.length text
        then (
          match quote with
          | Some c -> failwith ("Unclosed quote; add a closing " ^ String.of_char c)
          | None -> List.rev (finish tokens started))
        else (
          let c = text.[i] in
          match quote, c with
          | None, ' ' ->
            let tokens = finish tokens started in
            Buffer.clear token;
            loop (i + 1) None false tokens
          | None, ('\'' | '"') -> loop (i + 1) (Some c) true tokens
          | Some q, c when Char.equal q c -> loop (i + 1) None true tokens
          | Some '"', '\\' ->
            if i + 1 = String.length text
            then
              failwith
                "Unclosed double quote; add a closing quote (escape a literal backslash \
                 as \\\\)";
            let next = text.[i + 1] in
            if not (Char.equal next '"' || Char.equal next '\\')
            then
              failwith
                "Inside double quotes, only quote and backslash may be escaped; use \
                 single quotes for literal backslashes";
            Buffer.add_char token next;
            loop (i + 2) quote true tokens
          | _ ->
            Buffer.add_char token c;
            loop (i + 1) quote true tokens)
      in
      loop 0 None false [])
  ;;

  let selection text ~flow ~profile =
    let open Or_error.Let_syntax in
    let%bind tokens = decode text in
    match tokens with
    | endpoint :: assignments when not (String.is_empty endpoint) ->
      Ok { Asic.Selection.flow; profile; endpoint; assignments }
    | _ -> Or_error.error_string "Enter a nonempty endpoint before any assignments"
  ;;
end

let endpoint_query ~remembered ~(asic : Asic.Snapshot.t option) ~flow ~profile =
  match remembered with
  | Some (s : Asic.Selection.t)
    when String.equal s.flow flow && String.equal s.profile profile ->
    Prompt.encode (s.endpoint :: s.assignments)
  | _ ->
    Option.bind asic ~f:(fun snapshot ->
      List.find snapshot.flows ~f:(fun f ->
        String.equal f.id flow && List.mem f.profiles profile ~equal:String.equal)
      |> Option.bind ~f:default_endpoint)
    |> Option.value ~default:""
;;

let%test_unit "preferences retain exact inputs, reject other project contexts, and never \
               choose a fallback"
  =
  let selection : Asic.Selection.t =
    { flow = "fixture"
    ; profile = "custom"
    ; endpoint = "synthesis"
    ; assignments = [ "WIDTH=4" ]
    }
  in
  let sexp = sexp_of_t (create ~project_key:"project/environment" selection) in
  assert (Asic.Selection.equal (decode ~project_key:"project/environment" sexp) selection);
  assert (Result.is_error (Or_error.try_with (fun () -> decode ~project_key:"other" sexp)));
  assert (not (available selection []));
  assert (
    not
      (available
         selection
         [ { id = "fixture"
           ; profiles = [ "default" ]
           ; default_profile = "default"
           ; fresh_stage_endpoints = []
           }
         ]))
;;
