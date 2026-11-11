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

// Start-up code of the EC618 VM harness on QEMU's mps2-an385: the vector
// table (the EC618 base's prebuilt FreeRTOS handles SVC, PendSV and
// SysTick), the reset handler, and newlib's system calls through ARM
// semihosting (QEMU -semihosting-config enable=on,target=native).

#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>

extern uint32_t __data_load[], __data_start[], __data_end[];
extern uint32_t __bss_start[], __bss_end[];
extern uint32_t __main_stack_top[];
extern void (*__init_array_start[])(void);
extern void (*__init_array_end[])(void);

int main(void);
void SVC_Handler(void);
void PendSV_Handler(void);
void SysTick_Handler(void);

// --- Semihosting. -------------------------------------------------------------

static int semihost(int op, const void* arg) {
  register int r0 __asm__("r0") = op;
  register const void* r1 __asm__("r1") = arg;
  __asm__ volatile("bkpt 0xab" : "+r"(r0) : "r"(r1) : "memory");
  return r0;
}

#define SYS_OPEN 0x01
#define SYS_WRITE 0x05
#define SYS_WRITE0 0x04
#define SYS_EXIT_EXTENDED 0x20
#define ADP_STOPPED_APPLICATION_EXIT 0x20026

static int console = -1;

static void open_console(void) {
  if (console >= 0) return;
  uint32_t args[3] = { (uint32_t)":tt", 4 /* "w" */, 3 };
  console = semihost(SYS_OPEN, args);
}

void harness_write(const char* data, int length) {
  open_console();
  uint32_t args[3] = { (uint32_t)console, (uint32_t)data, (uint32_t)length };
  semihost(SYS_WRITE, args);
}

void harness_puts(const char* s) {
  harness_write(s, strlen(s));
}

__attribute__((noreturn)) void harness_exit(int code) {
  uint32_t args[2] = { ADP_STOPPED_APPLICATION_EXIT, (uint32_t)code };
  semihost(SYS_EXIT_EXTENDED, args);
  for (;;) {}
}

static void put_hex(uint32_t value) {
  char buffer[11] = "0x";
  for (int i = 0; i < 8; i++) buffer[2 + i] = "0123456789abcdef"[(value >> (28 - 4 * i)) & 0xf];
  buffer[10] = 0;
  harness_puts(buffer);
}

// --- Faults. --------------------------------------------------------------------

__attribute__((used)) void harness_fault(uint32_t* frame, uint32_t ipsr) {
  harness_puts("\n[harness] FAULT: exception ");
  put_hex(ipsr);
  harness_puts(" pc=");
  put_hex(frame[6]);
  harness_puts(" lr=");
  put_hex(frame[5]);
  harness_puts(" cfsr=");
  put_hex(*(volatile uint32_t*)0xE000ED28);
  harness_puts(" bfar=");
  put_hex(*(volatile uint32_t*)0xE000ED38);
  harness_puts(" mmfar=");
  put_hex(*(volatile uint32_t*)0xE000ED34);
  harness_puts("\n");
  harness_exit(70);
}

__attribute__((naked)) static void Fault_Handler(void) {
  __asm__ volatile(
      "tst lr, #4\n"
      "ite eq\n"
      "mrseq r0, msp\n"
      "mrsne r0, psp\n"
      "mrs r1, ipsr\n"
      "b harness_fault\n");
}

// --- Reset. ---------------------------------------------------------------------

__attribute__((noreturn)) void Reset_Handler(void) {
  // CCR.STKALIGN: 8-byte aligned exception frames (the AAPCS).
  *(volatile uint32_t*)0xE000ED14 |= 1u << 9;
  for (uint32_t* s = __data_load, *d = __data_start; d < __data_end;) *d++ = *s++;
  for (uint32_t* d = __bss_start; d < __bss_end;) *d++ = 0;
  for (void (**f)(void) = __init_array_start; f < __init_array_end; f++) (*f)();
  harness_exit(main());
}

__attribute__((section(".vectors"), used))
void (* const harness_vectors[16 + 32])(void) = {
  (void (*)(void))__main_stack_top,
  Reset_Handler,
  Fault_Handler,  // NMI.
  Fault_Handler,  // HardFault.
  Fault_Handler,  // MemManage.
  Fault_Handler,  // BusFault.
  Fault_Handler,  // UsageFault.
  0, 0, 0, 0,
  SVC_Handler,
  Fault_Handler,  // DebugMon.
  0,
  PendSV_Handler,
  SysTick_Handler,
  // The CMSDK peripherals' interrupts: none enabled.
  Fault_Handler, Fault_Handler, Fault_Handler, Fault_Handler,
  Fault_Handler, Fault_Handler, Fault_Handler, Fault_Handler,
  Fault_Handler, Fault_Handler, Fault_Handler, Fault_Handler,
  Fault_Handler, Fault_Handler, Fault_Handler, Fault_Handler,
  Fault_Handler, Fault_Handler, Fault_Handler, Fault_Handler,
  Fault_Handler, Fault_Handler, Fault_Handler, Fault_Handler,
  Fault_Handler, Fault_Handler, Fault_Handler, Fault_Handler,
  Fault_Handler, Fault_Handler, Fault_Handler, Fault_Handler,
};

// --- newlib system calls. -------------------------------------------------------

int _write(int fd, const char* data, int length) {
  (void)fd;
  harness_write(data, length);
  return length;
}

int _read(int fd, char* data, int length) {
  (void)fd; (void)data; (void)length;
  return 0;
}

int _close(int fd) { (void)fd; return -1; }
int _lseek(int fd, int offset, int whence) { (void)fd; (void)offset; (void)whence; return 0; }
int _isatty(int fd) { (void)fd; return 1; }
int _getpid(void) { return 1; }
int _kill(int pid, int signal) { (void)pid; (void)signal; errno = EINVAL; return -1; }
void _exit(int code) { harness_exit(code); }

int _fstat(int fd, struct stat* st) {
  (void)fd;
  memset(st, 0, sizeof(*st));
  st->st_mode = S_IFCHR;
  return 0;
}

int _gettimeofday(struct timeval* tv, void* tz) {
  (void)tz;
  if (tv != 0) { tv->tv_sec = 0; tv->tv_usec = 0; }
  return 0;
}

void* _sbrk(int increment) {
  // Every allocation goes to the EC618 base's cmpctmalloc (heap_7.c, with
  // newlib's _malloc_r and friends wrapped).
  (void)increment;
  errno = ENOMEM;
  return (void*)-1;
}
