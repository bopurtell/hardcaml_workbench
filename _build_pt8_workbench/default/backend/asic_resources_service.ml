open! Core
open! Async
module Inspection = Asic_inspection
open Hardcaml_workbench_protocol
module W = Asic_resources
module P = Asic_public

type stored = { version : int; identity : string; sources : W.Source.t list; indexes : W.Index.t list; digest : string }
[@@deriving sexp]

type t =
  { filename : string
  ; identity : string
  ; mutable value : W.Snapshot.t
  ; mutable lru : (string * W.Detail.t * int) list
  ; mutable cache_error : string option
  }

let text j k = P.text (P.field k j)
let optional j k = P.optional_text (P.field k j)
let integer j k =
  match P.field k j with
  | `Int n when n >= 0 -> n
  | _ -> failwith ("Invalid resource integer: " ^ k)
;;

let bounded_list n j =
  let xs = P.list j in
  P.require (List.length xs <= n) "Resource list budget exceeded";
  xs
;;

let exact names = function
  | `Assoc xs ->
    P.require (List.equal String.equal (List.sort names ~compare:String.compare)
      (List.sort (List.map xs ~f:fst) ~compare:String.compare)) "Resource object fields do not match schema"
  | _ -> failwith "Resource object required"
;;

let has j name =
  match j with `Assoc fields -> List.Assoc.mem fields name ~equal:String.equal | _ -> false
;;

let exact_optional required optional j =
  exact (required @ List.filter optional ~f:(has j)) j
;;

let classification j =
  if not (has j "classification") then W.Measurement.Classification.Unknown
  else match text j "classification" with
    | "observed" -> Observed
    | "derived" -> Derived
    | "estimate" -> Estimate
    | "unknown" -> Unknown
    | _ -> failwith "Unrecognized resource measurement classification"
;;

let inventory_status j =
  P.require (Bool.equal (has j "inventory_status") (has j "inventory_reason"))
    "Incomplete resource inventory availability fields";
  if not (has j "inventory_status") then W.Inventory_status.Unknown
  else match text j "inventory_status" with
    | "available" -> Available
    | "unavailable" -> Unavailable
    | "unknown" -> Unknown
    | _ -> failwith "Unrecognized resource inventory status"
;;

let content_digest sources indexes =
  P.digest (Sexp.to_string_mach [%sexp (sources : W.Source.t list), (indexes : W.Index.t list)])
;;

let finite = function
  | `Null -> None
  | `Int n -> Some (Float.of_int n)
  | `Intlit s ->
    let n = Float.of_string s in
    P.require (Float.is_finite n) "Nonfinite resource measurement";
    Some n
  | `Float n when Float.is_finite n -> Some n
  | _ -> failwith "Invalid resource measurement"
;;

let measurement j : W.Measurement.t =
  exact_optional ["name";"value";"unit";"stage";"definition";"scope";"reason"] ["classification"] j;
  { name = text j "name"; value = finite (P.field "value" j); unit_ = text j "unit"
  ; stage = text j "stage"; definition = text j "definition"; scope = text j "scope"
  ; reason = optional j "reason"; classification = classification j }
;;

let unique label xs =
  P.require (not (List.contains_dup xs ~compare:String.compare)) ("Duplicate " ^ label)
;;

let row j : W.Row.t =
  exact ["id";"contract";"requirement";"policy";"implementation";"reason";"role";"instances";"synthesis";"final";"measurements";"sections"] j;
  let sections = bounded_list 16 (P.field "sections" j) |> List.map ~f:(fun j ->
    exact ["id";"count";"status"] j;
    { W.Section.id = text j "id"; count = integer j "count"; status = text j "status" }) in
  unique "resource section" (List.map sections ~f:(fun s -> s.W.Section.id));
  Inspection.validate_row_id (text j "id");
  { id = text j "id"; contract = text j "contract"; requirement = text j "requirement"
  ; policy = text j "policy"; implementation = text j "implementation"; reason = text j "reason"
  ; role = text j "role"; instances = bounded_list 4096 (P.field "instances" j) |> List.map ~f:P.text
  ; synthesis = text j "synthesis"; final = text j "final"
  ; measurements = bounded_list 256 (P.field "measurements" j) |> List.map ~f:measurement
  ; sections }
;;

let validate_index (i : W.Index.t) =
  Inspection.validate_digest i.digest;
  P.require (List.length i.rows <= 4096 && i.artifact_count <= 1024) "Resource index bounds";
  unique "resource ID" (List.map i.rows ~f:(fun r -> r.W.Row.id));
  (match i.inventory_status with
   | Available -> P.require (Option.is_none i.inventory_reason) "Available resource inventory has an unavailable reason"
   | Unavailable ->
     P.require (List.is_empty i.rows && String.equal i.verdict "not_evaluated"
       && Option.exists i.inventory_reason ~f:(fun s -> not (String.is_empty (String.strip s))))
       "Unavailable inventory requires a reason, no asserted rows and no resource verdict"
   | Unknown -> ());
  P.require (String.length (Sexp.to_string_mach (W.Index.sexp_of_t i)) <= 2 * 1024 * 1024)
    "Normalized resource index exceeds 2MiB";
  List.iter (i.measurements @ List.concat_map i.rows ~f:(fun r -> r.measurements)) ~f:(fun m ->
    Option.iter m.value ~f:(fun f -> P.require (Float.is_finite f) "Nonfinite cached resource value"));
  ignore (P.decode i.provenance : Yojson.Safe.t)
;;

let create ~state_dir ~identity =
  let filename = Filename.concat state_dir ("asic-resources-" ^ P.digest identity ^ ".sexp") in
  let t = { filename; identity; value = W.Snapshot.empty; lru = []; cache_error = None } in
  (try
     if Poly.equal (Sys_unix.file_exists filename) `Yes then (
       let raw = Asic_evidence_file.read_bounded filename (18 * 1024 * 1024) in
       let stored = stored_of_sexp (Sexp.of_string raw) in
       P.require (stored.version = 1 && String.equal stored.identity identity
         && List.length stored.sources <= 32 && List.length stored.indexes <= 8) "Incompatible resource cache";
       unique "resource source" (List.map stored.sources ~f:(fun s -> s.W.Source.id));
       unique "resource index source" (List.map stored.indexes ~f:(fun i -> i.W.Index.source_id));
       P.require (String.equal stored.digest (content_digest stored.sources stored.indexes)) "Resource cache content digest mismatch";
       List.iter stored.sources ~f:(fun s ->
         P.require (String.equal s.W.Source.id (P.digest (identity ^ Sexp.to_string_mach (W.Target.sexp_of_t s.target)))) "Resource source cache identity mismatch");
       List.iter stored.indexes ~f:(fun i ->
         validate_index i;
         P.require (List.exists stored.sources ~f:(fun s -> String.equal s.W.Source.id i.source_id)) "Orphan resource cache");
       t.value <- { W.Snapshot.empty with
         sources = List.map stored.sources ~f:(fun s -> { s with W.Source.freshness = Cached_unverified })
       ; indexes = stored.indexes })
   with exn -> t.cache_error <- Some (Exn.to_string exn));
  t
