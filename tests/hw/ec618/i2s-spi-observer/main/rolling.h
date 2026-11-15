// Copyright (C) 2026 Toit contributors.
// Private diagnostic; use of this source is governed by tests/LICENSE.
#include "driver/spi_slave.h"
#include "esp_rom_gpio.h"
#include "esp_rom_sys.h"
#include "soc/gpio_sig_map.h"
#include "soc/spi_periph.h"
#include "soc/gpio_struct.h"
#include "wire.h"

enum { WIRE_CAPACITY = 6 * 4092 };
static uint8_t *wire_buffer, *wire_saved;
static uint8_t *stream_capture;
static unsigned stream_target, stream_bytes, stream_blocks, stream_stall_ms;
static int stream_start_before, stream_start_after, stream_end_before, stream_end_after;
static uint8_t wire_reference[251 * 8];
static size_t wire_cycle, wire_saved_bits;
static unsigned wire_windows, wire_bad_windows, wire_invalid;
static uint64_t wire_checked, wire_errors;
static int64_t wire_max_us;
static WireResult wire_saved_result;
static bool wire_initialized, wire_running;
static volatile bool wire_stop;
static SemaphoreHandle_t wire_mounted, wire_done;
static volatile int64_t wire_completed_us;
static unsigned wire_short;
static unsigned wire_prefix_bytes;
extern volatile uint32_t ec618_spi_length_before, ec618_spi_length_after;
extern volatile uint32_t ec618_spi_dma_bytes, ec618_spi_dma_owned, ec618_spi_dma_errors;
typedef struct { unsigned bits, before, after, dma_bytes, dma_owned, dma_errors; int64_t duration, completion; } ShortWindow;
static ShortWindow wire_short_records[16];
static unsigned wire_spi_mode;
static portMUX_TYPE wire_gate_lock = portMUX_INITIALIZER_UNLOCKED;

static bool IRAM_ATTR wire_gate(bool active) {
  // Change CS after the opposite edge from the selected sampling edge.
  // Wait for a fresh transition, not merely an already-low/high clock.
  // Limit polling so a missing clock cannot trap the CPU in a critical section.
  unsigned remaining = 4096;
  unsigned desired = wire_spi_mode ? 2 : 0;
  volatile uint32_t *clock = &GPIO.in;
  volatile uint32_t *gate = &GPIO.func_in_sel_cfg[spi_periph_signal[SPI2_HOST].spics_in].val;
  portENTER_CRITICAL(&wire_gate_lock);
  uint32_t value = (*gate & ~(1u << 6)) | ((unsigned)active << 6);
  // Materialize the address and complete register value before polling.
  // No flash lookup or register read-modify-write may follow the clock edge.
  __asm__ __volatile__("" : "+r"(gate), "+r"(value), "+r"(clock) : : "memory");
  while (remaining && (*clock & 2) == desired) remaining--;
  while (remaining && (*clock & 2) != desired) remaining--;
  // Always release CS even after the source has stopped its clock.
  // An unsynchronized selection is an invalid capture, never a reboot.
  *gate = value;
  portEXIT_CRITICAL(&wire_gate_lock);
  return remaining != 0;
}

static void IRAM_ATTR wire_complete(spi_slave_transaction_t *transaction) {
  (void)transaction;
  wire_completed_us = esp_timer_get_time();
}

static void IRAM_ATTR wire_mount(spi_slave_transaction_t *transaction) {
  (void)transaction;
  BaseType_t wake = pdFALSE;
  xSemaphoreGiveFromISR(wire_mounted, &wake);
  if (wake) portYIELD_FROM_ISR();
}

static void wire_select(bool active) {
  esp_rom_gpio_connect_in_signal(active ? GPIO_MATRIX_CONST_ZERO_INPUT : GPIO_MATRIX_CONST_ONE_INPUT,
                                spi_periph_signal[SPI2_HOST].spics_in, false);
}

static void wire_halt(void) {
  wire_stop = true;
  if (wire_running) {
    configASSERT(xSemaphoreTake(wire_done, pdMS_TO_TICKS(1000)));
    wire_running = false;
  }
}

static void wire_close(void) {
  wire_halt();
  if (wire_initialized) ESP_ERROR_CHECK(spi_slave_free(SPI2_HOST));
  wire_initialized = false;
  free(wire_buffer); wire_buffer = NULL;
  free(stream_capture); stream_capture = NULL;
  free(wire_saved); wire_saved = NULL;
}

