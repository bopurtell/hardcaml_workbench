open! Core
open Hardcaml_workbench_protocol
module E = Evidence_style
module W = Asic_workloads

(** Presentation only: JSON is already verified by the public provider. Raw numeric tokens
    are never converted to floats, and eligibility/deltas are never computed. *)
module Json = struct
  let parse text = Or_error.try_with (fun () -> Yojson.Raw.from_string text)

  let field j key =
    match j with
    | `Assoc xs ->
      List.Assoc.find xs key ~equal:String.equal |> Option.value ~default:`Null
    | _ -> `Null
  ;;

  let list = function
    | `List xs -> xs
    | _ -> []
  ;;

  let text = function
    | `Stringlit s ->
      (match Yojson.Safe.from_string s with
       | `String s -> s
       | _ -> s)
    | `Null -> "unavailable"
    | j -> Yojson.Raw.to_string j
  ;;

  let get j key = text (field j key)

  let fields = function
    | `Assoc xs -> xs
    | _ -> []
  ;;

  let facts prefix j =
    List.map (fields j) ~f:(fun (k, v) -> E.plain (prefix ^ k ^ ": " ^ text v))
  ;;
end

type mode =
  | Results
  | Detail
  | Provenance
  | Compare
[@@deriving equal]

type capture =
  { result : string
  ; source_digest : string
  ; bundle : string
  ; provider : string
  }
[@@deriving equal, sexp]

type t =
  { selected : string option
  ; mode : mode
  ; left : capture option
  ; right : capture option
  ; axis : string
  ; generation : int
  ; pending : string option
  ; request_floor : int option
  ; receipt_floor : int option
  ; error : string option
  ; scroll : int
  ; query : W.Query.t option
  ; descriptor : W.Descriptor.t option
  ; document : Yojson.Raw.t option
  ; inspections : W.Query.t list
  ; target_digests : (string * string) option
  }

let empty =
  { selected = None
  ; mode = Results
  ; left = None
  ; right = None
  ; axis = "resource_policy"
  ; generation = 0
  ; pending = None
  ; request_floor = None
  ; receipt_floor = None
  ; error = None
  ; scroll = 0
  ; query = None
  ; descriptor = None
  ; document = None
  ; inspections = []
  ; target_digests = None
  }
;;

let axes = [ "hardware"; "resource_policy"; "flow_configuration"; "descriptive" ]

let invalidate t =
  { t with
    generation = t.generation + 1
  ; pending = None
  ; request_floor = None
  ; receipt_floor = None
  ; error = None
  ; scroll = 0
  }
;;

let select t result = { (invalidate t) with selected = Some result; mode = Detail }

let reconnect t =
  { (invalidate t) with
    descriptor =
      Option.map t.descriptor ~f:(fun d ->
        { d with freshness = W.Freshness.Cached_unverified })
  }
;;

let set_axis t axis =
  if List.mem axes axis ~equal:String.equal
  then
    { (invalidate t) with
      axis
    ; mode = Compare
    ; target_digests = (if String.equal axis t.axis then t.target_digests else None)
    }
  else { t with error = Some "Unsupported comparison axis" }
;;

let swap t =
  { (invalidate t) with
    left = t.right
  ; right = t.left
  ; mode = Compare
  ; document = None
  ; descriptor = None
  ; target_digests = Option.map t.target_digests ~f:(fun (a, b) -> b, a)
  }
;;

