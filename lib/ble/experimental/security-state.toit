// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
The security a connection currently has, as seen by attribute access checks.

$SecurityState answers the three questions the attribute server and the
  key distribution code ask about a link: is it paired, is it encrypted, and
  was the pairing authenticated. The answer comes from the connection's
  security owner (`security-owner`), which has seen the pairing and the
  controller's encryption events; a peer's claim never counts.
*/

/** Live security evidence supplied by the connection owner, never by a remote request. */
interface SecurityState:
  /** Reports a verified security association for this live connection. */
  paired -> bool
  /** Reports successful controller encryption on the current connection. */
  encrypted -> bool
  /** Reports authenticated pairing while the connection remains encrypted. */
  authenticated -> bool
