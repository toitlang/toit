// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
The host's time bounds, in one place.

Every bounded wait in the host names one of these instead of a literal, so
  the policy is reviewable and adjustable. Values are conservative defaults
  for a controller that answers promptly; a caller's own deadline (through
  `with-timeout`) can always be shorter.
*/

/** A controller's answer to one HCI command (Command Status or Complete). */
COMMAND ::= Duration --s=3

/** Releasing protocol state after failure: disconnects, joins, credit returns. */
CLEANUP ::= Duration --s=3

/** Waiting for the receive task of a closed owner to end. */
JOIN ::= Duration --s=3

/** One ATT request's response (Core Vol 3 Part F 3.3.3 allows 30 s; we expect less). */
ATT-REQUEST ::= Duration --s=3

/** Draining accounted controller buffers before ending a link. */
DRAIN ::= Duration --s=3

/** Submitting one PDU: link serialization, controller credits and the transport. */
SEND ::= Duration --s=3

/** The whole SMP exchange and the encryption that follows (Core Vol 3 Part H 3.4). */
SECURITY ::= Duration --s=30

/** A connection parameter update after the controller accepted the command. */
PARAMETER-UPDATE ::= Duration --s=30

/** An indication's confirmation (Core Vol 3 Part F 3.3.3 transaction timeout). */
INDICATION ::= Duration --s=30

/** A pending durable store operation (CCCD or bond record). */
STORE ::= Duration --s=3

/** Serving one ATT PDU including its application handlers. */
SERVE-PDU ::= Duration --s=10

/** Establishing an outgoing connection. */
CONNECT ::= Duration --s=10

/** Accepting one incoming connection while advertising. */
ACCEPT ::= Duration --s=30

/** The termination event of one bounded advertising window (one second of advertising plus slack). */
WINDOW ::= Duration --s=3

/** One reply on the Linux Bluetooth management socket. */
MANAGEMENT ::= Duration --s=5

/** A cancelled session worker's cleanup, as awaited by its RPC caller. */
WORKER ::= Duration --s=5

/** Bringing up a shared host: controller initialization and its first configuration. */
SETUP ::= Duration --s=60
