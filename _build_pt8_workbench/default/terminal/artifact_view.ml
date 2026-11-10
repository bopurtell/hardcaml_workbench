open! Core
open Hardcaml_workbench_protocol

(** Bounded, tile-local presentation. Only typed daemon pages are accepted; paths are
    metadata, never terminal-host filenames. *)
let limit = 4096

let catalog_limit = 32

type reading =
  { artifact : Asic_artifact.Reference.t
  ; offset : int
  ; previous : int list
  ; page : Asic_artifact.Page.t option
  }

type t =
  { run : Run_ref.t
  ; scope : Run_ref.t option
  ; catalog : Asic_artifact.Reference.t list
  ; selected : int
  ; reading : reading option
  ; error : string option
  ; scroll : int
  ; generation : int
  ; acknowledged : bool
  ; transport_error : string option
  ; viewer_configured : bool
  ; binary_viewer_configured : bool
  ; external_notice : string option
  }

let create
  ?scope
  ?(generation = 0)
  ?(viewer_configured = false)
  ?(binary_viewer_configured = false)
  run
  =
  { run
  ; scope
  ; catalog = []
  ; selected = 0
  ; reading = None
  ; error = None
  ; scroll = 0
  ; generation
  ; acknowledged = false
  ; transport_error = None
  ; viewer_configured
  ; binary_viewer_configured
  ; external_notice = None
  }
;;

let reconcile_scope t ~scope =
  if Option.equal Run_ref.equal t.scope scope then Some t else None
;;

let same_reference (a : Asic_artifact.Reference.t) (b : Asic_artifact.Reference.t) =
  Run_ref.equal a.run b.run
  && String.equal a.id b.id
  && String.equal a.terminal_attempt b.terminal_attempt
  && String.equal a.sha256 b.sha256
;;

let matches (r : reading) (p : Asic_artifact.Page.t) =
  Run_ref.equal r.artifact.run p.run
  && String.equal r.artifact.id p.artifact_id
  && String.equal r.artifact.terminal_attempt p.terminal_attempt
  && String.equal r.artifact.sha256 p.sha256
  && r.offset = p.offset
  && p.limit = limit
;;

type request_identity =
  | Catalog of Run_ref.t
  | Page of Asic_artifact.Reference.t * int * int

type ticket =
  { instance_id : V1.Daemon_instance_id.t
  ; project : Project_id.t
  ; generation : int
  ; identity : request_identity
  }

let capture t ~instance_id ~project (operation : Asic.Operation.t) =
  let identity =
    match operation, t.reading with
    | List_artifacts run, None when Run_ref.equal run t.run -> Some (Catalog run)
    | Read_artifact { run; artifact_id; offset; limit = requested_limit }, Some r
      when Run_ref.equal run t.run
           && String.equal artifact_id r.artifact.id
           && offset = r.offset
           && requested_limit = limit -> Some (Page (r.artifact, offset, requested_limit))
    | _ -> None
  in
  Option.map identity ~f:(fun identity ->
    { instance_id; project; generation = t.generation; identity })
;;

let apply_response (t : t) (ticket : ticket) ~instance_id ~project response =
  let exact =
    V1.Daemon_instance_id.equal ticket.instance_id instance_id
    && Project_id.equal ticket.project project
    && t.generation = ticket.generation
    &&
    match ticket.identity, t.reading with
    | Catalog run, None -> Run_ref.equal run t.run
    | Page (artifact, offset, requested_limit), Some r ->
      Run_ref.equal artifact.run t.run
      && same_reference artifact r.artifact
      && offset = r.offset
      && requested_limit = limit
    | _ -> false
  in
  if not exact
  then t
  else (
    match response with
    | Ok () -> { t with acknowledged = true }
    | Error error ->
      { t with acknowledged = true; transport_error = Some error; error = Some error })
;;

