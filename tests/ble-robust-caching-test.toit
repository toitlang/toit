// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Robust Caching (Core 6.3 Vol 3 Part G 2.5.2.1, 7.2, 7.3): the Database
// Hash, per-client Client Supported Features, and the change-unaware
// client's Database Out Of Sync.

import expect show *
import io
import ble.experimental.attribute-server as attributes
import .ble-cccd-session-test as session-fixture

CLIENT-FEATURES ::= 11
HASH ::= 13
SERVICE-CHANGED ::= 8

// AES-CMAC (zero key) of the default layout's declarations, computed with
// OpenSSL from the message the specification defines, in wire order.
DEFAULT-HASH ::= #[0x1f, 0xb2, 0xc2, 0x45, 0xf8, 0x22, 0x40, 0xf7,
                   0x2b, 0x06, 0xc5, 0x26, 0x63, 0x75, 0xce, 0x16]

main:
  layout
  hash
  features
  out-of-sync
  hash-read
  indication-confirmed
  unencrypted
  migration
  limit

layout:
  plain := attributes.Database.with-defaults
  expect-null plain.client-features-handle
  expect-null plain.database-hash-handle
  database := attributes.Database.with-defaults --caching
  expect-equals CLIENT-FEATURES database.client-features-handle
  expect-equals HASH database.database-hash-handle
  // Application values are not reported for the GATT service's own values.
  session := database.session
  expect-equals #[0x13] (session.request #[0x12, CLIENT-FEATURES, 0, 1])
  written := []
  session.writes-do: | handle value | written.add handle
  expect written.is-empty

hash:
  database := attributes.Database.with-defaults --caching
  expect-equals DEFAULT-HASH database.database-hash
  session := database.session
  expect-equals #[0x0b] + DEFAULT-HASH (session.request #[0x0a, HASH, 0])
  // Read By Type finds it by UUID, as caching clients do.
  expect-equals #[0x09, 18, HASH, 0] + DEFAULT-HASH (session.request #[0x08, 1, 0, 0xff, 0xff, 0x2a, 0x2b])
  // Values do not change the hash; the layout does.
  other := attributes.Database.with-defaults --caching
  other.add-service #[0xf0, 0xff]
  value := other.add-characteristic #[0xf1, 0xff] --read --value=#[1]
  first := other.database-hash
  other.set-value value #[2]
  expect-equals first other.database-hash
  expect first != DEFAULT-HASH
  bigger := attributes.Database.with-defaults --caching
  bigger.add-service #[0xf0, 0xff]
  bigger.add-characteristic #[0xf1, 0xff] --read --notify --value=#[1]
  expect bigger.database-hash != first
  // The hash is not writable.
  expect-equals #[0x01, 0x12, HASH, 0, 0x03] (session.request #[0x12, HASH, 0, 0])