let result_rows j =
  let outcome = Json.field j "outcome" in
  [ E.plain
      ("Outcome / status: "
       ^ Json.get outcome "status"
       ^ " · functional: "
       ^ Json.get outcome "functional"
       ^ " · performance: "
       ^ Json.get outcome "performance")
  ; E.plain "Functional simulation — cycle evidence, not measured physical speed"
  ]
  @ List.concat_map
      (Json.list (Json.field j "metrics"))
      ~f:(fun m ->
        [ E.plain (Json.get m "name" ^ ": " ^ Json.get m "value" ^ " " ^ Json.get m "unit")
        ]
        @ List.filter_map [ "numerator"; "denominator"; "reason" ] ~f:(fun k ->
          match Json.field m k with
          | `Null -> None
          | v -> Some (E.plain ("  " ^ k ^ "=" ^ Json.text v))))
;;

let comparison_rows j =
  let value metric =
    let value = Json.get metric "value" in
    match Json.field metric "numerator", Json.field metric "denominator" with
    | `Null, _ | _, `Null -> value
    | numerator, denominator ->
      value ^ " (" ^ Json.text numerator ^ "/" ^ Json.text denominator ^ ")"
  in
  [ E.plain "Provider eligibility and right-minus-left deltas; no overall winner" ]
  @ List.concat_map
      [ "A", "left"; "B", "right" ]
      ~f:(fun (label, side) ->
        let side = Json.field j side in
        let outcome = Json.field (Json.field side "workload") "outcome" in
        [ E.plain
            (label
             ^ " status: "
             ^ Json.get outcome "status"
             ^ " · functional: "
             ^ Json.get outcome "functional"
             ^ " · performance: "
             ^ Json.get outcome "performance")
        ])
  @ List.concat_map
      (Json.list (Json.field j "metrics"))
      ~f:(fun m ->
        [ E.plain
            (Json.get m "metric_id"
             ^ ": A="
             ^ value (Json.field m "left")
             ^ " B="
             ^ value (Json.field m "right")
             ^ " delta(B-A)="
             ^ Json.get m "right_minus_left"
             ^ " · "
             ^ Json.get m "comparison")
        ]
        @ List.filter_map [ "right_minus_left_ratio"; "reasons" ] ~f:(fun k ->
          match Json.field m k with
          | `Null | `List [] -> None
          | v -> Some (E.plain ("  " ^ k ^ ": " ^ Json.text v))))
;;

let qualifications =
  [ E.plain
      "Physical limits: no matched workload Flops/Exact physical area or speed study."
  ; E.plain
      "Host runtime / functional clock / implementation constraint are not measured Fmax."
  ; E.plain "Firmware size and fetch counts are unsupported for this memory workload."
  ]
;;

let reference text =
  Or_error.try_with (fun () ->
    if String.length text > 16384 then failwith "Result reference exceeds 16KiB";
    let j = Yojson.Safe.from_string text in
    let fields =
      match j with
      | `Assoc xs -> xs
      | _ -> failwith "Result reference object required"
    in
    let names = List.map fields ~f:fst |> List.sort ~compare:String.compare in
    if not
         (List.equal
            String.equal
            names
            [ "contract"; "result"; "schema_version"; "source_digest" ])
    then failwith "Invalid result reference fields";
    let field k = List.Assoc.find_exn fields k ~equal:String.equal in
    let string k =
      match field k with
      | `String s -> s
      | _ -> failwith ("Invalid reference " ^ k)
    in
    if (not (String.equal (string "contract") "hardcaml-workbench.pt8-result-reference"))
       || not (Poly.equal (field "schema_version") (`Int 1))
    then failwith "Unsupported result reference schema";
    let result = string "result"
    and digest = string "source_digest" in
    if Filename.is_relative result
       || String.is_empty result
       || String.exists result ~f:(fun c -> Char.to_int c < 32)
    then failwith "Result reference requires an absolute retained path";
    if String.length digest <> 64
       || not
            (String.for_all digest ~f:(function
              | '0' .. '9' | 'a' .. 'f' -> true
              | _ -> false))
    then failwith "Invalid result reference digest";
    result, digest)
;;

let snapshot asic =
  Option.bind asic ~f:(fun s -> s.Asic.Snapshot.workloads)
  |> Option.value ~default:W.Snapshot.empty
;;

let operation query ~refresh = W.Operation.Load { query; refresh }
let key query = W.Operation.key (operation query ~refresh:false)