let reconcile t (snapshot : Asic.Snapshot.t) =
  let catalog =
    List.filter snapshot.artifacts ~f:(fun a -> Run_ref.equal t.run a.run)
    |> Fn.flip List.take catalog_limit
  in
  let t =
    { t with
      catalog
    ; selected = Int.min t.selected (Int.max 0 (List.length catalog - 1))
    }
  in
  let operation =
    match t.reading with
    | None -> Asic.Operation.List_artifacts t.run
    | Some r ->
      Read_artifact { run = t.run; artifact_id = r.artifact.id; offset = r.offset; limit }
  in
  let watched = Plain_rpc.keys operation snapshot in
  let error =
    if not t.acknowledged
    then t.transport_error
    else
      Option.first_some
        t.transport_error
        (watched
         |> List.find_map ~f:(fun key ->
           List.find snapshot.operations ~f:(fun op -> String.equal op.key key)
           |> Option.bind ~f:(fun op ->
             Option.first_some
               op.error
               (if List.mem [ "failed"; "detached" ] op.state ~equal:String.equal
                then Some (key ^ ": " ^ op.state)
                else None))))
  in
  match error with
  | Some error -> { t with error = Some error }
  | None ->
    (match t.reading with
     | None -> t
     | Some r ->
       if not (List.exists catalog ~f:(same_reference r.artifact))
       then
         { t with
           error = Some "Artifact missing or attempt/hash changed; return to catalog"
         }
       else (
         match List.find snapshot.artifact_pages ~f:(matches r) with
         | None ->
           if Option.is_none r.page
              && t.acknowledged
              && List.exists snapshot.operations ~f:(fun op ->
                List.mem watched op.key ~equal:String.equal
                && String.equal op.state "completed")
           then { t with error = Some "Page expired; read again (Enter)" }
           else t
         | Some page when Option.is_some page.error && not t.acknowledged -> t
         | Some page ->
           if String.length page.text > limit
              || page.next_offset < page.offset
              || ((not page.eof)
                  && page.next_offset = page.offset
                  && Option.is_none page.error)
           then { t with error = Some "Invalid or oversized artifact page" }
           else { t with reading = Some { r with page = Some page }; error = page.error }))
;;

let request r =
  Asic.Operation.Read_artifact
    { run = r.artifact.run; artifact_id = r.artifact.id; offset = r.offset; limit }
;;

let issue (t : t) reading =
  { t with
    reading = Some reading
  ; generation = t.generation + 1
  ; acknowledged = false
  ; transport_error = None
  ; error = None
  ; scroll = 0
  }
;;

(* Escape/control bytes from untrusted report text must never become terminal controls. *)
let safe text =
  let buffer = Buffer.create (String.length text) in
  let rec loop offset =
    if offset < String.length text
    then (
      let decoded = Stdlib.String.get_utf_8_uchar text offset in
      let length = Stdlib.Uchar.utf_decode_length decoded in
      let scalar = Stdlib.Uchar.to_int (Stdlib.Uchar.utf_decode_uchar decoded) in
      if (not (Stdlib.Uchar.utf_decode_is_valid decoded))
         || (scalar < 32 && scalar <> 9)
         || (scalar >= 127 && scalar < 160)
      then Buffer.add_char buffer '?'
      else if scalar = 9
      then Buffer.add_string buffer "    "
      else Buffer.add_substring buffer text ~pos:offset ~len:length;
      loop (offset + length))
  in
  loop 0;
  Buffer.contents buffer
;;

let wrap ~width text =
  let width = Int.max 1 width in
  let rec loop start offset cells output =
    if offset >= String.length text
    then List.rev (String.sub text ~pos:start ~len:(offset - start) :: output)
    else (
      let decoded = Stdlib.String.get_utf_8_uchar text offset in
      let length = Stdlib.Uchar.utf_decode_length decoded in
      let cell_width =
        Bonsai_term.View.uchar_tty_width (Stdlib.Uchar.utf_decode_uchar decoded)
        |> Int.max 0
      in
      if cells + cell_width > width && offset > start
      then
        loop offset offset 0 (String.sub text ~pos:start ~len:(offset - start) :: output)
      else loop start (offset + length) (cells + cell_width) output)
  in
  loop 0 0 0 []
;;

let page_lines t ~width =
  match t.error, t.reading with
  | None, Some { page = Some p; _ } when not (String.is_empty p.text) ->
    String.split_lines p.text |> List.concat_map ~f:(fun text -> wrap ~width (safe text))
  | _ -> []
;;

let external_reference t ~viewer =
  let open Or_error.Let_syntax in
  let%bind viewer =
    match viewer with
    | None ->
      Or_error.error_string
        "External text view disabled; configure --artifact-viewer ABSOLUTE_EXECUTABLE"
    | Some viewer -> Artifact_export.executable viewer
  in
  let%bind reference =
    match t.reading with
    | Some r ->
      if List.exists t.catalog ~f:(Artifact_export.same_reference r.artifact)
      then Ok r.artifact
      else Or_error.error_string "Artifact reference changed; return to catalog"
    | None ->
      List.nth t.catalog t.selected
      |> Or_error.of_option ~error:(Error.of_string "Select a text artifact first")
  in
  let%map () = Artifact_export.eligible reference in
  viewer, reference