;;

let save t =
  let data = Sexp.to_string_mach (sexp_of_stored
    { version = 1; identity = t.identity; sources = t.value.sources; indexes = t.value.indexes
    ; digest = content_digest t.value.sources t.value.indexes }) in
  P.require (String.length data <= 18 * 1024 * 1024) "Resource cache byte budget";
  let temporary = Filename_unix.temp_file ~in_dir:(Filename.dirname t.filename) ".resources-" ".tmp" in
  Exn.protect ~finally:(fun () -> if Poly.equal (Sys_unix.file_exists temporary) `Yes then Core_unix.unlink temporary)
    ~f:(fun () -> Out_channel.write_all temporary ~data; Core_unix.rename ~src:temporary ~dst:t.filename)
;;

(** The native resource CLI applies this exit/verdict contract to every query,
    including details, catalog and byte pages of genuine failed evidence. *)
let parse_process_result (output : Asic_process.Output.t) =
  let j = P.decode output.stdout |> fun j -> P.envelope j "hardcaml-asic.resource-inspection" 1 in
  let verdict = text j "verdict" in
  P.require
    (match output.exit_code, verdict with
     | 0, ("pass" | "not_evaluated") | 1, "fail" -> true
     | _ -> false)
    (sprintf "Resource CLI exit/verdict disagreement: exit %d, verdict %s" output.exit_code verdict);
  j
;;

let snapshot t = t.value
let cache_error t = t.cache_error

let invalidate_run t run =
  let ids = List.filter_map t.value.sources ~f:(fun s ->
    match s.W.Source.target with
    | Run r | Finalization {run=r;_} when Run_ref.equal r run -> Some s.id
    | _ -> None) in
  let invalid id = List.mem ids id ~equal:String.equal in
  t.value <- {t.value with
    sources=List.map t.value.sources ~f:(fun s -> if invalid s.W.Source.id then
      {s with freshness=Stale "Registered execution observation advanced; refresh resource evidence"} else s)
  ; details=List.filter t.value.details ~f:(fun d -> not (invalid d.W.Detail.source_id))
  ; artifacts=List.filter t.value.artifacts ~f:(fun d -> not (invalid d.W.Artifacts.source_id))
  ; bytes=List.filter t.value.bytes ~f:(fun d -> not (invalid d.W.Bytes.source_id))};
  t.lru <- List.filter t.lru ~f:(fun (_,d,_) -> not (invalid d.W.Detail.source_id))
;;
let source t id = List.find_exn t.value.sources ~f:(fun s -> String.equal s.W.Source.id id)
let index t id = List.find_exn t.value.indexes ~f:(fun i -> String.equal i.W.Index.source_id id)
let source_id t target = P.digest (t.identity ^ Sexp.to_string_mach (W.Target.sexp_of_t target))

let cached t target =
  let id = source_id t target in
  List.exists t.value.indexes ~f:(fun i -> String.equal i.W.Index.source_id id)
;;

let replace_source t (s : W.Source.t) =
  t.value <- { t.value with sources = s :: List.filter t.value.sources ~f:(fun old -> not (String.equal old.id s.id)) }
;;

let fail t target message =
  let id = source_id t target in
  let old = List.find t.value.sources ~f:(fun s -> String.equal s.W.Source.id id) in
  let s = Option.value old ~default:
    { W.Source.id; target; kind="unavailable";path="";label="Resource source unavailable"
    ; provider_identity="";freshness=Cached_unverified;error=None } in
  let freshness =
    if String.is_substring message ~substring:"resource_inspection1" then W.Freshness.Unsupported message
    else if String.is_substring message ~substring:"No such file" || String.is_substring message ~substring:"ENOENT" then Missing_source message
    else Refresh_failed message in
  if Option.is_some old || List.length t.value.sources < 32 then
    replace_source t { s with freshness; error = Some message }
;;

let envelope (source : W.Source.t) ~query j =
  let common=["contract";"schema_version";"kind";"target";"query";"source_digest";"provenance";"verdict"] in
  let names=match query with
    | "index" -> ["rows";"measurements";"artifact_count";"diagnostics";"truncated"]
    | "detail" -> ["resource_id";"section";"offset";"next_offset";"total";"items"]
    | "artifacts" -> ["offset";"next_offset";"total";"entries"]
    | "bytes" -> ["artifact_id";"sha256";"offset";"next_offset";"total";"bytes_hex"]
    | _ -> failwith "Invalid resource query" in
  exact_optional (common@names) (if String.equal query "index" then ["inventory_status";"inventory_reason"] else []) j;
  let j = P.envelope j "hardcaml-asic.resource-inspection" 1 in
  List.iter [ "kind",source.kind; "target",source.path; "query",query ] ~f:(fun (k,v) ->
    P.require (String.equal (text j k) v) ("Resource envelope mismatch: " ^ k));
  Inspection.validate_digest (text j "source_digest");
  j
;;

let parse_index source j : W.Index.t =
  let j = envelope source ~query:"index" j in
  let i =
    { W.Index.source_id = source.id; digest = text j "source_digest"
    ; provenance = Yojson.Safe.to_string (P.field "provenance" j)
    ; rows = bounded_list 4096 (P.field "rows" j) |> List.map ~f:row
    ; measurements = bounded_list 1024 (P.field "measurements" j) |> List.map ~f:measurement
    ; artifact_count = integer j "artifact_count"
    ; diagnostics = bounded_list 256 (P.field "diagnostics" j) |> List.map ~f:P.text
    ; truncated = (match P.field "truncated" j with `Bool b -> b | _ -> failwith "Resource truncated flag")
    ; verdict = text j "verdict"
    ; inventory_status = inventory_status j
    ; inventory_reason = optional j "inventory_reason" }
  in
  P.require (List.mem [ "pass"; "fail"; "not_evaluated" ] i.verdict ~equal:String.equal) "Invalid resource verdict";
  validate_index i;
  i
