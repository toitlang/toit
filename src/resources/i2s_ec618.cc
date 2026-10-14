// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only. See LICENSE in the top level directory.

#include "../top.h"

#ifdef TOIT_EC618

#include "../event_sources/uart_ec618.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource_pool.h"
#include "pad_table_ec618.h"
#include "i2s_clock_ec618.h"
#include "i2s_buffer_ec618.h"
#include "i2s_state_ec618.h"

extern "C" {
  #include "clock.h"
  #include "dma.h"
  #include "driver_gpio.h"
  #include "slpman.h"
  #include "task.h"
}

namespace toit {

// Unpacked FIFO words with generated or external BCLK/WS. Generated
// clocks require the fractional-clock exports in the matching base image.
static constexpr int kRead = 1;
static constexpr int kWrite = 2;
static constexpr int kError = 4;
static ResourcePool<int, -1> controllers(0, 1);
static uint32_t next_generation = 0;
static uint8_t sleep_handle = 0xff;
static int powered_controllers = 0;
static I2S_TypeDef* const regs[] = {I2S0, I2S1};
static const ClockId_e pclk[] = {PCLK_I2S0, PCLK_I2S1};
static const ClockId_e fclk[] = {FCLK_I2S0, FCLK_I2S1};
static const ClockResetId_e reset_pclk[] = {RST_PCLK_I2S0, RST_PCLK_I2S1};
static const ClockResetId_e reset_fclk[] = {RST_FCLK_I2S0, RST_FCLK_I2S1};
// Order matches the native create/configure arguments: TX, RX, MCLK, SCK, WS.
static constexpr int routes[2][5] = {{38, 37, 39, 35, 36}, {22, 21, 18, 19, 20}};
static const FracDivOutClkId_e mclk_output[] = {FRACDIV0_OUT0, FRACDIV1_OUT0};
static const FracDivOutClkId_e bclk_output[] = {FRACDIV0_OUT1, FRACDIV1_OUT1};
static const MclkId_e mclk_id[] = {MCLK0, MCLK1};
static const BclkId_e bclk_id[] = {BCLK0, BCLK1};
static const MclkSrc_e mclk_source[] = {MCLK_SRC_FRACDIV0_OUT0, MCLK_SRC_FRACDIV1_OUT0};
static const BclkSrc_e bclk_source[] = {BCLK_SRC_FRACDIV0_OUT1, BCLK_SRC_FRACDIV1_OUT1};
// GPR_setFracDivConfig writes BOTH dividers. Retain the other controller's
// setting instead of zeroing it as the vendor's single-controller example
// does. I2S owns these dividers; a future CSPI driver must share that ownership.
static FracDivConfig_t clock_config = {FRACDIC_ROOT_CLK_408M, 1, 0, 1, 0};

class I2sResource;
static I2sResource* owners[2] = {null, null};
static void dma0_rx(uint32_t event);
static void dma0_tx(uint32_t event);
static void dma1_rx(uint32_t event);
static void dma1_tx(uint32_t event);

// Each channel has two DMA blocks and a separate software ring. A DMA callback
// copies the completed block before DMA wraps back to it. No Toit heap pointer
// escapes a primitive, and slow readers/writers cannot stall the hardware.
struct I2sPipe {
  static constexpr unsigned kBlockWords = I2sBufferCapacity::kBlockWords;
  uint32_t blocks[2][kBlockWords];
  uint8_t* ring = null;
  I2sRingFormat ring_format;
  unsigned ring_words = 0;
  unsigned ring_capacity_bytes = 0;
  uint8_t descriptor_storage[2 * sizeof(DmaDescriptor_t) + 15];
  int channel = -1;
  unsigned block = 0;
  unsigned head = 0;
  unsigned tail = 0;
  unsigned count = 0;
  volatile uint32_t losses = 0;
  bool padded[2] = {false, false};

  DmaDescriptor_t* descriptors() {
    return reinterpret_cast<DmaDescriptor_t*>((reinterpret_cast<uword>(descriptor_storage) + 15) & ~uword(15));
  }