;;

let notice_rows t ~width =
  Option.value_map t.external_notice ~default:[] ~f:(fun notice ->
    wrap ~width ("External view: " ^ safe notice))
;;

(* The inspector uses one heading and six fixed metadata/control rows. Clamp the persisted
   state to the last full viewport, not to bytes or a render-only suffix. *)
let clamp t ~width ~height =
  let visible = Int.max 1 (height - 7 - List.length (notice_rows t ~width)) in
  let last = Int.max 0 (List.length (page_lines t ~width) - visible) in
  { t with scroll = Int.max 0 (Int.min t.scroll last) }
;;

type input =
  | Open
  | Next
  | Previous
  | Up
  | Down
  | Back

let input ?(width = 80) ?(height = 24) t event =
  let t = clamp t ~width ~height in
  match event with
  | Back ->
    (match t.reading with
     | None -> None, None
     | Some _ ->
       ( Some
           { t with
             reading = None
           ; error = None
           ; scroll = 0
           ; generation = t.generation + 1
           ; acknowledged = false
           ; transport_error = None
           }
       , None ))
  | (Up | Down) as direction ->
    let delta =
      match direction with
      | Up -> -1
      | _ -> 1
    in
    (match t.reading with
     | Some _ -> Some (clamp { t with scroll = t.scroll + delta } ~width ~height), None
     | None ->
       ( Some
           { t with
             selected =
               Int.max 0 (Int.min (List.length t.catalog - 1) (t.selected + delta))
           }
       , None ))
  | Open ->
    (match t.reading, List.nth t.catalog t.selected with
     | None, Some artifact ->
       let r = { artifact; offset = 0; previous = []; page = None } in
       Some (issue t r), Some (request r)
     | Some r, _ ->
       let r = { r with page = None } in
       Some (issue t r), Some (request r)
     | _ -> Some t, None)
  | Next ->
    (match t.reading with
     | Some ({ page = Some p; _ } as r) when (not p.eof) && Option.is_none t.error ->
       let r =
         { r with
           offset = p.next_offset
         ; previous = r.offset :: List.take r.previous 255
         ; page = None
         }
       in
       Some (issue t r), Some (request r)
     | _ -> Some t, None)
  | Previous ->
    (match t.reading with
     | Some ({ previous = offset :: previous; _ } as r) ->
       let r = { r with offset; previous; page = None } in
       Some (issue t r), Some (request r)
     | _ -> Some t, None)
;;

let rows ?(width = 80) t ~height =
  let t = clamp t ~width ~height in
  let heading = "REPORTS / ARTIFACTS — run " ^ t.run.id in
  let external_control =
    (if not t.viewer_configured
     then "x: disabled (--artifact-viewer)"
     else (
       let reference =
         match t.reading with
         | Some r -> Some r.artifact
         | None -> List.nth t.catalog t.selected
       in
       match reference with
       | None -> "x: unavailable (select text)"
       | Some reference when Or_error.is_error (Artifact_export.eligible reference) ->
         "x: unavailable (non-text/over 16 MiB)"
       | Some _ -> "x: export sanitized text"))
    ^
    if t.binary_viewer_configured
    then " · b: export exact physical binary"
    else " · b: disabled (--artifact-binary-viewer)"
  in
  let notices = notice_rows t ~width in
  let body =
    match t.reading with
    | None ->
      [ external_control
        ^ " · Enter: read · Up/Down: select · Esc or Space c x: close (≤32)"
      ]
      @ (if List.is_empty t.catalog
         then [ "No catalog entries received for this exact run" ]
         else [])
      @ (List.mapi t.catalog ~f:(fun i a ->
           sprintf
             "%s %s [%s, %d bytes]"
             (if i = t.selected then ">" else " ")
             (safe a.label)
             (safe a.kind)
             a.size)
         |> Fn.flip
              List.drop
              (Int.max 0 (t.selected - Int.max 1 (height - 5 - List.length notices))))
    | Some r ->
      [ safe r.artifact.label ^ " [" ^ safe r.artifact.kind ^ "]"
      ; "Daemon-host path: " ^ safe r.artifact.path
      ; "Attempt: " ^ safe r.artifact.terminal_attempt
      ; sprintf "SHA256: %s · %d bytes" (safe r.artifact.sha256) r.artifact.size
      ; sprintf
          "Offset %d · %s"
          r.offset
          (Option.value_map r.page ~default:"waiting for bounded page" ~f:(fun p ->
             sprintf "next %d · EOF %b" p.next_offset p.eof))
      ; external_control
        ^ " · Enter: reread · n/p: page · Up/Down: scroll · Esc: back · Space c x: close"
      ]
      @
        (match t.error, r.page with
        | Some _, _ -> []
        | None, None ->
          [ "Loading text/metadata (binary content is not decoded locally)" ]
        | None, Some p ->
          if String.is_empty p.text
          then [ "No text returned (empty or non-text artifact); metadata shown above" ]
          else List.drop (page_lines t ~width) t.scroll)
  in
  ((heading :: notices)
   @ Option.to_list (Option.map t.error ~f:(fun e -> "ERROR: " ^ safe e)))
  @ body
  |> Fn.flip List.take (Int.max 0 height)
