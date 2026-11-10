open! Core
open Wire

module Driver_protocol = struct
  let valid_key value =
    let valid_tail = function
      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
      | _ -> false
    in
    match String.to_list value with
    | ('A' .. 'Z' | 'a' .. 'z' | '0' .. '9') :: tail -> List.for_all tail ~f:valid_tail
    | [] | _ -> false
  ;;

  let valid_relative_path path =
    (not (String.is_empty path))
    && (not (Filename.is_absolute path))
    && List.for_all (String.split path ~on:'/') ~f:(fun component ->
      not (List.mem [ ""; "."; ".." ] component ~equal:String.equal))
  ;;
end

(** Pure bounded provider codecs. Stateful ordering is enforced by the backend reducer. *)
let check condition message = if not condition then failwith message

let text value =
  check
    (String.length value <= Limits.string_bytes && not (String.contains value '\000'))
    "Simulation string exceeds 4096 bytes or contains NUL"
;;

let key value =
  check
    (String.length value <= Limits.key_bytes && Driver_protocol.valid_key value)
    "Simulation key must match [A-Za-z0-9][A-Za-z0-9._-]* and be at most 128 bytes"
;;

let seed value =
  check
    (String.length value >= 1
     && String.length value <= 20
     && String.for_all value ~f:Char.is_digit
     && (String.length value = 1 || not (Char.equal value.[0] '0'))
     && (String.length value < 20 || String.compare value "18446744073709551615" <= 0))
    "Simulation seed must be a canonical unsigned 64-bit decimal string"
;;

let unique values ~f =
  let seen = Hash_set.create (module String) in
  List.iter values ~f:(fun value ->
    let id = f value in
    key id;
    check (not (Hash_set.mem seen id)) "Duplicate simulation key";
    Hash_set.add seen id)
;;

let validate_discovery (discovery : Discovery.t) =
  check (discovery.protocol_version = version) "Unsupported simulation provider version";
  check (List.length discovery.suites <= Limits.suites) "Too many simulation suites";
  unique discovery.suites ~f:(fun suite -> suite.Suite.id);
  let case_count = ref 0 in
  List.iter discovery.suites ~f:(fun suite ->
    text suite.label;
    seed suite.default_seed;
    case_count := !case_count + List.length suite.cases;
    check (not (List.is_empty suite.cases)) "Simulation suite must declare cases";
    unique suite.cases ~f:(fun case -> case.Case.id);
    List.iter suite.cases ~f:(fun case -> text case.Case.label);
    check (List.length suite.parameters <= Limits.parameters) "Too many parameters";
    unique suite.parameters ~f:(fun parameter -> parameter.Parameter.key);
    List.iter suite.parameters ~f:(fun parameter ->
      text parameter.label;
      text parameter.default;
      check (List.length parameter.choices <= 64) "Too many parameter choices";
      List.iter parameter.choices ~f:text;
      check
        (List.is_empty parameter.choices
         || List.mem parameter.choices parameter.default ~equal:String.equal)
        "Parameter default is not a declared choice"));
  check (!case_count <= Limits.cases) "Too many simulation cases";
  discovery
;;

let parse_discovery output =
  Or_error.try_with (fun () ->
    check
      (String.length output <= Limits.discovery_bytes)
      "Simulation discovery exceeds 1 MiB";
    Sexp.of_string output |> Discovery.t_of_sexp |> validate_discovery)
;;