  bool open(int id, bool tx) {
    channel = DMA_openChannel(DMA_INSTANCE_MP);
    if (channel < 0) return false;
    DMA_setChannelRequestSource(DMA_INSTANCE_MP, channel,
        id == 0 ? (tx ? DMA_REQUEST_I2S0_TX : DMA_REQUEST_I2S0_RX)
                : (tx ? DMA_REQUEST_I2S1_TX : DMA_REQUEST_I2S1_RX));
    DMA_rigisterChannelCallback(DMA_INSTANCE_MP, channel,
        id == 0 ? (tx ? dma0_tx : dma0_rx) : (tx ? dma1_tx : dma1_rx));
    return true;
  }

  void stop() {
    if (channel < 0) return;
    // Never free or reuse memory while DMA can still access it.
    if (DMA_stopChannel(DMA_INSTANCE_MP, channel, true) != 0) {
      FATAL("I2S DMA channel failed to stop");
    }
  }

  ~I2sPipe() {
    if (channel >= 0) {
      stop();
      DMA_rigisterChannelCallback(DMA_INSTANCE_MP, channel, null);
      DMA_closeChannel(DMA_INSTANCE_MP, channel);
    }
    free(ring);
  }

  bool reserve(unsigned bytes) {
    if (ring_capacity_bytes >= bytes) return true;
    // No DMA descriptor points into the software ring. Configuration only
    // grows it while stopped, and realloc preserves every queued word even
    // if the other direction subsequently fails to grow.
    auto replacement = static_cast<uint8_t*>(realloc(ring, bytes));
    if (!replacement) return false;
    ring = replacement;
    ring_capacity_bytes = bytes;
    return true;
  }

  FORCE_INLINE uint32_t pop() {
    uint32_t result = ring_format.load(ring, tail);
    if (++tail == ring_words) tail = 0;
    count--;
    return result;
  }

  FORCE_INLINE void push(uint32_t value) {
    ring_format.store(ring, head, value);
    if (++head == ring_words) head = 0;
    count++;
  }

  void fill(unsigned index) {
    bool underflow = false;
    for (unsigned i = 0; i < kBlockWords; i++) {
      if (count == 0) {
        blocks[index][i] = 0;
        underflow = true;
      } else {
        blocks[index][i] = pop();
      }
    }
    padded[index] = underflow;
  }

  void prepare(int id, bool tx) {
    block = 0;
    if (tx) {
      // Seed a complete stereo frame before enabling the transmitter. Starting
      // with an empty FIFO emits the previous run's left sample before DMA
      // supplies the first frame, even when external clocks start later.
      bool prime_underflow = count < 2;
      for (unsigned i = 0; i < 2; i++) {
        regs[id]->TFIFO = count == 0 ? 0 : pop();
      }
      fill(0);
      fill(1);
      padded[0] |= prime_underflow;
    } else {
      head = tail = count = 0;
    }
    auto desc = descriptors();
    for (int i = 0; i < 2; i++) {
      DmaTransferConfig_t config = {
        tx ? static_cast<void*>(blocks[i]) : const_cast<uint32_t*>(&regs[id]->RFIFO),
        tx ? const_cast<uint32_t*>(&regs[id]->TFIFO) : static_cast<void*>(blocks[i]),
        tx ? DMA_FLOW_CONTROL_TARGET : DMA_FLOW_CONTROL_SOURCE,
        tx ? DMA_ADDRESS_INCREMENT_SOURCE : DMA_ADDRESS_INCREMENT_TARGET,
        DMA_DATA_WIDTH_FOUR_BYTES,
        DMA_BURST_8_BYTES,
        sizeof(blocks[i]),
      };
      // Keep START interrupts disabled. The vendor MPDMA handler clears the
      // status snapshot, then dispatches START instead of END if both are
      // pending. Losing END would desynchronize our alternating block index.
      DmaExtraConfig_t extra = {&desc[1 - i], false, false, true};
      DMA_buildDescriptor(&desc[i], &config, &extra);
    }
    DMA_loadChannelDescriptorAndRun(DMA_INSTANCE_MP, channel, desc);
  }

  void completed(bool tx) {
    if (tx) {
      // Count padding only after that block reaches the peripheral, not when
      // preparing a future block (or starting without an external clock).
      if (padded[block]) losses++;
      fill(block);
    } else {
      if (ring_words - count < kBlockWords) {
        // Drop one complete stereo-aligned block, preserving old unread data.
        losses++;
      } else {
        for (unsigned i = 0; i < kBlockWords; i++) push(blocks[block][i]);
      }
    }
    block ^= 1;
  }
};

class I2sResource : public EventResource {
 public:
  TAG(I2sResource);

