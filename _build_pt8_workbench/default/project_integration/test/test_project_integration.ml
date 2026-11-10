open! Core
open Hardcaml_workbench_protocol
open Hardcaml_workbench_project_integration

let manifest body = Manifest.parse_string body

let%test_unit "versioned manifest serialization round-trips quoted values and defaults" =
  List.iter
    [ { Manifest.project_name = "a project \"name\"; with (sexps)\nand a newline"
      ; driver = None
      ; build_alias = Manifest.default_build_alias
      ; test_alias = Manifest.default_test_alias
      }
    ; { Manifest.project_name = "demo"
      ; driver = Some "./work bench/driver.exe"
      ; build_alias = "app/@build"
      ; test_alias = "@check"
      }
    ]
    ~f:(fun value ->
      match Manifest.parse_string (Manifest.to_string value) with
      | Error message -> failwith message
      | Ok parsed -> [%test_eq: Manifest.t] parsed value)
;;

let%expect_test "manifest defaults and explicit references" =
  List.iter
    [ "(lang hardcaml-workbench 1) (project (name demo)) (dune)"
    ; "(lang hardcaml-workbench 1) (project (name demo)) (dune (driver \
       ./workbench/driver.exe) (build_alias app/@build) (test_alias @check))"
    ]
    ~f:(fun input -> print_s [%sexp (manifest input : (Manifest.t, string) Result.t)]);
  [%expect
    {|
    (Ok
     ((project_name demo) (driver ()) (build_alias @all) (test_alias @runtest)))
    (Ok
     ((project_name demo) (driver (./workbench/driver.exe))
      (build_alias app/@build) (test_alias @check))) |}]
;;

let%expect_test "manifest rejects versions, duplicates, unknowns, and escaping references"
  =
  List.iter
    [ "(lang hardcaml-workbench 2) (project (name demo)) (dune)"
    ; "(lang hardcaml-workbench 1) (project (name a) (name b)) (dune)"
    ; "(lang hardcaml-workbench 1) (project (name demo)) (dune (mystery x))"
    ; "(lang hardcaml-workbench 1) (project (name demo)) (dune (driver ./../x.exe))"
    ; "(lang hardcaml-workbench 1) (project (name demo)) (dune (test_alias ../@x))"
    ]
    ~f:(fun input -> print_s [%sexp (manifest input : (Manifest.t, string) Result.t)]);
  [%expect
    {|
    (Error
     "lang: unsupported hardcaml-workbench manifest version 2 (supported: 1)")
    (Error "name: field is duplicated")
    (Error "dune.mystery: unknown field")
    (Error "dune.driver: expected ./path with no empty, '.' or '..' component")
    (Error
     "dune.test_alias: expected @name or path/@name with no empty, '.' or '..' path component") |}]
;;

let response ?(version = 1) ?(capabilities = [ "describe" ]) ?(targets = []) configs =
  { Driver_protocol.Describe_response.protocol_version = version
  ; capabilities
  ; targets
  ; configurations = configs
  }
;;

let%expect_test "driver compatibility distinguishes empty and unsupported" =
  let check value =
    let result =
      Driver_protocol.validate value
      |> Result.map ~f:(fun response -> List.length response.targets)
    in
    print_s ([%sexp_of: (int, string) Result.t] result)
  in
  check (response []);
  check (response ~capabilities:[ "future" ] []);
  check (response ~version:2 []);
  [%expect
    {|
    (Ok 0)
    (Error "driver does not advertise required capability describe")
    (Error "unsupported driver protocol version 2 (supported: 1)") |}]
;;