let results snapshot =
  List.filter_map snapshot.W.Snapshot.entries ~f:(fun d ->
    match d.W.Descriptor.query with
    | Inspect { result; _ } -> Some (result, d)
    | Compare _ -> None)
  |> List.sort ~compare:(fun (a, da) (b, db) ->
    let c = String.compare a b in
    if c <> 0
    then c
    else (
      let pinned (d : W.Descriptor.t) =
        match d.query with
        | Inspect { expected_digest = Some _; _ } -> 0
        | _ -> 1
      in
      let c = Int.compare (pinned da) (pinned db) in
      if c <> 0 then c else String.compare da.key db.key))
  |> List.group ~break:(fun (a, _) (b, _) -> not (String.equal a b))
  |> List.map ~f:List.hd_exn
;;

let inspection_query t result snapshot =
  let matching = function
    | W.Query.Inspect q -> String.equal q.result result
    | Compare _ -> false
  in
  Option.first_some
    (Option.filter t.query ~f:matching)
    (Option.first_some
       (List.find t.inspections ~f:matching)
       (List.Assoc.find (results snapshot) result ~equal:String.equal
        |> Option.map ~f:(fun d -> d.W.Descriptor.query)))
;;

let freshness = function
  | W.Freshness.Validated -> "Validated", E.Role.Validated
  | Cached_unverified -> "CACHED UNVERIFIED", Pending
  | Refresh_failed reason -> "Refresh failed: " ^ reason, Stale
;;

let diagnostic text =
  let rec failure = function
    | Sexp.List [ Atom "Failure"; Atom message ] -> Some message
    | List xs -> List.find_map xs ~f:failure
    | Atom _ -> None
  in
  Option.first_some
    (Result.ok (Or_error.try_with (fun () -> failure (Sexp.of_string text)))
     |> Option.join)
    (List.hd (String.split_lines text))
  |> Option.value ~default:text
;;

let begin_query t query ~refresh =
  let inspections =
    match query with
    | W.Query.Inspect q ->
      query
      :: List.filter t.inspections ~f:(function
        | Inspect old -> not (String.equal old.result q.result)
        | Compare _ -> false)
      |> Fn.flip List.take 32
    | Compare _ -> t.inspections
  in
  let same = Option.equal W.Query.equal t.query (Some query) in
  let op = operation query ~refresh in
  ( { (invalidate t) with
      query = Some query
    ; inspections
    ; pending = Some (W.Operation.key op)
    ; descriptor = (if same then t.descriptor else None)
    ; document = (if same then t.document else None)
    }
  , op )
;;

let admit t ~generation ~request_floor =
  if generation = t.generation && Option.is_some t.pending
  then { t with request_floor = Some request_floor; receipt_floor = None }
  else t
;;

let receipt t ~generation ~floor = function
  | _ when generation <> t.generation -> t
  | Error error -> { t with pending = None; error = Some error }
  | Ok () -> { t with receipt_floor = Some floor }
;;

