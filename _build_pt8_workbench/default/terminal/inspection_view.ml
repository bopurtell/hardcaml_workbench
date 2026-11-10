open! Core
open Hardcaml_workbench_protocol

(** Pure tile-local explorer. Reconciliation never produces a provider operation. *)
type sort =
  | Numeric_ascending
  | Numeric_descending
  | Name
[@@deriving equal]

type axis =
  | Corner
  | Group
  | Producer

type cache =
  { source : Asic_inspection.Index.t
  ; projection : (Asic_inspection.Row.t * string) list
  ; rows : Asic_inspection.Row.t list
  ; filter : string
  ; sort : sort
  ; corner : string option
  ; group : string option
  ; producer : string option
  ; near : bool
  }

type detail_cache =
  { index : Asic_inspection.Index.t option
  ; row : Asic_inspection.Row.t option
  ; selected : string option
  ; requested : (string * string) option
  ; detail : Asic_inspection.Detail.t option
  ; width : int
  ; info : bool
  ; age_bucket : int option
  (** Ages in [lines] are rebuilt when this minute bucket changes (WB-006). *)
  ; lines : string array
  }

(* The public run can advance without changing execution bytes or index rows. *)
type observation = Asic.Reference.t * int * string option [@@deriving equal]

type t =
  { run : Run_ref.t
  ; scope : Run_ref.t option
  ; workspace_epoch : string option
  ; domain : string
  ; stage : string
  ; analysis : Asic_inspection.Analysis_target.t option
  ; index : Asic_inspection.Index.t option
  ; observation : observation option
  ; selected : string option
  ; filter : string
  ; editing : bool
  ; pasting : bool
  ; filter_notice : string option
  ; sort : sort
  ; corner : string option
  ; group : string option
  ; producer : string option
  ; near : bool
  ; requested : (string * string) option
  ; detail : Asic_inspection.Detail.t option
  ; info : bool
  ; scroll : int
  ; generation : int
  ; error : string option
  ; pending_error : string option
  ; index_loading : bool
  ; operation_key : string option
  ; cache : cache option
  ; detail_cache : detail_cache option
  }

let defaults = [ "clocks", "signoff"; "physical", "placement"; "routing", "routing" ]

let stages =
  [ "synthesis"; "floorplan"; "placement"; "cts"; "routing"; "timing"; "signoff" ]
;;

let create ?analysis ?scope ?(generation = 0) ~run ~domain ~stage () =
  { run
  ; scope
  ; workspace_epoch = None
  ; domain
  ; stage
  ; analysis
  ; index = None
  ; observation = None
  ; selected = None
  ; filter = ""
  ; editing = false
  ; pasting = false
  ; filter_notice = None
  ; sort = Numeric_ascending
  ; corner = None
  ; group = None
  ; producer = None
  ; near = false
  ; requested = None
  ; detail = None
  ; info = false
  ; scroll = 0
  ; generation
  ; error = None
  ; pending_error = None
  ; index_loading = false
  ; operation_key =
      Some
        (match analysis with
         | Some target -> Asic_inspection.analysis_index_key ~run ~target
         | None -> Asic_inspection.index_key ~run ~domain ~stage)
  ; cache = None
  ; detail_cache = None
  }
;;

let reconcile_scope t ~scope =
  if Option.equal Run_ref.equal t.scope scope then Some t else None
;;

let index_key t =
  match t.analysis with
  | Some target -> Asic_inspection.analysis_index_key ~run:t.run ~target
  | None -> Asic_inspection.index_key ~run:t.run ~domain:t.domain ~stage:t.stage
;;

let detail_key t ~source_digest ~row_id =
  match t.analysis with
  | Some target ->
    Asic_inspection.analysis_detail_key ~run:t.run ~target ~source_digest ~row_id
  | None ->
    Asic_inspection.detail_key
      ~run:t.run
      ~domain:t.domain
      ~stage:t.stage
      ~source_digest
      ~row_id
;;

let detail_operation t ~source_digest ~row_id =
  match t.analysis with
  | Some target ->
    Asic.Operation.Inspect_analysis_detail { run = t.run; target; source_digest; row_id }
  | None ->
    Asic.Operation.Inspect_detail
      { run = t.run; domain = t.domain; stage = t.stage; source_digest; row_id }
;;

let matches_index t (index : Asic_inspection.Index.t) =
  Run_ref.equal index.run t.run
  && String.equal index.domain t.domain
  && String.equal index.stage t.stage
  && Option.value_map t.analysis ~default:true ~f:(fun target ->
    Option.equal Asic_inspection.Analysis_target.equal index.analysis (Some target))
;;

let operation ?(refresh = false) t =
  match t.analysis with
  | Some target -> Asic.Operation.Inspect_analysis { run = t.run; target; refresh }
  | None ->
    Asic.Operation.Inspect { run = t.run; domain = t.domain; stage = t.stage; refresh }
;;

type ticket =
  { generation : int
  ; workspace_epoch : string option
  ; operation : Asic.Operation.t
  }

let capture (t : t) operation =
  { generation = t.generation; workspace_epoch = t.workspace_epoch; operation }
;;

