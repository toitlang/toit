// Copyright (C) 2024 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#pragma once

#ifdef __cplusplus
#include <cstdint>
extern "C" {
#else
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#endif

/*
 * C interface for Toit's external API.
 */

/**
 * @brief Toit error constants.
 */
typedef enum {
  TOIT_OK = 0,                 /*!< The operation succeeded (no error). */
  TOIT_ERR_OOM,                /*!< Out of memory. */
  TOIT_ERR_NO_SUCH_RECEIVER,   /*!< The receiver of a system message didn't exist. */
  TOIT_ERR_NOT_FOUND,          /*!< The corresponding resource was not found. */
  TOIT_ERR_ERROR,              /*!< Unknown error. */
} toit_err_t;

/**
 * @brief Opaque context for a message handler.
 */
typedef struct toit_msg_context_t toit_msg_context_t;

/**
 * @brief A handle for a request.
 *
 * This handle is used to reply to an RPC request.
 */
typedef struct {
  int sender;
  int request_handle;
  toit_msg_context_t* context;
} toit_msg_request_handle_t;

/**
 * @brief Callback type for when the message handler is fully created.
 *
 * This callback is typically used to store the context of the message handler.
 *
 * @param user_data The user data passed to `toit_msg_add_handler`.
 * @param context The context of the message handler.
 * @return toit_err_t The result of the callback. Must be `TOIT_OK`.
 */
typedef toit_err_t (*toit_msg_on_created_cb_t)(void* user_data, toit_msg_context_t* context);

/**
 * @brief Callback type for when a notification message is received.
 *
 * This callback is called when a notification message is sent from Toit (or another
 * service) to this service.
 *
 * The data is owned by the receiver and must be freed.
 * If the Toit side sent a string, then the data is guaranteed to be 0-terminated. The
 * length does *not* include the 0-terminator.
 *
 * @param user_data The user data passed to `toit_msg_add_handler`.
 * @param sender The PID of the sender.
 * @param data The data of the message. Must be freed by the receiver.
 * @param length The length of the data.
 * @return toit_err_t The result of the callback. Must be `TOIT_OK`.
 */
typedef toit_err_t (*toit_msg_on_message_cb_t)(void* user_data, int sender, uint8_t* data, int length);

/**
 * @brief Callback type for when an RPC request is received.
 *
 * This callback is called when an RPC request is sent from Toit to this service.
 *
 * The function ID can be used to determine the type of request, and is free to be
 * used as the service sees fit.
 *
 * Services are expected to reply to the request using `toit_msg_request_reply` or
 * `toit_msg_request_fail`, using the `rpc_handle` provided.
 *
 * It is an error to not reply to the request, or to reply more than once.
 *
 * The data is owned by the receiver and must be freed.
 * If the Toit side sent a string, then the data is guaranteed to be 0-terminated. The
 * length does *not* include the 0-terminator.
 *
 * @param user_data The user data passed to `toit_msg_add_handler`.
 * @param sender The PID of the sender.
 * @param function The function ID of the request.
 * @param rpc_handle The handle to the request.
 * @param data The data of the request. Must be freed by the receiver.
 * @param length The length of the data.
 * @return toit_err_t The result of the callback. Must be `TOIT_OK`.
 */
typedef toit_err_t (*toit_msg_on_request_cb_t)(void* user_data,
                                               int sender,
                                               int function,
                                               toit_msg_request_handle_t rpc_handle,
                                               uint8_t* data, int length);

/**
 * @brief Callback type for when the message handler is removed.
 *
 * This callback is called when the message handler is removed from the system. At this
 * point, the user data is no longer needed and can be freed.
 *
 * @param user_data The user data passed to `toit_msg_add_handler`.
 * @return toit_err_t The result of the callback. Must be `TOIT_OK`.
 */
typedef toit_err_t (*toit_msg_on_removed_cb_t)(void* user_data);

/**
 * @brief Callbacks for the message handler.
 */
typedef struct toit_msg_cbs_t {
  toit_msg_on_created_cb_t on_created;
  toit_msg_on_message_cb_t on_message;
  toit_msg_on_request_cb_t on_rpc_request;
  toit_msg_on_removed_cb_t on_removed;
} toit_msg_cbs_t;

/**
 * @brief Macro to create an empty set of message handler callbacks.
 */
#define TOIT_MSG_EMPTY_CBS() { \
  .on_created = NULL,          \
  .on_message = NULL,          \
  .on_rpc_request = NULL,      \
  .on_removed = NULL,          \
}

/**
 * @brief Add a message handler for this service.
 *
 * This function must be called *before* the Toit system is started.
 *
 * Usually, one would use `__attribute__((constructor))` on a function to ensure
 * that the code that adds the handler is run before the system is started.
 *
 * Example:
 *
 * ```c
 * static void __attribute__((constructor)) init() {
 *   ...
 *   toit_msg_add_handler(...);
 * }
 *
 * The `id` is a unique identifier for the message handler. It should be based
 * on a URL-like format, like `my-domain.com/my-service`.
 *
 * @param id The unique identifier for the message handler.
 * @param user_data The user data to pass to the callbacks.
 * @param cbs The callbacks for the message handler.
 * @return toit_err_t
 *     - TOIT_OK: The message handler was added successfully.
 *     - TOIT_ERR_OOM: Out of memory.
 */
