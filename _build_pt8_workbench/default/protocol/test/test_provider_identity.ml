open! Core
module W = Hardcaml_workbench_provider.Wire
module D = Hardcaml_workbench_protocol

(* These assignments deliberately require nominal type identity, rather than accepting
   equivalent encodings or a conversion between duplicated types. *)
let request (value : W.Provider.Request.t) : D.Simulation.Provider.Request.t = value
let event (value : W.Provider.Event.t) : D.Simulation.Provider.Event.t = value
let discovery (value : W.Discovery.t) : D.Simulation.Discovery.t = value
let selection (value : W.Selection.t) : D.Simulation.Selection.t = value
let backend (value : W.Backend_id.t) : D.Backend_id.t = value
let build (value : W.Build_ref.t) : D.Build_ref.t = value
let run (value : W.Run_ref.t) : D.Run_ref.t = value

let%test_unit "provider aliases retain FS2 identity" =
  let value : W.Discovery.t = { protocol_version = 1; suites = [] } in
  assert (D.Simulation.Discovery.equal (discovery value) value)
;;
