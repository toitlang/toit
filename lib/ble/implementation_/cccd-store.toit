// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

/**
The persistence boundary for a bonded peer's client characteristic
  configuration.

$Store is what the attribute server and the GATT server call to load and
  save one peer's CCCDs and client features for one database revision. The
  provider chooses and owns the implementation (the bond registry supplies
  one backed by the cccd-storage library); the servers only borrow it for a
  session's lifetime.
*/

/**
Stores one bonded peer's CCCDs for one fixed database revision.

Trusted provider code selects the peer, bond lifetime and database context.
  Neither a claimed remote address nor an application-supplied handle is enough
  to select a store. The implementation must invalidate state on bond revocation
  and prevent restoration against a different database revision. This interface
  supplies no identity resolution, encryption, storage backend or migration.

Snapshots are bounded, versioned byte arrays owned by the caller. Session close
  does not close this borrowed store or erase persisted configuration. Providers
  own the store's lifetime. A store must not call back into its session.

Version 1 uses a two-byte header and sorted four-byte CCCD entries, at most
  255 of them (1022 bytes). Version 2 appends the client's supported features
  (one byte, nonzero; 1023 bytes at most). Bit 7 of the version byte retains a
  pending layout change the client has not seen: a full-range Service Changed
  indication, which requires the Service Changed CCCD to be enabled, or a
  Database Out Of Sync for a client with Robust Caching.
  ConfigurationMigration produces this flag together with remapped entries.
  Confirmation clears it in a replacement of the same complete snapshot.
*/
interface Store:
  /** Returns saved configuration or null for a new context, within three seconds. */
  load -> ByteArray?

  /**
  Atomically and durably replaces this context's entire configuration.

  Must finish within three seconds. Returning permits an ATT success response;
    failure or cancellation closes the session because the durable outcome may
    be uncertain. A subsequent load must return an owned snapshot. Implementations
    must not retain a caller's mutable byte array without copying it.
  */
  save state/ByteArray -> none
