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

#include "hw_perf.h"

#ifdef TOIT_HW_PERF

#include <esp_freertos_hooks.h>
#include <esp_timer.h>
#ifdef CONFIG_TOIT_HW_PERF_STALL_SAMPLES
#include <esp_intr_alloc.h>
#include <esp_ipc.h>
#endif
#include <soc/soc_caps.h>
#include <stdio.h>
#include <string.h>

namespace toit {

// The second counter cycles through these on every reset (the first one
// always counts retired instructions). Select and mask values of
// xtensa/xt_perf_consts.h.
struct HwPerfMode {
  const char* name;
  uint16 select;
  uint16 mask;
};

#ifdef CONFIG_TOIT_HW_PERF_STALL_SAMPLES
// Stall sampling: the second counter raises the profiling interrupt every
// PERIODS[mode] events of the mode; the PC samples are the PCs the
// performance monitor latched (INTPC), not timer ticks. The cycles mode is
// a dense time profile (about 20 kHz at 240 MHz).
static const HwPerfMode MODES[] = {
  { "i-stall-busy", 4, 0x0002 },   // Instruction RAM/ROM busy: flash-cache misses of code.
  { "d-stall-busy", 3, 0x0010 },   // Data RAM/ROM/XLMI busy: flash-cache misses of data.
  { "cycles", 0, 0x0001 },         // XTPERF_CNT_CYCLES.
};
static const uint32 PERIODS[] = { 1021, 1021, 12007 };
static volatile uint32 stall_period = 1021;
#else
static const HwPerfMode MODES[] = {
  { "i-stall", 4, 0x1ff },         // XTPERF_CNT_I_STALL, all.
  { "d-stall", 3, 0x1fe },         // XTPERF_CNT_D_STALL, all.
  { "i-stall-busy", 4, 0x0002 },   // Instruction RAM/ROM busy.
  { "d-stall-busy", 3, 0x0010 },   // Data RAM/ROM/XLMI busy.
  { "exr-window", 5, 0x0020 },     // Window exceptions.
  { "exr-int", 5, 0x0006 },        // Interrupts (level 1 and higher).
};
#endif
static const int MODE_COUNT = sizeof(MODES) / sizeof(MODES[0]);

struct HwPerfCounters {
  uint64 cycles;
  uint64 insns;
  uint64 other;
  uint32 count;
};

struct HwPerfPrimitive {
  uint32 key;  // module << 12 | index, plus one; 0 for an empty slot.
  uint32 count;
  uint64 cycles;
  uint64 insns;
  uint64 other;
};

static const int PRIMITIVE_SLOTS = 128;

volatile uint32 hw_perf_generation = 1;
uint32 hw_perf_configured[2];
static int mode_index = 0;
static int64 reset_time_us = 0;
static HwPerfCounters counters[2][HWP_COUNT];
static HwPerfPrimitive primitives[2][PRIMITIVE_SLOTS];
static uint32 primitive_overflow[2];

// PC sampling: the FreeRTOS tick hook of each core records the PC of the
// code the tick interrupted (from the interrupt frame the port saved at
// the task's top of stack: XT_STK_PC on Xtensa, RV_STK_MEPC on RISC-V).
// Build with a higher CONFIG_FREERTOS_HZ for more samples.
static const int PC_SLOTS = 1024;
struct HwPerfPc {
  uint32 pc;
  uint32 count;
};
static HwPerfPc pcs[2][PC_SLOTS];
static uint32 pc_samples[2];
static uint32 pc_overflow[2];
static bool tick_hooks_registered = false;
static volatile bool sampling = false;  // Not while printing the dump.

}  // namespace toit

extern "C" void* volatile pxCurrentTCBs[];

