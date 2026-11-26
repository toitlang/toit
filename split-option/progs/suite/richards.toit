// Copyright 2006-2008 the V8 project authors. All rights reserved.
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
//       copyright notice, this list of conditions and the following
//       disclaimer in the documentation and/or other materials provided
//       with the distribution.
//     * Neither the name of Google Inc. nor the names of its
//       contributors may be used to endorse or promote products derived
//       from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


// This is a Toit implementation of the Richards
// benchmark from:
//
//    http://www.cl.cam.ac.uk/~mr10/Bench.html
//
// The benchmark was originally implemented in BCPL by
// Martin Richards.

import .benchmark

main:
  log-execution-time "Richards" --iterations=10: run-richards

/**
The Richards benchmark simulates the task dispatcher of an
  operating system.
*/
run-richards:
  scheduler := Scheduler
  scheduler.add-idle-task ID-IDLE 0 null COUNT

  queue := Packet null ID-WORKER KIND-WORK
  queue = Packet queue ID-WORKER KIND-WORK
  scheduler.add-worker-task ID-WORKER 1000 queue

  queue = Packet null ID-DEVICE-A KIND-DEVICE
  queue = Packet queue ID-DEVICE-A KIND-DEVICE
  queue = Packet queue ID-DEVICE-A KIND-DEVICE
  scheduler.add-handler-task ID-HANDLER-A 2000 queue

  queue = Packet null ID-DEVICE-B KIND-DEVICE
  queue = Packet queue ID-DEVICE-B KIND-DEVICE
  queue = Packet queue ID-DEVICE-B KIND-DEVICE
  scheduler.add-handler-task ID-HANDLER-B 3000 queue

  scheduler.add-device-task ID-DEVICE-A 4000 null
  scheduler.add-device-task ID-DEVICE-B 5000 null

  scheduler.schedule

  assert: scheduler.queue-count == EXPECTED-QUEUE-COUNT
  assert: scheduler.hold-count == EXPECTED-HOLD-COUNT

/**
These constants specify how many times a packet is queued and
  how many times a task is put on hold in a correct run of richards.
They don't have any meaning a such but are characteristic of a
  correct run so if the actual queue or hold count is different from
  the expected there must be a bug in the implementation.
*/
COUNT                ::= 10000
EXPECTED-QUEUE-COUNT ::= 23246
EXPECTED-HOLD-COUNT  ::= 9297

ID-IDLE       ::= 0
ID-WORKER     ::= 1
ID-HANDLER-A  ::= 2
ID-HANDLER-B  ::= 3
ID-DEVICE-A   ::= 4
ID-DEVICE-B   ::= 5
NUMBER-OF-IDS ::= 6

KIND-DEVICE   ::= 0
KIND-WORK     ::= 1