;;

let load t ~target ~kind ~path ~provider_identity ~check ~query =
  let id = source_id t target in
  let source = { W.Source.id; target; kind; path; label = Filename.basename path
    ; provider_identity; freshness = Cached_unverified; error = None } in
  P.require (List.length t.value.sources < 32 || List.exists t.value.sources ~f:(fun s -> String.equal s.W.Source.id id)) "Resource source budget exhausted";
  if not (List.exists t.value.sources ~f:(fun s -> String.equal s.W.Source.id id)) then replace_source t source;
  let%bind j = query [] in
  check ();
  let i = parse_index source j in
  let freshness=match i.inventory_status with Unknown -> W.Freshness.Cached_unverified | Available | Unavailable -> Validated in
  let sources = List.map t.value.sources ~f:(fun s -> if String.equal s.W.Source.id id then { source with freshness } else s) in
  t.value <- { sources
    ; indexes = List.take (i :: List.filter t.value.indexes ~f:(fun old -> not (String.equal old.source_id id))) 8
    ; details = List.filter t.value.details ~f:(fun d -> not (String.equal d.source_id id))
    ; artifacts = List.filter t.value.artifacts ~f:(fun d -> not (String.equal d.source_id id))
    ; bytes = List.filter t.value.bytes ~f:(fun d -> not (String.equal d.source_id id)) };
  t.lru <- List.filter t.lru ~f:(fun (_,d,_) -> not (String.equal d.W.Detail.source_id id));
  let%map () = In_thread.run (fun () -> save t) in
  (* Only a completed atomic replacement repairs an active persistence error.
     Provider/parse/check/save failures leave the diagnostic available. *)
  t.cache_error <- None
