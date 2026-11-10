open! Core
open Hardcaml_workbench_protocol

module Log_fetch = struct
  type t =
    | Not_requested
    | Fetching
    | Received of { eof : bool }
    | Error of string
  [@@deriving equal, sexp]
end

(* Display only: never feed these strings back into evidence or numeric ordering. *)
let decimal ~places value =
  let places = Int.max 0 (Int.min 9 places) in
  if not (Float.is_finite value)
  then Float.to_string value
  else (
    (* Find a shortest significant-digit decimal that round-trips to this float. Scaling
       the binary float first can lose a decimal unit (1.001 * 1000 is
       1000.9999999999999). No epsilon: an adjacent float below the boundary must keep its
       distinct decimal representation and still truncate downwards. IEEE doubles need at
       most 17 significant digits. *)
    let rec shortest precision =
      let text = sprintf "%.*g" precision value in
      if precision = 17 || Float.equal (Float.of_string text) value
      then text
      else shortest (precision + 1)
    in
    let text = shortest 1 in
    let negative = String.is_prefix text ~prefix:"-" in
    let magnitude = if negative then String.drop_prefix text 1 else text in
    let mantissa, exponent =
      match String.lsplit2 (String.lowercase magnitude) ~on:'e' with
      | None -> magnitude, 0
      | Some (mantissa, exponent) -> mantissa, Int.of_string exponent
    in
    let point =
      Option.value (String.index mantissa '.') ~default:(String.length mantissa)
      + exponent
    in
    let digits = String.filter mantissa ~f:(fun c -> not (Char.equal c '.')) in
    let digit index =
      if index < 0 || index >= String.length digits then '0' else digits.[index]
    in
    (* Exponent expansion is bounded by double's range: <=309 integer digits, <=9
       fractional digits, plus sign and point. Tiny exponents allocate no intervening
       zero-filled buffer. Keep the sign even for negative zero. *)
    (if negative then "-" else "")
    ^ (if point <= 0 then "0" else String.init point ~f:digit)
    ^ if places = 0 then "" else "." ^ String.init places ~f:(fun i -> digit (point + i)))
;;

let compressible value =
  String.length value > 12 && String.for_all value ~f:(fun c -> Char.to_int c < 128)
;;

let identifier_edges ~edges value =
  if (2 * edges) + 1 >= String.length value
  then value
  else String.prefix value edges ^ "…" ^ String.suffix value edges
;;

let identifier ~compress value =
  if compress && compressible value then identifier_edges ~edges:4 value else value
;;

(** Build once from the entire displayed population, before viewport slicing. Compare
    complete labels, including unchanged Unicode tokens that contain an ellipsis. Equal
    raw identities deliberately share a token. This API is display-only. *)
let identifiers ?width ~compress population =
  let ids = List.dedup_and_sort population ~compare:String.compare in
  let rec resolve edges =
    let labels =
      Map.mapi edges ~f:(fun ~key:id ~data:edge ->
        if compress && compressible id then identifier_edges ~edges:edge id else id)
    in
    let counts = String.Table.create () in
    Map.iter labels ~f:(fun label -> Hashtbl.incr counts label);
    let changed = ref false in
    let edges =
      Map.mapi edges ~f:(fun ~key:id ~data:edge ->
        if Hashtbl.find_exn counts (Map.find_exn labels id) > 1
           && not (String.equal id (Map.find_exn labels id))
        then (
          changed := true;
          edge + 1)
        else edge)
    in
    if !changed then resolve edges else labels
  in
  let labels = resolve (String.Map.of_alist_exn (List.map ids ~f:(fun id -> id, 4))) in
  let label_set = String.Set.of_list (Map.data labels) in
  let rec marker_prefix prefix =
    if List.exists
         (List.mapi ids ~f:(fun i _ -> prefix ^ Int.to_string (i + 1)))
         ~f:(Set.mem label_set)
    then marker_prefix ("#" ^ prefix)
    else prefix
  in
  let marker_prefix = marker_prefix "#" in
  fun id ->
    let label = Option.value (Map.find labels id) ~default:(identifier ~compress id) in
    match width with
    | Some width when Bonsai_term.View.width (Bonsai_term.View.text label) > width ->
      (* A list-local ordinal is explicit and stable across viewport changes. Reserve it
         instead of clipping away the characters that resolved a collision. *)
      let rank = List.findi ids ~f:(fun _ raw -> String.equal raw id) in
      Option.value_map rank ~default:label ~f:(fun (i, _) ->
        marker_prefix ^ Int.to_string (i + 1))
    | _ -> label
;;

