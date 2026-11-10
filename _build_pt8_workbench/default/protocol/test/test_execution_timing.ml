open! Core
open Hardcaml_workbench_protocol

module Legacy_stage = struct
  type t =
    { id : string
    ; name : string
    ; status : Asic.Stage.Status.t
    ; requested : bool
    ; reason : string option
    ; action : Asic.Selection.t option
    }
  [@@deriving sexp]
end

module Legacy_summary = struct
  type t =
    { id : string
    ; job : Job_id.t
    ; suite : string
    ; seed : string
    ; created_at : string
    ; parent : Simulation.Parent.t option
    ; lifecycle : Simulation.Lifecycle.t
    ; outcome : Simulation.Outcome.t
    }
  [@@deriving sexp]
end

let%test_unit "strict legacy stage and simulation summary readers" =
  let stage =
    Asic.Stage.t_of_sexp
      (Sexp.of_string
         "((id synthesis) (name Synthesis) (status Completed) (requested true) (reason \
          ()) (action ()))")
  in
  assert (Option.is_none stage.execution_timing);
  let timing = Execution_timing.make ~measured_seconds:3. ~running:false () in
  let wire = Asic.Stage.sexp_of_t { stage with execution_timing = timing } in
  assert (Result.is_error (Or_error.try_with (fun () -> Legacy_stage.t_of_sexp wire)));
  ignore
    (Legacy_stage.t_of_sexp (Execution_timing.negotiate ~header_value:None wire)
     : Legacy_stage.t);
  let summary =
    Simulation.Summary.t_of_sexp
      (Sexp.of_string
         "((id sim) (job job) (suite suite) (seed 42) (created_at old) (parent ()) \
          (lifecycle Finished) (outcome Passed))")
  in
  assert (Option.is_none summary.execution_timing);
  let wire = Simulation.Summary.sexp_of_t { summary with execution_timing = timing } in
  assert (Result.is_error (Or_error.try_with (fun () -> Legacy_summary.t_of_sexp wire)));
  ignore
    (Legacy_summary.t_of_sexp (Execution_timing.negotiate ~header_value:None wire)
     : Legacy_summary.t);
  let restored =
    Simulation.Summary.t_of_sexp
      (Execution_timing.negotiate ~header_value:(Some "1") wire)
  in
  assert (Option.equal Execution_timing.equal restored.execution_timing timing)
;;

let%test_unit "duration bounds and terminal/live distinction" =
  let start =
    Execution_timing.timestamp "2026-10-20T12:00:00.000000Z" |> Option.value_exn
  in
  List.iter [ Float.nan; Float.infinity; -1.; 1e13 ] ~f:(fun measured_seconds ->
    assert (Option.is_none (Execution_timing.make ~measured_seconds ~running:false ())));
  let zero =
    Execution_timing.make ~measured_seconds:0. ~started_at:start ~running:true ()
    |> Option.value_exn
  in
  assert (Option.equal Float.equal zero.measured_seconds (Some 0.));
  assert (not zero.running);
  assert (Option.is_none (Execution_timing.make ~running:true ()));
  assert (Option.is_none (Execution_timing.timestamp "not a time"));
  let live = Execution_timing.make ~started_at:start ~running:true () in
  assert (Option.value_exn live).running;
  assert (not (Option.value_exn (Execution_timing.stopped live)).running)
;;

let%test_unit "timing opt-in is independent and strips nested fields for strict readers" =
  let legacy = Sexp.of_string "(Ok ((runs (((id r) (stages (((id s)))))))))" in
  let extended =
    Sexp.of_string
      "(Ok ((runs (((id r) (execution_timing ((measured_seconds (9)) (started_at ()) \
       (running false))) (stages (((id s) (execution_timing ((measured_seconds (0)) \
       (started_at ()) (running false)))))))))))"
  in
  List.iter [ None; Some "0"; Some "2" ] ~f:(fun header_value ->
    [%test_result: Sexp.t]
      (Execution_timing.negotiate ~header_value extended)
      ~expect:legacy);
  [%test_result: Sexp.t]
    (Execution_timing.negotiate ~header_value:(Some "1") extended)
    ~expect:extended
;;