;;

let%test_unit "artifact inspector pins run/attempt/hash and pages with exact offset \
               history"
  =
  let run : Run_ref.t =
    { backend = Backend_id.of_string "asic"
    ; id = "artifact-fixture"
    ; build = None
    ; label = None
    }
  in
  let artifact : Asic_artifact.Reference.t =
    { id = "report"
    ; run
    ; terminal_attempt = "attempt-a"
    ; label = "Timing report"
    ; path = "/daemon/private/timing.txt"
    ; sha256 = "hash-a"
    ; size = 9000
    ; kind = "text"
    }
  in
  let page : Asic_artifact.Page.t =
    { artifact_id = artifact.id
    ; run
    ; terminal_attempt = artifact.terminal_attempt
    ; sha256 = artifact.sha256
    ; offset = 0
    ; limit
    ; next_offset = 4096
    ; eof = false
    ; text = "first page"
    ; error = None
    }
  in
  let snapshot pages : Asic.Snapshot.t =
    { configured = true
    ; flows = []
    ; catalog_default = None
    ; description_json = None
    ; preview = None
    ; runs = []
    ; operations = []
    ; launches = []
    ; fresh_intent = None
    ; workflows = []
    ; resources = None
    ; workloads = None
    ; summaries = []
    ; finalizations = []
    ; artifacts = [ artifact ]
    ; artifact_pages = pages
    ; artifact_byte_pages = []
    ; inspections = []
    ; inspection_details = []
    ; cache_error = None
    }
  in
  let catalog = reconcile (create run) (snapshot []) in
  assert (Or_error.is_error (external_reference catalog ~viewer:None));
  assert (
    String.is_substring (String.concat (rows catalog ~height:20)) ~substring:"x: disabled");
  assert (Or_error.is_error (external_reference catalog ~viewer:(Some "relative-viewer")));
  let viewer, exported =
    external_reference catalog ~viewer:(Some "/explicit/viewer") |> Or_error.ok_exn
  in
  assert (
    String.equal viewer "/explicit/viewer"
    && Asic_artifact.Reference.equal exported artifact);
  assert (
    Or_error.is_error
      (external_reference
         { catalog with catalog = [ { artifact with kind = "binary" } ] }
         ~viewer:(Some viewer)));
  assert (
    Or_error.is_error
      (external_reference
         { catalog with
           catalog = [ { artifact with size = Artifact_export.max_bytes + 1 } ]
         }
         ~viewer:(Some viewer)));
  assert (
    not
      (String.is_substring
         (String.concat (rows catalog ~height:20))
         ~substring:artifact.path));
  let state, operation = input catalog Open in
  let state = Option.value_exn state in
  (match operation with
   | Some (Read_artifact { run = actual; artifact_id; offset = 0; limit = 4096 }) ->
     assert (Run_ref.equal actual run && String.equal artifact_id artifact.id)
   | _ -> assert false);
  List.iter
    [ { page with sha256 = "stale" }
    ; { page with terminal_attempt = "stale" }
    ; { page with run = { run with id = "other-run" } }
    ; { page with offset = 1 }
    ; { page with limit = 65536; text = String.make 65536 'x' }
    ]
    ~f:(fun stale ->
      let ignored = reconcile state (snapshot [ stale ]) in
      assert (Option.is_none (Option.value_exn ignored.reading).page));
  let loaded = reconcile state (snapshot [ page ]) in
  let mixed =
    reconcile
      state
      (snapshot [ { page with limit = 65536; text = String.make 65536 'x' }; page ])
  in
  assert (Option.is_none mixed.error);
  assert (
    String.equal (Option.value_exn (Option.value_exn mixed.reading).page).text page.text);
  assert (
    String.is_substring (String.concat (rows loaded ~height:20)) ~substring:"first page");
  let next, operation = input loaded Next in
  let next = Option.value_exn next in
  (match operation with
   | Some (Read_artifact { offset = 4096; _ }) -> ()
   | _ -> assert false);
  let eof =
    { page with offset = 4096; next_offset = 5000; eof = true; text = "last page" }
  in
  let next = reconcile next (snapshot [ eof; page ]) in
  assert (Option.is_none (snd (input next Next)));
  let previous, operation = input next Previous in
  (match operation with
   | Some (Read_artifact { offset = 0; _ }) -> ()
   | _ -> assert false);
  let previous = reconcile (Option.value_exn previous) (snapshot [ page ]) in
  let catalog, _ = input previous Back in
  assert (Option.is_none (Option.value_exn catalog).reading);
  assert (Option.is_none (fst (input (Option.value_exn catalog) Back)));
  let changed =
    { (snapshot []) with artifacts = [ { artifact with sha256 = "new-hash" } ] }
  in
  assert (Option.is_some (reconcile loaded changed).error);
  assert (
    Option.is_some
      (reconcile state (snapshot [ { page with text = String.make (limit + 1) 'x' } ]))
        .error);
  let error = { page with error = Some "hash mismatch"; text = "must not display" } in
  let lines =
    rows (reconcile { state with acknowledged = true } (snapshot [ error ])) ~height:20
    |> String.concat
  in
  assert (String.is_substring lines ~substring:"hash mismatch");
  assert (not (String.is_substring lines ~substring:"must not display"));
  assert (String.equal (safe "\027[31m\000") "?[31m?");
  let instance_id = V1.Daemon_instance_id.of_string "artifact-daemon" in
  let project = Project_id.of_string "artifact-project" in
  let operation = request (Option.value_exn state.reading) in
  let ticket = Option.value_exn (capture state ~instance_id ~project operation) in
  assert (
    Option.is_none
      (capture
         state
         ~instance_id
         ~project
         (Read_artifact { run; artifact_id = artifact.id; offset = 0; limit = 65536 })));
  let wrong_budget = { ticket with identity = Page (artifact, 0, 65536) } in
  assert (
    Option.is_none
      (apply_response state wrong_budget ~instance_id ~project (Error "wrong budget"))
        .error);
  let complete : Asic.Pending.t =
    { key = Asic_artifact.read_key ~run ~artifact_id:artifact.id ~offset:0 ~limit
    ; kind = "artifact-read"
    ; state = "completed"
    ; run = None
    ; error = None
    ; activity = Unreported
    }
  in
  let missing = { (snapshot []) with operations = [ complete ] } in
  (* No task yet and a historical completed task before this request is acknowledged are
     distinct from a completed current request whose shared page has expired. *)
  assert (Option.is_none (reconcile state (snapshot [])).error);
  assert (Option.is_none (reconcile state missing).error);
  let accepted = apply_response state ticket ~instance_id ~project (Ok ()) in
  let expired = reconcile accepted missing in
  assert (
    String.is_substring
      (String.concat (rows expired ~height:20))
      ~substring:"Page expired; read again");
  let retry, operation = input expired Open in
  let retry = Option.value_exn retry in
  assert (retry.generation > expired.generation);
  (match operation with
   | Some (Read_artifact { offset = 0; limit = 4096; _ }) -> ()
   | _ -> assert false);
  assert (Option.is_none (reconcile retry missing).error);
  assert (Option.is_none (reconcile retry (snapshot [ error ])).error);
  let stale response state = apply_response state ticket ~instance_id ~project response in
  assert (Option.is_none (stale (Error "old retry error") retry).error);
  assert (not (stale (Ok ()) retry).acknowledged);
  let reopened = create ~generation:(retry.generation + 1) run in
  assert (Option.is_none (stale (Error "old inspector error") reopened).error);
  List.iter
    [ instance_id, Project_id.of_string "other-project"
    ; V1.Daemon_instance_id.of_string "other-daemon", project
    ]
    ~f:(fun (instance_id, project) ->
      assert (
        Option.is_none
          (apply_response state ticket ~instance_id ~project (Error "foreign owner"))
            .error));
  let reading = Option.value_exn state.reading in
  List.iter
    [ { reading with artifact = { artifact with sha256 = "new-hash" } }
    ; { reading with artifact = { artifact with terminal_attempt = "new-attempt" } }
    ; { reading with artifact = { artifact with run = { run with id = "other-run" } } }
    ; { reading with offset = 4096 }
    ]
    ~f:(fun reading ->
      assert (
        Option.is_none
          (stale (Error "stale page error") { state with reading = Some reading }).error));
  let ticket =
    Option.value_exn
      (capture retry ~instance_id ~project (request (Option.value_exn retry.reading)))
  in
  let failed =
    apply_response retry ticket ~instance_id ~project (Error "current transport failure")
  in
  assert (Option.equal String.equal failed.error (Some "current transport failure"));
  assert (Option.equal String.equal (reconcile failed missing).error failed.error);
  let catalog = Option.value_exn (fst (input failed Back)) in
  assert (Option.is_none (reconcile catalog missing).error)