let validate_selection (discovery : Discovery.t) (selection : Selection.t) =
  Or_error.try_with (fun () ->
    let suite =
      List.find_exn discovery.suites ~f:(fun suite ->
        String.equal suite.id selection.suite)
    in
    seed selection.seed;
    check (not (List.is_empty selection.cases)) "Explicit case selection is required";
    check (List.length selection.cases <= Limits.cases) "Too many selected cases";
    unique selection.cases ~f:Fn.id;
    List.iter selection.cases ~f:(fun id ->
      check
        (List.exists suite.cases ~f:(fun case -> String.equal case.id id))
        "Selected simulation case is not in current discovery");
    check
      (List.length selection.parameters = List.length suite.parameters)
      "Supply exactly all declared simulation parameters";
    unique selection.parameters ~f:fst;
    List.iter selection.parameters ~f:(fun (name, value) ->
      text value;
      let parameter =
        List.find_exn suite.parameters ~f:(fun parameter ->
          String.equal parameter.key name)
      in
      check
        (List.is_empty parameter.choices
         || List.mem parameter.choices value ~equal:String.equal)
        "Invalid simulation parameter choice");
    check (List.length selection.asic_inputs <= 16) "Too many ASIC inputs";
    List.iter selection.asic_inputs ~f:(fun input ->
      text input.Asic_input.attempt;
      text input.artifact_id;
      check
        (String.length input.sha256 = 64
         && String.for_all input.sha256 ~f:(function
           | '0' .. '9' | 'a' .. 'f' -> true
           | _ -> false))
        "ASIC input requires lowercase SHA256");
    { selection with
      cases =
        List.filter_map suite.cases ~f:(fun case ->
          if List.mem selection.cases case.id ~equal:String.equal
          then Some case.id
          else None)
    ; parameters =
        List.sort selection.parameters ~compare:(fun (a, _) (b, _) -> String.compare a b)
    })
;;

let validate_event (event : Provider.Event.t) =
  check (event.protocol_version = version) "Unsupported simulation event version";
  text event.attempt_id;
  check (event.sequence >= 0) "Negative simulation event sequence";
  (match event.payload with
   | Started -> ()
   | Case_started id -> key id
   | Progress { case_id; completed; total; unit_ } ->
     Option.iter case_id ~f:key;
     text unit_;
     check (completed >= 0) "Negative simulation progress";
     Option.iter total ~f:(fun total ->
       check (total >= completed) "Progress exceeds declared total")
   | Case_finished { case_id; status; message } ->
     key case_id;
     check
       (match status with
        | Passed | Failed | Skipped -> true
        | Pending | Running | Incomplete -> false)
       "Provider case completion must be Passed, Failed or Skipped";
     Option.iter message ~f:text
   | Artifact artifact ->
     key artifact.id;
     Option.iter artifact.case_id ~f:key;
     List.iter
       [ artifact.label; artifact.kind; artifact.media_type; artifact.path ]
       ~f:text;
     check
       (Driver_protocol.valid_relative_path artifact.path
        && not (String.contains artifact.path '\000'))
       "Artifact path must be normalized and relative to artifact directory"
   | Finished outcome ->
     check
       (match outcome with
        | Passed | Failed -> true
        | Unknown | Incomplete -> false)
       "Provider completion must be Passed or Failed");
  event
;;

let parse_event_line line =
  Or_error.try_with (fun () ->
    check (String.length line + 1 <= Limits.event_bytes) "Simulation event exceeds 16 KiB";
    check
      (not (String.contains line '\n' || String.contains line '\r'))
      "Event must occupy one LF-terminated line";
    let rec framing index quoted escaped =
      if index < String.length line
      then (
        let char = line.[index] in
        if quoted
        then
          if escaped
          then framing (index + 1) true false
          else if Char.equal char '\\'
          then framing (index + 1) true true
          else framing (index + 1) (not (Char.equal char '"')) false
        else (
          check
            (not
               (Char.equal char ';'
                || (Char.equal char '#'
                    && index + 1 < String.length line
                    && (Char.equal line.[index + 1] ';' || Char.equal line.[index + 1] '|')
                   )))
            "Comments are not simulation events";
          framing (index + 1) (Char.equal char '"') false))
    in
    framing 0 false false;
    Sexp.of_string line |> Provider.Event.t_of_sexp |> validate_event)
;;
