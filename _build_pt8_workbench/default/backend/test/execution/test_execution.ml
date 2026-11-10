open! Core
open Hardcaml_workbench_protocol

let require condition message = if not condition then failwith message

let job ~project ~id ~namespace ~name =
  Job.create
    ~id:(Job_id.of_string id)
    ~kind:{ Job.Kind.namespace; name }
    ~project
    ~created_at:(Timestamp.of_time_ns Time_ns.epoch)
;;

let () =
  let a = Project_id.of_string "project-a" in
  let b = Project_id.of_string "project-b" in
  let make project id namespace name = job ~project ~id ~namespace ~name in
  let a_build = make a "a-build" "dune" "build" in
  let a_test =
    { (make a "a-test" "dune" "test") with
      state = Failed
    ; exit_status = Some (Launch_failed { reason = "test executable missing" })
    ; failure = Some "could not launch test"
    ; finished_at = Some (Timestamp.of_time_ns Time_ns.epoch)
    }
  in
  let b_test =
    { (make b "b-test" "dune" "test") with state = Failed; exit_status = Some (Exited 7) }
  in
  let b_build = make b "b-build" "dune" "build" in
  let jobs =
    [ make a "a-rtl" "driver" "generate_rtl"
    ; b_test
    ; a_test
    ; make a "a-discovery" "driver" "describe"
    ; a_build
    ; make b "b-rtl" "driver" "generate_rtl"
    ; make a "a-other-test" "driver" "test"
    ; make a "a-other-dune" "dune" "generate_rtl"
    ; b_build
    ]
  in
  let view_a = Execution.project_snapshot ~project:a jobs in
  let view_b = Execution.project_snapshot ~project:b jobs in
  require (Project_id.equal view_a.project a) "Projection lost project identity";
  require
    (List.equal Job.equal view_a.attempts [ a_test; a_build ])
    "Project A attempts leaked other projects/kinds, changed order, or lost metadata";
  require
    (List.equal Job.equal view_a.tests [ a_test ])
    "Project A tests lost launch-failure metadata or included non-tests";
  require
    (List.equal Job.equal view_b.attempts [ b_test; b_build ])
    "Project B attempts leaked Project A jobs";
  require
    (List.equal Job.equal view_b.tests [ b_test ])
    "Project B test lost its nonzero exit status";
  List.iter (view_a.attempts @ view_b.attempts) ~f:(fun attempt ->
    require
      (Option.is_none attempt.run && Option.is_none attempt.build)
      "Generic execution fabricated backend run/build identities");
  let absent =
    Execution.project_snapshot ~project:(Project_id.of_string "unopened") jobs
  in
  require
    (List.is_empty absent.attempts && List.is_empty absent.tests)
    "A project with no attempts inherited another project's tests";
  let empty = Execution.project_snapshot ~project:a [] in
  require
    (List.is_empty empty.attempts && List.is_empty empty.tests)
    "Empty input fabricated attempts";
  print_endline "execution projection tests passed"
;;
