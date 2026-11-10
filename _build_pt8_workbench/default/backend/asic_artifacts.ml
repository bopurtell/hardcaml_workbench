module Lock = Mutex
open! Core
open Hardcaml_workbench_protocol
module Reference = Asic_artifact.Reference
module Public = Asic_public

let max_file = 16 * 1024 * 1024
let max_page = 64 * 1024
let require = Public.require
let field = Public.field
let text = Public.text
let digest = Public.digest
let same_json a b = Poly.equal (Public.canonical_json a) (Public.canonical_json b)

(* Resolve before opening, then verify the opened descriptor's physical target. This
   closes the symlink/ancestor swap gap between realpath and open on Linux. *)
let contents path =
  let canonical = Filename_unix.realpath path in
  require (String.equal canonical path) "Artifact canonical path changed";
  let fd = Core_unix.openfile path ~mode:[ O_RDONLY; O_NONBLOCK; O_CLOEXEC ] in
  Exn.protect
    ~finally:(fun () -> Core_unix.close fd)
    ~f:(fun () ->
      let target =
        Filename_unix.realpath
          ("/proc/self/fd/" ^ Int.to_string (Core_unix.File_descr.to_int fd))
      in
      require (String.equal target canonical) "Artifact descriptor target changed";
      let before = Core_unix.fstat fd in
      require (Poly.equal before.st_kind S_REG) "Artifact is not a regular file";
      require
        Int64.(before.st_size >= 0L && before.st_size <= of_int max_file)
        "Artifact exceeds 16 MiB byte budget";
      let buf = Bytes.create (Int64.to_int_exn before.st_size + 1) in
      let rec loop pos =
        require (pos < Bytes.length buf) "Artifact grew while reading";
        let n = Core_unix.read fd ~buf ~pos ~len:(Bytes.length buf - pos) in
        if n = 0 then Bytes.To_string.sub buf ~pos:0 ~len:pos else loop (pos + n)
      in
      let bytes = loop 0 in
      let after = Core_unix.fstat fd in
      require
        (Int64.equal before.st_size after.st_size
         && Int64.equal after.st_size (Int64.of_int (String.length bytes))
         && Poly.equal before.st_mtime after.st_mtime
         && Poly.equal before.st_ctime after.st_ctime)
        "Artifact changed while reading";
      bytes)
;;

let resolve ~root ~external_hash path =
  require (not (String.is_empty path)) "Empty artifact path";
  require
    (not (List.mem (String.split path ~on:'/') ".." ~equal:String.equal))
    "Artifact path traversal";
  let relative = Filename.is_relative path in
  let canonical =
    Filename_unix.realpath (if relative then Filename.concat root path else path)
  in
  require
    ((external_hash && not relative) || String.is_prefix canonical ~prefix:(root ^ "/"))
    "Artifact escapes terminal attempt";
  canonical
;;

(* Strict UTF-8 decoder: overlong encodings, surrogates and out-of-range scalars are
   binary, never passed through to a terminal. *)
let scalar s i =
  let byte j = Char.to_int s.[j] in
  let a = byte i in
  let width, minimum, mask =
    if a < 0x80
    then 1, 0, 0x7f
    else if a land 0xe0 = 0xc0
    then 2, 0x80, 0x1f
    else if a land 0xf0 = 0xe0
    then 3, 0x800, 0x0f
    else if a land 0xf8 = 0xf0
    then 4, 0x10000, 0x07
    else failwith "Invalid UTF-8"
  in
  require (i + width <= String.length s) "Incomplete UTF-8";
  let value = ref (a land mask) in
  for j = i + 1 to i + width - 1 do
    let b = byte j in
    require (b land 0xc0 = 0x80) "Invalid UTF-8 continuation";
    value := (!value lsl 6) lor (b land 0x3f)
  done;
  require
    (!value >= minimum && !value <= 0x10ffff && not (!value >= 0xd800 && !value <= 0xdfff))
    "Invalid UTF-8 scalar";
  width, !value
