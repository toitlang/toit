// Copyright (C) 2023 Toitware ApS.
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

/*
 * C interface for Toit's messaging API.
 */

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct HandlerContext;

void toit_register_external_message_handler(void* user_context,
                                            int requested_pid,
                                            void (*create_handler)(void* user_context, HandlerContext* handler_context));
void toit_set_callback(HandlerContext* handler_context,
                       void (*callback)(void* user_context, int sender, int type, void* data, int length));
bool toit_send_message(HandlerContext* handler_context, int target_pid, int type, void* data, int length, bool free_on_failure);
void toit_release_handler(HandlerContext* handler_context);

#ifdef __cplusplus
}
#endif
