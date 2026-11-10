open! Core
open! Async
open Hardcaml_workbench_protocol
module S = Simulation

let identity (a : S.Artifact.t) =
  match a.availability, a.size, a.sha256 with
  | Available, Some size, Some hash
    when size >= 0
         && size <= S.Limits.artifact_bytes
         && String.length hash = 64
         && String.for_all hash ~f:(function
           | '0' .. '9' | 'a' .. 'f' -> true
           | _ -> false) -> Ok (size, hash)
  | _ -> Or_error.error_string "Artifact unavailable or lacks bounded size/SHA256"
;;

let validate (a : S.Artifact.t) ~offset (p : S.Byte_page.t) =
  let open Or_error.Let_syntax in
  let%bind size, hash = identity a in
  let%bind bytes = Artifact_binary_export.decode p.bytes_hex in
  if (not
        (String.equal a.attempt_id p.attempt_id
         && String.equal a.id p.artifact_id
         && String.equal hash p.sha256))
     || p.offset <> offset
     || p.total_size <> size
     || p.next_offset > size
     || p.next_offset < offset
     || p.next_offset - offset <> String.length bytes
     || (not (Bool.equal p.eof (p.next_offset = size)))
     || ((not p.eof) && String.is_empty bytes)
     || String.exists p.bytes_hex ~f:(function
       | 'A' .. 'F' -> true
       | _ -> false)
  then Or_error.error_string "Simulation byte page identity/size/offset/EOF mismatch"
  else Ok bytes
;;

let suffix (a : S.Artifact.t) =
  if String.is_substring (String.lowercase a.media_type) ~substring:"vcd"
  then ".vcd"
  else if String.is_substring (String.lowercase a.media_type) ~substring:"fst"
  then ".fst"
  else ".bin"
;;

