// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/** Live security evidence supplied by the connection owner, never by a remote request. */
interface SecurityState:
  /** Reports a verified security association for this live connection. */
  paired -> bool
  /** Reports successful controller encryption on the current connection. */
  encrypted -> bool
  /** Reports authenticated pairing while the connection remains encrypted. */
  authenticated -> bool
