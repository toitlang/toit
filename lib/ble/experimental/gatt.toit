// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io

import .att as att

/**
GATT client procedures on top of the ATT client.

$services, $included-services, $characteristics and $descriptors discover a
  peer's database into $Service, $Characteristic, $IncludedService and
  $Descriptor records that remember the $att.Client and database revision
  they came from, so a stale record is rejected instead of acting on a
  changed layout. $read, $write, $read-long, $write-long, $read-by-uuid and
  $read-multiple are the value procedures, and $with-notifications,
  $with-indications and $with-service-changed the scoped subscriptions. The
  central provider's GATT client operations build on this library.
*/

// Discovered records retain a client and integer revision, not a global registry.
// Unreachable records can therefore be collected without explicit deregistration.
class DiscoveryRecord_:
  client_/att.Client? := null
  revision_/int := 0

  /** Tests whether this record is still valid on its original connection. */
  valid -> bool:
    return not client_ or (client_.valid-database-revision revision_)

  /** Rejects stale records and records discovered on another connection. */
  check client/att.Client -> none:
    if client_ and client_ != client: throw "GATT_FOREIGN_RECORD"
    if client_: client.check-database-revision revision_

  bind_ client/att.Client revision/int -> none:
    client_ = client
    revision_ = revision

/** A primary service's inclusive handle range and little-endian UUID. */
class Service extends DiscoveryRecord_:
  start/int
  end/int
  uuid/ByteArray

  constructor .start .end .uuid:

/** A characteristic declaration, value handle, and descriptor range end. */
class Characteristic extends DiscoveryRecord_:
  declaration/int
  handle/int
  properties/int
  uuid/ByteArray
  end/int := 0

  constructor .declaration .handle .properties .uuid:

/**
A service included by another: the include declaration's handle and the
  included service's handle range and little-endian UUID.
*/
class IncludedService extends DiscoveryRecord_:
  handle/int
  start/int
  end/int
  uuid/ByteArray

  constructor .handle .start .end .uuid:

  /** The included service as a record for further discovery. */
  service -> Service:
    result := Service start end uuid
    result.client_ = client_
    result.revision_ = revision_
    return result

/** A descriptor handle and little-endian UUID. */
class Descriptor extends DiscoveryRecord_:
  handle/int
  uuid/ByteArray

  constructor .handle .uuid:

/**
Discovers primary services, with a bounded result of at most 512 entries.

Results are connection-local observations, not a persistent cache. Rediscover
  after reconnect and after an applicable Service Changed indication. Callers
  can use $with-service-changed for reader-side invalidation. Checked helpers
  reject stale records; raw numeric ATT handles remain the caller's
  responsibility.
*/
services client/att.Client -> List:
  // Attribute caching and Service Changed: Core 6.3 Vol 3 Part G 2.5.
  revision := client.database-revision
  result := []
  start := 1
  while start <= 0xffff:
    page := page_ client 0x10 start 0xffff --type=0x2800 --revision=revision
    if not page: break
    width := width_ page 6 20
    offset := 2
    while offset < page.size:
      first := io.LITTLE-ENDIAN.uint16 page offset
      last := io.LITTLE-ENDIAN.uint16 page (offset + 2)
      if not start <= first <= last: throw "GATT_INVALID_HANDLE_RANGE"
      record := Service first last page[offset + 4..offset + width]
      record.bind_ client revision
      add_ result record
      start = last + 1
      offset += width
  client.check-database-revision revision
  return result

/**
Discovers the services $service includes.

128-bit included UUIDs are not in the declaration; each costs one read of the
  included service's declaration.
*/
included-services client/att.Client service/Service -> List:
  // Find Included Services: Core 6.3 Vol 3 Part G 4.5.1.
  service.check client
  revision := client.database-revision
  range_ service.start service.end
  result := []
  start := service.start
  while start <= service.end:
    page := page_ client 8 start service.end --type=0x2802 --revision=revision
    if not page: break
    width := width_ page 6 8
    offset := 2
    while offset < page.size:
      handle := io.LITTLE-ENDIAN.uint16 page offset
      first := io.LITTLE-ENDIAN.uint16 page (offset + 2)
      last := io.LITTLE-ENDIAN.uint16 page (offset + 4)
      if not start <= handle <= service.end or not 1 <= first <= last:
        throw "GATT_INVALID_HANDLE_RANGE"
      uuid := width == 8
          ? page[offset + 6..offset + 8].copy
          : client.read first --database-revision=revision
      if uuid.size != 2 and uuid.size != 16: throw "GATT_INVALID_RESPONSE"
      record := IncludedService handle first last uuid
      record.bind_ client revision
      add_ result record
      start = handle + 1
      offset += width
  client.check-database-revision revision
  return result