/**
A scheduler can be used to schedule a set of tasks based on their relative
  priorities.  Scheduling is done by maintaining a list of task control blocks
  which holds tasks and the data queue they are processing.
*/
class Scheduler:
  queue-count := 0
  hold-count := 0
  blocks := List NUMBER-OF-IDS
  list := null
  current-tcb := null
  current-id := null

  /**
  Adds an idle task to this scheduler.
  - $id: the identity of the task.
  - $priority: the task's priority.
  - $queue: the queue of work to be processed by the task.
  - $count: the number of times to schedule the task.
  */
  add-idle-task id/int priority/int queue/Packet? count/int:
    add-running-task id priority queue
      IdleTask this 1 count

  /**
  Adds a work task to this scheduler.
  - $id: the identity of the task.
  - $priority: the task's priority.
  - $queue: the queue of work to be processed by the task.
  */
  add-worker-task id/int priority/int queue/Packet:
    add-task id priority queue
      WorkerTask this ID-HANDLER-A 0

  /**
  Adds a handler task to this scheduler.
  - $id: the identity of the task.
  - $priority: the task's priority.
  - $queue: the queue of work to be processed by the task.
  */
  add-handler-task id/int priority/int queue/Packet:
    add-task id priority queue
      HandlerTask this

  /**
  Adds a handler task to this scheduler.
  - $id: the identity of the task.
  - $priority: the task's priority.
  - $queue: the queue of work to be processed by the task.
  */
  add-device-task id/int priority/int queue/Packet?:
    add-task id priority queue
      DeviceTask this

  /**
  Adds the specified task and mark it as running.
  - $id: the identity of the task.
  - $priority: the task's priority.
  - $queue: the queue of work to be processed by the task.
  - $task: the task to add.
  */
  add-running-task id/int priority/int queue/Packet? task:
    add-task id priority queue task
    current-tcb.set-running

  /**
  Add the specified task to this scheduler.
  - $id: the identity of the task.
  - $priority: the task's priority.
  - $queue: the queue of work to be processed by the task.
  - $task: the task to add.
   */
  add-task id/int priority/int queue/Packet? task:
    current-tcb = TaskControlBlock list id priority queue task
    list = current-tcb
    blocks[id] = current-tcb

  /** Executes the tasks managed by this scheduler. */
  schedule:
    current-tcb = list
    while current-tcb:
      if current-tcb.is-held-or-suspended:
        current-tcb = current-tcb.link
      else:
        current-id = current-tcb.id
        current-tcb = current-tcb.run

  /**
  Blocks the currently executing task and return the next task control block
    to run.  The blocked task will not be made runnable until it is explicitly
    released, even if new work is added to it.
  */
  hold-current:
    hold-count++
    current-tcb.mark-as-held
    return current-tcb.link

  /**
  Suspends the currently executing task and return the next task control block
    to run.  If new work is added to the suspended task it will be made runnable.
  */
  suspend-current:
    current-tcb.mark-as-suspended
    return current-tcb

  /**
  Release a task that is currently blocked and return the next block to run.
  - $id: the id of the task to suspend.
  */
  release id:
    tcb := blocks[id]
    if not tcb: return tcb
    tcb.mark-as-not-held
    return tcb.priority > current-tcb.priority ? tcb : current-tcb

  /**
  Adds the specified packet to the end of the worklist used by the task
    associated with the packet and make the task runnable if it is currently
    suspended.
  - $packet: the packet to add.
   */
  queue packet/Packet:
    t := blocks[packet.id]
    if not t: return t
    queue-count++
    packet.link = null
    packet.id = current-id
    return t.check-priority-add current-tcb packet

/** The task is running and is currently scheduled. */
STATE-RUNNING ::= 0

/** The task has packets left to process. */
STATE-RUNNABLE ::= 1

/**
The task is not currently running.
The task is not blocked as such and may be started by the scheduler.
*/
STATE-SUSPENDED ::= 2

/** The task is blocked and cannot be run until it is explicitly released. */
STATE-HELD ::= 4

STATE-SUSPENDED-RUNNABLE ::= STATE-SUSPENDED | STATE-RUNNABLE
STATE-NOT-HELD ::= ~STATE-HELD

/**
A task control block manages a task and the queue of work packages associated
  with it.
*/
class TaskControlBlock:

  link     / TaskControlBlock? := ?
  id       / int := ?
  priority / int := ?
  queue    / Packet? := ?
  task := ?
  state / int:= ?

  /**
  - $link: the preceding block in the linked block list.
  - $id: the id of this block.
  - $priority: the priority of this block.
  - $queue: the queue of packages to be processed by the task.
  - $task: the task.
  */
  constructor .link .id .priority .queue .task:
    state = queue ? STATE-SUSPENDED-RUNNABLE : STATE-SUSPENDED

  set-running:
    state = STATE-RUNNING

  mark-as-not-held:
    state &= STATE-NOT-HELD

  mark-as-held:
    state |= STATE-HELD

  is-held-or-suspended:
    return state & STATE-HELD != 0 or state == STATE-SUSPENDED

  mark-as-suspended:
    state |= STATE-SUSPENDED

  mark-as-runnable:
    state |= STATE-RUNNABLE

  /** Runs this task, if it is ready to be run, and returns the next task to run. */
  run:
    packet := null
    if state == STATE-SUSPENDED-RUNNABLE:
      packet = queue
      queue = packet.link
      state = queue ? STATE-RUNNABLE : STATE-RUNNING
    return task.run packet

  /**
  Adds a packet to the worklist of this block's task, marks this as runnable if
    necessary, and returns the next runnable object to run (the one
    with the highest priority).
  */
  check-priority-add task packet:
    if not queue:
      queue = packet
      mark-as-runnable
      if priority > task.priority: return this
    else:
      queue = packet.add-to queue
    return task

