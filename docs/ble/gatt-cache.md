# GATT database, Service Changed and client cache

Governing text: Core 6.3 Vol 3 Part G 2.5 (caching), 3.3.3.3 (bonded CCCD
persistence), 7.1 (Service Changed), 7.2 (Client Supported Features) and 7.3
(Database Hash).

## Server layout

A `Database` is sealed when its first session is created; layouts change only
by creating a new database between sessions. `Database.with-defaults` adds GAP
(name, appearance) and GATT with Service Changed; `--immutable-layout` omits
Service Changed and promises a fixed layout for the device's lifetime. The
Service Changed value is indication-only, its CCCD starts disabled per
connection, and the full range 0x0001 to 0xFFFF is indicated.

`--caching` (on in the providers' databases) adds the Robust Caching pair to
the GATT service, so application attributes start at handle 14:

- Database Hash: AES-CMAC with a zero key over the declarations (Vol 3
  Part G 7.3.1), fixed when the database is sealed. Values do not take part.
  Clients that cache a layout compare it on reconnection.
- Client Supported Features: per connection; only Robust Caching (bit 0) is
  kept, and a client cannot clear a bit it set (Value Not Allowed). A bonded
  client's features are stored with its CCCDs.

A bonded client with Robust Caching is change-unaware while its stored
configuration carries a pending layout change and the link is encrypted: its
commands are ignored, its first request (other than the MTU exchange and a
Read By Type of the Database Hash) gets Database Out Of Sync (0x12), and the
next request makes it change-aware and clears the pending change durably, as
does confirming the Service Changed indication.

Sessions start with an empty subscription map unless a trusted `cccd.Store`
is supplied. The store belongs to one bond and one database revision; it is
loaded at session start, saved atomically on every CCCD or client features
write before the ATT response, and its loaded subscriptions stay inactive until paired encryption is
established. A save failure closes the session.

## Offline migration

`attribute-server.ConfigurationMigration old new {oldCccd: newCccd, ...}`
maps every old application CCCD to its successor (zero for removed). Service
Changed maps automatically and must keep its handle. The registry applies it to
each stored configuration before advertising and marks a pending full-range
Service Changed that is cleared durably only after the client confirms the
indication (or, with Robust Caching, after its request following Database
Out Of Sync). Client features carry over. Live database mutation is not implemented.

## Client side

Discovery records are connection-local observations bound to a
`database-revision`. `att.Client.monitor-service-changed` (or
`gatt.with-service-changed`) subscribes to the peer's Service Changed
indication and bumps the revision on every change before confirming; checked
operations reject stale records before transmission and after draining an
in-flight response. Nothing is retried automatically because a write may
already have been applied.

Through the service API, `Connection.with-service-changed` and
`Connection.database` give a `DatabaseView` whose `ServiceRecord`,
`CharacteristicRecord` and `DescriptorRecord` carry the revision into every
read, write and subscription. An active subscription whose database changed
reports `GATT_DATABASE_CHANGED`; its cleanup closes the link rather than
writing a possibly repurposed CCCD.

There is no persistent bonded client cache: the client does not read peers'
Database Hash or enable Robust Caching on them.
