open! Core
open! Async
open Hardcaml_workbench_protocol

let max_bytes = 16 * 1024 * 1024

(* Protocol offsets and limits count raw bytes; hexadecimal transport doubles the size. *)
let page_limit = 64 * 1024
let max_hex_length = 2 * page_limit

let executable path =
  if String.is_empty path
     || Filename.is_relative path
     || String.exists path ~f:(Char.equal '\000')
  then
    Or_error.error_string
      "--artifact-binary-viewer requires an absolute executable filename"
  else Ok path
;;

let extension (reference : Asic_artifact.Reference.t) =
  List.find [ ".gds"; ".png"; ".def"; ".odb" ] ~f:(fun suffix ->
    String.is_suffix (String.lowercase reference.path) ~suffix)
  |> Or_error.of_option
       ~error:
         (Error.of_string
            "Binary export supports only known .gds/.png/.def/.odb physical files")
;;

let eligible reference =
  let open Or_error.Let_syntax in
  let%bind _ = extension reference in
  if reference.size < 0 || reference.size > max_bytes
  then Or_error.error_string "Binary export is bounded to 16 MiB"
  else Ok ()
;;

let decode hex =
  if String.length hex > max_hex_length || String.length hex % 2 <> 0
  then Or_error.error_string "Invalid binary hex page length"
  else
    Or_error.try_with (fun () ->
      let digit = function
        | '0' .. '9' as c -> Char.to_int c - Char.to_int '0'
        | 'a' .. 'f' as c -> Char.to_int c - Char.to_int 'a' + 10
        | 'A' .. 'F' as c -> Char.to_int c - Char.to_int 'A' + 10
        | _ -> failwith "Invalid binary hex digit"
      in
      String.init
        (String.length hex / 2)
        ~f:(fun i ->
          Char.of_int_exn ((digit hex.[2 * i] lsl 4) lor digit hex.[(2 * i) + 1])))
;;

let%test_unit "binary hex page limit is 65536 raw bytes and 131072 hex characters" =
  let bytes = decode (String.make 131072 'f') |> Or_error.ok_exn in
  assert (String.length bytes = 65536);
  assert (String.for_all bytes ~f:(Char.equal '\255'));
  assert (Or_error.is_error (decode (String.make 131074 '0')));
  assert (Or_error.is_error (decode (String.make 131071 '0')))
;;

let validate_page
  (reference : Asic_artifact.Reference.t)
  ~offset
  (page : Asic_artifact.Byte_page.t)
  =
  let open Or_error.Let_syntax in
  let%bind () =
    if Run_ref.equal reference.run page.run
       && String.equal reference.id page.artifact_id
       && String.equal reference.terminal_attempt page.terminal_attempt
       && String.equal reference.sha256 page.sha256
       && page.offset = offset
       && page.limit = page_limit
    then Ok ()
    else Or_error.error_string "Binary page identity/offset/limit changed"
  in
  let%bind () =
    match page.error with
    | None -> Ok ()
    | Some e -> Or_error.error_string e
  in
  let%bind bytes = decode page.bytes_hex in
  if page.next_offset < offset
     || page.next_offset > reference.size
     || page.next_offset - offset <> String.length bytes
     || (not (Bool.equal page.eof (page.next_offset = reference.size)))
     || ((not page.eof) && String.is_empty bytes)
  then Or_error.error_string "Invalid binary page progress/size/EOF"
  else Ok bytes
;;

type payload =
  { reference : Asic_artifact.Reference.t
  ; bytes : string
  ; metadata : string
  }

let run ~viewer ~reference ~fetch ~publish ~launch =
  let abandoned = ref false in
  let deadline = Time_ns.add (Time_ns.now ()) (Time_ns.Span.of_sec 120.) in
  let check () =
    if !abandoned || Time_ns.compare (Time_ns.now ()) deadline >= 0
    then failwith "Binary export timed out"
  in
  let work () =
    let open Deferred.Or_error.Let_syntax in
    let%bind viewer = Deferred.return (executable viewer) in
    let%bind () = Deferred.return (eligible reference) in
    let buffer = Buffer.create (Int.min reference.size page_limit) in
    let rec collect offset remaining =
      check ();
      if remaining = 0
      then Deferred.return (Or_error.error_string "Binary export page budget exhausted")
      else (
        let%bind page = fetch ~reference ~offset ~limit:page_limit ~check in
        check ();
        let%bind bytes = Deferred.return (validate_page reference ~offset page) in
        if Buffer.length buffer + String.length bytes > max_bytes
        then Deferred.return (Or_error.error_string "Binary export exceeds 16 MiB")
        else (
          Buffer.add_string buffer bytes;
          if page.eof
          then Deferred.return (Ok (Buffer.contents buffer))
          else collect page.next_offset (remaining - 1)))
    in
    let%bind bytes = collect 0 4096 in
    let%bind () =
      Deferred.return
        (if String.equal (Plain_rpc.digest bytes) (String.lowercase reference.sha256)
         then Ok ()
         else
           Or_error.error_string
             "Binary export SHA256 mismatch; no file or viewer published")
    in
    check ();
    let metadata =
      Sexp.to_string_hum
        (Sexp.List
           [ Atom "terminal-host-exact-binary-export"
           ; List
               [ Atom "original_reference"; Asic_artifact.Reference.sexp_of_t reference ]
           ; List [ Atom "verified_sha256"; Atom (Plain_rpc.digest bytes) ]
           ])
      ^ "\n"
    in
    let%bind suffix = Deferred.return (extension reference) in
    let%bind path = publish { reference; bytes; metadata } in
    check ();
    let%bind () =
      Deferred.return
        (if Filename.is_relative path
            || String.equal path reference.path
            || String.exists path ~f:(Char.equal '\000')
            || not (String.is_suffix path ~suffix)
         then
           Or_error.error_string
             "Publisher did not return a local binary export with retained extension"
         else Ok ())
    in
    let%map () =
      Deferred.map (launch ~prog:viewer ~args:[ path ]) ~f:(fun r ->
        Or_error.tag r ~tag:("Verified binary retained at " ^ path))
    in
    path
  in
  let%map result =
    Clock.with_timeout
      (Time_float.Span.of_sec 120.)
      (Monitor.try_with_or_error work >>| Or_error.join)
  in
  match result with
  | `Result r -> r
  | `Timeout ->
    abandoned := true;
    Or_error.error_string "Binary export timed out; no further reads or launch"