  I2sResource(ResourceGroup* group, int id, bool master, bool mclk)
    : EventResource(group, Event::i2s_type(id)), id_(id), master_(master), mclk_(mclk) {}

  ~I2sResource() override {
    stop();
    delete rx_;
    delete tx_;
    owners[id_] = null;
    if (powered_) {
      regs[id_]->INTCTL = 0;
      CLOCK_clockDisable(fclk[id_]);
      CLOCK_setClockSrc(fclk[id_], id_ == 0 ? FCLK_I2S0_SEL_26M : FCLK_I2S1_SEL_26M);
      GPR_clockDisable(pclk[id_]);
      if (--powered_controllers == 0) slpManPlatVoteEnableSleep(sleep_handle, SLP_SLP1_STATE);
    }
    pads_.release();
    controllers.put(id_);
  }

  bool initialize() {
    // High-rate rig tests fail with the default 26 MHz functional clock.
    // Use 51.2 MHz and the managed API to enable its parent clock tree.
    if (powered_controllers++ == 0) slpManPlatVoteDisableSleep(sleep_handle, SLP_SLP1_STATE);
    GPR_clockEnable(pclk[id_]);
    Defer rollback { [&] {
      if (!powered_) {
        GPR_clockDisable(pclk[id_]);
        if (--powered_controllers == 0) slpManPlatVoteEnableSleep(sleep_handle, SLP_SLP1_STATE);
      }
    } };
    if (CLOCK_setClockSrc(fclk[id_], id_ == 0 ? FCLK_I2S0_SEL_51M : FCLK_I2S1_SEL_51M) != 0) return false;
    if (CLOCK_clockEnable(fclk[id_]) != 0) {
      CLOCK_setClockSrc(fclk[id_], id_ == 0 ? FCLK_I2S0_SEL_26M : FCLK_I2S1_SEL_26M);
      return false;
    }
    GPR_swReset(reset_pclk[id_]);
    GPR_swReset(reset_fclk[id_]);
    regs[id_]->INTCTL = 0;
    regs[id_]->I2SCTL = 0;
    regs[id_]->DFMT = I2S_DFMT_SLAVE_MODE_EN_Msk;
    // Gate generated clocks before routing any pins, including after reuse.
    disable_clocks();
    powered_ = true;
    owners[id_] = this;
    return true;
  }

  bool configure(unsigned words, int bits, int format, int slots_in, int slots_out,
                 bool invert_sck, bool invert_ws, const I2sClockPlan& plan) {
    // Reserve both directions before changing the logical configuration.
    // Successful growth may be retained if the second allocation fails, but
    // the old format, indexes and queued data remain intact for retry/use.
    I2sRingFormat ring_format(bits);
    unsigned bytes = words * ring_format.word_bytes();
    if (tx_ && !tx_->reserve(bytes)) return false;
    if (rx_ && !rx_->reserve(bytes)) return false;
    // Reuse larger allocations on shrink to avoid fragmenting the native
    // heap and needing two replacement rings for every rate change.
    if (tx_) {
      tx_->ring_words = words;
      tx_->ring_format = ring_format;
    }
    if (rx_) {
      rx_->ring_words = words;
      rx_->ring_format = ring_format;
    }
    clock_plan_ = plan;
    input_format_ = I2sBufferFormat(bits, slots_in);
    output_format_ = I2sBufferFormat(bits, slots_out);
    regs[id_]->DFMT = (master_ ? 0 : I2S_DFMT_SLAVE_MODE_EN_Msk) | I2S_DFMT_ENDIAN_MODE_Msk
        | ((bits - 1) << I2S_DFMT_SLOT_SIZE_Pos)
        | ((bits - 1) << I2S_DFMT_WORD_SIZE_Pos)
        | ((format == 1 ? 0 : 1) << I2S_DFMT_DATA_DLY_Pos);
    regs[id_]->SLOTCTL = 3 | (1 << I2S_SLOTCTL_SLOT_NUM_Pos);
    // Philips/MSB left slots begin on falling WS, as in the vendor HAL's
    // fsPolarity=1 configuration. PCM-short begins on the rising pulse.
    bool falling_ws = (format != 2) != invert_ws;
    regs[id_]->CLKCTL = (invert_sck ? 0 : I2S_CLKCTL_BCLK_POLARITY_Msk)
        | (falling_ws ? I2S_CLKCTL_FS_POLARITY_Msk : 0)
        | ((format == 2 ? 0 : bits - 1) << I2S_CLKCTL_FS_WIDTH_Pos);
    // Two 32-bit FIFO words per DMA burst, no sample packing in the FIFO.
    dma_control_ = (31 << I2S_DMA_CTRL_DMA_WORK_WAIT_CYCLE_Pos)
        | (1 << I2S_DMA_CTRL_RX_DMA_BURST_SIZE_SUB1_Pos)
        | (1 << I2S_DMA_CTRL_TX_DMA_BURST_SIZE_SUB1_Pos)
        | (2 << I2S_DMA_CTRL_RX_DMA_THRESHOLD_Pos)
        | (14 << I2S_DMA_CTRL_TX_DMA_THRESHOLD_Pos);
    regs[id_]->DMACTL = dma_control_ | I2S_DMA_CTRL_RX_FIFO_FLUSH_Msk
        | I2S_DMA_CTRL_TX_FIFO_FLUSH_Msk;
    regs[id_]->DMACTL = dma_control_;
    if (tx_) tx_->head = tx_->tail = tx_->count = 0;
    if (rx_) rx_->head = rx_->tail = rx_->count = 0;
    run_.configure();
    return true;
  }