static void wire_configure(unsigned bits, unsigned mode) {
  wire_close();
  wire_spi_mode = mode;
  stream_stall_ms = 0;
  stream_target = ((rate * 2 * (bits / 8) * 2 + 4091) / 4092) * 4092;
  if (stream_target) {
    stream_capture = heap_caps_malloc(stream_target, MALLOC_CAP_8BIT | MALLOC_CAP_SPIRAM);
    configASSERT(stream_capture);
    // Allocate and touch capture storage before either I2S direction starts.
    memset(stream_capture, 0, stream_target);
  }
  wire_buffer = heap_caps_malloc(WIRE_CAPACITY, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
  wire_saved = heap_caps_malloc(WIRE_CAPACITY, MALLOC_CAP_8BIT | MALLOC_CAP_SPIRAM);
  configASSERT(wire_buffer && wire_saved);
  wire_cycle = 251 * 2 * bits;
  wire_prefix_bytes = (rate / 50) * 2 * (bits / 8);
  unsigned width = bits / 8;
  for (unsigned frame = 0; frame < 251; frame++) {
    for (unsigned side = 0; side < 2; side++) {
      uint32_t value = sample(frame, side != 0, bits);
      for (unsigned byte = 0; byte < width; byte++)
        wire_reference[(frame * 2 + side) * width + byte] = value >> (8 * (width - 1 - byte));
    }
  }
  wire_saved_bits = wire_windows = wire_bad_windows = wire_invalid = 0;
  wire_short = 0;
  wire_checked = wire_errors = 0;
  wire_max_us = 0;
  spi_bus_config_t bus = {
    .mosi_io_num = 8, .miso_io_num = -1, .sclk_io_num = 1,
    .quadwp_io_num = -1, .quadhd_io_num = -1, .max_transfer_sz = WIRE_CAPACITY,
  };
  // GO stays high throughout capture. The driver reconnects that inactive
  // CS at each mount; the worker then selects/deselects internally. Never
  // change the physical GO level to gate a window.
  spi_slave_interface_config_t slave = {
    .spics_io_num = GO, .mode = mode, .queue_size = 1, .post_setup_cb = wire_mount,
    .post_trans_cb = wire_complete,
  };
  ESP_ERROR_CHECK(spi_slave_initialize(SPI2_HOST, &bus, &slave, SPI_DMA_CH_AUTO));
  wire_initialized = true;
  ESP_ERROR_CHECK(gpio_set_direction(GO, GPIO_MODE_INPUT_OUTPUT));
  wire_select(false);
}

extern volatile bool ec618_spi_ring_enabled;
extern int ec618_spi_ring_take(uint8_t *, unsigned);

static void wire_capture(void *unused) {
  (void)unused;
  stream_bytes = stream_blocks = 0;

  uint8_t *capture = stream_capture;
  configASSERT(capture);
  vTaskDelay(pdMS_TO_TICKS(100));
  ec618_spi_ring_enabled = true;
  spi_slave_transaction_t transaction = {.length = WIRE_CAPACITY * 8, .rx_buffer = wire_buffer};
  ESP_ERROR_CHECK(spi_slave_queue_trans(SPI2_HOST, &transaction, pdMS_TO_TICKS(1000)));
  configASSERT(xSemaphoreTake(wire_mounted, pdMS_TO_TICKS(1000)));
  int64_t start = esp_timer_get_time();
  stream_start_before = bit_count();
  bool clock_started = wire_gate(true);
  stream_start_after = bit_count();
  int error = clock_started ? 0 : -4;
  while (!error && !wire_stop && !gpio_get_level(ACK) && stream_bytes < stream_target && esp_timer_get_time() - start < 3000000) {
    int64_t copy_start = esp_timer_get_time();
    int n = ec618_spi_ring_take(capture + stream_bytes, stream_target - stream_bytes);
    int64_t copy_us = esp_timer_get_time() - copy_start;
    if (n < 0) { error = n; break; }
    if (n && copy_us >= (int64_t)n * 1000000 / (rate * 2 * (checks[0].bits / 8))) { error = -3; break; }
    if (n) {
      stream_bytes += n; stream_blocks++;
      if (stream_blocks == 1 && stream_stall_ms) vTaskDelay(pdMS_TO_TICKS(stream_stall_ms));
    }
    else vTaskDelay(1);
  }
  stream_end_before = bit_count();
  bool clock_stopped = wire_gate(false);
  if (!clock_stopped && !error) error = -5;
  stream_end_after = bit_count();
  wire_max_us = esp_timer_get_time() - start;
  spi_slave_transaction_t *completed = NULL;
  ESP_ERROR_CHECK(spi_slave_get_trans_result(SPI2_HOST, &completed, pdMS_TO_TICKS(1000)));
  ec618_spi_ring_enabled = false;
  configASSERT(completed == &transaction);
  int span = stream_end_after - stream_start_before;
  unsigned frame_bits = checks[0].bits * 2;
  bool counters = span >= (int)(stream_bytes * 8) - (int)(2 * frame_bits) &&
      span < (int)((stream_bytes + WIRE_CAPACITY) * 8) &&
      stream_start_after >= stream_start_before && stream_end_after >= stream_end_before;
  bool complete = !error && clock_started && clock_stopped && stream_bytes == stream_target && counters && !gpio_get_level(ACK);
  WireResult result = wire_check(capture, stream_bytes * 8, wire_reference, wire_cycle);
  wire_saved_result = result;
  wire_windows = 1;
  wire_checked = result.checked;
  wire_errors = result.errors;
  wire_invalid = !complete || result.phase < 0;
  wire_bad_windows = result.phase < 0 || result.errors;
  printf("STREAM stall_ms=%u target=%u bytes=%u blocks=%u error=%d counters=%u start_before=%d start_after=%d end_before=%d end_after=%d duration_us=%lld phase=%d checked=%u errors=%u first_error=%u\n",
      stream_stall_ms, stream_target, stream_bytes, stream_blocks, error, counters,
      stream_start_before, stream_start_after, stream_end_before, stream_end_after,
      (long long)wire_max_us, result.phase, (unsigned)result.checked, result.errors, (unsigned)result.first_error);

  xSemaphoreGive(wire_done);
  vTaskDelete(NULL);
}

static void wire_start(void) {
  wire_stop = false;
  wire_running = true;
  configASSERT(xTaskCreate(wire_capture, "spi-observer", 4096, NULL, 3, NULL) == pdPASS);
}

static bool wire_report(void) {
  printf("WIRE windows=%u bad_windows=%u invalid=%u checked_bits=%llu errors=%llu max_us=%lld saved_bits=0\n",
      wire_windows, wire_bad_windows, wire_invalid, (unsigned long long)wire_checked,
      (unsigned long long)wire_errors, (long long)wire_max_us);
  return wire_windows == 1 && !wire_invalid && !wire_bad_windows && wire_checked == stream_target * 8;
}

// Run only before starting the EC test. GPIO40/41 terminate at idle EC
// inputs. Physical BCLK/WS/data remain inputs; SPI observes matrix loopback.
static bool wire_selftest(unsigned mode) {
  wire_configure(16, mode);
  frame_configure(GO, 0);
  gpio_set_level(GO, 0);
  gpio_set_level(41, 0);
  ESP_ERROR_CHECK(gpio_set_direction(41, GPIO_MODE_INPUT_OUTPUT));
  esp_rom_gpio_connect_in_signal(GO, spi_periph_signal[SPI2_HOST].spiclk_in, false);
  esp_rom_gpio_connect_in_signal(41, spi_periph_signal[SPI2_HOST].spid_in, false);
  enum { PREFIX_BYTES = 5120, CLOCK_BITS = PREFIX_BYTES * 8 + 7 };
  bool valid = true;
  // Reuse the same descriptor storage: a short second transaction must not
  // inherit the first transaction's completed-prefix verdict.
  for (unsigned round = 0; round < 2; round++) {
  unsigned clocks = round == 0 ? CLOCK_BITS : 1031;
  spi_slave_transaction_t transaction = {.length = PREFIX_BYTES * 8, .rx_buffer = wire_buffer};
  ESP_ERROR_CHECK(spi_slave_queue_trans(SPI2_HOST, &transaction, pdMS_TO_TICKS(1000)));
  configASSERT(xSemaphoreTake(wire_mounted, pdMS_TO_TICKS(1000)));
  frame_start();
  wire_select(true);
  for (unsigned bit = 0; bit < clocks; bit++) {
    unsigned value = ((bit / 8) * 73 + 19) & 255;
    gpio_set_level(41, (value >> (7 - bit % 8)) & 1);
    esp_rom_delay_us(5);
    gpio_set_level(GO, 1);
    esp_rom_delay_us(5);
    gpio_set_level(GO, 0);
  }
  esp_rom_delay_us(5);
  wire_select(false);
  frame_stop();
  spi_slave_transaction_t *completed;
  ESP_ERROR_CHECK(spi_slave_get_trans_result(SPI2_HOST, &completed, pdMS_TO_TICKS(1000)));
  bool full = ec618_spi_dma_bytes == PREFIX_BYTES && !ec618_spi_dma_owned && !ec618_spi_dma_errors;
  bool passed = completed == &transaction && transaction.trans_len == clocks && full == (round == 0) && frame_final == clocks && bit_final == clocks;
  if (passed && round == 0) {
    for (unsigned bit = 0; bit < PREFIX_BYTES * 8; bit++) {
      unsigned value = ((bit / 8) * 73 + 19) & 255;
      passed &= wire_bit(wire_buffer, bit) == ((value >> (7 - bit % 8)) & 1);
    }
  }
  printf("WIRE SELFTEST mode=%u round=%u bits=%u dma_bytes=%u dma_owned=%u dma_errors=%u pcnt=%d bit_pcnt=%d exact=%u\n",
      mode, round, (unsigned)transaction.trans_len, (unsigned)ec618_spi_dma_bytes,
      (unsigned)ec618_spi_dma_owned, (unsigned)ec618_spi_dma_errors, frame_final, bit_final, passed);
  valid &= passed;
  }
  frame_close();
  wire_close();
  gpio_set_direction(41, GPIO_MODE_INPUT);
  gpio_set_direction(GO, GPIO_MODE_INPUT_OUTPUT);
  gpio_set_level(GO, 0);
  return valid;
}
