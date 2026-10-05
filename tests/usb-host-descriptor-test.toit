// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import usb.host as usb

// Configuration descriptor of a CP2102: one vendor interface with a bulk
// IN and a bulk OUT endpoint.
CP2102 ::= #[
  0x09, 0x02, 0x20, 0x00, 0x01, 0x01, 0x00, 0x80, 0x32,
  0x09, 0x04, 0x00, 0x00, 0x02, 0xff, 0x00, 0x00, 0x02,
  0x07, 0x05, 0x81, 0x02, 0x40, 0x00, 0x00,
  0x07, 0x05, 0x01, 0x02, 0x40, 0x00, 0x00,
]

// Configuration descriptor of a CH340: an interrupt IN endpoint plus bulk
// IN and OUT.
CH340 ::= #[
  0x09, 0x02, 0x27, 0x00, 0x01, 0x01, 0x00, 0x80, 0x31,
  0x09, 0x04, 0x00, 0x00, 0x03, 0xff, 0x01, 0x02, 0x00,
  0x07, 0x05, 0x82, 0x02, 0x20, 0x00, 0x00,
  0x07, 0x05, 0x02, 0x02, 0x20, 0x00, 0x00,
  0x07, 0x05, 0x81, 0x03, 0x08, 0x00, 0x01,
]

// Configuration descriptor of a CDC-ACM device: an interface association,
// a communication interface with class-specific descriptors and an
// interrupt endpoint, and a data interface with bulk endpoints.
CDC-ACM ::= #[
  0x09, 0x02, 0x4b, 0x00, 0x02, 0x01, 0x00, 0xc0, 0x32,
  0x08, 0x0b, 0x00, 0x02, 0x02, 0x02, 0x00, 0x00,
  0x09, 0x04, 0x00, 0x00, 0x01, 0x02, 0x02, 0x00, 0x00,
  0x05, 0x24, 0x00, 0x10, 0x01,
  0x05, 0x24, 0x01, 0x00, 0x01,
  0x04, 0x24, 0x02, 0x02,
  0x05, 0x24, 0x06, 0x00, 0x01,
  0x07, 0x05, 0x82, 0x03, 0x08, 0x00, 0x10,
  0x09, 0x04, 0x01, 0x00, 0x02, 0x0a, 0x00, 0x00, 0x00,
  0x07, 0x05, 0x01, 0x02, 0x40, 0x00, 0x00,
  0x07, 0x05, 0x81, 0x02, 0x40, 0x00, 0x00,
]

main:
  test-cp2102
  test-ch340
  test-cdc-acm
  test-alternates-and-class-descriptors
  test-malformed
  test-strings

test-cp2102:
  interfaces := usb.parse-interfaces_ CP2102
  expect-equals 1 interfaces.size
  descriptor/usb.InterfaceDescriptor := interfaces[0]
  expect-equals 0 descriptor.number
  expect-equals 0 descriptor.alternate
  expect-equals 0xff descriptor.class-code
  expect-equals 2 descriptor.endpoints.size
  in/usb.EndpointDescriptor := descriptor.endpoints[0]
  out/usb.EndpointDescriptor := descriptor.endpoints[1]
  expect-equals 0x81 in.address
  expect in.is-in
  expect in.is-bulk
  expect-equals 64 in.max-packet-size
  expect-equals 0x01 out.address
  expect out.is-out
  expect out.is-bulk

test-ch340:
  interfaces := usb.parse-interfaces_ CH340
  expect-equals 1 interfaces.size
  endpoints := interfaces[0].endpoints
  expect-equals 3 endpoints.size
  interrupt/usb.EndpointDescriptor := endpoints[2]
  expect interrupt.is-interrupt
  expect interrupt.is-in
  expect-not interrupt.is-bulk
  expect-equals 8 interrupt.max-packet-size
  expect-equals 1 interrupt.interval
  expect-equals 32 endpoints[0].max-packet-size

