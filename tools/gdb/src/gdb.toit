// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import .rsp

/**
A client library for GDB's Remote Serial Protocol.

The caller owns the transport and supplies a reader and writer to $Client.
This permits TCP, serial, pipe, and in-memory transports.
*/

export *
