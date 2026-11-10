open! Core
open Hardcaml_workbench_protocol

module Mode = struct
  type t =
    | Summary
    | Cells
    | Details
    | Metrics
    | Evidence
  [@@deriving equal, sexp]
end

module State = struct
  type identity = Run_ref.t * string [@@deriving equal]

  type cache =
    { source : Asic.Summary.t
    ; projection : Synthesis.t
    ; filter : string
    ; sort : Synthesis.Sort.t
    ; rows : Synthesis.Row.t list
    }

  type t =
    { mode : Mode.t
    ; sort : Synthesis.Sort.t
    ; selected : string option
    ; identity : identity option
    ; offset : int
    ; cache : cache option
    }

  let empty =
    { mode = Summary
    ; sort = Count_desc
    ; selected = None
    ; identity = None
    ; offset = 0
    ; cache = None
    }
  ;;

  let mode t = t.mode
  let sort t = t.sort
  let selected t = t.selected
  let cell_rows t = Option.value_map t.cache ~default:[] ~f:(fun cache -> cache.rows)

  let update_cache t ~summary ~filter ~changed =
    Option.map summary ~f:(fun source ->
      (* Metadata updates do not require decoding/sorting the cells again. Also compare
         cell data, since a same-digest cached summary can be updated. *)
      let reusable =
        Option.filter t.cache ~f:(fun cache ->
          (not changed)
          && (phys_equal source cache.source
              || (Option.equal Int.equal source.cell_count cache.source.cell_count
                  && List.equal
                       (fun (name_a, count_a) (name_b, count_b) ->
                         String.equal name_a name_b && Int.equal count_a count_b)
                       source.cells
                       cache.source.cells)))
      in
      let projection =
        Option.value_map reusable ~default:None ~f:(fun cache -> Some cache.projection)
        |> function
        | Some projection -> projection
        | None -> Synthesis.project source
      in
      let rows =
        match reusable with
        | Some cache
          when String.equal filter cache.filter && Synthesis.Sort.equal t.sort cache.sort
          -> cache.rows
        | _ -> Synthesis.rows projection ~filter ~sort:t.sort
      in
      { source; projection; filter; sort = t.sort; rows })
  ;;

  let reconcile t ~summary ~filter =
    let identity =
      Option.map summary ~f:(fun (s : Asic.Summary.t) -> s.run, s.source_digest)
    in
    let changed = not (Option.equal equal_identity t.identity identity) in
    let cache = update_cache t ~summary ~filter ~changed in
    let candidates = Option.value_map cache ~default:[] ~f:(fun cache -> cache.rows) in
    let selected =
      if changed && Option.is_some t.identity
      then None
      else (
        match t.selected with
        | Some name when List.exists candidates ~f:(fun row -> String.equal row.name name)
          -> t.selected
        | _ -> List.hd candidates |> Option.map ~f:(fun row -> row.name))
    in
    let mode =
      if Mode.equal t.mode Details
         && (changed
             || (not (Option.equal String.equal selected t.selected))
             || Option.is_none selected)
      then Mode.Cells
      else t.mode
    in
    { t with
      identity
    ; cache
    ; selected
    ; mode
    ; offset = (if changed || not (Mode.equal mode t.mode) then 0 else t.offset)
    }
  ;;

  let shift value delta =
    Int64.(max zero (min (of_int Int.max_value) (of_int value + of_int delta)))
    |> Int64.to_int_exn
  ;;

  let move t ~summary ~filter ~delta =
    let t = reconcile t ~summary ~filter in
    let candidates = cell_rows t in
    let current =
      List.findi candidates ~f:(fun _ row ->
        Option.equal String.equal (Some row.name) t.selected)
      |> Option.map ~f:fst
    in
    let index =
      match current with
      | None -> if delta < 0 then Int.max 0 (List.length candidates - 1) else 0
      | Some index -> Int.min (List.length candidates - 1) (shift index delta)
    in
    { t with
      selected = List.nth candidates index |> Option.map ~f:(fun row -> row.name)
    ; offset = 0
    }
  ;;

  let set_mode t mode = { t with mode; offset = 0 }

  let back t =
    set_mode
      t
      (match t.mode with
       | Summary -> Summary
       | Cells -> Summary
       | Metrics -> Summary
       | Details | Evidence -> Cells)
  ;;

  let set_sort t sort = { t with sort; offset = 0 }
  let cycle_sort t = set_sort t (Synthesis.Sort.next t.sort)

  let scroll t ~delta ~max_offset =
    let maximum = Int.max 0 max_offset in
    { t with offset = Int.min maximum (shift (Int.min maximum t.offset) delta) }
  ;;
end

(** Decode UTF-8 only to ask Bonsai/Notty for terminal cell widths. No byte-based
    truncation and no local wide-character tables. Controls occupy a safe visible
    placeholder; producer content is otherwise retained verbatim in Evidence. *)
