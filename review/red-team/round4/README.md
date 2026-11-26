<!-- Copyright (C) 2026 Toit contributors. -->
# Red-team round 4

Independent attack round against the untrusted-container claim
(docs/sandbox-policy.md, verified/spec/SOUNDNESS.md, verified/core/TRUSTED.md),
focused on the surface new since round 3: trusted/untrusted containers sharing
the verified loop with trusted-only unchecked twins (opcodes 104..113) and
builtins (101..103), format 2 as the host default with `--untrusted` selecting
checked compilation, the verdict flag bound by the header CRC, and the shipped
certificate.

See `ATTEMPTS.txt` for every attempt and `../round4` report in the task for the
summary. One LOW finding (F-TIMEINFO, a signed-overflow UB in the C++
`time_info` primitive reachable by a direct untrusted call; release safely
throws OUT_OF_RANGE). No memory-safety, isolation, DoS or policy breach.

## Batteries (wired into `verified/check.sh --tests`, ~100 s total)

Each takes `HOSTRUN` (normal build), `ASANRUN` (build/asan), `HOST32`
(build/host32) and `WORK` from the environment and self-checks.

| Battery | Line | What it does |
|---|---|---|
| `battery-A.sh` | A | splices twins (104..113), builtins (101..103), trusted HALTs and out-of-range opcodes into an untrusted method (assembler) — every one rejected with a named rule; an inconsistent method table (`asm --stale-table`, format note 21) refused at load, untrusted and trusted; since 2026-11-26 (T2) also denied and absent primitives (assembled and in repro/prims.toit): accepted, and the run must print PERMISSION_DENIED / PRIMITIVE_LOOKUP_FAILED on both builds; indices past the VM's table rejected |
| `battery-A-cert.sh` | A | device-path `--verify --require-certificate`: a trusted cert can't make untrusted rules accept twins; corrupt/short/wrong-count certs rejected; another policy's certificate refused (T2, prims-*) |
| `battery-B.sh` | B | certificate structural mutations (magic/version/count/sections/maps) rejected or safe under ASan; pathological programs verify in bounded time, 64 KB body limit enforced |
| `battery-C.sh` | C | 31 word-size-edge programs, host64 output == host32 output |
| `battery-D.sh` | D | 31 adversarial runtime collections driving the builtins and C++ primitives (rebuild_hash_index, array_*, blit, slices) — ASan clean |
| `battery-E.sh` | E | 31 untrusted service-layer attacks on the live system process — it survives, no crash/hang |
| `battery-F.sh` | F | 22 hostile-argument C++ primitive calls — ASan clean except the recorded F-TIMEINFO overflow |

The 2-hour 64/32 differential fuzz is a bulk job, not in `check.sh`:
`/home/flo/work/opentoit-sandbox-artifacts/red-team-4/difffuzz.sh` (log and any
findings under `.../red-team-4/difffuzz/`).

## Layout
- `repro/cedges/`, `repro/dcoll/`, `repro/eattacks/`, `repro/fattacks/`,
  `repro/pathological/` — the generated attack programs.
- `repro/*-results.txt` — recorded verdicts the batteries check against.
- `repro/fields.toit`, `repro/edges.toit`, `repro/num.toit`,
  `repro/timeinfo-overflow.toit` — hand-written bases and the F-TIMEINFO reproducer.
- Generators and bulk output live under
  `/home/flo/work/opentoit-sandbox-artifacts/red-team-4/`.
