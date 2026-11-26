// Copyright (C) 2026 Toit contributors.

// The service of the soak test: the controller (soak.toit) provides it,
// the worker containers (soak-worker.toit) call it.

import system.services

interface SoakService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="3f1e9c2a-6b7d-4e8f-a1b2-c3d4e5f60718"
      --major=1
      --minor=0

  echo value/any -> any
  static ECHO-INDEX ::= 0

  add a/int b/int -> int
  static ADD-INDEX ::= 1

  // [worker, iterations, pid, errors].
  report stats/List -> none
  static REPORT-INDEX ::= 2

class SoakServiceClient extends services.ServiceClient implements SoakService:
  static SELECTOR ::= SoakService.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  echo value/any -> any:
    return invoke_ SoakService.ECHO-INDEX value

  add a/int b/int -> int:
    return invoke_ SoakService.ADD-INDEX [a, b]

  report stats/List -> none:
    invoke_ SoakService.REPORT-INDEX stats