let wrap_line ~width text =
  let width = Int.max 1 width in
  let chunks = ref [] in
  let buffer = Buffer.create (String.length text) in
  let cells = ref 0 in
  let flush () =
    chunks := Buffer.contents buffer :: !chunks;
    Buffer.clear buffer;
    cells := 0
  in
  let rec loop offset =
    if offset < String.length text
    then (
      let decoded = Stdlib.String.get_utf_8_uchar text offset in
      let uchar = Stdlib.Uchar.utf_decode_uchar decoded in
      let length = Stdlib.Uchar.utf_decode_length decoded in
      let scalar = Stdlib.Uchar.to_int uchar in
      let unsafe = scalar < 32 || (scalar >= 127 && scalar < 160) in
      let size =
        if unsafe then 1 else Int.max 0 (Bonsai_term.View.uchar_tty_width uchar)
      in
      if !cells + size > width && !cells > 0 then flush ();
      if size > width
      then (
        Buffer.add_string buffer "?";
        incr cells)
      else (
        Buffer.add_string
          buffer
          (if unsafe then "?" else String.sub text ~pos:offset ~len:length);
        cells := !cells + size);
      loop (offset + length))
  in
  loop 0;
  flush ();
  List.rev !chunks
;;

let wrap ~width text = String.split text ~on:'\n' |> List.concat_map ~f:(wrap_line ~width)
let clip ~width text = if width <= 0 then "" else List.hd_exn (wrap ~width text)

let freshness = function
  | Asic.Summary.Freshness.Validated -> "Validated"
  | Cached_unverified -> "Cached_unverified"
  | Missing_source -> "Missing_source"
  | Refresh_failed _ -> "Refresh_failed"
;;

let total_text = function
  | Synthesis.Total.Unknown -> "unknown (not reported)"
  | Zero -> "0 (reported zero; shares unavailable)"
  | Positive n -> Int.to_string n
  | Invalid n -> sprintf "%d (invalid reported total)" n
;;

let coverage_text (projection : Synthesis.t) =
  let reason =
    match projection.coverage with
    | Unknown_total -> "reported total unknown"
    | Invalid_total -> "reported total invalid"
    | No_breakdown -> "no cell breakdown reported"
    | Matches -> "matches reported total"
    | Mismatch -> "MISMATCH with reported total"
    | Overflow -> "OVERFLOW (counts unavailable)"
  in
  if projection.breakdown_overflow
  then "Breakdown: " ^ reason
  else sprintf "Breakdown: %Ld cells; %s" projection.breakdown_count reason
;;

let count_text (row : Synthesis.Row.t) =
  if row.count_overflow then "overflow" else Int64.to_string row.count
;;

let share_text = function
  | None -> "unavailable"
  | Some percentage -> sprintf "%.2f%% of reported total" percentage
;;

let sort_text = function
  | Synthesis.Sort.Count_desc -> "Count descending"
  | Count_asc -> "Count ascending"
  | Name_asc -> "Cell type ascending"
  | Name_desc -> "Cell type descending"
;;

let metric_value (metric : Asic.Metric.t) =
  match metric.value with
  | None -> "unavailable"
  | Some value when not (Float.is_finite value) -> "invalid (non-finite)"
  | Some value when Float.(value < 0.) -> "invalid (negative)"
  | Some _ when not (String.equal metric.availability "available") -> "unavailable"
  | Some value ->
    sprintf "%g%s" value (Option.value_map metric.unit_ ~default:"" ~f:(( ^ ) " "))
;;

let metric_line (metric : Asic.Metric.t) =
  let label = if String.is_empty metric.label then metric.key else metric.label in
  let availability =
    if String.is_empty metric.availability
    then "availability not reported"
    else metric.availability
  in
  sprintf "%s: %s [%s]" label (metric_value metric) availability
;;

let semantic_metrics_lines (summary : Asic.Summary.t) =
  List.map
    ([ "Synthesis metrics | j/k scroll | e Evidence | Esc Summary" ]
     @ (if List.is_empty summary.metrics
        then [ "Metrics unavailable in cached summary; explicit Refresh needed" ]
        else List.map summary.metrics ~f:metric_line)
     @ [ "Scope: synthesis resources/diagnostics, not physical area or DRC/LVS" ])
    ~f:Evidence_style.plain
  @ [ Evidence_style.freshness summary.freshness
    ; Evidence_style.plain
        "Provenance: accumulated checkpoint-boundary reports; see Evidence"
    ; Evidence_style.fact ~label:"Acceptance (reported): " Verdict summary.acceptance
    ; Evidence_style.plain "Zero diagnostic counts do not imply signoff"
    ]
;;

let metrics_lines summary =
  List.map (semantic_metrics_lines summary) ~f:Evidence_style.text
;;

let checks_lines (summary : Asic.Summary.t) =
  let diagnostic_keys =
    [ "design__instance_unmapped__count"
    ; "synthesis__check_error__count"
    ; "design__inferred_latch__count"
    ; "design__lint_error__count"
    ; "design__lint_warning__count"
    ; "design__lint_timing_construct__count"
    ]
  in
  let diagnostics =
    List.filter summary.metrics ~f:(fun metric ->
      List.mem diagnostic_keys metric.key ~equal:String.equal)
  in
  [ "Checks: synthesis diagnostic counters (not DRC/LVS)" ]
  @ (if List.is_empty diagnostics
     then [ "Synthesis diagnostics unavailable; explicit Refresh needed for old caches" ]
     else List.map diagnostics ~f:metric_line)
  @ [ "Zero diagnostic counts do not imply signoff"
    ; "Acceptance (reported): " ^ summary.acceptance
    ; "Checkpoint-boundary provenance: synthesis Metrics / Evidence"
    ; "DRC/LVS: no terminal verification result imported"
    ]
