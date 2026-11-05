(** Checks on the shared protocol schemas.

    These cover the representation rules the architecture states, rather than the shape of
    any particular value: an unavailable metric must not read as a measurement, completion
    must not read as closure, and a dirty working tree must not read as an exact source
    identity. The round-trip checks exist because the schemas are derived for both sexp
    and bin_io before the transport is chosen, and a schema that serialized only one way
    would not be noticed until then. *)

open! Core
open Hardcaml_workbench_protocol

(** Values are printed with a label, so a block that asserts on several of them stays
    readable and a diff says which one moved. *)
let show label sexp = print_s [%message label ~_:(sexp : Sexp.t)]

let timestamp =
  Timestamp.of_time_ns (Time_ns.of_int_ns_since_epoch 1_700_000_000_000_000_000)
;;

let project_id = Project_id.of_string "project-1"
let target_id = Target_id.of_string "target-1"
let configuration_id = Configuration_id.of_string "configuration-1"
let job_id = Job_id.of_string "job-1"
let artifact_id = Artifact_id.of_string "artifact-1"
let fpga = Backend_id.of_string "fpga"
let vivado = { Tool_version.tool = "vivado"; version = Some "2023.2" }

let%expect_test "generation and artifact access are additive V1 operations" =
  let generation : V1.Generate_rtl.Request.t =
    { instance_id = "instance-1"
    ; project = project_id
    ; target = target_id
    ; configuration = Configuration_id.of_string "configuration-1"
    ; submission_key = "generate-1"
    }
  in
  let read : V1.Read_artifact.Request.t =
    { instance_id = "instance-1"; artifact = artifact_id; offset = 256; max_bytes = 4096 }
  in
  print_s (V1.Generate_rtl.Request.sexp_of_t generation);
  print_s (V1.Read_artifact.Request.sexp_of_t read);
  print_s
    [%sexp
      (V1.Codec.decode
         V1.Generate_rtl.Request.t_of_sexp
         (V1.Codec.encode V1.Generate_rtl.Request.sexp_of_t generation)
       |> Result.is_ok
       : bool)];
  [%expect
    {|
    ((instance_id instance-1) (project project-1) (target target-1)
     (configuration configuration-1) (submission_key generate-1))
    ((instance_id instance-1) (artifact artifact-1) (offset 256)
     (max_bytes 4096))
    true |}]
;;

let project =
  { Project.id = project_id
  ; root = Project_root.of_absolute_path "/home/user/devel/mac"
  ; name = "mac"
  ; integration =
      { Project_integration.level = Manifest
      ; manifest = Available { version = Some 1 }
      ; driver = Unusable { reason = "driver executable failed to build" }
      }
  ; targets =
      [ { Target.id = target_id
        ; name = "mac"
        ; top = "Mac.create"
        ; backend = fpga
        ; clocks = [ { name = "clock_i"; period_ns = Some 4.0; description = None } ]
        ; facts =
            [ { namespace = "vivado"
              ; name = "part"
              ; value = String "xc7a100tcsg324-1"
              ; display = None
              }
            ]
        }
      ]
  ; configurations =
      [ { Configuration.id = Configuration_id.of_string "configuration-1"
        ; target = target_id
        ; name = "default"
        ; description = None
        }
      ]
  }
;;

let%expect_test "a generic Dune project has no targets, which is not a discovery failure" =
  let generic =
    { project with
      integration = Project_integration.generic_dune
    ; targets = []
    ; configurations = []
    }
  in
  show "integration" [%sexp (generic.integration : Project_integration.t)];
  show "targets are empty" [%sexp (List.is_empty generic.targets : bool)];
  [%expect
    {|
    (integration ((level Generic_dune) (manifest Absent) (driver Absent)))
    ("targets are empty" true)
    |}]
;;

let%expect_test "an unusable driver degrades the integration level, not the project" =
  let level =
    Project_integration.level_of_components
      ~manifest:(Available { version = Some 1 })
      ~driver:(Unusable { reason = "driver executable failed to build" })
  in
  show "level" [%sexp (level : Project_integration.Level.t)];
  show "declared level" [%sexp (project.integration.level : Project_integration.Level.t)];
  [%expect {|
    (level Manifest)
    ("declared level" Manifest)
    |}]
;;

let%expect_test "an undeclared target fact is unknown rather than defaulted" =
  let target = List.hd_exn project.targets in
  show
    "declared part"
    [%sexp (Target.fact target ~namespace:"vivado" ~name:"part" : Target_fact.t option)];
  show
    "undeclared technology"
    [%sexp
      (Target.fact target ~namespace:"asic" ~name:"technology" : Target_fact.t option)];
  [%expect
    {|
    ("declared part"
     (((namespace vivado) (name part) (value (String xc7a100tcsg324-1))
       (display ()))))
    ("undeclared technology" ())
    |}]
;;

let%expect_test "a project round-trips through sexp" =
  show
    "equal after round trip"
    [%sexp (Project.equal project (Project.t_of_sexp (Project.sexp_of_t project)) : bool)];
  [%expect {| ("equal after round trip" true) |}]
;;

