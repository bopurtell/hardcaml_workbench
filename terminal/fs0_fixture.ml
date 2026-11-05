open! Core
open Hardcaml_workbench_protocol

let fresh_intent ?(elaboration_only = false) id : Asic.Fresh.Intent.t =
  { id
  ; selection = { flow = "flow"; profile = "profile"; endpoint = "cts"; assignments = [] }
  ; elaboration_only
  ; expected_plan_identity = None
  ; scope = "opaque-source-provider-environment-scope"
  ; created_at = Timestamp.of_time_ns Time_ns.epoch
  }
;;

let workflow ?run ?(phase = Asic.Fresh.Phase.Building) key intent : Asic.Fresh.Workflow.t =
  { id = "workflow-" ^ key
  ; key
  ; intent
  ; phase
  ; cancel_requested = false
  ; preparation_id = Some ("preparation-" ^ key)
  ; elaboration_started_at = Some (Timestamp.of_time_ns Time_ns.epoch)
  ; elaboration_finished_at = None
  ; elaboration_status = "building"
  ; build_job = None
  ; emission_job = None
  ; prepared = None
  ; run
  ; reference = None
  ; error = None
  ; created_at = Timestamp.of_time_ns Time_ns.epoch
  ; finished_at = None
  }
;;

(** Explicit synthetic evidence shared by the actual-renderer tests and FS0 frame
    captures. This module is never used to populate a connected session. *)
let run_a : Run_ref.t =
  { backend = Backend_id.of_string "asic"; id = "fixture-A"; build = None; label = None }
;;

let run_b = { run_a with id = "fixture-B" }

let execution_file (run : Run_ref.t) =
  "/explicit/synthetic/fs0/" ^ run.id ^ "/execution.sexp"
;;

let run run : Asic.Run.t =
  { run
  ; reference = { attempt = "/explicit/synthetic/fs0/" ^ run.id; stream_id = run.id }
  ; selection = None
  ; stages = []
  ; execution_timing = None
  ; cursor = 1
  ; status = "completed"
  ; execution_file = Some (execution_file run)
  ; error = None
  }
;;

let summary run cell_count cells : Asic.Summary.t =
  { run
  ; source_digest = "synthetic-digest-" ^ run.Run_ref.id
  ; execution_file = execution_file run
  ; plan_identity = None
  ; cell_count = Some cell_count
  ; cells
  ; timing = []
  ; metrics = []
  ; terminal = None
  ; timing_analysis = None
  ; completion = "completed"
  ; acceptance = "not evaluated (synthetic fixture)"
  ; producer = "SYNTHETIC FS0 FIXTURE"
  ; observed_at = "fixed fixture observation"
  ; freshness = Cached_unverified
  }
;;

let snapshot : Asic.Snapshot.t =
  { configured = true
  ; flows = []
  ; catalog_default = None
  ; description_json = None
  ; preview = None
  ; runs = [ run run_a; run run_b ]
  ; operations = []
  ; launches = []
  ; fresh_intent = None
  ; workflows = []
  ; resources = None
  ; workloads = None
  ; summaries =
      [ summary run_a 50 [ "NAND2", 35; "DFF", 15 ]
      ; summary run_b 73 [ "NAND2", 50; "DFF", 23 ]
      ]
  ; cache_error = None
  ; finalizations = []
  ; artifacts = []
  ; artifact_pages = []
  ; artifact_byte_pages = []
  ; inspections = []
  ; inspection_details = []
  }
;;
