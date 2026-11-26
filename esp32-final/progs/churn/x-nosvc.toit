// Copyright (C) 2026 Toit contributors.

// Opens a client of a service nobody provides (throws "Cannot find
// service"), as the soak workers did when the provider did not accept
// sandboxed clients.

import system.services

interface NoService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
      --major=1
      --minor=0

class NoServiceClient extends services.ServiceClient:
  constructor:
    super NoService.SELECTOR

main:
  client := NoServiceClient
  client.open
