// Copyright (C) 2026 Toit contributors.

// Thumb instruction semantics for the EC618 base allocator veneers.
// Unsupported opcodes or paths fail the check. The four port entry points
// are tail-call boundaries. LR denotes the original Thumb return address.
#include <stdbool.h>
#include "allocator_abi.inc"

unsigned nondet_uint(void);

static unsigned wide_branch_target(unsigned pc, unsigned first, unsigned second) {
  unsigned s = (first >> 10) & 1;
  unsigned i1 = 1 ^ s ^ ((second >> 13) & 1);
  unsigned i2 = 1 ^ s ^ ((second >> 11) & 1);
  unsigned offset = (s ? 0xff000000u : 0) | (i1 << 23) | (i2 << 22) |
                    ((first & 0x3ff) << 12) | ((second & 0x7ff) << 1);
  return pc + 4 + offset;
}

int main(void) {
  enum { ALIGN, MALLOC, FREE, REALLOC };
  unsigned operation = nondet_uint();
  __CPROVER_assume(operation <= REALLOC);
  unsigned pc = operation == ALIGN ? ADDR_aligned_alloc : operation == MALLOC ? ADDR_malloc :
                operation == FREE ? ADDR_free : ADDR_realloc;
  unsigned arg0 = nondet_uint(), arg1 = nondet_uint(), lr = nondet_uint();
  unsigned r[4] = {arg0, arg1, nondet_uint(), nondet_uint()};
  __CPROVER_assume((lr & 1u) != 0);  // Return to Thumb state.
  unsigned entry_lr = lr, saved_lr = 0;
  bool stacked = false, zero = nondet_uint() != 0, if_equal = false;
  // At most one aligned stack word is used. The caller supplies private
  // writable stack memory disjoint from the executable and _impure_ptr.
  for (;;) {
    if (pc == ADDR_pvPortMemalign || pc == ADDR_pvPortMallocEC ||
        pc == ADDR_vPortFree || pc == ADDR_pvPortReallocEC) {
      __CPROVER_assert(!stacked && lr == entry_lr && !if_equal, "tail call preserves SP and return address");
      __CPROVER_assert(
        (operation == ALIGN && pc == ADDR_pvPortMemalign && r[0] == arg0 && r[1] == arg1) ||
        (operation == MALLOC && pc == ADDR_pvPortMallocEC && r[0] == (arg0 ? arg0 : 4) && r[1] == entry_lr) ||
        (operation == FREE && pc == ADDR_vPortFree && r[0] == arg0 && arg0 != 0) ||
        (operation == REALLOC && pc == ADDR_pvPortReallocEC && r[0] == arg0 && r[1] == arg1 && r[2] == entry_lr),
        "reach the matching board allocator with the original arguments and malloc zero convention");
      return 0;
    }
    unsigned ins = halfword(pc);
    bool in_it_block = if_equal;
    if (if_equal) {
      __CPROVER_assert(ins == 0x2004, "IT EQ controls the immediate move");
      if_equal = false;
      if (!zero) { pc += 2; continue; }
    }
    if ((ins & 0xf800) == 0xf000) {  // B.W, signed PC-relative displacement.
      unsigned second = halfword(pc + 2);
      __CPROVER_assert((second & 0xd000) == 0x9000, "unconditional wide tail branch");
      pc = wide_branch_target(pc, ins, second);
      continue;
    }
    switch (ins) {
      case 0x4b02: {  // LDR r3,[PC,#8]
        unsigned literal = ((pc + 4) & ~3u) + 8;
        r[3] = halfword(literal) | (halfword(literal + 2) << 16);
        break;
      }
      case 0x6818:  // LDR r0,[r3]
        __CPROVER_assert(r[3] == ADDR_impure_ptr, "only read newlib's reentrancy pointer");
        r[0] = nondet_uint();
        break;
      case 0x460a: r[2] = r[1]; break;
      case 0x4601: r[1] = r[0]; break;
      case 0x4608: r[0] = r[1]; break;
      case 0x4611: r[1] = r[2]; break;
      case 0x4671: r[1] = lr; break;
      case 0x4672: r[2] = lr; break;
      case 0xb500:  // PUSH {lr}
        __CPROVER_assert(!stacked, "use at most one stack word");
        stacked = true;
        saved_lr = lr;
        break;
      case 0xf85d:  // LDR.W lr,[sp],#4
        __CPROVER_assert(halfword(pc + 2) == 0xeb04 && stacked, "restore the saved LR and pop one word");
        stacked = false;
        lr = saved_lr;
        pc += 2;
        break;
      case 0x2800: zero = r[0] == 0; break;  // CMP r0,#0
      case 0xbf08: if_equal = true; break;     // IT EQ
      case 0x2004:  // MOVS outside IT, MOV inside IT.
        r[0] = 4;
        if (!in_it_block) zero = false;
        break;
      case 0xb108: if (r[0] == 0) pc += 4; break;  // CBZ r0,PC+6
      case 0x4770:  // BX lr
        __CPROVER_assert(operation == FREE && arg0 == 0 && !stacked && lr == entry_lr,
                         "only free(NULL) can return without calling a port allocator");
        return 0;
      default: __CPROVER_assert(0, "supported allocator veneer instruction"); return 1;
    }
    pc += 2;
  }
}
