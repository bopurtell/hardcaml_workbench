open! Core

module Selection = struct
  type t =
    { flow : string
    ; profile : string
    ; endpoint : string
    ; assignments : string list
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Stage = struct
  module Status = struct
    type t =
      | Pending
      | Running
      | Completed
      | Failed
      | Skipped
      | Cancelled
      | Not_requested
      | Unsupported
      | Unknown of string
    [@@deriving bin_io, compare, equal, sexp]
  end

  (** Explicit provider observations only. An action prepares a new named-flow run through
      its endpoint using ordinary [Plan]/[Run], never a restart in this run. *)
  type t =
    { id : string
    ; name : string
    ; status : Status.t
    ; requested : bool
    ; reason : string option
    ; action : Selection.t option
    ; execution_timing : Execution_timing.t option
         [@sexp.default None] [@sexp_drop_default.equal]
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Flow = struct
  type t =
    { id : string
    ; profiles : string list
    ; default_profile : string
    ; fresh_stage_endpoints : string list [@sexp.default []]
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Flow_default = struct
  type t =
    { flow : string
    ; profile : string
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Reference = struct
  (** Exact public allocation references, never reconstructed from directory names. *)
  type t =
    { attempt : string
    ; stream_id : string
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Metric = struct
  (** Only explicitly understood public metrics are projected. [source] is JSON: the
      supplied stage source object, or terminal results path/hash/field plus complete
      supplied metric context and resolved source, or verified historical snapshot
      reference/configuration for a declared constraint. Checkpoint-wide stage attribution
      remains in [Summary.producer]. Unavailable is never zero or a pass. *)
  type t =
    { key : string
    ; label : string
    ; value : float option
    ; unit_ : string option
    ; availability : string
    ; source : string option
    }
  [@@deriving bin_io, compare, equal, sexp]

  let declared_clock_period_key = "declared_clock_period"
end

module Check = struct
  type t =
    { name : string
    ; status : string
    ; reason : string option
    ; source : string option
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Terminal_result = struct
  type t =
    { attempt : string
    ; results_file : string
    ; results_digest : string
    ; operation_status : string
    ; physical_completion : string
    ; acceptance : string
    ; timing_goal : string
    ; metrics : Metric.t list
    ; checks : Check.t list
    ; evidence : string
    ; execution_timing : Execution_timing.t option
         [@sexp.default None] [@sexp_drop_default.equal]
    }
  [@@deriving bin_io, compare, equal, sexp]

  (** A declared constraint, not a measured clock. [None] also covers legacy caches whose
      terminal projection predates declared-clock evidence. *)
  let declared_clock_period (t : t) =
    List.find t.metrics ~f:(fun metric ->
      String.equal metric.Metric.key Metric.declared_clock_period_key)
  ;;
end

module Timing_analysis = struct
  (** One exact native STA observation, independent of physical-stage status and
      finalization. [duration] is native STA runtime, not full Timing segment time.
      [enclosing_status] describes the captured source, which may still be running;
      [Summary.completion] describes the current overall execution. Provenance strings are
      provider JSON, not client-readable paths. *)
  module Status = struct
    type t =
      | Completed
      | Unavailable
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Goal = struct
    type t =
      | Pass
      | Fail
      | Unknown
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Duration = struct
    type t =
      { seconds : float
      ; basis : string
      ; precision_seconds : float
      ; source : string
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Metric = struct
    type t =
      { key : string
      ; corner : string
      ; raw_key : string
      ; value : float option
      ; unit_ : string option
      ; reason : string option
      ; provenance : string
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Corner = struct
    type t =
      { corner : string
      ; measured : bool
      ; setup_goal : Goal.t
      ; hold_goal : Goal.t
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  type t =
    { target : Asic_inspection.Analysis_target.t
    ; status : Status.t
    ; reason : string option
    ; duration : Duration.t option
    ; enclosing_status : string
    ; producer : string option
    ; corners : Corner.t list
    ; metrics : Metric.t list
    ; timing_goal : Goal.t
    ; evidence : string
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Summary = struct
  module Freshness = struct
    type t =
      | Validated
      | Cached_unverified
      | Missing_source
      | Refresh_failed of string
    [@@deriving bin_io, compare, equal, sexp]
  end

  type t =
    { run : Run_ref.t
    ; source_digest : string
    ; execution_file : string
    ; plan_identity : string option
    ; cell_count : int option
    ; cells : (string * int) list
    ; metrics : Metric.t list [@sexp.default []]
    ; terminal : Terminal_result.t option [@sexp.default None]
    ; timing_analysis : Timing_analysis.t option
         [@sexp.default None] [@sexp_drop_default.equal]
    (** [None] means no authoritative observation was published (including legacy
        providers/records). It is neither completion nor a passing timing goal. The
        enclosing summary's [freshness] also applies to this observation. *)
    ; timing : (string * float * string) list
    ; completion : string
    ; acceptance : string
    ; producer : string
    ; observed_at : string
    ; freshness : Freshness.t
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Run = struct
  type t =
    { run : Run_ref.t
    ; reference : Reference.t
    ; selection : Selection.t option
    ; cursor : int
    ; status : string
    ; execution_file : string option
    ; error : string option
    ; stages : Stage.t list [@sexp.default []]
    ; execution_timing : Execution_timing.t option
         [@sexp.default None] [@sexp_drop_default.equal]
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Pending = struct
  module Activity = struct
    (** What an operation is doing, where the daemon distinguishes it. Evidence reads are
        read-only: neither constructor is producer or flow execution.

        - [Evidence_cache_lookup]: only Workbench-derived caches are consulted; no
          provider operation is in progress.
        - [Evidence_read]: a bounded read-only provider/source read of retained evidence
          (an explicit refresh, a cold-cache fallback, a detail read or a summary
          revalidation). *)
    type t =
      | Unreported
      | Evidence_cache_lookup
      | Evidence_read
    [@@deriving bin_io, compare, equal, sexp]
  end

  type t =
    { key : string
    ; kind : string
    ; state : string
    ; run : Run_ref.t option
    ; error : string option
    ; activity : Activity.t [@sexp.default Unreported] [@sexp_drop_default.equal]
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Preview = struct
  type t =
    { selection : Selection.t
    ; plan_identity : string
    ; plan_json : string
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Launch = struct
  (** Durable reservation order, exact preview, and allocation identity. This is not
      evidence of current producer ownership or of a terminal producer outcome. *)
  type t =
    { key : string
    ; preview : Preview.t
    ; run_id : string option
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Acceptance = struct
  type t =
    { support_tools : string
    ; precheck_python : string
    ; testbench : string
    ; testbench_top : string
    ; replay_trace : string
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Finalization = struct
  type t =
    { key : string
    ; run : Run_ref.t
    ; execution_file : string
    ; acceptance_requested : bool
    ; attempt : string option
    ; state : string
    ; phase : string option
    ; operation_status : string option
    ; acceptance : string option
    ; error : string option
    ; owned : bool
    ; execution_timing : Execution_timing.t option
         [@sexp.default None] [@sexp_drop_default.equal]
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Fresh = struct
  module Intent = struct
    (** Captured inputs, not generated source bytes or an exact provider preview. *)
    type t =
      { id : string
      ; selection : Selection.t
      ; elaboration_only : bool
      ; expected_plan_identity : string option
      ; scope : string
      ; created_at : Timestamp.t
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Phase = struct
    type t =
      | Reserved
      | Building
      | Emitting
      | Prepared
      | Physical
      | Completed
      | Failed
      | Cancelled
      | Interrupted
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Prepared = struct
    type t =
      { bundle_identity : string
      ; bundle_directory : string
      ; plan_identity : string
      ; methodology_plan_path : string
      ; methodology_plan_digest : string
      }
    [@@deriving bin_io, compare, equal, sexp]
  end

  module Workflow = struct
    type t =
      { id : string
      ; key : string
      ; intent : Intent.t
      ; phase : Phase.t
      ; cancel_requested : bool
      ; preparation_id : string option
      ; elaboration_started_at : Timestamp.t option [@sexp.default None]
      ; elaboration_finished_at : Timestamp.t option [@sexp.default None]
      ; elaboration_status : string
      ; build_job : Job.t option
      ; emission_job : Job.t option
      ; prepared : Prepared.t option
      ; run : Run_ref.t option
      ; reference : Reference.t option
      ; error : string option
      ; created_at : Timestamp.t
      ; finished_at : Timestamp.t option
      }
    [@@deriving bin_io, compare, equal, sexp]
  end
end

module Snapshot = struct
  type t =
    { configured : bool
    ; flows : Flow.t list
    ; catalog_default : Flow_default.t option [@sexp.default None]
    ; description_json : string option
    ; preview : Preview.t option
    ; runs : Run.t list
    ; operations : Pending.t list
    ; launches : Launch.t list [@sexp.default []]
    ; summaries : Summary.t list
    ; finalizations : Finalization.t list [@sexp.default []]
    ; artifacts : Asic_artifact.Reference.t list [@sexp.default []]
    ; artifact_pages : Asic_artifact.Page.t list [@sexp.default []]
    ; artifact_byte_pages : Asic_artifact.Byte_page.t list [@sexp.default []]
    ; inspections : Asic_inspection.Index.t list [@sexp.default []]
    ; inspection_details : Asic_inspection.Detail.t list [@sexp.default []]
    ; cache_error : string option
    ; fresh_intent : Fresh.Intent.t option [@sexp.default None]
    ; workflows : Fresh.Workflow.t list [@sexp.default []]
    ; resources : Asic_resources.Snapshot.t option [@sexp.default None] [@sexp_drop_default.equal]
    ; workloads : Asic_workloads.Snapshot.t option [@sexp.default None] [@sexp_drop_default.equal]
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Operation = struct
  (** Queries schedule bounded/coalesced background work and return a snapshot promptly.
      Poll [Get] for completion. [Run.key] is an idempotency key; reuse with different
      arguments is an error. Disconnecting a client never cancels daemon-owned work.
      Summary selection does not launch tools. [Refresh] explicitly validates source
      evidence, including the last explicitly adopted finalization attempt. An ordinary
      [Load_summary] may return cached/unverified evidence. [Inspect_finalization] adopts
      an existing public operation reference; it never starts finalization. [Finalize]
      reserves exact inputs persistently before scheduling the sole owned producer.
      [Observe_finalization] is read-only and never reacquires process ownership.
      [Inspect] with [refresh=false] uses the bounded derived inspection cache or a
      bounded cold public read; [refresh=true] revalidates public evidence. Neither starts
      EDA. [Inspect_detail] fences the exact index digest and row. Artifact reads accept
      only catalog IDs for the current adopted terminal attempt, never client paths.
      [Inspect_analysis] captures [Timing_analysis.target] from the selected summary; its
      index query pins the analysis digest. [Inspect_analysis_detail] requires the same
      captured target plus the returned INDEX [source_digest] and [row_id]. Both reject
      missing/replaced analysis identity. They use timing/[target.stage] internally, never
      prepare a stage, and retain cache-only reopening as cached-unverified. Wait keys are
      [Asic_inspection.analysis_index_key]/[analysis_detail_key]. *)
  type t =
    | Get
    | Resources of Asic_resources.Operation.t
    | Workloads of Asic_workloads.Operation.t
    | Discover
    | Describe of string
    | Plan of Selection.t
    | Stage_fresh of
        { selection : Selection.t
        ; elaboration_only : bool
        ; expected_plan_identity : string option
        }
    | Launch_fresh of
        { key : string
        ; intent_id : string
        }
    | Cancel_workflow of string
    | Run of
        { key : string
        ; preview : Preview.t
        }
    | Register of Reference.t
    | Observe of Run_ref.t
    | Load_summary of Run_ref.t
    | Refresh of Run_ref.t
    | Inspect_finalization of
        { run : Run_ref.t
        ; attempt : string
        }
    | Finalize of
        { key : string
        ; run : Run_ref.t
        ; execution_file : string
        ; acceptance : Acceptance.t option
        }
    | Observe_finalization of string
    | List_artifacts of Run_ref.t
    | Inspect of
        { run : Run_ref.t
        ; domain : string
        ; stage : string
        ; refresh : bool
        }
    | Inspect_detail of
        { run : Run_ref.t
        ; domain : string
        ; stage : string
        ; source_digest : string
        ; row_id : string
        }
    | Read_artifact_bytes of
        { run : Run_ref.t
        ; artifact_id : string
        ; offset : int
        ; limit : int
        }
    | Read_artifact of
        { run : Run_ref.t
        ; artifact_id : string
        ; offset : int
        ; limit : int
        }
    | Cancel of string
    | Inspect_analysis of
        { run : Run_ref.t
        ; target : Asic_inspection.Analysis_target.t
        ; refresh : bool
        }
    | Inspect_analysis_detail of
        { run : Run_ref.t
        ; target : Asic_inspection.Analysis_target.t
        ; source_digest : string
        ; row_id : string
        }
  [@@deriving bin_io, compare, equal, sexp]
end

module Request = struct
  type t =
    { instance_id : V1.Daemon_instance_id.t
    ; project : Project_id.t
    ; operation : Operation.t
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Response = struct
  type t = (Snapshot.t, V1.Error.t) Result.t [@@deriving bin_io, compare, equal, sexp]
end

module Evidence_metadata = struct
  (* Per-request opt-in: old servers ignore this header and new readers default the absent
     metadata. Do not add fields to Request, which old readers reject. *)
  let header = "X-Workbench-Asic-Evidence-Metadata"
  let version = "1"
  let negotiated value = Option.value_map value ~default:false ~f:(String.equal version)
  let timing_analysis_header = "X-Workbench-Asic-Timing-Analysis"
  let timing_analysis_version = "2"

  let sexp_of_response
    ?(timing_analysis_header_value = None)
    ?(execution_timing_header_value = None)
    ~header_value
    response
    =
    let response =
      if Option.equal
           String.equal
           timing_analysis_header_value
           (Some timing_analysis_version)
      then response
      else if negotiated timing_analysis_header_value
      then
        Result.map response ~f:(fun (snapshot : Snapshot.t) ->
          { snapshot with
            summaries =
              List.map snapshot.summaries ~f:(fun summary ->
                { summary with
                  Summary.timing_analysis =
                    Option.filter summary.timing_analysis ~f:(fun analysis ->
                      String.equal analysis.target.stage "signoff"
                      && Option.is_none analysis.target.execution_file)
                })
          ; inspections =
              List.map snapshot.inspections ~f:(fun index ->
                { index with
                  Asic_inspection.Index.analysis =
                    Option.filter index.analysis ~f:(fun target ->
                      String.equal target.stage "signoff"
                      && Option.is_none target.execution_file)
                })
          })
      else
        Result.map response ~f:(fun (snapshot : Snapshot.t) ->
          { snapshot with
            summaries =
              List.map snapshot.summaries ~f:(fun summary ->
                { summary with Summary.timing_analysis = None })
          ; inspections =
              List.map snapshot.inspections ~f:(fun index ->
                { index with Asic_inspection.Index.analysis = None })
          })
    in
    let response =
      if negotiated header_value
      then response
      else
        Result.map response ~f:(fun (snapshot : Snapshot.t) ->
          { snapshot with
            inspections =
              List.map snapshot.inspections ~f:(fun index ->
                { index with Asic_inspection.Index.times = Evidence_time.Index.empty })
          ; operations =
              List.map snapshot.operations ~f:(fun operation ->
                { operation with Pending.activity = Unreported })
          })
    in
    Response.sexp_of_t response
    |> Execution_timing.negotiate ~header_value:execution_timing_header_value
  ;;
end