test-cdc-acm:
  interfaces := usb.parse-interfaces_ CDC-ACM
  expect-equals 2 interfaces.size
  comm/usb.InterfaceDescriptor := interfaces[0]
  data/usb.InterfaceDescriptor := interfaces[1]
  expect-equals 0 comm.number
  expect-equals 0x02 comm.class-code
  expect-equals 0x02 comm.subclass
  expect-equals 0x00 comm.protocol
  expect-equals 1 comm.endpoints.size
  notify/usb.EndpointDescriptor := comm.endpoints[0]
  expect-equals 0x82 notify.address
  expect notify.is-interrupt
  expect-equals usb.EndpointDescriptor.TYPE-INTERRUPT notify.type
  expect-equals 8 notify.max-packet-size
  expect-equals 16 notify.interval
  expect-equals 1 data.number
  expect-equals 0x0a data.class-code
  expect-equals 2 data.endpoints.size
  expect data.endpoints[0].is-out
  expect data.endpoints[1].is-in
  expect-equals "interface 1 alt 0 class 0a/00/00 endpoints [ep 01 type 2 mps 64, ep 81 type 2 mps 64]" data.stringify

test-strings:
  expect-null (usb.decode-string_ null)
  expect-equals "" (usb.decode-string_ #[])
  expect-equals "CP2102" (usb.decode-string_ #['C', 0, 'P', 0, '2', 0, '1', 0, '0', 0, '2', 0])

test-alternates-and-class-descriptors:
  bytes := #[
    0x09, 0x02, 0x00, 0x00, 0x02, 0x01, 0x00, 0x80, 0x32,
    // Interface 0, alternate 0, no endpoints.
    0x09, 0x04, 0x00, 0x00, 0x00, 0x02, 0x02, 0x01, 0x00,
    // Class-specific (CDC header) descriptor, skipped.
    0x05, 0x24, 0x00, 0x10, 0x01,
    // Interface 0, alternate 1, one high-speed bulk endpoint with extra
    // transaction bits set.
    0x09, 0x04, 0x00, 0x01, 0x01, 0x02, 0x02, 0x01, 0x00,
    0x07, 0x05, 0x83, 0x02, 0x00, 0x1a, 0x00,
  ]
  interfaces := usb.parse-interfaces_ bytes
  expect-equals 2 interfaces.size
  expect-equals 0 interfaces[0].alternate
  expect-equals 0 interfaces[0].endpoints.size
  expect-equals 1 interfaces[1].alternate
  expect-equals 1 interfaces[1].endpoints.size
  expect-equals 0x200 interfaces[1].endpoints[0].max-packet-size

test-malformed:
  expect-equals 0 (usb.parse-interfaces_ #[]).size
  expect-equals 0 (usb.parse-interfaces_ #[0x09]).size
  // A zero length would loop for ever if not caught.
  expect-equals 0 (usb.parse-interfaces_ #[0x00, 0x02, 0x00, 0x00]).size
  // Truncated: the endpoint descriptor claims more bytes than there are.
  truncated := CP2102[..CP2102.size - 3]
  interfaces := usb.parse-interfaces_ truncated
  expect-equals 1 interfaces.size
  expect-equals 1 interfaces[0].endpoints.size
  // A too-short interface descriptor is skipped, and so are the endpoints
  // that follow it, since they have no interface.
  short := #[
    0x05, 0x04, 0x00, 0x00, 0x01,
    0x07, 0x05, 0x81, 0x02, 0x40, 0x00, 0x00,
  ]
  expect-equals 0 (usb.parse-interfaces_ short).size
  // ... also when a valid interface came before: its endpoints must not
  // land on that one.
  interfaces = usb.parse-interfaces_ (CP2102 + short)
  expect-equals 1 interfaces.size
  expect-equals 2 interfaces[0].endpoints.size
  // A one-byte descriptor stops the parse too.
  expect-equals 1 (usb.parse-interfaces_ (CP2102 + #[0x01, 0x05])).size