let%expect_test "an unavailable metric is neither zero nor a pass" =
  let missing =
    { Metric.name = "worst_negative_slack"
    ; value = Unavailable { reason = "timing report not produced: implementation failed" }
    ; unit = Some "ns"
    ; tool = vivado
    ; stage = "implementation"
    ; corner = Some "slow"
    ; source = None
    }
  in
  show "value is available" [%sexp (Metric.Value.is_available missing.value : bool)];
  show "value" [%sexp (missing.value : Metric.Value.t)];
  [%expect
    {|
    ("value is available" false)
    (value
     (Unavailable (reason "timing report not produced: implementation failed")))
    |}]
;;

let%expect_test "completion, goals, and verification stay separate" =
  let result =
    { Structured_result.completion =
        [ { name = "synthesis"; requested = true; status = Completed }
        ; { name = "implementation"; requested = true; status = Completed }
        ; { name = "drc"; requested = false; status = Not_run }
        ]
    ; goals =
        [ { Metric.name = "worst_negative_slack"
          ; value = Float (-0.312)
          ; unit = Some "ns"
          ; tool = vivado
          ; stage = "implementation"
          ; corner = Some "slow"
          ; source = Some artifact_id
          }
        ]
    ; verification =
        [ { Check.name = "drc"
          ; status = Not_run { reason = "not requested" }
          ; tool = vivado
          ; stage = "implementation"
          ; source = None
          }
        ]
    }
  in
  (* Every requested stage finished, and the design still missed timing and was never
     checked. A single job status would have to misreport two of the three. *)
  show
    "every requested stage completed"
    [%sexp (Structured_result.all_requested_stages_completed result : bool)];
  show
    "goals"
    [%sexp (List.map result.goals ~f:(fun metric -> metric.value) : Metric.Value.t list)];
  show
    "verification"
    [%sexp
      (List.map result.verification ~f:(fun check -> check.status) : Check.Status.t list)];
  [%expect
    {|
    ("every requested stage completed" true)
    (goals ((Float -0.312)))
    (verification ((Not_run (reason "not requested"))))
    |}]
;;

let%expect_test "a dirty working tree does not identify the inputs" =
  let dirty =
    { Provenance.Source_identity.git_commit = Some "0b5e1c9"
    ; working_tree = Dirty
    ; design_hash = Some "sha256:2f1a"
    ; preserved_inputs = [ artifact_id ]
    }
  in
  show
    "dirty tree identifies inputs"
    [%sexp (Provenance.Source_identity.identifies_inputs_exactly dirty : bool)];
  show
    "clean tree identifies inputs"
    [%sexp
      (Provenance.Source_identity.identifies_inputs_exactly
         { dirty with working_tree = Clean }
       : bool)];
  show
    "inputs preserved for reproduction"
    [%sexp (dirty.preserved_inputs : Artifact_id.t list)];
  [%expect
    {|
    ("dirty tree identifies inputs" false)
    ("clean tree identifies inputs" true)
    ("inputs preserved for reproduction" (artifact-1))
    |}]
;;

let provenance =
  { Provenance.project_root = project.root
  ; target = Some target_id
  ; configuration = None
  ; build = None
  ; run = None
  ; generating_job = job_id
  ; requested_tools = [ { Tool_version.tool = "vivado"; version = Some "2023.1" } ]
  ; actual_tools = [ vivado ]
  ; environment =
      [ { Environment_identity.component = "os"; identity = Some "ubuntu-24.04" } ]
  ; source = Provenance.Source_identity.unknown ~reason:"root is not version controlled"
  ; created_at = timestamp
  }
;;

let%expect_test "requested and actual tool versions stay distinguishable" =
  show "requested" [%sexp (provenance.requested_tools : Tool_version.t list)];
  show "actual" [%sexp (provenance.actual_tools : Tool_version.t list)];
  [%expect
    {|
    (requested (((tool vivado) (version (2023.1)))))
    (actual (((tool vivado) (version (2023.2)))))
    |}]
;;

let artifact =
  { Artifact.id = artifact_id
  ; kind =
      { namespace = "vivado"
      ; name = "timing_summary"
      ; role = Report
      ; media = Some "text/plain"
      }
  ; project = project_id
  ; target = Some target_id
  ; configuration = None
  ; generating_job = job_id
  ; build = None
  ; run = None
  ; availability = Available
  ; metadata =
      { display_name = "Timing summary"
      ; description = None
      ; size_in_bytes = Some 18_204
      ; provenance
      }
  }
;;

let%expect_test "an artifact exposes no filesystem location" =
  (* The project root appears in provenance because it is how a user recognizes which
     checkout a result came from. No path below it may appear anywhere in the value: an
     artifact is retrieved from the daemon by identifier. *)
  let serialized = Sexp.to_string (Artifact.sexp_of_t artifact) in
  show
    "mentions a path below the root"
    [%sexp (String.is_substring serialized ~substring:"/home/user/devel/mac/" : bool)];
  show "retrieved by" [%sexp (artifact.id : Artifact_id.t)];
  [%expect
    {|
    ("mentions a path below the root" false)
    ("retrieved by" artifact-1)
    |}]
;;

