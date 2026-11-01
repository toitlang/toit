// Copyright (C) 2026 Toit contributors.
// Private diagnostic; use of this source is governed by tests/LICENSE.
#include "driver/pulse_cnt.h"
enum { FRAME_WINDOWS = 256 };
typedef struct { int before, after, phase, bit_before, bit_after; unsigned bits, errors; } FrameWindow;
static pcnt_unit_handle_t frame_unit;
static pcnt_channel_handle_t frame_channel;
static pcnt_unit_handle_t bit_unit;
static pcnt_channel_handle_t bit_channel;
static bool frame_counting;
static int frame_final;
static int bit_final;
static FrameWindow frame_windows[FRAME_WINDOWS];
static uint8_t *frame_storage;
static unsigned frame_stored, frame_overflow, frame_stride;

static int frame_count(void) {
  int count;
  ESP_ERROR_CHECK(pcnt_unit_get_count(frame_unit, &count));
  return count;
}

static int bit_count(void) {
  int count;
  ESP_ERROR_CHECK(pcnt_unit_get_count(bit_unit, &count));
  return count;
}

static void frame_stop(void) {
  if (frame_counting) {
    ESP_ERROR_CHECK(pcnt_unit_stop(frame_unit));
    ESP_ERROR_CHECK(pcnt_unit_stop(bit_unit));
    frame_counting = false;
    frame_final = frame_count();
    bit_final = bit_count();
  }
}

static void frame_close(void) {
  frame_stop();
  if (frame_unit) {
    ESP_ERROR_CHECK(pcnt_unit_disable(frame_unit));
    ESP_ERROR_CHECK(pcnt_del_channel(frame_channel));
    ESP_ERROR_CHECK(pcnt_del_unit(frame_unit));
    ESP_ERROR_CHECK(pcnt_unit_disable(bit_unit));
    ESP_ERROR_CHECK(pcnt_del_channel(bit_channel));
    ESP_ERROR_CHECK(pcnt_del_unit(bit_unit));
  }
  frame_unit = NULL;
  frame_channel = NULL;
  bit_unit = NULL;
  bit_channel = NULL;
  free(frame_storage); frame_storage = NULL;
}

static void frame_configure(int pin, unsigned prefix_bytes) {
  frame_close();
  pcnt_unit_config_t unit = {.low_limit = -30000, .high_limit = 30000, .flags.accum_count = true};
  ESP_ERROR_CHECK(pcnt_new_unit(&unit, &frame_unit));
  pcnt_chan_config_t channel = {.edge_gpio_num = pin, .level_gpio_num = -1};
  ESP_ERROR_CHECK(pcnt_new_channel(frame_unit, &channel, &frame_channel));
  ESP_ERROR_CHECK(gpio_pullup_dis(pin));
  ESP_ERROR_CHECK(gpio_pulldown_dis(pin));
  ESP_ERROR_CHECK(pcnt_channel_set_edge_action(frame_channel, PCNT_CHANNEL_EDGE_ACTION_HOLD, PCNT_CHANNEL_EDGE_ACTION_INCREASE));
  ESP_ERROR_CHECK(pcnt_channel_set_level_action(frame_channel, PCNT_CHANNEL_LEVEL_ACTION_KEEP, PCNT_CHANNEL_LEVEL_ACTION_KEEP));
  ESP_ERROR_CHECK(pcnt_unit_add_watch_point(frame_unit, 30000));
  ESP_ERROR_CHECK(pcnt_unit_enable(frame_unit));
  // The loopback counter test uses GO for both units. Live observation uses
  // rising BCLK edges on GPIO1 alongside falling WS edges on GPIO2.
  int bit_pin = pin == GO ? GO : 1;
  channel.edge_gpio_num = bit_pin;
  ESP_ERROR_CHECK(pcnt_new_unit(&unit, &bit_unit));
  ESP_ERROR_CHECK(pcnt_new_channel(bit_unit, &channel, &bit_channel));
  ESP_ERROR_CHECK(gpio_pullup_dis(bit_pin));
  ESP_ERROR_CHECK(gpio_pulldown_dis(bit_pin));
  ESP_ERROR_CHECK(pcnt_channel_set_edge_action(bit_channel, PCNT_CHANNEL_EDGE_ACTION_INCREASE, PCNT_CHANNEL_EDGE_ACTION_HOLD));
  ESP_ERROR_CHECK(pcnt_channel_set_level_action(bit_channel, PCNT_CHANNEL_LEVEL_ACTION_KEEP, PCNT_CHANNEL_LEVEL_ACTION_KEEP));
  ESP_ERROR_CHECK(pcnt_unit_add_watch_point(bit_unit, 30000));
  ESP_ERROR_CHECK(pcnt_unit_enable(bit_unit));
  frame_stride = prefix_bytes;
  if (prefix_bytes) {
    frame_storage = heap_caps_malloc((size_t)prefix_bytes * FRAME_WINDOWS, MALLOC_CAP_8BIT | MALLOC_CAP_SPIRAM);
    configASSERT(frame_storage);
  }
  frame_stored = frame_overflow = 0;
  frame_final = 0;
  bit_final = 0;
}