/**
Reads every attribute of type $uuid (little endian, 2 or 16 bytes) between
  $start and $end with one Read By Type request per page.

Returns [handle, value] pairs. Each value is at most MTU - 4 bytes; read a
  longer one by its handle.
*/
read-by-uuid client/att.Client uuid/ByteArray --start/int=1 --end/int=0xffff -> List:
  // Read Using Characteristic UUID: Core 6.3 Vol 3 Part G 4.8.2.
  if uuid.size != 2 and uuid.size != 16: throw "INVALID_ARGUMENT"
  range_ start end
  revision := client.database-revision
  result := []
  while start <= end:
    request := ByteArray 5 + uuid.size
    request[0] = 8
    io.LITTLE-ENDIAN.put-uint16 request 1 start
    io.LITTLE-ENDIAN.put-uint16 request 3 end
    request.replace 5 uuid
    page/ByteArray? := null
    error := catch: page = client.request request --response=9 --database-revision=revision
    if error:
      if error is att.AttributeError and error.code == 0x0a: break
      throw error
    if page.size < 2 or page[1] < 2 or (page.size - 2) % page[1] != 0: throw "GATT_INVALID_RESPONSE"
    width := page[1]
    offset := 2
    while offset < page.size:
      handle := io.LITTLE-ENDIAN.uint16 page offset
      if not start <= handle <= end: throw "GATT_INVALID_HANDLE_RANGE"
      add_ result [handle, page[offset + 2..offset + width].copy]
      start = handle + 1
      offset += width
    if start == 0: break
  client.check-database-revision revision
  return result

/**
Reads several attributes in one request.

Without $variable the peer concatenates the values (Read Multiple), so the
  caller must know their sizes; returns the bytes. With $variable (Read
  Multiple Variable Length) returns the list of values. Both stop at
  MTU - 1 bytes.
*/
read-multiple client/att.Client handles/List --variable/bool=false -> any:
  // Read Multiple and Read Multiple Variable Length: Core 6.3 Vol 3 Part G
  // 4.8.4 and 4.8.5.
  if handles.size < 2: throw "INVALID_ARGUMENT"
  request := ByteArray 1 + 2 * handles.size
  request[0] = variable ? 0x20 : 0x0e
  handles.size.repeat: | index/int |
    handle := handles[index]
    if not 1 <= handle <= 0xffff: throw "INVALID_ARGUMENT"
    io.LITTLE-ENDIAN.put-uint16 request (1 + 2 * index) handle
  response := client.request request --response=(variable ? 0x21 : 0x0f)
      --database-revision=client.database-revision
  if not variable: return response[1..].copy
  values := []
  offset := 1
  while offset + 2 <= response.size:
    length := io.LITTLE-ENDIAN.uint16 response offset
    offset += 2
    // The last value may be cut at the MTU.
    values.add response[offset..min (offset + length) response.size].copy
    offset += length
  return values

/** Discovers characteristics and derives their descriptor ranges. */
characteristics client/att.Client service/Service -> List:
  service.check client
  revision := client.database-revision
  range_ service.start service.end
  result := []
  start := service.start
  previous/Characteristic? := null
  while start <= service.end:
    page := page_ client 8 start service.end --type=0x2803 --revision=revision
    if not page: break
    width := width_ page 7 21
    offset := 2
    while offset < page.size:
      declaration := io.LITTLE-ENDIAN.uint16 page offset
      handle := io.LITTLE-ENDIAN.uint16 page (offset + 3)
      if not start <= declaration < handle <= service.end:
        throw "GATT_INVALID_HANDLE_RANGE"
      if previous:
        if declaration <= previous.handle: throw "GATT_INVALID_HANDLE_RANGE"
        previous.end = declaration - 1
      characteristic := Characteristic declaration handle page[offset + 2] page[offset + 5..offset + width]
      characteristic.bind_ client revision
      characteristic.end = service.end
      add_ result characteristic
      previous = characteristic
      start = declaration + 1
      offset += width
  client.check-database-revision revision
  return result

/** Discovers descriptors without crossing into the next characteristic. */
descriptors client/att.Client characteristic/Characteristic -> List:
  characteristic.check client
  revision := client.database-revision
  range_ characteristic.handle characteristic.end
  result := []
  start := characteristic.handle + 1
  while start <= characteristic.end:
    page := page_ client 4 start characteristic.end --revision=revision
    if not page: break
    if page.size < 2 or (page[1] != 1 and page[1] != 2):
      throw "GATT_INVALID_RESPONSE"
    width := page[1] == 1 ? 4 : 18
    if page.size <= 2 or (page.size - 2) % width != 0:
      throw "GATT_INVALID_RESPONSE"
    offset := 2
    while offset < page.size:
      handle := io.LITTLE-ENDIAN.uint16 page offset
      if not start <= handle <= characteristic.end: throw "GATT_INVALID_HANDLE_RANGE"
      record := Descriptor handle page[offset + 2..offset + width]
      record.bind_ client revision
      add_ result record
      start = handle + 1
      offset += width
  client.check-database-revision revision
  return result

/** Reads a characteristic after checking its discovery record. */
read client/att.Client characteristic/Characteristic -> ByteArray:
  characteristic.check client
  return client.read characteristic.handle --database-revision=client.database-revision

/** Writes a characteristic after checking its discovery record. */
write client/att.Client characteristic/Characteristic value/ByteArray -> none:
  characteristic.check client
  client.write characteristic.handle value --database-revision=client.database-revision