;;

let is_text bytes =
  Result.is_ok
    (Or_error.try_with (fun () ->
       let rec loop i =
         if i < String.length bytes
         then (
           let width, value = scalar bytes i in
           require (value <> 0) "Binary NUL";
           loop (i + width))
       in
       loop 0))
;;

let printable value =
  (value = 9 || value = 10 || value >= 32)
  && (not (value >= 0x7f && value <= 0x9f))
  && (not (value >= 0x202a && value <= 0x202e))
  && not (value >= 0x2066 && value <= 0x2069)
;;

let sanitized s =
  let b = Buffer.create (String.length s) in
  let rec loop i =
    if i < String.length s
    then (
      let width, value = scalar s i in
      if printable value then Buffer.add_substring b s ~pos:i ~len:width;
      loop (i + width))
  in
  loop 0;
  Buffer.contents b
;;

let label ?(suffix = "") s =
  let s = if is_text s then sanitized s else "artifact" in
  let s =
    String.map s ~f:(function
      | '\n' | '\t' -> ' '
      | c -> c)
  in
  let budget = 160 - String.length suffix in
  if String.length s <= budget
  then s ^ suffix
  else (
    let rec boundary i =
      let width, _ = scalar s i in
      if i + width > budget - 3 then i else boundary (i + width)
    in
    String.prefix s (boundary 0) ^ "..." ^ suffix)
;;

(* Bounded authorization memory, not a filesystem path capability supplied by clients. The
   mutex protects cache publication/lookup across synchronous worker calls. *)
let references : Reference.t list ref = ref []
let lock = Lock.create ()

let locked f =
  Lock.lock lock;
  Exn.protect ~f ~finally:(fun () -> Lock.unlock lock)
;;

