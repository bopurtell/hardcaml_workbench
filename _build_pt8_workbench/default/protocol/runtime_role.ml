(** Portable values shared by the native daemon and JavaScript frontend live in this
    library.

    The project, target, job, and artifact schemas are in place. Nothing here may contain
    a process handle, a file descriptor, a filesystem path, or any other native-only
    resource: a client receives identifiers and public metadata, and asks the daemon to
    resolve them. The typed request, response, and incremental-update contracts are added
    by the next milestone 1A construction task, once the architecture records the
    application RPC transport and serialization choice.

    Schemas are derived for both [sexp] and [bin_io] so that choosing a transport later
    does not require revising them. *)