let reconcile ?revision t asic =
  let snapshot = snapshot asic in
  let descriptor =
    Option.bind t.query ~f:(fun q ->
      List.find snapshot.entries ~f:(fun d -> String.equal d.key (key q)))
  in
  let t =
    match descriptor with
    | None ->
      { t with
        descriptor =
          Option.map t.descriptor ~f:(fun d -> { d with freshness = Cached_unverified })
      }
    | Some d ->
      let changed =
        match t.descriptor with
        | Some old ->
          not
            (Option.equal String.equal old.digest d.digest
             && Option.equal String.equal old.provider_identity d.provider_identity)
        | None -> true
      in
      let document =
        if (not changed) && Option.is_some t.document
        then t.document
        else
          Option.bind snapshot.selected ~f:(fun response ->
            if String.equal response.key d.key
               && Option.equal String.equal d.digest (Some response.digest)
               &&
               match d.query with
               | Inspect { expected_digest = Some expected; _ } ->
                 String.equal response.digest expected
               | _ -> true
            then Result.ok (Json.parse response.json)
            else None)
      in
      { t with descriptor = Some d; document }
  in
  let t =
    match t.query, t.descriptor, t.document with
    | Some (Compare _), Some d, Some j when W.Freshness.equal d.freshness Validated ->
      let digest side =
        match Json.field (Json.field j side) "source_digest" with
        | `Stringlit _ as v ->
          let s = Json.text v in
          if String.length s = 64
             && String.for_all s ~f:(function
               | '0' .. '9' | 'a' .. 'f' -> true
               | _ -> false)
          then Some s
          else None
        | _ -> None
      in
      (match digest "left", digest "right" with
       | Some a, Some b -> { t with target_digests = Some (a, b) }
       | _ -> t)
    | _ -> t
  in
  match t.pending, t.receipt_floor, t.request_floor, revision, asic with
  | Some pending, Some receipt, Some issued, Some revision, Some asic
    when revision >= receipt && revision >= issued ->
    (match
       List.find asic.Asic.Snapshot.operations ~f:(fun op -> String.equal op.key pending)
     with
     | Some op when String.equal op.state "failed" || Option.is_some op.error ->
       { t with
         pending = None
       ; error = Some (Option.value op.error ~default:"Workload read failed")
       }
     | Some op when String.equal op.state "completed" ->
       { t with pending = None; error = None }
     | _ -> t)
  | _ -> t
;;

let inspect t result expected_digest ~refresh =
  if Filename.is_relative result
     || String.is_empty result
     || String.length result > 4096
     || String.exists result ~f:(fun c -> Char.to_int c < 32)
  then
    ( { t with error = Some "Import requires an exact absolute retained result.json path" }
    , None )
  else (
    let t, op =
      begin_query (select t result) (Inspect { result; expected_digest }) ~refresh
    in
    t, Some op)
;;

let bundle_locator j =
  match Json.field (Json.field j "binding") "bundle" with
  | `Stringlit _ as v ->
    let path = Json.text v in
    Option.some_if
      (Filename.is_absolute path
       && String.length path <= 4096
       && not (String.exists path ~f:(fun c -> Char.to_int c < 32)))
      path
  | _ -> None
;;

let capture_ready t =
  match t.mode, t.query, t.selected, t.descriptor, t.document with
  | Detail, Some (Inspect q as query), Some selected, Some d, Some _ ->
    String.equal selected q.result
    && W.Query.equal d.query query
    && String.equal d.key (key query)
    && W.Freshness.equal d.freshness Validated
    && Option.is_some d.digest
    && Option.is_some d.provider_identity
  | _ -> false
;;

let capture t ~left ~bundle =
  match t.query, t.descriptor, t.document with
  | Some (Inspect { result; _ } as query), Some d, Some j
    when capture_ready t
         && Option.equal String.equal t.selected (Some result)
         && W.Query.equal query d.query
         && String.equal d.key (key query) ->
    if Option.exists (bundle_locator j) ~f:(fun verified ->
         not (String.equal verified bundle))
    then
      { t with error = Some "Bundle path differs from the verified inspection binding" }
    else (
      match d.digest, d.provider_identity, d.freshness with
      | Some source_digest, Some provider, W.Freshness.Validated
        when (not (Filename.is_relative bundle)) && not (String.is_empty bundle) ->
        let c = Some { result; source_digest; bundle; provider } in
        { (invalidate t) with
          left = (if left then c else t.left)
        ; right = (if left then t.right else c)
        ; target_digests = None
        }
      | _ ->
        { t with
          error =
            Some
              "Refresh a validated source and supply its exact absolute bundle path \
               before capture"
        })
  | _ ->
    { t with error = Some "Load a result detail before capture (Esc returns to list)" }
;;

let verified_bundle t =
  if capture_ready t then Option.bind t.document ~f:bundle_locator else None
