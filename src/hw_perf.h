// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

// Hardware measurements (Kconfig TOIT_HW_PERF, off by default): cycles,
// and on Xtensa retired instructions plus one selectable stall or
// exception counter of the core's performance monitor, accumulated per
// core for what the VM is doing (running a process, in a primitive, in the
// GC, idle, ...) and per primitive. Profiler.start without an installed
// profiler resets them and Profiler.stop prints them (primitive_core.cc).
// Without TOIT_HW_PERF everything here is empty.

#pragma once

#include "top.h"

#ifdef TOIT_ESP32
#include <esp_attr.h>  // Includes sdkconfig.h.
#endif

#if defined(TOIT_ESP32) && defined(CONFIG_TOIT_HW_PERF)

#define TOIT_HW_PERF 1

#include <esp_cpu.h>

namespace toit {

enum HwPerfBucket {
  HWP_PROCESS,  // Scheduler::run_process (scheduling overhead included).
  HWP_RUN,      // Interpreter::run.
  HWP_PRIM,     // C++ primitives called by the interpreter or the core.
  HWP_ALLOC,    // The core's allocation and stack-growth calls into C++.
  HWP_GC,       // Scheduler::gc.
  HWP_IDLE,     // A scheduler thread waiting for a ready process.
  HWP_SEND,     // Scheduler::send_message.
  HWP_YIELDED,  // Count only: runs that ended yielded.
  HWP_PREEMPTED,  // Count only: runs that ended preempted.
  HWP_COUNT
};

struct HwPerfSample {
  uint32 cycles;
  uint32 insns;
  uint32 other;
  uint32 generation;  // Intervals that span a reset are dropped.
};

extern volatile uint32 hw_perf_generation;
extern uint32 hw_perf_configured[2];
void hw_perf_configure();

static inline int hw_perf_core() {
#if CONFIG_FREERTOS_UNICORE || SOC_CPU_CORES_NUM == 1
  return 0;
#else
  return esp_cpu_get_core_id();
#endif
}

#if defined(__XTENSA__)
static inline uint32 hw_perf_eri_read(int address) {
  uint32 result;
  __asm__ volatile("rer %0, %1" : "=r"(result) : "r"(address));
  return result;
}
#endif

static inline void hw_perf_sample(HwPerfSample* sample) {
  if (hw_perf_configured[hw_perf_core()] != hw_perf_generation) hw_perf_configure();
  sample->generation = hw_perf_generation;
  sample->cycles = esp_cpu_get_cycle_count();
#if defined(__XTENSA__)
  // ERI_PERFMON_PM0 and PM1 (xtensa-debug-module.h).
  sample->insns = hw_perf_eri_read(0x101080);
  sample->other = hw_perf_eri_read(0x101084);
#else
  sample->insns = 0;
  sample->other = 0;
#endif
}

void hw_perf_add(int bucket, const HwPerfSample* start);
void hw_perf_count(int bucket);
void hw_perf_primitive(int module, int index, const HwPerfSample* start);
void hw_perf_reset();
void hw_perf_dump();

class HwPerfScope {
 public:
  explicit HwPerfScope(int bucket) : bucket_(bucket) { hw_perf_sample(&start_); }
  ~HwPerfScope() { hw_perf_add(bucket_, &start_); }

 private:
  int bucket_;
  HwPerfSample start_;
};

}  // namespace toit

#define HW_PERF_SCOPE(bucket) toit::HwPerfScope hw_perf_scope_(toit::bucket)
#define HW_PERF_COUNT(bucket) toit::hw_perf_count(toit::bucket)
#define HW_PERF_PRIMITIVE_START(name) toit::HwPerfSample name; toit::hw_perf_sample(&name)
#define HW_PERF_PRIMITIVE_END(name, module, index) toit::hw_perf_primitive(module, index, &name)

#else

#define HW_PERF_SCOPE(bucket)
#define HW_PERF_COUNT(bucket)
#define HW_PERF_PRIMITIVE_START(name)
#define HW_PERF_PRIMITIVE_END(name, module, index)

#endif
