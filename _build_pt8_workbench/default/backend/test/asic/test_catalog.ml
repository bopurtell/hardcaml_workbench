open! Core
open Hardcaml_workbench_protocol
module Public = Hardcaml_workbench_backend.Asic_public

let require ok message = if not ok then failwith message

let rec alter j path f =
  match path, j with
  | [], _ -> f j
  | key :: rest, `Assoc fields ->
    `Assoc
      (List.map fields ~f:(fun (k, v) ->
         k, if String.equal k key then alter v rest f else v))
  | "0" :: rest, `List (x :: xs) -> `List (alter x rest f :: xs)
  | _ -> failwith "Invalid test fixture path"
;;

let () =
  let fixture = Public.decode (In_channel.read_all "production_flow_list.json") in
  let flows, default = Public.flow_catalog fixture in
  let flow = List.hd_exn flows in
  require
    (List.equal
       String.equal
       flow.fresh_stage_endpoints
       (Public.recipe_stages (`Assoc [ "schema_version", `Int 3 ])))
    "Production fresh-prefix capabilities lost";
  require
    (Option.equal
       Asic.Flow_default.equal
       default
       (Some { flow = "standard"; profile = "balanced" }))
    "Actual catalog default lost";
  let entry = [ "declaration"; "entries"; "0" ] in
  let methodology = entry @ [ "methodology" ] in
  let executable =
    alter fixture (methodology @ [ "endpoints" ]) (fun _ ->
      `List (List.map Public.canonical_stages ~f:(fun s -> `String s)))
  in
  require
    (List.equal
       String.equal
       (List.hd_exn (Public.flows executable)).fresh_stage_endpoints
       Public.canonical_stages)
    "Seven-stage catalog lost executable Timing endpoint";
  let unsupported path value =
    let flows, _ = Public.flow_catalog (alter fixture path (fun _ -> value)) in
    require
      (List.is_empty (List.hd_exn flows).fresh_stage_endpoints)
      "Unsupported contract advertised a fresh mapping"
  in
  List.iter
    [ [ "capabilities"; "backend_recipe" ], `String "future.v2"
    ; [ "capabilities"; "input" ], `String "checkpoint"
    ; [ "capabilities"; "stage_selection" ], `String "arbitrary-subset"
    ; [ "capabilities"; "continuation" ], `Bool true
    ; methodology @ [ "backend_recipe" ], `String "future.v2"
    ; methodology @ [ "input" ], `String "resume"
    ; [ "capabilities" ], `Null
    ]
    ~f:(fun (path, value) -> unsupported path value);
  let rejects path f =
    require
      (Result.is_error
         (Or_error.try_with (fun () -> Public.flow_catalog (alter fixture path f))))
      ("Invalid catalog accepted: " ^ String.concat ~sep:"/" path)
  in
  List.iter
    [ [ "schema_version" ], `Int 2
    ; [ "declaration"; "schema_version" ], `Int 2
    ; [ "declaration"; "default"; "flow" ], `String "missing"
    ; [ "declaration"; "default"; "profile" ], `String "missing"
    ; [ "declaration"; "default"; "flow" ], `Null
    ; [ "declaration"; "default" ], `Null
    ; entry @ [ "default_profile" ], `String "missing"
    ; methodology @ [ "id" ], `String (String.make 257 'a')
    ; methodology @ [ "id" ], `String "bad\nidentity"
    ; methodology @ [ "endpoints" ], `List [ `String "guessed" ]
    ; methodology @ [ "endpoints" ], `List [ `String "routing"; `String "routing" ]
    ; methodology @ [ "endpoints" ], `List (List.init 7 ~f:(fun _ -> `String "routing"))
    ]
    ~f:(fun (path, value) -> rejects path (fun _ -> value));
  List.iter
    [ [ "declaration"; "entries" ]; entry @ [ "profiles" ] ]
    ~f:(fun path ->
      rejects path (function
        | `List xs -> `List (xs @ xs)
        | _ -> assert false);
      rejects path (function
        | `List (x :: _) -> `List (List.init 129 ~f:(fun _ -> x))
        | _ -> assert false));
  let restricted =
    alter fixture (methodology @ [ "endpoints" ]) (fun _ -> `List [ `String "routing" ])
  in
  require
    (List.equal
       String.equal
       (List.hd_exn (Public.flows restricted)).fresh_stage_endpoints
       [ "routing" ])
    "Undeclared endpoints inferred";
  let alternate_default =
    alter fixture [ "declaration"; "default"; "profile" ] (fun _ -> `String "synth_delay")
  in
  require
    (Option.equal
       Asic.Flow_default.equal
       (snd (Public.flow_catalog alternate_default))
       (Some { flow = "standard"; profile = "synth_delay" }))
    "Catalog default replaced by entry default/first profile";
  let legacy =
    alter fixture [ "capabilities" ] (fun _ -> `Null)
    |> fun j ->
    alter j [ "declaration" ] (function
      | `Assoc xs ->
        `Assoc (List.filter xs ~f:(fun (k, _) -> not (String.equal k "default")))
      | _ -> assert false)
  in
  let legacy_flows, legacy_default = Public.flow_catalog legacy in
  require
    (Option.is_none legacy_default
     && List.is_empty (List.hd_exn legacy_flows).fresh_stage_endpoints)
    "Legacy catalog fabricated a default or fresh mapping";
  rejects [ "declaration" ] (function
    | `Assoc xs ->
      `Assoc (List.filter xs ~f:(fun (k, _) -> not (String.equal k "default")))
    | _ -> assert false);
  (* Legacy sexp caches remain readable; absence is never upgraded to capability. *)
  let old =
    Asic.Flow.t_of_sexp
      (Sexp.of_string "((id standard)(profiles (balanced))(default_profile balanced))")
  in
  require (List.is_empty old.fresh_stage_endpoints) "Legacy flow invented mapping";
  print_endline "catalog normalization: ok"
;;
