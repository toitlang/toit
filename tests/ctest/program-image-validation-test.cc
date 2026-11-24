// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// What the install-time verification accepts in the program heap of an
// untrusted container (verified/cxx/annotated/README.md, "Findings", wave
// 11): the objects that carry a tag or wrap native state.
//
// A program heap comes from the snapshot reader (src/objects.cc
// read_content: the header word as the snapshot gives it, external byte
// arrays as raw bytes in the image) or from a flash image, whose words are
// installed as they are (src/resources/image.cc). Both are checked by the
// format-2 verifier's conversion of the program memory
// (verified/vmverify/src/from_vm.rs) before the program can run; format-1
// programs (-Xuntrusted_format1) by the C++ verifier's heap walk
// (src/verifier.cc walk_heap). The allow-list for an external byte array:
// the raw-bytes tag, a non-null address, the content inside the image; for
// every object: no finalizer flag (on an external byte array it says that
// the array owns its memory, and the message encoder hands such memory to
// the receiver, which frees it); for strings: a terminator inside the
// image.
//
// The test compiles the fixture, reads it into memory as the snapshot
// reader does, edits one field of the program heap at a time and checks
// that every verification path refuses the edited program (and names the
// reason), and that the original is accepted before and after:
//   * V2Verifier::install_verdict, the install of an image flagged untrusted
//     (the flash registry and the image writer call it);
//   * V2Verifier::verify, an untrusted launch of a format-2 snapshot
//     (ProcessGroup::create, the snapshot resource, the programs registry);
//   * Verifier::verify with untrusted rules, for a format-1 program.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

#include <functional>
#include <string>

#include "../../src/top.h"

#include "../../src/compiler/compiler.h"
#include "../../src/flags.h"
#include "../../src/flash_allocation.h"
#include "../../src/flash_registry.h"
#include "../../src/objects_inline.h"
#include "../../src/os.h"
#include "../../src/program.h"
#include "../../src/snapshot.h"
#include "../../src/tags.h"
#include "../../src/verifier.h"
#include "../../src/verifier_v2.h"

