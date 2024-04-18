# Project root multi test

There are 4 projects: 'p1', 'p2', and 'p3-bad', and 'p3-good'.
Project p1 depends on p2. Project p2 depends on *a* project p3.
The lock-file in p1 makes p2 resolve its p3 import to p3-bad.
The lock-file in p2 makes p2 resolve its p3 import to p3-good.

When giving diagnostics, the LSP should use the lock-file in p2,
and thus resolve p3 to p3-good.