let%expect_test "an artifact round-trips through sexp and bin_io" =
  show
    "equal after sexp round trip"
    [%sexp
      (Artifact.equal artifact (Artifact.t_of_sexp (Artifact.sexp_of_t artifact)) : bool)];
  let buffer = Bin_prot.Common.create_buf (Artifact.bin_size_t artifact) in
  let written = Artifact.bin_write_t buffer ~pos:0 artifact in
  let read_back = Artifact.bin_read_t buffer ~pos_ref:(ref 0) in
  show "bin_io wrote bytes" [%sexp (written > 0 : bool)];
  show "equal after bin_io round trip" [%sexp (Artifact.equal artifact read_back : bool)];
  [%expect
    {|
    ("equal after sexp round trip" true)
    ("bin_io wrote bytes" true)
    ("equal after bin_io round trip" true)
    |}]
;;

let job =
  Job.create
    ~id:job_id
    ~kind:{ Job.Kind.namespace = "dune"; name = "build" }
    ~project:project_id
    ~created_at:timestamp
;;

let%expect_test "a submitted job starts queued with nothing claimed about its outcome" =
  show "state" [%sexp (job.state : Job.State.t)];
  show "exit status" [%sexp (job.exit_status : Job.Exit_status.t option)];
  show "structured result" [%sexp (job.result : Structured_result.t option)];
  show "is terminal" [%sexp (Job.is_terminal job : bool)];
  [%expect
    {|
    (state Queued)
    ("exit status" ())
    ("structured result" ())
    ("is terminal" false)
    |}]
;;

let%expect_test "a launch failure is distinguishable from a nonzero exit" =
  let launch_failed =
    { job with
      state = Failed
    ; exit_status = Some (Launch_failed { reason = "dune: command not found" })
    ; finished_at = Some timestamp
    }
  in
  let exited_nonzero =
    { job with
      state = Failed
    ; exit_status = Some (Exited 1)
    ; finished_at = Some timestamp
    }
  in
  show "launch failed" [%sexp (launch_failed.exit_status : Job.Exit_status.t option)];
  show "exited nonzero" [%sexp (exited_nonzero.exit_status : Job.Exit_status.t option)];
  show
    "the two compare equal"
    [%sexp
      (Option.equal
         Job.Exit_status.equal
         launch_failed.exit_status
         exited_nonzero.exit_status
       : bool)];
  [%expect
    {|
    ("launch failed" ((Launch_failed (reason "dune: command not found"))))
    ("exited nonzero" ((Exited 1)))
    ("the two compare equal" false)
    |}]
;;

let%expect_test "a job round-trips through sexp" =
  let job = { job with state = Running; started_at = Some timestamp } in
  show
    "equal after round trip"
    [%sexp (Job.equal job (Job.t_of_sexp (Job.sexp_of_t job)) : bool)];
  [%expect {| ("equal after round trip" true) |}]
;;

let%expect_test "V1 codecs round-trip frozen wire values and reject malformed input" =
  let hello : V1.Hello.Response.t =
    { application_version = "0.1.0"
    ; protocol_versions = [ 1 ]
    ; instance_id = "instance-1"
    ; capabilities = [ "snapshot"; "updates" ]
    }
  in
  let encoded = V1.Codec.encode V1.Hello.Response.sexp_of_t hello in
  let decoded = V1.Codec.decode V1.Hello.Response.t_of_sexp encoded in
  let malformed = V1.Codec.decode V1.Hello.Response.t_of_sexp "(not-a-hello)" in
  show
    "round trip"
    [%sexp
      (Result.equal V1.Hello.Response.equal V1.Error.equal decoded (Ok hello) : bool)];
  show
    "malformed kind"
    [%sexp
      (Result.map_error malformed ~f:(fun error -> error.kind)
       : (V1.Hello.Response.t, V1.Error.Kind.t) Result.t)];
  [%expect
    {|
    ("round trip" true)
    ("malformed kind" (Error Invalid_request))
    |}]
;;

let%expect_test "structured hierarchy and read operation have portable codecs" =
  let round_trip ~equal ~sexp_of ~of_sexp ~bin_size ~bin_write ~bin_read value =
    assert (equal value (of_sexp (sexp_of value)));
    let buffer = Bin_prot.Common.create_buf (bin_size value) in
    ignore (bin_write buffer ~pos:0 value : int);
    assert (equal value (bin_read buffer ~pos_ref:(ref 0)))
  in
  let hierarchy : Hierarchy.t =
    { artifact = artifact.id
    ; project = project_id
    ; target = target_id
    ; configuration = configuration_id
    ; generating_job = job_id
    ; rtl_artifacts = [ Artifact_id.of_string "rtl-1" ]
    ; provenance
    ; root = "/"
    ; nodes =
        [ { key = "/"
          ; parent = None
          ; instance_name = None
          ; circuit_name = "counter_top"
          ; input_ports = [ { name = "clock_i"; width = 1 } ]
          ; output_ports = [ { name = "count_o"; width = 4 } ]
          ; metadata = []
          }
        ; { key = "/11:u_counter_0"
          ; parent = Some "/"
          ; instance_name = Some "u_counter_0"
          ; circuit_name = "counter"
          ; input_ports = []
          ; output_ports = [ { name = "count_o"; width = 4 } ]
          ; metadata = []
          }
        ]
    }
  in
  round_trip
    ~equal:Hierarchy.equal
    ~sexp_of:Hierarchy.sexp_of_t
    ~of_sexp:Hierarchy.t_of_sexp
    ~bin_size:Hierarchy.bin_size_t
    ~bin_write:Hierarchy.bin_write_t
    ~bin_read:Hierarchy.bin_read_t
    hierarchy;
  let response : V1.Read_hierarchy.Response.t = Ok { hierarchy } in
  round_trip
    ~equal:V1.Read_hierarchy.Response.equal
    ~sexp_of:V1.Read_hierarchy.Response.sexp_of_t
    ~of_sexp:V1.Read_hierarchy.Response.t_of_sexp
    ~bin_size:V1.Read_hierarchy.Response.bin_size_t
    ~bin_write:V1.Read_hierarchy.Response.bin_write_t
    ~bin_read:V1.Read_hierarchy.Response.bin_read_t
    response;
  show "nodes" [%sexp (List.length hierarchy.nodes : int)];
  let repeated_instance_key = (List.nth_exn hierarchy.nodes 1).key in
  show "distinct repeated instance key" [%sexp (repeated_instance_key : string)];
  [%expect {|
    (nodes 2)
    ("distinct repeated instance key" /11:u_counter_0) |}]