let list ~(summary : Asic.Summary.t) =
  match summary.terminal with
  | None -> []
  | Some terminal ->
    require (Filename.is_absolute terminal.attempt) "Expected absolute terminal attempt";
    require (String.length terminal.evidence <= 160 * 1024) "Terminal evidence too large";
    let evidence = Public.decode terminal.evidence in
    let operation = field "operation" evidence in
    let results = field "results" evidence in
    let root = Filename_unix.realpath terminal.attempt in
    require (not (String.equal root "/")) "Invalid terminal attempt";
    let local path = resolve ~root ~external_hash:false path in
    let operation_path = local (Filename.concat terminal.attempt "operation.json") in
    require
      (same_json (Public.decode (contents operation_path)) operation)
      "Original terminal operation context changed";
    require
      (Poly.equal
         (field "contract" operation)
         (`String "hardcaml-asic.segment-finalization")
       && Poly.equal (field "schema_version" operation) (`Int 1)
       && List.mem
            [ "completed"; "failed"; "interrupted" ]
            (text (field "status" operation))
            ~equal:String.equal)
      "Invalid terminal operation";
    let execution = field "execution" operation in
    require
      (Poly.equal (field "path" execution) (`String summary.execution_file)
       && Poly.equal (field "attempt_id" execution) (`String summary.run.id))
      "Terminal operation belongs to a different run";
    let execution_bytes = contents (Filename_unix.realpath summary.execution_file) in
    require
      (Poly.equal (field "sha256" execution) (`String (digest execution_bytes))
       && Poly.equal
            (field "attempt_id" (Public.decode execution_bytes))
            (`String summary.run.id))
      "Terminal execution hash/identity mismatch";
    let result_ref = field "results" operation in
    require
      (Poly.equal (field "path" result_ref) (`String terminal.results_file)
       && Poly.equal (field "sha256" result_ref) (`String terminal.results_digest))
      "Terminal results reference mismatch";
    let results_path = local terminal.results_file in
    let results_bytes = contents results_path in
    require
      (String.equal (digest results_bytes) terminal.results_digest
       && same_json (Public.decode results_bytes) results)
      "Terminal results hash/context mismatch";
    let provenance = field "provenance" results in
    require
      (Poly.equal
         (field "operation" provenance)
         (`String (Filename.concat terminal.attempt "operation.json"))
       && Poly.equal (field "contract" provenance) (field "contract" operation)
       && Poly.equal (field "schema_version" results) (`Int 1)
       && Poly.equal (field "run_id" results) (field "attempt_id" operation)
       && not (String.is_empty (text (field "run_id" results))))
      "Terminal results operation provenance mismatch";
    let candidates = ref [] in
    let add ?(external_hash = false) ?(observed = false) path sha256 =
      let path = resolve ~root ~external_hash path in
      match List.find !candidates ~f:(fun (p, _, _) -> String.equal p path) with
      | Some (_, hash, _) ->
        require (Option.equal String.equal hash sha256) "Conflicting artifact hashes"
      | None ->
        require (List.length !candidates < 32) "Artifact catalog exceeds 32 entries";
        candidates := !candidates @ [ path, sha256, observed ]
    in
    add terminal.results_file (Some terminal.results_digest);
    (match field "acceptance_report" operation with
     | `Null -> ()
     | reference ->
       add (text (field "path" reference)) (Some (text (field "sha256" reference))));
    (match field "postcheck_record" operation with
     | `Null -> ()
     | path -> add (text path) (Some (text (field "postcheck_sha256" operation))));
    let inventory = field "mapped_files" operation in
    let add_mapped path =
      match field "sha256" (field path inventory) with
      | `String hash -> add path (Some hash)
      | _ -> failwith "Raw artifact lacks exact hash inventory"
    in
    (match field "raw_artifacts" results with
     | `Null -> ()
     | values -> List.iter (Public.list values) ~f:(fun path -> add_mapped (text path)));
    List.iter [ "metrics"; "checks"; "synthesis_checks" ] ~f:(fun group ->
      match field group results with
      | `Assoc values ->
        List.iter values ~f:(fun (_, value) ->
          match field "source" value with
          | `String source ->
            (match field "sha256" (field source inventory) with
             | `String hash -> add source (Some hash)
             | _ -> add ~observed:true source None)
          | _ -> ())
      | _ -> ());
    let selected = field "selected_evidence" provenance in
    require
      (same_json selected (field "selected_evidence" operation))
      "Selected evidence context mismatch";
    (match selected with
     | `Null -> ()
     | values ->
       List.iter (Public.list values) ~f:(fun value ->
         match field "source" value, field "sha256" value with
         | `String source, `String hash ->
           let source_path = resolve ~root ~external_hash:true source in
           let checkpoints = Public.list (field "selected_checkpoints" operation) in
           require
             (List.exists checkpoints ~f:(fun checkpoint ->
                Poly.equal (field "boundary" checkpoint) (field "boundary" value)
                && String.is_prefix
                     source_path
                     ~prefix:
                       (Filename_unix.realpath (text (field "path" checkpoint)) ^ "/")))
             "Selected source is outside its declared checkpoint";
           require
             (Poly.equal
                (field "sha256" (field (text (field "mapped" value)) inventory))
                (`String hash))
             "Selected source differs from mapped hash inventory";
           add ~external_hash:true source (Some hash)
         | _ -> ()));
    let catalog =
      List.map !candidates ~f:(fun (path, declared, observed) ->
        let bytes = contents path in
        let sha256 = digest bytes in
        Option.iter declared ~f:(fun expected ->
          require (String.equal sha256 expected) "Artifact declared SHA-256 mismatch");
        let reference : Reference.t =
          { id = ""
          ; run = summary.run
          ; terminal_attempt = terminal.attempt
          ; label =
              label
                ~suffix:
                  (if observed then " [observed SHA-256; not provider-declared]" else "")
                (Filename.basename path)
          ; path
          ; sha256
          ; size = String.length bytes
          ; kind = (if is_text bytes then "text" else "binary")
          }
        in
        { reference with
          id = digest (Sexp.to_string_mach (Reference.sexp_of_t reference))
        })
    in
    locked (fun () ->
      let old =
        List.filter !references ~f:(fun old ->
          not (List.exists catalog ~f:(fun r -> String.equal r.id old.id)))
      in
      references := List.take (catalog @ old) 1024);
    catalog
;;

let read ~(reference : Reference.t) ~offset ~limit : Asic_artifact.Page.t =
  let page ?error ~next_offset ~eof text =
    { Asic_artifact.Page.artifact_id = reference.id
    ; run = reference.run
    ; terminal_attempt = reference.terminal_attempt
    ; sha256 = reference.sha256
    ; offset
    ; limit
    ; next_offset
    ; eof
    ; text
    ; error
    }
  in
  match
    Or_error.try_with (fun () ->
      require
        (locked (fun () -> List.exists !references ~f:(Reference.equal reference)))
        "Artifact reference was not listed (or expired); relist artifacts";
      require (offset >= 0 && offset <= reference.size) "Artifact offset out of range";
      require (limit > 0 && limit <= max_page) "Artifact limit must be 1..65536 bytes";
      let bytes = contents reference.path in
      require
        (String.length bytes = reference.size
         && String.equal (digest bytes) reference.sha256)
        "Artifact changed since listing (SHA-256/size mismatch)";
      require
        (String.equal reference.kind "text" && is_text bytes)
        "Binary artifact has no text view";
      let rec boundary i last =
        if i = String.length bytes || i >= offset + limit
        then last
        else (
          let width, _ = scalar bytes i in
          if i + width > offset + limit then last else boundary (i + width) (i + width))
      in
      if offset < String.length bytes then ignore (scalar bytes offset : int * int);
      let next_offset = boundary offset offset in
      require
        (next_offset > offset || offset = String.length bytes)
        "Artifact limit too small for next UTF-8 scalar";
      page
        ~next_offset
        ~eof:(next_offset = String.length bytes)
        (sanitized (String.sub bytes ~pos:offset ~len:(next_offset - offset))))
  with
  | Ok page -> page
  | Error error ->
    let error = Error.to_string_hum error in
    let error = if is_text error then sanitized error else "Artifact read failed" in
    page ~error ~next_offset:offset ~eof:false ""
;;

let read_bytes ~(reference : Reference.t) ~offset ~limit : Asic_artifact.Byte_page.t =
  let page ?error ~next_offset ~eof bytes_hex =
    { Asic_artifact.Byte_page.artifact_id = reference.id
    ; run = reference.run
    ; terminal_attempt = reference.terminal_attempt
    ; sha256 = reference.sha256
    ; offset
    ; limit
    ; next_offset
    ; eof
    ; bytes_hex
    ; error
    }
  in
  match
    Or_error.try_with (fun () ->
      require
        (locked (fun () -> List.exists !references ~f:(Reference.equal reference)))
        "Artifact reference was not listed (or expired); relist artifacts";
      require (offset >= 0 && offset <= reference.size) "Artifact offset out of range";
      require (limit > 0 && limit <= max_page) "Artifact limit must be 1..65536 bytes";
      let bytes = contents reference.path in
      require
        (String.length bytes = reference.size
         && String.equal (digest bytes) reference.sha256)
        "Artifact changed since listing (SHA-256/size mismatch)";
      let length = Int.min limit (String.length bytes - offset) in
      let next_offset = offset + length in
      let bytes_hex =
        String.sub bytes ~pos:offset ~len:length
        |> Cryptokit.transform_string (Cryptokit.Hexa.encode ())
      in
      page ~next_offset ~eof:(next_offset = String.length bytes) bytes_hex)
  with
  | Ok page -> page
  | Error error ->
    let error = Error.to_string_hum error in
    let error = if is_text error then sanitized error else "Artifact read failed" in
    page ~error ~next_offset:offset ~eof:false ""
;;
