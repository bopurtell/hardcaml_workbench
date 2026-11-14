(lang dune 3.22)

(name hardcaml_workbench)

(generate_opam_files true)

(source
 (github bopurtell/silver))

(authors "Bohdan Purtell <bohdanpurtell@gmail.com>")

(maintainers "Bohdan Purtell <bohdanpurtell@gmail.com>")

(package
 (name hardcaml_workbench)
 (synopsis "A local development workbench for independent Hardcaml projects")
 (description
  "A standalone native OCaml application for inspecting, running, measuring, and\ndebugging independently owned Hardcaml projects.")
 (depends
  (ocaml
   (>= 5.1))
  ; Portable shared protocol and application code.
   core
   hardcaml_workbench_provider
   ppx_jane
   ; Native daemon, backend, and adapters.
   core_unix
   bonsai
   bonsai_term
   bonsai_term_components
   ; Direct use of Notty is limited to the development baseline capture, which
   ; serialises a rendered bonsai_term view; bonsai_term already requires it.
   notty-community
   async
   cohttp-async
   cryptokit
   hardcaml
   hardcaml_waveterm
   yojson
   (conf-python-3 :with-test)
   ; Repository development tools.
  (ppx_js_style :with-dev-setup)
  (ocamlformat :with-dev-setup)
   (ocaml-lsp-server :with-dev-setup)))

(package
 (name hardcaml_workbench_provider)
 (synopsis "Synchronous FS2 simulation provider adapter library")
 (description "Shared FS2 wire types, validation and synchronous provider plumbing.")
  (depends
   (ocaml (>= 5.1))
   core
   core_unix
   ppx_jane
   (conf-python-3 :with-test)))

(package
 (name hardcaml_workbench_web)
 (synopsis "Optional browser client for Silver")
 (description
  "The optional Bonsai Web client and precompiled browser assets for Silver.")
 (allow_empty)
 (depends
  (ocaml
   (>= 5.1))
  core
  ppx_jane
  bonsai
  bonsai_web
  js_of_ocaml
  js_of_ocaml-ppx
  ppx_css
  (ppx_js_style :with-dev-setup)
  (ocamlformat :with-dev-setup)))