;;

let table ~state ~(projection : Synthesis.t) ~width ~height =
  let candidates = State.cell_rows state in
  let header = clip ~width "  Count  Cell type" in
  let available = Int.max 0 (height - 1) in
  let selected_index =
    List.findi candidates ~f:(fun _ row ->
      Option.equal String.equal (Some row.name) (State.selected state))
    |> Option.value_map ~default:0 ~f:fst
  in
  (* The cursor is always visible, including after resize, sorting, or filtering. *)
  let start = Int.max 0 (selected_index - available + 1) in
  let body =
    if List.is_empty candidates
    then
      [ (if List.is_empty projection.rows
         then "No cell breakdown reported"
         else "No cells match. Ctrl-U clears filter")
      ]
    else
      List.drop candidates start
      |> Fn.flip List.take available
      |> List.map ~f:(fun row ->
        let marker =
          if Option.equal String.equal (Some row.name) (State.selected state)
          then ">"
          else " "
        in
        sprintf "%s %5s  %s" marker (count_text row) row.name)
  in
  List.take (header :: List.map body ~f:(clip ~width)) (Int.max 0 height)
;;

let page ~state ~width ~height lines =
  let lines = List.concat_map lines ~f:(wrap ~width) in
  let start = Int.min state.State.offset (Int.max 0 (List.length lines - height)) in
  List.take (List.drop lines start) height
;;

let rows state ~summary ~filter ~width ~height =
  if width <= 0 || height <= 0
  then []
  else (
    let state = State.reconcile state ~summary ~filter in
    match summary with
    | None ->
      let message =
        if Mode.equal (State.mode state) Metrics
        then "Synthesis metrics unavailable (no cached summary); explicit Refresh needed"
        else "Synthesis summary unavailable (no cached data)"
      in
      List.take (wrap ~width message) height
    | Some summary ->
      let projection = (Option.value_exn state.State.cache).projection in
      (match State.mode state with
       | Summary ->
         let intro =
           ([ "Cell count: " ^ total_text projection.total
            ; "Freshness: " ^ freshness summary.freshness
            ]
            @
            if height < 10
            then []
            else
              List.find summary.metrics ~f:(fun metric ->
                String.equal metric.key "design__instance__area")
              |> Option.to_list
              |> List.map ~f:(fun metric ->
                "Synthesis resource area (mapped cells): " ^ metric_value metric))
           |> List.map ~f:(clip ~width)
         in
         let footer =
           (* Count and freshness, then the table, have priority over metadata. *)
           if height >= 8
           then
             [ coverage_text projection
             ; "Producer: provider checkpoint (inspect Evidence)"
             ; "Enter table/detail | m metrics | / filter | s sort | e evidence"
             ]
           else if height >= 6
           then [ coverage_text projection ]
           else []
         in
         List.take intro height
         @ table
             ~state
             ~projection
             ~width
             ~height:(height - List.length intro - List.length footer)
         @ List.map footer ~f:(clip ~width)
       | Cells ->
         let heading = "Cells | " ^ sort_text (State.sort state) in
         let filter_line =
           if String.is_empty filter
           then []
           else
             [ sprintf
                 "Filter: %S (%d matches)"
                 filter
                 (List.length (State.cell_rows state))
             ]
         in
         let headings =
           if height <= 3 && not (List.is_empty filter_line)
           then filter_line
           else heading :: filter_line
         in
         let footer =
           if height >= 5
           then [ "j/k select | Enter inspect | / filter | s sort | Esc back" ]
           else []
         in
         List.take (List.map headings ~f:(clip ~width)) height
         @ table
             ~state
             ~projection
             ~width
             ~height:(height - List.length headings - List.length footer)
         @ List.map footer ~f:(clip ~width)
       | Details ->
         (match
            List.find projection.rows ~f:(fun row ->
              Option.equal String.equal (Some row.name) (State.selected state))
          with
          | None -> page ~state ~width ~height [ "No cell selected" ]
          | Some row ->
            page
              ~state
              ~width
              ~height
              [ "Cell type: " ^ row.name
              ; "Count: " ^ count_text row
              ; "Share: " ^ share_text row.share
              ; "Reported total: " ^ total_text projection.total
              ; coverage_text projection
              ; "Source: cached summary.cells; execution reference in Evidence"
              ; "j/k scroll | e full evidence | Esc cell table"
              ])
       | Metrics -> page ~state ~width ~height (metrics_lines summary)
       | Evidence ->
         let freshness_detail =
           match summary.freshness with
           | Refresh_failed reason -> [ "Refresh failure: " ^ reason ]
           | Validated | Cached_unverified | Missing_source -> []
         in
         page
           ~state
           ~width
           ~height
           ([ "Synthesis evidence (cached summary; j/k scroll, Esc back)"
            ; "Backend: " ^ Backend_id.to_string summary.run.backend
            ; "Run: " ^ summary.run.id
            ; "Run reference: " ^ Sexp.to_string_hum (Run_ref.sexp_of_t summary.run)
            ; "Source digest: " ^ summary.source_digest
            ; "Execution file: " ^ summary.execution_file
            ; "Plan identity: "
              ^ Option.value summary.plan_identity ~default:"not reported"
            ]
            @ Evidence_time_view.summary_lines summary.observed_at
            @ [ "Freshness: " ^ freshness summary.freshness
              ; "Completion (reported): " ^ summary.completion
              ; "Acceptance (reported): " ^ summary.acceptance
              ; "Reported total: " ^ total_text projection.total
              ; coverage_text projection
              ]
            @ freshness_detail
            @ List.map summary.timing ~f:(fun (name, value, unit_) ->
              sprintf "Timing (reported): %s = %g %s" name value unit_)
            @ [ "Checkpoint-boundary provenance (accumulated reported metric sources)"
              ; "Boundaries are evidence scope, not stage completion or acceptance"
              ; "Zero diagnostic counts do not imply signoff; no DRC/LVS verdict inferred"
              ]
            @ (if List.is_empty summary.metrics
               then [ "Metrics unavailable in cached summary; explicit Refresh needed" ]
               else
                 List.concat_map summary.metrics ~f:(fun metric ->
                   [ "Metric key: " ^ metric.key
                   ; "Metric label (reported): " ^ metric.label
                   ; "Metric value (reported): "
                     ^ Option.value_map
                         metric.value
                         ~default:"not reported"
                         ~f:(sprintf "%g")
                   ; "Metric unit (reported): "
                     ^ Option.value metric.unit_ ~default:"not reported"
                   ; "Metric availability (reported): " ^ metric.availability
                   ; "Metric source (full): "
                     ^ Option.value metric.source ~default:"not reported"
                   ]))
            @ [ "Producer (raw):"; summary.producer ])))
