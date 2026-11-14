open! Core
open! Hardcaml

module Clock = struct
  type t =
    { name : string
    ; period_ns : float option
    ; description : string option
    }
  [@@deriving sexp]
end

module Fact = struct
  type t =
    { namespace : string
    ; name : string
    ; value : string
    ; display : string option
    }
  [@@deriving sexp]
end

module Target = struct
  type t =
    { key : string
    ; name : string
    ; top : string
    ; backend : string
    ; clocks : Clock.t list
    ; facts : Fact.t list
    }
  [@@deriving sexp]
end

module Configuration = struct
  type t =
    { key : string
    ; target : string
    ; name : string
    ; description : string option
    }
  [@@deriving sexp]
end

module Describe_response = struct
  type t =
    { protocol_version : int
    ; capabilities : string list
    ; targets : Target.t list
    ; configurations : Configuration.t list
    }
  [@@deriving sexp]
end

module Role = struct
  type t =
    | Source
    | Report
    | Log
    | Collateral
    | Deliverable
  [@@deriving sexp]
end

module Tool = struct
  type t =
    { name : string
    ; version : string option
    }
  [@@deriving sexp]
end

module Backend_ref = struct
  type t =
    { backend : string
    ; id : string
    ; label : string option
    }
  [@@deriving sexp]
end

module Run_ref = struct
  type t =
    { backend : string
    ; id : string
    ; build : Backend_ref.t option
    ; label : string option
    }
  [@@deriving sexp]
end

module Output = struct
  type t =
    { path : string
    ; namespace : string
    ; name : string
    ; role : Role.t
    ; media : string option
    ; display_name : string
    ; description : string option
    }
  [@@deriving sexp]
end

module Generate_rtl_response = struct
  type t =
    { protocol_version : int
    ; target : string
    ; configuration : string
    ; outputs : Output.t list
    ; tools : Tool.t list
    ; build : Backend_ref.t option
    ; run : Run_ref.t option
    }
  [@@deriving sexp]
end

module Port = struct
  type t =
    { name : string
    ; width : int
    }
  [@@deriving sexp]
end

module Metadata = struct
  type t =
    { name : string
    ; value : string
    }
  [@@deriving sexp]
end

module Node = struct
  type t =
    { key : string
    ; parent : string option
    ; instance_name : string option
    ; circuit_name : string
    ; input_ports : Port.t list
    ; output_ports : Port.t list
    ; metadata : Metadata.t list
    }
  [@@deriving sexp]
end

module Hierarchy_response = struct
  type t =
    { protocol_version : int
    ; target : string
    ; configuration : string
    ; root : string
    ; nodes : Node.t list
    }
  [@@deriving sexp]
end

let configurations = [ "four-bit", 4; "eight-bit", 8 ]

let describe protocol_version =
  if protocol_version <> 1
  then failwithf "unsupported requested protocol version %d" protocol_version ();
  ignore Fixture_counter.Counter.I.port_names;
  eprintf
    "fixture driver: selected environment prefix=%s\n%!"
    (Sys.getenv "OPAM_SWITCH_PREFIX" |> Option.value ~default:"inherited");
  let response : Describe_response.t =
    { protocol_version = 1
    ; capabilities = [ "describe"; "generate-rtl"; "generate-rtl-hierarchy" ]
    ; targets =
        [ { key = "counter"
          ; name = "Four-bit counter"
          ; top = "counter_top"
          ; backend = "simulation"
          ; clocks =
              [ { name = "clock_i"
                ; period_ns = None
                ; description = Some "Fixture counter clock"
                }
              ]
          ; facts =
              [ { namespace = "fixture"
                ; name = "counter_width"
                ; value = "configurable"
                ; display = Some "4 or 8 bits"
                }
              ]
          }
        ]
    ; configurations =
        List.map configurations ~f:(fun (key, width) : Configuration.t ->
          { key
          ; target = "counter"
          ; name = sprintf "%d-bit counter" width
          ; description = Some (sprintf "The fixture counter generated at width %d" width)
          })
    }
  in
  print_endline (Sexp.to_string_mach (Describe_response.sexp_of_t response))
;;

