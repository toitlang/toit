// Copyright (C) 2026 Toit contributors.

// Service provider container (started by the suite).

import .echo-service

main:
  provider := EchoServiceProvider
  provider.install
  print "PROVIDER installed"
