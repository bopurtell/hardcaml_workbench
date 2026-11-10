open! Core
open Hardcaml_workbench_protocol
module Wire = Hardcaml_workbench_protocol.Asic_inspection
module Public = Asic_public

let index_limit = 2 * 1024 * 1024
let detail_limit = 64 * 1024

let validate_selection ~domain ~stage =
  Public.require
    (List.mem [ "timing"; "clocks"; "physical"; "routing" ] domain ~equal:String.equal
     && List.mem
          [ "synthesis"; "floorplan"; "placement"; "cts"; "routing"; "timing"; "signoff" ]
          stage
          ~equal:String.equal)
    "Invalid inspection domain/stage"
;;

let validate_digest digest =
  Public.require
    (String.length digest = 64
     && String.for_all digest ~f:(function
       | '0' .. '9' | 'a' .. 'f' -> true
       | _ -> false))
    "Invalid inspection digest"
;;

let validate_row_id id =
  Public.require
    ((not (String.is_empty id)) && String.length id <= 4096)
    "Invalid inspection row ID"
;;

let validate_analysis_target (target : Wire.Analysis_target.t) =
  validate_digest target.source_digest;
  validate_digest target.execution_sha256;
  Option.iter target.execution_file ~f:(fun path ->
    ignore (Public.absolute path : string));
  Public.require
    ((not (String.is_empty target.attempt_id))
     && List.mem [ "signoff"; "timing" ] target.stage ~equal:String.equal
     && String.equal
          target.occurrence_id
          (target.attempt_id ^ "/implementation." ^ target.stage)
     && String.equal target.analysis_id (target.attempt_id ^ "/post-pnr-sta"))
    "Invalid timing analysis identity"
;;

let boolean = function
  | `Bool b -> b
  | _ -> failwith "Expected inspection boolean"
;;

let number = function
  | `Null -> None
  | `Int n -> Some (Float.of_int n)
  | `Intlit n ->
    let value = Float.of_string n in
    Public.require (Float.is_finite value) "Nonfinite inspection value";
    Some value
  | `Float f when Float.is_finite f -> Some f
  | _ -> failwith "Expected finite inspection value"
;;

let require_fields names = function
  | `Assoc fields ->
    List.iter names ~f:(fun name ->
      Public.require
        (List.Assoc.mem fields name ~equal:String.equal)
        ("Missing inspection field: " ^ name))
  | _ -> failwith "Expected inspection object"
;;

