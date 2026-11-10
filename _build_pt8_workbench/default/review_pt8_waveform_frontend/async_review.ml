open! Core
open! Async
open Hardcaml_workbench_protocol
module E = Terminal_presentation.Simulation_export
module S = Simulation

let artifact : S.Artifact.t =
  { id = "wave"; attempt_id = "attempt"; case_id = Some "flops256"; label = "wave"
  ; kind = "trace"; media_type = "text/vcd"; size = Some 3
  ; sha256 = Some (Terminal_presentation.Plain_rpc.digest "abc"); availability = Available }
;;

let page bytes_hex : S.Byte_page.t =
  { attempt_id = artifact.attempt_id; artifact_id = artifact.id
  ; sha256 = Option.value_exn artifact.sha256; offset = 0; next_offset = 3
  ; total_size = 3; eof = true; bytes_hex }
;;

let main () =
  let published = ref 0 in
  let run ~current ~fetch = E.run ~artifact ~fetch ~current ~viewer:None
    ~publish:(fun _ _ -> incr published; return (Ok "verified"))
    ~launch:(fun ~prog:_ ~args:_ -> assert false) in
  let%bind good = run ~current:(fun () -> true)
    ~fetch:(fun ~offset:_ ~limit:_ -> return (Ok (page "616263"))) in
  assert (Or_error.is_ok good && !published = 1);
  printf "PASS actual export digest verifies before publication\n";
  let%bind bad = run ~current:(fun () -> true)
    ~fetch:(fun ~offset:_ ~limit:_ -> return (Ok (page "616264"))) in
  assert (Or_error.is_error bad && !published = 1);
  printf "PASS changed actual bytes rejected despite claimed correct digest\n";
  let gate = Ivar.create () and requested = Ivar.create () in
  let current = ref true in
  let pending = run ~current:(fun () -> !current)
    ~fetch:(fun ~offset:_ ~limit:_ -> Ivar.fill_exn requested (); Ivar.read gate) in
  let%bind () = Ivar.read requested in
  current := false;
  Ivar.fill_exn gate (Ok (page "616263"));
  let%bind late = pending in
  assert (Or_error.is_error late && !published = 1);
  printf "PASS late byte reply after owner replacement cannot publish\n";
  let%map next = run ~current:(fun () -> true)
    ~fetch:(fun ~offset:_ ~limit:_ -> return (Ok (page "616263"))) in
  assert (Or_error.is_ok next && !published = 2);
  printf "PASS replacement owner independently loads verified bytes\n"
;;

let () =
  don't_wait_for (main () >>= fun () -> Shutdown.exit 0);
  never_returns (Scheduler.go ())
;;
