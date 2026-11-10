(** Deterministic synthetic display state for terminal baseline captures.

    These fixtures exist so the current screen can be rendered and reviewed without a
    daemon, a project, or a real ASIC flow. Every identifier, timestamp, ordering, and
    string is fixed here, so rendering the same fixture twice produces the same bytes.

    They are development fixtures. Nothing here is evidence that a project reports this
    data, and no value here may be read as a measurement, a verdict, or proof that live
    flow telemetry exists. The names are deliberately long and protemu-flavoured because
    the point of the capture is to expose how the current layout behaves with realistic
    identifiers, not to demonstrate a working integration. *)

open! Core
open Hardcaml_workbench_protocol

(** Which hierarchy node is selected and which subtrees are open, for a fixture that opens
    the hierarchy inspector. *)
module Hierarchy_state = struct
  type t =
    { selected_key : string
    ; expanded : string list
    }
end

(** Retrieved artifact content, as the console pane would hold it after [v]. *)
module Artifact_content = struct
  type t =
    { artifact : Artifact_id.t
    ; content : string
    ; truncated : bool
    }
end

(** One job's already-fetched log records and the state of its last fetch. *)
module Log = struct
  type t =
    { job : Job_id.t
    ; records : V1.Read_log.Record.t list
    ; fetch : Presentation.Log_fetch.t
    }
end

type t =
  { name : string (** file-name stem for the capture *)
  ; summary : string (** one line describing what the scenario is meant to expose *)
  ; endpoint : string
  ; status : string (** the single [session.status] string the header shows *)
  ; environment_label : string
  ; hello : V1.Hello.Response.t
  ; opened : V1.Open_project.Payload.t
  ; snapshot : V1.Snapshot.Payload.t
  ; selected_job : Job_id.t option
  ; selected_target : Target_id.t option
  ; selected_configuration : Configuration_id.t option
  ; selected_artifact : Artifact_id.t option
  ; logs : Log.t list
  ; hierarchy : (Hierarchy.t * Hierarchy_state.t) option
  ; artifact_view : Artifact_content.t option
  ; show_connection_details : bool
  }

(* A fixed instant, so ordering and sorting are stable without reading the clock. The
   terminal does not currently display any timestamp; these values only order jobs and
   artifacts. *)
let base_time = Time_ns.of_span_since_epoch (Time_ns.Span.of_int_sec 1_789_000_000)

let at seconds =
  Timestamp.of_time_ns (Time_ns.add base_time (Time_ns.Span.of_int_sec seconds))
;;

let instance = V1.Daemon_instance_id.of_string "daemon-2026-09-20T14-02-55Z-a41f"
let endpoint = "http://127.0.0.1:41733"

let hello : V1.Hello.Response.t =
  { application_version = "0.1.0"
  ; protocol_versions = [ V1.version ]
  ; instance_id = instance
  ; capabilities =
      [ "open-project"; "submit-job"; "read-log"; "read-artifact"; "read-hierarchy" ]
  }
;;

let project_id =
  Project_id.of_string "daemon/project/hardcaml-protemu-physical-emulation-0001"
;;

let project_root =
  Project_root.of_absolute_path
    "/home/wayne/devel/jane/scaf/worktrees/protemu-physical-emulation/hardcaml_protemu"
;;

let harness_target =
  Target_id.of_string "daemon/target/protemu-top-physical-emulation-harness-0001"
;;

let bridge_target =
  Target_id.of_string "daemon/target/protemu-debug-bridge-uart-capture-0002"
;;

let signoff_configuration =
  Configuration_id.of_string
    "daemon/configuration/sky130-hd-slow-corner-signoff-default-0001"
;;

let fast_configuration =
  Configuration_id.of_string "daemon/configuration/sky130-hd-fast-corner-exploration-0002"
;;

let bridge_configuration =
  Configuration_id.of_string "daemon/configuration/sky130-hd-uart-capture-default-0003"
;;

let targets : Target.t list =
  [ { id = harness_target
    ; name = "protemu_top_physical_emulation_harness"
    ; top = "protemu_top_physical_emulation_harness"
    ; backend = Backend_id.of_string "hardcaml-protemu-project-driver"
    ; clocks =
        [ { name = "clk_core"
          ; period_ns = Some 20.0
          ; description = Some "core emulation clock, sky130_hd slow corner target"
          }
        ; { name = "clk_capture"; period_ns = None; description = None }
        ]
    ; facts =
        [ { namespace = "asic"
          ; name = "technology"
          ; value = String "sky130_fd_sc_hd"
          ; display = None
          }
        ; { namespace = "asic"
          ; name = "harness"
          ; value = String "protemu"
          ; display = None
          }
        ]
    }
  ; { id = bridge_target
    ; name = "protemu_debug_bridge_uart_capture"
    ; top = "protemu_debug_bridge_uart_capture"
    ; backend = Backend_id.of_string "hardcaml-protemu-project-driver"
    ; clocks = []
    ; facts = []
    }
  ]
;;

let configurations : Configuration.t list =
  [ { id = signoff_configuration
    ; target = harness_target
    ; name = "sky130_hd_slow_corner_signoff_default"
    ; description = Some "signoff corner used by flow.sh postcheck and collect"
    }
  ; { id = fast_configuration
    ; target = harness_target
    ; name = "sky130_hd_fast_corner_exploration"
    ; description = None
    }
  ; { id = bridge_configuration
    ; target = bridge_target
    ; name = "sky130_hd_uart_capture_default"
    ; description = None
    }
  ]
;;

let project : Project.t =
  { id = project_id
  ; root = project_root
  ; name = "hardcaml_protemu_physical_emulation_workbench"
  ; integration =
      { level = Driver
      ; manifest = Available { version = Some 2 }
      ; driver = Available { version = Some 2 }
      }
  ; targets
  ; configurations
  }
;;

let environment : V1.Environment_summary.t =
  { selection = Opam_switch "5.2.0+ox"
  ; provenance = "opam switch 5.2.0+ox resolved from --environment opam:5.2.0+ox"
  ; dune_version = "3.22.2"
  ; command_prefix = [ "opam"; "exec"; "--switch=5.2.0+ox"; "--" ]
  }
;;

let workspace : V1.Dune_workspace.Inspection.t =
  { contexts = [ "default" ]
  ; items =
      [ { kind = "library"
        ; names = [ "hardcaml_protemu"; "hardcaml_protemu_physical" ]
        ; source_path = Some "lib/hardcaml_protemu"
        }
      ; { kind = "library"
        ; names = [ "hardcaml_protemu_workbench_driver" ]
        ; source_path = Some "workbench/driver"
        }
      ; { kind = "executable"
        ; names = [ "protemu_emit_rtl" ]
        ; source_path = Some "bin/emit_rtl"
        }
      ; { kind = "executable"
        ; names = [ "protemu_flow_status_adapter" ]
        ; source_path = Some "flow/adapter"
        }
      ; { kind = "test"
        ; names = [ "test_hardcaml_protemu_physical_emulation_regression" ]
        ; source_path = Some "test/physical_emulation"
        }
      ; { kind = "rule"; names = []; source_path = Some "flow/generated" }
      ]
  }
;;

let opened : V1.Open_project.Payload.t = { project; environment; workspace }
let job_id suffix = Job_id.of_string ("daemon/job/2026-09-20T14-03-11Z/" ^ suffix)
let build_job = job_id "0001-dune-build-default"
let describe_job = job_id "0002-project-driver-describe"
let generate_job = job_id "0003-project-driver-generate-rtl-harness"
let regression_job = job_id "0004-dune-runtest-physical-emulation-regression"
let flow_run_job = job_id "0005-project-driver-flow-run-full"
let archive_job = job_id "0006-project-driver-flow-archive"
let emit_job = job_id "0007-project-driver-flow-emit"
let report_job = job_id "0008-project-driver-flow-report"

let artifact_id suffix =
  Artifact_id.of_string ("daemon/artifact/2026-09-20T14-03-11Z/" ^ suffix)
;;

let rtl_artifact = artifact_id "0001-protemu-top-physical-emulation-harness-verilog"
let hierarchy_artifact = artifact_id "0002-protemu-elaboration-hierarchy"
let report_artifact = artifact_id "0003-protemu-flow-postcheck-summary"

let provenance ~created_at ~target ~configuration ~generating_job : Provenance.t =
  { project_root
  ; target
  ; configuration
  ; build = None
  ; run = None
  ; generating_job
  ; requested_tools = [ { tool = "dune"; version = Some "3.22.2" } ]
  ; actual_tools = [ { tool = "dune"; version = Some "3.22.2" } ]
  ; environment = [ { component = "opam-switch"; identity = Some "5.2.0+ox" } ]
  ; source =
      { git_commit = Some "abc1234def5678901234567890abcdef12345678"
      ; working_tree = Dirty
      ; design_hash = None
      ; preserved_inputs = []
      }
  ; created_at
  }
;;

let job
  ~id
  ~namespace
  ~name
  ~target
  ~configuration
  ~state
  ~phase
  ~exit_status
  ~failure
  ~created_at
  ~artifacts
  : Job.t
  =
  { id
  ; kind = { namespace; name }
  ; project = project_id
  ; target
  ; configuration
  ; parent = None
  ; children = []
  ; build = None
  ; run = None
  ; state
  ; phase
  ; exit_status
  ; failure
  ; created_at
  ; started_at = Some created_at
  ; finished_at = None
  ; artifacts
  ; result = None
  }
;;

let jobs : Job.t list =
  [ job
      ~id:build_job
      ~namespace:"dune"
      ~name:"build"
      ~target:None
      ~configuration:None
      ~state:Complete
      ~phase:None
      ~exit_status:(Some (Exited 0))
      ~failure:None
      ~created_at:(at 10)
      ~artifacts:[]
  ; job
      ~id:describe_job
      ~namespace:"project-driver"
      ~name:"describe"
      ~target:None
      ~configuration:None
      ~state:Complete
      ~phase:None
      ~exit_status:(Some (Exited 0))
      ~failure:None
      ~created_at:(at 20)
      ~artifacts:[]
  ; job
      ~id:generate_job
      ~namespace:"project-driver"
      ~name:"generate-rtl"
      ~target:(Some harness_target)
      ~configuration:(Some signoff_configuration)
      ~state:Complete
      ~phase:None
      ~exit_status:(Some (Exited 0))
      ~failure:None
      ~created_at:(at 30)
      ~artifacts:[ rtl_artifact; hierarchy_artifact ]
  ; job
      ~id:regression_job
      ~namespace:"dune"
      ~name:"test"
      ~target:None
      ~configuration:None
      ~state:Failed
      ~phase:(Some "test/physical_emulation")
      ~exit_status:(Some (Exited 2))
      ~failure:
        (Some
           "dune runtest reported 3 failing expect tests under test/physical_emulation; \
            see the captured output for the first diff")
      ~created_at:(at 40)
      ~artifacts:[]
  ; job
      ~id:flow_run_job
      ~namespace:"project-driver"
      ~name:"flow-run"
      ~target:(Some harness_target)
      ~configuration:(Some signoff_configuration)
      ~state:Running
      ~phase:(Some "run: openroad global placement, step 14 of 38")
      ~exit_status:None
      ~failure:None
      ~created_at:(at 50)
      ~artifacts:[]
  ; job
      ~id:archive_job
      ~namespace:"project-driver"
      ~name:"flow-archive"
      ~target:(Some harness_target)
      ~configuration:(Some signoff_configuration)
      ~state:Queued
      ~phase:None
      ~exit_status:None
      ~failure:None
      ~created_at:(at 60)
      ~artifacts:[]
  ; job
      ~id:emit_job
      ~namespace:"project-driver"
      ~name:"flow-emit"
      ~target:(Some harness_target)
      ~configuration:(Some fast_configuration)
      ~state:Cancelled
      ~phase:None
      ~exit_status:(Some (Signaled { signal = "TERM" }))
      ~failure:None
      ~created_at:(at 70)
      ~artifacts:[]
  ; job
      ~id:report_job
      ~namespace:"project-driver"
      ~name:"flow-report"
      ~target:(Some bridge_target)
      ~configuration:(Some bridge_configuration)
      ~state:Failed
      ~phase:None
      ~exit_status:
        (Some
           (Launch_failed
              { reason =
                  "flow/adapter/protemu_flow_status_adapter.exe: No such file or \
                   directory"
              }))
      ~failure:None
      ~created_at:(at 80)
      ~artifacts:[]
  ]
;;

let artifacts : Artifact.t list =
  [ { id = rtl_artifact
    ; kind =
        { namespace = "hardcaml"
        ; name = "verilog"
        ; role = Source
        ; media = Some "text/x-verilog"
        }
    ; project = project_id
    ; target = Some harness_target
    ; configuration = Some signoff_configuration
    ; generating_job = generate_job
    ; build = None
    ; run = None
    ; availability = Available
    ; metadata =
        { display_name = "protemu_top_physical_emulation_harness.v"
        ; description = Some "elaborated Verilog for the physical emulation harness"
        ; size_in_bytes = Some 1_482_113
        ; provenance =
            provenance
              ~created_at:(at 31)
              ~target:(Some harness_target)
              ~configuration:(Some signoff_configuration)
              ~generating_job:generate_job
        }
    }
  ; { id = hierarchy_artifact
    ; kind =
        { namespace = "hardcaml"
        ; name = "elaboration-hierarchy"
        ; role = Report
        ; media = Some "application/x-hardcaml-workbench-hierarchy-sexp"
        }
    ; project = project_id
    ; target = Some harness_target
    ; configuration = Some signoff_configuration
    ; generating_job = generate_job
    ; build = None
    ; run = None
    ; availability = Available
    ; metadata =
        { display_name = "protemu_top_physical_emulation_harness.hierarchy.sexp"
        ; description = None
        ; size_in_bytes = Some 28_904
        ; provenance =
            provenance
              ~created_at:(at 32)
              ~target:(Some harness_target)
              ~configuration:(Some signoff_configuration)
              ~generating_job:generate_job
        }
    }
  ; { id = report_artifact
    ; kind =
        { namespace = "protemu"
        ; name = "postcheck-summary"
        ; role = Report
        ; media = Some "text/plain"
        }
    ; project = project_id
    ; target = Some harness_target
    ; configuration = Some signoff_configuration
    ; generating_job = flow_run_job
    ; build = None
    ; run = None
    ; availability = Unavailable { reason = "flow_results scratch area was cleaned" }
    ; metadata =
        { display_name = "postcheck_summary.txt"
        ; description = None
        ; size_in_bytes = None
        ; provenance =
            provenance
              ~created_at:(at 33)
              ~target:(Some harness_target)
              ~configuration:(Some signoff_configuration)
              ~generating_job:flow_run_job
        }
    }
  ]
;;

let snapshot : V1.Snapshot.Payload.t =
  { projects = [ project ]
  ; jobs
  ; artifacts
  ; cursor = { instance_id = instance; sequence = 418 }
  }
;;

(* Interleaved stdout/stderr for the failing regression job. The console pane shows the
   tail, so the early records are here to demonstrate what is lost. *)
let regression_log_records =
  let record offset stream data : V1.Read_log.Record.t = { offset; stream; data } in
  let progress index =
    record
      index
      Stdout
      (sprintf
         "Building \
          test/physical_emulation/test_hardcaml_protemu_physical_emulation_regression.exe \
          (step %d of 42)"
         index)
  in
  List.init 30 ~f:(fun index -> progress (index + 1))
  @ [ record 31 Stderr "File \"test/physical_emulation/dune\", line 4, characters 12-58:"
    ; record
        32
        Stdout
        "protemu regression: elaborating protemu_top_physical_emulation_harness with \
         sky130_hd_slow_corner_signoff_default and capturing 4096 stimulus frames"
    ; record
        33
        Stderr
        "FAILED: test_hardcaml_protemu_physical_emulation_regression.ml, line 118: \
         capture_fifo_occupancy"
    ; record 34 Stdout "-|expected occupancy 4096"
    ; record 35 Stdout "+|actual   occupancy 4090"
    ; record
        36
        Stderr
        "FAILED: test_hardcaml_protemu_physical_emulation_regression.ml, line 204: \
         por_sequencer_release_order"
    ; record
        37
        Stdout
        "-|expected [ por_release; pll_lock; core_release; capture_release ]"
    ; record
        38
        Stdout
        "+|actual   [ por_release; core_release; pll_lock; capture_release ]"
    ; record
        39
        Stderr
        "FAILED: test_hardcaml_protemu_physical_emulation_regression.ml, line 377: \
         uart_capture_frame_checksum"
    ; record 40 Stdout "-|expected checksum 0x5a3c"
    ; record 41 Stdout "+|actual   checksum 0x5a3d"
    ; record 42 Stderr "3 failing expect tests; run dune promote to accept the new output"
    ; record 43 Stdout "dune runtest exited with status 2"
    ]
;;

let flow_log_records =
  let record offset stream data : V1.Read_log.Record.t = { offset; stream; data } in
  [ record 1 Stdout "flow.sh: build emit preflight run postcheck collect report archive"
  ; record
      2
      Stderr
      "[INFO] openroad: global_placement started for \
       protemu_top_physical_emulation_harness"
  ; record 3 Stdout "[step 14/38] global_placement density=0.62 target_utilisation=0.55"
  ]
;;

(* A long, wide artifact body. The console pane shows the first [console_height] lines of
   an artifact and truncates each line to the terminal width, so both the length and the
   long lines matter for the capture. *)
let artifact_content =
  let header =
    [ "// Generated by hardcaml_protemu emit_rtl; do not edit."
    ; "// target        : protemu_top_physical_emulation_harness"
    ; "// configuration : sky130_hd_slow_corner_signoff_default"
    ; "// generating job: \
       daemon/job/2026-09-20T14-03-11Z/0003-project-driver-generate-rtl-harness"
    ; ""
    ; "module protemu_top_physical_emulation_harness ("
    ; "    input  wire        clk_core,"
    ; "    input  wire        clk_capture,"
    ; "    input  wire        rst_n_async_por,"
    ; "    input  wire [31:0] stimulus_frame_data_in,"
    ; "    input  wire        stimulus_frame_valid_in,"
    ; "    output wire        stimulus_frame_ready_out,"
    ; "    output wire [31:0] capture_frame_data_out,"
    ; "    output wire        capture_frame_valid_out,"
    ; "    output wire        debug_bridge_uart_tx,"
    ; "    input  wire        debug_bridge_uart_rx"
    ; ");"
    ; ""
    ]
  in
  let body =
    List.init 600 ~f:(fun index ->
      match index % 4 with
      | 0 ->
        sprintf "  wire [31:0] stimulus_capture_fifo_bank_write_data_stage_%03d;" index
      | 1 ->
        sprintf
          "  assign stimulus_capture_fifo_bank_write_data_stage_%03d = \
           stimulus_capture_fifo_bank_write_data_stage_%03d ^ {16'h%04x, 16'h%04x}; // \
           pipeline balancing stage inserted by the physical emulation harness generator"
          index
          (Int.max 0 (index - 1))
          (index * 7 % 65536)
          (index * 13 % 65536)
      | 2 -> sprintf "  reg  [31:0] capture_frame_shift_register_stage_%03d;" index
      | _ ->
        sprintf
          "  always @(posedge clk_capture) capture_frame_shift_register_stage_%03d <= \
           stimulus_capture_fifo_bank_write_data_stage_%03d;"
          index
          index)
  in
  String.concat ~sep:"\n" (header @ body @ [ ""; "endmodule" ])
;;

let port name width : Hierarchy.Port.t = { name; width }

let hierarchy_nodes : Hierarchy.Node.t list =
  [ { key = "protemu_top"
    ; parent = None
    ; instance_name = None
    ; circuit_name = "protemu_top_physical_emulation_harness"
    ; input_ports =
        [ port "clk_core" 1
        ; port "clk_capture" 1
        ; port "rst_n_async_por" 1
        ; port "stimulus_frame_data_in" 32
        ; port "stimulus_frame_valid_in" 1
        ; port "debug_bridge_uart_rx" 1
        ]
    ; output_ports =
        [ port "stimulus_frame_ready_out" 1
        ; port "capture_frame_data_out" 32
        ; port "capture_frame_valid_out" 1
        ; port "debug_bridge_uart_tx" 1
        ]
    ; metadata =
        [ { name = "technology"; value = "sky130_fd_sc_hd" }
        ; { name = "clock_target_ns"; value = "20.0" }
        ]
    }
  ; { key = "protemu_top/clock_reset_management_unit"
    ; parent = Some "protemu_top"
    ; instance_name = Some "clock_reset_management_unit"
    ; circuit_name = "protemu_clock_reset_management_unit_with_por_sequencer"
    ; input_ports = [ port "clk_core" 1; port "rst_n_async_por" 1; port "pll_locked" 1 ]
    ; output_ports =
        [ port "core_reset_release" 1
        ; port "capture_reset_release" 1
        ; port "por_sequencer_state" 3
        ]
    ; metadata =
        [ { name = "reset_style"; value = "asynchronous_assert_synchronous_release" } ]
    }
  ; { key = "protemu_top/clock_reset_management_unit/por_sequencer_fsm"
    ; parent = Some "protemu_top/clock_reset_management_unit"
    ; instance_name = Some "por_sequencer_fsm"
    ; circuit_name = "protemu_power_on_reset_sequencer_state_machine"
    ; input_ports = [ port "clk_core" 1; port "rst_n_async_por" 1 ]
    ; output_ports = [ port "state" 3 ]
    ; metadata = []
    }
  ; { key = "protemu_top/clock_reset_management_unit/pll_lock_synchronizer"
    ; parent = Some "protemu_top/clock_reset_management_unit"
    ; instance_name = Some "pll_lock_synchronizer"
    ; circuit_name = "protemu_three_stage_metastability_synchronizer"
    ; input_ports = [ port "clk_core" 1; port "asynchronous_input" 1 ]
    ; output_ports = [ port "synchronized_output" 1 ]
    ; metadata = [ { name = "stages"; value = "3" } ]
    }
  ; { key = "protemu_top/stimulus_capture_fifo_bank"
    ; parent = Some "protemu_top"
    ; instance_name = Some "stimulus_capture_fifo_bank"
    ; circuit_name = "protemu_stimulus_capture_asynchronous_fifo_bank"
    ; input_ports =
        [ port "clk_write" 1
        ; port "clk_read" 1
        ; port "write_data" 32
        ; port "write_enable" 1
        ; port "read_enable" 1
        ]
    ; output_ports =
        [ port "read_data" 32; port "full" 1; port "empty" 1; port "occupancy" 13 ]
    ; metadata = [ { name = "depth"; value = "4096" }; { name = "width"; value = "32" } ]
    }
  ; { key = "protemu_top/stimulus_capture_fifo_bank/write_pointer_gray_code_converter"
    ; parent = Some "protemu_top/stimulus_capture_fifo_bank"
    ; instance_name = Some "write_pointer_gray_code_converter"
    ; circuit_name = "protemu_binary_to_gray_code_converter"
    ; input_ports = [ port "binary_in" 13 ]
    ; output_ports = [ port "gray_out" 13 ]
    ; metadata = []
    }
  ; { key = "protemu_top/stimulus_capture_fifo_bank/read_pointer_gray_code_converter"
    ; parent = Some "protemu_top/stimulus_capture_fifo_bank"
    ; instance_name = Some "read_pointer_gray_code_converter"
    ; circuit_name = "protemu_binary_to_gray_code_converter"
    ; input_ports = [ port "binary_in" 13 ]
    ; output_ports = [ port "gray_out" 13 ]
    ; metadata = []
    }
  ; { key = "protemu_top/stimulus_capture_fifo_bank/fifo_memory_dual_port_sram_macro"
    ; parent = Some "protemu_top/stimulus_capture_fifo_bank"
    ; instance_name = Some "fifo_memory_dual_port_sram_macro"
    ; circuit_name = "protemu_sky130_sram_2kbyte_1rw1r_32x512_8_macro_wrapper"
    ; input_ports =
        [ port "clk_write" 1
        ; port "write_enable" 1
        ; port "write_address" 9
        ; port "write_data" 32
        ; port "write_byte_mask" 4
        ; port "clk_read" 1
        ; port "read_enable" 1
        ; port "read_address" 9
        ]
    ; output_ports = [ port "read_data" 32 ]
    ; metadata =
        [ { name = "macro"; value = "sky130_sram_2kbyte_1rw1r_32x512_8" }
        ; { name = "placement"; value = "fixed" }
        ; { name = "lef"; value = "sky130_sram_2kbyte_1rw1r_32x512_8.lef" }
        ]
    }
  ; { key = "protemu_top/debug_bridge_uart_capture_frontend"
    ; parent = Some "protemu_top"
    ; instance_name = Some "debug_bridge_uart_capture_frontend"
    ; circuit_name = "protemu_debug_bridge_uart_capture_frontend"
    ; input_ports = [ port "clk_capture" 1; port "uart_rx" 1; port "frame_data" 32 ]
    ; output_ports = [ port "uart_tx" 1; port "frame_ready" 1 ]
    ; metadata = [ { name = "baud"; value = "115200" } ]
    }
  ]
;;

let hierarchy : Hierarchy.t =
  { artifact = hierarchy_artifact
  ; project = project_id
  ; target = harness_target
  ; configuration = signoff_configuration
  ; generating_job = generate_job
  ; rtl_artifacts = [ rtl_artifact ]
  ; provenance =
      provenance
        ~created_at:(at 32)
        ~target:(Some harness_target)
        ~configuration:(Some signoff_configuration)
        ~generating_job:generate_job
  ; root = "protemu_top"
  ; nodes = hierarchy_nodes
  }
;;

let common =
  { name = "unnamed"
  ; summary = ""
  ; endpoint
  ; status = "connected"
  ; environment_label = "opam switch 5.2.0+ox"
  ; hello
  ; opened
  ; snapshot
  ; selected_job = None
  ; selected_target = Some harness_target
  ; selected_configuration = Some signoff_configuration
  ; selected_artifact = Some rtl_artifact
  ; logs = []
  ; hierarchy = None
  ; artifact_view = None
  ; show_connection_details = false
  }
;;

let dashboard =
  { common with
    name = "dashboard"
  ; summary =
      "Populated dashboard: eight jobs in six states, a selected failing job with \
       interleaved stdout/stderr, and long project, target, configuration, job, and \
       artifact identifiers."
  ; selected_job = Some regression_job
  ; logs =
      [ { job = regression_job
        ; records = regression_log_records
        ; fetch = Received { eof = true }
        }
      ; { job = flow_run_job
        ; records = flow_log_records
        ; fetch = Received { eof = false }
        }
      ]
  }
;;

let hierarchy_inspector =
  { common with
    name = "hierarchy"
  ; summary =
      "Hierarchy inspector open over the project pane, with two subtrees expanded, a \
       deep selected node, long circuit names, and the node's port and metadata \
       information."
  ; status = "hierarchy loaded"
  ; selected_job = Some generate_job
  ; hierarchy =
      Some
        ( hierarchy
        , { selected_key =
              "protemu_top/stimulus_capture_fifo_bank/fifo_memory_dual_port_sram_macro"
          ; expanded =
              [ "protemu_top"
              ; "protemu_top/clock_reset_management_unit"
              ; "protemu_top/stimulus_capture_fifo_bank"
              ]
          } )
  ; logs =
      [ { job = generate_job
        ; records =
            [ { offset = 1
              ; stream = Stdout
              ; data = "protemu emit_rtl: wrote protemu_top_physical_emulation_harness.v"
              }
            ]
        ; fetch = Received { eof = true }
        }
      ]
  }
;;

let artifact_output =
  { common with
    name = "artifact-output"
  ; summary =
      "Retrieved RTL artifact in the console pane: 620 lines, many wider than 120 cells, \
       flagged as truncated at the 1 MiB fetch limit."
  ; status = "artifact loaded"
  ; selected_job = Some flow_run_job
  ; artifact_view =
      Some { artifact = rtl_artifact; content = artifact_content; truncated = true }
  ; logs =
      [ { job = flow_run_job
        ; records = flow_log_records
        ; fetch = Received { eof = false }
        }
      ]
  }
;;

let all = [ dashboard; hierarchy_inspector; artifact_output ]
