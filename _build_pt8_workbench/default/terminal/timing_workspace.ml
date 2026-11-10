open! Core
open Hardcaml_workbench_protocol

type pane =
  | Paths
  | Detail
  | Context
[@@deriving equal]

type t = Inspection_view.t

type selection =
  { run : Run_ref.t
  ; domain : string
  ; stage : string
  ; source_digest : string
  ; row_id : string
  }

type path_item =
  { row : Asic_inspection.Row.t
  ; selected : bool
  ; label : string
  }

let path_items ?(presentation = Tile_presentation.defaults) (t : t) =
  Inspection_view.visible t
  |> List.map ~f:(fun row ->
    let selected =
      Option.equal String.equal t.selected (Some row.Asic_inspection.Row.id)
    in
    let endpoint key = List.Assoc.find row.fields key ~equal:String.equal in
    let endpoints =
      match endpoint "startpoint", endpoint "endpoint" with
      | Some a, Some b -> " · " ^ a ^ " → " ^ b
      | _, Some b -> " · endpoint=" ^ b
      | Some a, _ -> " · startpoint=" ^ a
      | _ -> ""
    in
    { row
    ; selected
    ; label =
        Artifact_view.safe
          (sprintf
             "%s %s %s · %s%s · %s"
             (if selected then ">" else " ")
             (Option.value_map
                row.value
                ~default:"—"
                ~f:(Presentation.decimal ~places:presentation.decimal_places))
             (Option.value row.unit_ ~default:"")
             row.status
             endpoints
             row.name)
    })
;;

let pane = function
  | "timing-paths" -> Some Paths
  | "timing-detail" -> Some Detail
  | "timing-context" -> Some Context
  | _ -> None
;;

let create ~generation ~run ~stage =
  Inspection_view.create ~scope:run ~generation ~run ~domain:"timing" ~stage ()
;;

let with_analysis t analysis =
  let stage =
    Option.value_map analysis ~default:t.Inspection_view.stage ~f:(fun a ->
      a.Asic_inspection.Analysis_target.stage)
  in
  let t = { t with Inspection_view.analysis; stage } in
  { t with operation_key = Some (Inspection_view.index_key t) }
;;

(** Attach only published evidence. No Inspect operation or demand is created here. *)
let attach_retained (t : t) snapshot =
  let selected = t.selected in
  let t = Inspection_view.reconcile t snapshot in
  let t = if Option.is_none t.index then { t with selected } else t in
  match t.index, t.selected with
  | Some index, Some row_id when Option.is_none t.requested ->
    if List.exists snapshot.Asic.Snapshot.inspection_details ~f:(fun detail ->
         Run_ref.equal detail.run t.run
         && String.equal detail.domain t.domain
         && String.equal detail.stage t.stage
         && String.equal detail.source_digest index.source_digest
         && String.equal detail.row_id row_id)
    then
      Inspection_view.reconcile
        { t with requested = Some (index.source_digest, row_id) }
        snapshot
    else t
  | _ -> t
;;

let selection (t : t) =
  Option.bind t.index ~f:(fun index ->
    Option.map t.selected ~f:(fun row_id ->
      { run = t.run
      ; domain = t.domain
      ; stage = t.stage
      ; source_digest = index.source_digest
      ; row_id
      }))
;;

type line_role =
  | Selected
  | Metric
  | Metadata
  | Pending
  | Failure
  | Success
  | Source

let selected_row (t : t) =
  List.find (Inspection_view.visible t) ~f:(fun row ->
    Option.equal String.equal t.selected (Some row.Asic_inspection.Row.id))
;;

let row_status_role (row : Asic_inspection.Row.t) =
  if Option.exists row.value ~f:(fun value -> Float.is_finite value && Float.(value < 0.))
  then Failure
  else (
    match String.lowercase row.status with
    | "violated" | "fail" | "failed" -> Failure
    | "met" | "pass" | "passed" -> Success
    | "pending" | "unavailable" -> Pending
    | _ -> Metadata)
;;

(** The compact prefix is width-bounded; complete values live in Context. Provider payload
    is deliberately outside this prefix and is never semantically styled. *)
