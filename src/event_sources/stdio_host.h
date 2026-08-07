// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#pragma once

#include "../top.h"

#if !defined(TOIT_FREERTOS)

#include "../os.h"
#include "../resource.h"

namespace toit {

class StdinEventSource : public LazyEventSource, public Thread {
 public:
  static const int BUFFER_SIZE = 4 * KB;

  static StdinEventSource* instance() { return instance_; }

  StdinEventSource();
  ~StdinEventSource() override;

  int data_size(int* error);
  int read(uint8* destination, int size, int* error);

 protected:
  bool start() override;
  void stop() override;

 private:
  void entry() override;
  void on_register_resource(Locker& locker, Resource* resource) override;
  void on_unregister_resource(Locker& locker, Resource* resource) override;

  static StdinEventSource* instance_;

  ConditionVariable* changed_;
  uint8 buffer_[BUFFER_SIZE];
  int size_ = -1;
  int error_ = 0;
  bool stopping_ = false;
};

}  // namespace toit

#endif  // !defined(TOIT_FREERTOS)
