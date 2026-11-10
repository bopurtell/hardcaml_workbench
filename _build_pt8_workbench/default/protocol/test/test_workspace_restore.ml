open! Core
open Hardcaml_workbench_protocol
module W = Workspace

let ok = function
  | Ok value -> value
  | Error error -> raise_s [%sexp (error : V1.Error.t)]
;;

let mutate (s : W.Snapshot.t) mutation =
  W.apply s (Mutate { expected_revision = s.revision; mutation }) |> ok
;;

let geometry : W.Geometry.t = { x = 2; y = 3; width = 35; height = 9 }

let fixture () =
  let s = W.initial ~session_id:(W.Session_id.of_string "restore") in
  let w = List.hd_exn s.workspaces in
  let first = List.hd_exn s.tiles in
  let run : Run_ref.t =
    { backend = Backend_id.of_string "provider"
    ; id = "selected-and-pinned"
    ; build = None
    ; label = Some "evidence"
    }
  in
  let s = mutate s (Make_independent w.id) in
  let w = W.workspace s w.id in
  let s =
    mutate
      s
      (Select_run
         { workspace = w.id
         ; context = w.context
         ; expected_selection_revision = 0
         ; run = Some run
         })
  in
  let s = mutate s (Rename_workspace { workspace = w.id; name = "My desk" }) in
  let s = mutate s (Set_tile_binding { tile = first.id; binding = Pin_run run }) in
  let s = mutate s (Set_tile_hidden { tile = first.id; hidden = true }) in
  let s = mutate s (Create_tile { workspace = w.id; kind = first.kind; geometry }) in
  let duplicate = List.last_exn s.tiles in
  let s = mutate s (Set_tile_binding { tile = duplicate.id; binding = Pin_run run }) in
  let s = mutate s (Create_tile { workspace = w.id; kind = "custom"; geometry }) in
  let extra = List.last_exn s.tiles in
  let s = mutate s (Set_tile_binding { tile = extra.id; binding = Pin_run run }) in
  let s = mutate s (Set_zoom { workspace = w.id; tile = Some extra.id }) in
  s, w.id, first.id, duplicate.id, extra.id
;;

let%test_unit "restore claims hidden first occurrence, hides extras and preserves exact \
               state"
  =
  let before, workspace, first, duplicate, extra = fixture () in
  let specs = [ "run-selector", geometry; "missing", geometry ] in
  let mutation : W.Mutation.t =
    Restore_default_layout { workspace; preset = "testing"; tiles = specs }
  in
  let after = mutate before mutation in
  let fresh = List.last_exn after.tiles in
  assert (W.Binding.equal fresh.binding Follow);
  assert (String.equal fresh.kind "missing");
  assert (W.Workspace_id.equal fresh.workspace workspace);
  assert (not fresh.hidden);
  assert (W.Geometry.equal fresh.requested_geometry geometry);
  let expected : W.Snapshot.t =
    { before with
      revision = before.revision + 1
    ; next_id = before.next_id + 1
    ; workspaces =
        List.map before.workspaces ~f:(fun w ->
          if W.Workspace_id.equal w.id workspace
          then { w with preset = Some "testing"; zoomed_tile = None }
          else w)
    ; tiles =
        List.map before.tiles ~f:(fun t ->
          if W.Tile_id.equal t.id first
          then { t with hidden = false; requested_geometry = geometry }
          else if W.Tile_id.equal t.id duplicate || W.Tile_id.equal t.id extra
          then { t with hidden = true }
          else t)
        @ [ fresh ]
    }
  in
  assert (W.Snapshot.equal expected after);
  let repeated = mutate after mutation in
  assert (W.Snapshot.equal { after with revision = repeated.revision } repeated);
  assert (repeated.revision = after.revision + 1)
;;

let%test_unit "duplicate specs match counts in registry order and allocate only the \
               deficit"
  =
  let before, workspace, first, duplicate, extra = fixture () in
  let second = { geometry with x = 50 } in
  let third = { geometry with y = 25 } in
  let before = mutate before (Reorder_tile { tile = duplicate; before = Some first }) in
  let mutation : W.Mutation.t =
    Restore_default_layout
      { workspace
      ; preset = "duplicate-definition"
      ; tiles =
          [ "run-selector", geometry; "run-selector", second; "run-selector", third ]
      }
  in
  let after = mutate before mutation in
  assert (W.Geometry.equal (W.tile after duplicate).requested_geometry geometry);
  assert (W.Geometry.equal (W.tile after first).requested_geometry second);
  assert ((not (W.tile after first).hidden) && not (W.tile after duplicate).hidden);
  assert (W.Tile.equal (W.tile after extra) { (W.tile before extra) with hidden = true });
  assert (W.Geometry.equal (List.last_exn after.tiles).requested_geometry third);
  assert (List.length after.tiles = List.length before.tiles + 1);
  assert (
    List.equal
      W.Tile_id.equal
      (List.map before.tiles ~f:(fun t -> t.id))
      (List.map (List.take after.tiles (List.length before.tiles)) ~f:(fun t -> t.id)));
  let repeated = mutate after mutation in
  assert (W.Snapshot.equal { after with revision = repeated.revision } repeated)