;;

let axis = function
  | "hardware" -> W.Axis.Hardware
  | "flow_configuration" -> Flow_configuration
  | "descriptive" -> Descriptive
  | _ -> Resource_policy
;;

let compare t ~refresh =
  match t.left, t.right with
  | Some a, Some b when String.equal a.provider b.provider ->
    let query =
      W.Query.Compare
        { left = Bundle a.bundle
        ; right = Bundle b.bundle
        ; axis = axis t.axis
        ; left_workload = Some a.result
        ; right_workload = Some b.result
        ; expected_left_digest = Option.map t.target_digests ~f:fst
        ; expected_right_digest = Option.map t.target_digests ~f:snd
        ; expected_left_workload_digest = Some a.source_digest
        ; expected_right_workload_digest = Some b.source_digest
        }
    in
    let t, op = begin_query { t with mode = Compare } query ~refresh in
    t, Some op
  | _ ->
    ( { t with
        mode = Compare
      ; error = Some "Capture A and B from the same provider before comparison"
      ; document = None
      ; descriptor = None
      ; query = None
      }
    , None )
;;

type capture_token = int * string option * string option

let capture_token (t : t) =
  ( t.generation
  , Option.bind t.descriptor ~f:(fun d -> d.digest)
  , Option.bind t.descriptor ~f:(fun d -> d.provider_identity) )
;;

type input =
  | Open
  | Back
  | Move of int
  | Refresh
  | Show_results
  | Show_provenance
  | Show_compare
  | Swap
  | Axis of string
  | Capture of bool * string * capture_token
  | Scroll of int

let input t ~asic ~filter event =
  let candidates =
    results (snapshot asic)
    |> List.filter ~f:(fun (path, _) ->
      String.is_substring (String.lowercase path) ~substring:(String.lowercase filter))
  in
  match event with
  | Show_compare -> compare t ~refresh:false
  | Swap -> compare (swap t) ~refresh:false
  | Axis axis ->
    let t = set_axis t axis in
    if Option.is_some t.left && Option.is_some t.right
    then compare t ~refresh:false
    else { t with document = None; descriptor = None; query = None }, None
  | Capture (left, bundle, token) ->
    ( (if Poly.equal token (capture_token t)
       then capture t ~left ~bundle
       else
         { t with
           error = Some "Result changed while entering bundle; reopen capture command"
         })
    , None )
  | Refresh ->
    (match t.mode, t.query with
     | Compare, _ | _, Some (Compare _) -> compare t ~refresh:true
     | _, Some q ->
       let t, op = begin_query t q ~refresh:true in
       t, Some op
     | _ -> { t with error = Some "Select/import a result first" }, None)
  | Back | Show_results -> { (invalidate t) with mode = Results }, None
  | Show_provenance -> { t with mode = Provenance; scroll = 0 }, None
  | Scroll delta -> { t with scroll = Int.max 0 (t.scroll + delta) }, None
  | Open ->
    (match Option.first_some t.selected (Option.map (List.hd candidates) ~f:fst) with
     | None -> t, None
     | Some result ->
       let query = inspection_query t result (snapshot asic) in
       let expected_digest =
         match query with
         | Some (Inspect q) -> q.expected_digest
         | _ -> None
       in
       inspect t result expected_digest ~refresh:false)
  | Move delta when equal_mode t.mode Results ->
    let index =
      Option.bind t.selected ~f:(fun id ->
        List.findi candidates ~f:(fun _ (path, _) -> String.equal id path)
        |> Option.map ~f:fst)
      |> Option.value ~default:(if delta > 0 then -1 else 1)
    in
    let selected =
      List.nth
        candidates
        (Int.max 0 (Int.min (List.length candidates - 1) (index + delta)))
      |> Option.map ~f:fst
    in
    let changed = not (Option.equal String.equal selected t.selected) in
    ( { (invalidate t) with
        selected
      ; query = (if changed then None else t.query)
      ; descriptor = (if changed then None else t.descriptor)
      ; document = (if changed then None else t.document)
      }
    , None )
  | Move delta -> { t with scroll = Int.max 0 (t.scroll + delta) }, None
