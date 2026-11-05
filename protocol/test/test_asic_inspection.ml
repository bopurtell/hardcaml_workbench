open! Core
open Hardcaml_workbench_protocol

let run : Run_ref.t =
  { backend = Backend_id.of_string "asic"; id = "run:1"; build = None; label = None }
;;

(* Frozen pre-WB-003/WB-006 readers. Defaulting a new field only provides
   new-reader/old-record compatibility: these strict readers still reject it. *)
module Legacy_index = struct
  type t =
    { run : Run_ref.t
    ; execution_file : string
    ; execution_sha256 : string
    ; domain : string
    ; stage : string
    ; source_digest : string
    ; rows : Asic_inspection.Row.t list
    ; diagnostics : string list
    ; truncated : bool
    ; cached_unverified : bool
    }
  [@@deriving sexp]
end

module Legacy_pending = struct
  type t =
    { key : string
    ; kind : string
    ; state : string
    ; run : Run_ref.t option
    ; error : string option
    }
  [@@deriving sexp]
end

let round_trip equal sexp_of of_sexp bin_size bin_write bin_read value =
  assert (equal value (of_sexp (sexp_of value)));
  let buffer = Bin_prot.Common.create_buf (bin_size value) in
  let length = bin_write buffer ~pos:0 value in
  let pos_ref = ref 0 in
  assert (equal value (bin_read buffer ~pos_ref));
  assert (!pos_ref = length)
;;