(* Embedded admission is deliberately stricter than general export's file suffix. *)
let vcd_media (a : S.Artifact.t) =
  List.mem
    [ "text/vcd"; "text/x-vcd"; "application/vcd"; "application/x-vcd" ]
    (String.lowercase a.media_type)
    ~equal:String.equal
;;

let embedded_vcd a =
  let open Or_error.Let_syntax in
  let%bind size, _ = identity a in
  if not (vcd_media a)
  then Or_error.error_string "No supported VCD: publish a text/vcd waveform artifact"
  else if size <= 0 || size > Waveform_data.default_limits.max_bytes
  then
    Or_error.error_string "Embedded VCD must be nonempty and <=8 MiB; use artifact export"
  else Ok ()
;;

let digest_chunks chunks =
  let hash = Cryptokit.Hash.sha256 () in
  List.iter chunks ~f:hash#add_string;
  Cryptokit.transform_string (Cryptokit.Hexa.encode ()) hash#result
;;

let run ~artifact ~fetch ~current ~publish ~viewer ~launch =
  let abandoned = ref false in
  let check () =
    if !abandoned || not (current ())
    then failwith "Simulation export owner changed or timed out"
  in
  let work () =
    let open Deferred.Or_error.Let_syntax in
    let%bind _, hash = Deferred.return (identity artifact) in
    let rec collect offset chunks remaining =
      check ();
      if remaining = 0 then failwith "Simulation export page budget exhausted";
      let%bind p = fetch ~offset ~limit:S.Limits.byte_page in
      check ();
      let%bind bytes = In_thread.run (fun () -> validate artifact ~offset p) in
      check ();
      let chunks = bytes :: chunks in
      if p.eof
      then Deferred.return (Ok (List.rev chunks))
      else collect p.next_offset chunks (remaining - 1)
    in
    let%bind chunks = collect 0 [] 4096 in
    let%bind () =
      In_thread.run (fun () ->
        if String.equal hash (digest_chunks chunks)
        then Ok ()
        else Or_error.error_string "Simulation artifact SHA256 mismatch")
    in
    check ();
    let%bind path = publish artifact chunks in
    check ();
    let%map () =
      match viewer with
      | None -> Deferred.return (Ok ())
      | Some prog ->
        let%bind prog = Deferred.return (Artifact_binary_export.executable prog) in
        Deferred.map (launch ~prog ~args:[ path ]) ~f:(fun result ->
          Or_error.tag result ~tag:("Verified simulation bytes retained at " ^ path))
    in
    path
  in
  let%map r =
    Clock.with_timeout
      (Time_float.Span.of_sec 120.)
      (Monitor.try_with_or_error work >>| Or_error.join)
  in
  match r with
  | `Result r -> r
  | `Timeout ->
    abandoned := true;
    Or_error.error_string "Simulation export timed out"
;;

let publish_private artifact chunks =
  In_thread.run (fun () ->
    Or_error.try_with (fun () ->
      let dir = Filename_unix.temp_dir ~perm:0o700 "hardcaml-simulation-" "" in
      let write name chunks =
        let path = Filename.concat dir name in
        Out_channel.with_file
          path
          ~binary:true
          ~perm:0o600
          ~fail_if_exists:true
          ~f:(fun c -> List.iter chunks ~f:(Out_channel.output_string c));
        path
      in
      ignore
        (write "metadata.sexp" [ Sexp.to_string_hum (S.Artifact.sexp_of_t artifact) ]
         : string);
      write ("artifact" ^ suffix artifact) chunks))
;;

let%test_unit "raw bytes and ownership are validated independently of display" =
  let bytes = "\000\255\r\n\128" in
  let a : S.Artifact.t =
    { id = "wave"
    ; attempt_id = "sim"
    ; case_id = None
    ; label = "trace"
    ; kind = "waveform"
    ; media_type = "application/vnd.gtkwave.vcd"
    ; size = Some (String.length bytes)
    ; sha256 = Some (Plain_rpc.digest bytes)
    ; availability = Available
    }
  in
  let p : S.Byte_page.t =
    { attempt_id = a.attempt_id
    ; artifact_id = a.id
    ; sha256 = Option.value_exn a.sha256
    ; offset = 0
    ; next_offset = String.length bytes
    ; total_size = String.length bytes
    ; eof = true
    ; bytes_hex = Cryptokit.transform_string (Cryptokit.Hexa.encode ()) bytes
    }
  in
  assert (String.equal (Or_error.ok_exn (validate a ~offset:0 p)) bytes);
  List.iter
    [ { p with attempt_id = "other" }
    ; { p with total_size = 0 }
    ; { p with eof = false }
    ; { p with bytes_hex = "zz" }
    ]
    ~f:(fun p -> assert (Or_error.is_error (validate a ~offset:0 p)));
  assert (
    Or_error.is_error (identity { a with size = Some (S.Limits.artifact_bytes + 1) }))
;;

let%test_unit "chunk hashing matches raw SHA256 across byte boundaries without \
               concatenation"
  =
  let chunks = [ "\000\255"; ""; "\r\n"; String.make 65536 '\128' ] in
  assert (String.equal (digest_chunks chunks) (Plain_rpc.digest (String.concat chunks)))
;;

let%test_unit "native FIFO text/x-vcd admission retains exact MIME and artifact guards" =
  let artifact : S.Artifact.t =
    { id = "fifo-waveform"
    ; attempt_id = "fifo-attempt"
    ; case_id = Some "directed"
    ; label = "FIFO trace"
    ; kind = "trace"
    ; media_type = "text/x-vcd"
    ; size = Some 64
    ; sha256 = Some (String.make 64 'a')
    ; availability = Available
    }
  in
  List.iter
    [ "text/vcd"; "text/x-vcd"; "TEXT/X-VCD"; "application/vcd"; "application/x-vcd" ]
    ~f:(fun media_type ->
      assert (Or_error.is_ok (embedded_vcd { artifact with media_type })));
  List.iter
    [ "text/x-vcd-extra"
    ; "text/plain"
    ; "application/json"
    ; "application/x-fst"
    ; "text/x-vcd; charset=utf-8"
    ]
    ~f:(fun media_type ->
      assert (Or_error.is_error (embedded_vcd { artifact with media_type })));
  List.iter
    [ { artifact with size = Some 0 }
    ; { artifact with size = Some (Waveform_data.default_limits.max_bytes + 1) }
    ; { artifact with sha256 = None }
    ; { artifact with sha256 = Some "bad" }
    ]
    ~f:(fun artifact -> assert (Or_error.is_error (embedded_vcd artifact)))
;;

let%test_unit "multi-page export publishes exact host bytes and launches only after hash \
               verification"
  =
  Thread_safe.block_on_async_exn (fun () ->
    let bytes = "\000\255\r\n\128trace" in
    let artifact : S.Artifact.t =
      { id = "trace"
      ; attempt_id = "attempt-original"
      ; case_id = Some "case"
      ; label = "Waveform"
      ; kind = "waveform"
      ; media_type = "application/vnd.gtkwave.vcd"
      ; size = Some (String.length bytes)
      ; sha256 = Some (Plain_rpc.digest bytes)
      ; availability = Available
      }
    in
    let fetch ~offset ~limit =
      assert (limit = S.Limits.byte_page);
      let next_offset = Int.min (offset + 3) (String.length bytes) in
      return
        (Ok
           { S.Byte_page.attempt_id = artifact.attempt_id
           ; artifact_id = artifact.id
           ; sha256 = Option.value_exn artifact.sha256
           ; offset
           ; next_offset
           ; total_size = String.length bytes
           ; eof = next_offset = String.length bytes
           ; bytes_hex =
               Cryptokit.transform_string
                 (Cryptokit.Hexa.encode ())
                 (String.sub bytes ~pos:offset ~len:(next_offset - offset))
           })
    in
    let launched = ref false in
    let%bind result =
      run
        ~artifact
        ~fetch
        ~current:(fun () -> true)
        ~publish:publish_private
        ~viewer:(Some "/fixture/viewer with spaces")
        ~launch:(fun ~prog ~args ->
          assert (String.equal prog "/fixture/viewer with spaces");
          let path = List.hd_exn args in
          assert (String.equal (In_channel.read_all path) bytes);
          assert (String.is_suffix path ~suffix:".vcd");
          launched := true;
          return (Ok ()))
    in
    let path = Or_error.ok_exn result in
    assert !launched;
    Core_unix.unlink path;
    Core_unix.unlink (Filename.concat (Filename.dirname path) "metadata.sexp");
    Core_unix.rmdir (Filename.dirname path);
    let%bind result =
      run
        ~artifact:{ artifact with sha256 = Some (String.make 64 '0') }
        ~fetch
        ~current:(fun () -> true)
        ~publish:(fun _ _ -> assert false)
        ~viewer:None
        ~launch:(fun ~prog:_ ~args:_ -> assert false)
    in
    assert (Or_error.is_error result);
    let%bind result =
      run
        ~artifact
        ~fetch:(fun ~offset ~limit ->
          let%map page = fetch ~offset ~limit in
          Result.map page ~f:(fun (p : S.Byte_page.t) ->
            { p with bytes_hex = String.make (String.length p.bytes_hex) '0' }))
        ~current:(fun () -> true)
        ~publish:(fun _ _ -> assert false)
        ~viewer:(Some "/viewer")
        ~launch:(fun ~prog:_ ~args:_ -> assert false)
    in
    assert (Or_error.is_error result);
    let%map result =
      run
        ~artifact
        ~fetch
        ~current:(fun () -> false)
        ~publish:(fun _ _ -> assert false)
        ~viewer:(Some "/viewer")
        ~launch:(fun ~prog:_ ~args:_ -> assert false)
    in
    assert (Or_error.is_error result))
;;