let source_path ~compress value =
  if compress && String.contains value '/'
  then (
    let components = String.split value ~on:'/' in
    let source =
      List.find components ~f:(fun part ->
        String.is_prefix part ~prefix:"execution-"
        || String.is_prefix part ~prefix:"timing-"
        || String.is_prefix part ~prefix:"attempt-")
    in
    Option.value_map source ~default:"…" ~f:(identifier ~compress)
    ^ "/"
    ^ Filename.basename value)
  else value
;;

let%test_unit "collision resolution includes unchanged tokens and is order independent" =
  let a = "abcd000000000000wxyz" in
  let b = "abcd111111111111wxyz" in
  let unchanged = "abcd…wxyz" in
  let population = [ a; b; a; unchanged; "試験-long-identity"; "short" ] in
  let show = identifiers ~compress:true population in
  let reverse = identifiers ~compress:true (List.rev population) in
  List.iter population ~f:(fun id -> assert (String.equal (show id) (reverse id)));
  assert (not (String.equal (show a) (show b)));
  assert (not (String.equal (show a) unchanged));
  assert (String.equal (show unchanged) unchanged);
  assert (String.equal (show "試験-long-identity") "試験-long-identity");
  assert (String.equal (show "short") "short");
  List.iter population ~f:(fun id ->
    assert (String.equal (identifiers ~compress:false population id) id));
  let narrow = identifiers ~width:4 ~compress:true population in
  assert (not (String.equal (narrow a) (narrow b)))
;;

let source_metadata ~compress value =
  if not compress
  then value
  else (
    match Or_error.try_with (fun () -> Yojson.Safe.from_string value) with
    | Error _ -> source_path ~compress value
    | Ok json ->
      let rec compact = function
        | `String value -> `String (source_path ~compress value)
        | `Assoc fields ->
          `Assoc
            (List.map fields ~f:(fun (key, value) ->
               ( key
               , match value with
                 | `String text
                   when String.is_substring key ~substring:"sha"
                        || String.is_substring key ~substring:"digest" ->
                   `String (identifier ~compress text)
                 | _ -> compact value )))
        | `List values -> `List (List.map values ~f:compact)
        | value -> value
      in
      Yojson.Safe.to_string (compact json))
;;

(* Only provider source headers, never arbitrary technical body lines. *)
let report_source_header ~compress line =
  List.find_map
    [ "Source: "; "Report: "; "Report source: "; "source: " ]
    ~f:(fun prefix ->
      Option.map (String.chop_prefix line ~prefix) ~f:(fun value ->
        prefix ^ source_metadata ~compress value))
  |> Option.value ~default:line
;;

let identity_metadata_line ~compress line =
  match String.lsplit2 line ~on:':' with
  | Some (label, value) ->
    let value = String.strip value in
    let shown =
      match label with
      | "Run" | "Source digest" | "Execution SHA256" | "Analysis digest" | "Attempt" ->
        identifier ~compress value
      | "Execution" | "Execution file" | "Source" -> source_metadata ~compress value
      | _ -> value
    in
    label ^ ": " ^ shown
  | None -> line
;;