  void enable_clocks() {
    if (!master_ && !mclk_) return;
    taskENTER_CRITICAL();
    if (id_ == 0) {
      clock_config.fracDiv0DivRatioInteger = clock_plan_.integer;
      clock_config.fracDiv0DivRatioFrac = clock_plan_.fraction;
    } else {
      clock_config.fracDiv1DivRatioInteger = clock_plan_.integer;
      clock_config.fracDiv1DivRatioFrac = clock_plan_.fraction;
    }
    GPR_setFracDivConfig(&clock_config);
    if (mclk_) {
      GPR_setMclkSrc(mclk_id[id_], mclk_source[id_]);
      GPR_setMclkDiv(mclk_id[id_], 1);
      GPR_setFracDivOutClkDiv(mclk_output[id_], clock_plan_.output_divider);
      GPR_fracDivOutCLkEnable(mclk_output[id_]);
      GPR_mclkEnable(mclk_id[id_]);
    }
    if (master_) {
      GPR_setBclkSrc(bclk_id[id_], bclk_source[id_]);
      GPR_setBclkDiv(bclk_id[id_], clock_plan_.bit_clock_divider);
      GPR_setFracDivOutClkDiv(bclk_output[id_], clock_plan_.output_divider);
      GPR_fracDivOutCLkEnable(bclk_output[id_]);
      GPR_BclkEnable(bclk_id[id_]);
    }
    taskEXIT_CRITICAL();
  }

  void disable_clocks() {
    // The vendor exposes no BCLK gate-disable API. Gating its dedicated
    // fractional output stops the source without affecting the other I2S.
    GPR_fracDivOutClkDisable(bclk_output[id_]);
    GPR_mclkDisable(mclk_id[id_]);
    GPR_fracDivOutClkDisable(mclk_output[id_]);
  }

  bool start() {
    // Do not let a DMA fault gate the peripheral midway through setup and
    // then accidentally re-enable it in the rest of this method.
    taskENTER_CRITICAL();
    if (!run_.start(++next_generation)) {
      taskEXIT_CRITICAL();
      return false;
    }
    if (rx_) rx_->prepare(id_, false);
    if (tx_) tx_->prepare(id_, true);
    regs[id_]->DMACTL = dma_control_
        | (rx_ ? I2S_DMA_CTRL_RX_DMA_REQ_EN_Msk : 0)
        | (tx_ ? I2S_DMA_CTRL_TX_DMA_REQ_EN_Msk : 0);
    regs[id_]->I2SCTL = (tx_ ? 1 : 0) | (rx_ ? 2 : 0);
    // DMA and the peripheral must be ready before the first generated edge.
    enable_clocks();
    taskEXIT_CRITICAL();
    return true;
  }

