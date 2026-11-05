open! Core
open! Async
open Hardcaml_workbench_protocol
module W = Asic_workloads
module P = Asic_public
module Storage = Asic_workloads_storage

let mib = 1024 * 1024
let key query = W.Operation.key (Load { query; refresh = false })
let require = P.require
let digest s =
  require (String.length s = 64 && String.for_all s ~f:(function
    | '0'..'9' | 'a'..'f' -> true | _ -> false)) "Invalid workload digest"
;;
let path s =
  require (Filename.is_absolute s && String.length s <= 4096
    && not (String.contains s '\000')) "Workload path must be absolute and bounded"
;;
let target = function
  | W.Target.Bundle p -> "bundle", p
  | Coarse_run p -> "coarse_run", p
  | Execution p -> "execution", p
;;
let axis = function
  | W.Axis.Hardware -> "hardware" | Resource_policy -> "resource_policy"
  | Flow_configuration -> "flow_configuration" | Descriptive -> "descriptive"
;;
let validate_query = function
  | W.Query.Inspect q -> path q.result; Option.iter q.expected_digest ~f:digest
  | Compare q ->
    path (snd (target q.left)); path (snd (target q.right));
    List.iter [q.left_workload;q.right_workload] ~f:(Option.iter ~f:path);
    List.iter [q.expected_left_digest;q.expected_right_digest;
      q.expected_left_workload_digest;q.expected_right_workload_digest]
      ~f:(Option.iter ~f:digest);
    require (Option.is_none q.expected_left_workload_digest || Option.is_some q.left_workload)
      "Left workload digest requires a workload path";
    require (Option.is_none q.expected_right_workload_digest || Option.is_some q.right_workload)
      "Right workload digest requires a workload path"
;;

let field j name = P.field name j
let text j name = P.text (field j name)
let object_ = function `Assoc _ -> () | _ -> failwith "Expected workload JSON object"
let bounded_list j name limit =
  let xs = P.list (field j name) in
  require (List.length xs <= limit) ("Workload list budget: " ^ name); xs
;;
let fence expected actual =
  digest actual;
  Option.iter expected ~f:(fun expected ->
    require (String.equal expected actual) "Captured workload/target digest changed")
;;
let exact j names =
  match j with
  | `Assoc xs -> require (List.equal String.equal
      (List.sort (List.map xs ~f:fst) ~compare:String.compare)
      (List.sort names ~compare:String.compare)) "Workload envelope fields mismatch"
  | _ -> failwith "Expected workload envelope"
;;
let numeric = function
  | `Null | `Int _ | `Intlit _ -> ()
  | `Float f when Float.is_finite f -> ()
  | _ -> failwith "Invalid workload numeric value"
;;
let integer = function `Int _ | `Intlit _ -> () | _ -> failwith "Expected exact workload integer"
let ratio = function
  | `Null -> ()
  | j ->
    exact j ["numerator";"denominator"];
    integer (field j "numerator"); integer (field j "denominator");
    let positive = match field j "denominator" with
      | `Int n -> n>0
      | `Intlit s -> not (String.is_prefix s ~prefix:"-") && String.exists s ~f:(fun c -> Char.(c >= '1' && c <= '9'))
      | _ -> false in
    require positive "Invalid workload rational denominator"
;;
let unique_metrics rows =
  let ids = List.map rows ~f:(fun r -> text r "metric_id") in
  require (not (List.contains_dup ids ~compare:String.compare)) "Duplicate workload metric ID"
;;
let metric m =
  object_ m;
  ignore (text m "metric_id" : string);
  List.iter ["name";"quantity"]
    ~f:(fun k -> ignore (text m k : string));
  require (List.mem ["integer";"real"] (text m "quantity") ~equal:String.equal)
    "Invalid workload metric quantity";
  List.iter ["classification";"unit";"stage";"definition"] ~f:(fun k ->
    match field m k with `Null | `String _ -> () | _ -> failwith "Invalid metric description");
  numeric (field m "value");
  if String.equal (text m "quantity") "integer" && not (Poly.equal (field m "value") `Null)
  then (match field m "value" with
    | `Float f when Float.(f >= 0. && f < 9007199254740992. && round_down f = f) -> ()
    | n -> integer n);
  List.iter ["numerator";"denominator"] ~f:(fun k -> match field m k with `Null -> () | n -> integer n)