toit_err_t toit_msg_add_handler(const char* id,
                                void* user_data,
                                toit_msg_cbs_t cbs);

/**
 * @brief Requests the removal of a message handler.
 *
 * Once the message handler is removed, the `on_removed` callback will be called.
 *
 * @param context The context of the message handler.
 * @return toit_err_t
 *     - TOIT_OK: The message handler was removed successfully.
 *     - TOIT_ERR_NOT_FOUND: The message handler was not found.
 */
toit_err_t toit_msg_remove_handler(toit_msg_context_t* context);

/**
 * @brief Sends a notification message to a target process.
 *
 * Ownership of the data is transferred to the system, and the system will free
 * the data when it is no longer needed.
 *
 * If `free_on_failure` is `true`, the data will be freed even if the message
 * cannot be sent.
 *
 * Ids of target processes must be received through a request or notification.
 * There is currently no way to find the id of a Toit process without having
 * received a message from it first.
 * *
 * @param context The context of the message handler.
 * @param target_pid The PID of the target process.
 * @param data The data to send.
 * @param length The length of the data.
 * @param free_on_failure Whether to free the data if the message cannot be sent.
 * @return toit_err_t
 *     - TOIT_OK: The message was sent successfully.
 *     - TOIT_ERR_NO_SUCH_RECEIVER: The target process does not exist.
 *     - TOIT_ERR_OOM: Out of memory, despite calling `toit_gc`.
 */
toit_err_t toit_msg_notify(toit_msg_context_t* context,
                           int target_pid,
                           uint8_t* data, int length,
                           bool free_on_failure);

/**
 * @brief Reply to an RPC request.
 *
 * Ownership of the data is transferred to the system, and the system will free
 * the data when it is no longer needed.
 *
 * If `free_on_failure` is `true`, the data will be freed even if the message
 * cannot be sent.
 *
 * @param handle The handle to the request. This handle must have been received
 *              through the `on_rpc_request` callback.
 * @param data The data to send.
 * @param length The length of the data.
 * @param free_on_failure Whether to free the data if the message cannot be sent.
 * @return toit_err_t
 *    - TOIT_OK: The message was sent successfully.
 *    - TOIT_ERR_NO_SUCH_RECEIVER: The target process does not exist.
 *    - TOIT_ERR_OOM: Out of memory, despite calling `toit_gc`.
 */
toit_err_t toit_msg_request_reply(toit_msg_request_handle_t handle, uint8_t* data, int length, bool free_on_failure);

/**
 * @brief Fail an RPC request.
 *
 * This function is used to fail an RPC request. The error message will be sent
 * to the requester.
 *
 * The error message is *not* freed by the system and the caller retains ownership of it.
 * It is typically a string literal. The string must not exceed 128 characters.
 *
 * @param handle The handle to the request. This handle must have been received
 *              through the `on_rpc_request` callback.
 * @param error The error message to send.
 * @return toit_err_t
 *     - TOIT_OK: The failure message was sent successfully.
 *     - TOIT_ERR_NO_SUCH_RECEIVER: The target process does not exist.
 *     - TOIT_ERR_OOM: Out of memory, despite calling `toit_gc`.
 */
toit_err_t toit_msg_request_fail(toit_msg_request_handle_t handle, const char* error);

/**
 * @brief Perform a garbage collection on all Toit processes.
 *
 * @return toit_err_t
 *     - TOIT_OK: The garbage collection was run successfully.
 */
toit_err_t toit_gc();

/**
 * @brief A wrapper around `malloc` that calls `toit_gc` if `malloc` fails.
 *
 * If `malloc` fails, this function calls `toit_gc` and then retries the allocation.
 *
 * @param size The size of the memory to allocate.
 * @return void* A pointer to the allocated memory, or `NULL` if the allocation failed.
 */
void* toit_malloc(size_t size);

/**
 * @brief A wrapper around `calloc` that calls `toit_gc` if `calloc` fails.
 *
 * If `calloc` fails, this function calls `toit_gc` and then retries the allocation.
 *
 * @param nmemb The number of elements to allocate.
 * @param size The size of each element.
 * @return void* A pointer to the allocated memory, or `NULL` if the allocation failed.
 */
void* toit_calloc(size_t nmemb, size_t size);

/**
 * @brief A wrapper around `realloc` that calls `toit_gc` if `realloc` fails.
 *
 * If `realloc` fails, this function calls `toit_gc` and then retries the allocation.
 *
 * @param ptr The pointer to the memory to reallocate.
 * @param size The new size that is requested.
 * @return void* A pointer to the allocated memory, or `NULL` if the reallocation failed.
 */
void* toit_realloc(void* ptr, size_t size);

#ifdef __cplusplus
}
#endif
