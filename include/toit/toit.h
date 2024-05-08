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
  TOIT_ERR_SUCCESS = 0,
  // The operation encountered an out-of-memory error.
  TOIT_ERR_OOM,
  // An error, for when the receiver of a system message didn't exist.
  TOIT_ERR_NO_SUCH_RECEIVER,
  // The corresponding resource was not found.
  TOIT_ERR_NOT_FOUND,
  // An unknown error.
  TOIT_ERR_ERROR,
} toit_err_t;

const int TOIT_MSG_RESERVED_TYPES = 64;

struct toit_msg_context_t;
typedef struct toit_msg_context_t toit_msg_context_t;

typedef struct {
  int sender;
  int request_handle;
  toit_msg_context_t* context;
} toit_msg_request_handle_t;

typedef toit_err_t (*toit_msg_on_created_cb_t)(void* user_data, toit_msg_context_t* context);
typedef toit_err_t (*toit_msg_on_message_cb_t)(void* user_data, int sender, void* data, int length);
typedef toit_err_t (*toit_msg_on_request_cb_t)(void* user_data,
                                               int sender,
                                               int function,
                                               toit_msg_request_handle_t rpc_handle,
                                               void* data, int length);
typedef toit_err_t (*toit_msg_on_removed_cb_t)(void* user_data);

typedef struct toit_msg_cbs_t {
  toit_msg_on_created_cb_t on_created;
  toit_msg_on_message_cb_t on_message;
  toit_msg_on_request_cb_t on_rpc_request;
  toit_msg_on_removed_cb_t on_removed;
} toit_msg_cbs_t;

toit_err_t toit_msg_add_handler(const char* id,
                                void* user_data,
                                toit_msg_cbs_t cbs);

toit_err_t toit_msg_remove_handler(toit_msg_context_t* context);

toit_err_t toit_msg_notify(toit_msg_context_t* context,
                           int target_pid,
                           void* data, int length,
                           bool free_on_failure);

toit_err_t toit_msg_request_reply(toit_msg_request_handle_t handle, void* data, int length, bool free_on_failure);
toit_err_t toit_msg_request_fail(toit_msg_request_handle_t handle, const char* error);

toit_err_t toit_gc(toit_msg_context_t* context, bool try_hard);

#ifdef __cplusplus
}
#endif
