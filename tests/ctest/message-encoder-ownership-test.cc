// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The ownership of a message encoder's buffer on a failure path of the
// sender side (found by the VeriFast proof of the sender side,
// verified/cxx/annotated/messaging).
//
// MessageEncoder takes ownership of the buffer it is given (its class
// comment): the destructor frees it unless take_buffer() gave it to a
// message. ExternalSystemMessageHandler::send and reply_rpc (the C API's
// toit_msg_notify and toit_msg_request_reply) rely on that: when the
// SystemMessage can't be allocated, send_ returns "since the destructor of
// the encoder already takes care of" the buffer. But the one-argument
// constructor they use, `MessageEncoder(uint8* buffer)`, left
// take_ownership_of_buffer_ false: every such failure leaked the encoded
// buffer.
//
// The test gives the encoder a buffer large enough to be mapped by malloc
// (mallinfo2 sees it come and go) and destroys the encoder without
// take_buffer, as send_ does when the message allocation fails. glibc only.

#include <stdlib.h>
#ifdef __GLIBC__
#include <malloc.h>
#endif

#include "../../src/top.h"
#include "../../src/messaging.h"

namespace toit {

static const word LARGE = 1 << 20;

#ifdef __GLIBC__
static size_t mapped() {
  return mallinfo2().hblkhd;
}
#endif

static void test_destructor_frees_buffer() {
#ifdef __GLIBC__
  size_t before = mapped();
  { uint8* buffer = unvoid_cast<uint8*>(malloc(LARGE));
    if (buffer == null) FATAL("malloc failed");
    if (mapped() < before + LARGE) FATAL("the buffer is not mapped: the test can't see it");
    MessageEncoder encoder(buffer);  // Takes over buffer.
    // The SystemMessage allocation fails here in send_: no take_buffer.
  }
  if (mapped() != before) FATAL("the encoder did not free its buffer (leak)");
#endif
}

static void test_take_buffer_keeps_buffer() {
  uint8* buffer = unvoid_cast<uint8*>(malloc(16));
  if (buffer == null) FATAL("malloc failed");
  uint8* taken;
  { MessageEncoder encoder(buffer);
    taken = encoder.take_buffer();
  }
  if (taken != buffer) FATAL("take_buffer returned another buffer");
  free(taken);  // Freed once: a double free would abort here.
}

}  // namespace toit

int main(int argc, char** argv) {
  toit::test_destructor_frees_buffer();
  toit::test_take_buffer_keeps_buffer();
  return 0;
}
