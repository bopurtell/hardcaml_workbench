open! Core

module Preset = struct
  type t =
    | Instrument
    | Structured
    | Minimal
    | Studio
    | Structured_studio
  [@@deriving enumerate, equal, sexp]

  let label = function
    | Instrument -> "A - Instrument"
    | Structured -> "B - Structured"
    | Minimal -> "C - Minimal"
    | Studio -> "D - Studio"
    | Structured_studio -> "E - Structured studio"
  ;;

  let key = function
    | Instrument -> "instrument"
    | Structured -> "structured"
    | Minimal -> "minimal"
    | Studio -> "studio"
    | Structured_studio -> "structured-studio"
  ;;

  let of_key key_ = List.find all ~f:(fun t -> String.equal (key t) key_)
end

module Color = struct
  type t =
    | Vivid
    | Selective
    | Restrained
  [@@deriving enumerate, equal, sexp]

  let label = function
    | Vivid -> "Vivid"
    | Selective -> "Selective"
    | Restrained -> "Restrained"
  ;;

  let key = function
    | Vivid -> "vivid"
    | Selective -> "selective"
    | Restrained -> "restrained"
  ;;

  let of_key key_ = List.find all ~f:(fun t -> String.equal (key t) key_)
end

module Scheme = struct
  type t =
    | Carbon
    | Slate
    | Crimson
    | Neon
  [@@deriving enumerate, equal, sexp]

  let label = function
    | Carbon -> "Carbon"
    | Slate -> "Slate"
    | Crimson -> "Crimson"
    | Neon -> "Neon"
  ;;

  let key t = String.lowercase (label t)
  let of_key key_ = List.find all ~f:(fun t -> String.equal (key t) key_)
end

module Icons = struct
  type t =
    | None_
    | Ascii
    | Unicode
  [@@deriving enumerate, equal, sexp]

  let label = function
    | None_ -> "Off"
    | Ascii -> "ASCII"
    | Unicode -> "Unicode"
  ;;

  let key = function
    | None_ -> "none"
    | Ascii -> "ascii"
    | Unicode -> "unicode"
  ;;

  let of_key key_ = List.find all ~f:(fun t -> String.equal (key t) key_)
end

module Density = struct
  type t =
    | Compact
    | Comfortable
  [@@deriving enumerate, equal, sexp]

  let label = function
    | Compact -> "Compact"
    | Comfortable -> "Comfortable"
  ;;

  let key = function
    | Compact -> "compact"
    | Comfortable -> "comfortable"
  ;;

  let of_key key_ = List.find all ~f:(fun t -> String.equal (key t) key_)
end

type t =
  { preset : Preset.t
  ; color : Color.t
  ; scheme : Scheme.t [@sexp.default Scheme.Carbon]
  ; icons : Icons.t
  ; density : Density.t
  }
[@@deriving equal, sexp]

(* Provisional presentation default; independent of persisted workspace state. *)
let default =
  { preset = Instrument
  ; color = Vivid
  ; scheme = Carbon
  ; icons = Unicode
  ; density = Comfortable
  }
;;

let%test_unit "appearance keys are stable and round trip" =
  List.iter Preset.all ~f:(fun t ->
    assert (Option.equal Preset.equal (Preset.of_key (Preset.key t)) (Some t)));
  List.iter Color.all ~f:(fun t ->
    assert (Option.equal Color.equal (Color.of_key (Color.key t)) (Some t)));
  List.iter Scheme.all ~f:(fun t ->
    assert (Option.equal Scheme.equal (Scheme.of_key (Scheme.key t)) (Some t)));
  List.iter Icons.all ~f:(fun t ->
    assert (Option.equal Icons.equal (Icons.of_key (Icons.key t)) (Some t)));
  List.iter Density.all ~f:(fun t ->
    assert (Option.equal Density.equal (Density.of_key (Density.key t)) (Some t)));
  assert (Option.is_none (Preset.of_key "unknown"))
;;

let%test_unit "legacy appearance defaults to carbon and schemes round trip independently" =
  let legacy =
    t_of_sexp
      (Sexp.of_string "((preset Studio)(color Restrained)(icons Ascii)(density Compact))")
  in
  assert (Scheme.equal default.scheme Carbon);
  assert (Scheme.equal legacy.scheme Carbon);
  assert (
    equal
      legacy
      { default with
        preset = Studio
      ; color = Restrained
      ; icons = Ascii
      ; density = Compact
      });
  List.iter Scheme.all ~f:(fun scheme ->
    let appearance = { legacy with scheme } in
    assert (equal appearance (t_of_sexp (sexp_of_t appearance)));
    let explicit =
      t_of_sexp
        (Sexp.of_string
           (sprintf
              "((preset Studio)(color Restrained)(scheme %s)(icons Ascii)(density \
               Compact))"
              (Scheme.label scheme)))
    in
    assert (equal explicit appearance))
;;
