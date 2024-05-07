// Copyright (C) 2024 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#pragma once

#ifdef __cplusplus
extern "C" {
#else
#include <stdbool.h>
#endif

/*
 * C interface for Toit's external API.
 */

typedef enum {
  // The operation succeeded.
  TOIT_ERR_SUCCESS,
  // The operation encountered an out-of-memory error.
  TOIT_ERR_OOM,
  // An error, for when the receiver of a system message didn't exist.
  TOIT_ERR_NO_SUCH_RECEIVER,
  // The corresponding resource was not found.
  TOIT_ERR_NOT_FOUND,
  // The given type is reserved.
  TOIT_ERR_RESERVED_TYPE,
  // An unknown error.
  TOIT_ERR_ERROR,
} toit_err_t;

struct toit_message_handler_context_t;
typedef struct toit_message_handler_context_t toit_message_handler_context_t;

typedef struct {
  int sender;
  int request_handle;
  toit_message_handler_context_t* handler_context;
} toit_rpc_handle_t;

typedef toit_err_t (*on_created_cb_t)(void* user_context, toit_message_handler_context_t* handler_context);
typedef toit_err_t (*on_message_cb_t)(void* user_context, int sender, int type, void* data, int length);
typedef toit_err_t (*on_rpc_request_cb_t)(void* user_context,
                                          int sender,
                                          toit_rpc_handle_t rpc_handle,
                                          void* data, int length);
typedef toit_err_t (*on_removed_cb_t)(void* user_context);

typedef struct toit_message_handler_cbs_t {
  on_created_cb_t on_created;
  on_message_cb_t on_message;
  on_rpc_request_cb_t on_rpc_request;
  on_removed_cb_t on_removed;
} toit_message_handler_cbs_t;

toit_err_t toit_add_external_message_handler(const char* id,
                                             void* user_context,
                                             toit_message_handler_cbs_t cbs);

toit_err_t toit_remove_external_message_handler(toit_message_handler_context_t* handler_context);

toit_err_t toit_send_message(toit_message_handler_context_t* handler_context,
                             int target_pid, int type,
                             void* data, int length,
                             bool free_on_failure);

toit_err_t toit_fail_rpc_request(toit_rpc_handle_t handle, const char* error);
toit_err_t toit_reply_rpc_request(toit_rpc_handle_t handle, void* data, int length, bool free_on_failure);

toit_err_t toit_gc(toit_message_handler_context_t* handler_context, bool try_hard);

#ifdef __cplusplus
}
#endif
