(** Portable authoring and resolved application data, never registry state. Keys are
    case-sensitive and scoped by config / window / definition respectively. Instances
    always start Main-linked with following tiles; pins and selections are not syntax.

    Use [decode] at file boundaries, then [resolve] before daemon application. The
    resolved codec is for transport/persistence and needs no installed preset catalog.
    Generated sexp/bin_io readers are unchecked; validate after using them. *)
open! Core

module Presentation = struct
  type t =
    { title : bool option [@sexp.default None]
    ; binding_badge : string option [@sexp.default None]
    ; run_reference : bool option [@sexp.default None]
    ; freshness : bool option [@sexp.default None]
    ; hints : bool option [@sexp.default None]
    ; frame : bool option [@sexp.default None]
    ; padding : int option [@sexp.default None]
    ; visible_rows : int option [@sexp.default None]
    ; compact_summary : bool option [@sexp.default None]
    ; horizontal_stages : bool option [@sexp.default None]
    ; string_compression : bool option [@sexp.default None]
    ; decimal_places : int option [@sexp.default None]
    }
  [@@deriving bin_io, compare, equal, sexp]

  let inherit_defaults =
    { title = None
    ; binding_badge = None
    ; run_reference = None
    ; freshness = None
    ; hints = None
    ; frame = None
    ; padding = None
    ; visible_rows = None
    ; compact_summary = None
    ; horizontal_stages = None
    ; string_compression = None
    ; decimal_places = None
    }
  ;;
end

