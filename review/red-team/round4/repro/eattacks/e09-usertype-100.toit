// Copyright (C) 2026 Toit contributors.

send_ pid/int type/int msg -> bool: #primitive.core.process_send
self_ -> int: #primitive.core.process_current_id
sys_ -> int: #primitive.core.process_system_id
grant_ gid/int pid/int: #primitive.core.process_grant_send
spawn_ gid method args: #primitive.core.spawn
pid-ext_ id/string: #primitive.core.pid_for_external_id
SYS-TERMINATED ::= 0
SYS-SPAWNED ::= 1
SYS-TRACE ::= 2
SYS-RPC-REQUEST ::= 3
SYS-RPC-REPLY ::= 4
SYS-RPC-CANCEL ::= 5
SYS-RPC-NOTIFY-TERMINATED ::= 6
SYS-RPC-NOTIFY-RESOURCE ::= 7
SYS-EXTERNAL-NOTIFICATION ::= 8
try_ name/string [fn]:
  e := catch: fn.call
  print "attack $name: $(e ? "threw $e" : "no-throw")"

main:
  try_ "usertype-100": send_ sys_ 100 [1,2,3]
  print "E-DONE"
