// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
A set of exception classes based on gRPC status codes.

The exceptions are well defined and can be translatable to most network errors (HTTP, CoAP).

See https://developers.google.com/maps-booking/reference/grpc-api/status_codes for the full description.

Exception descriptons are licensed under https://creativecommons.org/licenses/by/4.0/.
*/
abstract class Exception:
  code/string
  number/int
  message/string

  constructor .code .number .message:

  stringify -> string:
    if message == "": return code
    return "$code: $message"

/**
The operation was cancelled, typically by the caller.
*/
class CancelledException extends Exception:
  constructor message/string:
    super "CANCELLED" 1 message

/**
Unknown error.
For example, this error may be returned when a Status
  value received from another address space belongs to an error space
  that is not known in this address space. Also errors raised by APIs
  that do not return enough error information may be converted to this
  error.
*/
class UnknownException extends Exception:
  constructor message/string:
    super "UNKNOWN" 2 message

/**
The client specified an invalid argument.
Note that this differs from
  FAILED_PRECONDITION. INVALID_ARGUMENT indicates arguments that are
  problematic regardless of the state of the system (e.g., a malformed file name).
*/
class InvalidArgumentException extends Exception:
  constructor message/string:
    super "INVALID_ARGUMENT" 3 message

/**
The deadline expired before the operation could complete.
  For operations
  that change the state of the system, this error may be returned even
  if the operation has completed successfully. For example, a successful
  response from a server could have been delayed long.
*/
class DeadlineExceededException extends Exception:
  constructor message/string:
    super "DEADLINE_EXCEEDED" 4 message

/**
Some requested entity (e.g., file or directory) was not found.
Note to
  server developers: if a request is denied for an entire class of users,
  such as gradual feature rollout or undocumented allowlist, NOT_FOUND
  may be used. If a request is denied for some users within a class of
  users, such as user-based access control, PERMISSION_DENIED must be used.
*/
class NotFoundException extends Exception:
  constructor message/string:
    super "NOT_FOUND" 5 message

/**
The entity that a client attempted to create (e.g., file or directory)
  already exists.
*/
class AlreadyExistsException extends Exception:
  constructor message/string:
    super "ALREADY_EXISTS" 6 message

/**
The caller does not have permission to execute the specified operation.
PERMISSION_DENIED must not be used for rejections caused by exhausting
  some resource (use RESOURCE_EXHAUSTED instead for those errors).
  PERMISSION_DENIED must not be used if the caller can not be identified
  (use UNAUTHENTICATED instead for those errors). This error code does
  not imply the request is valid or the requested entity exists or
  satisfies other pre-conditions.
*/
class PermissionDeniedException extends Exception:
  constructor message/string:
    super "PERMISSION_DENIED" 7 message

/**
Some resource has been exhausted, perhaps a per-user quota, or perhaps
  the entire file system is out of space.
*/
class ResourceExhaustedException extends Exception:
  constructor message/string:
    super "RESOURCE_EXHAUSTED" 8 message

/**
The operation was rejected because the system is not in a state required
  for the operation's execution.
For example, the directory to be deleted
  is non-empty, an rmdir operation is applied to a non-directory, etc.
  Service implementors can use the following guidelines to decide between
  FAILED_PRECONDITION, ABORTED, and UNAVAILABLE:
  - Use UNAVAILABLE if the client can retry just the failing call.
  - Use ABORTED if the client should retry at a higher level (e.g.,
      when a client-specified test-and-set fails, indicating the client
      should restart a read-modify-write sequence).
  - Use FAILED_PRECONDITION if the client should not retry until the
      system state has been explicitly fixed. E.g., if an "rmdir" fails
      because the directory is non-empty, FAILED_PRECONDITION should be
      returned since the client should not retry unless the files are
      deleted from the directory.
*/
class FailedPreconditionException extends Exception:
  constructor message/string:
    super "FAILED_PRECONDITION" 9 message

/**
The operation was aborted, typically due to a concurrency issue such as a
  sequencer check failure or transaction abort.
See the guidelines above
  for deciding between FAILED_PRECONDITION, ABORTED, and UNAVAILABLE.
*/
class AbortedException extends Exception:
  constructor message/string:
    super "ABORTED" 10 message

/**
The operation was attempted past the valid range.
E.g., seeking or reading
  past end-of-file. Unlike INVALID_ARGUMENT, this error indicates a problem
  that may be fixed if the system state changes. For example, a 32-bit file
  system will generate INVALID_ARGUMENT if asked to read at an offset that
  is not in the range [0,2^32-1], but it will generate OUT_OF_RANGE if
  asked to read from an offset past the current file size. There is a fair
  bit of overlap between FAILED_PRECONDITION and OUT_OF_RANGE. We recommend
  using OUT_OF_RANGE (the more specific error) when it applies so that
  callers who are iterating through a space can easily look for an
  OUT_OF_RANGE error to detect when they are done.
*/
class OutOfRangeException extends Exception:
  constructor message/string:
    super "OUT_OF_RANGE" 11 message

/**
The operation is not implemented or is not supported/enabled in this service.
*/
class UnimplementedException extends Exception:
  constructor message/string:
    super "UNIMPLEMENTED" 12 message

/**
Internal errors.
This means that some invariants expected by the underlying
  system have been broken. This error code is reserved for serious errors.
*/
class InternalException extends Exception:
  constructor message/string:
    super "INTERNAL" 13 message

/**
The service is currently unavailable.
This is most likely a transient
  condition, which can be corrected by retrying with a backoff. Note that it
  is not always safe to retry non-idempotent operations.
*/
class UnavailableException extends Exception:
  constructor message/string:
    super "UNAVAILABLE" 14 message

/**
Unrecoverable data loss or corruption.
*/
class DataLossException extends Exception:
  constructor message/string:
    super "DATA_LOSS" 15 message

/**
The request does not have valid authentication credentials for the operation.
*/
class UnauthenticatedException extends Exception:
  constructor message/string:
    super "UNAUTHENTICATED" 16 message