;;

let validate_response query raw =
  validate_query query;
  require (String.length raw <= mib) "Workload response exceeds 1MiB";
  let j = Yojson.Safe.from_string raw in
  let nodes = ref 0 in
  let rec structure depth j =
    incr nodes;
    require (depth <= 64 && !nodes <= 100_000) "Workload JSON structural budget";
    match j with
    | `Assoc xs ->
      require (List.length xs <= 4096) "Workload object budget";
      require (not (List.contains_dup (List.map xs ~f:fst) ~compare:String.compare)) "Duplicate workload JSON key";
      List.iter xs ~f:(fun (_,v) -> structure (depth+1) v)
    | `List xs ->
      require (List.length xs <= 16384) "Workload array budget";
      List.iter xs ~f:(structure (depth+1))
    | `Intlit s ->
      let digits = if String.is_prefix s ~prefix:"-" then String.drop_prefix s 1 else s in
      require (String.length s <= 1024 && not (String.is_empty digits)
        && String.for_all digits ~f:Char.is_digit) "Invalid exact workload integer"
    | `Float f -> require (Float.is_finite f) "Nonfinite workload JSON"
    | `Tuple _ | `Variant _ -> failwith "Nonstandard workload JSON"
    | _ -> ()
  in
  structure 0 j;
  let inspection ?expected j =
    exact j ["contract";"schema_version";"source_digest";"binding";"controls";"provenance";"outcome";"metrics"];
    ignore (P.envelope j "hardcaml-asic.workload-inspection" 1 : Yojson.Safe.t);
    let d = text j "source_digest" in fence expected d;
    List.iter ["binding";"controls";"provenance";"outcome"] ~f:(fun k -> object_ (field j k));
    List.iter ["bundle_identity";"hardware_variant_identity";"workload_identity";"simulation_sha256"]
      ~f:(fun k -> digest (text (field j "binding") k));
    (match field j "binding" with
     | `Assoc fields when List.Assoc.mem fields "bundle" ~equal:String.equal ->
       path (text (field j "binding") "bundle")
     | _ -> ());
    ignore (text (field j "binding") "simulation_attempt_id" : string);
    let outcome = field j "outcome" in
    List.iter ["status",["completed";"failed";"interrupted";"partial"];
      "functional",["pass";"fail";"unavailable"];
      "performance",["available";"unavailable"]] ~f:(fun (k, allowed) ->
        require (List.mem allowed (text outcome k) ~equal:String.equal) ("Invalid workload outcome: " ^ k));
    let metrics = bounded_list j "metrics" 256 in unique_metrics metrics;
    List.iter metrics ~f:metric;
    d
  in
  let d = match query with
    | W.Query.Inspect q -> inspection ?expected:q.expected_digest j
    | Compare q ->
      exact j ["contract";"schema_version";"comparison_digest";"policy";"axis";"left";"right";"differences";"metrics";"workload";"truncated"];
      ignore (P.envelope j "hardcaml-asic.variant-comparison" 1 : Yojson.Safe.t);
      require (String.equal (text j "policy") "bounded-pair-v1"
        && String.equal (text j "axis") (axis q.axis)
        && Poly.equal (field j "truncated") (`Bool false)) "Unsupported comparison policy/axis/truncation";
      let side name selected workload expected expected_workload =
        let s = field j name in object_ s;
        let kind, _ = target selected in
        require (String.equal (text s "kind") kind) "Comparison target kind mismatch";
        (* Provider canonicalizes admitted root aliases. Paths are descriptive;
           exact identities are pinned by source digests, never guessed from paths. *)
        path (text s "target");
        fence expected (text s "source_digest");
        object_ (field s "identities"); object_ (field s "outcomes");
        (match workload, field s "workload" with
         | None, `Null -> ()
         | Some _, w -> ignore (inspection ?expected:expected_workload w : string)
         | None, _ -> failwith "Unexpected comparison workload attachment")
      in
      side "left" q.left q.left_workload q.expected_left_digest q.expected_left_workload_digest;
      side "right" q.right q.right_workload q.expected_right_digest q.expected_right_workload_digest;
      let metrics = bounded_list j "metrics" 512 in unique_metrics metrics;
      List.iter metrics ~f:(fun m ->
        List.iter ["left";"right"] ~f:(fun k -> match field m k with `Null -> () | value -> metric value);
        let state = text m "comparison" in
        require (List.mem ["comparable";"confounded";"unavailable"] state ~equal:String.equal)
          "Invalid metric comparison state";
        List.iter (bounded_list m "reasons" 256) ~f:(fun r -> ignore (P.text r : string));
        numeric (field m "right_minus_left");
        ratio (field m "right_minus_left_ratio");
        if not (String.equal state "comparable") then
          require (Poly.equal (field m "right_minus_left") `Null
            && Poly.equal (field m "right_minus_left_ratio") `Null) "Unavailable/confounded metric asserts delta");
      ignore (bounded_list j "differences" 4096 : Yojson.Safe.t list);
      let d = text j "comparison_digest" in digest d; d
  in
  (* Retain original JSON bytes: no float conversion or rational recomputation. *)
  { W.Response.key = key query; digest = d; json = raw }
