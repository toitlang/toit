// Copyright (C) 2026 Toit contributors.

// Reproducer of the launch-fuzz finding of 2026-11-10 (commit cec3d9e5b): the
// C++ primitive task_receive_message dereferenced NULL when a program called
// it without a pending message (the library only calls it when
// task_has_messages is true). It returns null now.

task-receive-message_:
  #primitive.core.task-receive-message

main:
  print (task-receive-message_ == null ? "null" : "message")