module Tile = struct
  (** Positional correspondence with [template.views], with a stable instance key.
      Optional presentation inherits app policy, then local explicit overrides win. *)
  type t =
    { key : string
    ; presentation : Presentation.t option [@sexp.default None]
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Tree = struct
  (** Same slicing vocabulary as the terminal, but leaves identify tile instances, not
      kinds. Unmentioned tiles remain extras, never discarded. *)
  type t =
    | Leaf of
        { tile : string
        ; min_width : int
        ; min_height : int
        ; weight : int
        }
    | Stack of t list
    | Columns of t list
    | Weighted_columns of (int * t) list
    | Narrow of t
  [@@deriving bin_io, compare, equal, sexp]
end

module Definition = struct
  type t =
    { key : string
    ; template : Workspace_template.t
    ; tiles : Tile.t list
    ; layout : Tree.t option [@sexp.default None]
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Reference = struct
  type t =
    | Builtin of string
    | Custom of string
  [@@deriving bin_io, compare, equal, sexp]
end

module Instance = struct
  type t =
    { key : string
    ; name : string
    ; definition : Reference.t
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Window = struct
  type t =
    { key : string
    ; name : string
    ; workspaces : Instance.t list
    }
  [@@deriving bin_io, compare, equal, sexp]
end

type t =
  { version : int
  ; id : string
  ; definitions : Definition.t list
  ; windows : Window.t list
  }
[@@deriving bin_io, compare, equal, sexp]

let version = 1
let max_encoded_bytes = 4 * 1024 * 1024
let max_definitions = 128
let max_windows = 32
let max_workspaces = 256
let max_tiles = 4096
let max_tree_depth = 32
let max_tree_nodes = 4096
let max_dimension = 1_000_000
let max_sexp_nesting = 256
let max_sexp_comments = 256

let builtin_ids =
  [ "overview"; "timing"; "testing"; "waveforms"; "resources"; "workloads" ]
;;

let is_builtin key = List.mem builtin_ids key ~equal:String.equal

(** Version 1 already permitted user definitions named [resources]. Adding a builtin is
    not permission to expand that version's reserved custom namespace. References and
    template ancestry distinguish the new builtin from an unchanged custom key. Changing
    these reservations requires an authoring-version migration. *)
let custom_key_allowed key =
  not (List.mem [ "overview"; "timing"; "testing"; "waveforms" ] key ~equal:String.equal)
;;

let builtin_definition (d : Definition.t) =
  Option.equal String.equal d.template.preset (Some d.key) && is_builtin d.key
;;

let valid_key key =
  String.length key > 0
  && String.length key <= 128
  && String.for_all key ~f:(fun c ->
    Char.is_alphanum c || Char.equal c '-' || Char.equal c '_' || Char.equal c '.')
;;

let require condition message = if condition then () else failwith message

let unique_keys keys =
  let seen = Hash_set.create (module String) in
  List.iter keys ~f:(fun key ->
    require (valid_key key) ("Invalid authoring key: " ^ key);
    require (not (Hash_set.mem seen key)) ("Duplicate authoring key: " ^ key);
    Hash_set.add seen key)
;;

let validate_definition (d : Definition.t) =
  Or_error.try_with (fun () ->
    require (valid_key d.key) "Invalid definition key";
    Workspace_template.validate d.template |> Or_error.ok_exn;
    require
      (List.length d.tiles = List.length d.template.views)
      "Definition tiles must correspond one-for-one, in order, to template views";
    unique_keys (List.map d.tiles ~f:(fun t -> t.Tile.key));
    List.iter d.tiles ~f:(fun tile ->
      Option.iter tile.presentation ~f:(fun p ->
        Option.iter p.decimal_places ~f:(fun n ->
          require (n >= 0 && n <= 9) "Decimal places must be between 0 and 9");
        List.iter [ p.padding; p.visible_rows ] ~f:(fun n ->
          Option.iter n ~f:(fun n ->
            require (n >= 0 && n <= max_dimension) "Invalid presentation dimension"));
        Option.iter p.binding_badge ~f:(fun badge ->
          require (Workspace_template.valid_label badge) "Invalid binding badge")));
    let tiles = String.Set.of_list (List.map d.tiles ~f:(fun t -> t.Tile.key)) in
    let claimed = Hash_set.create (module String) in
    let nodes = ref 0 in
    let rec tree depth (t : Tree.t) =
      incr nodes;
      require (depth <= max_tree_depth) "Layout exceeds maximum depth";
      require (!nodes <= max_tree_nodes) "Layout exceeds maximum node count";
      let children ts =
        require (not (List.is_empty ts)) "Layout groups must not be empty";
        List.iter ts ~f:(tree (depth + 1))
      in
      match t with
      | Leaf { tile; min_width; min_height; weight } ->
        require (Set.mem tiles tile) ("Unknown layout tile: " ^ tile);
        require (not (Hash_set.mem claimed tile)) ("Repeated layout tile: " ^ tile);
        Hash_set.add claimed tile;
        require
          (min_width > 0
           && min_width <= max_dimension
           && min_height > 0
           && min_height <= max_dimension
           && weight >= 0
           && weight <= max_dimension)
          "Invalid leaf dimensions or weight"
      | Stack ts | Columns ts -> children ts
      | Weighted_columns ts ->
        List.iter ts ~f:(fun (weight, _) ->
          require (weight > 0 && weight <= max_dimension) "Invalid column weight");
        children (List.map ts ~f:snd)
      | Narrow t -> tree (depth + 1) t
    in
    Option.iter d.layout ~f:(tree 1))
;;

(** [resolved] permits builtin definitions and requires their complete definitions.
    Version-1 custom reservations are frozen separately from the expanding catalog. *)
let validate_common ~resolved (t : t) =
  Or_error.try_with (fun () ->
    require (t.version = version) "Unsupported workspace configuration version";
    require (valid_key t.id) "Invalid configuration id";
    require (List.length t.definitions <= max_definitions) "Too many definitions";
    require
      ((not (List.is_empty t.windows)) && List.length t.windows <= max_windows)
      "Configuration requires 1-32 windows";
    unique_keys (List.map t.definitions ~f:(fun d -> d.Definition.key));
    unique_keys (List.map t.windows ~f:(fun w -> w.Window.key));
    let definitions = String.Table.create () in
    let stored_tiles = ref 0 in
    List.iter t.definitions ~f:(fun d ->
      let builtin = builtin_definition d in
      require (resolved || not builtin) "Custom definition shadows a built-in";
      validate_definition d |> Or_error.ok_exn;
      (* A custom definition cannot select compiled preset policy via its template. *)
      require
        (if builtin
         then true
         else custom_key_allowed d.key && Option.is_none d.template.preset)
        "Custom templates must omit preset; built-in templates must match their key";
      stored_tiles := !stored_tiles + List.length d.tiles;
      require (!stored_tiles <= max_tiles) "Too many definition tiles";
      Hashtbl.set definitions ~key:d.key ~data:d);
    let workspaces = ref 0 in
    let instantiated_tiles = ref 0 in
    List.iter t.windows ~f:(fun w ->
      require (Workspace_template.valid_label w.name) "Invalid window name";
      require (not (List.is_empty w.workspaces)) "Windows require at least one workspace";
      unique_keys (List.map w.workspaces ~f:(fun i -> i.Instance.key));
      List.iter w.workspaces ~f:(fun i ->
        incr workspaces;
        require (!workspaces <= max_workspaces) "Too many workspace instances";
        require (Workspace_template.valid_label i.name) "Invalid workspace name";
        let key, must_resolve =
          match i.definition with
          | Builtin key ->
            require (is_builtin key) ("Unknown built-in: " ^ key);
            key, resolved
          | Custom key ->
            require
              (custom_key_allowed key)
              "Custom reference uses a reserved built-in ID";
            key, true
        in
        if must_resolve
        then (
          let d =
            Hashtbl.find definitions key
            |> Option.value_exn ~message:("Missing definition: " ^ key)
          in
          require
            (Bool.equal
               (builtin_definition d)
               (match i.definition with
                | Builtin _ -> true
                | Custom _ -> false))
            "Definition reference/ancestry mismatch";
          instantiated_tiles := !instantiated_tiles + List.length d.tiles;
          require (!instantiated_tiles <= max_tiles) "Too many instantiated tiles"))))
;;

let validate = validate_common ~resolved:false

(* Bound parser nesting as well as semantic tree depth, including unknown fields. Respect
   sexp strings and comments so authoring comments cannot bypass the bound. *)
let check_text text =
  Or_error.try_with (fun () ->
    require
      (String.length text <= max_encoded_bytes)
      "Workspace configuration exceeds 4 MiB";
    let length = String.length text in
    (* Consecutive #; directives nest in the parser even without parentheses. Bound their
       total count conservatively, including nonconsecutive ones. *)
    let sexp_comments = ref 0 in
    let pair i a b =
      i + 1 < length && Char.equal text.[i] a && Char.equal text.[i + 1] b
    in
    let rec scan i depth quoted escaped line_comment block =
      require
        (depth <= max_sexp_nesting && block <= max_sexp_nesting)
        "Configuration sexp nesting exceeds 256";
      if i < length
      then (
        let c = text.[i] in
        if line_comment
        then scan (i + 1) depth false false (not (Char.equal c '\n')) block
        else if quoted
        then
          if escaped
          then scan (i + 1) depth true false false block
          else if Char.equal c '\\'
          then scan (i + 1) depth true true false block
          else scan (i + 1) depth (not (Char.equal c '"')) false false block
        else if block > 0
        then
          if pair i '#' '|'
          then scan (i + 2) depth false false false (block + 1)
          else if pair i '|' '#'
          then scan (i + 2) depth false false false (block - 1)
          else if Char.equal c '"'
          then scan (i + 1) depth true false false block
          else scan (i + 1) depth false false false block
        else if pair i '#' '|'
        then scan (i + 2) depth false false false 1
        else if pair i '#' ';'
        then (
          incr sexp_comments;
          require
            (!sexp_comments <= max_sexp_comments)
            "Configuration exceeds 256 sexp comments";
          scan (i + 2) depth false false false 0)
        else if Char.equal c ';'
        then scan (i + 1) depth false false true 0
        else if Char.equal c '"'
        then scan (i + 1) depth true false false 0
        else if Char.equal c '('
        then scan (i + 1) (depth + 1) false false false 0
        else if Char.equal c ')'
        then scan (i + 1) (depth - 1) false false false 0
        else scan (i + 1) depth false false false 0)
    in
    scan 0 0 false false false 0)
;;

let decode_with validate text =
  let open Or_error.Let_syntax in
  let%bind () = check_text text in
  let%bind t = Or_error.try_with (fun () -> t_of_sexp (Sexp.of_string text)) in
  let%map () = validate t in
  t
;;

let encode_with validate t =
  let open Or_error.Let_syntax in
  let%bind () = validate t in
  let text = Sexp.to_string_hum (sexp_of_t t) ^ "\n" in
  let%map () = check_text text in
  text
;;

let decode = decode_with validate
let encode = encode_with validate

module Resolved = struct
  (** Same envelope, but all referenced definitions (including built-ins) are embedded.
      Persist this rather than depending on the client's config file. This is portable
      policy, not a claim of trusted built-in implementation. *)
  type nonrec t = t [@@deriving bin_io, compare, equal, sexp]

  let validate = validate_common ~resolved:true
  let decode = decode_with validate
  let encode = encode_with validate
end

let resolve t ~builtins =
  let open Or_error.Let_syntax in
  let%bind () = validate t in
  let keys =
    List.concat_map t.windows ~f:(fun w ->
      List.filter_map w.workspaces ~f:(fun i ->
        match i.definition with
        | Builtin key -> Some key
        | Custom _ -> None))
    |> List.dedup_and_sort ~compare:String.compare
  in
  let%bind definitions =
    List.fold keys ~init:(Ok t.definitions) ~f:(fun acc key ->
      let%bind acc in
      let%bind d = Or_error.try_with_join (fun () -> builtins key) in
      if String.equal d.Definition.key key
      then Ok (acc @ [ d ])
      else Or_error.error_string ("Built-in resolver returned wrong key for " ^ key))
  in
  let resolved = { t with definitions } in
  let%map () = Resolved.validate resolved in
  resolved
;;

(** Explicit migration helper; legacy template files continue using their existing codec.
    The caller chooses a nonreserved key and clears preset ancestry if it intends a custom
    definition rather than a built-in reference. *)
let definition_of_template ~key template =
  let open Or_error.Let_syntax in
  let%bind () = Workspace_template.validate template in
  let definition =
    { Definition.key
    ; template
    ; tiles =
        List.mapi template.Workspace_template.views ~f:(fun index _ ->
          { Tile.key = "tile-" ^ Int.to_string (index + 1); presentation = None })
    ; layout = None
    }
  in
  Or_error.map (validate_definition definition) ~f:(fun () -> definition)
;;
