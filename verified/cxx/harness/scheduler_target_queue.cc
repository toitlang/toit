// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "process.h"
#include "process_group.h"
#include "scheduler.h"
#undef protected
#undef private

using namespace toit;
using Queue = ProcessListFromScheduler;
using Link = Queue::Element;
using Member = ProcessListFromProcessGroup::Element;
extern Process first_process, next_process, last_process, extra_process;

extern ProcessGroup first_group, next_group;

extern SchedulerThread first_worker, next_worker;

static void check_worker_cursor() {
  SchedulerThreadList workers;
  bool empty = nondet_bool();
  bool last = nondet_bool();
  auto* first = static_cast<SchedulerThreadList::Element*>(&first_worker);
  workers.anchor_.next_ = empty ? nullptr : first;
  first->next_ = last ? nullptr : static_cast<SchedulerThreadList::Element*>(&next_worker);
  auto it = workers.begin();
  auto end = workers.end();
  CXXV_ASSERT(end.entry_ == nullptr && (it != end) == !empty, "the worker iterator ends at null");
  if (empty) return;
  CXXV_ASSERT(*it == &first_worker, "the worker cursor recovers the containing thread");
  ++it;
  CXXV_ASSERT((it != end) == !last && (last || *it == &next_worker), "advance follows the worker list link");
}

static void check_group_cursor() {
  ProcessGroupList groups;
  auto* anchor = &groups.anchor_;
  bool empty = nondet_bool();
  bool last = nondet_bool();
  anchor->next_ = empty ? anchor : &first_group;
  first_group.next_ = last ? anchor : &next_group;
  auto it = groups.begin();
  auto end = groups.end();
  CXXV_ASSERT(end.entry_ == anchor && (it != end) == !empty,
              "the scheduler group iterator ends at its own anchor");
  if (empty) return;
  CXXV_ASSERT(*it == &first_group, "the group cursor names the registered group");
  ++it;
  CXXV_ASSERT((it != end) == !last && (last || *it == &next_group), "advance to the next registered group");
}

static void check_member_cursor() {
  auto& members = first_group.processes();
  CXXV_ASSERT(&members == &first_group.processes_, "the group owns the member list being enumerated");
  bool empty = nondet_bool();
  bool last = nondet_bool();
  auto* first = static_cast<Member*>(&first_process);
  auto* next = static_cast<Member*>(&next_process);
  members.anchor_.next_ = empty ? nullptr : first;
  first->next_ = last ? nullptr : next;
  auto it = members.begin();
  auto end = members.end();
  CXXV_ASSERT(end.entry_ == nullptr && (it != end) == !empty, "the group member range ends at null");
  if (empty) return;
  CXXV_ASSERT(*it == &first_process, "the membership cursor recovers its containing process");
  Queue targets;
  static_cast<Link*>(&first_process)->next_ = nullptr;
  targets.append(&first_process);
  ++it;
  CXXV_ASSERT((it != end) == !last && (last || *it == &next_process),
              "appending a target preserves the next group member");
}

extern Scheduler scheduler;
static void check_priority_bucket() {
  uint8 priority = nondet_uchar();
  uint8 other = nondet_uchar();
  int bucket = Scheduler::compute_ready_queue_index(priority);
  int other_bucket = Scheduler::compute_ready_queue_index(other);
  CXXV_ASSERT(0 <= bucket && bucket < Scheduler::NUMBER_OF_READY_QUEUES &&
              (priority > other ? bucket <= other_bucket : bucket >= other_bucket),
              "every priority selects an in-bounds queue, with higher priorities visited first");
  auto& selected = scheduler.ready_queue(priority);
  auto& second = scheduler.ready_queue(other);
  CXXV_ASSERT(&selected == &scheduler.ready_queue_[bucket] && (&selected == &second) == (bucket == other_bucket),
              "two priorities share the same physical FIFO exactly when their bucket indices agree");
  new (&selected) Queue();
  selected.append(&extra_process);
  CXXV_ASSERT(scheduler.ready_queue(priority).remove_first() == &extra_process && selected.is_empty(),
              "both accesses at a priority use the same live scheduler FIFO");
}

int main() {
  check_priority_bucket();
  check_worker_cursor();
  check_group_cursor();
  check_member_cursor();
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  Queue queue;
  bool empty = nondet_bool();
  bool singleton = !empty && nondet_bool();
  bool pair = !empty && !singleton && nondet_bool();
  Link* first = empty ? nullptr : static_cast<Link*>(&first_process);
  Link* next = empty || singleton ? nullptr : static_cast<Link*>(&next_process);
  Link* last = empty ? &queue.anchor_ : singleton ? first : pair ? next : static_cast<Link*>(&last_process);
  queue.anchor_.next_ = first;
  queue.tail_ = last;
  // In a longer queue the unexamined part starts at the successor. Only
  // the final link and the removed head's successor matter to this step.
  if (first) first->next_ = next;
  if (!empty) last->next_ = nullptr;
  auto* member = static_cast<Member*>(&first_process);
  auto* group_next = member->next_;
  auto* suffix = next ? next->next_ : nullptr;
  CXXV_ASSERT(queue.is_empty() == empty && queue.first() == (empty ? nullptr : &first_process),
              "emptiness and the logical head agree with the scheduler links");
  auto it = queue.begin();
  auto end = queue.end();
  CXXV_ASSERT(end.entry_ == nullptr && (it != end) == !empty, "range iteration starts at the head and stops at null");
  if (!empty) {
    CXXV_ASSERT(*it == &first_process, "the scheduler link recovers its containing process");
    ++it;
    CXXV_ASSERT(it.entry_ == next && (it != end) == !singleton, "advance follows one scheduler link");
    if (next) CXXV_ASSERT(*it == &next_process, "the next cursor names the successor process");
  }
  Process* removed = queue.remove_first();
  CXXV_ASSERT(removed == (empty ? nullptr : &first_process) && queue.anchor_.next_ == next &&
              queue.tail_ == (next ? last : &queue.anchor_), "pop returns the head and preserves the remaining FIFO");
  CXXV_ASSERT((!first || !first->next_) && (!next || next->next_ == suffix) && member->next_ == group_next,
              "pop detaches only the scheduler link and preserves the suffix and group membership");

  auto* added = static_cast<Link*>(&extra_process);
  added->next_ = nullptr;
  queue.append(&extra_process);
  CXXV_ASSERT(queue.anchor_.next_ == (next ? next : added) && queue.tail_ == added &&
              (!next || last->next_ == added) && !added->next_, "append extends the retained FIFO at its tail");
}