;;

(** The Summary layout fixes freshness immediately after cell count; construct this row
    from the typed source rather than classifying rendered/provider text. Cells, metrics
    and raw evidence are never keyword-colored. *)
let semantic_rows state ~summary ~filter ~width ~height =
  let state = State.reconcile state ~summary ~filter in
  match summary, State.mode state with
  | Some summary, Metrics ->
    Evidence_style.page
      ~width
      ~height
      ~offset:state.offset
      (semantic_metrics_lines summary)
  | Some summary, Summary ->
    rows state ~summary:(Some summary) ~filter ~width ~height
    |> List.mapi ~f:(fun index line ->
      if index = 1
      then Evidence_style.clip ~width (Evidence_style.freshness summary.freshness)
      else Evidence_style.plain line)
  | _ -> rows state ~summary ~filter ~width ~height |> List.map ~f:Evidence_style.plain
;;

let scroll state ~summary ~filter ~width ~height ~delta =
  let state = State.reconcile state ~summary ~filter in
  match State.mode state with
  | Summary | Cells -> state
  | Details | Metrics | Evidence ->
    let content =
      rows { state with offset = 0 } ~summary ~filter ~width ~height:Int.max_value
    in
    State.scroll
      state
      ~delta
      ~max_offset:
        (if width <= 0 || height <= 0 then 0 else Int.max 0 (List.length content - height))
;;