let%test_unit "display precision truncates toward zero, preserving violations and \
               nonfinite values"
  =
  [%test_result: string] (decimal ~places:3 0.125029) ~expect:"0.125";
  [%test_result: string] (decimal ~places:3 (-0.000029)) ~expect:"-0.000";
  [%test_result: string] (decimal ~places:0 (-0.125029)) ~expect:"-0";
  [%test_result: string] (decimal ~places:3 0.) ~expect:"0.000";
  [%test_result: string] (decimal ~places:9 0.1250299879) ~expect:"0.125029987";
  List.iter
    [ 0.125029, 6, "0.125029"; 1.001, 3, "1.001"; 0.29, 2, "0.29" ]
    ~f:(fun (value, places, expected) ->
      [%test_result: string] (decimal ~places value) ~expect:expected;
      [%test_result: string] (decimal ~places (-.value)) ~expect:("-" ^ expected);
      let below = Stdlib.Float.next_after value Float.neg_infinity in
      assert (Float.(below < value));
      assert (not (String.equal (Float.to_string below) (Float.to_string value)));
      [%test_result: string]
        (decimal ~places below)
        ~expect:
          (match places with
           | 6 -> "0.125028"
           | 3 -> "1.000"
           | _ -> "0.28");
      [%test_result: string]
        (decimal ~places (-.below))
        ~expect:
          (match places with
           | 6 -> "-0.125028"
           | 3 -> "-1.000"
           | _ -> "-0.28"));
  (* Actual retained provider metric, not the rounded report's 0.125029. *)
  [%test_result: string] (decimal ~places:6 0.12502899069955042) ~expect:"0.125028";
  [%test_result: string] (decimal ~places:3 1e20) ~expect:"100000000000000000000.000";
  [%test_result: string] (decimal ~places:3 (-1e20)) ~expect:"-100000000000000000000.000";
  [%test_result: string] (decimal ~places:9 1.23456789e-7) ~expect:"0.000000123";
  [%test_result: string] (decimal ~places:9 (-1.23456789e-7)) ~expect:"-0.000000123";
  [%test_result: string] (decimal ~places:9 5e-324) ~expect:"0.000000000";
  [%test_result: string] (decimal ~places:9 (-5e-324)) ~expect:"-0.000000000";
  [%test_result: string] (decimal ~places:3 (-0.)) ~expect:"-0.000";
  [%test_result: string] (decimal ~places:(-1) 1.001) ~expect:"1";
  let largest = Float.of_string "1.7976931348623157e308" in
  let expanded = decimal ~places:99 largest in
  assert (String.length expanded = 319);
  assert (Float.equal (Float.of_string expanded) largest);
  assert (
    String.is_substring (String.lowercase (decimal ~places:3 Float.nan)) ~substring:"nan");
  assert (
    String.is_substring
      (String.lowercase (decimal ~places:3 Float.infinity))
      ~substring:"inf")
;;

let%test_unit "compact identity and structured sources are reversible display choices" =
  let id = "a02325d9895a428aa7b90734314e4e4a" in
  [%test_result: string] (identifier ~compress:true id) ~expect:"a023…4e4a";
  [%test_result: string] (identifier ~compress:false id) ~expect:id;
  [%test_result: string]
    (identifier ~compress:true "界界界界abcdefgh界界界界")
    ~expect:"界界界界abcdefgh界界界界";
  let path =
    "/retained/timing-817177-2eeaceb51e3413c008ecd50516122412/reports/sta/max.rpt"
  in
  let json =
    Yojson.Safe.to_string (`Assoc [ "path", `String path; "sha256", `String id ])
  in
  let compact = source_metadata ~compress:true json in
  assert (String.is_substring compact ~substring:"max.rpt");
  assert (String.is_substring compact ~substring:"a023…4e4a");
  assert (not (String.is_substring compact ~substring:"/retained/"));
  [%test_result: string] (source_metadata ~compress:false json) ~expect:json;
  [%test_result: string] (source_path ~compress:false path) ~expect:path;
  let body = "42: cell/technical/report_path 0.125029 ns" in
  [%test_result: string] (report_source_header ~compress:true body) ~expect:body
;;

let middle_truncate ~width text =
  if width <= 0
  then ""
  else if String.length text <= width
  then text
  else if width <= 3
  then String.prefix text width
  else (
    let available = width - 3 in
    let final_component =
      String.rfindi text ~f:(fun _ char -> Char.equal char '/')
      |> Option.map ~f:(fun index -> String.drop_prefix text index)
    in
    let prefix_length, suffix_length =
      match final_component with
      | Some suffix when String.length suffix < available ->
        available - String.length suffix, String.length suffix
      | _ ->
        let prefix_length = (available + 1) / 2 in
        prefix_length, available - prefix_length
    in
    String.prefix text prefix_length ^ "..." ^ String.suffix text suffix_length)
;;

let wrap_path ~width ~indent path =
  let content_width = width - String.length indent in
  if content_width <= 0
  then [ String.prefix indent (Int.max 0 width) ]
  else (
    let rec loop remaining lines =
      if String.length remaining <= content_width
      then List.rev ((indent ^ remaining) :: lines)
      else (
        let break =
          let rec search index =
            if index <= 0
            then None
            else if Char.equal remaining.[index] '/'
            then Some index
            else search (index - 1)
          in
          search (content_width - 1)
        in
        let length = Option.value break ~default:content_width in
        let line = String.prefix remaining length in
        let rest = String.drop_prefix remaining length in
        loop rest ((indent ^ line) :: lines))
    in
    loop path [])
;;

let wrap_value ~width ~indent value =
  let content_width = width - String.length indent in
  if content_width <= 0
  then [ String.prefix indent (Int.max 0 width) ]
  else
    String.to_list value
    |> List.chunks_of ~length:content_width
    |> List.map ~f:(fun chars -> indent ^ String.of_char_list chars)
;;

let job_outcome_lines (job : Job.t) =
  let process =
    match job.exit_status with
    | Some (Exited code) -> sprintf "Process: exited with code %d" code
    | Some (Signaled { signal }) -> "Process: terminated by signal " ^ signal
    | Some (Launch_failed _) -> "Process: launch failed"
    | None when Job.is_terminal job -> "Process: outcome unavailable"
    | None -> "Process: not finished"
  in
  let failure =
    match job.exit_status, job.failure with
    | Some (Launch_failed { reason }), _ -> Some ("Launch failure: " ^ reason)
    | _, Some reason -> Some ("Failure reason: " ^ reason)
    | _, None when Job.State.equal job.state Failed ->
      Some "Failure reason: none reported; see process outcome"
    | _ -> None
  in
  [ "STATUS: " ^ Job.State.to_string job.state; process ] @ Option.to_list failure
;;

let empty_log_notice ~job_state ~fetch =
  match fetch with
  | Log_fetch.Not_requested -> Some "(logs have not been fetched yet)"
  | Fetching -> Some "(fetching stdout/stderr...)"
  | Error message -> Some ("(log retrieval failed: " ^ message ^ ")")
  | Received { eof = true } -> Some "(job finished without stdout/stderr output)"
  | Received { eof = false } ->
    (match job_state with
     | Job.State.Running -> Some "(job is running; no stdout/stderr output so far)"
     | Complete | Failed | Cancelled ->
       Some "(job finished; waiting for remaining stdout/stderr)"
     | Queued | Starting -> Some "(job has not produced stdout/stderr output yet)")
;;

let%test_unit "job outcome follows state and process status, not failure absence" =
  let job state exit_status failure =
    { (Job.create
         ~id:(Job_id.of_string "job")
         ~kind:{ namespace = "dune"; name = "build" }
         ~project:(Project_id.of_string "project")
         ~created_at:(Timestamp.of_time_ns Time_ns.epoch))
      with
      state
    ; exit_status
    ; failure
    }
  in
  [%test_result: string list]
    (job_outcome_lines (job Complete (Some (Exited 0)) None))
    ~expect:[ "STATUS: Complete"; "Process: exited with code 0" ];
  [%test_result: string list]
    (job_outcome_lines (job Failed (Some (Exited 2)) None))
    ~expect:
      [ "STATUS: Failed"
      ; "Process: exited with code 2"
      ; "Failure reason: none reported; see process outcome"
      ];
  [%test_result: string list]
    (job_outcome_lines
       (job Failed (Some (Launch_failed { reason = "missing dune" })) None))
    ~expect:[ "STATUS: Failed"; "Process: launch failed"; "Launch failure: missing dune" ];
  [%test_result: string list]
    (job_outcome_lines (job Cancelled (Some (Signaled { signal = "TERM" })) None))
    ~expect:[ "STATUS: Cancelled"; "Process: terminated by signal TERM" ];
  [%test_result: string list]
    (job_outcome_lines (job Running None None))
    ~expect:[ "STATUS: Running"; "Process: not finished" ]
;;

let%test_unit "empty log notices distinguish fetch, drain, and EOF" =
  let notice state fetch = empty_log_notice ~job_state:state ~fetch in
  [%test_result: string option]
    (notice Running Not_requested)
    ~expect:(Some "(logs have not been fetched yet)");
  [%test_result: string option]
    (notice Running (Received { eof = false }))
    ~expect:(Some "(job is running; no stdout/stderr output so far)");
  [%test_result: string option]
    (notice Complete (Received { eof = false }))
    ~expect:(Some "(job finished; waiting for remaining stdout/stderr)");
  [%test_result: string option]
    (notice Complete (Received { eof = true }))
    ~expect:(Some "(job finished without stdout/stderr output)");
  [%test_result: string option]
    (notice Failed (Error "connection lost"))
    ~expect:(Some "(log retrieval failed: connection lost)")
;;

let%test_unit "middle truncation preserves location and final directory when it fits" =
  let root = "/home/wayne/devel/jane/hardcaml_workbench/test/fixtures/example_project" in
  [%test_result: string]
    (middle_truncate ~width:45 root)
    ~expect:"/home/wayne/devel/jane/har.../example_project";
  [%test_result: int] (String.length (middle_truncate ~width:20 root)) ~expect:20;
  [%test_result: string] (middle_truncate ~width:20 root) ~expect:"/.../example_project"
;;

let%test_unit "path wrapping prefers separators and bounds long components" =
  let path = "/home/wayne/a_component_that_exceeds_the_width/example_project" in
  let lines = wrap_path ~width:18 ~indent:"  " path in
  List.iter lines ~f:(fun line -> assert (String.length line <= 18));
  [%test_result: string]
    (lines |> List.map ~f:(fun line -> String.drop_prefix line 2) |> String.concat)
    ~expect:path;
  assert (List.exists lines ~f:(String.is_prefix ~prefix:"  /example_project"))
;;
