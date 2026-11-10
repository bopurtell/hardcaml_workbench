open! Core
open! Async
open Hardcaml_workbench_protocol

let max_bytes = 16 * 1024 * 1024
let page_limit = 64 * 1024
let timeout_seconds = 120.
let max_pages = 4096

let executable path =
  if String.is_empty path
     || Filename.is_relative path
     || String.exists path ~f:(Char.equal '\000')
  then Or_error.error_string "--artifact-viewer requires an absolute executable filename"
  else Ok path
;;

let eligible (reference : Asic_artifact.Reference.t) =
  if not (String.equal reference.kind "text")
  then
    Or_error.error_string "External text view unavailable for binary/non-text artifacts"
  else if reference.size < 0 || reference.size > max_bytes
  then Or_error.error_string "External text view is bounded to 16 MiB"
  else Ok ()
;;

let same_reference (a : Asic_artifact.Reference.t) (b : Asic_artifact.Reference.t) =
  Asic_artifact.Reference.equal a b
;;

let sanitize text =
  Or_error.try_with (fun () ->
    let buffer = Buffer.create (String.length text) in
    let rec loop offset =
      if offset < String.length text
      then (
        let decoded = Stdlib.String.get_utf_8_uchar text offset in
        if not (Stdlib.Uchar.utf_decode_is_valid decoded)
        then failwith "Invalid artifact UTF-8";
        let scalar = Stdlib.Uchar.to_int (Stdlib.Uchar.utf_decode_uchar decoded) in
        let length = Stdlib.Uchar.utf_decode_length decoded in
        if (scalar = 9 || scalar = 10 || scalar >= 32)
           && (not (scalar >= 127 && scalar < 160))
           && (not (scalar >= 0x202a && scalar <= 0x202e))
           && not (scalar >= 0x2066 && scalar <= 0x2069)
        then Buffer.add_substring buffer text ~pos:offset ~len:length;
        loop (offset + length))
    in
    loop 0;
    Buffer.contents buffer)
;;

let validate_page
  (reference : Asic_artifact.Reference.t)
  ~offset
  (page : Asic_artifact.Page.t)
  =
  if not
       (Run_ref.equal reference.run page.run
        && String.equal reference.id page.artifact_id
        && String.equal reference.terminal_attempt page.terminal_attempt
        && String.equal reference.sha256 page.sha256
        && page.offset = offset
        && page.limit = page_limit)
  then Or_error.error_string "Export page identity/offset/limit changed"
  else (
    match page.error with
    | Some error -> Or_error.error_string ("Export read failed: " ^ error)
    | None ->
      if String.length page.text > page_limit
         || page.next_offset < offset
         || page.next_offset - offset > page_limit
         || String.length page.text > page.next_offset - offset
         || page.next_offset > reference.size
         || (not (Bool.equal page.eof (Int.equal page.next_offset reference.size)))
         || ((not page.eof) && page.next_offset = offset)
      then Or_error.error_string "Invalid export page size/progress/EOF"
      else sanitize page.text)
;;

type payload =
  { reference : Asic_artifact.Reference.t
  ; text : string
  ; metadata : string
  }

let metadata reference text =
  Sexp.to_string_hum
    (Sexp.List
       [ Atom "terminal-host-sanitized-text-export"
       ; List
           [ Atom "content"
           ; Atom "Sanitized UTF-8 text; not byte-identical provider raw bytes"
           ]
       ; List [ Atom "original_reference"; Asic_artifact.Reference.sexp_of_t reference ]
       ; List [ Atom "exported_text_sha256"; Atom (Plain_rpc.digest text) ]
       ])
  ^ "\n"
;;

(** [fetch] must also check that the captured reference is still current in every RPC
    snapshot. Only the publisher creates host paths; only the launcher starts programs.
    The deadline abandons reads, never cancels daemon work or an already-started viewer. *)
