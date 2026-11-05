open! Core

type member =
  { tile : string
  ; kind : string
  }
[@@deriving sexp]

type artifact =
  { id : string
  ; sha256 : string option
  ; size : int option
  }
[@@deriving sexp]

type testing =
  { attempt : string option
  ; case_id : string option
  ; artifact : artifact option
  }
[@@deriving sexp]

type timing =
  { stage : string
  ; filter : string
  ; row_id : string option
  ; run : string option [@sexp.option]
  ; source_digest : string option [@sexp.option]
  ; analysis : Hardcaml_workbench_protocol.Asic_inspection.Analysis_target.t option
       [@sexp.option]
  }
[@@deriving sexp]

type workspace =
  { id : string
  ; members : member list
  ; focus : string option
  ; testing : testing option
  ; timing : timing option
  }
[@@deriving sexp]

type t =
  { schema_version : int
  ; project_key : string
  ; session : string
  ; active : string option
  ; workspaces : workspace list
  ; workloads : (string * Workloads_view.saved) list
       [@sexp.default []] [@sexp_drop_default.equal]
  }
[@@deriving sexp]

let max_file_size = 256 * 1024
let fail message = failwith ("Navigation preferences: " ^ message)

let check_string ?(empty = false) value =
  if String.length value > 4096 || ((not empty) && String.is_empty value)
  then fail "invalid string length"
;;

let check_optional value = Option.iter value ~f:(fun value -> check_string value)

let unique values =
  if List.contains_dup values ~compare:String.compare then fail "duplicate identity"
;;

let validate (t : t) =
  if t.schema_version <> 1 then fail "unsupported schema";
  check_string t.project_key;
  check_string t.session;
  check_optional t.active;
  if List.length t.workspaces > 256 then fail "workspace count limit exceeded";
  let workspace_ids = List.map t.workspaces ~f:(fun w -> w.id) in
  unique workspace_ids;
  if Option.exists t.active ~f:(fun id ->
       not (List.mem workspace_ids id ~equal:String.equal))
  then fail "active workspace is not saved";
  let members = List.concat_map t.workspaces ~f:(fun w -> w.members) in
  if List.length members > 1024 then fail "member count limit exceeded";
  unique (List.map members ~f:(fun m -> m.tile));
  if List.length t.workloads > 128 then fail "workload selection count exceeded";
  unique (List.map t.workloads ~f:fst);
  List.iter t.workloads ~f:(fun (tile, saved) ->
    check_string tile;
    if not
         (List.exists members ~f:(fun m ->
            String.equal m.tile tile && String.equal m.kind "workloads"))
    then fail "workload tile not saved";
    ignore (Workloads_view.restore saved : Workloads_view.t));
  List.iter t.workspaces ~f:(fun w ->
    check_string w.id;
    List.iter w.members ~f:(fun m ->
      check_string m.tile;
      check_string m.kind);
    check_optional w.focus;
    if Option.exists w.focus ~f:(fun id ->
         not (List.exists w.members ~f:(fun m -> String.equal m.tile id)))
    then fail "focus is not a workspace member";
    Option.iter w.testing ~f:(fun testing ->
      check_optional testing.attempt;
      check_optional testing.case_id;
      if Option.is_some testing.case_id && Option.is_none testing.attempt
      then fail "case requires attempt";
      if Option.is_some testing.artifact && Option.is_none testing.attempt
      then fail "artifact requires attempt";
      Option.iter testing.artifact ~f:(fun artifact ->
        check_string artifact.id;
        check_optional artifact.sha256;
        if Option.exists artifact.size ~f:(fun size -> size < 0)
        then fail "negative artifact size"));
    Option.iter w.timing ~f:(fun timing ->
      check_string timing.stage;
      check_string ~empty:true timing.filter;
      check_optional timing.row_id;
      check_optional timing.run;
      check_optional timing.source_digest;
      Option.iter timing.analysis ~f:(fun a ->
        List.iter
          [ a.attempt_id
          ; a.occurrence_id
          ; a.analysis_id
          ; a.source_digest
          ; a.execution_sha256
          ]
          ~f:check_string)))