;;

let%test_unit "wrapped viewport persists its bottom clamp and reclamps on resize" =
  let run : Run_ref.t =
    { backend = Backend_id.of_string "asic"
    ; id = "scroll-fixture"
    ; build = None
    ; label = None
    }
  in
  let artifact : Asic_artifact.Reference.t =
    { id = "report"
    ; run
    ; terminal_attempt = "attempt"
    ; label = "Report"
    ; path = "/daemon/report"
    ; sha256 = "hash"
    ; size = 4096
    ; kind = "text"
    }
  in
  let text =
    List.init 20 ~f:(fun i -> sprintf "row-%02d-abcdefghij" (i + 1))
    |> String.concat ~sep:"\n"
  in
  let page : Asic_artifact.Page.t =
    { artifact_id = artifact.id
    ; run
    ; terminal_attempt = artifact.terminal_attempt
    ; sha256 = artifact.sha256
    ; offset = 0
    ; limit
    ; next_offset = String.length text
    ; eof = true
    ; text
    ; error = None
    }
  in
  let initial =
    { (create ~scope:run run) with
      catalog = [ artifact ]
    ; reading = Some { artifact; offset = 0; previous = []; page = Some page }
    }
  in
  let step ~width ~height state event =
    let state, operation = input ~width ~height state event in
    assert (Option.is_none operation);
    Option.value_exn state
  in
  let bottom =
    List.fold (List.init 100 ~f:Fn.id) ~init:initial ~f:(fun state _ ->
      step state Down ~width:10 ~height:12)
  in
  assert (bottom.scroll = 35);
  let body state ~width ~height = List.drop (rows state ~width ~height) 7 in
  assert (List.length (body bottom ~width:10 ~height:12) = 5);
  let up = step bottom Up ~width:10 ~height:12 in
  assert (up.scroll = 34);
  assert (
    not
      (List.equal
         String.equal
         (body bottom ~width:10 ~height:12)
         (body up ~width:10 ~height:12)));
  let resized = clamp bottom ~width:20 ~height:17 in
  assert (resized.scroll = 10);
  assert (
    String.equal (List.hd_exn (body resized ~width:20 ~height:17)) "row-11-abcdefghij");
  let up = step resized Up ~width:20 ~height:17 in
  assert (up.scroll = 9);
  assert (String.equal (List.hd_exn (body up ~width:20 ~height:17)) "row-10-abcdefghij");
  (* Input also normalizes a changed viewport before applying the first key. *)
  assert ((step bottom Up ~width:20 ~height:17).scroll = 9);
  assert ((clamp bottom ~width:80 ~height:40).scroll = 0);
  assert (Option.is_some (reconcile_scope initial ~scope:(Some run)));
  assert (Option.is_none (reconcile_scope initial ~scope:(Some { run with id = "other" })));
  assert (Option.is_none (reconcile_scope initial ~scope:None));
  let snapshot : Asic.Snapshot.t =
    { configured = true
    ; flows = []
    ; catalog_default = None
    ; description_json = None
    ; preview = None
    ; runs = []
    ; operations = []
    ; launches = []
    ; fresh_intent = None
    ; workflows = []
    ; resources = None
    ; workloads = None
    ; summaries = []
    ; finalizations = []
    ; artifacts = List.init 40 ~f:(fun i -> { artifact with id = Int.to_string i })
    ; artifact_pages = []
    ; artifact_byte_pages = []
    ; inspections = []
    ; inspection_details = []
    ; cache_error = None
    }
  in
  assert (List.length (reconcile (create run) snapshot).catalog = 32)
;;