let apply_response (t : t) (ticket : ticket) response =
  if t.generation <> ticket.generation
     || not (Option.equal String.equal t.workspace_epoch ticket.workspace_epoch)
  then t
  else (
    let matches =
      match ticket.operation with
      | Inspect_analysis { run; target; _ } ->
        Run_ref.equal run t.run
        && Option.equal Asic_inspection.Analysis_target.equal (Some target) t.analysis
      | Inspect_analysis_detail { run; target; source_digest; row_id } ->
        Run_ref.equal run t.run
        && Option.equal Asic_inspection.Analysis_target.equal (Some target) t.analysis
        && Option.equal
             [%equal: string * string]
             t.requested
             (Some (source_digest, row_id))
      | Inspect { run; domain; stage; _ } ->
        Option.is_none t.analysis
        && Run_ref.equal run t.run
        && String.equal domain t.domain
        && String.equal stage t.stage
      | Inspect_detail { run; domain; stage; source_digest; row_id } ->
        Option.is_none t.analysis
        && Run_ref.equal run t.run
        && String.equal domain t.domain
        && String.equal stage t.stage
        && Option.equal
             (fun (a, b) (c, d) -> String.equal a c && String.equal b d)
             t.requested
             (Some (source_digest, row_id))
      | _ -> false
    in
    if not matches
    then t
    else (
      match response with
      | Ok () -> t
      | Error error -> { t with error = Some error }))
;;

let row_text (r : Asic_inspection.Row.t) =
  String.concat
    ~sep:" "
    ([ r.id; r.category; r.name; r.producer; r.status; r.source ]
     @ Option.to_list r.corner
     @ Option.to_list r.group
     @ List.concat_map r.fields ~f:(fun (key, value) -> [ key; value ]))
;;

let project_rows (t : t) projection =
  let filter = String.lowercase t.filter in
  projection
  |> List.filter_map ~f:(fun ((r : Asic_inspection.Row.t), text) ->
    let matches choice value =
      Option.value_map choice ~default:true ~f:(fun c ->
        Option.equal String.equal (Some c) value)
    in
    if String.is_substring text ~substring:filter
       && matches t.corner r.corner
       && matches t.group r.group
       && matches t.producer (Some r.producer)
       && ((not t.near)
           || (not (String.equal t.domain "timing"))
           || String.equal (String.lowercase r.status) "violated"
           || Option.value_map r.value ~default:false ~f:(fun value ->
             match r.unit_ with
             | Some "ns" -> Float.(value <= 1.)
             | Some "ps" -> Float.(value <= 1000.)
             | Some "s" -> Float.(value <= 1e-9)
             | _ -> false))
    then Some r
    else None)
  |> List.sort ~compare:(fun a b ->
    let numeric a b =
      match a.Asic_inspection.Row.value, b.Asic_inspection.Row.value with
      | Some a, Some b -> Float.compare a b
      | Some _, None -> -1
      | None, Some _ -> 1
      | None, None -> 0
    in
    let order =
      match t.sort with
      | Name -> String.compare a.name b.name
      | Numeric_ascending -> numeric a b
      | Numeric_descending -> numeric b a
    in
    if order <> 0 then order else String.compare a.id b.id)
;;

let same_source (a : Asic_inspection.Index.t) (b : Asic_inspection.Index.t) =
  (* Polling reconstructs typed records. Digest alone is not sufficient: cached rows can
     be updated under the same digest. Rebase the memo onto each equal new source so
     subsequent input/repaint uses the physical-identity fast path. *)
  phys_equal a b
  || (Run_ref.equal a.run b.run
      && String.equal a.domain b.domain
      && String.equal a.stage b.stage
      && String.equal a.source_digest b.source_digest
      && Option.equal Asic_inspection.Analysis_target.equal a.analysis b.analysis
      && String.equal a.execution_file b.execution_file
      && String.equal a.execution_sha256 b.execution_sha256
      && (phys_equal a.rows b.rows || List.equal Asic_inspection.Row.equal a.rows b.rows)
     )
;;

let same_query (t : t) (cache : cache) =
  String.equal t.filter cache.filter
  && equal_sort t.sort cache.sort
  && Option.equal String.equal t.corner cache.corner
  && Option.equal String.equal t.group cache.group
  && Option.equal String.equal t.producer cache.producer
  && Bool.equal t.near cache.near
;;

let memoize (t : t) =
  match t.index with
  | None -> if Option.is_none t.cache then t else { t with cache = None }
  | Some source ->
    (match t.cache with
     | Some cache when phys_equal source cache.source && same_query t cache -> t
     | previous ->
       let reusable =
         Option.filter previous ~f:(fun cache -> same_source source cache.source)
       in
       let projection =
         match reusable with
         | Some cache -> cache.projection
         | None ->
           List.map source.rows ~f:(fun row -> row, String.lowercase (row_text row))
       in
       let rows =
         match reusable with
         | Some cache when same_query t cache -> cache.rows
         | _ -> project_rows t projection
       in
       { t with
         cache =
           Some
             { source
             ; projection
             ; rows
             ; filter = t.filter
             ; sort = t.sort
             ; corner = t.corner
             ; group = t.group
             ; producer = t.producer
             ; near = t.near
             }
       })
;;

let visible (t : t) =
  Option.value_map (memoize t).cache ~default:[] ~f:(fun cache -> cache.rows)
;;

