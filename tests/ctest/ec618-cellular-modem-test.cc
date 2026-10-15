// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in tests/LICENSE.

#include <initializer_list>
#include <stdio.h>
#include <stdlib.h>

#include "../../src/resources/cellular_modem_ec618.h"

using toit::CellularModemState;

#define CHECK(condition) do { \
  if (!(condition)) { \
    fprintf(stderr, "line %d: %s\n", __LINE__, #condition); \
    exit(1); \
  } \
} while (0)

struct Command { uint8_t mode; int32_t result; };
static struct {
  Command entries[2];
  unsigned count = 0;
  unsigned next = 0;

  void operator=(std::initializer_list<Command> script) {
    CHECK(empty());
    CHECK(script.size() <= 2);
    count = 0;
    next = 0;
    for (auto command : script) entries[count++] = command;
  }

  bool empty() const { return next == count; }
} commands;

static int32_t set_function(uint8_t mode) {
  CHECK(!commands.empty());
  auto command = commands.entries[commands.next++];
  CHECK(mode == command.mode);
  return command.result;
}

static void expect_connected(CellularModemState& modem, const void* owner) {
  auto result = modem.activate(owner, set_function);
  CHECK(!result.already_in_use);
  CHECK(result.error == 0);
  CHECK(commands.empty());
}

int main() {
  int first, second;
  // Numeric CMS errors must survive, including unfamiliar future values.
  for (int32_t error : {-1, -3, -7, -8, 77}) {
    CellularModemState modem;
    commands = {{0, error}};
    CHECK(modem.initialize(set_function) == error);
    CHECK(commands.empty());
    // A failed initialization must not become a permanently cached success.
    commands = {{0, 0}, {1, 0}};
    expect_connected(modem, &first);

    // A second group or failed duplicate resource must not disable the owner.
    CHECK(modem.initialize(set_function) == 0);
    auto duplicate = modem.activate(&first, set_function);
    CHECK(duplicate.already_in_use);
    duplicate = modem.activate(&second, set_function);
    CHECK(duplicate.already_in_use);
    CHECK(modem.deactivate(&second, set_function) == 0);

    // Teardown failure releases the resource but requires CFUN=0 recovery.
    commands = {{0, error}};
    CHECK(modem.deactivate(&first, set_function) == error);
    CHECK(commands.empty());
    CHECK(modem.deactivate(&first, set_function) == 0);
    commands = {{0, error}};
    auto retry = modem.activate(&second, set_function);
    CHECK(!retry.already_in_use);
    CHECK(retry.error == error);
    CHECK(commands.empty());  // Do not enable after failed recovery.
    commands = {{0, 0}, {1, 0}};
    expect_connected(modem, &second);
    commands = {{0, 0}};
    CHECK(modem.deactivate(&second, set_function) == 0);
    CHECK(commands.empty());

    // An enable timeout may have reached the modem. Reset before retrying;
    // there must be no dangling ownership blocking the next resource.
    commands = {{1, error}, {0, error}};
    auto failed = modem.activate(&first, set_function);
    CHECK(!failed.already_in_use);
    CHECK(failed.error == error);
    CHECK(commands.empty());
    CHECK(modem.deactivate(&first, set_function) == 0);
    commands = {{0, 0}, {1, 0}};
    expect_connected(modem, &second);
    commands = {{0, 0}};
    CHECK(modem.deactivate(&second, set_function) == 0);
    CHECK(commands.empty());

    // Successful cleanup after a failed enable avoids leaving the radio on
    // with no owner and allows a subsequent caller to retry directly.
    commands = {{1, error}, {0, 0}};
    failed = modem.activate(&first, set_function);
    CHECK(!failed.already_in_use);
    CHECK(failed.error == error);
    CHECK(commands.empty());
    commands = {{1, 0}};
    expect_connected(modem, &second);
    commands = {{0, 0}};
    CHECK(modem.deactivate(&second, set_function) == 0);
    CHECK(commands.empty());
  }
  puts("PASS cellular modem: command errors, ownership, failed teardown, recovery and reuse");
}