;;

let capture_rows name = function
  | None -> [ E.plain (name ^ ": not captured") ]
  | Some c ->
    [ E.plain (name ^ ": " ^ c.result)
    ; E.plain (name ^ " source_digest: " ^ c.source_digest)
    ; E.plain (name ^ " bundle: " ^ c.bundle)
    ; E.plain (name ^ " reader: " ^ c.provider)
    ]
;;

let rows t ~asic ~filter ~width ~height =
  let header =
    [ E.plain "Workloads · project evidence (independent of Main)"
    ; E.plain
        "j/k browse · Enter detail · Esc list · / filter · r refresh · d provenance · c \
         compare · Space c c commands"
    ]
    @ Option.to_list
        (Option.map t.pending ~f:(fun _ ->
           E.plain "Read requested — retained evidence only"))
    @ Option.to_list
        (Option.map t.error ~f:(fun s ->
           [ { E.text = "Read error: " ^ diagnostic s; role = E.Role.Stale } ]))
    @ Option.to_list
        (Option.map (snapshot asic).cache_error ~f:(fun s ->
           [ { E.text = "Cache error: " ^ diagnostic s; role = E.Role.Stale } ]))
  in
  let status =
    Option.value_map t.descriptor ~default:[] ~f:(fun d ->
      let text, role = freshness d.freshness in
      [ [ { E.text = diagnostic text; role } ] ]
      @ Option.to_list
          (Option.map d.error ~f:(fun s -> E.plain ("Source error: " ^ diagnostic s))))
  in
  let contents =
    match t.mode with
    | Results ->
      let entries =
        results (snapshot asic)
        |> List.filter ~f:(fun (path, _) ->
          String.is_substring (String.lowercase path) ~substring:(String.lowercase filter))
      in
      let index =
        Option.bind t.selected ~f:(fun path ->
          List.findi entries ~f:(fun _ (p, _) -> String.equal path p) |> Option.map ~f:fst)
        |> Option.value ~default:0
      in
      let entries =
        List.drop entries (Int.max 0 (index - Int.max 1 (height / 4) + 1))
        |> Fn.flip List.take (Int.max 1 (height / 4))
      in
      [ E.plain
          ("Retained results · filter: "
           ^ filter
           ^ " · palette: Import exact absolute result.json")
      ]
      @ List.map entries ~f:(fun (path, d) ->
        E.plain
          ((if Option.equal String.equal t.selected (Some path) then "> " else "  ")
           ^ path
           ^ " · "
           ^ fst (freshness d.freshness)))
      @
      if List.is_empty entries
      then
        [ E.plain
            "No matching retained results. Import a result, or launch PT.8 in Testing."
        ]
      else []
    | Detail ->
      status
      @ Option.to_list
          (Option.map t.selected ~f:(fun s ->
             E.plain
               ("Result: "
                ^ Filename.basename (Filename.dirname s)
                ^ "/"
                ^ Filename.basename s)))
      @ Option.value_map
          t.document
          ~default:[ E.plain "No matching document loaded — Enter or r" ]
          ~f:result_rows
      @ qualifications
    | Provenance ->
      status
      @ Option.to_list
          (Option.map t.selected ~f:(fun s -> E.plain ("Selected result: " ^ s)))
      @ capture_rows "A" t.left
      @ capture_rows "B" t.right
      @ Option.value_map t.descriptor ~default:[] ~f:(fun d ->
        [ E.plain ("Digest: " ^ Option.value d.digest ~default:"unavailable")
        ; E.plain ("Reader: " ^ Option.value d.provider_identity ~default:"unavailable")
        ])
      @ Option.to_list
          (Option.map t.error ~f:(fun s -> E.plain ("Full read diagnostic: " ^ s)))
      @ Option.to_list
          (Option.bind t.descriptor ~f:(fun d ->
             Option.map d.error ~f:(fun s -> E.plain ("Full source diagnostic: " ^ s))))
      @ Option.value_map
          t.document
          ~default:[ E.plain "No source document loaded" ]
          ~f:(fun j ->
            Json.facts "Controls / " (Json.field j "controls")
            @ Json.facts "Outcome / " (Json.field j "outcome")
            @ Json.facts "Binding / " (Json.field j "binding")
            @ List.concat_map
                (Json.list (Json.field j "metrics"))
                ~f:(Json.facts "Metric / ")
            @ List.concat_map
                (Json.list (Json.field j "differences"))
                ~f:(Json.facts "Difference / ")
            @ Json.facts "Provenance / " (Json.field j "provenance")
            @ Json.facts "Left / " (Json.field j "left")
            @ Json.facts "Right / " (Json.field j "right"))
    | Compare ->
      List.map
        [ "A", t.left; "B", t.right ]
        ~f:(fun (name, c) ->
          E.plain
            (name
             ^ ": "
             ^ Option.value_map c ~default:"not captured" ~f:(fun c ->
               Filename.basename (Filename.dirname c.result)
               ^ "/"
               ^ Filename.basename c.result)))
      @ [ E.plain ("Axis: " ^ t.axis) ]
      @ status
      @ Option.value_map
          t.document
          ~default:
            [ E.plain "No comparison loaded — capture both sides and choose Compare" ]
          ~f:comparison_rows
      @ qualifications
  in
  E.page
    ~width
    ~height
    ~offset:(if equal_mode t.mode Results then 0 else t.scroll)
    (header @ contents)