let normalize (t : t) =
  let t = memoize t in
  let rows = visible t in
  if List.exists rows ~f:(fun r ->
       Option.equal String.equal (Some r.Asic_inspection.Row.id) t.selected)
  then t
  else
    { t with
      selected = Option.map (List.hd rows) ~f:(fun r -> r.Asic_inspection.Row.id)
    ; requested = None
    ; detail = None
    ; scroll = 0
    }
;;

let reconcile t (snapshot : Asic.Snapshot.t) =
  let observation =
    List.find snapshot.runs ~f:(fun run -> Run_ref.equal run.Asic.Run.run t.run)
    |> Option.map ~f:(fun run -> run.reference, run.cursor, run.execution_file)
  in
  let index = List.find snapshot.inspections ~f:(matches_index t) in
  let digest index =
    Option.map index ~f:(fun i -> i.Asic_inspection.Index.source_digest)
  in
  let selected_row index =
    Option.bind index ~f:(fun i ->
      List.find i.Asic_inspection.Index.rows ~f:(fun row ->
        Option.equal String.equal t.selected (Some row.id)))
  in
  let changed =
    (not (Option.equal equal_observation t.observation observation))
    || (not (Option.equal String.equal (digest t.index) (digest index)))
    || (not
          (Option.equal
             (fun (a : Asic_inspection.Index.t) (b : Asic_inspection.Index.t) ->
               Option.equal Asic_inspection.Analysis_target.equal a.analysis b.analysis)
             t.index
             index))
    || (not
          (Option.equal
             (fun a b ->
               String.equal a.Asic_inspection.Index.execution_file b.execution_file
               && String.equal a.execution_sha256 b.execution_sha256)
             t.index
             index))
    || (not
          (Option.equal
             (fun a b ->
               Bool.equal a.Asic_inspection.Index.cached_unverified b.cached_unverified)
             t.index
             index))
    || not
         (Option.equal
            Asic_inspection.Row.equal
            (selected_row t.index)
            (selected_row index))
  in
  let t =
    if changed
    then
      { t with
        index
      ; generation = t.generation + 1
      ; error = None
      ; requested = None
      ; detail = None
      ; operation_key = Option.filter t.operation_key ~f:(String.equal (index_key t))
      ; info = false
      ; scroll = 0
      ; detail_cache = None
      }
    else { t with index }
  in
  let detail =
    Option.bind t.requested ~f:(fun (source_digest, row_id) ->
      let matches d =
        Run_ref.equal d.Asic_inspection.Detail.run t.run
        && String.equal d.domain t.domain
        && String.equal d.stage t.stage
        && String.equal d.source_digest source_digest
        && String.equal d.row_id row_id
      in
      Option.first_some
        (List.find snapshot.inspection_details ~f:matches)
        (Option.filter t.detail ~f:(fun d -> matches d && Option.is_none d.error)))
  in
  let pending_error =
    Option.bind t.operation_key ~f:(fun key ->
      List.find snapshot.operations ~f:(fun op -> String.equal op.key key)
      |> Option.bind ~f:(fun op ->
        Option.first_some
          op.error
          (if List.mem [ "failed"; "detached" ] op.state ~equal:String.equal
           then Some (key ^ ": " ^ op.state)
           else None)))
  in
  normalize { t with observation; detail; pending_error }
;;

let cycle_axis t axis =
  let get (r : Asic_inspection.Row.t) =
    match axis with
    | Corner -> r.corner
    | Group -> r.group
    | Producer -> Some r.producer
  in
  let current =
    match axis with
    | Corner -> t.corner
    | Group -> t.group
    | Producer -> t.producer
  in
  let values =
    Option.value_map t.index ~default:[] ~f:(fun i -> List.filter_map i.rows ~f:get)
    |> List.dedup_and_sort ~compare:String.compare
  in
  let choices = None :: List.map values ~f:Option.some in
  let position =
    List.findi choices ~f:(fun _ c -> Option.equal String.equal c current)
    |> Option.value_map ~default:0 ~f:fst
  in
  let next = List.nth_exn choices ((position + 1) % List.length choices) in
  normalize
    (match axis with
     | Corner -> { t with corner = next }
     | Group -> { t with group = next }
     | Producer -> { t with producer = next })
;;

let build_detail_lines ?(now = Time_ns.now ()) (t : t) ~width =
  let metadata =
    Option.value_map t.index ~default:[] ~f:(fun i ->
      [ "Execution: " ^ i.execution_file
      ; "Execution SHA256: " ^ i.execution_sha256
      ; "Source digest: " ^ i.source_digest
      ]
      @ Evidence_time_view.lines ~now i
      @ (if i.cached_unverified
         then [ "CACHED UNVERIFIED — explicit refresh required" ]
         else [])
      @ (if i.truncated then [ "Index truncated by provider" ] else [])
      @ List.map i.diagnostics ~f:(fun d -> "Diagnostic: " ^ d))
  in
  let row =
    List.find (visible t) ~f:(fun r ->
      Option.equal String.equal t.selected (Some r.Asic_inspection.Row.id))
  in
  let row =
    Option.value_map row ~default:[] ~f:(fun r ->
      [ "Row: " ^ r.id ^ " · " ^ r.name; "Producer: " ^ r.producer ]
      @ Option.value_map t.index ~default:[] ~f:(fun i ->
        [ Evidence_time_view.row_line ~now i r ])
      @ [ "Category: " ^ r.category ^ " · Status: " ^ r.status
        ; "Value: "
          ^ Option.value_map r.value ~default:"(unreported)" ~f:(sprintf "%.9g")
          ^ " "
          ^ Option.value r.unit_ ~default:"(unit unreported)"
        ; "Corner: "
          ^ Option.value r.corner ~default:"(none)"
          ^ " · Group: "
          ^ Option.value r.group ~default:"(none)"
        ; "Source: " ^ r.source
        ]
      @ List.map r.fields ~f:(fun (k, v) -> k ^ ": " ^ v))
  in
  let body =
    match t.requested, t.detail with
    | None, _ -> []
    | Some _, None -> [ "Waiting for exact row/digest detail (Enter retries)" ]
    | Some _, Some d ->
      (match d.error with
       | Some e -> [ "ERROR: " ^ e ]
       | None -> String.split_lines d.text)
  in
  (if t.info then metadata @ row else row @ body @ metadata)
  |> List.concat_map ~f:(fun line -> Artifact_view.wrap ~width (Artifact_view.safe line))
