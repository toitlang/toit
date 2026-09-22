# GATT database, Service Changed and client cache

Governing text: Core 6.3 Vol 3 Part G 2.5 (caching), 3.3.3.3 (bonded CCCD
persistence) and 7.1 (Service Changed).

## Server layout

A `Database` is sealed when its first session is created; layouts change only
by creating a new database between sessions. `Database.with-defaults` adds GAP
(name, appearance) and GATT with Service Changed; `--immutable-layout` omits
Service Changed and promises a fixed layout for the device's lifetime. The
Service Changed value is indication-only, its CCCD starts disabled per
connection, and the full range 0x0001 to 0xFFFF is indicated.

Sessions start with an empty subscription map unless a trusted `cccd.Store`
is supplied. The store belongs to one bond and one database revision; it is
loaded at session start, saved atomically on every CCCD write before the ATT
response, and its loaded subscriptions stay inactive until paired encryption is
established. A save failure closes the session.

## Offline migration

`attribute-server.ConfigurationMigration old new {oldCccd: newCccd, ...}`
maps every old application CCCD to its successor (zero for removed). Service
Changed maps automatically and must keep its handle. The registry applies it to
each stored configuration before advertising and marks a pending full-range
Service Changed that is cleared durably only after the client confirms the
indication. Live database mutation is not implemented.

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

There is no persistent bonded client cache and no Database Hash / Client
Supported Features support.