/**
An idle task doesn't do any work itself but cycles control between the two
  device tasks.
*/
class IdleTask:

  /**
  - $scheduler: the scheduler that manages this task.
  - $v1: a seed value that controls how the device tasks are scheduled.
  - $count: the number of times this task should be scheduled.
  */
  constructor .scheduler .v1 .count:

  scheduler / Scheduler := ?
  v1 / int := ?
  count / int := ?

  run packet:
    count--
    if count == 0: return scheduler.hold-current
    if v1 & 1 == 0:
      v1 >>= 1
      return scheduler.release ID-DEVICE-A
    else:
      v1 = v1 >> 1 ^ 0xd008
      return scheduler.release ID-DEVICE-B

/**
A task that suspends itself after each time it has been run to simulate
  waiting for data from an external device.
*/
class DeviceTask:

  /**
  - $scheduler: the scheduler that manages this task.
  */
  constructor .scheduler:

  scheduler / Scheduler := ?
  v1 := null

  run packet:
    if not packet:
      if not v1: return scheduler.suspend-current
      v := v1
      v1 = null
      return scheduler.queue v
    else:
      v1 = packet
      return scheduler.hold-current

/** A task that manipulates work packets. */
class WorkerTask:

  /**
  - $scheduler: the scheduler that manages this task.
  - $v1: a seed used to specify how work packets are manipulated.
  - $v2: another seed used to specify how work packets are manipulated.
  */
  constructor .scheduler .v1 .v2:

  scheduler / Scheduler := ?
  v1 / int := ?
  v2 / int := ?

  run packet:
    if not packet: return scheduler.suspend-current
    v1 = v1 == ID-HANDLER-A ? ID-HANDLER-B : ID-HANDLER-A
    packet.id = v1
    packet.a1 = 0
    for i := 0; i < DATA-SIZE; i++:
      if ++v2 > 26: v2 = 1
      packet.a2[i] = v2
    return scheduler.queue packet

/** A task that manipulates work packets and then suspends itself. */
class HandlerTask:

  /**
  - $scheduler: the scheduler that manages this task.
  */
  constructor .scheduler:

  scheduler / Scheduler := ?
  v1 := null
  v2 := null

  run packet:
    if packet:
      if packet.kind == KIND-WORK:
        v1 = packet.add-to v1
      else:
        v2 = packet.add-to v2
    if v1:
      count := v1.a1
      if count < DATA-SIZE:
        if v2:
          v := v2
          v2 = v2.link
          v.a1 = v1.a2[count]
          v1.a1 = count + 1
          return scheduler.queue v
      else:
        v := v1
        v1 = v1.link
        return scheduler.queue v
    return scheduler.suspend-current

/* --- *
 * P a c k e t
 * --- */
DATA-SIZE := 4

/**
A simple package of data that is manipulated by the tasks.  The exact layout
  of the payload data carried by a packet is not important, and neither is the
  nature of the work performed on packets by the tasks.

Besides carrying data, packets form linked lists and are hence used both as
  data and worklists.
*/
class Packet:

  /**
  - $link: the tail of the linked list of packets.
  - $id: an ID for this packet.
  - $kind: the type of this packet.
  */
  constructor .link .id .kind:

  link / Packet? := ?
  id   / int := ?
  kind / int := ?
  a1 := 0
  a2 := List DATA-SIZE

  add-to queue:
    link = null
    if not queue: return this
    next := queue
    while true:
      peek := next.link
      if not peek: break
      next = peek
    next.link = this
    return queue