let row j : Wire.Row.t =
  require_fields
    [ "id"
    ; "category"
    ; "producer"
    ; "corner"
    ; "group"
    ; "name"
    ; "value"
    ; "unit"
    ; "status"
    ; "source"
    ; "fields"
    ]
    j;
  let field name = Public.field name j in
  let id = Public.text (field "id") in
  validate_row_id id;
  let source = Public.text (field "source") in
  ignore (Public.decode source : Yojson.Safe.t);
  { id
  ; category = Public.text (field "category")
  ; producer = Public.text (field "producer")
  ; corner = Public.optional_text (field "corner")
  ; group = Public.optional_text (field "group")
  ; name = Public.text (field "name")
  ; value = number (field "value")
  ; unit_ = Public.optional_text (field "unit")
  ; status = Public.text (field "status")
  ; source
  ; fields =
      List.map
        (Public.list (field "fields"))
        ~f:(function
          | `List [ `String key; `String value ] -> key, value
          | _ -> failwith "Expected inspection string pair")
  }
;;

(** A producer-supplied instant must name its zone ([Z] or a numeric UTC offset); a
    zone-less or unparseable value is retained as [Rejected], never reinterpreted in a
    local zone or replaced by another time. *)
let production_time raw : Evidence_time.Production.t =
  let reject reason =
    Evidence_time.Production.Rejected { raw = String.prefix raw 128; reason }
  in
  let explicit_zone =
    String.is_suffix raw ~suffix:"Z"
    || (String.length raw >= 6
        &&
        let zone = String.suffix raw 6 in
        List.for_alli (String.to_list zone) ~f:(fun i c ->
          match i with
          | 0 -> Char.equal c '+' || Char.equal c '-'
          | 3 -> Char.equal c ':'
          | _ -> Char.is_digit c))
  in
  if String.length raw > 64
  then reject "production time exceeds 64 bytes"
  else if not explicit_zone
  then reject "production time has no explicit UTC offset"
  else (
    match
      Or_error.try_with (fun () ->
        let at = Time_ns.of_string_with_utc_offset raw in
        (* The nanosecond parser can wrap its Int63 arithmetic. Independently parse in the
           much wider float representation to detect that wrap, without converting the
           stored instant through a float or losing its nanosecond precision. The
           one-second guard comfortably exceeds float rounding error; a wrap shifts the
           instant by centuries, including at either one-nanosecond range boundary. *)
        let wide = Time_float.of_string_with_utc_offset raw in
        let delta = Time_float.diff wide (Time_ns.to_time_float_round_nearest at) in
        if Float.(abs (Time_float.Span.to_sec delta) >= 1.)
        then failwith "production time outside nanosecond range";
        at)
    with
    | Ok at -> Supplied { at = Timestamp.of_time_ns at }
    | Error _ -> reject "unparseable production time")
;;

(** Optional [production_times]: [{producer; produced_at}] entries keyed by the exact row
    producer attribution. Absent or [null] means no producer supplied any production time,
    which is rendered as unknown. *)
let production_times j =
  match Public.field "production_times" j with
  | `Null -> []
  | entries ->
    let entries = Public.list entries in
    Public.require (List.length entries <= 256) "Inspection production times exceed 256";
    let production =
      List.map entries ~f:(fun entry ->
        require_fields [ "producer"; "produced_at" ] entry;
        let producer = Public.text (Public.field "producer" entry) in
        Public.require
          ((not (String.is_empty producer)) && String.length producer <= 4096)
          "Invalid inspection production producer";
        producer, production_time (Public.text (Public.field "produced_at" entry)))
    in
    let producers = List.map production ~f:fst in
    Public.require
      (List.length producers
       = List.length (List.dedup_and_sort producers ~compare:String.compare))
      "Duplicate inspection production producer";
    production
;;

(** The path is supplied only by the registered run, never by the client. Hash the actual
    bytes at the exact canonical public path, and fence the attempt as well. *)
let execution_hash ~(registered : Asic.Run.t) ~execution_file =
  Public.require
    (Option.equal String.equal registered.execution_file (Some execution_file)
     && String.equal (Filename_unix.realpath execution_file) execution_file)
    "Inspection requires the registered canonical execution file";
  let bytes = Asic_evidence_file.read_bounded execution_file (8 * 1024 * 1024) in
  let execution = Public.decode bytes in
  Public.require
    (Poly.equal
       (Public.field "attempt_id" execution)
       (`String registered.reference.stream_id))
    "Inspection execution attempt mismatch";
  Public.digest bytes
;;

let identity ~(registered : Asic.Run.t) ~execution_file ~execution_sha256 ~domain ~stage j
  =
  validate_selection ~domain ~stage;
  validate_digest execution_sha256;
  Public.require
    (Option.equal String.equal registered.execution_file (Some execution_file))
    "Inspection execution is not registered";
  let j = Public.envelope j "hardcaml-asic.inspection" 1 in
  List.iter
    [ "execution_file", execution_file
    ; "execution_sha256", execution_sha256
    ; "attempt_id", registered.reference.stream_id
    ; "domain", domain
    ; "stage", stage
    ]
    ~f:(fun (key, expected) ->
      Public.require
        (Poly.equal (Public.field key j) (`String expected))
        ("Inspection identity mismatch: " ^ key));
  let digest = Public.text (Public.field "source_digest" j) in
  validate_digest digest;
  digest
;;

let validate_index (index : Wire.Index.t) =
  validate_selection ~domain:index.domain ~stage:index.stage;
  validate_digest index.source_digest;
  validate_digest index.execution_sha256;
  Option.iter index.analysis ~f:(fun analysis ->
    validate_analysis_target analysis;
    Public.require
      (String.equal index.domain "timing"
       && String.equal index.stage analysis.stage
       && (Option.is_some analysis.execution_file
           || String.equal analysis.execution_sha256 index.execution_sha256))
      "Invalid cached analysis inspection");
  ignore (Public.absolute index.execution_file : string);
  Public.require (List.length index.rows <= 4096) "Inspection exceeds 4096 rows";
  Public.require
    (List.length index.times.production <= 256
     && List.length index.times.observations <= 4)
    "Inspection timestamps exceed budget";
  let ids = List.map index.rows ~f:(fun r -> r.Wire.Row.id) in
  Public.require
    (List.length ids = List.length (List.dedup_and_sort ids ~compare:String.compare))
    "Duplicate inspection row ID";
  List.iter index.rows ~f:(fun row ->
    validate_row_id row.id;
    Option.iter row.value ~f:(fun value ->
      Public.require (Float.is_finite value) "Nonfinite cached inspection value");
    ignore (Public.decode row.source : Yojson.Safe.t));
  Public.require
    (String.length (Sexp.to_string_mach (Wire.Index.sexp_of_t index)) <= index_limit)
    "Normalized inspection exceeds 2MiB"
;;

let analysis_target ?captured ~attempt_id ~execution_sha256 ~stage j =
  match Public.field "analysis_id" j, Public.field "analysis_digest" j with
  | `Null, `Null -> None
  | `String analysis_id, `String source_digest ->
    validate_digest source_digest;
    Public.require
      (String.equal analysis_id (attempt_id ^ "/post-pnr-sta"))
      "Inspection analysis ID mismatch";
    let target =
      { Wire.Analysis_target.attempt_id
      ; occurrence_id = attempt_id ^ "/implementation." ^ stage
      ; analysis_id
      ; source_digest
      ; execution_sha256
      ; stage
      ; execution_file = None
      }
    in
    Some
      (Option.value_map captured ~default:target ~f:(fun captured ->
         validate_analysis_target captured;
         Public.require
           (String.equal captured.attempt_id attempt_id
            && String.equal captured.stage stage
            && String.equal captured.analysis_id analysis_id
            && String.equal captured.source_digest source_digest)
           "Captured analysis inspection identity mismatch";
         captured))
  | _ -> failwith "Incomplete inspection analysis identity"
;;

let parse_index ?analysis ~registered ~execution_file ~execution_sha256 ~domain ~stage j =
  Public.require
    (String.length (Yojson.Safe.to_string j) <= index_limit)
    "Inspection response exceeds 2MiB";
  let source_digest =
    identity ~registered ~execution_file ~execution_sha256 ~domain ~stage j
  in
  let index : Wire.Index.t =
    { run = registered.Asic.Run.run
    ; execution_file
    ; execution_sha256
    ; domain
    ; stage
    ; source_digest
    ; rows = List.map (Public.list (Public.field "rows" j)) ~f:row
    ; diagnostics = List.map (Public.list (Public.field "diagnostics" j)) ~f:Public.text
    ; truncated = boolean (Public.field "truncated" j)
    ; cached_unverified = false
    ; analysis =
        analysis_target
          ?captured:analysis
          ~attempt_id:registered.reference.stream_id
          ~execution_sha256
          ~stage
          j
    ; times = { Evidence_time.Index.empty with production = production_times j }
    }
  in
  validate_index index;
  index
;;

let observe_times ~execution_file ~validated_at (index : Wire.Index.t) =
  let modified =
    Option.try_with (fun () ->
      let stats = Core_unix.stat execution_file in
      Evidence_time.Observation.File_modified
        { at =
            Timestamp.of_time_ns
              (Time_ns.of_span_since_epoch (Time_ns.Span.of_sec stats.st_mtime))
        ; path = execution_file
        })
  in
  let times =
    Evidence_time.Index.with_validated
      { index.times with observations = Option.to_list modified }
      ~at:validated_at
  in
  { index with times }
;;

let parse_detail ?execution_sha256 ~registered ~(index : Wire.Index.t) ~row_id j =
  validate_row_id row_id;
  Public.require
    (Run_ref.equal registered.Asic.Run.run index.run)
    "Wrong inspection detail run";
  let digest =
    identity
      ~registered
      ~execution_file:index.execution_file
      ~execution_sha256:(Option.value execution_sha256 ~default:index.execution_sha256)
      ~domain:index.domain
      ~stage:index.stage
      j
  in
  Public.require
    (Option.equal
       Wire.Analysis_target.equal
       index.analysis
       (analysis_target
          ?captured:index.analysis
          ~attempt_id:registered.reference.stream_id
          ~execution_sha256:index.execution_sha256
          ~stage:index.stage
          j))
    "Inspection detail analysis changed";
  Public.require
    (String.equal digest index.source_digest
     && Poly.equal (Public.field "row_id" j) (`String row_id)
     && List.exists index.rows ~f:(fun r -> String.equal r.id row_id))
    "Inspection detail digest/row mismatch";
  let text = Public.text (Public.field "detail" j) in
  Public.require (String.length text <= detail_limit) "Inspection detail exceeds 64KiB";
  { Wire.Detail.run = index.run
  ; domain = index.domain
  ; stage = index.stage
  ; source_digest = index.source_digest
  ; row_id
  ; text
  ; error = None
  }
;;

module Blob = struct
  type t =
    { digest : string
    ; index : Wire.Index.t
    }
  [@@deriving sexp]
end

module Cache = struct
  type t =
    { version : int
    ; identity : string
    ; entries : Blob.t list
    }
  [@@deriving sexp]
end

let cache_path ~state_dir ~identity =
  Filename.concat state_dir ("asic-" ^ Public.digest identity ^ "-inspections-v1.sexp")
;;

let index_digest index = Public.digest (Sexp.to_string_mach (Wire.Index.sexp_of_t index))

let key (index : Wire.Index.t) =
  Wire.index_key ~run:index.run ~domain:index.domain ~stage:index.stage
;;

let read_cache ~state_dir ~identity =
  let path = cache_path ~state_dir ~identity in
  if Poly.equal (Sys_unix.file_exists path) `No
  then []
  else (
    let bytes = Asic_evidence_file.read_bounded path ((8 * index_limit) + 65536) in
    let cache = Cache.t_of_sexp (Sexp.of_string bytes) in
    Public.require
      ((cache.version = 1 || cache.version = 2)
       && String.equal cache.identity identity
       && List.length cache.entries <= 8)
      "Incompatible inspection cache identity/budget";
    List.iter cache.entries ~f:(fun blob ->
      Public.require
        (cache.version >= 2 || Option.is_none blob.index.analysis)
        "Analysis inspection requires cache version 2";
      validate_index blob.index;
      Public.require
        (String.equal blob.digest (index_digest blob.index))
        "Corrupt inspection cache digest");
    let keys = List.map cache.entries ~f:(fun b -> key b.index) in
    Public.require
      (List.length keys = List.length (List.dedup_and_sort keys ~compare:String.compare))
      "Duplicate inspection cache identity";
    cache.entries)
;;

let load ~state_dir ~identity ~run ~execution_file ~domain ~stage =
  let wanted = Wire.index_key ~run ~domain ~stage in
  let blob =
    List.find (read_cache ~state_dir ~identity) ~f:(fun b ->
      String.equal (key b.index) wanted)
    |> Option.value_exn ~message:"No cached inspection"
  in
  Public.require
    (String.equal blob.index.execution_file execution_file)
    "Stale cached inspection execution";
  { blob.index with cached_unverified = true }
;;

let save ?(rebuild_invalid = false) ~state_dir ~identity index =
  validate_index index;
  let index = { index with Wire.Index.cached_unverified = false } in
  let entries =
    match Or_error.try_with (fun () -> read_cache ~state_dir ~identity) with
    | Ok entries -> entries
    | Error _ when rebuild_invalid -> []
    | Error error -> Error.raise error
  in
  let entries =
    List.take
      ({ Blob.digest = index_digest index; index }
       :: List.filter entries ~f:(fun b -> not (String.equal (key b.index) (key index))))
      8
  in
  let version =
    if List.exists entries ~f:(fun blob -> Option.is_some blob.index.analysis)
    then 2
    else 1
  in
  let data = Sexp.to_string_mach (Cache.sexp_of_t { version; identity; entries }) in
  Public.require
    (String.length data <= (8 * index_limit) + 65536)
    "Inspection cache exceeds byte budget";
  Core_unix.mkdir_p state_dir ~perm:0o700;
  let temporary = Filename_unix.temp_file ~in_dir:state_dir ".asic-inspection-" ".tmp" in
  Exn.protect
    ~finally:(fun () ->
      if Poly.equal (Sys_unix.file_exists temporary) `Yes then Core_unix.unlink temporary)
    ~f:(fun () ->
      Out_channel.write_all temporary ~data;
      Core_unix.rename ~src:temporary ~dst:(cache_path ~state_dir ~identity))
;;