namespace toit {

static void IRAM_ATTR hw_perf_record_pc(int core, uint32 pc) {
  pc_samples[core]++;
  uint32 slot = (pc * 2654435761u) >> 22;  // 10 bits: PC_SLOTS.
  for (int i = 0; i < 8; i++) {
    HwPerfPc* p = &pcs[core][(slot + i) & (PC_SLOTS - 1)];
    if (p->pc == pc || p->pc == 0) {
      p->pc = pc;
      p->count++;
      return;
    }
  }
  pc_overflow[core]++;
}

static void IRAM_ATTR hw_perf_tick() {
#ifndef CONFIG_TOIT_HW_PERF_STALL_SAMPLES
  if (!sampling) return;
  int core = hw_perf_core();
  uint32** tcb = reinterpret_cast<uint32**>(pxCurrentTCBs[core]);
  if (tcb == null) return;
  uint32* frame = *tcb;  // pxTopOfStack, the first field of the TCB.
  if (frame == null) return;
#if defined(__XTENSA__)
  uint32 pc = frame[1];
#else
  uint32 pc = frame[0];
#endif
  hw_perf_record_pc(core, pc);
#endif
}

#if defined(__XTENSA__)
static inline void IRAM_ATTR eri_write_(int address, uint32 value) {
  __asm__ volatile("wer %0, %1" : : "r"(value), "r"(address));
  __asm__ volatile("isync");
}
#endif

#ifdef CONFIG_TOIT_HW_PERF_STALL_SAMPLES
// The profiling interrupt (level 3) of the performance monitor: PM1
// overflowed after PERIODS[mode] events. Records the PC the monitor
// latched at that event (ERI_PERFMON_INTPC), restarts PM1 and clears its
// overflow status (ERI_PERFMON_PMSTAT1, write one to clear).
static void IRAM_ATTR hw_perf_stall_isr(void* arg) {
  int core = hw_perf_core();
  uint32 pc = hw_perf_eri_read(0x101010);
  uint32 status = hw_perf_eri_read(0x101184);
  eri_write_(0x101084, static_cast<uint32>(-static_cast<int32>(stall_period)));
  eri_write_(0x101184, status);
  if (sampling) hw_perf_record_pc(core, pc);
}

static intr_handle_t stall_interrupts[2];

static void hw_perf_alloc_stall_interrupt(void* arg) {
  int core = hw_perf_core();
  if (stall_interrupts[core] != null) return;
  esp_err_t err = esp_intr_alloc(ETS_INTERNAL_PROFILING_INTR_SOURCE,
                                 ESP_INTR_FLAG_LEVEL3 | ESP_INTR_FLAG_IRAM,
                                 hw_perf_stall_isr, null, &stall_interrupts[core]);
  if (err != ESP_OK) printf("[hw-perf] core %d: no profiling interrupt (%d)\n", core, err);
}
#endif

void IRAM_ATTR hw_perf_configure() {
  int core = hw_perf_core();
  uint32 generation = hw_perf_generation;
#if defined(__XTENSA__)
  const HwPerfMode& mode = MODES[mode_index];
  // ERI_PERFMON_PGM: off while reprogramming.
  eri_write_(0x101000, 0);
  // PM0 counts retired instructions (XTPERF_CNT_INSN, mask 0xffff for
  // XTPERF_MASK_INSN_ALL), PM1 the mode's input; trace level 15 and
  // KRNLCNT 0: at every interrupt level, like CCOUNT.
  uint32 tracelevel = 15 << 4;
  eri_write_(0x101080, 0);
  eri_write_(0x101100, tracelevel | (2 << 8) | (0x8dffu << 16));
#ifdef CONFIG_TOIT_HW_PERF_STALL_SAMPLES
  // PM1 starts at -PERIODS[mode] and interrupts on overflow (PMCTRL INTEN).
  eri_write_(0x101184, hw_perf_eri_read(0x101184));
  eri_write_(0x101084, static_cast<uint32>(-static_cast<int32>(stall_period)));
  eri_write_(0x101104, tracelevel | (static_cast<uint32>(mode.select) << 8) |
                       (static_cast<uint32>(mode.mask) << 16) | 1);
#else
  eri_write_(0x101084, 0);
  eri_write_(0x101104, tracelevel | (static_cast<uint32>(mode.select) << 8) |
                       (static_cast<uint32>(mode.mask) << 16));
#endif
  eri_write_(0x101000, 1);  // PGM_PMEN.
#endif
  hw_perf_configured[core] = generation;
}

void IRAM_ATTR hw_perf_add(int bucket, const HwPerfSample* start) {
  HwPerfSample now;
  hw_perf_sample(&now);
  if (now.generation != start->generation) return;
  HwPerfCounters* c = &counters[hw_perf_core()][bucket];
  c->cycles += now.cycles - start->cycles;
  c->insns += now.insns - start->insns;
  c->other += now.other - start->other;
  c->count++;
}

void IRAM_ATTR hw_perf_count(int bucket) {
  counters[hw_perf_core()][bucket].count++;
}

void IRAM_ATTR hw_perf_primitive(int module, int index, const HwPerfSample* start) {
  HwPerfSample now;
  hw_perf_sample(&now);
  if (now.generation != start->generation) return;
  int core = hw_perf_core();
  HwPerfCounters* c = &counters[core][HWP_PRIM];
  uint32 cycles = now.cycles - start->cycles;
  uint32 insns = now.insns - start->insns;
  uint32 other = now.other - start->other;
  c->cycles += cycles;
  c->insns += insns;
  c->other += other;
  c->count++;
  uint32 key = ((static_cast<uint32>(module) << 12) | static_cast<uint32>(index)) + 1;
  uint32 slot = (key * 2654435761u) >> 25;  // 7 bits: PRIMITIVE_SLOTS.
  for (int i = 0; i < PRIMITIVE_SLOTS; i++) {
    HwPerfPrimitive* p = &primitives[core][(slot + i) & (PRIMITIVE_SLOTS - 1)];
    if (p->key == key || p->key == 0) {
      p->key = key;
      p->count++;
      p->cycles += cycles;
      p->insns += insns;
      p->other += other;
      return;
    }
  }
  primitive_overflow[core]++;
}

void hw_perf_reset() {
  mode_index = (mode_index + 1) % MODE_COUNT;
#ifdef CONFIG_TOIT_HW_PERF_STALL_SAMPLES
  stall_period = PERIODS[mode_index];
#endif
  memset(counters, 0, sizeof(counters));
  memset(primitives, 0, sizeof(primitives));
  memset(primitive_overflow, 0, sizeof(primitive_overflow));
  memset(pcs, 0, sizeof(pcs));
  memset(pc_samples, 0, sizeof(pc_samples));
  memset(pc_overflow, 0, sizeof(pc_overflow));
  if (!tick_hooks_registered) {
    tick_hooks_registered = true;
    for (int core = 0; core < SOC_CPU_CORES_NUM; core++) {
      esp_register_freertos_tick_hook_for_cpu(hw_perf_tick, core);
#ifdef CONFIG_TOIT_HW_PERF_STALL_SAMPLES
      // Internal interrupts are per core: allocate on each.
      if (core == hw_perf_core()) {
        hw_perf_alloc_stall_interrupt(null);
      } else {
        esp_ipc_call_blocking(core, hw_perf_alloc_stall_interrupt, null);
      }
#endif
    }
  }
  reset_time_us = esp_timer_get_time();
  hw_perf_generation = hw_perf_generation + 1;
  sampling = true;
}

static const char* BUCKET_NAMES[HWP_COUNT] = {
  "process", "run", "prim", "alloc", "gc", "idle", "send", "yielded", "preempted"
};

void hw_perf_dump() {
  sampling = false;
  int64 wall_us = esp_timer_get_time() - reset_time_us;
#if defined(__XTENSA__)
  const char* other = MODES[mode_index].name;
#else
  const char* other = "none";
#endif
  printf("[hw-perf] wall %lld us mode %s\n", static_cast<long long>(wall_us), other);
  for (int core = 0; core < 2; core++) {
    for (int b = 0; b < HWP_COUNT; b++) {
      HwPerfCounters* c = &counters[core][b];
      if (c->count == 0) continue;
      printf("[hw-perf] core %d %s n %u cyc %llu ins %llu %s %llu\n", core, BUCKET_NAMES[b],
             static_cast<unsigned>(c->count), static_cast<unsigned long long>(c->cycles),
             static_cast<unsigned long long>(c->insns), other, static_cast<unsigned long long>(c->other));
    }
    // The primitives, most cycles first (a selection sort of the few
    // non-empty slots).
    bool printed[PRIMITIVE_SLOTS] = { false };
    for (int k = 0; k < 24; k++) {
      int best = -1;
      for (int i = 0; i < PRIMITIVE_SLOTS; i++) {
        HwPerfPrimitive* p = &primitives[core][i];
        if (p->key == 0 || printed[i]) continue;
        if (best < 0 || p->cycles > primitives[core][best].cycles) best = i;
      }
      if (best < 0) break;
      printed[best] = true;
      HwPerfPrimitive* p = &primitives[core][best];
      uint32 key = p->key - 1;
      printf("[hw-perf] core %d prim %u:%u n %u cyc %llu ins %llu %s %llu\n", core,
             static_cast<unsigned>(key >> 12), static_cast<unsigned>(key & 0xfff),
             static_cast<unsigned>(p->count), static_cast<unsigned long long>(p->cycles),
             static_cast<unsigned long long>(p->insns), other, static_cast<unsigned long long>(p->other));
    }
    if (primitive_overflow[core] != 0) {
      printf("[hw-perf] core %d prim-overflow %u\n", core, static_cast<unsigned>(primitive_overflow[core]));
    }
    // The PC samples (hw-pc lines), twelve per line.
#ifdef CONFIG_TOIT_HW_PERF_STALL_SAMPLES
    printf("[hw-pc] core %d samples %u overflow %u stall-period %u\n", core,
           static_cast<unsigned>(pc_samples[core]), static_cast<unsigned>(pc_overflow[core]),
           static_cast<unsigned>(stall_period));
#else
    printf("[hw-pc] core %d samples %u overflow %u\n", core, static_cast<unsigned>(pc_samples[core]),
           static_cast<unsigned>(pc_overflow[core]));
#endif
    int on_line = 0;
    for (int i = 0; i < PC_SLOTS; i++) {
      HwPerfPc* p = &pcs[core][i];
      if (p->pc == 0) continue;
      if (on_line == 0) printf("[hw-pc] %d", core);
      printf(" %x:%u", static_cast<unsigned>(p->pc), static_cast<unsigned>(p->count));
      if (++on_line == 12) { printf("\n"); on_line = 0; }
    }
    if (on_line != 0) printf("\n");
  }
  printf("[hw-perf] end\n");
}

}  // namespace toit

#endif  // TOIT_HW_PERF
