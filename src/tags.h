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

#define NON_BLE_RESOURCE_CLASSES_DO(fn) \
  fn(IntResource)                       \
  fn(LookupResult)                      \
  fn(LwipSocket)                        \
  fn(Timer)                             \
  fn(Peer)                              \
  fn(UdpSocket)                         \
  fn(WifiEvents)                        \
  fn(WifiIpEvents)                      \
  fn(EthernetEvents)                    \
  fn(EthernetIpEvents)                  \
  fn(SpiDevice)                         \
  fn(X509Certificate)                   \
  fn(AesContext)                        \
  fn(FlashRegion)                       \
  fn(AesCbcContext)                     \
  fn(SslSession)                        \
  fn(Sha1)                              \
  fn(Blake2s)                           \
  fn(Sha)                               \
  fn(Siphash)                           \
  fn(Adler32)                           \
  fn(ZlibRle)                           \
  fn(Zlib)                              \
  fn(UartResource)                      \
  fn(GpioResource)                      \
  fn(GpioPinResource)                   \
  fn(GpioChipResource)                  \
  fn(I2cBusResource)                    \
  fn(I2cDeviceResource)                 \
  fn(I2sResource)                       \
  fn(SpiResource)                       \
  fn(AdcResource)                       \
  fn(DacResource)                       \
  fn(PcntUnitResource)                  \
  fn(PcntChannelResource)               \
  fn(PwmResource)                       \
  fn(RmtResource)                       \
  fn(RmtSyncManagerResource)            \
  fn(RmtPatternEncoderResource)         \
  fn(PmLockResource)                    \
  fn(Directory)                         \
  fn(UdpSocketResource)                 \
  fn(TcpSocketResource)                 \
  fn(TcpServerSocketResource)           \
  fn(SubprocessResource)                \
  fn(PipeResource)                      \
  fn(AeadContext)                       \
  fn(TlsHandshakeToken)                 \
  fn(EspNowResource)                    \
  fn(MbedTlsSocket)                     \
  fn(RsaKey)                            

// When adding a class make sure that they all are subclasses of
// the BleCallbackResource. If it isn't update the Min/MaxTag below.
// Similarly, check, whether the new class is a read-write class.
#define BLE_CLASSES_DO(fn)              \
  fn(BleAdapterResource)                \
  fn(BleCentralManagerResource)         \
  fn(BlePeripheralManagerResource)      \
  fn(BleRemoteDeviceResource)           \
  fn(BleServiceResource)                \

#define BLE_READ_WRITE_CLASSES_DO(fn)   \
  fn(BleCharacteristicResource)         \
  fn(BleDescriptorResource)             \

#define RESOURCE_GROUP_CLASSES_DO(fn)   \
  fn(SimpleResourceGroup)               \
  fn(DacResourceGroup)                  \
  fn(GpioResourceGroup)                 \
  fn(I2cResourceGroup)                  \
  fn(I2sResourceGroup)                  \
  fn(SpiResourceGroup)                  \
  fn(SpiFlashResourceGroup)             \
  fn(SignalResourceGroup)               \
  fn(SocketResourceGroup)               \
  fn(TcpResourceGroup)                  \
  fn(TimerResourceGroup)                \
  fn(RpcResourceGroup)                  \
  fn(MbedTlsResourceGroup)              \
  fn(UdpResourceGroup)                  \
  fn(UartResourceGroup)                 \
  fn(RmtResourceGroup)                  \
  fn(WifiResourceGroup)                 \
  fn(EthernetResourceGroup)             \
  fn(BleResourceGroup)                  \
  fn(BleServerConfigGroup)              \
  fn(PipeResourceGroup)                 \
  fn(SubprocessResourceGroup)           \
  fn(PersistentResourceGroup)           \
  fn(X509ResourceGroup)                 \
  fn(PcntUnitResourceGroup)             \
  fn(PwmResourceGroup)                  \
  fn(TouchResourceGroup)                \
  fn(EspNowResourceGroup)               \

#define MAKE_ENUM(name)                 \
  name##Tag,                            \

enum StructTag {
  RawByteTag = 0,
  NullStructTag = 1,
  MappedFileTag = 2,

  // Resource subclasses.
  ResourceMinTag,
  NON_BLE_RESOURCE_CLASSES_DO(MAKE_ENUM)
  BleResourceMinTag,
  BleCallbackResourceMinTag,
  BLE_CLASSES_DO(MAKE_ENUM)
  BleReadWriteElementMinTag,
  BLE_READ_WRITE_CLASSES_DO(MAKE_ENUM)
  BleReadWriteElementMaxTag,
  BleCallbackResourceMaxTag,
  BleResourceMaxTag,
  ResourceMaxTag,

  // ResourceGroup subclasses.
  ResourceGroupMinTag,
  RESOURCE_GROUP_CLASSES_DO(MAKE_ENUM)
  ResourceGroupMaxTag,

  // Misc.
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