;;

let equal_option_phys equal a b =
  phys_equal a b || Option.equal (fun a b -> phys_equal a b || equal a b) a b
;;

let same_detail_metadata (a : Asic_inspection.Index.t) (b : Asic_inspection.Index.t) =
  phys_equal a b
  || (Run_ref.equal a.run b.run
      && String.equal a.domain b.domain
      && String.equal a.stage b.stage
      && String.equal a.source_digest b.source_digest
      && String.equal a.execution_file b.execution_file
      && String.equal a.execution_sha256 b.execution_sha256
      && Bool.equal a.cached_unverified b.cached_unverified
      && Bool.equal a.truncated b.truncated
      && Evidence_time.Index.equal a.times b.times
      && (phys_equal a.diagnostics b.diagnostics
          || List.equal String.equal a.diagnostics b.diagnostics))
;;

let memoize_detail ?(now = Time_ns.now ()) (t : t) ~width =
  let age_bucket = Evidence_time_view.age_bucket ~now t.index in
  let row =
    List.find (visible t) ~f:(fun row ->
      Option.equal String.equal t.selected (Some row.Asic_inspection.Row.id))
  in
  let reusable =
    Option.exists t.detail_cache ~f:(fun cache ->
      cache.width = width
      && Bool.equal cache.info t.info
      && Option.equal Int.equal cache.age_bucket age_bucket
      && Option.equal String.equal t.selected cache.selected
      && Option.equal
           (fun (a, b) (c, d) -> String.equal a c && String.equal b d)
           t.requested
           cache.requested
      && equal_option_phys same_detail_metadata t.index cache.index
      && equal_option_phys Asic_inspection.Row.equal row cache.row
      && equal_option_phys Asic_inspection.Detail.equal t.detail cache.detail)
  in
  if reusable
  then (
    let cache = Option.value_exn t.detail_cache in
    if phys_equal cache.index t.index
       && phys_equal cache.detail t.detail
       && phys_equal cache.row row
    then t
    else
      { t with
        detail_cache = Some { cache with index = t.index; detail = t.detail; row }
      })
  else
    { t with
      detail_cache =
        Some
          { index = t.index
          ; row
          ; selected = t.selected
          ; requested = t.requested
          ; detail = t.detail
          ; width
          ; info = t.info
          ; age_bucket
          ; lines = Array.of_list (build_detail_lines ~now t ~width)
          }
    }
;;

let detail_mode (t : t) = Option.is_some t.requested || t.info
let page_size (t : t) ~height = Int.max 1 (height - if detail_mode t then 3 else 4)

let clamp ?now (t : t) ~width ~height =
  let t = normalize t in
  if not (detail_mode t)
  then { t with scroll = 0; detail_cache = None }
  else (
    let t = memoize_detail ?now t ~width in
    let last =
      Int.max
        0
        (Array.length (Option.value_exn t.detail_cache).lines - page_size t ~height)
    in
    { t with scroll = Int.clamp_exn t.scroll ~min:0 ~max:last })
;;

let reject_filter_text (t : t) =
  { t with
    filter_notice =
      Some "Filter rejects controls, newlines and invalid UTF-8; input was not executed"
  }
;;

let append_filter_text (t : t) text =
  let rec valid offset =
    if offset >= String.length text
    then true
    else (
      let decoded = Stdlib.String.get_utf_8_uchar text offset in
      let scalar = Stdlib.Uchar.to_int (Stdlib.Uchar.utf_decode_uchar decoded) in
      Stdlib.Uchar.utf_decode_is_valid decoded
      && scalar >= 32
      && (not (scalar >= 127 && scalar < 160))
      && scalar <> 0x2028
      && scalar <> 0x2029
      && valid (offset + Stdlib.Uchar.utf_decode_length decoded))
  in
  if not (valid 0)
  then reject_filter_text t
  else (
    let remaining = Int.max 0 (4096 - String.length t.filter) in
    let rec prefix offset =
      if offset >= String.length text
      then offset
      else (
        let length =
          Stdlib.Uchar.utf_decode_length (Stdlib.String.get_utf_8_uchar text offset)
        in
        if offset + length > remaining then offset else prefix (offset + length))
    in
    let length = prefix 0 in
    { t with
      filter = t.filter ^ String.prefix text length
    ; filter_notice =
        (if length < String.length text
         then
           Some
             "Filter limited to 4096 UTF-8 bytes; excess text ignored at a codepoint \
              boundary"
         else t.filter_notice)
    })
