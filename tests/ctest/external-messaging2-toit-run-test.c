// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <stdio.h>
#include <stdlib.h>

#include "../../include/toit/toit.h"

typedef struct {
  toit_msg_context_t* handler_context;
} test_handler_t;

static toit_err_t on_created(void* user_data, toit_msg_context_t* context) {
  printf("created external message handler\n");
  test_handler_t* test_handler = (test_handler_t*)(user_data);
  test_handler->handler_context = context;
  return TOIT_ERR_SUCCESS;
}

static toit_err_t on_message(void* user_data, int sender, void* data, int length) {
  printf("received message in C\n");
  toit_msg_context_t* handler_context = ((test_handler_t*)(user_data))->handler_context;
  if (toit_msg_notify(handler_context, sender, data, length, true) != TOIT_ERR_SUCCESS) {
    printf("unable to send\n");
  }
  if (length == 2 && ((char*)data)[0] == 99 && ((char*)data)[1] == 99) {
    toit_msg_remove_handler(handler_context);
  }
  return TOIT_ERR_SUCCESS;
}

static toit_err_t on_rpc_request(void* user_data, int sender, int function, toit_msg_request_handle_t handle, void* data, int length) {
  printf("received rpc request in C\n");
  if (length == 2 && ((char*)data)[0] == 99 && ((char*)data)[1] == 99) {
    toit_msg_request_fail(handle, "EXTERNAL-ERROR");
  } else {
    if (toit_msg_request_reply(handle, data, length, true) != TOIT_ERR_SUCCESS) {
      printf("unable to reply\n");
    }
  }
  return TOIT_ERR_SUCCESS;
}

static toit_err_t on_removed(void* user_data) {
  printf("freeing user context\n");
  free(user_data);
  return TOIT_ERR_SUCCESS;
}

static void __attribute__((constructor)) init() {
  printf("registering external handler\n");
  test_handler_t* test_handler = (test_handler_t*)malloc(sizeof(test_handler_t));
  toit_msg_cbs_t cbs = {
    .on_created = &on_created,
    .on_message = &on_message,
    .on_rpc_request = &on_rpc_request,
    .on_removed = &on_removed,
  };
  toit_msg_add_handler("toit.io/external-test", test_handler, cbs);
}
