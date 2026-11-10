open! Core
open Hardcaml_workbench_protocol
module C = Workspace_config
module T = Workspace_template
module R = C.Reference
module Tree = C.Tree

let definition =
  let template = T.starter "Two logs" [ "logs"; "logs"; "future-kind" ] in
  let d = C.definition_of_template ~key:"debug" template |> Or_error.ok_exn in
  let leaf tile : Tree.t =
    Tree.Leaf { tile; min_width = 24; min_height = 6; weight = 1 }
  in
  { d with
    tiles =
      [ { C.Tile.key = "left"
        ; presentation =
            Some
              { C.Presentation.inherit_defaults with
                padding = Some 0
              ; title = Some false
              }
        }
      ; { key = "right"; presentation = None }
      ; { key = "extra"; presentation = None }
      ]
  ; layout =
      Some
        (Tree.Stack
           [ Tree.Columns [ Tree.Narrow (leaf "left") ]
           ; Tree.Weighted_columns [ 2, leaf "right" ]
           ])
  }
;;

let instance key (definition : R.t) : C.Instance.t = { key; name = "Desk"; definition }

let window key (workspaces : C.Instance.t list) : C.Window.t =
  { key; name = "Window"; workspaces }
;;

let config : C.t =
  { version = C.version
  ; id = "my-config"
  ; definitions = [ definition ]
  ; windows =
      [ window "main" [ instance "debugger" (R.Custom "debug") ]
      ; window "second" [ instance "debugger" (R.Custom "debug") ]
      ]
  }
;;

let invalid (t : C.t) =
  assert (Result.is_error (C.validate t));
  assert (Result.is_error (C.encode t));
  assert (Result.is_error (C.decode (Sexp.to_string (C.sexp_of_t t))))
;;

let with_definition (d : C.Definition.t) = { config with definitions = [ d ] }

let%test_unit "portable per-tile compression and bounded precision roundtrip" =
  let configured places =
    with_definition
      { definition with
        tiles =
          List.mapi definition.tiles ~f:(fun i tile ->
            if i <> 0
            then tile
            else
              { tile with
                presentation =
                  Some
                    { C.Presentation.inherit_defaults with
                      string_compression = Some false
                    ; decimal_places = Some places
                    }
              })
      }
  in
  List.iter (List.init 10 ~f:Fn.id) ~f:(fun places ->
    let config = configured places in
    assert (
      C.equal config (C.decode (C.encode config |> Or_error.ok_exn) |> Or_error.ok_exn)));
  List.iter [ -1; 10; Int.max_value ] ~f:(fun places -> invalid (configured places))
;;

let%test_unit "composition roundtrips duplicate kinds, keyed leaves, sparse defaults and \
               extras"
  =
  let encoded = C.encode config |> Or_error.ok_exn in
  assert (C.equal config (C.decode encoded |> Or_error.ok_exn));
  assert (C.equal config (C.t_of_sexp (C.sexp_of_t config)));
  (* A sparse presentation record inherits every unspecified field. *)
  let p = C.Presentation.t_of_sexp (Sexp.of_string "((padding (0)))") in
  assert (C.Presentation.equal p { C.Presentation.inherit_defaults with padding = Some 0 });
  (* Stable keys are independent of display names and duplicate labels are legal. *)
  let renamed =
    { config with
      windows = List.map config.windows ~f:(fun w -> { w with name = "Renamed" })
    }
  in
  C.validate renamed |> Or_error.ok_exn;
  assert (String.equal renamed.id config.id)
;;

let%test_unit "key namespaces reject ambiguity without requiring unique display names" =
  invalid { config with id = "bad key" };
  invalid { config with id = "" };
  invalid { config with definitions = [ definition; definition ] };
  invalid
    { config with windows = [ List.hd_exn config.windows; List.hd_exn config.windows ] };
  invalid
    { config with
      windows =
        [ window
            "main"
            [ instance "same" (R.Custom "debug"); instance "same" (R.Custom "debug") ]
        ]
    };
  invalid
    (with_definition
       { definition with
         tiles = List.map definition.tiles ~f:(fun t -> { t with key = "same" })
       });
  invalid (with_definition { definition with tiles = [] });
  invalid { config with windows = [] };
  invalid { config with windows = [ window "empty" [] ] };
  invalid
    { config with windows = [ { (List.hd_exn config.windows) with name = "bad\nname" } ] }
;;

