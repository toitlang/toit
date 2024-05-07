// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <stdio.h>
#include <stdlib.h>

#include "../../include/toit/toit.h"

typedef struct {
  toit_message_handler_context_t* handler_context;
} user_context_t;

static toit_err_t on_created(void* user_context, toit_message_handler_context_t* handler_context) {
  printf("created external message handler\n");
  user_context_t* context = (user_context_t*)(user_context);
  context->handler_context = handler_context;
  return TOIT_ERR_SUCCESS;
}

static toit_err_t on_message(void* user_context, int sender, int type, void* data, int length) {
  printf("received message in C\n");
  toit_message_handler_context_t* handler_context = ((user_context_t*)(user_context))->handler_context;
  if (toit_send_message(handler_context, sender, type + 1, data, length, true) != TOIT_ERR_SUCCESS) {
    printf("unable to send\n");
  }
  if (length == 2 && ((char*)data)[0] == 99 && ((char*)data)[1] == 99) {
    toit_remove_external_message_handler(handler_context);
  }
  return TOIT_ERR_SUCCESS;
}

static toit_err_t on_rpc_request(void* user_context, int sender, toit_rpc_handle_t handle, void* data, int length) {
  printf("received rpc request in C\n");
  if (length == 2 && ((char*)data)[0] == 99 && ((char*)data)[1] == 99) {
    toit_fail_rpc_request(handle, "EXTERNAL-ERROR");
  } else {
    if (toit_reply_rpc_request(handle, data, length, true) != TOIT_ERR_SUCCESS) {
      printf("unable to reply\n");
    }
  }
  return TOIT_ERR_SUCCESS;
}

static toit_err_t on_removed(void* user_context) {
  printf("freeing user context\n");
  free(user_context);
  return TOIT_ERR_SUCCESS;
}

static void __attribute__((constructor)) init() {
  printf("registering external handler\n");
  user_context_t* user_context = (user_context_t*)malloc(sizeof(user_context_t));
  toit_message_handler_cbs_t cbs = {
    .on_created = &on_created,
    .on_message = &on_message,
    .on_rpc_request = &on_rpc_request,
    .on_removed = &on_removed,
  };
  toit_add_external_message_handler("toit.io/external-test", user_context, cbs);
}