;;

type input =
  | Up
  | Down
  | Page_up
  | Page_down
  | Open
  | Back
  | Sort
  | Cycle of axis
  | Near
  | Stage
  | Refresh
  | Filter
  | Info
  | Character of char
  | Text of string
  | Backspace

let input ~width ~height t action =
  let t = clamp t ~width ~height in
  let page = page_size t ~height in
  let max_scroll =
    Option.value_map t.detail_cache ~default:0 ~f:(fun cache ->
      Int.max 0 (Array.length cache.lines - page))
  in
  let local t = Some (clamp t ~width ~height), None in
  if t.editing
  then (
    match action with
    | Character c -> local (append_filter_text t (String.of_char c))
    | Text text -> local (append_filter_text t text)
    | _ when t.pasting -> local (reject_filter_text t)
    | Back | Open -> local { t with editing = false }
    | Backspace ->
      let rec previous offset last =
        if offset >= String.length t.filter
        then last
        else
          previous
            (offset
             + Stdlib.Uchar.utf_decode_length
                 (Stdlib.String.get_utf_8_uchar t.filter offset))
            offset
      in
      local { t with filter = String.prefix t.filter (previous 0 0) }
    | _ -> local t)
  else (
    match action with
    | Back ->
      if Option.is_some t.requested || t.info
      then
        local
          { t with
            requested = None
          ; detail = None
          ; info = false
          ; scroll = 0
          ; generation = t.generation + 1
          ; error = None
          ; pending_error = None
          ; operation_key = None
          }
      else None, None
    | Info -> local { t with info = true; scroll = 0 }
    | Open ->
      (match t.index, t.selected with
       | Some index, Some row_id ->
         ( Some
             { t with
               requested = Some (index.source_digest, row_id)
             ; detail = None
             ; info = false
             ; scroll = 0
             ; generation = t.generation + 1
             ; error = None
             ; pending_error = None
             ; operation_key =
                 Some (detail_key t ~source_digest:index.source_digest ~row_id)
             }
         , Some (detail_operation t ~source_digest:index.source_digest ~row_id) )
       | _ -> local t)
    | (Up | Down | Page_up | Page_down) as direction ->
      let delta =
        match direction with
        | Up -> -1
        | Down -> 1
        | Page_up -> -page
        | _ -> page
      in
      if Option.is_some t.requested || t.info
      then
        local { t with scroll = Int.clamp_exn (t.scroll + delta) ~min:0 ~max:max_scroll }
      else (
        let rows = visible t in
        let pos =
          List.findi rows ~f:(fun _ r ->
            Option.equal String.equal t.selected (Some r.Asic_inspection.Row.id))
          |> Option.value_map ~default:0 ~f:fst
        in
        local
          { t with
            selected =
              Option.map
                (List.nth rows (Int.max 0 (Int.min (List.length rows - 1) (pos + delta))))
                ~f:(fun r -> r.Asic_inspection.Row.id)
          })
    | Sort ->
      local
        { t with
          sort =
            (match t.sort with
             | Numeric_ascending -> Numeric_descending
             | Numeric_descending -> Name
             | Name -> Numeric_ascending)
        }
    | Cycle axis -> local (cycle_axis t axis)
    | Near -> local { t with near = String.equal t.domain "timing" && not t.near }
    | Filter -> local { t with editing = true; filter_notice = None }
    | Stage when Option.is_some t.analysis ->
      local
        { t with
          filter_notice =
            Some
              "Captured analysis: stage is fixed; open a generic Timing investigation to \
               browse stages"
        }
    | Stage ->
      let pos =
        List.findi stages ~f:(fun _ s -> String.equal s t.stage)
        |> Option.value_map ~default:0 ~f:fst
      in
      let t =
        { t with
          stage = List.nth_exn stages ((pos + 1) % List.length stages)
        ; index = None
        ; requested = None
        ; detail = None
        ; info = false
        ; scroll = 0
        ; selected = None
        ; generation = t.generation + 1
        ; error = None
        ; cache = None
        ; detail_cache = None
        }
      in
      let t = { t with pending_error = None; operation_key = Some (index_key t) } in
      Some t, Some (operation t)
    | Refresh ->
      ( Some
          { t with
            requested = None
          ; detail = None
          ; info = false
          ; scroll = 0
          ; generation = t.generation + 1
          ; error = None
          ; pending_error = None
          ; operation_key = Some (index_key t)
          }
      , Some (operation ~refresh:true t) )
    | Character _ | Text _ | Backspace -> local t)
;;