namespace toit {

static int failures = 0;

static void expect(bool condition, const char* what, const char* detail, int line) {
  if (condition) return;
  printf("FAIL (line %d): %s [%s]\n", line, what, detail);
  failures++;
}

// Runs `f` with stdout and stderr redirected to a temporary file; returns
// its output.
static std::string capture(const std::function<void()>& f) {
  fflush(stdout);
  fflush(stderr);
  FILE* out = tmpfile();
  if (out == null) FATAL("tmpfile");
  int saved_out = dup(1);
  int saved_err = dup(2);
  dup2(fileno(out), 1);
  dup2(fileno(out), 2);
  f();
  fflush(stdout);
  fflush(stderr);
  dup2(saved_out, 1);
  dup2(saved_err, 2);
  close(saved_out);
  close(saved_err);
  std::string result;
  rewind(out);
  char buffer[512];
  size_t n;
  while ((n = fread(buffer, 1, sizeof(buffer), out)) > 0) result.append(buffer, n);
  fclose(out);
  return result;
}

static SnapshotBundle compile(const char* path, int format, bool untrusted) {
  Flags::bytecode_format = format;
  Flags::untrusted = untrusted;
  auto bundle = SnapshotBundle::invalid();
  {
    compiler::Compiler compiler;
    bundle = compiler.compile(path, null, null, {
      .dep_file = null,
      .dep_format = compiler::Compiler::DepFormat::none,
      .project_root = null,
      .force = false,
      .werror = true,
      .show_package_warnings = false,
      .print_diagnostics_on_stdout = false,
      // As toit.compile does (at -O0 the type propagation does not narrow
      // the receivers the untrusted rules check).
      .optimization_level = DEFAULT_OPTIMIZATION_LEVEL,
    });
  }
  if (!bundle.is_valid()) FATAL("fixture compilation failed");
  return bundle;
}

// The program heap of the fixture: its external byte array (the content of
// the literal BYTES), its external string (TEXT) and an instance.
struct Fixture {
  Program* program;
  word size;
  int format;
  ByteArray* bytes = null;
  String* text = null;
  Instance* instance = null;
  // Format 2: the method table literal (the last literal, format note 21),
  // an external byte array too.
  ByteArray* table = null;
};

// Walks the objects of the program heap (the test has access to its blocks:
// -fno-access-control, tests/ctest/CMakeLists.txt).
static void find_objects(Fixture* f) {
  Program* program = f->program;
  int count = program->literals.length();
  Object* last = count > 0 ? program->literals.at(count - 1) : null;
  if (f->format == 2) {
    if (last == null || !is_byte_array(last) || !ByteArray::cast(last)->has_external_address()) {
      FATAL("no external method table literal");
    }
    f->table = ByteArray::cast(last);
  }
  for (auto block : program->heap_.blocks_) {
    uword p = reinterpret_cast<uword>(block->base());
    uword top = reinterpret_cast<uword>(block->top());
    while (p < top) {
      HeapObject* object = HeapObject::from_address(p);
      if (is_byte_array(object) && ByteArray::cast(object)->has_external_address() && object != last) {
        f->bytes = ByteArray::cast(object);
      } else if (is_string(object) && !String::cast(object)->content_on_heap()) {
        f->text = String::cast(object);
      } else if (is_instance(object) && f->instance == null) {
        f->instance = Instance::cast(object);
      }
      p += object->size(program);
    }
  }
  if (f->bytes == null || f->text == null || f->instance == null) {
    FATAL("fixture objects not found (format %d)", f->format);
  }
  if (f->bytes->external_tag() != RawByteTag) FATAL("unexpected tag");
}

// Every verification path, on the program as it is now. Returns true if
// one accepted it; `output` gets what they printed.
struct Verdicts {
  bool install = false;  // Format 2: the install of an untrusted image.
  bool launch = false;   // Format 2: an untrusted launch of the snapshot.
  bool format1 = false;  // Format 1: the C++ verifier, untrusted rules.
  std::string output;
};

static Verdicts verify(Fixture* f) {
  Verdicts v;
  v.output = capture([&]() {
    if (f->format == 2) {
      uint8 metadata[FlashAllocation::Header::METADATA_SIZE] = { 0 };
      metadata[0] = FlashAllocation::Header::FLAGS_PROGRAM_UNTRUSTED_MASK;
      const char* error = V2Verifier::install_verdict(f->program, f->size, metadata, null, 0, null);
      v.install = error == null &&
          (metadata[0] & FlashAllocation::Header::FLAGS_PROGRAM_VERIFIED_MASK) != 0;
      v.launch = V2Verifier::verify(f->program, false);
    } else {
      VerifierOptions options;
      options.untrusted = true;
      VerifierStats stats;
      v.format1 = Verifier::verify(f->program, &stats, options);
    }
  });
  return v;
}

static bool accepted(const Verdicts& v) { return v.install || v.launch || v.format1; }

// Applies `edit`, expects every path to refuse the program with `reason`
// in its output, and undoes the edit with `undo`.
static void expect_refused(Fixture* f, const char* name, const char* reason,
                           const std::function<void()>& edit, const std::function<void()>& undo) {
  edit();
  Verdicts v = verify(f);
  undo();
  char detail[160];
  snprintf(detail, sizeof(detail), "format %d: %s", f->format, name);
  expect(!accepted(v), "refused", detail, __LINE__);
  bool named = v.output.find(reason) != std::string::npos;
  expect(named, reason, detail, __LINE__);
  if (!named || accepted(v)) printf("  output: %s\n", v.output.c_str());
}

#define WORD_FIELD(object, offset) \
  (*reinterpret_cast<uword*>(reinterpret_cast<uword>(object) - Object::HEAP_TAG + (offset)))

// Format 2: the tables the Program points to lie inside the image
// (V2Verifier::image_layout_error), checked before V2MethodTable::compute
// and the verifier's conversion read them; and the method table literal is
// raw bytes inside the image.
alignas(16) static uint8 outside[64];  // Memory that is not part of the image.

template <typename T>
static void expect_list_refused(Fixture* f, const char* name, T* data_field, const char* reason) {
  T saved = *data_field;
  uword begin = reinterpret_cast<uword>(f->program);
  T values[] = {
    reinterpret_cast<T>(outside),                            // An absolute address.
    reinterpret_cast<T>(begin + f->size),                    // Just past the image.
    reinterpret_cast<T>(begin + f->size - sizeof(word)),     // Its end past the image.
    reinterpret_cast<T>(reinterpret_cast<uword>(saved) + 1), // Unaligned (inside).
  };
  int count = sizeof(*saved) == 1 ? 3 : 4;  // The bytecodes need no alignment.
  for (int i = 0; i < count; i++) {
    char full[96];
    snprintf(full, sizeof(full), "%s at %s", name,
             i == 0 ? "an absolute address" : i == 1 ? "the end of the image" : i == 2 ? "the last word" : "an odd address");
    expect_refused(f, full, reason, [&]() { *data_field = values[i]; }, [&]() { *data_field = saved; });
  }
}

static void test_layout(Fixture* f) {
  Program* program = f->program;
  expect_list_refused(f, "global variables", &program->global_variables.array_, "global variables outside the image");
  expect_list_refused(f, "literals", &program->literals.array_, "literals outside the image");
  expect_list_refused(f, "dispatch table", &program->dispatch_table.data_, "dispatch table outside the image");
  expect_list_refused(f, "class bits", &program->class_bits.data_, "class bits outside the image");
  expect_list_refused(f, "class check ids", &program->class_check_ids.data_, "class check ids outside the image");
  expect_list_refused(f, "interface check offsets", &program->interface_check_offsets.data_,
                      "interface check offsets outside the image");
  expect_list_refused(f, "bytecodes", &program->bytecodes.data_, "bytecodes outside the image");
  // A length that runs past the image.
  word saved_length = program->bytecodes.length_;
  expect_refused(f, "bytecodes longer than the image", "bytecodes outside the image",
                 [&]() { program->bytecodes.length_ = f->size; },
                 [&]() { program->bytecodes.length_ = saved_length; });

  // The method table literal: another tag, no address, an address outside
  // the image, a length past its end. (Its records were checked already;
  // its content was read wherever its address word pointed.)
  ByteArray* table = f->table;
  uword tag_word = WORD_FIELD(table, ByteArray::EXTERNAL_TAG_OFFSET);
  uword address_word = WORD_FIELD(table, ByteArray::EXTERNAL_ADDRESS_OFFSET);
  uword length_word = WORD_FIELD(table, ByteArray::LENGTH_OFFSET);
  for (word tag : { static_cast<word>(MappedFileTag), static_cast<word>(ResourceMinTag + 1), static_cast<word>(-1) }) {
    expect_refused(f, "method table literal with another tag", "method table literal is not raw bytes",
                   [&]() { WORD_FIELD(table, ByteArray::EXTERNAL_TAG_OFFSET) = static_cast<uword>(tag); },
                   [&]() { WORD_FIELD(table, ByteArray::EXTERNAL_TAG_OFFSET) = tag_word; });
  }
  expect_refused(f, "method table literal at address 0", "method table literal outside the image",
                 [&]() { WORD_FIELD(table, ByteArray::EXTERNAL_ADDRESS_OFFSET) = 0; },
                 [&]() { WORD_FIELD(table, ByteArray::EXTERNAL_ADDRESS_OFFSET) = address_word; });
  expect_refused(f, "method table literal at an absolute address", "method table literal outside the image",
                 [&]() { WORD_FIELD(table, ByteArray::EXTERNAL_ADDRESS_OFFSET) = reinterpret_cast<uword>(outside); },
                 [&]() { WORD_FIELD(table, ByteArray::EXTERNAL_ADDRESS_OFFSET) = address_word; });
  // External lengths are stored as -1 - length.
  expect_refused(f, "method table literal longer than the image", "method table literal outside the image",
                 [&]() { WORD_FIELD(table, ByteArray::LENGTH_OFFSET) = static_cast<uword>(-1 - f->size); },
                 [&]() { WORD_FIELD(table, ByteArray::LENGTH_OFFSET) = length_word; });
  // The last literal outside the image.
  Object** literals = program->literals.array_;
  int last = program->literals.length_ - 1;
  Object* saved_last = literals[last];
  expect_refused(f, "last literal outside the image", "last literal outside the image",
                 [&]() { literals[last] = reinterpret_cast<Object*>(reinterpret_cast<uword>(outside) + Object::HEAP_TAG); },
                 [&]() { literals[last] = saved_last; });
}

static void test_program(Fixture* f) {
  Verdicts original = verify(f);
  expect(accepted(original), "the original program is accepted", f->format == 2 ? "format 2" : "format 1", __LINE__);
  if (f->format == 2) {
    expect(original.install && original.launch, "both format-2 paths accept the original", "", __LINE__);
  }
  if (!accepted(original)) printf("  output: %s\n", original.output.c_str());

  bool v2 = f->format == 2;
  const char* tag_reason = v2 ? "another tag than raw bytes" : "external byte array at";
  const char* address_reason = v2 ? "without an address" : "has no address";
  const char* flag_reason = v2 ? "finalizer flag" : "finalizer flag";
  const char* terminator_reason = v2 ? "terminator" : "no terminator";

  ByteArray* bytes = f->bytes;
  uword tag_word = WORD_FIELD(bytes, ByteArray::EXTERNAL_TAG_OFFSET);
  uword address_word = WORD_FIELD(bytes, ByteArray::EXTERNAL_ADDRESS_OFFSET);

  // Other external tags than raw bytes: the null struct, a mapped file, a
  // resource proxy, a resource group, the misc tags, and words no tag has.
  const word tags[] = {
    NullStructTag, MappedFileTag, ResourceMinTag + 1, ResourceMaxTag - 1, ResourceGroupMinTag + 1,
    ResourceGroupMaxTag - 1, FontTag, ImageOutputStreamTag, ChannelTag, ChannelTag + 1, 0x7fffffff, -1,
  };
  for (word tag : tags) {
    char name[64];
    snprintf(name, sizeof(name), "external byte array tag %zd", static_cast<size_t>(tag));
    expect_refused(f, name, tag_reason,
                   [&]() { WORD_FIELD(bytes, ByteArray::EXTERNAL_TAG_OFFSET) = static_cast<uword>(tag); },
                   [&]() { WORD_FIELD(bytes, ByteArray::EXTERNAL_TAG_OFFSET) = tag_word; });
  }

  // Raw bytes without an address but with their length (1100 bytes): the
  // blob decoders would read them from address 0.
  expect_refused(f, "external byte array at address 0", address_reason,
                 [&]() { WORD_FIELD(bytes, ByteArray::EXTERNAL_ADDRESS_OFFSET) = 0; },
                 [&]() { WORD_FIELD(bytes, ByteArray::EXTERNAL_ADDRESS_OFFSET) = address_word; });

  // The finalizer flag on the external byte array (the encoder would
  // transfer the image's memory to a receiver that frees it), the
  // external string, an instance, and the null object.
  HeapObject* flagged[] = { bytes, f->text, f->instance, HeapObject::cast(f->program->null_object()) };
  const char* flagged_names[] = { "external byte array", "external string", "first instance", "null" };
  for (int i = 0; i < 4; i++) {
    HeapObject* object = flagged[i];
    char name[64];
    snprintf(name, sizeof(name), "finalizer flag on the %s", flagged_names[i]);
    expect_refused(f, name, flag_reason,
                   [&]() { object->set_has_active_finalizer(); },
                   [&]() { object->clear_has_active_finalizer(); });
  }

  // An external string without its terminator.
  String* text = f->text;
  uint8* end = const_cast<uint8*>(String::Bytes(text).address()) + text->length();
  expect_refused(f, "external string without terminator", terminator_reason,
                 [&]() { *end = 'x'; },
                 [&]() { *end = '\0'; });

  if (v2) test_layout(f);

  // The edits were undone: the original is accepted again.
  Verdicts after = verify(f);
  expect(accepted(after), "the original program is accepted after the edits",
         f->format == 2 ? "format 2" : "format 1", __LINE__);
}

static void run(const char* path, int format) {
  auto bundle = compile(path, format, format == 2);
  {
    AllowThrowingNew allow_throwing_new;
    auto image = bundle.snapshot().read_image(null);
    if (!image.is_valid()) FATAL("reading the fixture failed");
    // The program image is read-only once read; the test edits it.
    long page = sysconf(_SC_PAGESIZE);
    uword size = Utils::round_up(static_cast<uword>(image.byte_size()), static_cast<uword>(page));
    if (mprotect(image.address(), size, PROT_READ | PROT_WRITE) != 0) FATAL("mprotect");
    Fixture f;
    f.program = image.program();
    f.size = image.byte_size();
    f.format = format;
    find_objects(&f);
    test_program(&f);
    image.release();
  }
  free(bundle.buffer());
}

}  // namespace toit

int main(int argc, char** argv) {
  using namespace toit;
  if (argc != 2) FATAL("expected fixture source");
  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();
  run(argv[1], 2);
  run(argv[1], 1);
  ObjectMemory::tear_down();
  OS::tear_down();
  FlashRegistry::tear_down();
  if (failures != 0) {
    printf("%d failures\n", failures);
    return 1;
  }
  printf("the install-time verification refuses every disallowed program-heap value.\n");
  return 0;
}