;;

let encode t =
  validate t;
  let text = Sexp.to_string_hum (sexp_of_t t) ^ "\n" in
  if String.length text > max_file_size then fail "file size limit exceeded";
  text
;;

let decode ~project_key text =
  if String.length text > max_file_size then fail "file size limit exceeded";
  let t = t_of_sexp (Sexp.of_string text) in
  validate t;
  if not (String.equal t.project_key project_key) then fail "project/environment mismatch";
  t
;;

let create ~project_key ~session ~active ~workspaces =
  let t =
    { schema_version = 1; project_key; session; active; workspaces; workloads = [] }
  in
  ignore (encode t : string);
  t
;;

let with_workloads t workloads =
  let t = { t with workloads } in
  ignore (encode t : string);
  t
;;

let path ~state_directory ~project_key =
  Filename.concat state_directory ("navigation-" ^ Plain_rpc.digest project_key ^ ".sexp")
;;

let load ~state_directory ~project_key =
  let file = path ~state_directory ~project_key in
  match Sys_unix.file_exists file with
  | `No -> None
  | `Unknown -> fail "cannot inspect sidecar"
  | `Yes ->
    if Int64.((Core_unix.stat file).st_size > of_int max_file_size)
    then fail "file size limit exceeded";
    (* Also cap the actual read: the file may change after stat. *)
    let text =
      In_channel.with_file file ~f:(fun channel ->
        let buffer = Bytes.create (max_file_size + 1) in
        let rec read pos =
          if pos > max_file_size then fail "file size limit exceeded";
          let count =
            In_channel.input channel ~buf:buffer ~pos ~len:(Bytes.length buffer - pos)
          in
          if count = 0
          then Bytes.to_string (Bytes.sub buffer ~pos:0 ~len:pos)
          else read (pos + count)
        in
        read 0)
    in
    Some (decode ~project_key text)
;;

let save ~state_directory t =
  let data = encode t in
  (* A failed load must never be "repaired" by discarding the saved intent. *)
  ignore (load ~state_directory ~project_key:t.project_key : t option);
  Core_unix.mkdir_p state_directory ~perm:0o700;
  let temp = Filename_unix.temp_file ~in_dir:state_directory ".navigation-" ".tmp" in
  Exn.protect
    ~finally:(fun () ->
      if Poly.equal (Sys_unix.file_exists temp) `Yes then Core_unix.unlink temp)
    ~f:(fun () ->
      Out_channel.write_all temp ~data;
      Core_unix.rename ~src:temp ~dst:(path ~state_directory ~project_key:t.project_key))
;;

let test_fixture () =
  create
    ~project_key:"project/environment"
    ~session:"registry-session"
    ~active:(Some "testing-workspace")
    ~workspaces:
      [ { id = "testing-workspace"
        ; members = [ { tile = "testing-tile"; kind = "testing" } ]
        ; focus = Some "testing-tile"
        ; testing =
            Some
              { attempt = Some "old-attempt"
              ; case_id = Some "exact-case"
              ; artifact =
                  Some { id = "exact-artifact"; sha256 = Some "digest"; size = Some 0 }
              }
        ; timing = None
        }
      ; { id = "timing-workspace"
        ; members = [ { tile = "timing-tile"; kind = "timing" } ]
        ; focus = None
        ; testing = None
        ; timing =
            Some
              { stage = "route"
              ; filter = ""
              ; row_id = Some "path-42"
              ; run = Some "stable-run-reference"
              ; source_digest = Some "source-digest"
              ; analysis = None
              }
        }
      ]
;;

let rejects f = assert (Result.is_error (Or_error.try_with f))