;;

let publish_private payload =
  In_thread.run (fun () ->
    Or_error.try_with (fun () ->
      let suffix = extension payload.reference |> Or_error.ok_exn in
      let directory = Filename_unix.temp_dir ~perm:0o700 "hardcaml-binary-" "" in
      Core_unix.chmod directory ~perm:0o700;
      let write path bytes =
        Out_channel.with_file
          path
          ~binary:true
          ~perm:0o600
          ~fail_if_exists:true
          ~f:(fun channel -> Out_channel.output_string channel bytes);
        Core_unix.chmod path ~perm:0o600
      in
      let path = Filename.concat directory ("artifact" ^ suffix) in
      write (Filename.concat directory "metadata.sexp") payload.metadata;
      write path payload.bytes;
      path))
;;

let%test_unit "binary export injectable recording launcher preserves bytes and rejects \
               corrupt pages/hash"
  =
  Thread_safe.block_on_async_exn (fun () ->
    let bytes = "\137PNG\000\255\r\n" in
    let reference : Asic_artifact.Reference.t =
      { id = "png"
      ; run = Fs0_fixture.run_a
      ; terminal_attempt = "attempt"
      ; label = "PNG"
      ; path = "/provider/private/image.png"
      ; sha256 = Plain_rpc.digest bytes
      ; size = String.length bytes
      ; kind = "binary"
      }
    in
    let hex = Cryptokit.transform_string (Cryptokit.Hexa.encode ()) bytes in
    let page : Asic_artifact.Byte_page.t =
      { artifact_id = reference.id
      ; run = reference.run
      ; terminal_attempt = reference.terminal_attempt
      ; sha256 = reference.sha256
      ; offset = 0
      ; limit = page_limit
      ; next_offset = reference.size
      ; eof = true
      ; bytes_hex = hex
      ; error = None
      }
    in
    let recorded = ref [] in
    let reads = ref [] in
    let viewer = "/recording/fixture with spaces;no-shell" in
    let host_path = "/local/private/artifact.png" in
    let%bind result =
      run
        ~viewer
        ~reference
        ~fetch:(fun ~reference:actual ~offset ~limit ~check ->
          check ();
          assert (Asic_artifact.Reference.equal actual reference && limit = page_limit);
          reads := !reads @ [ offset ];
          let next_offset = if offset = 0 then 3 else reference.size in
          return
            (Ok
               { page with
                 offset
               ; next_offset
               ; eof = next_offset = reference.size
               ; bytes_hex =
                   String.sub hex ~pos:(offset * 2) ~len:((next_offset - offset) * 2)
               }))
        ~publish:(fun p ->
          assert (String.equal p.bytes bytes);
          assert (String.is_substring p.metadata ~substring:reference.path);
          assert (List.equal Int.equal !reads [ 0; 3 ]);
          return (Ok host_path))
        ~launch:(fun ~prog ~args ->
          recorded := (prog, args) :: !recorded;
          return (Ok ()))
    in
    assert (Or_error.is_ok result);
    assert (List.length !recorded = 1);
    let prog, args = List.hd_exn !recorded in
    assert (String.equal prog viewer && List.equal String.equal args [ host_path ]);
    assert (Or_error.is_error (eligible { reference with path = "/unknown.svg" }));
    assert (Or_error.is_error (eligible { reference with size = max_bytes + 1 }));
    let%map () =
      Deferred.List.iter
        [ { page with bytes_hex = "0z" }
        ; { page with bytes_hex = "0" }
        ; { page with bytes_hex = String.make (String.length hex) '0' }
        ; { page with terminal_attempt = "late" }
        ]
        ~how:`Sequential
        ~f:(fun page ->
          let%map r =
            run
              ~viewer:"/recording/fixture"
              ~reference
              ~fetch:(fun ~reference:_ ~offset:_ ~limit:_ ~check:_ -> return (Ok page))
              ~publish:(fun _ -> assert false)
              ~launch:(fun ~prog:_ ~args:_ -> assert false)
          in
          assert (Or_error.is_error r))
    in
    ())
;;
