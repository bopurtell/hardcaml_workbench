open! Core

(** A pure inspection projection of cached [Asic.Summary] values. No provider IO or
    interpretation of cell names, timing, completion, acceptance, or producer JSON. *)
module Sort = struct
  type t =
    | Count_desc
    | Count_asc
    | Name_asc
    | Name_desc
  [@@deriving enumerate, equal, sexp]

  let next = function
    | Count_desc -> Count_asc
    | Count_asc -> Name_asc
    | Name_asc -> Name_desc
    | Name_desc -> Count_desc
  ;;
end

module Total = struct
  type t =
    | Unknown
    | Zero
    | Positive of int
    | Invalid of int
  [@@deriving equal, sexp]

  let of_reported = function
    | None -> Unknown
    | Some 0 -> Zero
    | Some n when n > 0 -> Positive n
    | Some n -> Invalid n
  ;;
end

module Row = struct
  (** [name] is the stable identity, with exact spelling/case preserved. Duplicate names
      in the source are combined. If a sum exceeds int64 bounds, [count] saturates and
      [count_overflow] is set: the count must be labelled overflow, never presented as an
      exact value. Overflow is sticky, including cancellation. [share] is a percentage of
      the reported total, never of a filtered subtotal. Missing/zero/invalid totals (or
      negative counts) have no percentage. *)
  type t =
    { name : string
    ; count : int64
    ; count_overflow : bool
    ; share : float option
    }
  [@@deriving compare, equal, sexp]
end

module Coverage = struct
  type t =
    | Unknown_total
    | Invalid_total
    | No_breakdown
    | Matches
    | Mismatch
    | Overflow
  [@@deriving equal, sexp]
end

type t =
  { total : Total.t
  ; breakdown_count : int64
  (** A checked accumulator, not an exact total when [breakdown_overflow] is true. *)
  ; breakdown_overflow : bool
  ; coverage : Coverage.t
  ; rows : Row.t list
  }
[@@deriving equal, sexp]

let compare_rows sort (a : Row.t) (b : Row.t) =
  match (sort : Sort.t) with
  | Name_asc -> String.compare a.name b.name
  | Name_desc -> String.compare b.name a.name
  | Count_desc | Count_asc ->
    let order =
      match sort with
      | Count_desc -> Int64.compare b.count a.count
      | Count_asc -> Int64.compare a.count b.count
      | Name_asc | Name_desc -> assert false
    in
    if order = 0 then String.compare a.name b.name else order
;;

(** Checked signed addition, without performing an overflowing operation. *)
let add_count a b =
  if Int64.(b > zero && a > max_value - b)
  then Int64.max_value, true
  else if Int64.(b < zero && a < min_value - b)
  then Int64.min_value, true
  else Int64.(a + b), false
;;

let project (summary : Asic.Summary.t) =
  let total = Total.of_reported summary.cell_count in
  let counts =
    List.fold summary.cells ~init:String.Map.empty ~f:(fun counts (name, count) ->
      Map.update counts name ~f:(fun previous ->
        let previous, overflow = Option.value previous ~default:(0L, false) in
        if overflow then previous, true else add_count previous (Int64.of_int count)))
  in
  let rows =
    Map.to_alist counts
    |> List.map ~f:(fun (name, (count, count_overflow)) ->
      let share =
        match total with
        | Positive n when (not count_overflow) && Int64.(count >= zero) ->
          Some (Int64.to_float count /. Float.of_int n *. 100.)
        | Unknown | Zero | Invalid _ | Positive _ -> None
      in
      { Row.name; count; count_overflow; share })
  in
  let breakdown_count, breakdown_overflow =
    List.fold rows ~init:(0L, false) ~f:(fun (sum, overflow) row ->
      if overflow
      then sum, true
      else (
        let sum, overflow = add_count sum row.Row.count in
        sum, overflow || row.count_overflow))
  in
  let coverage =
    if breakdown_overflow
    then Coverage.Overflow
    else (
      match total with
      | Unknown -> Coverage.Unknown_total
      | Invalid _ -> Invalid_total
      | Zero | Positive _ ->
        if List.is_empty rows
        then No_breakdown
        else (
          let reported =
            match total with
            | Zero -> 0L
            | Positive n -> Int64.of_int n
            | Unknown | Invalid _ -> assert false
          in
          if Int64.equal reported breakdown_count then Matches else Mismatch))
  in
  { total; breakdown_count; breakdown_overflow; coverage; rows }
;;

(** Case-insensitive substring matching on the literal cell name. Empty filters match all
    rows; sorting never changes identity or the denominator. *)
let rows t ~filter ~sort =
  let substring = String.lowercase filter in
  List.filter t.rows ~f:(fun row ->
    String.is_substring (String.lowercase row.Row.name) ~substring)
  |> List.sort ~compare:(compare_rows sort)
;;

let%test_unit "deterministic ties, all sort modes, literal filtering" =
  let row name count =
    { Row.name; count = Int64.of_int count; count_overflow = false; share = None }
  in
  let t =
    { total = Unknown
    ; breakdown_count = 8L
    ; breakdown_overflow = false
    ; coverage = Unknown_total
    ; rows = [ row "z" 3; row "A" 3; row "a" 2 ]
    }
  in
  let names sort filter = rows t ~sort ~filter |> List.map ~f:(fun row -> row.Row.name) in
  [%test_result: string list] (names Count_desc "") ~expect:[ "A"; "z"; "a" ];
  [%test_result: string list] (names Count_asc "") ~expect:[ "a"; "A"; "z" ];
  [%test_result: string list] (names Name_asc "") ~expect:[ "A"; "a"; "z" ];
  [%test_result: string list] (names Name_desc "") ~expect:[ "z"; "a"; "A" ];
  [%test_result: string list] (names Count_desc "A") ~expect:[ "A"; "a" ];
  [%test_result: string list] (names Count_desc "missing") ~expect:[];
  assert (Sort.equal (Sort.next Name_desc) Count_desc)
;;

let%test_unit "checked accumulation detects both signed bounds before addition" =
  [%test_result: int64 * bool]
    (add_count Int64.max_value 1L)
    ~expect:(Int64.max_value, true);
  [%test_result: int64 * bool]
    (add_count Int64.min_value (-1L))
    ~expect:(Int64.min_value, true);
  [%test_result: int64 * bool]
    (add_count Int64.max_value (-1L))
    ~expect:(Int64.(max_value - 1L), false);
  [%test_result: int64 * bool]
    (add_count Int64.min_value 1L)
    ~expect:(Int64.(min_value + 1L), false)
;;

let%test_unit "total classification preserves missing, zero and invalid evidence" =
  assert (Total.equal (Total.of_reported None) Unknown);
  assert (Total.equal (Total.of_reported (Some 0)) Zero);
  assert (Total.equal (Total.of_reported (Some (-1))) (Invalid (-1)));
  assert (Total.equal (Total.of_reported (Some 20)) (Positive 20))
;;
