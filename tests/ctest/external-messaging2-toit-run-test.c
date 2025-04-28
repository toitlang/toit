// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include "../../include/toit/toit.h"

typedef struct {
  int id;
  toit_msg_context_t* msg_context;
} test_service_t;

static toit_err_t on_created(void* user_data, toit_msg_context_t* context) {
  test_service_t* test_service = (test_service_t*)user_data;
  printf("created external message handler %d\n", test_service->id);
  test_service->msg_context = context;
  return TOIT_OK;
}

static toit_err_t on_message(void* user_data, int sender, uint8_t* data, int length) {
  test_service_t* test_service = (test_service_t*)user_data;
  printf("received message in C %d\n", test_service->id);
  toit_msg_context_t* context = ((test_service_t*)(user_data))->msg_context;
  if (toit_msg_notify(context, sender, data, length, true) != TOIT_OK) {
    printf("unable to send\n");
  }
  if (length == 2 && ((char*)data)[0] == 99 && ((char*)data)[1] == 99) {
    toit_msg_remove_handler(context);
  }
  return TOIT_OK;
}

static toit_err_t on_rpc_request(void* user_data, int sender, int function, toit_msg_request_handle_t handle, uint8_t* data, int length) {
  test_service_t* test_service = (test_service_t*)user_data;
  printf("received rpc request in C %d\n", test_service->id);
  if (length == 2 && ((char*)data)[0] == 99 && ((char*)data)[1] == 99) {
    toit_msg_request_fail(handle, "EXTERNAL_ERROR");
  } else {
    if (length == 1 && data[0] == 0xFF) {
      // If the message is #[0xFF], respond with our id.
      data[0] = test_service->id;
    } else if (length == 1 && data[0] == 0xFE) {
      // If the message is #[0xFE], do a GC and reply with #[0].
      toit_gc();
      data[0] = 0;
    }
    if (toit_msg_request_reply(handle, data, length, true) != TOIT_OK) {
      printf("unable to reply\n");
    }
  }
  return TOIT_OK;
}

static toit_err_t on_removed(void* user_data) {
  test_service_t* test_service = (test_service_t*)user_data;
  printf("freeing user data %d\n", test_service->id);
  free(user_data);
  return TOIT_OK;
}

static void __attribute__((constructor)) init() {
  printf("registering external handler 0\n");
  test_service_t* test_service = (test_service_t*)malloc(sizeof(test_service_t));
  test_service->id = 0;
  test_service->msg_context = NULL;
  toit_msg_cbs_t cbs = {
    .on_created = on_created,
    .on_message = on_message,
    .on_rpc_request = on_rpc_request,
    .on_removed = on_removed,
  };
  toit_msg_add_handler("toit.io/external-test0", test_service, cbs);
}

static void __attribute__((constructor)) init2() {
  printf("registering external handler 1\n");
  test_service_t* test_service = (test_service_t*)malloc(sizeof(test_service_t));
  test_service->id = 1;
  test_service->msg_context = NULL;
  toit_msg_cbs_t cbs = TOIT_MSG_EMPTY_CBS();
  cbs.on_created = on_created;
  cbs.on_message = on_message;
  cbs.on_rpc_request = on_rpc_request;
  cbs.on_removed = on_removed;
  toit_msg_add_handler("toit.io/external-test1", test_service, cbs);
}