  void stop() {
    // Retire callbacks before halting channels, then synchronously quiesce DMA.
    if (!run_.stop()) return;
    regs[id_]->I2SCTL = 0;
    disable_clocks();
    regs[id_]->DMACTL = dma_control_;
    if (rx_) rx_->stop();
    if (tx_) tx_->stop();
    if (rx_) rx_->head = rx_->tail = rx_->count = 0;
    if (tx_) tx_->head = tx_->tail = tx_->count = 0;
    regs[id_]->DMACTL = dma_control_ | I2S_DMA_CTRL_RX_FIFO_FLUSH_Msk
        | I2S_DMA_CTRL_TX_FIFO_FLUSH_Msk;
    regs[id_]->DMACTL = dma_control_;
  }

  void interrupt(bool tx, uint32_t event) {
    if (run_.phase() != I2sRunState::RUNNING) return;
    auto pipe = tx ? tx_ : rx_;
    if (event == DMA_EVENT_END) {
      pipe->completed(tx);
    } else if (event == DMA_EVENT_ERROR) {
      pipe->losses++;
      run_.fail();
      // Do not wait for DMA in its ISR. Stop new peripheral requests now;
      // stop/close will synchronously quiesce the channels before reuse/free.
      regs[id_]->I2SCTL = 0;
      regs[id_]->DMACTL = dma_control_;
      disable_clocks();
    } else {
      return;
    }
    Ec618EventSource::send_event_from_isr(Event::i2s_type(id_), run_.generation());
  }

  int transfer(uint8_t* bytes, int length, bool tx) {
    auto pipe = tx ? tx_ : rx_;
    const I2sBufferFormat& format = tx ? output_format_ : input_format_;
    int frame_bytes = format.frame_bytes();
    int transferred = 0;
    // Amortize the primitive/monitor overhead without extending a critical
    // section. Limit each call too, so a large buffer cannot monopolize the VM.
    for (unsigned block = 0; block < 8; block++) {
      taskENTER_CRITICAL();
      // DMA may fault between blocks while interrupts are enabled.
      if (run_.failed()) {
        taskEXIT_CRITICAL();
        return -1;
      }
      unsigned frames = Utils::min(static_cast<unsigned>((length - transferred) / frame_bytes),
          (tx ? pipe->ring_words - pipe->count : pipe->count) / 2);
      // DMA still needs its next block serviced at high sample rates.
      frames = Utils::min(frames, I2sPipe::kBlockWords / 2);
      // Always consume both wire slots, including when the public buffer is
      // mono. Every ring position and DMA block remains stereo-frame aligned.
      if (format.matches_ring(pipe->ring_format.word_bytes())) {
        unsigned words = frames * 2;
        if (tx) {
          pipe->head = pipe->ring_format.copy(pipe->ring, pipe->ring_words,
              pipe->head, bytes, words, true);
          pipe->count += words;
        } else {
          pipe->tail = pipe->ring_format.copy(pipe->ring, pipe->ring_words,
              pipe->tail, bytes, words, false);
          pipe->count -= words;
        }
        bytes += frames * frame_bytes;
      } else {
        for (unsigned i = 0; i < frames; i++) {
          if (tx) {
            uint32_t left, right;
            format.encode(bytes, &left, &right);
            pipe->push(left);
            pipe->push(right);
          } else {
            uint32_t left = pipe->pop();
            uint32_t right = pipe->pop();
            format.decode(bytes, left, right);
          }
          bytes += frame_bytes;
        }
      }
      taskEXIT_CRITICAL();
      transferred += frames * frame_bytes;
      if (frames == 0 || transferred == length) break;
    }
    return transferred;
  }