let run ~viewer ~reference ~fetch ~publish ~launch =
  let abandoned = ref false in
  let deadline = Time_ns.add (Time_ns.now ()) (Time_ns.Span.of_sec timeout_seconds) in
  let check () =
    if !abandoned || Time_ns.compare (Time_ns.now ()) deadline >= 0
    then (
      abandoned := true;
      failwith "Artifact export timed out")
  in
  let work () =
    let open Deferred.Or_error.Let_syntax in
    let%bind viewer = Deferred.return (executable viewer) in
    let%bind () = Deferred.return (eligible reference) in
    let buffer = Buffer.create (Int.min reference.size page_limit) in
    let rec collect offset remaining =
      check ();
      if remaining = 0
      then Deferred.return (Or_error.error_string "Export page budget exhausted")
      else (
        let%bind page = fetch ~reference ~offset ~limit:page_limit ~check in
        check ();
        let%bind text = Deferred.return (validate_page reference ~offset page) in
        if Buffer.length buffer + String.length text > max_bytes
        then Deferred.return (Or_error.error_string "Sanitized export exceeds 16 MiB")
        else (
          Buffer.add_string buffer text;
          if page.eof
          then Deferred.return (Ok (Buffer.contents buffer))
          else collect page.next_offset (remaining - 1)))
    in
    let%bind text = collect 0 max_pages in
    check ();
    let%bind path = publish { reference; text; metadata = metadata reference text } in
    check ();
    if Filename.is_relative path
       || String.equal path reference.path
       || String.exists path ~f:(Char.equal '\000')
       || not (String.is_suffix path ~suffix:".txt")
    then
      Deferred.return
        (Or_error.error_string "Publisher did not return a terminal-host .txt export")
    else (
      let%map () =
        Deferred.map (launch ~prog:viewer ~args:[ path ]) ~f:(fun result ->
          Or_error.tag result ~tag:("Sanitized text retained at " ^ path))
      in
      path)
  in
  let%map result =
    Clock.with_timeout
      (Time_float.Span.of_sec timeout_seconds)
      (Monitor.try_with_or_error work >>| Or_error.join)
  in
  match result with
  | `Result result -> result
  | `Timeout ->
    abandoned := true;
    Or_error.error_string
      "Artifact export timed out after 120 seconds; no further pages or viewer launch \
       will be requested"
;;

let publish_private payload =
  In_thread.run (fun () ->
    Or_error.try_with (fun () ->
      let directory = Filename_unix.temp_dir ~perm:0o700 "hardcaml-artifact-" "" in
      Core_unix.chmod directory ~perm:0o700;
      let path = Filename.concat directory "artifact.txt" in
      let write path text =
        Out_channel.with_file path ~perm:0o600 ~fail_if_exists:true ~f:(fun channel ->
          Out_channel.output_string channel text);
        Core_unix.chmod path ~perm:0o600
      in
      (* Retain these files for the viewer/user, including if spawning fails. *)
      write (Filename.concat directory "metadata.sexp") payload.metadata;
      write path payload.text;
      path))
;;

let launch_viewer ~prog ~args =
  let%map process = Process.create ~prog ~args () in
  match process with
  | Error error -> Error error
  | Ok process ->
    (* Drain to nowhere with bounded reader buffers; never forward viewer output into the
       TUI, collect unbounded output, or wait for GUI exit on the input effect. *)
    let background f = don't_wait_for (Monitor.try_with f >>| fun _ -> ()) in
    background (fun () -> Writer.close (Process.stdin process));
    background (fun () -> Reader.drain (Process.stdout process));
    background (fun () -> Reader.drain (Process.stderr process));
    background (fun () -> Process.wait process >>| fun _ -> ());
    Ok ()
;;

let%test_unit "external text export validates every page and launches only a local path \
               argv"
  =
  Thread_safe.block_on_async_exn (fun () ->
    let reference_run : Run_ref.t =
      { backend = Backend_id.of_string "asic"
      ; id = "export-run"
      ; build = None
      ; label = None
      }
    in
    let reference : Asic_artifact.Reference.t =
      { id = "text"
      ; run = reference_run
      ; terminal_attempt = "exact-attempt"
      ; label = "Report"
      ; path = "/daemon/private/report.txt"
      ; sha256 = "original-raw-hash"
      ; size = 6
      ; kind = "text"
      }
    in
    let page offset : Asic_artifact.Page.t =
      { artifact_id = reference.id
      ; run = reference_run
      ; terminal_attempt = reference.terminal_attempt
      ; sha256 = reference.sha256
      ; offset
      ; limit = page_limit
      ; next_offset = offset + 3
      ; eof = offset = 3
      ; text = (if offset = 0 then "\027A\n" else "界")
      ; error = None
      }
    in
    let reads = ref [] in
    let published = ref None in
    let launched = ref None in
    let viewer = "/explicit/viewer with spaces;no-shell" in
    let host_path = "/terminal/private/new-export/artifact.txt" in
    let fetch ~reference:actual ~offset ~limit ~check =
      check ();
      assert (Asic_artifact.Reference.equal reference actual);
      assert (limit = page_limit);
      reads := !reads @ [ offset ];
      return (Ok (page offset))
    in
    let publish payload =
      assert (List.equal Int.equal !reads [ 0; 3 ]);
      published := Some payload;
      return (Ok host_path)
    in
    let launch ~prog ~args =
      launched := Some (prog, args);
      return (Ok ())
    in
    let%map result = run ~viewer ~reference ~fetch ~publish ~launch in
    assert (String.equal (Or_error.ok_exn result) host_path);
    let payload = Option.value_exn !published in
    assert (String.equal payload.text "A\n界");
    assert (String.is_substring payload.metadata ~substring:"Sanitized UTF-8 text");
    assert (String.is_substring payload.metadata ~substring:reference.path);
    assert (String.is_substring payload.metadata ~substring:reference.sha256);
    let prog, args = Option.value_exn !launched in
    assert (String.equal prog viewer);
    assert (List.equal String.equal args [ host_path ]);
    assert (not (List.mem args reference.path ~equal:String.equal)))
