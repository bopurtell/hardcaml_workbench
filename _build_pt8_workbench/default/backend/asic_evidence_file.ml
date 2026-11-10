open! Core

let read_bounded filename limit =
  let fd = Core_unix.openfile filename ~mode:[ O_RDONLY; O_NONBLOCK; O_CLOEXEC ] in
  Exn.protect
    ~finally:(fun () -> Core_unix.close fd)
    ~f:(fun () ->
      let stat = Core_unix.fstat fd in
      if not (Poly.equal stat.st_kind S_REG)
      then failwith "Public evidence is not a regular file";
      if Int64.(stat.st_size > of_int limit)
      then failwith "Public evidence exceeds byte budget";
      let buf = Bytes.create (limit + 1) in
      let rec read pos =
        if pos > limit then failwith "Public evidence grew beyond byte budget";
        let n = Core_unix.read fd ~buf ~pos ~len:(limit + 1 - pos) in
        if n = 0 then Bytes.To_string.sub buf ~pos:0 ~len:pos else read (pos + n)
      in
      read 0)
;;