let rows ?(now = Time_ns.now ()) ~width ~height t =
  let t = clamp ~now t ~width ~height in
  let all = Option.value ~default:"ALL" in
  let header =
    [ sprintf "INSPECT %s · stage %s · run %s" t.domain t.stage t.run.id
    ; (if t.pasting
       then
         "FILTER PASTE ACTIVE · "
         ^ Option.value
             t.filter_notice
             ~default:"Waiting for end marker; payload is literal; Ctrl-C exits"
       else (
         match t.filter_notice with
         | Some notice -> notice
         | None ->
           if t.editing
           then
             "FILTER INPUT — Enter/Esc finish · Backspace deletes codepoint · Ctrl-U \
              clears · Ctrl-C exits"
           else
             "Enter detail · Esc back · Space c x close · j/k scroll · n/N page · / \
              filter · s sort · c/g/p axes · v ≤1ns · t stage · r refresh · d \
              source/diagnostics"))
    ; (if t.editing || t.pasting
       then ""
       else
         Option.value_map
           (Option.first_some t.error t.pending_error)
           ~default:""
           ~f:(fun e -> "ERROR: " ^ e ^ " · "))
      ^ sprintf
          "%sfilter=%s · sort=%s · corner=%s · group=%s · producer=%s · near=%b"
          (if t.editing then "EDIT " else "")
          t.filter
          (match t.sort with
           | Numeric_ascending -> "numeric ↑"
           | Numeric_descending -> "numeric ↓"
           | Name -> "name")
          (all t.corner)
          (all t.group)
          (all t.producer)
          t.near
    ]
  in
  let body =
    if Option.is_some t.requested || t.info
    then (
      let lines = (Option.value_exn t.detail_cache).lines in
      Array.sub
        lines
        ~pos:t.scroll
        ~len:(Int.min (page_size t ~height) (Array.length lines - t.scroll))
      |> Array.to_list)
    else (
      match t.index with
      | None -> [ "Waiting for explicitly requested index" ]
      | Some i ->
        let rows = visible t in
        let pos =
          List.findi rows ~f:(fun _ r ->
            Option.equal String.equal (Some r.Asic_inspection.Row.id) t.selected)
          |> Option.value_map ~default:0 ~f:fst
        in
        let viewport = Int.max 1 (height - 4) in
        [ sprintf
            "%d rows%s%s · %s · %s%s"
            (List.length rows)
            (if i.truncated then " TRUNCATED" else "")
            (if i.cached_unverified then " CACHED UNVERIFIED" else "")
            (Evidence_time_view.summary ~now i)
            (if String.equal t.domain "clocks"
             then
               "Clock/name | Value/unit | Status | Producer/corner/group | Reported \
                fields · "
             else "")
            (String.concat ~sep:"; " i.diagnostics)
        ]
        @ (List.drop rows (pos / viewport * viewport)
           |> Fn.flip List.take viewport
           |> List.map ~f:(fun r ->
             sprintf
               "%s %s · %s %s · %s · producer=%s corner=%s group=%s · %s"
               (if Option.equal String.equal t.selected (Some r.id) then ">" else " ")
               r.name
               (Option.value_map r.value ~default:"—" ~f:(sprintf "%.6g"))
               (Option.value r.unit_ ~default:"")
               r.status
               r.producer
               (Option.value r.corner ~default:"—")
               (Option.value r.group ~default:"—")
               (String.concat
                  ~sep:" · "
                  (List.map r.fields ~f:(fun (k, v) -> k ^ "=" ^ v))))))
  in
  List.take (List.map (header @ body) ~f:Artifact_view.safe) (Int.max 0 height)
;;

let%test_unit "literal endpoint filtering, stable numeric selection and explicit axis \
               ALL cycles"
  =
  let run = Fs0_fixture.run_a in
  let row id value corner producer : Asic_inspection.Row.t =
    { id
    ; category = "path"
    ; producer
    ; corner = Some corner
    ; group = Some "clock"
    ; name = id
    ; value = Some value
    ; unit_ = Some "ns"
    ; status = "ok"
    ; source = "/source/report"
    ; fields = [ "startpoint", "in[3].a*"; "endpoint", "out/Q" ]
    }
  in
  let a = row "a" 0.2 "slow" "sta"
  and b = row "b" 2. "fast" "route" in
  let index : Asic_inspection.Index.t =
    { run
    ; execution_file = "/execution"
    ; execution_sha256 = "execution-sha"
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "digest"
    ; rows = [ b; a ]
    ; diagnostics = [ "fixture" ]
    ; truncated = false
    ; cached_unverified = true
    ; analysis = None
    ; times = Evidence_time.Index.empty
    }
  in
  let t =
    normalize
      { (create ~run ~domain:"timing" ~stage:"signoff" ()) with index = Some index }
  in
  assert (Option.equal String.equal t.selected (Some "a"));
  let t = { t with selected = Some "b" } in
  let local t action =
    let t, operation = input ~width:60 ~height:12 t action in
    assert (Option.is_none operation);
    Option.value_exn t
  in
  let sorted = local t Sort in
  assert (Option.equal String.equal sorted.selected (Some "b"));
  assert (String.equal (List.hd_exn (visible sorted)).id "b");
  assert (List.length (visible { t with filter = "in[3].a*" }) = 2);
  assert (List.is_empty (visible { t with filter = "in.*" }));
  assert (List.length (visible (local t Near)) = 1);
  List.iter [ Corner; Group; Producer ] ~f:(fun axis ->
    let rec loop state remaining =
      if remaining = 0
      then assert false
      else (
        let state = local state (Cycle axis) in
        let choice =
          match axis with
          | Corner -> state.corner
          | Group -> state.group
          | Producer -> state.producer
        in
        if Option.is_none choice then () else loop state (remaining - 1))
    in
    loop t 5);
  let staged, operation = input ~width:60 ~height:12 t Stage in
  let staged = Option.value_exn staged in
  assert (not (String.equal staged.stage "signoff"));
  assert (Option.is_none staged.index);
  match operation with
  | Some (Inspect { stage; refresh = false; _ }) ->
    assert (String.equal stage staged.stage)
  | _ -> assert false
