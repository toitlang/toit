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

typedef enum toit_err_t {
  // The operation succeeded.
  TOIT_ERR_SUCCESS = 0,
  // The operation encountered an out-of-memory error.
  TOIT_ERR_OOM = 1,
  // An error, for when the receiver of a system message didn't exist.
  TOIT_ERR_NO_SUCH_RECEIVER = 2,
  // An unknown error.
  TOIT_ERR_ERROR = 3,
} toit_err_t;

struct toit_process_context_t;
typedef struct toit_process_context_t toit_process_context_t;

typedef toit_err_t (*start_cb_t)(void* user_context, toit_process_context_t* process_context);
typedef toit_err_t (*on_message_cb_t)(void* user_context, int sender, int type, void* data, int length);
typedef toit_err_t (*on_removed_cb_t)(void* user_context);

typedef struct toit_process_cbs_t {
  on_message_cb_t on_message;
  on_removed_cb_t on_removed;
} toit_process_cbs_t;

toit_err_t toit_add_external_process(void* user_context,
                                     const char* id,
                                     start_cb_t start_cb);

toit_err_t toit_remove_process(toit_process_context_t* process_context);

toit_err_t toit_set_callbacks(toit_process_context_t* process_context, toit_process_cbs_t cbs);

toit_err_t toit_send_message(toit_process_context_t* process_context,
                             int target_pid, int type,
                             void* data, int length,
                             bool free_on_failure);

toit_err_t toit_gc(toit_process_context_t* process_context, bool try_hard);

#ifdef __cplusplus
}
#endif
