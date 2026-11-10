open! Core
open Hardcaml_workbench_protocol
module W = Workspace

let initial () = W.initial ~session_id:(W.Session_id.of_string "preset-test")

let mutate s mutation =
  W.apply s (Mutate { expected_revision = s.W.Snapshot.revision; mutation })
  |> Result.ok
  |> Option.value_exn
;;

let%test_unit "legacy snapshot migration is once-only and rename-stable" =
  let s = initial () in
  let rec remove = function
    | Sexp.Atom _ as s -> s
    | Sexp.List xs ->
      Sexp.List
        (List.filter_map xs ~f:(function
          | Sexp.List (Sexp.Atom "preset" :: _) -> None
          | x -> Some (remove x)))
  in
  let loaded = W.Snapshot.t_of_sexp (remove (W.Snapshot.sexp_of_t s)) in
  assert (
    List.equal
      (Option.equal String.equal)
      (List.map loaded.workspaces ~f:(fun w -> w.preset))
      [ Some "overview"; Some "timing" ]);
  let w = List.hd_exn loaded.workspaces in
  let renamed = mutate loaded (Rename_workspace { workspace = w.id; name = "Timing" }) in
  let reloaded = W.Snapshot.t_of_sexp (W.Snapshot.sexp_of_t renamed) in
  assert (
    Option.equal String.equal (List.hd_exn reloaded.workspaces).preset (Some "overview"));
  let custom =
    { s with workspaces = List.map s.workspaces ~f:(fun w -> { w with preset = None }) }
  in
  let reloaded = W.Snapshot.t_of_sexp (W.Snapshot.sexp_of_t custom) in
  assert (List.for_all reloaded.workspaces ~f:(fun w -> Option.is_none w.preset))
;;

let%test_unit "apply additive, reset geometry only, duplicate and custom retention" =
  let s = initial () in
  let w = List.hd_exn s.workspaces
  and t = List.hd_exn s.tiles in
  let g : W.Geometry.t = { x = 2; y = 3; width = 51; height = 12 } in
  let s = mutate s (Create_tile { workspace = w.id; kind = t.kind; geometry = g }) in
  let duplicate = List.last_exn s.tiles in
  let s = mutate s (Create_tile { workspace = w.id; kind = "custom"; geometry = g }) in
  let extra = List.last_exn s.tiles in
  let run : Run_ref.t =
    { backend = Backend_id.of_string "custom-provider"
    ; id = "exact-run"
    ; build = None
    ; label = None
    }
  in
  let s = mutate s (Set_tile_binding { tile = t.id; binding = Pin_run run }) in
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
  let s = mutate s (Set_zoom { workspace = w.id; tile = Some t.id }) in
  let s = mutate s (Set_tile_hidden { tile = duplicate.id; hidden = true }) in
  let before = s in
  let specs = [ "run-selector", g; "checks", g ] in
  let s =
    mutate s (Apply_preset { workspace = w.id; preset = "testing"; tiles = specs })
  in
  assert (W.Geometry.equal (W.tile s t.id).requested_geometry t.requested_geometry);
  assert (List.length s.tiles = List.length before.tiles + 1);
  let s =
    mutate s (Apply_preset { workspace = w.id; preset = "testing"; tiles = specs })
  in
  assert (List.length s.tiles = List.length before.tiles + 1);
  let s =
    mutate s (Reset_arrangement { workspace = w.id; preset = "testing"; tiles = specs })
  in
  assert (W.Geometry.equal (W.tile s t.id).requested_geometry g);
  assert (W.Binding.equal (W.tile s t.id).binding (Pin_run run));
  assert (W.Tile.equal (W.tile s duplicate.id) (W.tile before duplicate.id));
  assert (W.Tile.equal (W.tile s extra.id) extra);
  assert (List.equal W.Context.equal s.contexts before.contexts);
  assert (Option.equal W.Tile_id.equal (W.workspace s w.id).zoomed_tile (Some t.id));
  assert (W.Context_id.equal (W.workspace s w.id).context w.context)
;;

let%test_unit "unknown metadata stays honest and malformed metadata never infers" =
  let s = initial () in
  let w = List.hd_exn s.workspaces in
  let s =
    { s with
      workspaces =
        { w with preset = Some "provider/custom-v2" } :: List.tl_exn s.workspaces
    }
  in
  let s = W.Snapshot.t_of_sexp (W.Snapshot.sexp_of_t s) in
  let s = mutate s (Rename_workspace { workspace = w.id; name = "Timing" }) in
  assert (
    Option.equal String.equal (W.workspace s w.id).preset (Some "provider/custom-v2"));
  let malformed =
    { s with
      workspaces = List.map s.workspaces ~f:(fun w -> { w with preset = Some " " })
    }
  in
  assert (Result.is_error (W.validate malformed));
  let fields =
    match W.Arrangement.sexp_of_t w with
    | Sexp.List fields -> fields
    | _ -> assert false
  in
  let fields =
    List.map fields ~f:(function
      | Sexp.List [ Sexp.Atom "preset"; _ ] ->
        Sexp.List [ Sexp.Atom "preset"; Sexp.Atom "overview" ]
      | field -> field)
  in
  assert (Exn.does_raise (fun () -> W.Arrangement.t_of_sexp (Sexp.List fields)))
;;

let%test_unit "duplicate specs claim occurrences and preserve order, hidden primary and \
               selection"
  =
  let s = initial () in
  let w = List.hd_exn s.workspaces
  and t = List.hd_exn s.tiles in
  let g : W.Geometry.t = { x = 1; y = 2; width = 36; height = 9 } in
  let other : W.Geometry.t = { g with x = 40 } in
  let s = mutate s (Create_tile { workspace = w.id; kind = t.kind; geometry = g }) in
  let duplicate = List.last_exn s.tiles in
  let s = mutate s (Set_tile_hidden { tile = t.id; hidden = true }) in
  let s = mutate s (Reorder_tile { tile = duplicate.id; before = Some t.id }) in
  let before = s in
  let specs = [ t.kind, g; t.kind, other; "checks", g ] in
  let s =
    mutate s (Apply_preset { workspace = w.id; preset = "overview"; tiles = specs })
  in
  assert (
    List.equal W.Tile.equal (List.take s.tiles (List.length before.tiles)) before.tiles);
  let before_reset = s in
  let s =
    mutate s (Reset_arrangement { workspace = w.id; preset = "overview"; tiles = specs })
  in
  assert (
    List.equal
      W.Tile_id.equal
      (List.map s.tiles ~f:(fun t -> t.id))
      (List.map before_reset.tiles ~f:(fun t -> t.id)));
  assert (W.Geometry.equal (W.tile s duplicate.id).requested_geometry g);
  assert (W.Geometry.equal (W.tile s t.id).requested_geometry other);
  assert (W.tile s t.id).hidden;
  assert (List.equal W.Context.equal s.contexts before.contexts);
  let invalid : W.Geometry.t = { g with width = 0 } in
  assert (
    Result.is_error
      (W.apply
         s
         (Mutate
            { expected_revision = s.revision
            ; mutation =
                Reset_arrangement
                  { workspace = w.id
                  ; preset = "overview"
                  ; tiles = [ "new", g; "bad", invalid ]
                  }
            })));
  assert (W.Snapshot.equal s (W.Snapshot.t_of_sexp (W.Snapshot.sexp_of_t s)))
;;