;;

let%test_unit "detail responses require exact digest row stage scope and request \
               generation"
  =
  let run = Fs0_fixture.run_a in
  let row : Asic_inspection.Row.t =
    { id = "row"
    ; category = "path"
    ; producer = "sta"
    ; corner = None
    ; group = None
    ; name = "path"
    ; value = Some (-0.1)
    ; unit_ = Some "ns"
    ; status = "violated"
    ; source = "/source"
    ; fields = []
    }
  in
  let index : Asic_inspection.Index.t =
    { run
    ; execution_file = "/execution"
    ; execution_sha256 = "sha"
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "digest-a"
    ; rows = [ row ]
    ; diagnostics = []
    ; truncated = false
    ; cached_unverified = true
    ; analysis = None
    ; times = Evidence_time.Index.empty
    }
  in
  let snapshot = { Fs0_fixture.snapshot with inspections = [ index ] } in
  let initial =
    reconcile (create ~scope:run ~run ~domain:"timing" ~stage:"signoff" ()) snapshot
  in
  let opened, operation = input ~width:30 ~height:10 initial Open in
  let opened = Option.value_exn opened in
  let ticket = capture opened (Option.value_exn operation) in
  let detail : Asic_inspection.Detail.t =
    { run
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "digest-a"
    ; row_id = "row"
    ; text = String.concat ~sep:"\n" (List.init 100 ~f:(fun i -> sprintf "detail-%d" i))
    ; error = None
    }
  in
  List.iter
    [ { detail with source_digest = "old" }
    ; { detail with row_id = "other" }
    ; { detail with stage = "placement" }
    ; { detail with run = Fs0_fixture.run_b }
    ]
    ~f:(fun stale ->
      assert (
        Option.is_none
          (reconcile opened { snapshot with inspection_details = [ stale ] }).detail));
  let loaded = reconcile opened { snapshot with inspection_details = [ detail ] } in
  assert (Option.is_some loaded.detail);
  let scroll =
    List.fold (List.init 500 ~f:Fn.id) ~init:loaded ~f:(fun state _ ->
      Option.value_exn (fst (input ~width:30 ~height:10 state Page_down)))
  in
  let up = Option.value_exn (fst (input ~width:30 ~height:10 scroll Up)) in
  assert (up.scroll = scroll.scroll - 1);
  let changed =
    reconcile
      loaded
      { snapshot with
        inspections = [ { index with source_digest = "digest-b" } ]
      ; inspection_details = [ detail ]
      }
  in
  assert (Option.is_none changed.detail && Option.is_none changed.requested);
  assert (Option.is_none (apply_response changed ticket (Error "late detail error")).error);
  let retry = Option.value_exn (fst (input ~width:30 ~height:10 loaded Open)) in
  assert (Option.is_none (apply_response retry ticket (Error "late retry error")).error);
  assert (Option.is_none (reconcile_scope loaded ~scope:(Some Fs0_fixture.run_b)));
  assert (Option.is_some (reconcile_scope loaded ~scope:(Some run)))
;;

let%test_unit "inspection memo preserves projections across scrolling repaint and equal \
               polling but checks same-digest rows"
  =
  let run = Fs0_fixture.run_a in
  let source = String.make 2048 'S' in
  let source_rows =
    List.init 1021 ~f:(fun i : Asic_inspection.Row.t ->
      { id = sprintf "row-%04d" i
      ; category = "path"
      ; producer = (if i % 2 = 0 then "sta" else "route")
      ; corner = Some (if i % 2 = 0 then "slow" else "fast")
      ; group = Some (if i % 2 = 0 then "clk1" else "clk2")
      ; name = sprintf "path-%04d" i
      ; value = Some (Float.of_int i)
      ; unit_ = Some "ns"
      ; status = "ok"
      ; source
      ; fields = [ "endpoint", sprintf "out[%d]/Q" i ]
      })
  in
  let index : Asic_inspection.Index.t =
    { run
    ; execution_file = "/execution"
    ; execution_sha256 = "sha"
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "same-digest"
    ; rows = source_rows
    ; diagnostics = []
    ; truncated = false
    ; cached_unverified = false
    ; analysis = None
    ; times = Evidence_time.Index.empty
    }
  in
  let snapshot = { Fs0_fixture.snapshot with inspections = [ index ] } in
  let initial =
    reconcile (create ~scope:run ~run ~domain:"timing" ~stage:"signoff" ()) snapshot
  in
  let cache = Option.value_exn initial.cache in
  let check_reused state =
    let current = Option.value_exn state.cache in
    assert (phys_equal current.projection cache.projection);
    assert (phys_equal current.rows cache.rows)
  in
  check_reused (normalize initial);
  ignore (rows ~width:120 ~height:40 initial : string list);
  check_reused initial;
  let moved = Option.value_exn (fst (input ~width:120 ~height:40 initial Down)) in
  check_reused moved;
  assert (Option.equal String.equal moved.selected (Some "row-0001"));
  let copied = Asic_inspection.Index.t_of_sexp (Asic_inspection.Index.sexp_of_t index) in
  assert (not (phys_equal copied.rows index.rows));
  let polled = reconcile moved { snapshot with inspections = [ copied ] } in
  check_reused polled;
  let metadata =
    reconcile
      polled
      { snapshot with
        inspections =
          [ { copied with cached_unverified = true; diagnostics = [ "updated" ] } ]
      }
  in
  check_reused metadata;
  assert (Option.equal String.equal metadata.selected moved.selected);
  List.iter
    [ { initial with filter = "out[10]/Q" }
    ; { initial with sort = Numeric_descending }
    ; { initial with sort = Name }
    ; { initial with corner = Some "slow" }
    ; { initial with group = Some "clk1" }
    ; { initial with producer = Some "sta" }
    ; { initial with near = true }
    ]
    ~f:(fun query ->
      let query = normalize query in
      let current = Option.value_exn query.cache in
      assert (phys_equal current.projection cache.projection);
      assert (not (phys_equal current.rows cache.rows)));
  let first = List.hd_exn index.rows in
  let changed =
    reconcile
      polled
      { snapshot with
        inspections =
          [ { copied with
              rows = { first with name = "changed-row" } :: List.tl_exn copied.rows
            }
          ]
      }
  in
  assert (not (phys_equal (Option.value_exn changed.cache).projection cache.projection));
  assert (String.equal (List.hd_exn (visible changed)).name "changed-row");
  let redigested =
    reconcile
      initial
      { snapshot with inspections = [ { index with source_digest = "new-digest" } ] }
  in
  assert (not (phys_equal (Option.value_exn redigested.cache).projection cache.projection))
