// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// A verdict of the format-2 verifier is bound to the policy it was computed
// for (red-team round 4, line A, T2; docs/sandbox-guarantee.md clause 6).
// The verifier checks every PRIMITIVE against the primitive table of the
// policy it verifies for (PrimitivePolicy::verifier_arities), and the
// verified run loop runs a primitive only where the process' own policy's
// table allows it; so a verdict computed for the trusted policy must never
// count for an untrusted process, which would then run on the verified loop
// with a table its verdict did not check. V2MethodTable::runs_verified is
// that check (exact match: 1 = untrusted, 2 = trusted).
//
// The fixture calls spawn, which the trusted policy allows and the untrusted
// one denies. Its table, verified for the trusted policy, must not run
// verified in an untrusted process, and verified for the untrusted policy,
// not in a trusted one; an unverified table runs verified in neither. Both
// verdicts accept the program (the untrusted one because a denied primitive
// is accepted and completed with PERMISSION_DENIED by the core).

#include <stdio.h>

#include "../../src/top.h"

#include "../../src/compiler/compiler.h"
#include "../../src/flags.h"
#include "../../src/flash_registry.h"
#include "../../src/heap.h"
#include "../../src/interpreter_v2.h"
#include "../../src/os.h"
#include "../../src/primitive_policy.h"
#include "../../src/program.h"
#include "../../src/snapshot.h"
#include "../../src/verifier_v2.h"
#include "../../src/vm.h"

namespace toit {

static int failures = 0;

#define EXPECT(condition) do { \
  if (!(condition)) { printf("FAIL (line %d): %s\n", __LINE__, #condition); failures++; } \
} while (false)

static void test_verdicts(Program* program) {
  EXPECT(program->is_format2());
  V2MethodTable* none = V2MethodTable::compute(program);
  V2MethodTable* trusted = V2MethodTable::compute(program);
  V2MethodTable* untrusted = V2MethodTable::compute(program);
  if (none == null || trusted == null || untrusted == null) FATAL("no method table");

  EXPECT(!none->runs_verified(true));
  EXPECT(!none->runs_verified(false));

  EXPECT(V2Verifier::verify(program, trusted, true));
  EXPECT(trusted->runs_verified(false));      // A trusted process.
  EXPECT(!trusted->runs_verified(true));      // Never an untrusted one.

  EXPECT(V2Verifier::verify(program, untrusted, false));
  EXPECT(untrusted->runs_verified(true));     // An untrusted process.
  EXPECT(!untrusted->runs_verified(false));   // Never a trusted one.

  // The two policies' verifier tables differ at spawn: the arity for the
  // trusted policy, denied for the untrusted one.
  const uint8* t = PrimitivePolicy::verifier_arities_of(PrimitivePolicy::TRUSTED);
  const uint8* u = PrimitivePolicy::verifier_arities_of(PrimitivePolicy::UNTRUSTED);
  word length = PrimitivePolicy::verifier_arities_length();
  bool differ = false;
  for (word i = 0; i < length; i++) if (t[i] != u[i]) differ = true;
  EXPECT(differ);

  delete none;
  delete trusted;
  delete untrusted;
}

}  // namespace toit

int main(int argc, char** argv) {
  using namespace toit;
  if (argc != 2) FATAL("expected fixture source");
  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();
  // As `toit compile --untrusted`: checked opcodes only, so that both
  // rule sets can accept the program.
  Flags::untrusted = true;
  Flags::v2_unchecked = false;
  auto bundle = SnapshotBundle::invalid();
  {
    compiler::Compiler compiler;
    bundle = compiler.compile(argv[1], null, null, {
      .dep_file = null,
      .dep_format = compiler::Compiler::DepFormat::none,
      .project_root = null,
      .force = false,
      .werror = true,
      .show_package_warnings = false,
      .print_diagnostics_on_stdout = false,
      .optimization_level = 1,  // As toit compile's default.
      .verbosity = 0,
    });
  }
  if (!bundle.is_valid()) FATAL("fixture compilation failed");
  {
    VM vm;
    auto image = bundle.snapshot().read_image(null);
    test_verdicts(image.program());
    image.release();
  }
  free(bundle.buffer());
  ObjectMemory::tear_down();
  OS::tear_down();
  FlashRegistry::tear_down();
  if (failures != 0) {
    printf("%d failures\n", failures);
    return 1;
  }
  printf("Verdicts count only for the policy they were computed for.\n");
  return 0;
}