static void frame_start(void) {
  ESP_ERROR_CHECK(pcnt_unit_clear_count(frame_unit));
  ESP_ERROR_CHECK(pcnt_unit_clear_count(bit_unit));
  ESP_ERROR_CHECK(pcnt_unit_start(frame_unit));
  ESP_ERROR_CHECK(pcnt_unit_start(bit_unit));
  frame_counting = true;
}

static void frame_save(int before, int after, int bit_before, int bit_after, int phase, unsigned bits, unsigned errors, const uint8_t *data) {
  if (frame_stored == FRAME_WINDOWS) { frame_overflow++; return; }
  configASSERT(bits == frame_stride * 8);
  frame_windows[frame_stored] = (FrameWindow){.before=before, .after=after, .phase=phase,
      .bit_before=bit_before, .bit_after=bit_after, .bits=bits, .errors=errors};
  memcpy(frame_storage + (size_t)frame_stored * frame_stride, data, frame_stride);
  frame_stored++;
}

// Print raw prefixes potentially covering a native error. The broad startup
// range here selects dumps only; the host must establish absolute alignment
// from BCLK PCNT, pattern phase, training, DMA snapshots and final counts.
static void frame_report(void) {
  printf("FRAME_CLOCK final=%d bit_final=%d stored=%u overflow=%u\n", frame_final, bit_final, frame_stored, frame_overflow);
  bool dump[FRAME_WINDOWS] = {false};
  unsigned dumped = 0;
  unsigned frame_bits = checks[0].bits * 2;
  for (unsigned i = 0; i < frame_stored; i++) {
    FrameWindow *w = &frame_windows[i];
    printf("FRAME_WINDOW index=%u before=%d after=%d bit_before=%d bit_after=%d phase=%d bits=%u errors=%u\n",
        i, w->before, w->after, w->bit_before, w->bit_after, w->phase, w->bits, w->errors);
    int cycle = 251 * frame_bits;
    if (w->phase < 0 || w->bit_before % 30000 < 512 || w->bit_after % 30000 > 29488) continue;
    if (w->bit_after < w->bit_before || w->bit_after - w->bit_before > frame_bits) continue;
    int lower = w->bit_before - 9 * frame_bits;
    int upper = w->bit_after - 7 * frame_bits;
    int residue = (w->phase - lower) % cycle;
    if (residue < 0) residue += cycle;
    int first_bit = lower + residue;
    if (first_bit < 0 || first_bit > upper || first_bit + cycle <= upper) continue;
    {
      int first = first_bit / frame_bits;
      uint64_t start = first_bit;
      for (unsigned rx_id = 0; rx_id < 2; rx_id++) {
        Verify *v = &checks[rx_id];
        for (unsigned j = 0; j < v->errors && j < VERIFY_RECORDS; j++) {
          VerifyError *e = &v->records[j];
          uint64_t bit = (uint64_t)e->frame * frame_bits;
          if (bit < start || bit + frame_bits > start + w->bits) continue;
          printf("FRAME_CANDIDATE receiver=%u frame=%lu window=%u first_frame=%d native_left=%08lx native_right=%08lx\n",
              rx_id, (unsigned long)e->frame, i, first, (unsigned long)e->left, (unsigned long)e->right);
          if (!dump[i] && dumped < 4) { dump[i] = true; dumped++; }
        }
      }
    }
  }
  for (unsigned i = 0; i < frame_stored; i++) {
    if (!dump[i]) continue;
    const uint8_t *data = frame_storage + (size_t)i * frame_stride;
    for (unsigned offset = 0; offset < frame_stride; offset += 512) {
      printf("FRAME_RAW window=%u offset=%u hex=", i, offset);
      for (unsigned j = offset; j < offset + 512 && j < frame_stride; j++) printf("%02x", data[j]);
      puts("");
    }
  }
}

// Capture counters before checking each selected DMA buffer. The payload frame
// count is recorded after checking that buffer. This audits alignment without
// assuming the WS counter starts at the first transmitted sample.
enum { DMA_SNAPSHOTS = 128 };
typedef struct {
  int ws, bits;
  uint32_t frames, callback;
  unsigned training;
} DmaSnapshot;
static DmaSnapshot dma_snapshots[2][DMA_SNAPSHOTS];
static unsigned dma_snapshot_count[2], dma_callback_count[2];
static DmaSnapshot dma_last[2];

static void dma_report(void) {
  for (unsigned id = 0; id < 2; id++) {
    for (unsigned i = 0; i <= dma_snapshot_count[id]; i++) {
      DmaSnapshot *s = i == dma_snapshot_count[id] ? &dma_last[id] : &dma_snapshots[id][i];
      printf("DMA_CLOCK receiver=%u callback=%lu frames=%lu training=%u ws=%d bits=%d last=%u\n",
          id, (unsigned long)s->callback, (unsigned long)s->frames, s->training,
          s->ws, s->bits, i == dma_snapshot_count[id]);
    }
  }
}