;;

let%test_unit "1000 detail downs then one up reverses the visible viewport and retains \
               immutable wrapped lines"
  =
  let run = Fs0_fixture.run_a in
  let row : Asic_inspection.Row.t =
    { id = "row"
    ; category = "path"
    ; producer = "sta"
    ; corner = None
    ; group = None
    ; name = "path"
    ; value = Some 0.
    ; unit_ = Some "ns"
    ; status = "ok"
    ; source = String.make 300 's'
    ; fields = []
    }
  in
  let index : Asic_inspection.Index.t =
    { run
    ; execution_file = "/execution"
    ; execution_sha256 = "sha"
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "digest"
    ; rows = [ row ]
    ; diagnostics = []
    ; truncated = false
    ; cached_unverified = false
    ; analysis = None
    ; times = Evidence_time.Index.empty
    }
  in
  let detail : Asic_inspection.Detail.t =
    { run
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "digest"
    ; row_id = "row"
    ; text =
        String.concat
          ~sep:"\n"
          (List.init 100 ~f:(fun i ->
             sprintf "unique-line-%03d %s" i (String.make 135 'x')))
    ; error = None
    }
  in
  let initial =
    normalize
      { (reconcile
           (create ~run ~domain:"timing" ~stage:"signoff" ())
           { Fs0_fixture.snapshot with inspections = [ index ] })
        with
        index = Some index
      ; selected = Some "row"
      ; requested = Some ("digest", "row")
      ; detail = Some detail
      }
  in
  List.iter
    [ 120, 40; 112, 40; 80, 24 ]
    ~f:(fun (width, height) ->
      let initial = clamp initial ~width ~height in
      let lines = (Option.value_exn initial.detail_cache).lines in
      let projection = (Option.value_exn initial.cache).projection in
      let copied_index =
        Asic_inspection.Index.t_of_sexp (Asic_inspection.Index.sexp_of_t index)
      in
      let copied_detail =
        Asic_inspection.Detail.t_of_sexp (Asic_inspection.Detail.sexp_of_t detail)
      in
      let polled =
        reconcile
          initial
          { Fs0_fixture.snapshot with
            inspections = [ copied_index ]
          ; inspection_details = [ copied_detail ]
          }
        |> fun t -> clamp t ~width ~height
      in
      assert (phys_equal (Option.value_exn polled.detail_cache).lines lines);
      let diagnostic_change =
        reconcile
          polled
          { Fs0_fixture.snapshot with
            inspections = [ { copied_index with diagnostics = [ "new-diagnostic" ] } ]
          ; inspection_details = [ copied_detail ]
          }
        |> fun t -> clamp t ~width ~height
      in
      assert (
        not (phys_equal (Option.value_exn diagnostic_change.detail_cache).lines lines));
      let step t action =
        let state, operation = input ~width ~height t action in
        assert (Option.is_none operation);
        Option.value_exn state
      in
      let bottom =
        List.fold (List.init 1000 ~f:Fn.id) ~init:initial ~f:(fun t _ -> step t Down)
      in
      assert (bottom.scroll = Array.length lines - page_size bottom ~height);
      assert (phys_equal (Option.value_exn bottom.detail_cache).lines lines);
      assert (phys_equal (Option.value_exn bottom.cache).projection projection);
      let up = step bottom Up in
      assert (up.scroll = bottom.scroll - 1);
      assert (phys_equal (Option.value_exn up.detail_cache).lines lines);
      assert (
        not
          (List.equal String.equal (rows ~width ~height bottom) (rows ~width ~height up)));
      let resized = clamp bottom ~width:(width + 17) ~height:(height + 5) in
      assert (not (phys_equal (Option.value_exn resized.detail_cache).lines lines));
      let reversed, _ = input ~width:(width + 17) ~height:(height + 5) resized Up in
      assert ((Option.value_exn reversed).scroll = resized.scroll - 1))
;;