let generate_rtl protocol_version target configuration output_dir =
  if protocol_version <> 1
  then failwithf "unsupported requested protocol version %d" protocol_version ();
  if not (String.equal target "counter") then failwithf "unknown target %s" target ();
  let width =
    List.Assoc.find configurations configuration ~equal:String.equal
    |> Option.value_or_thunk ~default:(fun () ->
      failwithf "unknown configuration %s for target %s" configuration target ())
  in
  if not (Sys_unix.is_directory_exn output_dir)
  then failwithf "output directory does not exist: %s" output_dir ();
  let circuit, database = Fixture_counter.Counter.hierarchical_circuit ~width in
  let verilog =
    Rtl.create ~database Verilog [ circuit ] |> Rtl.full_hierarchy |> Rope.to_string
  in
  let filename = sprintf "counter-%d.v" width in
  Out_channel.write_all (Filename.concat output_dir filename) ~data:verilog;
  let port signal =
    let name =
      match Signal.names signal with
      | [ name ] -> name
      | names -> failwithf "expected one name for circuit port: %s" (String.concat ~sep:"," names) ()
    in
    { Port.name; width = Signal.width signal }
  in
  let key ~parent instance_name =
    sprintf
      "%s/%d:%s"
      (if String.equal parent "/" then "" else parent)
      (String.length instance_name)
      instance_name
  in
  let rec nodes ~parent ~instance_name circuit =
    let node_key =
      match parent, instance_name with
      | None, None -> "/"
      | Some parent, Some instance_name -> key ~parent instance_name
      | None, Some _ | Some _, None -> failwith "invalid hierarchy occurrence"
    in
    let node : Node.t =
      { key = node_key
      ; parent
      ; instance_name
      ; circuit_name = Circuit.name circuit
      ; input_ports = List.map (Circuit.inputs circuit) ~f:port
      ; output_ports = List.map (Circuit.outputs circuit) ~f:port
      ; metadata = []
      }
    in
    let children =
      Circuit.instantiations circuit
      |> List.sort ~compare:(fun a b ->
        String.compare a.instantiation.instance_label b.instantiation.instance_label)
      |> List.concat_map ~f:(fun instantiation ->
        let instance_name = instantiation.instantiation.instance_label in
        match
          Circuit_database.find
            database
            ~mangled_name:instantiation.instantiation.circuit_name
        with
        | Some child -> nodes ~parent:(Some node_key) ~instance_name:(Some instance_name) child
        | None ->
          [ { Node.key = key ~parent:node_key instance_name
            ; parent = Some node_key
            ; instance_name = Some instance_name
            ; circuit_name = instantiation.instantiation.circuit_name
            ; input_ports =
                List.map instantiation.instantiation.inputs ~f:(fun input ->
                  { Port.name = input.name; width = Signal.width input.input_signal })
            ; output_ports =
                List.map instantiation.instantiation.outputs ~f:(fun output ->
                  { Port.name = output.name; width = output.output_width })
            ; metadata = [ { name = "implementation"; value = "unavailable" } ]
            }
          ])
    in
    node :: children
  in
  let hierarchy_filename = sprintf "counter-%d.hierarchy.sexp" width in
  let hierarchy : Hierarchy_response.t =
    { protocol_version = 1
    ; target
    ; configuration
    ; root = "/"
    ; nodes = nodes ~parent:None ~instance_name:None circuit
    }
  in
  Out_channel.write_all
    (Filename.concat output_dir hierarchy_filename)
    ~data:(Sexp.to_string_mach (Hierarchy_response.sexp_of_t hierarchy));
  eprintf
    "fixture driver: generated %d-bit counter in environment prefix=%s\n%!"
    width
    (Sys.getenv "OPAM_SWITCH_PREFIX" |> Option.value ~default:"inherited");
  let response : Generate_rtl_response.t =
    { protocol_version = 1
    ; target
    ; configuration
    ; outputs =
        [ { path = filename
          ; namespace = "hardcaml"
          ; name = "verilog"
          ; role = Deliverable
          ; media = Some "text/x-verilog"
          ; display_name = sprintf "counter-%d.v" width
          ; description = Some (sprintf "Generated %d-bit fixture counter RTL" width)
          }
        ; { path = hierarchy_filename
          ; namespace = "hardcaml"
          ; name = "elaboration-hierarchy"
          ; role = Report
          ; media = Some "application/x-hardcaml-workbench-hierarchy-sexp"
          ; display_name = sprintf "counter-%d hierarchy" width
          ; description = Some (sprintf "Elaborated %d-bit fixture hierarchy" width)
          }
        ]
    ; tools =
        [ { name = "ocaml"; version = Some Sys.ocaml_version }
        ; { name = "hardcaml"; version = None }
        ; { name = "fixture-project-driver"; version = Some "1" }
        ]
    ; build = None
    ; run = None
    }
  in
  print_endline (Sexp.to_string_mach (Generate_rtl_response.sexp_of_t response))
;;

let command =
  Command.basic
    ~summary:"Silver fixture project driver"
    (let%map_open.Command operation = anon ("OPERATION" %: string)
     and protocol_version =
       flag "--protocol-version" (required int) ~doc:"VERSION requested protocol version"
     and target = flag "--target" (optional string) ~doc:"KEY declared target key"
     and configuration =
       flag "--configuration" (optional string) ~doc:"KEY declared configuration key"
     and output_dir =
       flag "--output-dir" (optional string) ~doc:"DIR job-specific output directory"
     in
     fun () ->
       match operation with
       | "describe" -> describe protocol_version
       | "generate-rtl" ->
         generate_rtl
           protocol_version
           (Option.value_exn target)
           (Option.value_exn configuration)
           (Option.value_exn output_dir)
       | operation -> failwithf "unsupported operation %s" operation ())
;;

let () = Command_unix.run command