let%test_unit "navigation roundtrip preserves exact stable IDs and optional metadata" =
  let t = test_fixture () in
  let decoded = decode ~project_key:t.project_key (encode t) in
  assert (Sexp.equal (sexp_of_t t) (sexp_of_t decoded));
  let empty = create ~project_key:"p" ~session:"s" ~active:None ~workspaces:[] in
  assert (String.equal (encode empty) (encode (decode ~project_key:"p" (encode empty))));
  rejects (fun () -> decode ~project_key:"different/environment" (encode t));
  rejects (fun () -> decode ~project_key:t.project_key "((truncated");
  rejects (fun () -> encode { t with schema_version = 2 });
  rejects (fun () ->
    decode ~project_key:t.project_key (String.make (max_file_size + 1) ' '))
;;

let%test_unit "suite-level artifacts roundtrip without a case" =
  let t = test_fixture () in
  let w = List.hd_exn t.workspaces in
  let testing = { (Option.value_exn w.testing) with case_id = None } in
  let t = { t with workspaces = [ { w with testing = Some testing } ] } in
  let decoded = decode ~project_key:t.project_key (encode t) in
  let restored = Option.value_exn (List.hd_exn decoded.workspaces).testing in
  assert (Option.is_none restored.case_id);
  assert (Option.equal String.equal restored.attempt testing.attempt);
  assert (Option.is_some restored.artifact);
  assert (Sexp.equal (sexp_of_t t) (sexp_of_t decoded))
;;

let%test_unit "historical schema-1 timing rows decode without evidence identity" =
  let historical =
    "((schema_version 1)(project_key project/environment)(session registry-session)\n\
     (active (timing-workspace))\n\
     (workspaces (((id timing-workspace)(members (((tile timing-tile)(kind timing))))\n\
     (focus ())(testing ())\n\
     (timing (((stage route)(filter \"\")(row_id (path-42)))))))))"
  in
  let t = decode ~project_key:"project/environment" historical in
  let timing = Option.value_exn (List.hd_exn t.workspaces).timing in
  assert (t.schema_version = 1);
  assert (Option.equal String.equal timing.row_id (Some "path-42"));
  assert (Option.is_none timing.run);
  assert (Option.is_none timing.source_digest);
  assert (
    Sexp.equal (sexp_of_t t) (sexp_of_t (decode ~project_key:t.project_key (encode t))))
;;

let%test_unit "timing evidence identity strings obey sidecar bounds" =
  let t = test_fixture () in
  let w = List.last_exn t.workspaces in
  let timing = Option.value_exn w.timing in
  let with_timing timing =
    { t with workspaces = [ { w with timing = Some timing } ]; active = None }
  in
  rejects (fun () -> encode (with_timing { timing with run = Some "" }));
  rejects (fun () ->
    encode (with_timing { timing with source_digest = Some (String.make 4097 'x') }))
;;

let%test_unit "navigation rejects duplicate and inconsistent identities" =
  let t = test_fixture () in
  let w = List.hd_exn t.workspaces in
  let only w = { t with workspaces = [ w ] } in
  rejects (fun () -> encode { t with workspaces = [ w; w ] });
  rejects (fun () -> encode (only { w with members = w.members @ w.members }));
  rejects (fun () ->
    encode { t with workspaces = [ w; { w with id = "other-workspace" } ] });
  rejects (fun () -> encode { t with active = Some "missing-workspace" });
  rejects (fun () -> encode (only { w with focus = Some "timing-tile" }));
  let testing = Option.value_exn w.testing in
  rejects (fun () ->
    encode (only { w with testing = Some { testing with attempt = None } }));
  rejects (fun () ->
    encode
      (only { w with testing = Some { testing with attempt = None; case_id = None } }));
  let artifact = Option.value_exn testing.artifact in
  rejects (fun () ->
    encode
      (only
         { w with
           testing =
             Some { testing with artifact = Some { artifact with size = Some (-1) } }
         }));
  (* Decode must validate too, even when the invalid record bypassed encode. *)
  rejects (fun () ->
    decode
      ~project_key:t.project_key
      (Sexp.to_string (sexp_of_t { t with workspaces = [ w; w ] })))