features:
  session := (attributes.Database.with-defaults --caching).session
  expect-equals #[0x0b, 0] (session.request #[0x0a, CLIENT-FEATURES, 0])
  // Unsupported bits are ignored.
  expect-equals #[0x13] (session.request #[0x12, CLIENT-FEATURES, 0, 0x07])
  expect-equals #[0x0b, 1] (session.request #[0x0a, CLIENT-FEATURES, 0])
  // A client cannot disable a feature it enabled.
  expect-equals #[0x01, 0x12, CLIENT-FEATURES, 0, 0x13] (session.request #[0x12, CLIENT-FEATURES, 0, 0])
  expect-equals #[0x01, 0x12, CLIENT-FEATURES, 0, 0x0d] (session.request #[0x12, CLIENT-FEATURES, 0])
  expect-equals 1 session.client-features
  // Each connection starts without features.
  other := (attributes.Database.with-defaults --caching).session
  expect-equals 0 other.client-features
  // A prepared write follows the same rules.
  prepared := (attributes.Database.with-defaults --caching).session
  expect-equals #[0x17, CLIENT-FEATURES, 0, 0, 0, 1] (prepared.request #[0x16, CLIENT-FEATURES, 0, 0, 0, 1])
  expect-equals #[0x19] (prepared.request #[0x18, 1])
  expect-equals 1 prepared.client-features
  expect-equals #[0x17, CLIENT-FEATURES, 0, 0, 0, 0] (prepared.request #[0x16, CLIENT-FEATURES, 0, 0, 0, 0])
  expect-equals #[0x01, 0x18, CLIENT-FEATURES, 0, 0x13] (prepared.request #[0x18, 1])

  // A bonded client's features persist in format 2.
  store := session-fixture.Store
  bonded := bonded-session store
  expect-equals #[0x13] (bonded.request #[0x12, CLIENT-FEATURES, 0, 1])
  expect-equals #[2, 0, 1] store.state
  restored := bonded-session store
  expect-equals 1 restored.client-features
  expect-equals #[0x0b, 1] (restored.request #[0x0a, CLIENT-FEATURES, 0])
  // Format 2 needs features and a database that has them.
  [#[2, 0, 0], #[2, 0, 2], #[1, 0, 1]].do: | state/ByteArray |
    store.state = state
    expect-throw "GATT_INVALID_CCCD_STATE":
      bonded-session store
  store.state = #[2, 0, 1]
  expect-throw "GATT_INVALID_CCCD_STATE":
    attributes.Database.with-defaults.session --cccd-store=store --security=session-fixture.Evidence

/** A bonded client with Robust Caching whose layout changed since it last connected. */
unaware store/session-fixture.Store evidence/session-fixture.Evidence -> attributes.Session:
  store.state = #[0x82, 0, 1]
  session := (attributes.Database.with-defaults --caching).session --security=evidence --cccd-store=store
  expect session.change-unaware
  return session

out-of-sync:
  store := session-fixture.Store
  session := unaware store session-fixture.Evidence
  // Commands are ignored.
  expect-null (session.request #[0x52, 3, 0, 0x41])
  expect-equals 0 store.saves
  // The MTU exchange is not an attribute access.
  expect-equals #[0x03, 23, 0] (session.request #[0x02, 23, 0])
  // The first request is refused, the next one is served and ends it.
  expect-equals #[0x01, 0x0a, 3, 0, 0x12] (session.request #[0x0a, 3, 0])
  expect-equals #[0x0b] + "Toit".to-byte-array (session.request #[0x0a, 3, 0])
  expect (not session.change-unaware)
  expect-equals #[2, 0, 1] store.state
  expect-equals #[0x0b] + "Toit".to-byte-array (session.request #[0x0a, 3, 0])
  // Execute Write has no handle in error.
  other := unaware session-fixture.Store session-fixture.Evidence
  expect-equals #[0x01, 0x18, 0, 0, 0x12] (other.request #[0x18, 1])

hash-read:
  store := session-fixture.Store
  session := unaware store session-fixture.Evidence
  // Reading the hash by type is answered; the request after it is served.
  expect-equals #[0x09, 18, HASH, 0] + DEFAULT-HASH
      (session.request #[0x08, 1, 0, 0xff, 0xff, 0x2a, 0x2b])
  expect session.change-unaware
  expect-equals #[0x05, 1, 1, 0, 0, 0x28] (session.request #[0x04, 1, 0, 1, 0])
  expect (not session.change-unaware)
  expect-equals #[2, 0, 1] store.state

indication-confirmed:
  // Subscribed to Service Changed as well: the confirmation ends it.
  store := session-fixture.Store
  state := #[0x82, 1, SERVICE-CHANGED + 1, 0, 2, 0, 1]
  store.state = state
  session := bonded-session store
  expect session.change-unaware
  expect session.service-changed-pending
  session.confirm-service-changed
  expect (not session.change-unaware)
  expect-equals #[2, 1, SERVICE-CHANGED + 1, 0, 2, 0, 1] store.state
  expect-equals #[0x0b, 0, 0x18] (session.request #[0x0a, 1, 0])

unencrypted:
  // Before encryption the bond's state does not apply.
  store := session-fixture.Store
  evidence := session-fixture.Evidence
  evidence.encrypted = false
  session := unaware-with store evidence
  expect (not session.change-unaware)
  expect-equals #[0x0b, 0, 0x18] (session.request #[0x0a, 1, 0])
  expect-equals #[0x01, 0x0a, CLIENT-FEATURES, 0, 0x0f] (session.request #[0x0a, CLIENT-FEATURES, 0])
  evidence.encrypted = true
  expect session.change-unaware

bonded-session store/session-fixture.Store -> attributes.Session:
  evidence := session-fixture.Evidence
  return (attributes.Database.with-defaults --caching).session --security=evidence --cccd-store=store

unaware-with store/session-fixture.Store evidence/session-fixture.Evidence -> attributes.Session:
  store.state = #[0x82, 0, 1]
  return (attributes.Database.with-defaults --caching).session --security=evidence --cccd-store=store

migration:
  before := attributes.Database.with-defaults --caching
  after := attributes.Database.with-defaults --caching
  after.add-service #[0xf0, 0xff]
  after.add-characteristic #[0xf1, 0xff] --read --value=#[1]
  migration := attributes.ConfigurationMigration before after {:}
  // A client with Robust Caching learns of the change without Service Changed.
  expect-equals #[0x82, 0, 1] (migration.apply #[2, 0, 1])
  expect-equals #[1, 0] (migration.apply #[1, 0])
  // A layout without the features drops them.
  plain := attributes.Database.with-defaults
  expect-equals #[1, 0] ((attributes.ConfigurationMigration before plain {:}).apply #[2, 0, 1])

limit:
  // The pair comes on top of the requested limit.
  database := attributes.Database.with-defaults --caching --attribute-limit=10
  database.add-service #[0xf0, 0xff]
  expect-throw "GATT_DATABASE_FULL": database.add-service #[0xf1, 0xff]
  full := attributes.Database.with-defaults --caching --attribute-limit=attributes.Database.MAX-ATTRIBUTES
  full.add-service #[0xf0, 0xff]
  (attributes.Database.MAX-ATTRIBUTES - 14).repeat: full.add-service #[0xf0, 0xff]
  expect-throw "GATT_DATABASE_FULL": full.add-service #[0xf0, 0xff]