;;

let require_portable_round_trip
  label
  ~equal
  ~sexp_of
  ~of_sexp
  ~bin_size
  ~bin_write
  ~bin_read
  value
  =
  let sexp_value = of_sexp (sexp_of value) in
  if not (equal value sexp_value)
  then raise_s [%message "sexp round trip failed" (label : string)];
  let buffer = Bin_prot.Common.create_buf (bin_size value) in
  let length = bin_write buffer ~pos:0 value in
  if length <> Bigstring.length buffer
  then
    raise_s [%message "bin_io size disagreed with writer" (label : string) (length : int)];
  let position = ref 0 in
  let bin_value = bin_read buffer ~pos_ref:position in
  if !position <> length || not (equal value bin_value)
  then
    raise_s
      [%message
        "bin_io round trip failed" (label : string) (!position : int) (length : int)]
;;

let%expect_test "ASIC metrics round-trip and old summary sexps have no metrics" =
  let metric : Asic.Metric.t =
    { key = "design__instance__area"
    ; label = "Mapped cell area"
    ; value = Some 13041.6048
    ; unit_ = Some "µm²"
    ; availability = "available"
    ; source =
        Some
          "{\"path\":\"/public/segment.json\",\"field\":\"metrics.design__instance__area\"}"
    }
  in
  require_portable_round_trip
    "ASIC metric"
    ~equal:Asic.Metric.equal
    ~sexp_of:Asic.Metric.sexp_of_t
    ~of_sexp:Asic.Metric.t_of_sexp
    ~bin_size:Asic.Metric.bin_size_t
    ~bin_write:Asic.Metric.bin_write_t
    ~bin_read:Asic.Metric.bin_read_t
    metric;
  let check : Asic.Check.t =
    { name = "drc"; status = "unknown"; reason = Some "metric missing"; source = None }
  in
  let terminal : Asic.Terminal_result.t =
    { attempt = "/public/operation"
    ; results_file = "/public/operation/published-results.json"
    ; results_digest = "results-digest"
    ; operation_status = "failed"
    ; physical_completion = "full"
    ; acceptance = "fail"
    ; timing_goal = "unknown"
    ; metrics = [ metric ]
    ; checks = [ check ]
    ; evidence = "supplied operation/results metadata"
    ; execution_timing = None
    }
  in
  require_portable_round_trip
    "ASIC terminal result"
    ~equal:Asic.Terminal_result.equal
    ~sexp_of:Asic.Terminal_result.sexp_of_t
    ~of_sexp:Asic.Terminal_result.t_of_sexp
    ~bin_size:Asic.Terminal_result.bin_size_t
    ~bin_write:Asic.Terminal_result.bin_write_t
    ~bin_read:Asic.Terminal_result.bin_read_t
    terminal;
  let summary : Asic.Summary.t =
    { run =
        { backend = Backend_id.of_string "asic"; id = "old"; build = None; label = None }
    ; source_digest = "digest"
    ; execution_file = "/public/execution.json"
    ; plan_identity = None
    ; cell_count = Some 673
    ; cells = []
    ; metrics = [ metric ]
    ; terminal = Some terminal
    ; timing_analysis = None
    ; timing = []
    ; completion = "completed"
    ; acceptance = "not_evaluated"
    ; producer = "boundary_snapshot"
    ; observed_at = "recorded"
    ; freshness = Cached_unverified
    }
  in
  require_portable_round_trip
    "ASIC summary"
    ~equal:Asic.Summary.equal
    ~sexp_of:Asic.Summary.sexp_of_t
    ~of_sexp:Asic.Summary.t_of_sexp
    ~bin_size:Asic.Summary.bin_size_t
    ~bin_write:Asic.Summary.bin_write_t
    ~bin_read:Asic.Summary.bin_read_t
    summary;
  let legacy =
    Sexp.of_string
      "((run ((backend asic) (id old) (build ()) (label ())))\n\
      \        (source_digest digest) (execution_file /public/execution.json)\n\
      \        (plan_identity ()) (cell_count (673)) (cells ()) (timing ())\n\
      \        (completion completed) (acceptance not_evaluated)\n\
      \        (producer boundary_snapshot) (observed_at recorded) (freshness \
       Cached_unverified))"
  in
  let decoded = Asic.Summary.t_of_sexp legacy in
  assert (Asic.Summary.equal decoded { summary with metrics = []; terminal = None });
  let v2 =
    match Asic.Summary.sexp_of_t { summary with terminal = None } with
    | Sexp.List fields ->
      Sexp.List
        (List.filter fields ~f:(function
          | Sexp.List (Sexp.Atom "terminal" :: _) -> false
          | _ -> true))
    | _ -> assert false
  in
  assert (Asic.Summary.equal (Asic.Summary.t_of_sexp v2) { summary with terminal = None });
  let inspect =
    Asic.Operation.Inspect_finalization { run = summary.run; attempt = terminal.attempt }
  in
  require_portable_round_trip
    "ASIC inspect finalization"
    ~equal:Asic.Operation.equal
    ~sexp_of:Asic.Operation.sexp_of_t
    ~of_sexp:Asic.Operation.t_of_sexp
    ~bin_size:Asic.Operation.bin_size_t
    ~bin_write:Asic.Operation.bin_write_t
    ~bin_read:Asic.Operation.bin_read_t
    inspect;
  let acceptance : Asic.Acceptance.t =
    { support_tools = "/tools/support"
    ; precheck_python = "/tools/python"
    ; testbench = "/source/replay.v"
    ; testbench_top = "replay"
    ; replay_trace = "/source/replay.trace"
    }
  in
  let finalization : Asic.Finalization.t =
    { key = "accept"
    ; run = summary.run
    ; execution_file = summary.execution_file
    ; acceptance_requested = true
    ; attempt = Some terminal.attempt
    ; state = "failed"
    ; phase = Some "acceptance"
    ; operation_status = Some "failed"
    ; acceptance = Some "fail"
    ; error = Some "process exited 1"
    ; owned = false
    ; execution_timing = None
    }
  in
  require_portable_round_trip
    "ASIC acceptance inputs"
    ~equal:Asic.Acceptance.equal
    ~sexp_of:Asic.Acceptance.sexp_of_t
    ~of_sexp:Asic.Acceptance.t_of_sexp
    ~bin_size:Asic.Acceptance.bin_size_t
    ~bin_write:Asic.Acceptance.bin_write_t
    ~bin_read:Asic.Acceptance.bin_read_t
    acceptance;
  require_portable_round_trip
    "ASIC finalization lifecycle"
    ~equal:Asic.Finalization.equal
    ~sexp_of:Asic.Finalization.sexp_of_t
    ~of_sexp:Asic.Finalization.t_of_sexp
    ~bin_size:Asic.Finalization.bin_size_t
    ~bin_write:Asic.Finalization.bin_write_t
    ~bin_read:Asic.Finalization.bin_read_t
    finalization;
  List.iter
    [ Asic.Operation.Finalize
        { key = "accept"
        ; run = summary.run
        ; execution_file = summary.execution_file
        ; acceptance = Some acceptance
        }
    ; Finalize
        { key = "collect"
        ; run = summary.run
        ; execution_file = summary.execution_file
        ; acceptance = None
        }
    ; Observe_finalization "accept"
    ; List_artifacts summary.run
    ; Read_artifact
        { run = summary.run; artifact_id = "known"; offset = 10; limit = 1024 }
    ; Stage_fresh
        { selection =
            { flow = "standard"
            ; profile = "balanced"
            ; endpoint = "cts"
            ; assignments = []
            }
        ; elaboration_only = false
        ; expected_plan_identity = None
        }
    ; Launch_fresh { key = "fresh-key"; intent_id = "fresh-input-intent" }
    ; Cancel_workflow "workflow-key"
    ]
    ~f:(fun operation ->
      require_portable_round_trip
        "ASIC finalization/artifact operation"
        ~equal:Asic.Operation.equal
        ~sexp_of:Asic.Operation.sexp_of_t
        ~of_sexp:Asic.Operation.t_of_sexp
        ~bin_size:Asic.Operation.bin_size_t
        ~bin_write:Asic.Operation.bin_write_t
        ~bin_read:Asic.Operation.bin_read_t
        operation);
  let snapshot : Asic.Snapshot.t =
    { configured = true
    ; flows =
        [ { id = "standard"
          ; profiles = [ "balanced" ]
          ; default_profile = "balanced"
          ; fresh_stage_endpoints = [ "synthesis"; "routing" ]
          }
        ]
    ; catalog_default = Some { flow = "standard"; profile = "balanced" }
    ; description_json = None
    ; preview = None
    ; runs = []
    ; operations = []
    ; launches =
        [ { key = "exact-launch"
          ; preview =
              { selection =
                  { flow = "flow"
                  ; profile = "profile"
                  ; endpoint = "synthesis"
                  ; assignments = [ "x=1"; "x=1" ]
                  }
              ; plan_identity = "exact-preview"
              ; plan_json = "opaque exact bytes"
              }
          ; run_id = Some summary.run.id
          }
        ]
    ; summaries = [ summary ]
    ; finalizations = [ finalization ]
    ; artifacts = []
    ; artifact_pages = []
    ; artifact_byte_pages = []
    ; inspections = []
    ; inspection_details = []
    ; cache_error = None
    ; fresh_intent = None
    ; workflows = []
    ; resources = None
    ; workloads = None
    }
  in
  require_portable_round_trip
    "ASIC lifecycle snapshot"
    ~equal:Asic.Snapshot.equal
    ~sexp_of:Asic.Snapshot.sexp_of_t
    ~of_sexp:Asic.Snapshot.t_of_sexp
    ~bin_size:Asic.Snapshot.bin_size_t
    ~bin_write:Asic.Snapshot.bin_write_t
    ~bin_read:Asic.Snapshot.bin_read_t
    snapshot;
  let legacy_snapshot =
    match Asic.Snapshot.sexp_of_t snapshot with
    | Sexp.List fields ->
      Sexp.List
        (List.filter fields ~f:(function
          | Sexp.List
              (Sexp.Atom
                 ( "catalog_default"
                 | "launches"
                 | "finalizations"
                 | "artifacts"
                 | "artifact_pages"
                 | "artifact_byte_pages"
                 | "inspections"
                 | "inspection_details" )
              :: _) -> false
          | Sexp.List (Sexp.Atom ("fresh_intent" | "workflows") :: _) -> false
          | _ -> true))
    | _ -> assert false
  in
  assert (
    Asic.Snapshot.equal
      (Asic.Snapshot.t_of_sexp legacy_snapshot)
      { snapshot with
        catalog_default = None
      ; launches = []
      ; finalizations = []
      ; artifacts = []
      ; artifact_pages = []
      });
  show "legacy metrics" [%sexp (decoded.metrics : Asic.Metric.t list)];
  show "legacy cell count" [%sexp (decoded.cell_count : int option)];
  [%expect {|
    ("legacy metrics" ())
    ("legacy cell count" (673)) |}]
