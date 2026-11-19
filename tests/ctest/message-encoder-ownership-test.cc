// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Checks that a MessageEncoder frees the buffer it is given, unless
// take_buffer() hands it to a message.
//
// ExternalSystemMessageHandler::send_ and reply_rpc (behind toit_msg_notify
// and toit_msg_request_reply) use the one-argument constructor,
// `MessageEncoder(uint8* buffer)`, and rely on the destructor to free the
// buffer when the SystemMessage can't be allocated.
//
// The test gives the encoder a buffer that is large enough to be mapped by
// malloc, so that mallinfo2 sees it come and go, and destroys the encoder
// without calling take_buffer(), as send_ does when the allocation of the
// message fails. The leak check needs glibc.

#include <stdlib.h>
#ifdef __GLIBC__
#include <malloc.h>
#endif

#include "../../src/top.h"
#include "../../src/messaging.h"

namespace toit {

#ifdef __GLIBC__
static const word LARGE = 1 << 20;

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
    // No take_buffer(), as in send_ when the message can't be allocated.
  }
  if (mapped() != before) FATAL("the encoder did not free its buffer");
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
  free(taken);  // A double free would abort here.
}

}  // namespace toit

int main(int argc, char** argv) {
  toit::test_destructor_frees_buffer();
  toit::test_take_buffer_keeps_buffer();
  return 0;
}