/** Reads a complete value using one checked discovery revision. */
read-long client/att.Client characteristic/Characteristic --limit/int=512
    --timeout/Duration=(Duration --s=30) -> ByteArray:
  characteristic.check client
  return client.read-long characteristic.handle --limit=limit --timeout=timeout
      --database-revision=client.database-revision

/**
Writes a complete value using one checked discovery revision.

A change during preparation cancels the prepared queue. A change during execute
  reports invalidation without retrying: the peer may already have committed.
*/
write-long client/att.Client characteristic/Characteristic value/ByteArray
    --timeout/Duration=(Duration --s=30) -> none:
  characteristic.check client
  client.write-long characteristic.handle value --timeout=timeout
      --database-revision=client.database-revision

/**
Discovers Service Changed and monitors database revisions during $body.

The body takes no argument and should discover application services inside the
  scope. Each change invalidates all discovered records, including outstanding
  discovery requests. Retry discovery after GATT_DATABASE_CHANGED. No background
  consumer task, persistent cache, or per-packet callback is required.
  A peer without Service Changed produces GATT_SERVICE_CHANGED_NOT_FOUND.
*/
with-service-changed client/att.Client [body]:
  changed/Characteristic? := null
  (services client).do: | service/Service |
    if not (uuid-is_ service.uuid 0x1801): continue.do
    (characteristics client service).do: | characteristic/Characteristic |
      if not (uuid-is_ characteristic.uuid 0x2a05): continue.do
      if changed: throw "GATT_DUPLICATE_SERVICE_CHANGED"
      if characteristic.properties != 0x20: throw "GATT_INVALID_SERVICE_CHANGED"
      changed = characteristic
  if not changed: throw "GATT_SERVICE_CHANGED_NOT_FOUND"
  cccd := cccd_ client changed
  changed.check client
  return client.monitor-service-changed changed.handle --cccd=cccd.handle body

uuid-is_ uuid/ByteArray short/int -> bool:
  if uuid.size == 2: return (io.LITTLE-ENDIAN.uint16 uuid 0) == short
  if uuid.size != 16: return false
  return uuid[..12] == #[0xfb, 0x34, 0x9b, 0x5f, 0x80, 0, 0, 0x80, 0, 0x10, 0, 0] and
      (io.LITTLE-ENDIAN.uint32 uuid 12) == short

/** Discovers the CCCD and enables notifications for the duration of $body. */
with-notifications client/att.Client characteristic/Characteristic [body]:
  if characteristic.properties & 0x10 == 0: throw "GATT_NOT_NOTIFIABLE"
  return with-updates_ client characteristic false body

/** Discovers the CCCD and enables indications for the duration of $body. */
with-indications client/att.Client characteristic/Characteristic [body]:
  if characteristic.properties & 0x20 == 0: throw "GATT_NOT_INDICATABLE"
  return with-updates_ client characteristic true body

with-updates_ client/att.Client characteristic/Characteristic indications/bool [body]:
  cccd := cccd_ client characteristic
  characteristic.check client
  return client.subscribe characteristic.handle --cccd=cccd.handle --indications=indications
      --database-revision=client.database-revision
      body

cccd_ client/att.Client characteristic/Characteristic -> Descriptor:
  characteristic.check client
  cccd/Descriptor? := null
  (descriptors client characteristic).do: | descriptor/Descriptor |
    is-cccd := descriptor.uuid == #[2, 0x29] or descriptor.uuid ==
        #[0xfb, 0x34, 0x9b, 0x5f, 0x80, 0, 0, 0x80, 0, 0x10, 0, 0, 2, 0x29, 0, 0]
    if is-cccd:
      if cccd: throw "GATT_DUPLICATE_CCCD"
      cccd = descriptor
  if not cccd: throw "GATT_CCCD_NOT_FOUND"
  return cccd

page_ client/att.Client opcode/int start/int end/int --type/int?=null --revision/int -> ByteArray?:
  range_ start end
  request := ByteArray (type ? 7 : 5)
  request[0] = opcode
  io.LITTLE-ENDIAN.put-uint16 request 1 start
  io.LITTLE-ENDIAN.put-uint16 request 3 end
  if type: io.LITTLE-ENDIAN.put-uint16 request 5 type
  response/ByteArray? := null
  error := catch: response = client.request request --response=(opcode + 1) --database-revision=revision
  if error:
    if error is att.AttributeError and error.code == 0x0a: return null
    throw error
  return response

width_ page/ByteArray short/int long/int -> int:
  if page.size < 2: throw "GATT_INVALID_RESPONSE"
  width := page[1]
  if (width != short and width != long) or page.size <= 2 or
      (page.size - 2) % width != 0:
    throw "GATT_INVALID_RESPONSE"
  return width

range_ start/int end/int -> none:
  if not 1 <= start <= end <= 0xffff: throw "INVALID_ARGUMENT"

add_ result/List value -> none:
  if result.size >= 512: throw "GATT_DISCOVERY_LIMIT"
  result.add value