;;

let query_paths = function
  | W.Query.Inspect q -> [q.result]
  | Compare q -> [snd (target q.left);snd (target q.right)]
    @ List.filter_opt [q.left_workload;q.right_workload]
;;
let evidence_roots query paths =
  match query, paths with
  | W.Query.Inspect _, [p] -> [Filename.dirname p]
  | Compare q, left::right::workloads ->
    let root target p = match target with W.Target.Execution _ -> Filename.dirname p | _ -> p in
    [root q.left left;root q.right right] @ List.map workloads ~f:Filename.dirname
  | _ -> failwith "Invalid workload binding paths"
;;
let lexical p =
  let parts=List.fold (String.split p ~on:'/') ~init:[] ~f:(fun parts -> function
    | "" | "." -> parts | ".." -> List.drop parts 1 | name -> name::parts) in
  "/" ^ String.concat ~sep:"/" (List.rev parts)
;;
let separate cache roots =
  List.iter roots ~f:(fun root ->
    let root=lexical root in
    require (not (String.equal root "/" || String.equal cache root
      || String.is_prefix cache ~prefix:(root ^ "/"))) "Workload cache must be outside selected evidence roots")
;;
let capture_targets query =
  let result p = Filename.concat (Filename_unix.realpath (Filename.dirname p)) (Filename.basename p) in
  match query with
  | W.Query.Inspect q -> [result q.result]
  | Compare q ->
    [Filename_unix.realpath (snd (target q.left));Filename_unix.realpath (snd (target q.right))]
    @ List.filter_map [q.left_workload;q.right_workload] ~f:(Option.map ~f:result)
;;
let check_targets query ~paths raw =
  let j = Yojson.Safe.from_string raw in
  let inspection selected j =
    let sources = bounded_list (field j "provenance") "sources" 16384 in
    require (List.exists sources ~f:(fun source -> String.equal (text source "path") selected))
      "Workload inspection does not bind selected result path"
  in
  match query, paths with
  | W.Query.Inspect _, [p] -> inspection p j
  | Compare q, left::right::workloads ->
    require (String.equal (text (field j "left") "target") left
      && String.equal (text (field j "right") "target") right) "Comparison returned different selected targets";
    let sides=List.filter_map ["left",q.left_workload;"right",q.right_workload]
      ~f:(fun (side,p) -> Option.map p ~f:(fun _ -> side)) in
    List.iter2_exn sides workloads ~f:(fun side path -> inspection path (field (field j side) "workload"))
  | _ -> failwith "Invalid captured workload target paths"
;;
let check_bindings query bindings raw =
  require (List.equal String.equal (query_paths query) (List.map bindings ~f:fst))
    "Cached workload query/binding mismatch";
  List.iter bindings ~f:(fun (original,canonical) -> path original; path canonical;
    require (String.equal canonical (lexical canonical)) "Cached workload binding is not canonical");
  let paths=List.map bindings ~f:snd in
  check_targets query ~paths raw