module%test Tests = struct
  let summary
    ?(id = "run-a")
    ?(digest = "digest-a")
    ?(total = Some 10)
    ?(cells = [ "alpha", 4; "beta", 6 ])
    ?(metrics = [])
    ()
    : Asic.Summary.t
    =
    { run = { backend = Backend_id.of_string "asic"; id; build = None; label = None }
    ; source_digest = digest
    ; execution_file = "/private/evidence/execution.json"
    ; plan_identity = Some "plan-a"
    ; cell_count = total
    ; cells
    ; timing = []
    ; metrics
    ; terminal = None
    ; timing_analysis = None
    ; completion = "reported completion"
    ; acceptance = "reported acceptance"
    ; producer = "{\"raw-provider-sentinel\":\"untouched\"}"
    ; observed_at = "2026-10-15"
    ; freshness = Cached_unverified
    }
  ;;

  let ready summary =
    State.reconcile State.empty ~summary:(Some summary) ~filter:""
    |> fun t -> State.reconcile t ~summary:(Some summary) ~filter:""
  ;;

  let%test_unit "evidence paging stores the viewport bound and reverses after resize" =
    let s = summary () in
    let initial = State.set_mode (ready s) Evidence in
    let move state ~width ~height delta =
      scroll state ~summary:(Some s) ~filter:"" ~width ~height ~delta
    in
    let view state ~width ~height =
      rows state ~summary:(Some s) ~filter:"" ~width ~height
    in
    let bottom = move initial ~width:20 ~height:3 Int.max_value in
    let stopped = move bottom ~width:20 ~height:3 100 in
    assert (stopped.offset = bottom.offset);
    let reverse = move stopped ~width:20 ~height:3 (-1) in
    assert (reverse.offset = bottom.offset - 1);
    assert (
      List.equal
        String.equal
        (List.drop (view reverse ~width:20 ~height:3) 1)
        (List.take (view bottom ~width:20 ~height:3) 2));
    let resized_reverse = move bottom ~width:100 ~height:8 (-1) in
    assert (
      List.equal
        String.equal
        (List.drop (view resized_reverse ~width:100 ~height:8) 1)
        (List.take (view bottom ~width:100 ~height:8) 7));
    assert (initial.offset = 0)
  ;;

  let metric
    ?(value = Some 12.5)
    ?(unit_ = Some "um^2")
    ?(availability = "available")
    ?(source = Some "/private/checkpoints/synthesis/resources.json#area")
    key
    label
    : Asic.Metric.t
    =
    { key; label; value; unit_; availability; source }
  ;;

  let render_mode s mode =
    rows
      (State.set_mode (ready s) mode)
      ~summary:(Some s)
      ~filter:""
      ~width:200
      ~height:200
  ;;

  let%test_unit "semantic synthesis preserves text and separates validation from \
                 acceptance"
    =
    let s = { (summary ()) with freshness = Validated; acceptance = "fail" } in
    List.iter [ Mode.Summary; Metrics; Cells; Details; Evidence ] ~f:(fun mode ->
      List.iter [ 1; 17; 80 ] ~f:(fun width ->
        let state = State.set_mode (ready s) mode in
        let plain = rows state ~summary:(Some s) ~filter:"" ~width ~height:100 in
        let styled =
          semantic_rows state ~summary:(Some s) ~filter:"" ~width ~height:100
        in
        [%test_result: string list] (List.map styled ~f:Evidence_style.text) ~expect:plain));
    let styled =
      semantic_rows
        (State.set_mode (ready s) Metrics)
        ~summary:(Some s)
        ~filter:""
        ~width:200
        ~height:100
      |> List.concat
    in
    assert (
      List.exists styled ~f:(fun span -> Evidence_style.Role.equal span.role Validated));
    assert (List.exists styled ~f:(fun span -> Evidence_style.Role.equal span.role Failed));
    assert (
      not (List.exists styled ~f:(fun span -> Evidence_style.Role.equal span.role Passed)))
  ;;

  let%test_unit "metrics missing in old caches require explicit Refresh; invalid values \
                 stay explicit"
    =
    let output = render_mode (summary ()) Metrics in
    assert (
      List.mem
        output
        "Metrics unavailable in cached summary; explicit Refresh needed"
        ~equal:String.equal);
    let s =
      summary
        ~metrics:
          [ metric "area" "Synthesis resource area"
          ; metric ~value:None ~availability:"not_reported" "missing" "Missing"
          ; metric ~value:(Some Float.nan) "nan" "NaN"
          ; metric ~value:(Some Float.infinity) "inf" "Infinity"
          ; metric ~value:(Some (-1.)) "negative" "Negative"
          ; metric ~value:(Some 0.) ~unit_:None "diagnostics" "Synthesis diagnostics"
          ; metric ~unit_:None ~availability:"" ~source:None "fallback" ""
          ]
        ()
    in
    let output = render_mode s Metrics in
    List.iter
      [ "Synthesis resource area: 12.5 um^2 [available]"
      ; "Missing: unavailable [not_reported]"
      ; "NaN: invalid (non-finite) [available]"
      ; "Infinity: invalid (non-finite) [available]"
      ; "Negative: invalid (negative) [available]"
      ; "Synthesis diagnostics: 0 [available]"
      ; "fallback: unavailable [availability not reported]"
      ; "Zero diagnostic counts do not imply signoff"
      ; "Acceptance (reported): reported acceptance"
      ]
      ~f:(fun line -> assert (List.mem output line ~equal:String.equal));
    assert (not (List.exists output ~f:(String.is_substring ~substring:"/private/")));
    let compact =
      rows
        (State.set_mode (ready s) Metrics)
        ~summary:(Some s)
        ~filter:""
        ~width:80
        ~height:2
    in
    assert (
      List.mem
        compact
        "Synthesis resource area: 12.5 um^2 [available]"
        ~equal:String.equal)
  ;;

  let%test_unit "summary area and Checks use synthesis scope and preserve acceptance" =
    let s =
      summary
        ~metrics:
          [ metric "design__instance__area" "Mapped cell area"
          ; metric
              ~value:(Some 0.)
              ~unit_:(Some "count")
              "synthesis__check_error__count"
              "Synthesis check errors"
          ; metric
              ~value:(Some 2.)
              ~unit_:(Some "count")
              "design__lint_warning__count"
              "Lint warnings"
          ]
        ()
    in
    let output = render_mode s Summary in
    assert (
      List.mem
        output
        "Synthesis resource area (mapped cells): 12.5 um^2"
        ~equal:String.equal);
    let checks = checks_lines s in
    assert (
      List.mem
        checks
        "Checks: synthesis diagnostic counters (not DRC/LVS)"
        ~equal:String.equal);
    assert (
      List.mem checks "Synthesis check errors: 0 count [available]" ~equal:String.equal);
    assert (List.mem checks "Lint warnings: 2 count [available]" ~equal:String.equal);
    assert (
      List.mem checks "Acceptance (reported): reported acceptance" ~equal:String.equal);
    assert (
      List.mem checks "Zero diagnostic counts do not imply signoff" ~equal:String.equal);
    assert (
      not (List.exists checks ~f:(String.is_substring ~substring:"Mapped cell area")));
    let missing = checks_lines (summary ()) in
    assert (
      List.exists missing ~f:(String.is_substring ~substring:"explicit Refresh needed"));
    let no_summary =
      rows
        (State.set_mode State.empty Metrics)
        ~summary:None
        ~filter:""
        ~width:100
        ~height:2
    in
    assert (
      List.exists no_summary ~f:(String.is_substring ~substring:"explicit Refresh needed"))
  ;;

  let%test_unit "checkpoint boundaries retain original sources separately from acceptance"
    =
    let sources =
      [ "/private/checkpoints/rtl/check.json#diagnostics"
      ; "/private/checkpoints/synthesis/check.json#diagnostics"
      ]
    in
    let s =
      summary
        ~metrics:
          (List.mapi sources ~f:(fun n source ->
             metric
               ~value:(Some 0.)
               ~unit_:None
               ~source:(Some source)
               (sprintf "checks-%d" n)
               "Synthesis diagnostic count"))
        ()
    in
    let output = render_mode s Evidence in
    List.iter sources ~f:(fun source ->
      assert (List.mem output ("Metric source (full): " ^ source) ~equal:String.equal));
    assert (
      List.mem output "Acceptance (reported): reported acceptance" ~equal:String.equal);
    assert (
      List.mem
        output
        "Boundaries are evidence scope, not stage completion or acceptance"
        ~equal:String.equal);
    assert (List.mem output s.producer ~equal:String.equal);
    let wrapped =
      rows
        (State.set_mode (ready s) Evidence)
        ~summary:(Some s)
        ~filter:""
        ~width:17
        ~height:200
    in
    let text = String.concat wrapped in
    List.iter sources ~f:(fun source ->
      assert (String.is_substring text ~substring:source))
  ;;

  let%test_unit "metrics paging is local and same-digest metric refresh renders new data" =
    let s = summary () in
    let cells = ready s |> fun t -> State.set_mode t Cells in
    let metrics =
      State.set_mode cells Metrics |> fun t -> State.scroll t ~delta:2 ~max_offset:10
    in
    assert (Mode.equal (State.mode cells) Cells);
    [%test_result: int] cells.State.offset ~expect:0;
    [%test_result: string option] (State.selected metrics) ~expect:(State.selected cells);
    let updated = { s with metrics = [ metric "area" "Synthesis resource area" ] } in
    let refreshed = State.reconcile metrics ~summary:(Some updated) ~filter:"" in
    assert (Mode.equal (State.mode refreshed) Metrics);
    [%test_result: int] refreshed.State.offset ~expect:2;
    let output = rows refreshed ~summary:(Some updated) ~filter:"" ~width:200 ~height:2 in
    assert (List.exists output ~f:(String.is_substring ~substring:"Scope: synthesis"));
    let top = State.scroll refreshed ~delta:Int.min_value ~max_offset:10 in
    let output = rows top ~summary:(Some updated) ~filter:"" ~width:200 ~height:2 in
    assert (
      List.mem output "Synthesis resource area: 12.5 um^2 [available]" ~equal:String.equal);
    let replacement =
      State.reconcile refreshed ~summary:(Some (summary ~digest:"new" ())) ~filter:""
    in
    assert (Mode.equal (State.mode replacement) Metrics);
    [%test_result: int] replacement.State.offset ~expect:0;
    assert (Mode.equal (State.mode (State.back replacement)) Summary)
  ;;

  let%test_unit "shares use reported denominator; all coverage states are explicit" =
    let s = summary () in
    let projection = Synthesis.project s in
    assert (Synthesis.Coverage.equal projection.coverage Matches);
    let filtered = Synthesis.rows projection ~sort:Count_desc ~filter:"alpha" in
    [%test_result: float option] (List.hd_exn filtered).share ~expect:(Some 40.);
    let missing = Synthesis.project { s with cell_count = None } in
    assert (Synthesis.Coverage.equal missing.coverage Unknown_total);
    assert (List.for_all missing.rows ~f:(fun row -> Option.is_none row.share));
    let zero = Synthesis.project { s with cell_count = Some 0 } in
    assert (Synthesis.Coverage.equal zero.coverage Mismatch);
    assert (List.for_all zero.rows ~f:(fun row -> Option.is_none row.share));
    let mismatched = Synthesis.project { s with cell_count = Some 5 } in
    assert (Synthesis.Coverage.equal mismatched.coverage Mismatch);
    assert (
      List.exists mismatched.rows ~f:(fun row ->
        Float.(Option.value_exn row.share > 100.)));
    let empty = Synthesis.project { s with cells = [] } in
    assert (Synthesis.Coverage.equal empty.coverage No_breakdown);
    [%test_result: Synthesis.Row.t list]
      (Synthesis.rows empty ~sort:Count_desc ~filter:"")
      ~expect:[];
    let duplicate = Synthesis.project { s with cells = [ "x", 3; "x", 7 ] } in
    [%test_result: int64] (List.hd_exn duplicate.rows).count ~expect:10L
  ;;

  let%test_unit "domain-sized extreme duplicate and distinct counts label overflow" =
    (* On the supported 64-bit host, even 4096 individually valid OCaml ints can exceed
       int64. Both duplicate aggregation and the breakdown need checks. *)
    if Stdlib.Sys.word_size = 64
    then (
      let duplicate =
        summary ~cells:(List.init 4096 ~f:(fun _ -> "x", Int.max_value)) ()
        |> Synthesis.project
      in
      let row = List.hd_exn duplicate.rows in
      assert row.count_overflow;
      assert (Int64.equal row.count Int64.max_value);
      [%test_result: float option] row.share ~expect:None;
      assert duplicate.breakdown_overflow;
      assert (Synthesis.Coverage.equal duplicate.coverage Overflow);
      [%test_result: string] (count_text row) ~expect:"overflow";
      let distinct =
        summary ~cells:(List.init 4096 ~f:(fun n -> Int.to_string n, Int.max_value)) ()
        |> Synthesis.project
      in
      assert (List.for_all distinct.rows ~f:(fun row -> not row.count_overflow));
      assert distinct.breakdown_overflow;
      assert (Synthesis.Coverage.equal distinct.coverage Overflow);
      assert (String.is_substring (coverage_text distinct) ~substring:"OVERFLOW"))
  ;;

  let%test_unit "cached projection and sorted rows survive repaint and metadata updates" =
    let s = summary () in
    let t = ready s in
    let initial = Option.value_exn t.State.cache in
    let unchanged = State.reconcile t ~summary:(Some s) ~filter:"" in
    let cache = Option.value_exn unchanged.State.cache in
    assert (phys_equal cache.projection initial.projection);
    assert (phys_equal cache.rows initial.rows);
    let metadata = { s with producer = "new raw metadata"; freshness = Validated } in
    let refreshed = State.reconcile unchanged ~summary:(Some metadata) ~filter:"" in
    let cache = Option.value_exn refreshed.State.cache in
    assert (phys_equal cache.projection initial.projection);
    assert (phys_equal cache.rows initial.rows);
    let sorted = State.set_sort refreshed Name_asc in
    let sorted = State.reconcile sorted ~summary:(Some metadata) ~filter:"" in
    let cache = Option.value_exn sorted.State.cache in
    assert (phys_equal cache.projection initial.projection);
    [%test_result: string list]
      (List.map cache.rows ~f:(fun row -> row.name))
      ~expect:[ "alpha"; "beta" ];
    let updated = { s with cells = [ "alpha", 10 ] } in
    let changed = State.reconcile sorted ~summary:(Some updated) ~filter:"" in
    let cache = Option.value_exn changed.State.cache in
    assert (not (phys_equal cache.projection initial.projection));
    [%test_result: int] (List.length cache.rows) ~expect:1;
    let filtered = State.reconcile changed ~summary:(Some updated) ~filter:"absent" in
    [%test_result: int] (List.length (State.cell_rows filtered)) ~expect:0
  ;;

  let%test_unit "compact summary preserves count and explicit freshness before cells" =
    let s = summary () in
    let t = ready s in
    let output = rows t ~summary:(Some s) ~filter:"" ~width:32 ~height:4 in
    [%test_result: string list]
      (List.take output 3)
      ~expect:[ "Cell count: 10"; "Freshness: Cached_unverified"; "  Count  Cell type" ];
    [%test_result: int] (List.length output) ~expect:4;
    assert (List.exists output ~f:(String.is_substring ~substring:"beta"));
    let failed = { s with freshness = Refresh_failed "/private/failure/raw" } in
    let output = rows t ~summary:(Some failed) ~filter:"" ~width:32 ~height:4 in
    assert (List.mem output "Freshness: Refresh_failed" ~equal:String.equal);
    assert (not (List.exists output ~f:(String.is_substring ~substring:"/private")));
    let evidence =
      rows
        (State.set_mode t Evidence)
        ~summary:(Some failed)
        ~filter:""
        ~width:100
        ~height:100
    in
    assert (List.mem evidence "Refresh failure: /private/failure/raw" ~equal:String.equal)
  ;;

  let%test_unit "selection follows name through sort, filter and cached updates" =
    let s = summary () in
    let t = ready s |> fun t -> State.set_mode t Cells in
    [%test_result: string option] (State.selected t) ~expect:(Some "beta");
    let t = State.set_sort t Name_asc in
    let t = State.reconcile t ~summary:(Some s) ~filter:"" in
    [%test_result: string option] (State.selected t) ~expect:(Some "beta");
    let t = State.move t ~summary:(Some s) ~filter:"" ~delta:(-1) in
    [%test_result: string option] (State.selected t) ~expect:(Some "alpha");
    let t = State.set_mode t Details in
    let updated = { s with cells = [ "alpha", 9; "beta", 1 ]; freshness = Validated } in
    let t = State.reconcile t ~summary:(Some updated) ~filter:"" in
    assert (Mode.equal (State.mode t) Details);
    [%test_result: string option] (State.selected t) ~expect:(Some "alpha");
    let t = State.reconcile t ~summary:(Some updated) ~filter:"BETA" in
    assert (Mode.equal (State.mode t) Cells);
    [%test_result: string option] (State.selected t) ~expect:(Some "beta");
    let t = State.reconcile t ~summary:(Some s) ~filter:"no match" in
    [%test_result: string option] (State.selected t) ~expect:None
  ;;

  let%test_unit "run/digest replacement and missing data clear stale details; pins \
                 independent"
    =
    let s = summary () in
    let pinned = ready s |> fun t -> State.set_mode t Details in
    List.iter
      [ summary ~id:"run-b" (); summary ~digest:"digest-b" () ]
      ~f:(fun replacement ->
        let t = State.reconcile pinned ~summary:(Some replacement) ~filter:"" in
        assert (Mode.equal (State.mode t) Cells);
        assert (Synthesis.Sort.equal (State.sort t) Count_desc);
        [%test_result: string option] (State.selected t) ~expect:None);
    let missing = State.reconcile pinned ~summary:None ~filter:"" in
    assert (Mode.equal (State.mode missing) Cells);
    [%test_result: string option] (State.selected missing) ~expect:None;
    let pinned = State.reconcile pinned ~summary:(Some s) ~filter:"" in
    assert (Mode.equal (State.mode pinned) Details);
    [%test_result: string option] (State.selected pinned) ~expect:(Some "beta")
  ;;

  let%test_unit "empty navigation, unchanged snapshots, sort cycle and back are local" =
    let empty = State.move State.empty ~summary:None ~filter:"" ~delta:(-1) in
    [%test_result: string option] (State.selected empty) ~expect:None;
    let s = summary () in
    let t = State.reconcile empty ~summary:(Some s) ~filter:"" in
    [%test_result: string option] (State.selected t) ~expect:(Some "beta");
    let t = State.set_sort t Name_desc |> fun t -> State.set_mode t Details in
    let same = State.reconcile t ~summary:(Some s) ~filter:"" in
    assert (Mode.equal (State.mode same) Details);
    assert (Synthesis.Sort.equal (State.sort same) Name_desc);
    [%test_result: string option] (State.selected same) ~expect:(Some "beta");
    assert (Mode.equal (State.mode (State.back same)) Cells);
    assert (Mode.equal (State.mode (State.back (State.back same))) Summary);
    assert (Synthesis.Sort.equal (State.sort (State.cycle_sort same)) Count_desc);
    let empty = State.move same ~summary:(Some s) ~filter:"absent" ~delta:(-1) in
    [%test_result: string option] (State.selected empty) ~expect:None
  ;;

  let%test_unit "normal views hide raw producer and paths, evidence preserves them" =
    let s = summary () in
    let t = ready s in
    List.iter [ Mode.Summary; Cells ] ~f:(fun mode ->
      let output =
        rows (State.set_mode t mode) ~summary:(Some s) ~filter:"" ~width:100 ~height:30
      in
      let text = String.concat ~sep:"\n" output in
      assert (not (String.is_substring text ~substring:s.producer));
      assert (not (String.is_substring text ~substring:s.execution_file)));
    let output =
      rows (State.set_mode t Evidence) ~summary:(Some s) ~filter:"" ~width:200 ~height:100
    in
    assert (List.mem output s.producer ~equal:String.equal);
    assert (List.exists output ~f:(String.is_substring ~substring:s.execution_file));
    let output =
      rows
        (State.set_mode t Cells)
        ~summary:(Some s)
        ~filter:"absent"
        ~width:80
        ~height:10
    in
    assert (List.mem output "No cells match. Ctrl-U clears filter" ~equal:String.equal);
    assert (not (List.is_empty (rows t ~summary:None ~filter:"" ~width:40 ~height:5)))
  ;;

  let%test_unit "cell-aware wrapping, tiny sizes, paging and cursor visibility" =
    [%test_result: string list] (wrap ~width:3 "界ab") ~expect:[ "界a"; "b" ];
    [%test_result: string list] (wrap ~width:1 "界a") ~expect:[ "?"; "a" ];
    [%test_result: string list] (wrap ~width:1 "éx") ~expect:[ "é"; "x" ];
    let s = summary ~cells:(List.init 20 ~f:(fun n -> sprintf "cell-%02d" n, n)) () in
    let t = ready s |> fun t -> State.set_mode t Cells in
    let t = State.move t ~summary:(Some s) ~filter:"" ~delta:19 in
    let output = rows t ~summary:(Some s) ~filter:"" ~width:30 ~height:4 in
    assert (List.exists output ~f:(String.is_substring ~substring:">     0  cell-00"));
    [%test_result: string list]
      (rows t ~summary:(Some s) ~filter:"" ~width:0 ~height:4)
      ~expect:[];
    let evidence =
      State.set_mode t Evidence
      |> fun t ->
      scroll t ~summary:(Some s) ~filter:"" ~width:80 ~height:3 ~delta:Int.max_value
    in
    let output = rows evidence ~summary:(Some s) ~filter:"" ~width:80 ~height:3 in
    [%test_result: int] (List.length output) ~expect:3;
    assert (List.mem output s.producer ~equal:String.equal)
  ;;
end
