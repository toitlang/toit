// Copyright (C) 2026 Toitware ApS.
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

#include "top.h"

#if defined(TOIT_ESP32) && CONFIG_TOIT_DEVICE_MEMORY_DUMP

#include <esp_chip_info.h>
#include <esp_cpu.h>
#include <esp_heap_caps.h>
#include <esp_ipc_isr.h>
#include <esp_private/system_internal.h>
#include <freertos/FreeRTOS.h>
#include <hal/mwdt_ll.h>
#include <hal/timer_hal.h>
#include <hal/wdt_hal.h>
#include <hal/wdt_types.h>
#include <heap_memory_layout.h>

#if CONFIG_SPIRAM
#include <esp_psram.h>
#endif

#include <driver/uart.h>
#include <soc/rtc.h>
#include <soc/soc.h>
#include <soc/uart_reg.h>

#include "device_memory_dump_esp32.h"
#include "utils.h"

namespace toit {

void panic_put_char(char c);

namespace {

const uint32 DUMP_FORMAT_VERSION = 1;
const uword DUMP_CHUNK_SIZE = 1024;

enum DumpFrameType : uint8 {
  DUMP_FRAME_INFO = 1,
  DUMP_FRAME_REGION = 2,
  DUMP_FRAME_END = 3,
  DUMP_FRAME_CPU = 4,
};

enum DumpRegionKind : uint8 {
  DUMP_REGION_INTERNAL = 1,
  DUMP_REGION_EXTERNAL = 2,
  DUMP_REGION_RTC = 3,
  DUMP_REGION_WORD_ONLY = 4,
};

enum DumpFrameFlags : uint16 {
  DUMP_FRAME_FIRST = 1 << 0,
  DUMP_FRAME_LAST = 1 << 1,
  DUMP_FRAME_VOLATILE = 1 << 2,
  DUMP_FRAME_TRUNCATED = 1 << 3,
  DUMP_FRAME_PARTIAL = 1 << 4,
};

enum DumpCaptureFlags : uint32 {
  DUMP_CAPTURE_PSRAM_PRESENT = 1 << 0,
  DUMP_CAPTURE_PSRAM_TRUNCATED = 1 << 1,
  DUMP_CAPTURE_CURRENT_STACK_VOLATILE = 1 << 2,
  DUMP_CAPTURE_PERIPHERALS_RUNNING = 1 << 3,
  DUMP_CAPTURE_PEER_CPU_FROZEN = 1 << 4,
  DUMP_CAPTURE_CPU_EVIDENCE = 1 << 5,
  DUMP_CAPTURE_PEER_CPU_PARTIAL = 1 << 6,
};

enum DumpCpuArchitecture : uint32 {
  DUMP_CPU_XTENSA = 1,
  DUMP_CPU_RISCV = 2,
};

enum DumpCpuProvenance : uint32 {
  DUMP_CPU_CALLING_SAMPLE = 1,
  DUMP_CPU_IPC_INTERRUPT = 2,
};

enum DumpRegisterId : uint32 {
  DUMP_REGISTER_PC = 1,
  DUMP_REGISTER_SP = 2,
  DUMP_REGISTER_STATUS = 3,
  DUMP_REGISTER_CAUSE = 4,
  DUMP_REGISTER_FAULT_ADDRESS = 5,
  DUMP_REGISTER_XTENSA_SAR = 0x100,
  DUMP_REGISTER_XTENSA_A0 = 0x110,
  DUMP_REGISTER_RISCV_X0 = 0x200,
};

enum DumpSpecialRegister : uint32 {
  DUMP_SPECIAL_PC = 1 << 0,
  DUMP_SPECIAL_STATUS = 1 << 1,
  DUMP_SPECIAL_CAUSE = 1 << 2,
  DUMP_SPECIAL_FAULT_ADDRESS = 1 << 3,
  DUMP_SPECIAL_SAR = 1 << 4,
};

struct DumpCpuEvidence {
  volatile uint32 ready;
  uint32 pc;
  uint32 status;
  uint32 cause;
  uint32 fault_address;
  uint32 gpr_valid;
  uint32 gpr[32];
  uint32 special_valid;
  uint32 sar;
};

static_assert(offsetof(DumpCpuEvidence, ready) == 0, "CPU evidence layout");
static_assert(offsetof(DumpCpuEvidence, pc) == 4, "CPU evidence layout");
static_assert(offsetof(DumpCpuEvidence, status) == 8, "CPU evidence layout");
static_assert(offsetof(DumpCpuEvidence, cause) == 12, "CPU evidence layout");
static_assert(offsetof(DumpCpuEvidence, fault_address) == 16, "CPU evidence layout");
static_assert(offsetof(DumpCpuEvidence, gpr_valid) == 20, "CPU evidence layout");
static_assert(offsetof(DumpCpuEvidence, gpr) == 24, "CPU evidence layout");
static_assert(offsetof(DumpCpuEvidence, special_valid) == 152, "CPU evidence layout");
static_assert(offsetof(DumpCpuEvidence, sar) == 156, "CPU evidence layout");

static DRAM_ATTR DumpCpuEvidence calling_cpu_evidence;
#if SOC_CPU_CORES_NUM > 1 && CONFIG_ESP_IPC_ISR_ENABLE
static DRAM_ATTR DumpCpuEvidence peer_cpu_evidence;

extern "C" void toit_dump_capture_peer_registers(void* evidence);

#if CONFIG_IDF_TARGET_ARCH_RISCV
// The RISC-V IPC interrupt handler has saved a0-a7, t0-t6, and ra at
// sp[0..15]. The remaining integer registers are still live because this
// callback is assembly-only and does not return.
asm(
    ".section .iram1,\"ax\"\n"
    ".balign 4\n"
    ".global toit_dump_capture_peer_registers\n"
    ".type toit_dump_capture_peer_registers,@function\n"
    "toit_dump_capture_peer_registers:\n"
    "mv t0, a0\n"
    "csrr t1, mepc\n"
    "sw t1, 4(t0)\n"
    "csrr t1, mstatus\n"
    "sw t1, 8(t0)\n"
    "csrr t1, mcause\n"
    "sw t1, 12(t0)\n"
    "csrr t1, mtval\n"
    "sw t1, 16(t0)\n"
    "lw t1, 60(sp)\n"
    "sw t1, 28(t0)\n"
    "addi t1, sp, 64\n"
    "sw t1, 32(t0)\n"
    "sw gp, 36(t0)\n"
    "sw tp, 40(t0)\n"
    "lw t1, 32(sp)\n"
    "sw t1, 44(t0)\n"
    "lw t1, 36(sp)\n"
    "sw t1, 48(t0)\n"
    "lw t1, 40(sp)\n"
    "sw t1, 52(t0)\n"
    "sw s0, 56(t0)\n"
    "sw s1, 60(t0)\n"
    "lw t1, 0(sp)\n"
    "sw t1, 64(t0)\n"
    "lw t1, 4(sp)\n"
    "sw t1, 68(t0)\n"
    "lw t1, 8(sp)\n"
    "sw t1, 72(t0)\n"
    "lw t1, 12(sp)\n"
    "sw t1, 76(t0)\n"
    "lw t1, 16(sp)\n"
    "sw t1, 80(t0)\n"
    "lw t1, 20(sp)\n"
    "sw t1, 84(t0)\n"
    "lw t1, 24(sp)\n"
    "sw t1, 88(t0)\n"
    "lw t1, 28(sp)\n"
    "sw t1, 92(t0)\n"
    "sw s2, 96(t0)\n"
    "sw s3, 100(t0)\n"
    "sw s4, 104(t0)\n"
    "sw s5, 108(t0)\n"
    "sw s6, 112(t0)\n"
    "sw s7, 116(t0)\n"
    "sw s8, 120(t0)\n"
    "sw s9, 124(t0)\n"
    "sw s10, 128(t0)\n"
    "sw s11, 132(t0)\n"
    "lw t1, 44(sp)\n"
    "sw t1, 136(t0)\n"
    "lw t1, 48(sp)\n"
    "sw t1, 140(t0)\n"
    "lw t1, 52(sp)\n"
    "sw t1, 144(t0)\n"
    "lw t1, 56(sp)\n"
    "sw t1, 148(t0)\n"
    "fence rw, rw\n"
    "li t1, 1\n"
    "sw t1, 0(t0)\n"
    "fence rw, rw\n"
    "1: j 1b\n"
    ".previous\n");
#elif CONFIG_IDF_TARGET_ARCH_XTENSA
#if CONFIG_ESP_SYSTEM_CHECK_INT_LEVEL_5
#define TOIT_DUMP_XTENSA_READ_INTERRUPT_STATE \
    "rsr.epc5 a4\n"                         \
    "s32i a4, a3, 4\n"                      \
    "rsr.eps5 a4\n"                         \
    "s32i a4, a3, 8\n"
#elif CONFIG_ESP_SYSTEM_CHECK_INT_LEVEL_4
#define TOIT_DUMP_XTENSA_READ_INTERRUPT_STATE \
    "rsr.epc4 a4\n"                         \
    "s32i a4, a3, 4\n"                      \
    "rsr.eps4 a4\n"                         \
    "s32i a4, a3, 8\n"
#else
#error "Unsupported Xtensa IPC interrupt level"
#endif

// The Xtensa IPC handler has already overwritten A0/A2/A3/A4. Their original
// values live in an IDF-private assembly buffer, so this callback deliberately
// records only the registers that remain architecturally available.
asm(
    ".section .iram1,\"ax\"\n"
    ".align 4\n"
    ".global toit_dump_capture_peer_registers\n"
    ".type toit_dump_capture_peer_registers,@function\n"
    "toit_dump_capture_peer_registers:\n"
    "mov a3, a2\n"
    TOIT_DUMP_XTENSA_READ_INTERRUPT_STATE
    "s32i a1, a3, 28\n"
    "s32i a5, a3, 44\n"
    "s32i a6, a3, 48\n"
    "s32i a7, a3, 52\n"
    "s32i a8, a3, 56\n"
    "s32i a9, a3, 60\n"
    "s32i a10, a3, 64\n"
    "s32i a11, a3, 68\n"
    "s32i a12, a3, 72\n"
    "s32i a13, a3, 76\n"
    "s32i a14, a3, 80\n"
    "s32i a15, a3, 84\n"
    "rsr.sar a4\n"
    "s32i a4, a3, 156\n"
    "memw\n"
    "movi a4, 1\n"
    "s32i a4, a3, 0\n"
    "memw\n"
    "1: j 1b\n"
    ".previous\n");
#undef TOIT_DUMP_XTENSA_READ_INTERRUPT_STATE
#endif
#endif

static bool memory_type_has_cap(size_t type, uint32 cap) {
  if (type >= soc_memory_type_count) return false;
  for (int i = 0; i < SOC_MEMORY_TYPE_NO_PRIOS; i++) {
    if ((soc_memory_types[type].caps[i] & cap) != 0) return true;
  }
  return false;
}

static bool is_psram_region(const soc_memory_region_t& region) {
  return memory_type_has_cap(region.type, MALLOC_CAP_SPIRAM);
}

static bool is_word_only_region(const soc_memory_region_t& region) {
  return !memory_type_has_cap(region.type, MALLOC_CAP_8BIT);
}

static uint8 region_kind(const soc_memory_region_t& region) {
  if (is_psram_region(region)) return DUMP_REGION_EXTERNAL;
  if (memory_type_has_cap(region.type, MALLOC_CAP_RTCRAM)) return DUMP_REGION_RTC;
  if (is_word_only_region(region)) return DUMP_REGION_WORD_ONLY;
  return DUMP_REGION_INTERNAL;
}

static uint32 update_crc32(uint32 crc, uint8 byte) {
  crc ^= byte;
  for (int i = 0; i < 8; i++) {
    crc = (crc >> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return crc;
}

static void dump_write_byte(uint8 byte, uint32* crc = null) {
  panic_put_char(static_cast<char>(byte));
  if (crc != null) *crc = update_crc32(*crc, byte);
}

static void dump_write_uint16(uint16 value, uint32* crc) {
  dump_write_byte(value, crc);
  dump_write_byte(value >> 8, crc);
}

static void dump_write_uint32(uint32 value, uint32* crc) {
  for (int i = 0; i < 4; i++) dump_write_byte(value >> (8 * i), crc);
}

static uint32 current_cpu_architecture() {
#if CONFIG_IDF_TARGET_ARCH_RISCV
  return DUMP_CPU_RISCV;
#elif CONFIG_IDF_TARGET_ARCH_XTENSA
  return DUMP_CPU_XTENSA;
#else
#error "Unsupported ESP32 architecture"
#endif
}

static int stack_pointer_gpr(uint32 architecture) {
  return architecture == DUMP_CPU_RISCV ? 2 : 1;
}

static void capture_calling_cpu_registers() {
  DumpCpuEvidence* evidence = &calling_cpu_evidence;
  evidence->ready = 0;
  evidence->cause = 0;
  evidence->fault_address = 0;
  evidence->gpr_valid = 0;
  evidence->special_valid = DUMP_SPECIAL_PC | DUMP_SPECIAL_STATUS;
  evidence->sar = 0;

  // This is the address at which the post-primitive sample is constructed,
  // not the PC from which the Toit program invoked the primitive.
  evidence->pc = reinterpret_cast<uword>(&&sample_point);
sample_point:
  uword sp = reinterpret_cast<uword>(esp_cpu_get_sp());
#if CONFIG_IDF_TARGET_ARCH_RISCV
  evidence->gpr[2] = sp;
  evidence->gpr_valid = 1 << 2;
  asm volatile("csrr %0, mstatus" : "=r"(evidence->status));
#elif CONFIG_IDF_TARGET_ARCH_XTENSA
  evidence->gpr[1] = sp;
  evidence->gpr_valid = 1 << 1;
  evidence->special_valid |= DUMP_SPECIAL_SAR;
  asm volatile("rsr.ps %0" : "=a"(evidence->status));
  asm volatile("rsr.sar %0" : "=a"(evidence->sar));
#endif
  evidence->ready = 1;
}

static void prepare_peer_cpu_capture() {
#if SOC_CPU_CORES_NUM > 1 && CONFIG_ESP_IPC_ISR_ENABLE
  DumpCpuEvidence* evidence = &peer_cpu_evidence;
  evidence->ready = 0;
  evidence->pc = 0;
  evidence->status = 0;
  evidence->cause = 0;
  evidence->fault_address = 0;
  evidence->sar = 0;
#if CONFIG_IDF_TARGET_ARCH_RISCV
  // X0 is architecturally hard-wired to zero, so it is sound to include it
  // even though the interrupt prologue does not save it.
  evidence->gpr[0] = 0;
  evidence->gpr_valid = UINT32_MAX;
  evidence->special_valid =
      DUMP_SPECIAL_PC | DUMP_SPECIAL_STATUS | DUMP_SPECIAL_CAUSE | DUMP_SPECIAL_FAULT_ADDRESS;
#elif CONFIG_IDF_TARGET_ARCH_XTENSA
  evidence->gpr_valid = (1 << 1) | (0x7ff << 5);
  evidence->special_valid = DUMP_SPECIAL_PC | DUMP_SPECIAL_STATUS | DUMP_SPECIAL_SAR;
#endif
  esp_ipc_isr_asm_call(&toit_dump_capture_peer_registers, evidence);
  // esp_ipc_isr_call waits until the peer handler has started, but restores
  // this core's interrupt level on return. Mask interrupts immediately, then
  // wait until the assembly callback has published the evidence.
  portDISABLE_INTERRUPTS();
  while (evidence->ready == 0) {
  }
#else
  portDISABLE_INTERRUPTS();
#endif
}

static void dump_register_pair(uint32 id, uint32 value, uint32* crc) {
  dump_write_uint32(id, crc);
  dump_write_uint32(value, crc);
}

static uint32 dump_frame_start(
    DumpFrameType type,
    uint8 kind,
    uint16 flags,
    uint32 sequence,
    uint32 region_id,
    uint32 address,
    uint32 length);
static void dump_frame_finish(uint32 crc);

static void dump_cpu_frame(
    const DumpCpuEvidence& evidence,
    uint32 core,
    uint32 architecture,
    DumpCpuProvenance provenance,
    uint32 sequence) {
  uint32 gpr_valid = evidence.gpr_valid;
  int sp_gpr = stack_pointer_gpr(architecture);
  uint32 register_count = __builtin_popcount(gpr_valid & ~(1u << sp_gpr));
  if ((gpr_valid & (1u << sp_gpr)) != 0) register_count++;
  register_count += __builtin_popcount(evidence.special_valid);

  const uint32 HEADER_WORDS = 5;
  uint32 payload_size = HEADER_WORDS * sizeof(uint32) + register_count * 2 * sizeof(uint32);
  uint16 flags = DUMP_FRAME_VOLATILE | DUMP_FRAME_PARTIAL;
  uint32 crc = dump_frame_start(
      DUMP_FRAME_CPU,
      architecture,
      flags,
      sequence,
      core,
      evidence.pc,
      payload_size);
  dump_write_uint32(1, &crc);  // CPU evidence payload version.
  dump_write_uint32(core, &crc);
  dump_write_uint32(architecture, &crc);
  dump_write_uint32(provenance, &crc);
  dump_write_uint32(register_count, &crc);

  if ((evidence.special_valid & DUMP_SPECIAL_PC) != 0) {
    dump_register_pair(DUMP_REGISTER_PC, evidence.pc, &crc);
  }
  if ((gpr_valid & (1u << sp_gpr)) != 0) {
    dump_register_pair(DUMP_REGISTER_SP, evidence.gpr[sp_gpr], &crc);
  }
  if ((evidence.special_valid & DUMP_SPECIAL_STATUS) != 0) {
    dump_register_pair(DUMP_REGISTER_STATUS, evidence.status, &crc);
  }
  if ((evidence.special_valid & DUMP_SPECIAL_CAUSE) != 0) {
    dump_register_pair(DUMP_REGISTER_CAUSE, evidence.cause, &crc);
  }
  if ((evidence.special_valid & DUMP_SPECIAL_FAULT_ADDRESS) != 0) {
    dump_register_pair(DUMP_REGISTER_FAULT_ADDRESS, evidence.fault_address, &crc);
  }
  if ((evidence.special_valid & DUMP_SPECIAL_SAR) != 0) {
    dump_register_pair(DUMP_REGISTER_XTENSA_SAR, evidence.sar, &crc);
  }

  uint32 gpr_base = architecture == DUMP_CPU_RISCV ? DUMP_REGISTER_RISCV_X0 : DUMP_REGISTER_XTENSA_A0;
  int gpr_count = architecture == DUMP_CPU_RISCV ? 32 : 16;
  for (int i = 0; i < gpr_count; i++) {
    if (i == sp_gpr || (gpr_valid & (1u << i)) == 0) continue;
    dump_register_pair(gpr_base + i, evidence.gpr[i], &crc);
  }
  dump_frame_finish(crc);
}

static uint32 dump_frame_start(
    DumpFrameType type,
    uint8 kind,
    uint16 flags,
    uint32 sequence,
    uint32 region_id,
    uint32 address,
    uint32 length) {
  // The sync word is excluded from the CRC so a receiver can scan for it
  // without buffering a frame.
  dump_write_byte('T');
  dump_write_byte('D');
  dump_write_byte('M');
  dump_write_byte('1');

  uint32 crc = UINT32_MAX;
  dump_write_byte(type, &crc);
  dump_write_byte(kind, &crc);
  dump_write_uint16(flags, &crc);
  dump_write_uint32(sequence, &crc);
  dump_write_uint32(region_id, &crc);
  dump_write_uint32(address, &crc);
  dump_write_uint32(length, &crc);
  return crc;
}

static void feed_watchdog(wdt_hal_context_t* context) {
  if (!wdt_hal_is_enabled(context)) return;
  wdt_hal_write_protect_disable(context);
  wdt_hal_feed(context);
  wdt_hal_write_protect_enable(context);
}

static void feed_dump_watchdogs() {
  // Mirror the IDF panic handler without depending on its private symbol.
  wdt_hal_context_t timer_group_0 = {
    .inst = WDT_MWDT0,
    .mwdt_dev = &TIMERG0,
  };
  feed_watchdog(&timer_group_0);

#if SOC_TIMER_GROUPS >= 2
  wdt_hal_context_t timer_group_1 = {
    .inst = WDT_MWDT1,
    .mwdt_dev = &TIMERG1,
  };
  feed_watchdog(&timer_group_1);
#endif

  wdt_hal_context_t rtc = RWDT_HAL_CONTEXT_DEFAULT();
  feed_watchdog(&rtc);
}

static void dump_frame_finish(uint32 crc) {
  dump_write_uint32(~crc, null);
  feed_dump_watchdogs();
}

static void dump_info_frame(
    const esp_chip_info_t& chip,
    uint32 baud_rate,
    uint32 region_count,
    uint32 psram_physical_size,
    uint32 psram_mapped_size,
    uint32 capture_flags) {
  const uint32 PAYLOAD_WORDS = 11;
  uint32 crc = dump_frame_start(DUMP_FRAME_INFO, 0, 0, 0, 0, 0, PAYLOAD_WORDS * sizeof(uint32));
  dump_write_uint32(DUMP_FORMAT_VERSION, &crc);
  dump_write_uint32(static_cast<uint32>(chip.model), &crc);
  dump_write_uint32(chip.revision, &crc);
  dump_write_uint32(chip.cores, &crc);
  dump_write_uint32(chip.features, &crc);
  dump_write_uint32(CONFIG_ESP_CONSOLE_UART_NUM, &crc);
  dump_write_uint32(baud_rate, &crc);
  dump_write_uint32(region_count, &crc);
  dump_write_uint32(psram_physical_size, &crc);
  dump_write_uint32(psram_mapped_size, &crc);
  dump_write_uint32(capture_flags, &crc);
  dump_frame_finish(crc);
}

static void dump_region_frame(
    uint8 kind,
    uint16 flags,
    uint32 sequence,
    uint32 region_id,
    uword address,
    uword length,
    bool word_only) {
  uint32 crc = dump_frame_start(
      DUMP_FRAME_REGION,
      kind,
      flags,
      sequence,
      region_id,
      static_cast<uint32>(address),
      static_cast<uint32>(length));

  if (word_only) {
    for (uword offset = 0; offset < length; offset += sizeof(uint32)) {
      uint32 word = *reinterpret_cast<volatile const uint32*>(address + offset);
      for (int i = 0; i < 4; i++) dump_write_byte(word >> (8 * i), &crc);
    }
  } else {
    volatile const uint8* bytes = reinterpret_cast<volatile const uint8*>(address);
    for (uword offset = 0; offset < length; offset++) dump_write_byte(bytes[offset], &crc);
  }
  dump_frame_finish(crc);
}

static void dump_region(
    uint8 kind,
    uint32 region_id,
    uword address,
    uword size,
    bool word_only,
    bool truncated,
    uint32* sequence,
    uint32* chunk_count,
    uint32* dumped_bytes) {
  if (word_only) {
    uword aligned_start = Utils::round_up(address, sizeof(uint32));
    uword skipped = aligned_start - address;
    if (skipped >= size) return;
    address = aligned_start;
    uword unaligned_size = size - skipped;
    size = unaligned_size & ~(sizeof(uint32) - 1);
    truncated |= skipped != 0 || size != unaligned_size;
  }
  if (size == 0) return;

  for (uword offset = 0; offset < size; offset += DUMP_CHUNK_SIZE) {
    uword length = Utils::min(DUMP_CHUNK_SIZE, size - offset);
    uint16 flags = DUMP_FRAME_VOLATILE;
    if (offset == 0) flags |= DUMP_FRAME_FIRST;
    if (offset + length == size) flags |= DUMP_FRAME_LAST;
    if (truncated) flags |= DUMP_FRAME_TRUNCATED;
    dump_region_frame(kind, flags, (*sequence)++, region_id, address + offset, length, word_only);
    (*chunk_count)++;
    *dumped_bytes += length;
  }
}

static void dump_end_frame(uint32 sequence, uint32 region_count, uint32 chunk_count, uint32 dumped_bytes) {
  const uint32 PAYLOAD_WORDS = 3;
  uint32 crc = dump_frame_start(DUMP_FRAME_END, 0, 0, sequence, 0, 0, PAYLOAD_WORDS * sizeof(uint32));
  dump_write_uint32(region_count, &crc);
  dump_write_uint32(chunk_count, &crc);
  dump_write_uint32(dumped_bytes, &crc);
  dump_frame_finish(crc);
}

static void wait_for_dump_uart_idle() {
  while (true) {
    uint32 status = READ_PERI_REG(UART_STATUS_REG(CONFIG_ESP_CONSOLE_UART_NUM));
    uint32 fifo_count = (status >> UART_TXFIFO_CNT_S) & UART_TXFIFO_CNT;
    uint32 tx_state = (status >> UART_ST_UTX_OUT_S) & UART_ST_UTX_OUT;
    if (fifo_count == 0 && tx_state == 0) return;
  }
}

}  // namespace

bool device_memory_dump_is_supported() {
#if CONFIG_ESP_CONSOLE_UART
  return true;
#else
  return false;
#endif
}

esp_err_t prepare_device_memory_dump(uint32 baud_rate) {
  wait_for_dump_uart_idle();
  return uart_set_baudrate(
      static_cast<uart_port_t>(CONFIG_ESP_CONSOLE_UART_NUM),
      baud_rate);
}

[[noreturn]] void dump_device_memory(uint32 baud_rate) {
  esp_chip_info_t chip;
  esp_chip_info(&chip);

  uint32 psram_physical_size = 0;
  uint32 psram_mapped_size = 0;
#if CONFIG_SPIRAM
  if (esp_psram_is_initialized()) {
    psram_physical_size = esp_psram_get_size();
    psram_mapped_size = Utils::min(
        static_cast<uword>(psram_physical_size),
        static_cast<uword>(SOC_EXTRAM_DATA_SIZE));
  }
#endif

  uint32 region_count = 0;
  for (size_t i = 0; i < soc_memory_region_count; i++) {
    if (soc_memory_regions[i].size != 0 && !is_psram_region(soc_memory_regions[i])) region_count++;
  }
  if (psram_mapped_size != 0) region_count++;

  uint32 capture_flags =
      DUMP_CAPTURE_CURRENT_STACK_VOLATILE | DUMP_CAPTURE_PERIPHERALS_RUNNING | DUMP_CAPTURE_CPU_EVIDENCE;
#if SOC_CPU_CORES_NUM > 1 && CONFIG_ESP_IPC_ISR_ENABLE
  capture_flags |= DUMP_CAPTURE_PEER_CPU_FROZEN;
#if CONFIG_IDF_TARGET_ARCH_XTENSA
  capture_flags |= DUMP_CAPTURE_PEER_CPU_PARTIAL;
#endif
#endif
  if (psram_physical_size != 0) capture_flags |= DUMP_CAPTURE_PSRAM_PRESENT;
  if (psram_mapped_size < psram_physical_size) capture_flags |= DUMP_CAPTURE_PSRAM_TRUNCATED;

  // The IPC callback captures the registers that remain available at its
  // assembly entry, then makes the peer spin with interrupts masked. The
  // helper also masks this core before waiting for the peer's evidence. This
  // operation is terminal, so the callback never returns.
  prepare_peer_cpu_capture();
  capture_calling_cpu_registers();

  uint32 sequence = 1;
  uint32 chunk_count = 0;
  uint32 dumped_bytes = 0;
  dump_info_frame(
      chip,
      baud_rate,
      region_count,
      psram_physical_size,
      psram_mapped_size,
      capture_flags);

  uint32 calling_core = esp_cpu_get_core_id();
  uint32 architecture = current_cpu_architecture();
  dump_cpu_frame(calling_cpu_evidence, calling_core, architecture, DUMP_CPU_CALLING_SAMPLE, sequence++);
#if SOC_CPU_CORES_NUM > 1 && CONFIG_ESP_IPC_ISR_ENABLE
  uint32 peer_core = calling_core == 0 ? 1 : 0;
  dump_cpu_frame(peer_cpu_evidence, peer_core, architecture, DUMP_CPU_IPC_INTERRUPT, sequence++);
#endif

  uint32 region_id = 0;
  for (size_t i = 0; i < soc_memory_region_count; i++) {
    const soc_memory_region_t& region = soc_memory_regions[i];
    if (region.size == 0 || is_psram_region(region)) continue;
    bool word_only = is_word_only_region(region);
    dump_region(
        region_kind(region),
        region_id++,
        region.start,
        region.size,
        word_only,
        false,
        &sequence,
        &chunk_count,
        &dumped_bytes);
  }

#if CONFIG_SPIRAM
  if (psram_mapped_size != 0) {
    dump_region(
        DUMP_REGION_EXTERNAL,
        region_id++,
        SOC_EXTRAM_DATA_LOW,
        psram_mapped_size,
        false,
        psram_mapped_size < psram_physical_size,
        &sequence,
        &chunk_count,
        &dumped_bytes);
  }
#endif

  dump_end_frame(sequence, region_id, chunk_count, dumped_bytes);
  wait_for_dump_uart_idle();
  esp_restart_noos();
}

}  // namespace toit

#endif  // defined(TOIT_ESP32) && CONFIG_TOIT_DEVICE_MEMORY_DUMP