;;

let%test_unit "invalid, stale, binary and incomplete exports never publish or launch" =
  Thread_safe.block_on_async_exn (fun () ->
    let reference : Asic_artifact.Reference.t =
      { id = "text"
      ; run =
          { backend = Backend_id.of_string "asic"
          ; id = "export"
          ; build = None
          ; label = None
          }
      ; terminal_attempt = "attempt"
      ; label = "Report"
      ; path = "/daemon/report.txt"
      ; sha256 = "hash"
      ; size = 6
      ; kind = "text"
      }
    in
    let first : Asic_artifact.Page.t =
      { artifact_id = reference.id
      ; run = reference.run
      ; terminal_attempt = reference.terminal_attempt
      ; sha256 = reference.sha256
      ; offset = 0
      ; limit = page_limit
      ; next_offset = 3
      ; eof = false
      ; text = "abc"
      ; error = None
      }
    in
    let forbidden _ = assert false in
    let bad_pages =
      [ { first with artifact_id = "other" }
      ; { first with run = { reference.run with id = "other" } }
      ; { first with terminal_attempt = "other" }
      ; { first with sha256 = "changed" }
      ; { first with offset = 3 }
      ; { first with limit = 4096 }
      ; { first with next_offset = 0; text = "" }
      ; { first with next_offset = 7 }
      ; { first with eof = true }
      ; { first with text = String.make (page_limit + 1) 'x' }
      ; { first with text = "\255" }
      ; { first with error = Some "Reference changed since listing" }
      ]
    in
    let fail fetch reference =
      let%map result =
        run
          ~viewer:"/explicit/viewer"
          ~reference
          ~fetch
          ~publish:forbidden
          ~launch:(fun ~prog:_ ~args:_ -> assert false)
      in
      assert (Or_error.is_error result)
    in
    let%bind () =
      Deferred.List.iter bad_pages ~how:`Sequential ~f:(fun page ->
        fail (fun ~reference:_ ~offset:_ ~limit:_ ~check:_ -> return (Ok page)) reference)
    in
    let%bind () =
      Deferred.List.iter
        [ { reference with kind = "binary" }; { reference with size = max_bytes + 1 } ]
        ~how:`Sequential
        ~f:(fail (fun ~reference:_ ~offset:_ ~limit:_ ~check:_ -> assert false))
    in
    (* Valid initial bytes are never published if a subsequent read changes identity. *)
    let%bind () =
      fail
        (fun ~reference:_ ~offset ~limit:_ ~check:_ ->
          return
            (Ok
               (if offset = 0
                then first
                else
                  { first with
                    offset = 3
                  ; next_offset = 6
                  ; eof = true
                  ; sha256 = "changed"
                  })))
        reference
    in
    let%bind () =
      fail
        (fun ~reference:_ ~offset:_ ~limit:_ ~check:_ ->
          return (Or_error.error_string "Captured artifact changed while fetching"))
        reference
    in
    let%map result =
      run
        ~viewer:"/explicit/viewer"
        ~reference
        ~fetch:(fun ~reference:_ ~offset ~limit:_ ~check:_ ->
          return (Ok { first with offset; next_offset = 6; eof = true; text = "abc" }))
        ~publish:(fun _ -> return (Ok reference.path))
        ~launch:(fun ~prog:_ ~args:_ -> assert false)
    in
    assert (Or_error.is_error result))
;;
