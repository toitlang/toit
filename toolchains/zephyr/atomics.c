// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include <zephyr/kernel.h>
#include <zephyr/sys/barrier.h>

BUILD_ASSERT(!IS_ENABLED(CONFIG_SMP), "64-bit atomic helpers require a single core");
#include <stdint.h>

// Cortex-M33 has no doubleword exclusive instruction. This port uses one core
// and does not share these counters with the network processor. Disabling
// interrupts makes each operation indivisible; barriers cover every order.
uint64_t __atomic_load_8(const volatile void* pointer, int order) {
  (void)order;
  unsigned int key = irq_lock();
  barrier_dmem_fence_full();
  uint64_t result = *(const volatile uint64_t*)pointer;
  barrier_dmem_fence_full();
  irq_unlock(key);
  return result;
}
uint64_t __atomic_fetch_add_8(volatile void* pointer, uint64_t value, int order) {
  (void)order;
  unsigned int key = irq_lock();
  barrier_dmem_fence_full();
  uint64_t previous = *(volatile uint64_t*)pointer;
  *(volatile uint64_t*)pointer = previous + value;
  barrier_dmem_fence_full();
  irq_unlock(key);
  return previous;
}
uint64_t __atomic_fetch_sub_8(volatile void* pointer, uint64_t value, int order) {
  return __atomic_fetch_add_8(pointer, -value, order);
}
