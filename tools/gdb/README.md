# GDB for Toit

This package implements the client side of GDB's Remote Serial Protocol (RSP)
over arbitrary Toit readers and writers. It supports packet checksums,
acknowledged and no-ack modes, escaping, run-length decoding, capability
discovery, requests, and chunked `qXfer` reads.

Transport is deliberately separate: callers can use TCP, serial, a pipe, or an
in-memory stream.

```toit
import gdb.gdb as gdb

client := gdb.Client reader writer
client.initialize
register-packet := client.request "g"
```

`Client.read-qxfer` handles target-description and thread XML transfers while
leaving XML interpretation to the caller. This keeps the package useful for
debuggers and inspection tools beyond the current QEMU capture path.