;;

let%expect_test "V1 1B operation values have portable codecs and bounded wire shapes" =
  let check label equal sexp_of of_sexp bin_size bin_write bin_read value =
    require_portable_round_trip
      label
      ~equal
      ~sexp_of
      ~of_sexp
      ~bin_size
      ~bin_write
      ~bin_read
      value
  in
  let inherited = V1.Environment_selection.Inherit_daemon in
  let opam = V1.Environment_selection.Opam_switch "workbench-switch" in
  List.iter [ inherited; opam ] ~f:(fun value ->
    check
      "environment selection"
      V1.Environment_selection.equal
      V1.Environment_selection.sexp_of_t
      V1.Environment_selection.t_of_sexp
      V1.Environment_selection.bin_size_t
      V1.Environment_selection.bin_write_t
      V1.Environment_selection.bin_read_t
      value);
  let environment : V1.Environment_summary.t =
    { selection = opam
    ; provenance = "opam switch workbench-switch"
    ; dune_version = "3.24.2"
    ; command_prefix = [ "opam"; "exec"; "--switch=workbench-switch"; "--" ]
    }
  in
  check
    "environment summary"
    V1.Environment_summary.equal
    V1.Environment_summary.sexp_of_t
    V1.Environment_summary.t_of_sexp
    V1.Environment_summary.bin_size_t
    V1.Environment_summary.bin_write_t
    V1.Environment_summary.bin_read_t
    environment;
  let workspace_item : V1.Dune_workspace.Item.t =
    { kind = "library"
    ; names = [ "workbench"; "workbench_private" ]
    ; source_path = Some "lib"
    }
  in
  check
    "workspace item"
    V1.Dune_workspace.Item.equal
    V1.Dune_workspace.Item.sexp_of_t
    V1.Dune_workspace.Item.t_of_sexp
    V1.Dune_workspace.Item.bin_size_t
    V1.Dune_workspace.Item.bin_write_t
    V1.Dune_workspace.Item.bin_read_t
    workspace_item;
  let workspace : V1.Dune_workspace.Inspection.t =
    { contexts = [ "default" ]; items = [ workspace_item ] }
  in
  check
    "workspace inspection"
    V1.Dune_workspace.Inspection.equal
    V1.Dune_workspace.Inspection.sexp_of_t
    V1.Dune_workspace.Inspection.t_of_sexp
    V1.Dune_workspace.Inspection.bin_size_t
    V1.Dune_workspace.Inspection.bin_write_t
    V1.Dune_workspace.Inspection.bin_read_t
    workspace;
  List.iter [ V1.Dune_action.Build; Test ] ~f:(fun value ->
    check
      "Dune action"
      V1.Dune_action.equal
      V1.Dune_action.sexp_of_t
      V1.Dune_action.t_of_sexp
      V1.Dune_action.bin_size_t
      V1.Dune_action.bin_write_t
      V1.Dune_action.bin_read_t
      value);
  let open_request : V1.Open_project.Request.t =
    { instance_id = "instance-1"; root = "/workspace/project"; environment = opam }
  in
  let open_payload : V1.Open_project.Payload.t = { project; environment; workspace } in
  let open_response : V1.Open_project.Response.t = Ok open_payload in
  check
    "open-project request"
    V1.Open_project.Request.equal
    V1.Open_project.Request.sexp_of_t
    V1.Open_project.Request.t_of_sexp
    V1.Open_project.Request.bin_size_t
    V1.Open_project.Request.bin_write_t
    V1.Open_project.Request.bin_read_t
    open_request;
  check
    "open-project payload"
    V1.Open_project.Payload.equal
    V1.Open_project.Payload.sexp_of_t
    V1.Open_project.Payload.t_of_sexp
    V1.Open_project.Payload.bin_size_t
    V1.Open_project.Payload.bin_write_t
    V1.Open_project.Payload.bin_read_t
    open_payload;
  check
    "open-project response"
    V1.Open_project.Response.equal
    V1.Open_project.Response.sexp_of_t
    V1.Open_project.Response.t_of_sexp
    V1.Open_project.Response.bin_size_t
    V1.Open_project.Response.bin_write_t
    V1.Open_project.Response.bin_read_t
    open_response;
  let submit_request : V1.Submit_job.Request.t =
    { instance_id = "instance-1"
    ; project = project_id
    ; action = Build
    ; submission_key = "submission-1"
    }
  in
  let submit_payload : V1.Submit_job.Payload.t = { job } in
  let submit_response : V1.Submit_job.Response.t = Ok submit_payload in
  check
    "submit-job request"
    V1.Submit_job.Request.equal
    V1.Submit_job.Request.sexp_of_t
    V1.Submit_job.Request.t_of_sexp
    V1.Submit_job.Request.bin_size_t
    V1.Submit_job.Request.bin_write_t
    V1.Submit_job.Request.bin_read_t
    submit_request;
  check
    "submit-job payload"
    V1.Submit_job.Payload.equal
    V1.Submit_job.Payload.sexp_of_t
    V1.Submit_job.Payload.t_of_sexp
    V1.Submit_job.Payload.bin_size_t
    V1.Submit_job.Payload.bin_write_t
    V1.Submit_job.Payload.bin_read_t
    submit_payload;
  check
    "submit-job response"
    V1.Submit_job.Response.equal
    V1.Submit_job.Response.sexp_of_t
    V1.Submit_job.Response.t_of_sexp
    V1.Submit_job.Response.bin_size_t
    V1.Submit_job.Response.bin_write_t
    V1.Submit_job.Response.bin_read_t
    submit_response;
  let cancel_request : V1.Cancel_job.Request.t =
    { instance_id = "instance-1"; job = job_id }
  in
  let cancel_payload : V1.Cancel_job.Payload.t = { job } in
  let cancel_response : V1.Cancel_job.Response.t = Ok cancel_payload in
  check
    "cancel-job request"
    V1.Cancel_job.Request.equal
    V1.Cancel_job.Request.sexp_of_t
    V1.Cancel_job.Request.t_of_sexp
    V1.Cancel_job.Request.bin_size_t
    V1.Cancel_job.Request.bin_write_t
    V1.Cancel_job.Request.bin_read_t
    cancel_request;
  check
    "cancel-job payload"
    V1.Cancel_job.Payload.equal
    V1.Cancel_job.Payload.sexp_of_t
    V1.Cancel_job.Payload.t_of_sexp
    V1.Cancel_job.Payload.bin_size_t
    V1.Cancel_job.Payload.bin_write_t
    V1.Cancel_job.Payload.bin_read_t
    cancel_payload;
  check
    "cancel-job response"
    V1.Cancel_job.Response.equal
    V1.Cancel_job.Response.sexp_of_t
    V1.Cancel_job.Response.t_of_sexp
    V1.Cancel_job.Response.bin_size_t
    V1.Cancel_job.Response.bin_write_t
    V1.Cancel_job.Response.bin_read_t
    cancel_response;
  List.iter [ V1.Read_log.Stream.Stdout; Stderr ] ~f:(fun value ->
    check
      "log stream"
      V1.Read_log.Stream.equal
      V1.Read_log.Stream.sexp_of_t
      V1.Read_log.Stream.t_of_sexp
      V1.Read_log.Stream.bin_size_t
      V1.Read_log.Stream.bin_write_t
      V1.Read_log.Stream.bin_read_t
      value);
  let log_bytes = "rpc-log-marker\000\255\n" in
  let log_record : V1.Read_log.Record.t =
    { offset = 7; stream = Stderr; data = log_bytes }
  in
  let read_request : V1.Read_log.Request.t =
    { instance_id = "instance-1"
    ; job = job_id
    ; offset = 7
    ; max_records = 12
    ; max_bytes = 4096
    }
  in
  let read_payload : V1.Read_log.Payload.t =
    { records = [ log_record ]; next_offset = 8; eof = true }
  in
  let read_response : V1.Read_log.Response.t = Ok read_payload in
  check
    "log record"
    V1.Read_log.Record.equal
    V1.Read_log.Record.sexp_of_t
    V1.Read_log.Record.t_of_sexp
    V1.Read_log.Record.bin_size_t
    V1.Read_log.Record.bin_write_t
    V1.Read_log.Record.bin_read_t
    log_record;
  check
    "read-log request"
    V1.Read_log.Request.equal
    V1.Read_log.Request.sexp_of_t
    V1.Read_log.Request.t_of_sexp
    V1.Read_log.Request.bin_size_t
    V1.Read_log.Request.bin_write_t
    V1.Read_log.Request.bin_read_t
    read_request;
  check
    "read-log payload"
    V1.Read_log.Payload.equal
    V1.Read_log.Payload.sexp_of_t
    V1.Read_log.Payload.t_of_sexp
    V1.Read_log.Payload.bin_size_t
    V1.Read_log.Payload.bin_write_t
    V1.Read_log.Payload.bin_read_t
    read_payload;
  check
    "read-log response"
    V1.Read_log.Response.equal
    V1.Read_log.Response.sexp_of_t
    V1.Read_log.Response.t_of_sexp
    V1.Read_log.Response.bin_size_t
    V1.Read_log.Response.bin_write_t
    V1.Read_log.Response.bin_read_t
    read_response;
  let log_event : V1.Event.t = Log_available { job = job_id; next_offset = 8 } in
  let sequenced : V1.Event.sequenced = { sequence = 9; event = log_event } in
  check
    "log-available event"
    V1.Event.equal
    V1.Event.sexp_of_t
    V1.Event.t_of_sexp
    V1.Event.bin_size_t
    V1.Event.bin_write_t
    V1.Event.bin_read_t
    log_event;
  check
    "sequenced log event"
    V1.Event.equal_sequenced
    V1.Event.sexp_of_sequenced
    V1.Event.sequenced_of_sexp
    V1.Event.bin_size_sequenced
    V1.Event.bin_write_sequenced
    V1.Event.bin_read_sequenced
    sequenced;
  let snapshot : V1.Snapshot.Payload.t =
    { projects = [ project ]
    ; jobs = [ job ]
    ; artifacts = [ artifact ]
    ; cursor = { instance_id = "instance-1"; sequence = 9 }
    }
  in
  let field_names = function
    | Sexp.List fields ->
      List.filter_map fields ~f:(function
        | List (Atom name :: _) -> Some name
        | Atom _ | List _ -> None)
    | Atom _ -> []
  in
  let constructor = function
    | Sexp.List (Atom name :: _) -> name
    | Atom name -> name
    | List (List _ :: _) | List [] -> "<not-a-constructor>"
  in
  let snapshot_sexp = V1.Snapshot.Payload.sexp_of_t snapshot in
  show
    "environment choices"
    [%sexp ([ inherited; opam ] : V1.Environment_selection.t list)];
  show
    "environment summary fields"
    [%sexp (field_names (V1.Environment_summary.sexp_of_t environment) : string list)];
  show "workspace" [%sexp (workspace : V1.Dune_workspace.Inspection.t)];
  show
    "workspace field shapes"
    [%sexp
      ([ field_names (V1.Dune_workspace.Item.sexp_of_t workspace_item)
       ; field_names (V1.Dune_workspace.Inspection.sexp_of_t workspace)
       ]
       : string list list)];
  show "operation actions" [%sexp ([ Build; Test ] : V1.Dune_action.t list)];
  show
    "operation request fields"
    [%sexp
      ([ field_names (V1.Open_project.Request.sexp_of_t open_request)
       ; field_names (V1.Submit_job.Request.sexp_of_t submit_request)
       ; field_names (V1.Cancel_job.Request.sexp_of_t cancel_request)
       ; field_names (V1.Read_log.Request.sexp_of_t read_request)
       ]
       : string list list)];
  show
    "operation payload fields"
    [%sexp
      ([ field_names (V1.Open_project.Payload.sexp_of_t open_payload)
       ; field_names (V1.Submit_job.Payload.sexp_of_t submit_payload)
       ; field_names (V1.Cancel_job.Payload.sexp_of_t cancel_payload)
       ; field_names (V1.Read_log.Payload.sexp_of_t read_payload)
       ]
       : string list list)];
  show
    "operation response constructors"
    [%sexp
      ([ constructor (V1.Open_project.Response.sexp_of_t open_response)
       ; constructor (V1.Submit_job.Response.sexp_of_t submit_response)
       ; constructor (V1.Cancel_job.Response.sexp_of_t cancel_response)
       ; constructor (V1.Read_log.Response.sexp_of_t read_response)
       ]
       : string list)];
  show "log streams" [%sexp ([ Stdout; Stderr ] : V1.Read_log.Stream.t list)];
  show
    "log record fields"
    [%sexp (field_names (V1.Read_log.Record.sexp_of_t log_record) : string list)];
  show "log byte length" [%sexp (String.length log_record.data : int)];
  show "snapshot fields" [%sexp (field_names snapshot_sexp : string list)];
  show
    "snapshot contains log bytes"
    [%sexp
      (String.is_substring (Sexp.to_string snapshot_sexp) ~substring:log_bytes : bool)];
  show
    "log event contains log bytes"
    [%sexp
      (String.is_substring
         (Sexp.to_string (V1.Event.sexp_of_t log_event))
         ~substring:log_bytes
       : bool)];
  [%expect
    {|
    ("environment choices" (Inherit_daemon (Opam_switch workbench-switch)))
    ("environment summary fields"
     (selection provenance dune_version command_prefix))
    (workspace
     ((contexts (default))
      (items
       (((kind library) (names (workbench workbench_private))
         (source_path (lib)))))))
    ("workspace field shapes" ((kind names source_path) (contexts items)))
    ("operation actions" (Build Test))
    ("operation request fields"
     ((instance_id root environment) (instance_id project action submission_key)
      (instance_id job) (instance_id job offset max_records max_bytes)))
    ("operation payload fields"
     ((project environment workspace) (job) (job) (records next_offset eof)))
    ("operation response constructors" (Ok Ok Ok Ok))
    ("log streams" (Stdout Stderr))
    ("log record fields" (offset stream data))
    ("log byte length" 17)
    ("snapshot fields" (projects jobs artifacts cursor))
    ("snapshot contains log bytes" false)
    ("log event contains log bytes" false)
    |}]
;;
