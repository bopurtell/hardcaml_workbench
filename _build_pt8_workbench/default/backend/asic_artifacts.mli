open! Core
open Hardcaml_workbench_protocol

(** Explicit synchronous filesystem work; callers should schedule off the event loop.
    Raises on invalid evidence. No provider calls or writes. At most 32 entries, each at
    most 16 MiB. An overfull catalog raises instead of silently truncating. Only terminal
    receipt references, declared metric/check sources, hash-inventoried raw artifacts and
    exact hash-bearing selected evidence are supported.

    [sha256] is always observed and verified at listing. Labels mark sources without a
    provider-declared hash as [observed SHA-256; not provider-declared]. Labels are
    control-sanitized and truncated to 160 bytes, preserving the hash qualifier.
    NUL-containing or malformed UTF-8 files are binary, accessible via [read_bytes].
    Checkpoint views require explicit hash-bearing selected evidence or a mapped raw
    artifact; directories and unhashed checkpoint manifests are never scanned. *)
val list : summary:Asic.Summary.t -> Asic_artifact.Reference.t list

(** Accept only a previously listed, unchanged server reference (retain it server-side;
    clients select an opaque ID, never submit paths). The process-local authorization
    cache retains the latest 1024 references; relist after eviction/restart. Reopens a
    regular file nonblocking, checks its canonical descriptor target, and hashes the
    complete bounded contents from that same descriptor before paging. Errors are returned
    in [Page.error], with no text and no offset advancement.

    [offset] and [next_offset] count raw bytes; [limit] is 1..65536 raw bytes. UTF-8
    scalar boundaries are preserved by shortening pages; a mid-scalar offset or a limit
    too small for the next scalar returns an error. C0/C1 controls except newline/tab and
    Unicode direction overrides/isolates are removed from text. Sanitization never changes
    raw offsets. *)
val read
  :  reference:Asic_artifact.Reference.t
  -> offset:int
  -> limit:int
  -> Asic_artifact.Page.t

(** Raw transfer for either text or binary references, using the same authorization,
    descriptor, size and complete-file SHA-256 verification as [read]. [offset] and
    [next_offset] count raw bytes; [limit] must be 1..65536 raw bytes. [bytes_hex] encodes
    exactly the requested slice, without sanitization, newline conversion or UTF-8
    decoding. EOF at the file size succeeds with an empty payload. Errors are returned in
    [Byte_page.error] with no payload, no offset advancement and [eof=false]. *)
val read_bytes
  :  reference:Asic_artifact.Reference.t
  -> offset:int
  -> limit:int
  -> Asic_artifact.Byte_page.t
