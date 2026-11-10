open! Core
open Hardcaml

(* This executable knows hardware and checks, not the Workbench protocol. The
   project-owned provider.py translates its flushed observations into FS2 events. *)
let () =
  let argv = Sys.get_argv () in
  if Array.length argv <> 7 then failwith "counter CASE SEED CYCLES STEP VCD INJECT";
  let case = argv.(1) in
  let seed = Int64.of_string argv.(2) in
  let cycles = Int.of_string argv.(3) in
  let step = Int.of_string argv.(4) in
  let inject = Bool.of_string argv.(6) in
  if cycles < 32 || cycles > 100000 then failwith "cycles must be 32..100000";
  if step < 1 || step > 15 then failwith "step must be 1..15";
  let open Signal in
  let clock = input "clock" 1 in
  let clear = input "clear" 1 in
  let enable = input "enable" 1 in
  let spec = Reg_spec.create ~clock ~clear () in
  let count = reg_fb spec ~enable ~width:4 ~f:(fun q -> q +:. step) in
  let circuit = Circuit.create_exn ~name:"fs2_counter" [ output "count" count ] in
  let trace = Out_channel.create argv.(5) in
  let sim = Vcd.wrap trace (Cyclesim.create circuit) in
  let clear = Cyclesim.in_port sim "clear" in
  let enable = Cyclesim.in_port sim "enable" in
  let count = Cyclesim.out_port sim "count" in
  let expected = ref 0 in
  let state = ref seed in
  let failures = ref 0 in
  let wraps = ref 0 in
  for cycle = 0 to cycles - 1 do
    (* Fixed LCG, including seed 0, independent of OCaml Random versions. *)
    (state := Int64.((!state * 6364136223846793005L) + 1442695040888963407L));
    let reset = cycle = 0 || (String.equal case "reset" && cycle % 13 = 0) in
    let en = (not (String.equal case "seeded")) || Int64.(!state land 4L <> 0L) in
    clear := Bits.of_int_trunc ~width:1 (Bool.to_int reset);
    enable := Bits.of_int_trunc ~width:1 (Bool.to_int en);
    if reset
    then expected := 0
    else if en
    then (
      if !expected + step > 15 then Stdlib.incr wraps;
      expected := (!expected + step) land 15);
    Cyclesim.cycle sim;
    let actual = Bits.to_int_trunc !count in
    let wanted = if inject && cycle = 17 then !expected lxor 1 else !expected in
    if actual <> wanted
    then (
      Stdlib.incr failures;
      printf "CHECK_FAILED cycle=%d expected=%d actual=%d\n%!" cycle wanted actual);
    if cycle % 8 = 0 || cycle = cycles - 1
    then printf "PROGRESS %d %d\n%!" (cycle + 1) cycles
  done;
  Out_channel.close trace;
  if String.equal case "wrap" && !wraps = 0 then failwith "directed wrap coverage missing";
  printf
    "RESULT %s checks=%d wraps=%d seed=%s step=%d\n%!"
    (if !failures = 0 then "Passed" else "Failed")
    cycles
    !wraps
    argv.(2)
    step
;;