let%expect_test "driver validates keys and configuration references" =
  let target key : Driver_protocol.Target.t =
    { key
    ; name = "Counter"
    ; top = "counter"
    ; backend = "simulation"
    ; clocks = []
    ; facts = []
    }
  in
  let config target : Driver_protocol.Configuration.t =
    { key = "default"; target; name = "Default"; description = None }
  in
  List.iter
    [ response ~targets:[ target "bad/key" ] []
    ; response ~targets:[ target "counter"; target "counter" ] []
    ; response ~targets:[ target "counter" ] [ config "missing" ]
    ]
    ~f:(fun value ->
      print_s
        ([%sexp_of: (Driver_protocol.Describe_response.t, string) Result.t]
           (Driver_protocol.validate value)));
  [%expect
    {|
    (Error "target key \"bad/key\" is invalid")
    (Error "target key \"counter\" is duplicated")
    (Error "configuration \"default\" refers to unknown target key \"missing\"")
    |}]
;;

let%expect_test "driver framing rejects malformed and oversized stdout" =
  print_s
    [%sexp
      (Driver_protocol.parse "diagnostic before (())"
       : (Driver_protocol.Describe_response.t, string) Result.t)];
  print_s
    [%sexp
      (Driver_protocol.parse (String.make (Driver_protocol.max_stdout_bytes + 1) 'x')
       : (Driver_protocol.Describe_response.t, string) Result.t)];
  [%expect
    {|
    (Error
      "malformed driver describe response: (Failure\
     \n \"Sexplib.Sexp.of_string: got multiple S-expressions where only one was expected.\")")
    (Error "driver stdout exceeded 1048576 bytes")
    |}]
;;

let generate_response ?(path = "counter.v") ?(target = "counter") configuration =
  { Driver_protocol.Generate_rtl_response.protocol_version = 1
  ; target
  ; configuration
  ; outputs =
      [ { Driver_protocol.Output.path
        ; namespace = "hardcaml"
        ; name = "verilog"
        ; role = Artifact.Role.Deliverable
        ; media = Some "text/x-verilog"
        ; display_name = "counter.v"
        ; description = None
        }
      ]
  ; tools = [ { name = "ocaml"; version = Some "5.2.0" } ]
  ; build = None
  ; run = None
  }
;;

let%expect_test "generate-rtl validates request identity and output handoff" =
  let check response =
    let result =
      response
      |> Driver_protocol.Generate_rtl_response.sexp_of_t
      |> Sexp.to_string_mach
      |> Driver_protocol.parse_generate ~target:"counter" ~configuration:"four-bit"
      |> Result.map ~f:(fun response -> List.length response.outputs)
    in
    print_s ([%sexp_of: (int, string) Result.t] result)
  in
  check (generate_response "four-bit");
  check (generate_response ~target:"other" "four-bit");
  check (generate_response "eight-bit");
  check (generate_response ~path:"../escape.v" "four-bit");
  check { (generate_response "four-bit") with outputs = [] };
  [%expect
    {|
    (Ok 1)
    (Error "generate-rtl result target does not match the request")
    (Error "generate-rtl result configuration does not match the request")
    (Error "output path \"../escape.v\" is not a normalized relative path")
    (Error "generate-rtl result declared no outputs") |}]
;;

let hierarchy_node ?parent ?instance_name ?(inputs = []) ?(outputs = []) key circuit_name
  : Hierarchy.Node.t
  =
  { key
  ; parent
  ; instance_name
  ; circuit_name
  ; input_ports = inputs
  ; output_ports = outputs
  ; metadata = []
  }
;;

let hierarchy nodes : Driver_protocol.Hierarchy_response.t =
  { protocol_version = 1
  ; target = "counter"
  ; configuration = "four-bit"
  ; root = "/"
  ; nodes
  }
;;

