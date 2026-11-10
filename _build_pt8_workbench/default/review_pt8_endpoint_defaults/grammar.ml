open! Core
open Hardcaml_workbench_protocol
open Terminal_presentation
module P = Launch_preferences.Prompt
module H = Workspace_host

let checks = ref 0
let check label condition =
  if not condition then failwith ("Independent prompt grammar review: " ^ label);
  incr checks
;;

let decode text expected =
  check ("decode literal grammar: " ^ text)
    (List.equal String.equal (Or_error.ok_exn (P.decode text)) expected)
;;

let () =
  let samples =
    [ ""; "simple"; "two words"; " leading and trailing "; "single'quote"; "double\"quote"
    ; "both'\"quotes"; "\\"; "C:\\new\\path\\"; "literal\\n"; "a\\ b"
    ; "$HOME"; "${USER}"; "$(printf injected)"; "`printf injected`"; "x; printf injected"
    ; "*.ml"; "?[]{}~"; "2>output | cat && false"; "SYNTH_STRATEGY=DELAY 1"; "é/λ"
    ]
    @ List.init 95 ~f:(fun i -> String.of_char (Char.of_int_exn (i + 32)))
  in
  List.iter samples ~f:(fun token ->
    List.iter [ []; [ "routing" ]; [ "prefix"; ""; "suffix" ] ] ~f:(fun before ->
      let tokens = before @ [ token; token ^ "\\\"' end" ] in
      check "encoded tokens round-trip exactly, without shell interpretation"
        (List.equal String.equal (Or_error.ok_exn (P.decode (P.encode tokens))) tokens)));
  decode "  routing   X=1  " [ "routing"; "X=1" ];
  decode "'' \"\" a''b\"\"" [ ""; ""; "ab" ];
  decode "'a b'\"c d\"e" [ "a bc de" ];
  decode "'C:\\new\\path'" [ "C:\\new\\path" ];
  decode "bare\\" [ "bare\\" ];
  decode "a\\ b" [ "a\\"; "b" ];
  decode "\"a\\\"b\\\\c\"" [ "a\"b\\c" ];
  decode "$HOME ${USER} `id` *.ml ; >" [ "$HOME"; "${USER}"; "`id`"; "*.ml"; ";"; ">" ];
  let host, _, _ = Host_view.refinement_fixture Hardcaml_workbench_workspaces.Overview.definition in
  let capture = H.capture host |> Option.value_exn in
  let input argument query =
    let state = { host with palette = Some { capture; commands = []; query; index = 0; argument = Some argument } } in
    H.input state Enter ~commands:[]
  in
  let arguments = [ H.Plan_endpoint ("chosen", "profile"); H.Preparation_inputs ("chosen", "profile") ] in
  List.iter arguments ~f:(fun argument ->
    List.iter samples ~f:(fun token ->
      let expected : Asic.Selection.t =
        { flow = "chosen"; profile = "profile"; endpoint = "routing"
        ; assignments = [ "SYNTH_STRATEGY=DELAY 1"; "LITERAL=" ^ token; "last=unchanged" ] }
      in
      let query = Launch_preferences.endpoint_query ~remembered:(Some expected) ~asic:None
          ~flow:"chosen" ~profile:"profile" in
      let _, effect = input argument query in
      match effect with
      | Execute (_, (Asic (Plan actual) | Select_preparation actual)) ->
        check "actual Enter retains literal quotes/backslashes/shell syntax and exact assignment boundaries"
          (Asic.Selection.equal actual expected)
      | _ -> failwith "valid literal token query did not dispatch");
    let malformed =
      [ "routing 'unterminated"; "routing \"unterminated"; "routing \"dangling\\"
      ; "routing \"bad\\q\""; "routing \"bad\\n\""; "routing 'single\\'still-open'"
      ; ""; "   "; "'' X=1"; "\"\" X=1"
      ]
      @ List.init 33 ~f:(fun i ->
        "routing literal=" ^ String.of_char (Char.of_int_exn (if i = 32 then 127 else i)))
    in
    List.iter malformed ~f:(fun query ->
      check "malformed quote/control/empty endpoint is rejected by selection decoder"
        (Or_error.is_error (P.selection query ~flow:"chosen" ~profile:"profile"));
      let after, effect = input argument query in
      check "malformed input never dispatches" (match effect with No_effect -> true | _ -> false);
      check "malformed input retains the editable prompt and exact entered text"
        (Option.value_map after.palette ~default:false ~f:(fun p -> String.equal p.query query));
      check ("malformed input publishes a user-facing error notice: "
             ^ Sexp.to_string_hum ([%sexp_of: string * string] (query, after.notice)))
        (if String.is_empty (String.strip query)
         then String.is_substring after.notice ~substring:"explicit endpoint"
         else String.is_prefix after.notice ~prefix:"Invalid typed input:" && String.length after.notice > 22);
      let rendered =
        Host_view.render_palette after { width = 200; height = 60 } (Bonsai_term.View.text "")
        |> Host_view.plain_text
      in
      check "the retained prompt actually renders its rejection notice"
        (String.is_substring rendered ~substring:(if String.is_empty (String.strip query)
          then "explicit endpoint" else "Invalid typed input:"))));
  printf "PASS: %d independent quote/backslash/literal/rejection checks\n%!" !checks
;;