;;

type saved =
  { selected : string option
  ; left : capture option
  ; right : capture option
  ; axis : string
  ; query : W.Query.t option
  ; inspections : W.Query.t list [@sexp.default []] [@sexp_drop_default.equal]
  ; target_digests : (string * string) option [@sexp.option]
  }
[@@deriving sexp, equal]

let remember (t : t) : saved =
  { selected = t.selected
  ; left = t.left
  ; right = t.right
  ; axis = t.axis
  ; query = t.query
  ; inspections = t.inspections
  ; target_digests = t.target_digests
  }
;;

let restore (s : saved) =
  let path s =
    (not (Filename.is_relative s))
    && String.length s <= 4096
    && not (String.exists s ~f:(fun c -> Char.to_int c < 32))
  in
  let captured c =
    path c.result
    && path c.bundle
    && String.length c.source_digest = 64
    && String.length c.provider <= 4096
  in
  let digest s =
    String.length s = 64
    && String.for_all s ~f:(function
      | '0' .. '9' | 'a' .. 'f' -> true
      | _ -> false)
  in
  if List.length s.inspections > 32
     || List.exists s.inspections ~f:(function
       | Inspect q ->
         (not (path q.result))
         || Option.exists q.expected_digest ~f:(fun d -> not (digest d))
       | Compare _ -> true)
     || Option.exists s.target_digests ~f:(fun (a, b) -> not (digest a && digest b))
  then failwith "Invalid saved workload generation expectations";
  if (not (List.mem axes s.axis ~equal:String.equal))
     || Option.exists s.selected ~f:(fun s -> not (path s))
     || List.exists (List.filter_opt [ s.left; s.right ]) ~f:(fun c -> not (captured c))
  then failwith "Invalid saved workload selection";
  { empty with
    selected = s.selected
  ; left = s.left
  ; right = s.right
  ; axis = s.axis
  ; query = s.query
  ; inspections = s.inspections
  ; target_digests = s.target_digests
  ; mode =
      (match s.query with
       | Some (Compare _) -> Compare
       | Some (Inspect _) -> Detail
       | None -> Results)
  }
;;