;;

let%test_unit "invalid definitions, allocation exhaustion, revision overflow and stale \
               CAS are atomic"
  =
  let s, workspace, _, _, _ = fixture () in
  let mutation preset tiles : W.Mutation.t =
    Restore_default_layout { workspace; preset; tiles }
  in
  let check (s : W.Snapshot.t) ~expected_revision mutation ~kind =
    let original = W.Snapshot.sexp_of_t s in
    let error =
      W.apply s (Mutate { expected_revision; mutation })
      |> Result.error
      |> Option.value_exn
    in
    assert (V1.Error.Kind.equal error.kind kind);
    assert (Sexp.equal original (W.Snapshot.sexp_of_t s));
    assert (W.Snapshot.equal s (W.apply s Get |> ok));
    error
  in
  List.iter
    [ mutation "" [ "new", geometry ]
    ; mutation "valid" []
    ; mutation "valid" [ "new", geometry; " ", geometry ]
    ; mutation "valid" [ "new", geometry; "bad", { geometry with x = -1 } ]
    ; mutation "valid" [ "new", geometry; "bad", { geometry with y = -1 } ]
    ; mutation "valid" [ "new", geometry; "bad", { geometry with width = 0 } ]
    ; mutation "valid" [ "new", geometry; "bad", { geometry with height = 0 } ]
    ]
    ~f:(fun mutation ->
      ignore
        (check s ~expected_revision:s.revision mutation ~kind:Invalid_request
         : V1.Error.t));
  let exhausted = { s with next_id = Int.max_value - 1 } in
  let two_missing = mutation "valid" [ "new-1", geometry; "new-2", geometry ] in
  ignore
    (check
       exhausted
       ~expected_revision:exhausted.revision
       two_missing
       ~kind:Invalid_request
     : V1.Error.t);
  (* Whole-definition validation wins even when the first allocation would fail. *)
  let exhausted = { s with next_id = Int.max_value } in
  let error =
    check
      exhausted
      ~expected_revision:s.revision
      (mutation "valid" [ "new", geometry; "bad", { geometry with width = 0 } ])
      ~kind:Invalid_request
  in
  assert (String.is_substring error.message ~substring:"geometry");
  let overflow = { s with revision = Int.max_value } in
  ignore
    (check overflow ~expected_revision:overflow.revision two_missing ~kind:Invalid_request
     : V1.Error.t);
  ignore
    (check s ~expected_revision:(s.revision - 1) two_missing ~kind:Conflict : V1.Error.t)
;;

let%test_unit "restore operation and resulting snapshot serialize with the existing \
               protocol header"
  =
  let s, workspace, _, _, _ = fixture () in
  let operation : W.Operation.t =
    Mutate
      { expected_revision = s.revision
      ; mutation =
          Restore_default_layout
            { workspace; preset = "overview"; tiles = [ "run-selector", geometry ] }
      }
  in
  assert (V1.version = 1);
  assert (String.equal V1.protocol_header "X-Workbench-Protocol");
  assert (W.schema_version = 1);
  assert (
    W.Operation.equal operation (W.Operation.t_of_sexp (W.Operation.sexp_of_t operation)));
  let buffer = Bin_prot.Common.create_buf (W.Operation.bin_size_t operation) in
  let length = W.Operation.bin_write_t buffer ~pos:0 operation in
  let pos_ref = ref 0 in
  assert (W.Operation.equal operation (W.Operation.bin_read_t buffer ~pos_ref));
  assert (!pos_ref = length);
  let after = W.apply s operation |> ok in
  assert (W.Snapshot.equal after (W.Snapshot.t_of_sexp (W.Snapshot.sexp_of_t after)));
  let buffer = Bin_prot.Common.create_buf (W.Snapshot.bin_size_t after) in
  let length = W.Snapshot.bin_write_t buffer ~pos:0 after in
  let pos_ref = ref 0 in
  assert (W.Snapshot.equal after (W.Snapshot.bin_read_t buffer ~pos_ref));
  assert (!pos_ref = length)
;;