let%expect_test "hierarchy validates identity, references, cycles, and port facts" =
  let root =
    hierarchy_node
      ~outputs:[ { Hierarchy.Port.name = "count_o"; width = 4 } ]
      "/"
      "counter_top"
  in
  let child name =
    hierarchy_node
      ~parent:"/"
      ~instance_name:name
      (Driver_protocol.hierarchy_key ~parent:"/" name)
      "counter"
  in
  let check nodes =
    let result =
      Driver_protocol.validate_hierarchy
        ~target:"counter"
        ~configuration:"four-bit"
        (hierarchy nodes)
      |> Result.map ~f:(fun hierarchy ->
        List.map hierarchy.nodes ~f:(fun node -> node.key))
    in
    print_s ([%sexp_of: (string list, string) Result.t] result)
  in
  check [ root; child "same/module"; child "same:module" ];
  check [ root; child "duplicate"; child "duplicate" ];
  check
    [ root
    ; hierarchy_node
        ~parent:"/missing"
        ~instance_name:"child"
        "/7:missing/5:child"
        "counter"
    ];
  check
    [ root
    ; hierarchy_node ~parent:"/1:b" ~instance_name:"a" "/1:a" "counter"
    ; hierarchy_node ~parent:"/1:a" ~instance_name:"b" "/1:b" "counter"
    ];
  let _, deep_nodes =
    List.fold
      (List.init (Driver_protocol.max_hierarchy_depth + 1) ~f:Fn.id)
      ~init:("/", [ root ])
      ~f:(fun (parent, nodes) index ->
        let instance_name = sprintf "n%d" index in
        let key = Driver_protocol.hierarchy_key ~parent instance_name in
        key, hierarchy_node ~parent ~instance_name key "counter" :: nodes)
  in
  check (List.rev deep_nodes);
  check
    [ { root with
        output_ports =
          [ { name = "count_o"; width = 4 }; { name = "count_o"; width = 8 } ]
      }
    ];
  check
    [ { root with
        input_ports = [ { name = "count_o"; width = 1 } ]
      ; output_ports = [ { name = "count_o"; width = 4 } ]
      }
    ];
  check [ { root with output_ports = [ { name = "count_o"; width = 0 } ] } ];
  [%expect
    {|
    (Ok (/ /11:same/module /11:same:module))
    (Error "hierarchy node key \"/9:duplicate\" is duplicated")
    (Error "node \"/7:missing/5:child\" refers to unknown parent \"/missing\"")
    (Error "hierarchy contains a cycle at \"/1:a\"")
    (Error "hierarchy exceeded depth 256")
    (Error "node.ports name \"count_o\" is duplicated")
    (Error "node.ports name \"count_o\" is duplicated")
    (Error "output port \"count_o\" has non-positive width") |}]
;;

let%expect_test "hierarchy framing and limits are bounded" =
  let valid = hierarchy [ hierarchy_node "/" "counter_top" ] in
  let encoded =
    Driver_protocol.Hierarchy_response.sexp_of_t valid |> Sexp.to_string_mach
  in
  print_s
    [%sexp
      (Driver_protocol.parse_hierarchy ~target:"counter" ~configuration:"four-bit" encoded
       : (Driver_protocol.Hierarchy_response.t, string) Result.t)];
  print_s
    [%sexp
      (Driver_protocol.parse_hierarchy
         ~target:"counter"
         ~configuration:"four-bit"
         (String.make (V1.max_hierarchy_bytes + 1) 'x')
       : (Driver_protocol.Hierarchy_response.t, string) Result.t)];
  let too_many_nodes =
    { valid with
      nodes =
        List.init (Driver_protocol.max_hierarchy_nodes + 1) ~f:(fun _ ->
          List.hd_exn valid.nodes)
    }
  in
  print_s
    [%sexp
      (Driver_protocol.validate_hierarchy
         ~target:"counter"
         ~configuration:"four-bit"
         too_many_nodes
       : (Driver_protocol.Hierarchy_response.t, string) Result.t)];
  [%expect
    {|
    (Ok
     ((protocol_version 1) (target counter) (configuration four-bit) (root /)
      (nodes
       (((key /) (parent ()) (instance_name ()) (circuit_name counter_top)
         (input_ports ()) (output_ports ()) (metadata ()))))))
    (Error "hierarchy sidecar exceeded 8388608 bytes")
    (Error "hierarchy exceeded 10000 nodes") |}]
;;
