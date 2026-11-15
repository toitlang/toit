// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import ...flash.registry show FlashRegistry
import ..shared.storage-provider show FlashRegistryStorageServiceProvider

class StorageServiceProviderZephyr extends FlashRegistryStorageServiceProvider:
  constructor registry/FlashRegistry:
    super "system/storage/zephyr" registry