;;

let%test_unit "navigation bounds strings, entries and total encoded size" =
  let t = test_fixture () in
  rejects (fun () -> encode { t with session = "" });
  rejects (fun () -> encode { t with session = String.make 4097 'x' });
  let workspace i =
    { id = Int.to_string i; members = []; focus = None; testing = None; timing = None }
  in
  rejects (fun () ->
    encode { t with active = None; workspaces = List.init 257 ~f:workspace });
  let w = workspace 0 in
  rejects (fun () ->
    encode
      { t with
        active = None
      ; workspaces =
          [ { w with
              members =
                List.init 1025 ~f:(fun i -> { tile = Int.to_string i; kind = "k" })
            }
          ]
      });
  rejects (fun () ->
    encode
      { t with
        active = None
      ; workspaces =
          List.init 100 ~f:(fun i ->
            { (workspace i) with
              timing =
                Some
                  { stage = "route"
                  ; filter = String.make 4096 'x'
                  ; row_id = None
                  ; run = None
                  ; source_digest = None
                  ; analysis = None
                  }
            })
      })
;;

let with_test_directory f =
  let directory = Filename_unix.temp_dir "navigation-preferences-test-" "" in
  Exn.protect
    ~finally:(fun () ->
      List.iter (Sys_unix.ls_dir directory) ~f:(fun file ->
        Core_unix.unlink (Filename.concat directory file));
      Core_unix.rmdir directory)
    ~f:(fun () -> f directory)
;;

let%test_unit "navigation absent, corrupt and oversized sidecars stay isolated and intact"
  =
  with_test_directory (fun state_directory ->
    let t = test_fixture () in
    let file = path ~state_directory ~project_key:t.project_key in
    assert (Option.is_none (load ~state_directory ~project_key:t.project_key));
    save ~state_directory t;
    assert (Option.is_none (load ~state_directory ~project_key:"other/environment"));
    List.iter
      [ "broken("
      ; String.make (max_file_size + 1) ' '
      ; encode { t with project_key = "other" }
      ]
      ~f:(fun corrupt ->
        Out_channel.write_all file ~data:corrupt;
        rejects (fun () -> load ~state_directory ~project_key:t.project_key);
        rejects (fun () -> save ~state_directory t);
        assert (String.equal (In_channel.read_all file) corrupt);
        assert (List.length (Sys_unix.ls_dir state_directory) = 1)))
;;

let%test_unit "navigation atomic replacement leaves old readers complete and rejects \
               invalid writes"
  =
  with_test_directory (fun state_directory ->
    let t = test_fixture () in
    save ~state_directory t;
    let file = path ~state_directory ~project_key:t.project_key in
    let other = { t with project_key = "other/environment"; session = "other-session" } in
    save ~state_directory other;
    assert (String.equal (In_channel.read_all file) (encode t));
    assert (
      String.equal
        (Option.value_exn (load ~state_directory ~project_key:other.project_key)).session
        other.session);
    let next = { t with active = Some "timing-workspace" } in
    In_channel.with_file file ~f:(fun old_reader ->
      save ~state_directory next;
      assert (String.equal (In_channel.input_all old_reader) (encode t));
      assert (String.equal (In_channel.read_all file) (encode next)));
    let loaded = Option.value_exn (load ~state_directory ~project_key:t.project_key) in
    assert (Option.equal String.equal loaded.active next.active);
    rejects (fun () -> save ~state_directory { next with active = Some "missing" });
    assert (String.equal (In_channel.read_all file) (encode next));
    assert (List.length (Sys_unix.ls_dir state_directory) = 2))
;;