let%test_unit "references are explicit, reserved, and fully resolved before transport" =
  let calls = ref [] in
  let builtins key =
    calls := key :: !calls;
    C.definition_of_template ~key { T.generic with preset = Some key }
  in
  let t =
    { config with
      windows =
        [ window
            "main"
            [ instance "one" (R.Builtin "overview")
            ; instance "two" (R.Builtin "overview")
            ; instance "custom" (R.Custom "debug")
            ]
        ]
    }
  in
  C.validate t |> Or_error.ok_exn;
  assert (Result.is_error (C.Resolved.validate t));
  let resolved = C.resolve t ~builtins |> Or_error.ok_exn in
  assert (List.equal String.equal !calls [ "overview" ]);
  assert (List.length resolved.definitions = 2);
  let encoded = C.Resolved.encode resolved |> Or_error.ok_exn in
  assert (C.equal resolved (C.Resolved.decode encoded |> Or_error.ok_exn));
  assert (Result.is_error (C.decode encoded));
  List.iter C.builtin_ids ~f:(fun key ->
    invalid { config with definitions = [ { definition with key } ] });
  List.iter
    [ R.Custom "overview"; R.Custom "missing"; R.Builtin "unknown" ]
    ~f:(fun reference ->
      invalid { config with windows = [ window "main" [ instance "one" reference ] ] });
  assert (
    Result.is_error (C.resolve t ~builtins:(fun _ -> Or_error.error_string "unavailable")));
  assert (Result.is_error (C.resolve t ~builtins:(fun _ -> Ok definition)));
  assert (Result.is_error (C.resolve t ~builtins:(fun _ -> failwith "resolver exception")));
  invalid
    (with_definition
       { definition with
         template = { definition.template with preset = Some "overview" }
       })
;;

let%test_unit "layout references identify occurrences and enforce structural and numeric \
               bounds"
  =
  let leaf tile : Tree.t =
    Tree.Leaf { tile; min_width = 1; min_height = 1; weight = 0 }
  in
  let bad (tree : Tree.t) =
    invalid (with_definition { definition with layout = Some tree })
  in
  bad (leaf "missing");
  bad (Tree.Stack [ leaf "left"; leaf "left" ]);
  bad (Tree.Stack []);
  bad (Tree.Columns []);
  bad (Tree.Weighted_columns []);
  bad (Tree.Weighted_columns [ 0, leaf "left" ]);
  bad (Tree.Weighted_columns [ -1, leaf "left" ]);
  bad (Tree.Leaf { tile = "left"; min_width = 0; min_height = 1; weight = 1 });
  bad (Tree.Leaf { tile = "left"; min_width = 1; min_height = 1; weight = Int.max_value });
  let rec narrow n (t : Tree.t) = if n = 0 then t else narrow (n - 1) (Tree.Narrow t) in
  bad (narrow C.max_tree_depth (leaf "left"));
  (* Enough distinct leaves to exceed node count without first hitting duplicate
     references or the depth bound. *)
  let wide =
    T.starter "Wide" (List.init T.max_views ~f:(fun _ -> "logs"))
    |> C.definition_of_template ~key:"debug"
    |> Or_error.ok_exn
  in
  invalid
    (with_definition
       { wide with
         layout =
           Some
             (Tree.Stack
                (List.map wide.tiles ~f:(fun (t : C.Tile.t) -> narrow 4 (leaf t.key))))
       });
  C.validate
    (with_definition
       { definition with layout = Some (narrow (C.max_tree_depth - 1) (leaf "left")) })
  |> Or_error.ok_exn;
  let p = { C.Presentation.inherit_defaults with visible_rows = Some (-1) } in
  invalid
    (with_definition
       { definition with
         tiles = List.map definition.tiles ~f:(fun t -> { t with presentation = Some p })
       });
  invalid
    (with_definition
       { definition with template = { definition.template with version = 2 } })
;;