;;
let bundle_roots raw =
  let j=Yojson.Safe.from_string raw in
  let bundle j = match field j "binding" with
    | `Assoc xs when List.Assoc.mem xs "bundle" ~equal:String.equal -> Some (text (field j "binding") "bundle")
    | _ -> None in
  List.filter_opt [bundle j;bundle (field (field j "left") "workload");bundle (field (field j "right") "workload")]
;;
let bound_separation cache query bindings raw =
  separate cache (evidence_roots query (List.map bindings ~f:snd)
    @ evidence_roots query (List.map bindings ~f:fst) @ bundle_roots raw)
;;

type item =
  { descriptor : W.Descriptor.t
  ; response : W.Response.t option
  ; bindings : (string * string) list
  }
[@@deriving sexp]
type stored = { version : int; identity : string; items : item list; checksum : string }
[@@deriving sexp]
type t =
  { name : string; storage : Storage.t; identity : string; mutable items : item list
  ; mutable selected : string option; mutable cache_error : string option }

let size item = Option.value_map item.response ~default:0 ~f:(fun r -> String.length r.json)
let checksum items = P.digest (Sexp.to_string_mach ([%sexp_of: item list] items))
let trim items =
  let rec loop count bytes = function
    | [] -> []
    | i::xs when count < 8 && bytes + size i <= 8*mib -> i::loop (count+1) (bytes+size i) xs
    | _ -> []
  in loop 0 0 items
;;
let create ~state_dir ~identity =
  let name = "asic-workloads-" ^ P.digest identity ^ ".sexp" in
  let storage=Storage.create state_dir in
  let t = { name; storage; identity; items=[]; selected=None; cache_error=None } in
  (try
     Option.iter (Storage.read storage ~name ~max_bytes:(32*mib)) ~f:(fun raw ->
       let s = stored_of_sexp (Sexp.of_string raw) in
       require (s.version=2 && String.equal s.identity identity && List.length s.items<=8
         && List.sum (module Int) s.items ~f:size<=8*mib) "Invalid workload cache bounds/identity";
       require (String.equal s.checksum (checksum s.items)) "Workload cache checksum mismatch";
       require (not (List.contains_dup (List.map s.items ~f:(fun i -> i.descriptor.key)) ~compare:String.compare))
         "Duplicate workload cache key";
       List.iter s.items ~f:(fun i ->
         validate_query i.descriptor.query;
         require (String.equal i.descriptor.key (key i.descriptor.query)) "Workload cache key mismatch";
         Option.iter i.descriptor.provider_identity ~f:digest;
         Option.iter i.response ~f:(fun r ->
           let checked = validate_response i.descriptor.query r.json in
            require (W.Response.equal checked r && Option.equal String.equal i.descriptor.digest (Some r.digest))
              "Workload cache response mismatch";
            check_bindings i.descriptor.query i.bindings r.json;
            bound_separation (Storage.canonical storage) i.descriptor.query i.bindings r.json));
       t.items <- List.map s.items ~f:(fun i -> {i with descriptor={i.descriptor with freshness=Cached_unverified}}))
   with exn -> t.cache_error <- Some (String.prefix (Exn.to_string exn) 4096));
  t
;;
let snapshot t =
  { W.Snapshot.entries = List.map t.items ~f:(fun i -> i.descriptor)
  ; selected = Option.bind t.selected ~f:(fun key ->
      List.find t.items ~f:(fun i -> String.equal i.descriptor.key key)
      |> Option.bind ~f:(fun i -> i.response))
  ; cache_error = t.cache_error }
;;
let cached t query = List.exists t.items ~f:(fun i -> String.equal i.descriptor.key (key query) && Option.is_some i.response)
let replace t item = t.items <- trim (item :: List.filter t.items ~f:(fun i -> not (String.equal i.descriptor.key item.descriptor.key)))
let select t query =
  validate_query query;
  let k = key query in t.selected <- Some k;
  Option.iter (List.find t.items ~f:(fun i -> String.equal i.descriptor.key k)) ~f:(replace t)
;;
let fail t query error =
  let k = key query in
  let old = List.find t.items ~f:(fun i -> String.equal i.descriptor.key k) in
  let descriptor = Option.value_map old ~f:(fun i -> i.descriptor) ~default:
    {W.Descriptor.key=k;query;digest=None;provider_identity=None;freshness=Cached_unverified;error=None} in
  let error = String.prefix error 4096 in
  replace t {descriptor={descriptor with freshness=Refresh_failed error;error=Some error};
    response=Option.bind old ~f:(fun i -> i.response);
    bindings=Option.value_map old ~default:[] ~f:(fun i -> i.bindings)}
;;
let publish ?paths ?(check=fun () -> ()) t query ~provider_identity raw =
  digest provider_identity;
  let response = validate_response query raw in
  let originals=query_paths query in
  let paths=Option.value paths ~default:originals in
  let bindings=List.zip_exn originals paths in
  check_bindings query bindings raw;
  bound_separation (Storage.canonical t.storage) query bindings raw;
  let descriptor = {W.Descriptor.key=key query;query;digest=Some response.digest;
    provider_identity=Some provider_identity;freshness=Validated;error=None} in
  let items=trim ({descriptor;response=Some response;bindings}
    ::List.filter t.items ~f:(fun i -> not (String.equal i.descriptor.key descriptor.key))) in
  let data = Sexp.to_string_mach (sexp_of_stored
    {version=2;identity=t.identity;items;checksum=checksum items}) in
  require (String.length data <= 32*mib) "Serialized workload cache exceeds budget";
  check ();
  let%bind result = Monitor.try_with (fun () -> In_thread.run (fun () ->
    Storage.write t.storage ~name:t.name ~data ~before_write:(fun () ->
      bound_separation (Storage.canonical t.storage) query bindings raw;
      separate (Storage.canonical t.storage)
        (List.map (evidence_roots query (query_paths query) @ bundle_roots raw) ~f:Storage.physical)))) in
  match result with
  | Ok () -> check (); t.items <- items; t.cache_error <- None; Deferred.unit
  | Error exn -> t.cache_error <- Some (String.prefix (Exn.to_string exn) 4096); raise exn
;;

let check_capabilities query metadata =
  P.metadata metadata;
  let caps = field (field metadata "cli_contract") "capabilities" in
  let capability name =
    match field caps name with
    | `Bool true -> ()
    | `Assoc _ as c -> require (Poly.equal (field c "schema_version") (`Int 1)
        && Poly.equal (field c "read_only") (`Bool true)) ("Unsupported " ^ name)
    | _ -> failwith ("Provider lacks " ^ name)
  in
  match query with
  | W.Query.Inspect _ -> capability "workload_inspection1"
  | Compare q -> capability "variant_comparison1";
    if Option.is_some q.left_workload || Option.is_some q.right_workload then capability "workload_comparison1"
;;
let provider_identity ~executable query =
  let executable = Filename_unix.realpath executable in
  let helper = match query with W.Query.Inspect _ -> "workload-inspect" | Compare _ -> "compare" in
  let companion = Filename.concat (Filename.dirname executable)
    (if String.equal (Filename.basename executable) "flow_cli.exe"
     then "experimental_" ^ String.tr helper ~target:'-' ~replacement:'_' ^ ".exe"
     else "hardcaml-asic-experimental-" ^ helper) in
  let hash file =
    let fd = Core_unix.openfile file ~mode:[O_RDONLY;O_NONBLOCK;O_CLOEXEC] in
    Exn.protect ~finally:(fun () -> Core_unix.close fd) ~f:(fun () ->
      let before = Core_unix.fstat fd in
      require (Poly.equal before.st_kind S_REG && Int64.(before.st_size <= of_int 134217728)) "Workload provider binary budget/type";
      let h = Cryptokit.Hash.sha256 () and b = Bytes.create 65536 and total = ref 0 in
      let rec loop () =
        let n = Core_unix.read fd ~buf:b ~pos:0 ~len:(Bytes.length b) in
        if n>0 then (total := !total+n; require (!total<=128*mib) "Provider grew beyond budget";
          h#add_substring b 0 n; loop ()) in
      loop ();
      let after = Core_unix.fstat fd in
      require (Int.equal before.st_ino after.st_ino && Int.equal before.st_dev after.st_dev
        && Int64.equal before.st_size after.st_size && Poly.equal before.st_mtime after.st_mtime
        && Poly.equal before.st_ctime after.st_ctime) "Workload provider binary changed while hashing";
      Cryptokit.transform_string (Cryptokit.Hexa.encode ()) h#result) in
  P.digest (executable ^ "\000" ^ hash executable ^ "\000" ^ Filename_unix.realpath companion ^ "\000" ^ hash companion)
;;
let check_separation ~state_dir query =
  separate (Storage.physical state_dir)
    (List.map (evidence_roots query (query_paths query)) ~f:Storage.physical)
;;
