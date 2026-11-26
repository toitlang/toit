// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The rate limit of the out-of-memory heap reports of a process group
// (src/out_of_memory.h): the first failure is reported, the failures in the
// following interval are counted, and the next report after the interval
// carries the count. Groups are independent. (The system process is never
// limited: Scheduler::should_report_allocation_failure doesn't consult a
// limiter for it; tests/sandbox/oom-report-rate-test.toit runs the VM.)

#include "../../src/top.h"
#include "../../src/out_of_memory.h"

using namespace toit;

static const int64 SECOND = 1000 * 1000;
static const int64 INTERVAL = OutOfMemoryReportLimiter::INTERVAL_US;

static void expect_report(OutOfMemoryReportLimiter* limiter, int64 now, word expected_suppressed) {
  word suppressed = -1;
  if (!limiter->should_report(now, &suppressed)) FATAL("no report at %lld us", static_cast<long long>(now));
  if (suppressed != expected_suppressed) {
    FATAL("report at %lld us: %ld suppressed, expected %ld",
          static_cast<long long>(now), static_cast<long>(suppressed), static_cast<long>(expected_suppressed));
  }
}

static void expect_suppressed(OutOfMemoryReportLimiter* limiter, int64 now) {
  word suppressed = -1;
  if (limiter->should_report(now, &suppressed)) FATAL("unexpected report at %lld us", static_cast<long long>(now));
  if (suppressed != -1) FATAL("a suppressed failure changed the count argument");
}

int main(int argc, char** argv) {
  if (INTERVAL < SECOND) FATAL("the interval is shorter than a second");

  // The first failure is reported, whenever it happens (also at time 0).
  { OutOfMemoryReportLimiter limiter;
    expect_report(&limiter, 0, 0);
    expect_suppressed(&limiter, 0);
  }

  // A storm: 397 failures within one interval give one report; the next
  // failure after the interval is reported with the count.
  OutOfMemoryReportLimiter limiter;
  int64 start = 5 * SECOND;
  expect_report(&limiter, start, 0);
  for (int i = 1; i < 397; i++) {
    expect_suppressed(&limiter, start + i * (INTERVAL / 400));
  }
  if (limiter.suppressed() != 396) FATAL("counted %ld", static_cast<long>(limiter.suppressed()));
  expect_suppressed(&limiter, start + INTERVAL - 1);
  expect_report(&limiter, start + INTERVAL, 397);
  // The interval starts again at the last report.
  expect_suppressed(&limiter, start + INTERVAL + 1);
  expect_suppressed(&limiter, start + 2 * INTERVAL - 1);
  expect_report(&limiter, start + 2 * INTERVAL, 2);
  // After a quiet period the next failure is reported right away, with no
  // count.
  expect_report(&limiter, start + 10 * INTERVAL, 0);

  // Another group's limiter is independent.
  OutOfMemoryReportLimiter other;
  expect_report(&other, start + 10 * INTERVAL + 1, 0);
  expect_suppressed(&limiter, start + 10 * INTERVAL + 2);
  expect_suppressed(&other, start + 10 * INTERVAL + 3);
  if (limiter.suppressed() != 1 || other.suppressed() != 1) FATAL("groups share a count");

  printf("ok\n");
  return 0;
}