let%test_unit "inspection wire codecs preserve unknown values and provenance" =
  let row : Asic_inspection.Row.t =
    { id = "path:1"
    ; category = "setup"
    ; producer = "opensta"
    ; corner = Some "slow"
    ; group = Some "clock"
    ; name = "endpoint"
    ; value = None
    ; unit_ = Some "ns"
    ; status = "unavailable"
    ; source = "{\"path\":\"/public/timing.json\"}"
    ; fields = [ "startpoint", "a"; "endpoint", "b" ]
    }
  in
  round_trip
    Asic_inspection.Row.equal
    Asic_inspection.Row.sexp_of_t
    Asic_inspection.Row.t_of_sexp
    Asic_inspection.Row.bin_size_t
    Asic_inspection.Row.bin_write_t
    Asic_inspection.Row.bin_read_t
    row;
  let index : Asic_inspection.Index.t =
    { run
    ; execution_file = "/public/execution.json"
    ; execution_sha256 = String.make 64 'a'
    ; domain = "timing"
    ; stage = "routing"
    ; source_digest = String.make 64 'b'
    ; rows = [ row ]
    ; diagnostics = [ "missing corner" ]
    ; truncated = true
    ; cached_unverified = true
    ; analysis = None
    ; times = Evidence_time.Index.empty
    }
  in
  (* Indexes without times must serialize exactly as before timestamps existed: derived
     caches are digested over this sexp. *)
  assert (
    not
      (String.is_substring
         (Sexp.to_string_mach (Asic_inspection.Index.sexp_of_t index))
         ~substring:"times"));
  let legacy = Legacy_index.t_of_sexp (Asic_inspection.Index.sexp_of_t index) in
  assert (
    Asic_inspection.Index.equal
      index
      (Asic_inspection.Index.t_of_sexp (Legacy_index.sexp_of_t legacy)));
  let at seconds =
    Timestamp.of_time_ns (Time_ns.of_span_since_epoch (Time_ns.Span.of_sec seconds))
  in
  let index =
    { index with
      times =
        { production =
            [ "opensta", Supplied { at = at 1.7e9 }
            ; "legacy", Rejected { raw = "yesterday"; reason = "no offset" }
            ]
        ; observations =
            [ Workbench_validated { at = at 1.8e9 }
            ; File_modified { at = at 1.75e9; path = "/public/execution.json" }
            ]
        }
    }
  in
  assert (
    Evidence_time.Production.equal
      (Evidence_time.Index.production index.times ~producer:"absent")
      Unknown);
  let refreshed = Evidence_time.Index.with_validated index.times ~at:(at 1.9e9) in
  assert (
    Result.is_error
      (Or_error.try_with (fun () ->
         Legacy_index.t_of_sexp (Asic_inspection.Index.sexp_of_t index))));
  assert (
    List.equal
      (Tuple2.equal ~eq1:String.equal ~eq2:Evidence_time.Production.equal)
      refreshed.production
      index.times.production);
  assert (
    Option.equal
      Timestamp.equal
      (Evidence_time.Index.validated refreshed)
      (Some (at 1.9e9)));
  assert (
    Option.equal
      (Tuple2.equal ~eq1:String.equal ~eq2:Timestamp.equal)
      (Evidence_time.Index.file_modified refreshed)
      (Evidence_time.Index.file_modified index.times));
  round_trip
    Asic_inspection.Index.equal
    Asic_inspection.Index.sexp_of_t
    Asic_inspection.Index.t_of_sexp
    Asic_inspection.Index.bin_size_t
    Asic_inspection.Index.bin_write_t
    Asic_inspection.Index.bin_read_t
    index;
  let detail : Asic_inspection.Detail.t =
    { run
    ; domain = index.domain
    ; stage = index.stage
    ; source_digest = index.source_digest
    ; row_id = row.id
    ; text = ""
    ; error = Some "stale digest"
    }
  in
  round_trip
    Asic_inspection.Detail.equal
    Asic_inspection.Detail.sexp_of_t
    Asic_inspection.Detail.t_of_sexp
    Asic_inspection.Detail.bin_size_t
    Asic_inspection.Detail.bin_write_t
    Asic_inspection.Detail.bin_read_t
    detail;
  let snapshot : Asic.Snapshot.t =
    { configured = true
    ; flows = []
    ; catalog_default = None
    ; description_json = None
    ; preview = None
    ; runs = []
    ; operations =
        [ { key = Asic_inspection.index_key ~run ~domain:"timing" ~stage:"routing"
          ; kind = "inspection"
          ; state = "executing"
          ; run = Some run
          ; error = None
          ; activity = Evidence_read
          }
        ]
    ; launches = []
    ; summaries = []
    ; finalizations = []
    ; artifacts = []
    ; artifact_pages = []
    ; artifact_byte_pages = []
    ; inspections = [ index ]
    ; inspection_details = [ detail ]
    ; cache_error = None
    ; fresh_intent = None
    ; workflows = []
    ; resources = None
    ; workloads = None
    }
  in
  round_trip
    Asic.Snapshot.equal
    Asic.Snapshot.sexp_of_t
    Asic.Snapshot.t_of_sexp
    Asic.Snapshot.bin_size_t
    Asic.Snapshot.bin_write_t
    Asic.Snapshot.bin_read_t
    snapshot;
  (* Exercise the endpoint's serializer with populated metadata, not just empty defaults.
     Every other field must survive the legacy projection unchanged. *)
  let fields name = function
    | Sexp.List fields ->
      List.Assoc.find_exn
        (List.map fields ~f:(function
          | Sexp.List [ Sexp.Atom name; value ] -> name, value
          | _ -> assert false))
        ~equal:String.equal
        name
    | _ -> assert false
  in
  List.iter [ None; Some ""; Some "0"; Some "2" ] ~f:(fun header_value ->
    let wire = Asic.Evidence_metadata.sexp_of_response ~header_value (Ok snapshot) in
    let payload =
      match wire with
      | Sexp.List [ Sexp.Atom "Ok"; payload ] -> payload
      | _ -> assert false
    in
    (match fields "inspections" payload, fields "operations" payload with
     | Sexp.List [ index ], Sexp.List [ pending ] ->
       ignore (Legacy_index.t_of_sexp index : Legacy_index.t);
       ignore (Legacy_pending.t_of_sexp pending : Legacy_pending.t)
     | _ -> assert false);
    assert (
      Asic.Response.equal
        (Asic.Response.t_of_sexp wire)
        (Ok
           { snapshot with
             inspections = [ { index with times = Evidence_time.Index.empty } ]
           ; operations =
               [ { (List.hd_exn snapshot.operations) with activity = Unreported } ]
           })));
  assert (
    Sexp.equal
      (Asic.Evidence_metadata.sexp_of_response
         ~header_value:(Some Asic.Evidence_metadata.version)
         (Ok snapshot))
      (Asic.Response.sexp_of_t (Ok snapshot)));
  assert (not (Evidence_time.Index.equal index.times Evidence_time.Index.empty));
  List.iter [ None; Some Asic.Evidence_metadata.version ] ~f:(fun header_value ->
    let error = Error (V1.Error.create Invalid_request "test error") in
    assert (
      Sexp.equal
        (Asic.Evidence_metadata.sexp_of_response ~header_value error)
        (Asic.Response.sexp_of_t error)));
  let legacy =
    match Asic.Snapshot.sexp_of_t snapshot with
    | Sexp.List fields ->
      Sexp.List
        (List.filter fields ~f:(function
          | Sexp.List
              (Sexp.Atom ("inspections" | "inspection_details" | "artifact_byte_pages")
              :: _) -> false
          | _ -> true))
    | _ -> assert false
  in
  assert (
    Asic.Snapshot.equal
      (Asic.Snapshot.t_of_sexp legacy)
      { snapshot with
        inspections = []
      ; inspection_details = []
      ; artifact_byte_pages = []
      });
  (* Pending activity is optional on the wire: an older daemon makes no claim. *)
  let unreported : Asic.Pending.t =
    { (List.hd_exn snapshot.operations) with activity = Unreported }
  in
  ignore (Legacy_pending.t_of_sexp (Asic.Pending.sexp_of_t unreported) : Legacy_pending.t);
  assert (
    Result.is_error
      (Or_error.try_with (fun () ->
         Legacy_pending.t_of_sexp
           (Asic.Pending.sexp_of_t (List.hd_exn snapshot.operations)))));
  assert (
    not
      (String.is_substring
         (Sexp.to_string_mach (Asic.Pending.sexp_of_t unreported))
         ~substring:"activity"));
  assert (
    Asic.Pending.equal
      (Asic.Pending.t_of_sexp (Asic.Pending.sexp_of_t unreported))
      unreported);
  List.iter
    [ Asic.Operation.Inspect
        { run; domain = index.domain; stage = index.stage; refresh = false }
    ; Inspect { run; domain = index.domain; stage = index.stage; refresh = true }
    ; Inspect_detail
        { run
        ; domain = index.domain
        ; stage = index.stage
        ; source_digest = index.source_digest
        ; row_id = row.id
        }
    ; Read_artifact_bytes { run; artifact_id = "binary"; offset = 7; limit = 1024 }
    ]
    ~f:
      (round_trip
         Asic.Operation.equal
         Asic.Operation.sexp_of_t
         Asic.Operation.t_of_sexp
         Asic.Operation.bin_size_t
         Asic.Operation.bin_write_t
         Asic.Operation.bin_read_t)
;;

let%test_unit "inspection completion keys isolate full run and detail identities" =
  let index run domain stage = Asic_inspection.index_key ~run ~domain ~stage in
  assert (
    not
      (String.equal
         (index run "timing" "routing")
         (index { run with label = Some "different" } "timing" "routing")));
  let key digest row_id =
    Asic_inspection.detail_key
      ~run
      ~domain:"timing"
      ~stage:"routing"
      ~source_digest:digest
      ~row_id
  in
  assert (not (String.equal (key "a:b" "c") (key "a" "b:c")));
  assert (not (String.equal (key "digest" "row-1") (key "digest" "row-2")));
  assert (not (String.equal (key "digest-1" "row") (key "digest-2" "row")))
;;