let semantic_prefix
  ?(presentation = Tile_presentation.defaults)
  ?(now = Time_ns.now ())
  ~pane
  ~width
  (t : t)
  =
  let compress = presentation.string_compression in
  let population =
    [ t.run.id ]
    @ Option.value_map t.index ~default:[] ~f:(fun i ->
      [ i.source_digest; i.execution_sha256 ] @ List.map i.rows ~f:(fun row -> row.id))
    @ Option.value_map t.analysis ~default:[] ~f:(fun a ->
      [ a.analysis_id; a.attempt_id; a.occurrence_id; a.source_digest ])
  in
  let identity = Presentation.identifiers ~compress population in
  let path = Presentation.source_path ~compress in
  let field label value = Source, label ^ ": " ^ value in
  match pane with
  | Paths -> []
  | Detail ->
    (match selected_row t with
     | None -> [ Pending, "No selected path · select a loaded path in Paths" ]
     | Some row ->
       let endpoint key =
         List.Assoc.find row.fields key ~equal:String.equal |> Option.value ~default:"—"
       in
       [ Selected, "Path: " ^ row.name
       ; ( Metric
         , "Slack: "
           ^ Option.value_map
               row.value
               ~default:"unreported"
               ~f:(Presentation.decimal ~places:presentation.decimal_places)
           ^ " "
           ^ Option.value row.unit_ ~default:"(unit unreported)"
           ^ " · "
           ^ row.status )
       ; ( Metadata
         , "Corner: "
           ^ Option.value row.corner ~default:"—"
           ^ " · Group: "
           ^ Option.value row.group ~default:"—" )
       ; Metadata, "Endpoints: " ^ endpoint "startpoint" ^ " → " ^ endpoint "endpoint"
       ])
    |> List.map ~f:(fun (role, line) ->
      let lines =
        Artifact_view.wrap ~width:(Int.max 1 (width - 1)) (Artifact_view.safe line)
      in
      ( role
      , if width <= 0
        then ""
        else (
          match lines with
          | [] -> ""
          | [ line ] -> line
          | line :: _ -> if width = 1 then "…" else line ^ "…") ))
  | Context ->
    let observation =
      match t.index with
      | None ->
        [ ( Pending
          , if t.index_loading
            then "Loading timing index…"
            else "No loaded observation; Inspect/refresh to load" )
        ]
      | Some i ->
        [ (if i.cached_unverified
           then Pending, "CACHED UNVERIFIED"
           else Success, "Verified cached observation")
        ; (if i.truncated then Pending, "TRUNCATED index" else Success, "Complete index")
        ; field "Source digest" (identity i.source_digest)
        ; field "Execution" (path i.execution_file)
        ; field "Execution SHA256" (identity i.execution_sha256)
        ]
        @ List.map (Evidence_time_view.lines ~now i) ~f:(fun line -> Metadata, line)
        @ List.map i.diagnostics ~f:(fun diagnostic -> field "Diagnostic" diagnostic)
    in
    [ field "Run" (identity t.run.id)
    ; field "Domain" (t.domain ^ " · Stage: " ^ t.stage)
    ]
    @ Option.value_map t.analysis ~default:[] ~f:(fun a ->
      [ field "Captured analysis" (identity a.analysis_id)
      ; field
          "Attempt / occurrence"
          (identity a.attempt_id ^ " / " ^ identity a.occurrence_id)
      ; field "Analysis digest" (identity a.source_digest)
      ; field "Captured stage" a.stage
      ; Metadata, "Exact STA evidence; current execution may have failed downstream"
      ])
    @ observation
    @
      (match selected_row t with
      | None -> [ Pending, "No selected path provenance" ]
      | Some row ->
        [ field "Row" (identity row.id)
        ; field "Path" row.name
        ; field "Producer" row.producer
        ]
        @ Option.value_map t.index ~default:[] ~f:(fun i ->
          [ Metadata, Evidence_time_view.row_line ~now i row ])
        @ [ row_status_role row, "Category / status: " ^ row.category ^ " / " ^ row.status
          ; field
              "Value"
              (Option.value_map
                 row.value
                 ~default:"unreported"
                 ~f:(Presentation.decimal ~places:presentation.decimal_places)
               ^ " "
               ^ Option.value row.unit_ ~default:"(unit unreported)")
          ; field "Corner" (Option.value row.corner ~default:"(none)")
          ; field "Group" (Option.value row.group ~default:"(none)")
          ; field "Source" (Presentation.source_metadata ~compress row.source)
          ]
        @ List.map row.fields ~f:(fun (key, value) -> field key value))
;;

let detail_body (t : t) =
  match selected_row t with
  | None -> []
  | Some _ ->
    (match Option.first_some t.error t.pending_error with
     | Some error -> [ "ERROR: " ^ error ]
     | None ->
       (match t.requested, t.detail with
        | None, _ -> [ "Enter to load selected path detail (read-only)" ]
        | Some _, None ->
          [ "Pending: waiting for exact selected path detail · Enter retries" ]
        | Some _, Some detail ->
          (match detail.error with
           | Some error -> [ "ERROR: " ^ error ]
           | None ->
             if String.is_empty detail.text
             then [ "Provider returned no detail text" ]
             else String.split_lines detail.text)))
