open! Core

module Badge = struct
  type t =
    | Exceptions
    | Always
    | Hidden
  [@@deriving equal, sexp]
end

type t =
  { header : bool
  ; title : bool
  ; badge : Badge.t
  ; run_reference : bool
  ; freshness : bool
  ; hints : bool
  ; frame : bool
  ; padding : int
  ; run_selector_rows : int
  ; string_compression : bool
  ; decimal_places : int
  }
[@@deriving equal, sexp]

type overrides =
  { header : bool option
  ; title : bool option
  ; badge : Badge.t option
  ; run_reference : bool option
  ; freshness : bool option
  ; hints : bool option
  ; frame : bool option
  ; padding : int option
  ; run_selector_rows : int option
  ; string_compression : bool option
  ; decimal_places : int option
  }
[@@deriving equal, sexp]

let inherit_ : overrides =
  { header = None
  ; title = None
  ; badge = None
  ; run_reference = None
  ; freshness = None
  ; hints = None
  ; frame = None
  ; padding = None
  ; run_selector_rows = None
  ; string_compression = None
  ; decimal_places = None
  }
;;

(* WB-048: run reference and freshness describe run selection/data, not appearance, so
   they stay session-local. Everything else is an explicit appearance choice. *)
let persisted (o : overrides) = { o with run_reference = None; freshness = None }

let defaults : t =
  { header = true
  ; title = true
  ; badge = Exceptions
  ; run_reference = false
  ; freshness = true
  ; hints = true
  ; frame = true
  ; padding = 0
  ; run_selector_rows = 4
  ; string_compression = true
  ; decimal_places = 3
  }
;;

let navigation =
  { inherit_ with header = Some false; title = Some false; hints = Some false }
;;

let apply (base : t) (o : overrides) : t =
  { header = Option.value o.header ~default:base.header
  ; title = Option.value o.title ~default:base.title
  ; badge = Option.value o.badge ~default:base.badge
  ; run_reference = Option.value o.run_reference ~default:base.run_reference
  ; freshness = Option.value o.freshness ~default:base.freshness
  ; hints = Option.value o.hints ~default:base.hints
  ; frame = Option.value o.frame ~default:base.frame
  ; padding = Int.max 0 (Option.value o.padding ~default:base.padding)
  ; run_selector_rows =
      Int.max 1 (Option.value o.run_selector_rows ~default:base.run_selector_rows)
  ; string_compression =
      Option.value o.string_compression ~default:base.string_compression
  ; decimal_places =
      Int.max 0 (Int.min 9 (Option.value o.decimal_places ~default:base.decimal_places))
  }
;;

let resolve ~app ~workspace ~tile = apply (apply (apply defaults app) workspace) tile

module Binding = struct
  type t =
    | Follow
    | Pinned
    | Project
  [@@deriving equal, sexp]
end

let show_badge (t : t) binding =
  match t.badge, binding with
  | Hidden, _ -> false
  | Always, _ | Exceptions, Binding.Pinned -> true
  | Exceptions, (Follow | Project) -> false
;;

let show_title (t : t) = t.header && t.title

let%test_unit "sparse inheritance and reset preserve independent fields" =
  let app = { inherit_ with padding = Some 2; badge = Some Always; hints = Some false } in
  let workspace = { inherit_ with padding = Some 1; frame = Some false } in
  let tile = { inherit_ with padding = Some 3; hints = Some true } in
  let resolved = resolve ~app ~workspace ~tile in
  assert (resolved.padding = 3 && resolved.hints && not resolved.frame);
  assert (Badge.equal resolved.badge Always);
  let reset = resolve ~app ~workspace ~tile:{ tile with padding = None } in
  assert (reset.padding = 1 && reset.hints && not reset.frame);
  assert ((resolve ~app:inherit_ ~workspace:inherit_ ~tile:inherit_).run_selector_rows = 4)
;;

let%test_unit "quiet follow and project, visible pins even without header" =
  let t = apply defaults navigation in
  assert (not (show_title t));
  assert (not (show_badge t Follow));
  assert (not (show_badge t Project));
  assert (show_badge t Pinned);
  List.iter [ Binding.Follow; Pinned; Project ] ~f:(fun binding ->
    assert (show_badge (apply t { inherit_ with badge = Some Always }) binding);
    assert (not (show_badge (apply t { inherit_ with badge = Some Hidden }) binding)))
;;

let%test_unit "invalid dimensions normalize without changing parent values" =
  let t =
    apply defaults { inherit_ with padding = Some (-9); run_selector_rows = Some 0 }
  in
  assert (t.padding = 0 && t.run_selector_rows = 1);
  assert (defaults.run_selector_rows = 4)
;;
