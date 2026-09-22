# Local BLE specification references

Implementation reference for USB startup ordering: [Core 6.3, Vol 4 Part B,
sections 2.1–2.4](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core_v6.3/out/en/host-controller-interface/usb-transport-layer.html)
describes separate event and ACL endpoints in legacy USB mode. A
[July 2026 Linux Bluetooth patch report](https://lkml.iu.edu/hypermail/linux/kernel/2607.3/14640.html)
reports ACL preceding Connection Complete on Edimax USB `7392:c611`, matching
our dongle ID. This is evidence for a transport-ordering hypothesis, not proof
that the proposed kernel patch is merged or that every observed failure has
that cause. Our HCI user-channel implementation handles its own bounded hold.

Inspected on 2026-09-07. These four user-provided PDFs satisfy the reference
requirements for starting the BLE host implementation. All allow text extraction;
`pdftotext -layout` completed successfully for each. The Core includes the HCI,
GAP, L2CAP, ATT, GATT, and SMP chapters. This is an inventory and a coverage
check, not a claim that every page or protocol requirement has been reviewed.

The PDFs currently live at the repository root as local reference material.
Record this inventory in source control; keep the PDF binaries and extracted
text out of source commits. Paths below describe this workspace and need not
exist in a fresh checkout.

| File | Edition / document date | Pages | Use |
| --- | --- | ---: | --- |
| `Core_v6.3.pdf` | Core v6.3, 2026-05-05 | 3,924 | HCI and host protocol definitions, state machines, timing and security |
| `CSS_v15.pdf` | Core Supplement v15, 2026-05-05 | 47 | Advertising data formats and supplemental definitions |
| `Assigned_Numbers.pdf` | 2026-09-04 | 445 | Protocol identifiers, AD types, UUIDs and assigned constants |
| `GATT_Specification_Supplement.pdf` | 2026-02-05 | 207 | Standard characteristic/descriptor value definitions beyond the Core |

SHA-256 checksums:

```text
e210fb8f697fca2b970001d35f8c9c7c8f836190550b7fd29d2915a1c8596d60  Core_v6.3.pdf
43226d4aabfbd7271fecf2be077ce3dbed795892e14e06005e6d8d9f5bb3fed8  CSS_v15.pdf
20d9b88505806966cfa42a387b5db0f6bd96b77a0a1f929154e0eac7f50441ea  Assigned_Numbers.pdf
1819c5b938832adc0fe17528e238126e05e1f45e7c4f6d71aad6086a49f5a574  GATT_Specification_Supplement.pdf
```

## Reading map

| Work | Primary reference |
| --- | --- |
| HCI initialization, commands/events, ACL flow control | Core Vol 4 Part E |
| A future H4/UART transport | Core Vol 4 Part A |
| LE fixed channels, signaling, segmentation/reassembly | Core Vol 3 Part A, plus HCI ACL fragmentation rules |
| Discovery, roles, connection/security policy | Core Vol 3 Part C |
| Attribute requests, responses, errors, timing | Core Vol 3 Part F |
| Service discovery, CCCDs, notifications/indications | Core Vol 3 Part G |
| Pairing, key distribution, cryptographic functions | Core Vol 3 Part H |
| Advertising structures | Core Supplement Part A and Assigned Numbers AD types |
| Standard attribute values | GATT Supplement, with Core-defined descriptors in Core Vol 3 Part G |

Spot checks located the LE scan-enable command at PDF page 2528, Host Number
Of Completed Packets at page 2109, and the HCI functional specification beginning
at page 1802. Assigned Numbers contains the CCCD UUID `0x2902` at page 82.
The Core Supplement includes UUID, local-name, flags, and manufacturer-data
formats. The GATT Supplement includes standard value definitions such as Battery
Level. Page numbers here are one-based PDF pages, not extraction line numbers;
implementation comments should cite volume/part/section for stability.

Extracted copies were placed in `/tmp/<PDF-stem>-ble-reference.txt`. Regenerate
them as needed with `pdftotext -layout`; `/tmp` is not durable project storage.
Retain the original PDFs for diagrams/tables whose text extraction loses layout.

## Later validation material

These documents are enough to begin. During protocol hardening, consult the
applicable HCI, L2CAP, ATT/GATT, GAP, and Security Manager test suites and
implementation conformance statements, along with the relevant TCRL. They are
listed on the [official Core 6.3 page](https://www.bluetooth.com/specifications/specs/core-specification-6-3/).
The three suites supplied on 2026-09-08 are inventoried below. ICS, IXIT and
the applicable TCRL configuration still need a release-specific review.

Check applicable corrections as features are implemented and again before
release. A supplied PDF/checksum pins our reference; it does not establish
that no later correction applies. Core 6.3 is a reference edition, not an
implicit claim to support every feature or an automatic conformance target.

### Test-suite retrieval check (2026-09-08)

Rechecked the official Core 6.3 page. It links
[L2CAP TS](https://files.bluetooth.com/download/l2cap-ts-p38-pdf/),
[SM TS](https://files.bluetooth.com/download/sm-ts-p26-pdf/) and
[GATT TS](https://files.bluetooth.com/download/gatt-ts-p26-pdf/).
The ATT and GATT rows currently point to the same GATT download link. The page
also lists ICS, IXIT and TCRL material. No separate correction entry was visible
in the returned document list; that observation does not establish that no
applicable correction exists.

The browser reached download landing pages but failed fetching the PDF links.
Direct public-endpoint requests returned HTTP 403 for all three suites. No PDFs
were obtained through those endpoints. Retrieval results are in
build/ble-conformance-references/download-results.json. The user subsequently
supplied the newer revisions inventoried below; this resolves the missing-file
issue. Current local regressions must not be labeled official-suite passes.

### Supplied test suites (2026-09-08)

All three allow text extraction and state revision date **2026-05-05**, published
in **TCRL.pkg103**, on their title pages. The revisions below are read from the
PDFs, not inferred from the older download URLs above.

| File / actual revision | Pages | Initial review |
| --- | ---: | --- |
| `GATT.TS.p30.pdf` / GATT.TS.p30 | 292 | Client/server MTU procedures and ATT bearer applicability |
| `SM.TS.p30.pdf` / SM.TS.p30 | 96 | Secure Connections role coverage, Just Works and invalid public keys |
| `L2CAP.TS.p42.pdf` / L2CAP.TS.p42 | 367 | LE connection parameter updates and unknown-command rejection |

```text
3588a2184e0f380a5e64336f3d178cb6ed4c12736b64cb6f94dafae452ff479a  GATT.TS.p30.pdf
4ec918ec136912a0256197b94657a1eb70126e752802863434c191d3ac94f7e8  SM.TS.p30.pdf
b1126cc5358daf2cd183de6dbedaebc289a696fb2b08bee2970fec3056b6ec0c  L2CAP.TS.p42.pdf
```

These satisfy the immediate need for L2CAP, SM and GATT test definitions.
Reading selected procedures is not a complete applicability audit. See the
[initial conformance map and upstream test review](conformance-tests.md) for
concrete starting points, evidence limits and next acceptance criteria.
