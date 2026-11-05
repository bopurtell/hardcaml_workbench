open! Core
open Hardcaml_workbench_protocol
module W = Asic_workloads

let%test_unit "captured workload queries retain every fence and ordered input" =
  let query = W.Query.Compare
    { left = Bundle "/left"; right = Execution "/right.json"; axis = Resource_policy
    ; left_workload = Some "/left/result.json"; right_workload = Some "/right/result.json"
    ; expected_left_digest = Some (String.make 64 'a')
    ; expected_right_digest = Some (String.make 64 'b')
    ; expected_left_workload_digest = Some (String.make 64 'c')
    ; expected_right_workload_digest = Some (String.make 64 'd') }
  in
  let operation = Asic.Operation.Workloads (Load { query; refresh = true }) in
  assert (Asic.Operation.equal operation
    (Asic.Operation.t_of_sexp (Asic.Operation.sexp_of_t operation)));
  let key refresh = W.Operation.key (Load {query;refresh}) in
  assert (String.equal (key true) (key false));
  let changed = match query with
    | Inspect _ -> assert false
    | Compare q -> W.Query.Compare {q with expected_right_workload_digest=None} in
  assert (not (String.equal (key true) (W.Operation.key (Load {query=changed;refresh=true}))));
  let snapshot = W.Snapshot.
    {entries=[];cache_error=None;
     selected=Some {key=key false;digest=String.make 64 'e';
       json="{\"value\":9007199254740993,\"ratio\":{\"numerator\":1,\"denominator\":3}}"}} in
  assert (W.Snapshot.equal snapshot (W.Snapshot.t_of_sexp (W.Snapshot.sexp_of_t snapshot)))
;;

let%test_unit "legacy ASIC snapshots omit the optional workloads field" =
  let snapshot : Asic.Snapshot.t =
    { configured=false;flows=[];catalog_default=None;description_json=None;preview=None
    ; runs=[];operations=[];launches=[];summaries=[];finalizations=[];artifacts=[]
    ; artifact_pages=[];artifact_byte_pages=[];inspections=[];inspection_details=[]
    ; cache_error=None;fresh_intent=None;workflows=[];resources=None;workloads=None } in
  let sexp = Asic.Snapshot.sexp_of_t snapshot in
  assert (not (String.is_substring (Sexp.to_string_mach sexp) ~substring:"workloads"));
  assert (Asic.Snapshot.equal snapshot (Asic.Snapshot.t_of_sexp sexp))
;;