;;

let empty_paths_message (t : t) =
  match Option.first_some t.error t.pending_error with
  | Some error -> "ERROR: " ^ error
  | None ->
    (match t.index with
     | None -> "No loaded index · explicit Inspect/refresh required"
     | Some index when List.is_empty index.rows ->
       "No timing paths reported for stage "
       ^ t.stage
       ^ Option.value_map (List.hd index.diagnostics) ~default:"" ~f:(fun reason ->
         " · " ^ reason)
     | Some index ->
       sprintf "No paths match the current filters (%d loaded)" (List.length index.rows))
;;

let rows
  ?(presentation = Tile_presentation.defaults)
  ?now
  ~pane
  ~scroll
  ~width
  ~height
  (t : t)
  =
  match pane with
  | Paths ->
    let items = path_items ~presentation t in
    let status =
      match t.index with
      | None ->
        if t.index_loading
        then "Loading timing index…"
        else "No loaded index · Inspect/refresh to load"
      | Some index ->
        sprintf
          "%d paths · %s%s%s"
          (List.length items)
          t.stage
          (if index.cached_unverified then " · CACHED UNVERIFIED" else " · observed cache")
          (if index.truncated then " · TRUNCATED" else "")
    in
    let status =
      Option.value_map
        (Option.first_some t.error t.pending_error)
        ~default:status
        ~f:(fun error -> "ERROR: " ^ error ^ " · " ^ status)
    in
    let query =
      if t.editing || t.pasting
      then
        (if t.pasting then "PASTE " else "FILTER ")
        ^ t.filter
        ^ "▏ · "
        ^ Option.value t.filter_notice ~default:"Enter/Esc finish · Ctrl-U clear"
      else
        sprintf
          "filter=%s · %s · corner=%s group=%s producer=%s near=%b"
          t.filter
          (match t.sort with
           | Numeric_ascending -> "value ↑"
           | Numeric_descending -> "value ↓"
           | Name -> "name")
          (Option.value t.corner ~default:"ALL")
          (Option.value t.group ~default:"ALL")
          (Option.value t.producer ~default:"ALL")
          t.near
    in
    (* The styled host path table reserves four header rows; on tiny panes both
       representations retain one actual path row. Keep keyboard paging identical. *)
    let header_height = Int.min 4 (Int.max 0 (height - 1)) in
    let viewport = Int.max 1 (height - header_height) in
    let position =
      List.findi items ~f:(fun _ item -> item.selected)
      |> Option.value_map ~default:0 ~f:fst
    in
    List.take
      (List.map
         (List.take
            [ status
            ; query
            ; "Enter detail · / filter · s sort · c/g/p axes · v near · t stage · r \
               refresh"
            ; "Value / unit · reported status · reported endpoints / path"
            ]
            header_height)
         ~f:Artifact_view.safe
       @
       if List.is_empty items
       then [ Artifact_view.safe (empty_paths_message t) ]
       else
         List.drop items (position / viewport * viewport)
         |> Fn.flip List.take viewport
         |> List.map ~f:(fun item -> item.label))
      (Int.max 0 height)
  | Detail | Context ->
    let lines =
      List.map (semantic_prefix ~presentation ?now ~pane ~width t) ~f:snd
      @
      if equal_pane pane Detail
      then
        List.mapi (detail_body t) ~f:(fun index line ->
          if index = 0 && String.is_prefix line ~prefix:"/"
          then Presentation.source_path ~compress:presentation.string_compression line
          else
            Presentation.report_source_header
              ~compress:presentation.string_compression
              line)
      else []
    in
    let lines =
      List.concat_map lines ~f:(fun line ->
        Artifact_view.wrap ~width (Artifact_view.safe line))
    in
    List.take
      (List.drop lines (Int.min scroll (Int.max 0 (List.length lines - height))))
      height
;;

