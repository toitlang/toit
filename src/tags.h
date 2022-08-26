// Copyright (C) 2018 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#pragma once

namespace toit {

#define NON_TLS_RESOURCE_CLASSES_DO(fn) \
  fn(IntResource)                       \
  fn(LookupResult)                      \
  fn(LwIPSocket)                        \
  fn(Timer)                             \
  fn(Peer)                              \
  fn(UDPSocket)                         \
  fn(WifiEvents)                        \
  fn(WifiIpEvents)                      \
  fn(EthernetEvents)                    \
  fn(EthernetIpEvents)                  \
  fn(SPIDevice)                         \
  fn(X509Certificate)                   \
  fn(AesContext)                        \
  fn(SslSession)                        \
  fn(Sha1)                              \
  fn(Sha256)                            \
  fn(Siphash)                           \
  fn(Adler32)                           \
  fn(ZlibRle)                           \
  fn(UARTResource)                      \
  fn(GPIOResource)                      \
  fn(I2SResource)                       \
  fn(AdcResource)                       \
  fn(DacResource)                       \
  fn(PcntUnitResource)                  \
  fn(PWMResource)                       \
  fn(RMTResource)                       \
  fn(GAPResource)                       \
  fn(GATTResource)                      \
  fn(BLEServerServiceResource)          \
  fn(BLEServerCharacteristicResource)   \
  fn(Directory)                         \

#define TLS_CLASSES_DO(fn)              \
  fn(MbedTLSSocket)                     \

#define RESOURCE_GROUP_CLASSES_DO(fn)   \
  fn(SimpleResourceGroup)               \
  fn(DacResourceGroup)                  \
  fn(GPIOResourceGroup)                 \
  fn(I2CResourceGroup)                  \
  fn(I2SResourceGroup)                  \
  fn(SPIResourceGroup)                  \
  fn(SignalResourceGroup)               \
  fn(SocketResourceGroup)               \
  fn(TCPResourceGroup)                  \
  fn(TimerResourceGroup)                \
  fn(RpcResourceGroup)                  \
  fn(MbedTLSResourceGroup)              \
  fn(UDPResourceGroup)                  \
  fn(UARTResourceGroup)                 \
  fn(RMTResourceGroup)                  \
  fn(WifiResourceGroup)                 \
  fn(EthernetResourceGroup)             \
  fn(BLEResourceGroup)                  \
  fn(BLEServerConfigGroup)              \
  fn(PipeResourceGroup)                 \
  fn(SubprocessResourceGroup)           \
  fn(PersistentResourceGroup)           \
  fn(X509ResourceGroup)                 \
  fn(PcntChannelResourceGroup)          \
  fn(PcntUnitResourceGroup)             \
  fn(PWMResourceGroup)                  \
  fn(TouchResourceGroup)                \

#define MAKE_ENUM(name)                 \
  name##Tag,                            \

enum StructTag {
  RawByteTag = 0,
  NullStructTag = 1,
  MappedFileTag = 2,

  // Resource subclasses.
  ResourceMinTag,
  NON_TLS_RESOURCE_CLASSES_DO(MAKE_ENUM)
  BaseTLSSocketMinTag,
  TLS_CLASSES_DO(MAKE_ENUM)
  BaseTLSSocketMaxTag,
  ResourceMaxTag,

  // ResourceGroup subclasses.
  ResourceGroupMinTag,
  RESOURCE_GROUP_CLASSES_DO(MAKE_ENUM)
  ResourceGroupMaxTag,

  // Misc.
  LeakyDirectoryTag,
  FontTag,
  ImageOutputStreamTag,
  ChannelTag
};

#undef MAKE_ENUM

// For leaf classes, define the tag and the single-item range.
#define TAG(x)                           \
  static const int tag_min = x##Tag;     \
  static const int tag_max = x##Tag;     \
  static const int tag     = x##Tag      \

// For abstract base classes, define the range of the subclasses' tags.
#define TAGS(x)                          \
  static const int tag_min = x##MinTag;  \
  static const int tag_max = x##MaxTag   \

}