;;

let page_bounds ~offset ~limit ~bytes =
  P.require (offset >= 0 && offset <= 128 * 1024 * 1024 && limit >= 1
    && limit <= if bytes then 16384 else 64) "Resource page budget"
;;

let paging j ~offset ~count =
  let total = integer j "total" and next = integer j "next_offset" in
  P.require (integer j "offset" = offset && next = offset + count && next <= total)
    "Resource paging mismatch";
  P.require (count > 0 || offset >= total) "Nonprogressing resource page";
  next,total
;;

let publish xs ~equal x = List.take (x :: List.filter xs ~f:(fun old -> not (equal old x))) 8

let page t operation ~check ~query =
  check ();
  let source_id,expected,query_name,offset,limit,args =
    match operation with
    | W.Operation.Load _ -> failwith "Load is not a resource page"
    | Detail {source_id;expected_digest;resource_id;section;offset;limit} ->
      source_id,expected_digest,"detail",offset,limit,["--resource-id";resource_id;"--section";section]
    | Artifacts {source_id;expected_digest;offset;limit} ->
      source_id,expected_digest,"artifacts",offset,limit,[]
    | Read_artifact {source_id;expected_digest;artifact_id;offset;limit} ->
      source_id,expected_digest,"bytes",offset,limit,["--artifact-id";artifact_id]
  in
  page_bounds ~offset ~limit ~bytes:(String.equal query_name "bytes");
  Inspection.validate_digest source_id;
  let s = source t source_id and i = index t source_id in
  (match s.freshness with Stale reason -> failwith reason | _ -> ());
  Inspection.validate_digest expected;
  P.require (String.equal i.digest expected) "Stale resource index digest";
  (match operation with
   | Detail {resource_id;section;_} ->
     Inspection.validate_row_id resource_id;
     P.require (String.length section <= 64) "Resource section exceeds budget";
     let row = List.find_exn i.rows ~f:(fun r -> String.equal r.W.Row.id resource_id) in
     P.require (List.exists row.sections ~f:(fun s -> String.equal s.W.Section.id section)) "Unknown resource section"
   | Read_artifact {artifact_id;_} ->
     Inspection.validate_digest artifact_id;
     P.require (List.exists t.value.artifacts ~f:(fun a ->
       String.equal a.W.Artifacts.source_id source_id && String.equal a.digest expected
       && List.exists a.entries ~f:(fun e -> String.equal e.W.Artifact.id artifact_id)))
       "Resource artifact requires a current catalog handle"
   | _ -> ());
  let key = W.Operation.key operation ^ s.provider_identity in
  let cached = List.find t.lru ~f:(fun (k,_,_) -> String.equal k key) in
  match cached with
  | Some (_,detail,size) ->
    t.lru <- (key,detail,size) :: List.filter t.lru ~f:(fun (k,_,_) -> not (String.equal k key));
    t.value <- { t.value with details = publish t.value.details ~equal:W.Detail.equal detail };
    Deferred.unit
  | None ->
    let%bind j = query (["--query";query_name;"--expected-digest";expected;"--offset";Int.to_string offset;"--limit";Int.to_string limit] @ args) in
    check ();
    let j = envelope s ~query:query_name j in
    P.require (String.equal (text j "source_digest") expected && W.Index.equal i (index t source_id)) "Resource source changed during page read";
    P.require (String.length (Yojson.Safe.to_string j) <= 65536) "Resource page exceeds 64KiB";
    (match operation with
     | Detail {resource_id;section;_} ->
       P.require (String.equal (text j "resource_id") resource_id && String.equal (text j "section") section) "Resource detail identity mismatch";
       let items = bounded_list limit (P.field "items" j) |> List.map ~f:(fun j ->
         exact ["id";"title";"fields"] j;
         { W.Item.id = text j "id"; title = text j "title"; fields =
           bounded_list 1024 (P.field "fields" j) |> List.map ~f:(function
             | `List [`String k;`String v] -> k,v | _ -> failwith "Invalid resource item fields") }) in
       let next_offset,total = paging j ~offset ~count:(List.length items) in
       let d = { W.Detail.source_id; digest=expected;resource_id;section;offset;next_offset;total;items } in
       let size = String.length (Sexp.to_string_mach (W.Detail.sexp_of_t d)) in
       P.require (size <= 65536) "Normalized resource detail exceeds 64KiB";
       let candidates = (key,d,size) :: List.filter t.lru ~f:(fun (k,_,_) -> not (String.equal k key)) in
       let rec trim n bytes = function
         | (_,_,size):: _ when n=0 || size>bytes -> []
         | (k,d,size)::xs -> (k,d,size)::trim (n-1) (bytes-size) xs
         | [] -> [] in
       t.lru <- trim 64 (4*1024*1024) candidates;
       t.value <- {t.value with details=publish t.value.details ~equal:W.Detail.equal d}
     | Artifacts _ ->
       let entries = bounded_list limit (P.field "entries" j) |> List.map ~f:(fun j ->
         exact ["id";"label";"sha256";"format"] j;
         Inspection.validate_digest (text j "id"); Inspection.validate_digest (text j "sha256");
         { W.Artifact.id=text j "id";label=text j "label";sha256=text j "sha256";format=text j "format" }) in
       unique "resource artifact" (List.map entries ~f:(fun a -> a.W.Artifact.id));
       let next_offset,total=paging j ~offset ~count:(List.length entries) in
       P.require (total=i.artifact_count) "Resource artifact count changed";
       let a={W.Artifacts.source_id;digest=expected;offset;next_offset;total;entries} in
       t.value <- {t.value with artifacts=publish t.value.artifacts ~equal:W.Artifacts.equal a}
     | Read_artifact {artifact_id;_} ->
       P.require (String.equal (text j "artifact_id") artifact_id) "Resource artifact ID mismatch";
       let known = List.concat_map t.value.artifacts ~f:(fun a ->
         if String.equal a.W.Artifacts.source_id source_id && String.equal a.digest expected then a.entries else []) in
       let entry=List.find_exn known ~f:(fun a -> String.equal a.W.Artifact.id artifact_id) in
       P.require (String.equal (text j "sha256") entry.sha256) "Resource artifact hash mismatch";
       let bytes_hex=text j "bytes_hex" in
       P.require (String.length bytes_hex % 2=0 && String.length bytes_hex<=2*limit
         && String.for_all bytes_hex ~f:(function '0'..'9'|'a'..'f' -> true | _ -> false)) "Invalid resource artifact bytes";
       let next_offset,total=paging j ~offset ~count:(String.length bytes_hex/2) in
       let b={W.Bytes.source_id;digest=expected;artifact_id;sha256=entry.sha256;offset;next_offset;total;bytes_hex} in
       t.value <- {t.value with bytes=publish t.value.bytes ~equal:W.Bytes.equal b}
     | Load _ -> assert false);
    Deferred.unit
;;
