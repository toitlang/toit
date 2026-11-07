// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "recovery-stdio.h"
#include "recovery-stdio-stubs.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static uint64_t now, release_at, disconnect_at;
static unsigned used, feeds;
static char output[256];
static unsigned length;
enum { CAPACITY = 4 };

uint64_t time_us_64(void) { return now; }
void sleep_us(uint64_t delay) { assert(delay <= 1000); now += delay; }
void watchdog_update(void) { feeds++; }
bool stdio_usb_connected(void) { return now < disconnect_at; }
uint32_t tud_cdc_write_available(void) {
  if (now >= release_at) used = 0;
  return CAPACITY - used;
}
int stdio_put_string(const char* bytes, int count, bool newline, bool cr_translation) {
  assert(!newline && !cr_translation);
  assert(count > 0 && (unsigned)count <= CAPACITY - used);
  assert(length + (unsigned)count < sizeof(output));
  memcpy(output + length, bytes, (unsigned)count);
  length += (unsigned)count;
  used += (unsigned)count;
  return count;
}
static void reset(void) {
  now = release_at = 0;
  disconnect_at = UINT64_MAX;
  used = feeds = length = 0;
  memset(output, 0, sizeof(output));
}

int main(void) {
  reset();
  assert(recovery_reply("OK block %u\n", 4096));
  assert(!strcmp(output, "OK block 4096\n"));

  reset();
  release_at = 1500000;
  assert(recovery_reply("READY block\n"));
  assert(!strcmp(output, "READY block\n"));
  assert(now == release_at && feeds >= 1500);

  reset();
  release_at = UINT64_MAX;
  assert(!recovery_reply("READY block\n"));
  assert(now == 5000000 && feeds >= 5000);
  assert(length == CAPACITY && !memcmp(output, "READ", CAPACITY));

  reset();
  release_at = UINT64_MAX;
  disconnect_at = 2000;
  assert(!recovery_reply("OK begin\n"));
  assert(now == disconnect_at && length == CAPACITY);

  reset();
  disconnect_at = 0;
  assert(!recovery_reply("OK\n"));
  assert(length == 0 && now == 0);

  reset();
  char text[129];
  memset(text, 'x', sizeof(text));
  text[127] = 0;
  assert(recovery_reply("%s", text));
  assert(length == 127);
  reset();
  text[127] = 'x';
  text[128] = 0;
  assert(!recovery_reply("%s", text));
  assert(length == 0);
  puts("PASS: recovery replies preserve bytes under backpressure, bound waits, feed watchdog and reject overflow");
}