let input
  ?(presentation = Tile_presentation.defaults)
  ~pane
  ~scroll
  ~width
  ~height
  (t : t)
  action
  =
  match pane, action with
  | _, Inspection_view.Back ->
    ( { t with
        requested = None
      ; detail = None
      ; info = false
      ; generation = t.generation + 1
      ; operation_key = None
      ; error = None
      ; pending_error = None
      }
    , scroll
    , None )
  | (Detail | Context), (Inspection_view.Up | Down | Page_up | Page_down) ->
    let delta =
      match action with
      | Up -> -1
      | Down -> 1
      | Page_up -> -Int.max 1 height
      | _ -> Int.max 1 height
    in
    let length =
      List.length (rows ~presentation ~pane ~scroll:0 ~width ~height:Int.max_value t)
    in
    let last = Int.max 0 (length - height) in
    t, Int.clamp_exn (Int.min scroll last + delta) ~min:0 ~max:last, None
  | _ ->
    (* A selected detail never steals the list's navigation mode. *)
    let browsing = { t with requested = None; detail = None; info = false; scroll = 0 } in
    let next, operation = Inspection_view.input ~width ~height browsing action in
    let next = Option.value next ~default:browsing in
    let changed = not (Option.equal String.equal next.selected t.selected) in
    let next =
      if changed && Option.is_none operation
      then { next with operation_key = None; error = None; pending_error = None }
      else if Option.is_some operation
      then next
      else
        { next with
          requested = t.requested
        ; detail = t.detail
        ; operation_key = t.operation_key
        }
    in
    next, scroll, operation
;;

let%test_unit "ten-row selected detail leads with provider text and retains full \
               provenance in Context"
  =
  let run = Fs0_fixture.run_a in
  let source =
    "{\"path\":\"/report/" ^ String.make 2048 's' ^ "\",\"row_id\":\"selected\"}"
  in
  let payload = String.make 3000 'x' in
  let row : Asic_inspection.Row.t =
    { id = "selected"
    ; name = "setup path " ^ String.make 200 'n'
    ; category = "path"
    ; producer = "sta"
    ; corner = Some "slow"
    ; group = Some "clk"
    ; value = Some (-0.125)
    ; unit_ = Some "ns"
    ; status = "violated"
    ; source
    ; fields = [ "startpoint", "in/Q"; "endpoint", "out/D"; "raw_payload", payload ]
    }
  in
  let index : Asic_inspection.Index.t =
    { run
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "source-digest"
    ; execution_file = "/execution.json"
    ; execution_sha256 = "execution-sha"
    ; rows = [ row ]
    ; diagnostics = [ "provider diagnostic" ]
    ; truncated = false
    ; cached_unverified = false
    ; analysis = None
    ; times = Evidence_time.Index.empty
    }
  in
  let snapshot = { Fs0_fixture.snapshot with inspections = [ index ] } in
  let t =
    Inspection_view.reconcile (create ~generation:1 ~run ~stage:"signoff") snapshot
  in
  let filtered = { t with filter = "nonexistent-path-filter"; cache = None } in
  let filtered_lines = rows ~pane:Paths ~scroll:0 ~width:120 ~height:10 filtered in
  assert (
    List.mem
      filtered_lines
      "No paths match the current filters (1 loaded)"
      ~equal:String.equal);
  let empty =
    { t with
      index = Some { index with rows = []; diagnostics = [ "report missing" ] }
    ; cache = None
    }
  in
  assert (
    String.equal
      (empty_paths_message empty)
      "No timing paths reported for stage signoff · report missing");
  assert (
    String.equal
      (empty_paths_message { empty with error = Some "captured source changed" })
      "ERROR: captured source changed");
  assert (
    String.is_prefix
      (empty_paths_message { empty with index = None })
      ~prefix:"No loaded index");
  let t, _, _ = input ~pane:Paths ~scroll:0 ~width:68 ~height:10 t Open in
  let pending = rows ~pane:Detail ~scroll:0 ~width:68 ~height:10 t in
  assert (List.exists pending ~f:(fun line -> String.is_prefix line ~prefix:"Pending:"));
  let detail : Asic_inspection.Detail.t =
    { run
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "source-digest"
    ; row_id = "selected"
    ; text = "ACTUAL PROVIDER DETAIL\ncell/A 0.1 ns\ncell/B 0.2 ns"
    ; error = None
    }
  in
  let t = Inspection_view.reconcile t { snapshot with inspection_details = [ detail ] } in
  let visible = rows ~pane:Detail ~scroll:0 ~width:68 ~height:10 t in
  let report_path =
    "/retained/timing-817177-2eeaceb51e3413c008ecd50516122412/reports/sta/max.rpt"
  in
  let report_text = report_path ^ "\n42: technical/cell/path 0.125029 ns" in
  let with_report = { t with detail = Some { detail with text = report_text } } in
  let compact_report =
    rows ~pane:Detail ~scroll:0 ~width:120 ~height:20 with_report
    |> String.concat ~sep:"\n"
  in
  assert (String.is_substring compact_report ~substring:"timi…2412/max.rpt");
  assert (not (String.is_substring compact_report ~substring:report_path));
  assert (
    String.is_substring compact_report ~substring:"42: technical/cell/path 0.125029 ns");
  let full_report =
    rows
      ~presentation:{ Tile_presentation.defaults with string_compression = false }
      ~pane:Detail
      ~scroll:0
      ~width:120
      ~height:20
      with_report
    |> String.concat ~sep:"\n"
  in
  assert (String.is_substring full_report ~substring:report_path);
  assert (String.equal (Option.value_exn with_report.detail).text report_text);
  assert (String.equal (List.nth_exn visible 4) "ACTUAL PROVIDER DETAIL");
  assert (
    List.exists visible ~f:(fun line -> String.is_substring line ~substring:"-0.125 ns"));
  assert (
    List.exists visible ~f:(fun line ->
      String.is_substring line ~substring:"in/Q → out/D"));
  assert (
    not
      (List.exists visible ~f:(fun line ->
         String.is_substring line ~substring:"Source:"
         || String.is_substring line ~substring:"raw_payload")));
  let context =
    rows
      ~presentation:{ Tile_presentation.defaults with string_compression = false }
      ~pane:Context
      ~scroll:0
      ~width:68
      ~height:Int.max_value
      t
    |> String.concat ~sep:""
  in
  List.iter
    [ source; payload; "source-digest"; "execution-sha"; row.name; "provider diagnostic" ]
    ~f:(fun value -> assert (String.is_substring context ~substring:value));
  let failed =
    Inspection_view.reconcile
      t
      { snapshot with
        inspection_details = [ { detail with error = Some "detail unavailable" } ]
      }
  in
  assert (
    List.mem
      (rows ~pane:Detail ~scroll:0 ~width:68 ~height:10 failed)
      "ERROR: detail unavailable"
      ~equal:String.equal)
;;

let%test_unit "retained attachment preserves intent until index and attaches only exact \
               detail"
  =
  let run = Fs0_fixture.run_a in
  let row : Asic_inspection.Row.t =
    { id = "saved-row"
    ; name = "endpoint/Q"
    ; category = "path"
    ; producer = "sta"
    ; corner = None
    ; group = None
    ; value = Some (-1.)
    ; unit_ = Some "ns"
    ; status = "violated"
    ; source = "source"
    ; fields = []
    }
  in
  let index : Asic_inspection.Index.t =
    { run
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "digest"
    ; execution_file = "/execution"
    ; execution_sha256 = "sha"
    ; rows = [ row ]
    ; diagnostics = []
    ; truncated = false
    ; cached_unverified = true
    ; analysis = None
    ; times = Evidence_time.Index.empty
    }
  in
  let detail : Asic_inspection.Detail.t =
    { run
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "digest"
    ; row_id = row.id
    ; text = "retained detail"
    ; error = None
    }
  in
  let view =
    { (create ~generation:0 ~run ~stage:"signoff") with selected = Some row.id }
  in
  let pending = attach_retained view Fs0_fixture.snapshot in
  assert (Option.equal String.equal pending.selected (Some row.id));
  let snapshot =
    { Fs0_fixture.snapshot with
      inspections = [ index ]
    ; inspection_details = [ { detail with run = Fs0_fixture.run_b } ]
    }
  in
  let attached = attach_retained pending snapshot in
  assert (Option.is_some attached.index && Option.is_none attached.detail);
  let attached =
    attach_retained attached { snapshot with inspection_details = [ detail ] }
  in
  assert (String.equal (Option.value_exn attached.detail).text "retained detail");
  assert (Option.value_exn attached.index).cached_unverified;
  assert (Option.equal String.equal attached.operation_key view.operation_key);
  let replaced =
    attach_retained
      attached
      { snapshot with
        inspections = [ { index with source_digest = "replacement" } ]
      ; inspection_details = [ detail ]
      }
  in
  assert (Option.is_none replaced.detail)
;;

let%test_unit "Timing investigation layout fits 120x40 without a default vertical \
               checklist"
  =
  let module P = Hardcaml_workbench_workspaces in
  let definition = P.Timing.definition in
  let kinds = List.map definition.tiles ~f:(fun tile -> tile.P.Common.kind) in
  assert (not (List.mem kinds "stage-checklist" ~equal:String.equal));
  match P.Layout.compute definition ~width:120 ~height:38 ~kinds with
  | Compact -> assert false
  | Grid cells ->
    let geometry kind =
      List.nth_exn
        cells
        (List.findi_exn kinds ~f:(fun _ value -> String.equal value kind) |> fst)
    in
    let nav = geometry "workspace-tabs"
    and session = geometry "live-status"
    and selector = geometry "run-selector"
    and paths = geometry "timing-paths"
    and detail = geometry "timing-detail"
    and context = geometry "timing-context" in
    assert (nav.height = 1);
    assert (session.y = selector.y && session.width = 40 && selector.width = 80);
    assert (paths.y >= session.y + session.height);
    assert (paths.width = 60 && detail.width = 60);
    assert (
      detail.x = context.x && detail.y = paths.y && context.y >= detail.y + detail.height);
    assert (detail.height >= 10 && context.height >= 8);
    List.iter cells ~f:(fun cell ->
      assert (cell.x + cell.width <= 120 && cell.y + cell.height <= 38))
;;

let%test_unit "Timing weighted layout remains bounded at narrow and roomy sizes" =
  let module P = Hardcaml_workbench_workspaces in
  let definition = P.Timing.definition in
  let kinds = List.map definition.tiles ~f:(fun tile -> tile.P.Common.kind) in
  List.iter [ 30; 60; 79; 80; 96; 120; 180 ] ~f:(fun width ->
    match P.Layout.compute definition ~width ~height:38 ~kinds with
    | Compact -> ()
    | Grid cells ->
      List.iter cells ~f:(fun cell ->
        assert (cell.x >= 0 && cell.y >= 0 && cell.width > 0 && cell.height > 0);
        assert (cell.x + cell.width <= width && cell.y + cell.height <= 38));
      List.iteri cells ~f:(fun i a ->
        List.iter
          (List.drop cells (i + 1))
          ~f:(fun b ->
            assert (
              a.x + a.width <= b.x
              || b.x + b.width <= a.x
              || a.y + a.height <= b.y
              || b.y + b.height <= a.y))))
;;

let%test_unit "cooperating panes select actual paths; browsing is local and details exact"
  =
  let run = Fs0_fixture.run_a in
  let row id value : Asic_inspection.Row.t =
    { id
    ; category = "path"
    ; producer = "sta"
    ; corner = Some "slow"
    ; group = Some "clk"
    ; name = id
    ; value = Some value
    ; unit_ = Some "ns"
    ; status = "violated"
    ; source = "/report"
    ; fields = [ "endpoint", id ^ "/Q" ]
    }
  in
  let index : Asic_inspection.Index.t =
    { run
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "digest"
    ; execution_file = "/execution"
    ; execution_sha256 = "sha"
    ; rows = [ row "a" (-1.); row "b" 0. ]
    ; diagnostics = []
    ; truncated = false
    ; cached_unverified = false
    ; analysis = None
    ; times = Evidence_time.Index.empty
    }
  in
  let snapshot = { Fs0_fixture.snapshot with inspections = [ index ] } in
  let original =
    Inspection_view.reconcile (create ~generation:1 ~run ~stage:"signoff") snapshot
  in
  let precise_index =
    { index with
      rows =
        [ row "higher" 0.125029
        ; row "lower" 0.125021
        ; row "tiny-negative" (-0.000029)
        ; row "zero" 0.
        ]
    }
  in
  let precise =
    Inspection_view.reconcile
      (create ~generation:1 ~run ~stage:"signoff")
      { snapshot with inspections = [ precise_index ] }
  in
  let items = path_items precise in
  [%test_result: string list]
    (List.map items ~f:(fun item -> item.row.id))
    ~expect:[ "tiny-negative"; "zero"; "lower"; "higher" ];
  assert (String.is_substring (List.hd_exn items).label ~substring:"-0.000");
  List.iter (List.drop items 2) ~f:(fun item ->
    assert (String.is_substring item.label ~substring:"0.125"));
  assert (Option.equal Float.equal (List.last_exn items).row.value (Some 0.125029));
  let full_precision =
    path_items
      ~presentation:{ Tile_presentation.defaults with decimal_places = 9 }
      precise
  in
  assert (
    String.is_substring (List.last_exn full_precision).label ~substring:"0.125029000");
  assert (Asic_inspection.Index.equal (Option.value_exn precise.index) precise_index);
  let moved, _, op = input ~pane:Paths ~scroll:0 ~width:60 ~height:12 original Down in
  assert (Option.is_none op);
  assert (String.equal (Option.value_exn (selection moved)).row_id "b");
  assert (String.equal (Option.value_exn (selection original)).row_id "a");
  assert (
    List.exists (rows ~pane:Detail ~scroll:0 ~width:80 ~height:30 moved) ~f:(fun line ->
      String.is_substring line ~substring:"b/Q"));
  let opened, _, operation =
    input ~pane:Paths ~scroll:0 ~width:60 ~height:12 moved Open
  in
  let opened = { opened with workspace_epoch = Some "workspace-A:selection-epoch" } in
  let ticket = Inspection_view.capture opened (Option.value_exn operation) in
  (match operation with
   | Some (Inspect_detail { row_id; source_digest; _ }) ->
     assert (String.equal row_id "b" && String.equal source_digest "digest")
   | _ -> assert false);
  let moved, _, op = input ~pane:Paths ~scroll:0 ~width:60 ~height:12 opened Up in
  assert (Option.is_none op && Option.is_none moved.requested);
  assert (Option.is_none moved.operation_key && Option.is_none moved.pending_error);
  assert (
    Option.is_none (Inspection_view.apply_response moved ticket (Error "late")).error);
  let independent, scroll, op =
    input ~pane:Detail ~scroll:0 ~width:60 ~height:3 opened Down
  in
  assert (scroll = 1 && Option.is_none op);
  assert (Option.equal String.equal independent.selected opened.selected);
  assert (
    Option.is_none
      (Inspection_view.apply_response
         { opened with workspace_epoch = Some "workspace-B:selection-epoch" }
         ticket
         (Error "moved tile receipt"))
        .error);
  let closed, _, operation =
    input ~pane:Detail ~scroll:4 ~width:60 ~height:3 opened Back
  in
  assert (Option.is_none operation && Option.is_none closed.requested);
  assert (Option.is_some closed.index);
  let detail : Asic_inspection.Detail.t =
    { run
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "digest"
    ; row_id = "b"
    ; text = "cached selected detail"
    ; error = None
    }
  in
  let late =
    Inspection_view.reconcile closed { snapshot with inspection_details = [ detail ] }
  in
  assert (Option.is_none late.detail);
  assert (
    Option.is_none
      (Inspection_view.apply_response late ticket (Error "closed reader receipt")).error);
  let changed_row = { (List.last_exn index.rows) with source = "/replacement-report" } in
  let replaced =
    Inspection_view.reconcile
      opened
      { snapshot with
        inspections = [ { index with rows = [ List.hd_exn index.rows; changed_row ] } ]
      ; inspection_details = [ detail ]
      }
  in
  assert (Option.is_none replaced.requested && Option.is_none replaced.detail);
  assert (
    Option.is_none
      (Inspection_view.apply_response replaced ticket (Error "old same-id row receipt"))
        .error);
  let loaded =
    Inspection_view.reconcile
      opened
      { snapshot with
        inspection_details =
          [ { detail with
              text = String.concat ~sep:"\n" (List.init 100 ~f:(fun i -> Int.to_string i))
            }
          ]
      }
  in
  let bottom, scroll =
    List.fold (List.init 1000 ~f:Fn.id) ~init:(loaded, 0) ~f:(fun (t, scroll) _ ->
      let t, scroll, operation = input ~pane:Detail ~scroll ~width:60 ~height:3 t Down in
      assert (Option.is_none operation);
      t, scroll)
  in
  let _, up, _ = input ~pane:Detail ~scroll ~width:60 ~height:3 bottom Up in
  assert (up = scroll - 1);
  assert (Option.equal String.equal bottom.selected opened.selected);
  let refreshing, _, operation =
    input ~pane:Paths ~scroll:0 ~width:60 ~height:12 opened Refresh
  in
  let refresh_ticket = Inspection_view.capture refreshing (Option.value_exn operation) in
  let stale =
    Inspection_view.reconcile
      opened
      { snapshot with inspections = [ { index with source_digest = "new" } ] }
  in
  assert (Option.is_none stale.detail && Option.is_none stale.requested);
  assert (
    Option.is_none
      (Inspection_view.apply_response stale ticket (Error "old digest")).error);
  let refreshed =
    Inspection_view.reconcile
      refreshing
      { snapshot with inspections = [ { index with source_digest = "new" } ] }
  in
  assert (
    Option.is_none
      (Inspection_view.apply_response
         refreshed
         refresh_ticket
         (Error "old index receipt"))
        .error)
;;

let%test_unit "WB-006: evidence times keep their meanings through refresh, cache and \
               carry-forward"
  =
  let now = Time_ns.of_string_with_utc_offset "2026-10-19 15:30:00Z" in
  let ago minutes =
    Timestamp.of_time_ns (Time_ns.sub now (Time_ns.Span.of_min minutes))
  in
  let row id producer : Asic_inspection.Row.t =
    { id
    ; category = "path"
    ; producer
    ; corner = Some "slow"
    ; group = Some "clk"
    ; name = id
    ; value = Some 0.25
    ; unit_ = Some "ns"
    ; status = "met"
    ; source = "{}"
    ; fields = []
    }
  in
  let routed = "OpenROAD.DetailedRouting@9-route"
  and sta = "OpenROAD.STAPostPNR@11-sta" in
  let index : Asic_inspection.Index.t =
    { run = Fs0_fixture.run_a
    ; execution_file = "/exact/execution.json"
    ; execution_sha256 = String.make 64 'a'
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = String.make 64 'b'
    ; rows = [ row "carried" routed; row "fresh" sta ]
    ; diagnostics = []
    ; truncated = false
    ; cached_unverified = false
    ; analysis = None
    ; times =
        Evidence_time.Index.with_validated
          { production = [ routed, Supplied { at = ago (60. *. 50.) } ]
          ; observations = []
          }
          ~at:(ago 90.)
    }
  in
  let snapshot index = { Fs0_fixture.snapshot with inspections = [ index ] } in
  let view =
    Inspection_view.reconcile
      (create ~generation:1 ~run:Fs0_fixture.run_a ~stage:"signoff")
      (snapshot index)
  in
  let has lines substring = List.exists lines ~f:(String.is_substring ~substring) in
  let header view = Inspection_view.rows ~now ~width:200 ~height:10 view in
  assert (has (header view) "produced 1/2 producers known · validated 1h 30m ago");
  (* #1: refreshing unchanged bytes moves only the labelled validation time. *)
  let refreshed =
    { index with times = Evidence_time.Index.with_validated index.times ~at:(ago 1.) }
  in
  let after = Inspection_view.reconcile view (snapshot refreshed) in
  assert (after.generation = view.generation);
  assert (has (header after) "validated 1m ago");
  let context view = rows ~now ~pane:Context ~scroll:0 ~width:400 ~height:100 view in
  let production lines = List.filter lines ~f:(String.is_prefix ~prefix:"Produced (") in
  assert (List.equal String.equal (production (context view)) (production (context after)));
  assert (has (context after) "Validated by Workbench: 2026-10-19 15:29 UTC (1m ago)");
  assert (has (context view) "Validated by Workbench: 2026-10-19 14:00 UTC (1h 30m ago)");
  (* #2: the producer without a supplied time stays unknown, whatever else is known. *)
  let selected id view = { view with Inspection_view.selected = Some id } in
  assert (has (context (selected "fresh" after)) ("Produced: unknown · by " ^ sta));
  (* #3: the carried-forward row keeps its own producer's time and age. *)
  assert (
    has
      (context (selected "carried" after))
      ("Produced: 2026-10-17 13:30 UTC (2d ago) · by " ^ routed));
  (* #4: a future value is flagged, with its zone, never as a negative age. *)
  let future =
    { refreshed with
      times =
        { refreshed.times with production = [ routed, Supplied { at = ago (-15.) } ] }
    }
  in
  let future_view = Inspection_view.reconcile after (snapshot future) in
  assert (
    has
      (context (selected "carried" future_view))
      "Produced: 2026-10-19 15:45 UTC (FUTURE +15m: clock skew?)");
  assert (not (has (context (selected "carried" future_view)) "-15"));
  (* #5: cached-unverified status is shown independently of a recent timestamp. *)
  let cached =
    Inspection_view.reconcile after (snapshot { refreshed with cached_unverified = true })
  in
  assert (has (header cached) "CACHED UNVERIFIED");
  assert (has (header cached) "validated 1m ago");
  assert (has (context cached) "CACHED UNVERIFIED");
  (* The memoized detail page is rebuilt when only the times change. *)
  let detail view =
    let view =
      Inspection_view.clamp ~now { view with info = true } ~width:200 ~height:40
    in
    Array.to_list (Option.value_exn view.detail_cache).lines
  in
  let before =
    Inspection_view.clamp ~now { view with info = true } ~width:200 ~height:40
  in
  let rebased = Inspection_view.reconcile before (snapshot refreshed) in
  assert (has (detail rebased) "(1m ago)");
  assert (has (detail view) "(1h 30m ago)");
  (* The clock alone must invalidate memoized ages, even with identical metadata. *)
  let memoized =
    Inspection_view.clamp ~now { after with info = true } ~width:200 ~height:40
  in
  let later = Time_ns.add now (Time_ns.Span.of_min 1.) in
  let advanced = Inspection_view.clamp ~now:later memoized ~width:200 ~height:40 in
  assert (has (Array.to_list (Option.value_exn advanced.detail_cache).lines) "(2m ago)");
  assert (phys_equal advanced.index memoized.index);
  assert (
    has
      (rows ~now:later ~pane:Context ~scroll:0 ~width:400 ~height:100 after)
      "2026-10-19 15:29 UTC (2m ago)")
;;
