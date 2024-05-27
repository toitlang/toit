// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include "../../include/toit/toit.h"

static toit_err_t on_rpc_request(void* user_data, int sender, int function, toit_msg_request_handle_t handle, uint8_t* data, int length) {
  if (toit_msg_request_reply(handle, data, length + 1, true) != TOIT_OK) {
    printf("unable to reply\n");
  }
  return TOIT_OK;
}

static void __attribute__((constructor)) init() {
  printf("registering external handler 1\n");
  toit_msg_cbs_t cbs = TOIT_MSG_EMPTY_CBS();
  cbs.on_rpc_request = on_rpc_request;
  toit_msg_add_handler("toit.io/external-test", NULL, cbs);
}