  int id_;
  bool master_;
  bool mclk_;
  I2sClockPlan clock_plan_ = {};
  Pads pads_;
  I2sPipe* tx_ = null;
  I2sPipe* rx_ = null;
  I2sRunState run_;
  I2sBufferFormat input_format_;
  I2sBufferFormat output_format_;
  uint32_t dma_control_ = 0;
  bool powered_ = false;
};

static void dma0_rx(uint32_t e) { if (owners[0]) owners[0]->interrupt(false, e); }
static void dma0_tx(uint32_t e) { if (owners[0]) owners[0]->interrupt(true, e); }
static void dma1_rx(uint32_t e) { if (owners[1]) owners[1]->interrupt(false, e); }
static void dma1_tx(uint32_t e) { if (owners[1]) owners[1]->interrupt(true, e); }

class I2sResourceGroup : public ResourceGroup {
 public:
  TAG(I2sResourceGroup);
  I2sResourceGroup(Process* process, EventSource* source) : ResourceGroup(process, source) {}
  uint32_t on_event(Resource* r, word data, uint32_t state) override {
    auto bus = static_cast<I2sResource*>(r);
    if (!bus->run_.accepts(uint32_t(data))) return state;
    if (bus->run_.failed()) return state | kError;
    return state | kRead | kWrite;
  }
};

MODULE_IMPLEMENTATION(i2s, MODULE_I2S)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  auto group = _new I2sResourceGroup(process, Ec618EventSource::instance());
  if (!group) FAIL(MALLOC_FAILED);
  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(create) {
  ARGS(I2sResourceGroup, group, int, tx, int, rx, int, mclk, int, sck, int, ws, bool, master);
  if (tx == -1 && rx == -1) FAIL(INVALID_ARGUMENT);
  int id = sck == 35 && ws == 36 ? 0 : sck == 19 && ws == 20 ? 1 : -1;
  if (id < 0 || (tx != -1 && tx != routes[id][0]) || (rx != -1 && rx != routes[id][1])) FAIL(INVALID_ARGUMENT);
  if (mclk != -1 && mclk != routes[id][2]) FAIL(INVALID_ARGUMENT);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  PadReserver pads;
  const int selected_pads[] = {tx, rx, mclk, sck, ws};
  for (int pad : selected_pads) { if (!pads.take(pad)) FAIL(ALREADY_IN_USE); }
  if (!controllers.take(id)) FAIL(ALREADY_IN_USE);
  auto bus = _new I2sResource(group, id, master, mclk != -1);
  if (!bus) { controllers.put(id); FAIL(MALLOC_FAILED); }
  bool success = false;
  Defer cleanup { [&] { if (!success) delete bus; } };
  if (sleep_handle == 0xff) {
    slpManApplyPlatVoteHandle("TOITI2S", &sleep_handle);
    if (sleep_handle == 0xff) FAIL(MALLOC_FAILED);
  }
  if (tx != -1) {
    bus->tx_ = _new I2sPipe;
    if (!bus->tx_ || !bus->tx_->open(id, true)) FAIL(MALLOC_FAILED);
  }
  if (rx != -1) {
    bus->rx_ = _new I2sPipe;
    if (!bus->rx_ || !bus->rx_->open(id, false)) FAIL(MALLOC_FAILED);
  }
  bus->pads_.adopt(pads);
  pads.keep();
  if (!bus->initialize()) FAIL(HARDWARE_ERROR);
  // Peripheral and generated clocks remain disabled until start.
  for (int pad : selected_pads) {
    if (pad >= 0) { GPIO_IomuxEC618(pad, 1, 0, 1); GPIO_PullConfig(pad, 0, 0); }
  }
  group->register_resource(bus);
  proxy->set_external_address(bus);
  success = true;
  return proxy;
}

static Object* configure_bus(Process* process, I2sResource* bus, int rate, int bits,
                             int multiplier, int external, int format, int slots_in,
                             int slots_out, int tx, int rx, int mclk, int sck, int ws,
                             int duration_ms) {
  if (bus->run_.active()) FAIL(INVALID_STATE);
  if (!I2sBufferFormat::valid_bits(bits) || format < 0 || format > 2 ||
      !I2sBufferFormat::valid_input(slots_in) || !I2sBufferFormat::valid_output(slots_out)) FAIL(INVALID_ARGUMENT);
  unsigned words = I2sBufferCapacity::ring_words(rate, duration_ms, I2sRingFormat(bits).word_bytes());
  if (words == 0) FAIL(INVALID_ARGUMENT);
  if (rate > I2sClockPlan::maximum_sample_rate(bits)) FAIL(UNSUPPORTED);
  if (external > 0) FAIL(UNSUPPORTED);
  if (mclk != -1 && (mclk & 0x10000)) FAIL(UNSUPPORTED);
  const int* pins = routes[bus->id_];
  if (tx != (bus->tx_ ? pins[0] : -1) || rx != (bus->rx_ ? pins[1] : -1) ||
      mclk != (bus->mclk_ ? pins[2] : -1) ||
      (sck & ~0x10000) != pins[3] || (ws & ~0x10000) != pins[4]) FAIL(INVALID_ARGUMENT);
  I2sClockPlan plan = {};
  if ((bus->master_ || bus->mclk_) && !I2sClockPlan::calculate(rate, bits, multiplier, &plan)) FAIL(UNSUPPORTED);
  if (!bus->configure(words, bits, format, slots_in, slots_out, sck & 0x10000, ws & 0x10000, plan)) FAIL(MALLOC_FAILED);
  return process->null_object();
}

PRIMITIVE(configure) {
  ARGS(I2sResource, bus, int, rate, int, bits, int, multiplier, int, external,
       int, format, int, slots_in, int, slots_out, int, tx, int, rx, int, mclk, int, sck, int, ws);
  return configure_bus(process, bus, rate, bits, multiplier, external, format,
      slots_in, slots_out, tx, rx, mclk, sck, ws, 0);
}

PRIMITIVE(configure_buffered) {
  ARGS(I2sResource, bus, int, rate, int, bits, int, multiplier, int, external,
       int, format, int, slots_in, int, slots_out, int, tx, int, rx, int, mclk, int, sck, int, ws,
       int, duration_ms);
  if (duration_ms <= 0) FAIL(INVALID_ARGUMENT);
  return configure_bus(process, bus, rate, bits, multiplier, external, format,
      slots_in, slots_out, tx, rx, mclk, sck, ws, duration_ms);
}

PRIMITIVE(start) {
  ARGS(I2sResource, bus);
  if (!bus->start()) FAIL(INVALID_STATE);
  if (bus->run_.failed()) FAIL(HARDWARE_ERROR);
  return process->null_object();
}

PRIMITIVE(stop) {
  ARGS(I2sResource, bus);
  bus->stop();
  return process->null_object();
}

PRIMITIVE(close) {
  ARGS(I2sResourceGroup, group, I2sResource, bus);
  if (bus->resource_group() != group) FAIL(INVALID_ARGUMENT);
  group->unregister_resource(bus);
  bus_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(preload) {
  ARGS(I2sResource, bus, Blob, buffer);
  if (bus->run_.phase() != I2sRunState::STOPPED) FAIL(INVALID_STATE);
  if (!bus->tx_) FAIL(UNSUPPORTED);
  if (buffer.length() % bus->output_format_.frame_bytes() != 0) FAIL(INVALID_ARGUMENT);
  return Smi::from(bus->transfer(const_cast<uint8_t*>(buffer.address()), buffer.length(), true));
}

PRIMITIVE(write) {
  ARGS(I2sResource, bus, Blob, buffer);
  if (bus->run_.failed()) FAIL(HARDWARE_ERROR);
  if (bus->run_.phase() != I2sRunState::RUNNING) FAIL(INVALID_STATE);
  if (!bus->tx_) FAIL(UNSUPPORTED);
  if (buffer.length() % bus->output_format_.frame_bytes() != 0) FAIL(INVALID_ARGUMENT);
  int written = bus->transfer(const_cast<uint8_t*>(buffer.address()), buffer.length(), true);
  if (written < 0) FAIL(HARDWARE_ERROR);
  return Smi::from(written);
}

PRIMITIVE(read_to_buffer) {
  ARGS(I2sResource, bus, MutableBlob, buffer);
  if (bus->run_.failed()) FAIL(HARDWARE_ERROR);
  if (bus->run_.phase() != I2sRunState::RUNNING) FAIL(INVALID_STATE);
  if (!bus->rx_) FAIL(UNSUPPORTED);
  if (buffer.length() < bus->input_format_.frame_bytes()) FAIL(INVALID_ARGUMENT);
  int read = bus->transfer(buffer.address(), buffer.length(), false);
  if (read < 0) FAIL(HARDWARE_ERROR);
  return Smi::from(read);
}

PRIMITIVE(errors_underrun) {
  ARGS(I2sResource, bus);
  return Primitive::integer(bus->tx_ ? bus->tx_->losses : 0, process);
}

PRIMITIVE(errors_overrun) {
  ARGS(I2sResource, bus);
  return Primitive::integer(bus->rx_ ? bus->rx_->losses : 0, process);
}

}  // namespace toit
#endif  // TOIT_EC618