let%test_unit "aggregate counts include repeated instances, not only stored definitions" =
  invalid
    { config with
      windows =
        List.init (C.max_windows + 1) ~f:(fun i ->
          window ("w" ^ Int.to_string i) [ instance "desk" (R.Custom "debug") ])
    };
  invalid
    { config with
      definitions =
        List.init (C.max_definitions + 1) ~f:(fun i ->
          { definition with key = "d" ^ Int.to_string i })
    };
  invalid
    { config with
      windows =
        [ window
            "main"
            (List.init (C.max_workspaces + 1) ~f:(fun i ->
               instance ("i" ^ Int.to_string i) (R.Custom "debug")))
        ]
    };
  let many =
    T.starter "Many" (List.init 100 ~f:(fun _ -> "logs"))
    |> C.definition_of_template ~key:"debug"
    |> Or_error.ok_exn
  in
  invalid
    { config with
      definitions = [ many ]
    ; windows =
        [ window
            "main"
            (List.init 42 ~f:(fun i ->
               instance ("i" ^ Int.to_string i) (R.Custom "debug")))
        ]
    };
  invalid
    { config with
      definitions = List.init 42 ~f:(fun i -> { many with key = "d" ^ Int.to_string i })
    ; windows = [ window "main" [ instance "one" (R.Custom "d0") ] ]
    };
  (* The unresolved count cannot know builtin sizes; resolution must check them. *)
  let t =
    { config with
      definitions = []
    ; windows =
        [ window
            "main"
            (List.init 42 ~f:(fun i ->
               instance ("i" ^ Int.to_string i) (R.Builtin "overview")))
        ]
    }
  in
  C.validate t |> Or_error.ok_exn;
  assert (
    Result.is_error
      (C.resolve t ~builtins:(fun key ->
         Ok { many with key; template = { many.template with preset = Some key } })))
;;

let%test_unit "aggregate tile limit accepts 4096 and rejects 4097" =
  let definitions =
    List.init 5 ~f:(fun i ->
      let count = if i = 4 then C.max_tiles mod T.max_views else T.max_views in
      T.starter "Bounded" (List.init count ~f:(fun _ -> "logs"))
      |> C.definition_of_template ~key:("d" ^ Int.to_string i)
      |> Or_error.ok_exn)
  in
  let t =
    { config with
      definitions
    ; windows =
        [ window
            "main"
            (List.map definitions ~f:(fun (d : C.Definition.t) ->
               instance d.key (R.Custom d.key)))
        ]
    }
  in
  C.validate t |> Or_error.ok_exn;
  C.Resolved.validate t |> Or_error.ok_exn;
  let extra =
    T.starter "Extra" [ "logs" ]
    |> C.definition_of_template ~key:"extra"
    |> Or_error.ok_exn
  in
  invalid { t with definitions = extra :: t.definitions };
  (* One more instantiation exceeds the same limit with stored definitions unchanged. *)
  invalid
    { t with
      windows =
        [ window
            "main"
            (instance "again" (R.Custom "d4") :: (List.hd_exn t.windows).workspaces)
        ]
    }
;;

let%test_unit "sexp comment directives have a parser budget independent of parentheses" =
  let text = C.encode config |> Or_error.ok_exn in
  let comments n = String.concat (List.init n ~f:(fun _ -> "#; ignored ")) in
  let accepted = comments C.max_sexp_comments ^ text in
  assert (C.equal config (C.decode accepted |> Or_error.ok_exn));
  let rejected = comments (C.max_sexp_comments + 1) ^ text in
  assert (Result.is_error (C.check_text rejected));
  assert (Result.is_error (C.decode rejected));
  let nested = String.concat (List.init (C.max_sexp_comments + 1) ~f:(fun _ -> "#; ")) in
  assert (Result.is_error (C.check_text (nested ^ "ignored")));
  (* Comment syntax in strings, line comments and block comments is not a directive. *)
  let inert = comments (C.max_sexp_comments + 1) in
  let commented = "#; \"" ^ inert ^ "\"\n; " ^ inert ^ "\n#| " ^ inert ^ " |#\n" ^ text in
  assert (C.equal config (C.decode commented |> Or_error.ok_exn))
;;

let%test_unit "file codec rejects malformed, unknown, excessive and unsupported input" =
  invalid { config with version = 999 };
  let text = C.encode config |> Or_error.ok_exn in
  List.iter
    [ "("
    ; text ^ " ()"
    ; "((version 1) (id x) (definitions ()) (windows ()) (run forbidden))"
    ; String.make (C.max_encoded_bytes + 1) ' '
    ; String.make 257 '(' ^ String.make 257 ')'
    ; "; \"\n" ^ String.make 257 '(' ^ String.make 257 ')'
    ; "#| \" |#" ^ String.make 257 '(' ^ String.make 257 ')'
    ; "#;" ^ String.make 257 '(' ^ String.make 257 ')' ^ text
    ]
    ~f:(fun text -> assert (Result.is_error (C.decode text)));
  assert (
    C.equal
      config
      (C.decode ("; a comment\n#| block ( \"quoted\" |#\n" ^ text) |> Or_error.ok_exn));
  let legacy = T.encode T.generic |> Or_error.ok_exn |> T.decode |> Or_error.ok_exn in
  let d = C.definition_of_template ~key:"legacy" legacy |> Or_error.ok_exn in
  assert (T.equal d.template legacy);
  assert (List.length d.tiles = List.length legacy.views);
  assert (Option.is_none d.layout)
;;
