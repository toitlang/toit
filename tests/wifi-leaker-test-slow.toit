// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import crypto.sha256 show *
import crypto.hamming as hamming

prng-array:
  hash := sha256 NOISE-KEY_
  hash.size.repeat: hash[it] &= INDEX-MASK_
  return hash

class DataListenerTester extends DataListener:
  data-arrived := false

  constructor offset:
    super offset

  got-raw-packet data:
    data-arrived = true

  got-packet data:
    throw "Unused"

no-noise-data-test:
  prng := prng-array
  listener := OffsetListener
  offset := random 0 15
  10.repeat:
    16.repeat:
      listener.add prng[it] + offset + ((random 0 32) * 32)
  expect-equals offset listener.k

  data-listener := DataListenerTester offset

  5.repeat:
    16.repeat:
      data-listener.add prng[it] + offset + (("The correct data"[it] & 0x1f) << 5) + data-listener.coarse-offset_
  expect data-listener.data-arrived

inserted-random-data-test:
  prng := prng-array
  listener := OffsetListener
  offset := random 0 15
  10.repeat:
    16.repeat:
      listener.add prng[it] + offset + ((random 0 32) * 32)
      listener.add (random 0 1536)
  expect-equals offset listener.k

  data-listener := DataListenerTester offset

  5.repeat:
    16.repeat:
      data-listener.add prng[it] + offset + (("The correct data"[it] & 0x1f) << 5) + data-listener.coarse-offset_
      data-listener.add (random 0 1536)
  expect data-listener.data-arrived

main:
  set-random-seed "wifi"
  prng := prng-array
  test-no-noise prng
  test-no-noise-big-k prng
  test-present-present-missing-missing prng
  test-every-other-missing prng
  test-random-packets-missing prng
  test-every-other-packet-is-constant prng
  test-every-other-packet-is-random prng
  test-every-other-packet-is-random-and-one-quarter-are-missing prng
  test-every-other-packet-is-constant-and-one-quarter-are-missing prng
  no-noise-data-test
  inserted-random-data-test
  test-round-trip-x-percent-loss 17 0
  test-round-trip-x-percent-loss 0 51
  test-round-trip-x-percent-loss 17 51

test-no-noise prng:
  listener := OffsetListener
  10.repeat:
    16.repeat:
      listener.add prng[it] + 12 + ((random 0 32) * 32)
  expect-equals 12 listener.k

test-no-noise-big-k prng:
  listener := OffsetListener
  10.repeat:
    16.repeat:
      listener.add prng[it] + 44 + ((random 0 32) * 32)
  expect-equals 12 listener.k

test-present-present-missing-missing prng:
  listener := OffsetListener
  10.repeat:
    16.repeat:
      if (it % 4) < 2: listener.add prng[it] + 11 + ((random 0 32) * 32)
  expect-equals 11 listener.k

test-every-other-missing prng:
  // Only even packets get through.
  listener := OffsetListener
  10.repeat:
    16.repeat:
      if (it % 2) == 0: listener.add prng[it] + 15 + ((random 0 32) * 32)
  expect-equals 15 listener.k

  // Only odd packets get through.
  listener = OffsetListener
  10.repeat:
    16.repeat:
      if (it % 2) == 1: listener.add prng[it] + 0 + ((random 0 32) * 32)
  expect-equals 0 listener.k

test-random-packets-missing prng:
  // Only every second packet get through.
  listener := OffsetListener
  15.repeat:
    16.repeat:
      if (random 0 2) == 0: listener.add prng[it] + 15 + ((random 0 32) * 32)
  expect-equals 15 listener.k

  // Only every third packet gets through.
  listener = OffsetListener
  30.repeat:
    16.repeat:
      if (random 0 3) == 0: listener.add prng[it] + 1 + ((random 0 32) * 32)
  expect-equals 1 listener.k

  // Only every 4th packet gets through.
  listener = OffsetListener
  45.repeat:
    16.repeat:
      if (random 0 4) == 0: listener.add prng[it] + 1 + ((random 0 32) * 32)
  expect-equals 1 listener.k

  // Only every 5th packet gets through.
  listener = OffsetListener
  100.repeat:
    16.repeat:
      if (random 0 5) == 0: listener.add prng[it] + 1 + ((random 0 32) * 32)
  expect-equals 1 listener.k

test-every-other-packet-is-constant prng:
  listener := OffsetListener
  10.repeat:
    16.repeat:
      listener.add prng[it] + 6 + ((random 0 32) * 32)
      listener.add 44 + ((random 0 32) * 32)
  expect-equals 6 listener.k

test-every-other-packet-is-random prng:
  listener := OffsetListener
  10.repeat:
    16.repeat:
      listener.add prng[it] + 3 + ((random 0 32) * 32)
      listener.add (random 0 31) + ((random 0 32) * 32)
  expect-equals 3 listener.k

test-every-other-packet-is-random-and-one-quarter-are-missing prng:
  listener := OffsetListener
  14.repeat:  // Takes a bit longer.
    16.repeat:
      if (it % 4) != 2: listener.add prng[it] + 3 + ((random 0 32) * 32)
      listener.add (random 0 31) + ((random 0 32) * 32)
  expect-equals 3 listener.k

test-every-other-packet-is-constant-and-one-quarter-are-missing prng:
  listener := OffsetListener
  15.repeat:  // Takes a lot longer.
    16.repeat:
      if (it % 4) != 2: listener.add prng[it] + 3 + ((random 0 32) * 32)
      listener.add 12 + ((random 0 32) * 32)
  expect-equals 3 listener.k

class TestStringDecoder extends WifiDataDecoder:
  msg := null
  got := false

  got-message byte-array:
    got = true
    msg = byte-array.to-string

// Loses 'loss' percent of packets, tests we still get the message.
// Inserts random packets 'insertion' percent of the time
test-round-trip-x-percent-loss loss insertion:
  decoder := TestStringDecoder
  MSG ::= "The correct message at $loss% loss and $insertion% insertion!"
  encoder := WifiDataEncoder MSG

  prng := prng-array

  offset := random 0 15

  ctr := 0
  while not decoder.got:
    value := encoder.next-value
    if not value:
      encoder.reset
      value = encoder.next-value
    if (random 0 100) >= loss:
      decoder.add offset + value
    while (random 0 100) < insertion:
      decoder.add (random 0 1536)
    ctr++
  expect decoder.got
  expect decoder.msg == MSG

// Each packet of data has a 5 bit index and 5 bits of datum.  There can be
// errors, insertions and deletions in the packet stream, and we need to
// identify where we are in the sequence (the true index) and insert the datum
// into the correct place in the data.
//
// To make things interesting, the index can be offset by a random amount that
// is constant from packet to packet, but unknown to the receiver.  For this
// reason we use the delta of the index rather than the index itself to place
// ourselves in the stream.
//
// We use a 5-bit PRNG with a cycle size of 16 and instead of the raw index
// cycling from 0-15, we transmit the nth pseudo-random number.  This means the
// deltas are not just 1, 1, 1,... ..., 1, -15, but rather have a
// discernible pattern, and we can tell when we are off by one.
//
// For example
// 1 5 6 2 15  10...    // Expected random sequence
//   4 1 12 13 11...    // Deltas (mod 16) between the elements of the sequence.
//
// If we think we are at position 0 and we get a packet with a random index 4
// more than the previous, then we now think we are at position 1.  If we get
// one that is 5 more, we think we are probably at position 2, having missed a
// packet, but we are less sure.
//
// When decoding we maintain an array of the 16 states, with an indication of
// how likely it is we are in that state.

STATES_ ::= 0x10   // We cycle through these states when transmitting.
STATE-MASK_ ::= 0xf
INDEXES_ ::= 0x20  // Each state has an index in this range.
INDEX-MASK_ ::= 0x1f

// We hash this string to get a random-number sequence that helps us
// distinguish noise from signal.  This key has some nice properties
// where sequential packets don't have the same size.
NOISE-KEY_ ::= "hued"

HEADER-PACKETS_ ::= 2
BYTES-PER-PACKET_ ::= 6   // Not counting 7-bit packet checksum.
PAYLOAD-PER-PACKET_ ::= 5 // Not counting packet number.
MAX-PACKETS_ ::= 0x100

SMALL-PACKET-LIMIT_ ::= 96  // We ignore packets smaller than this, since they are likely noise.

// This listener gets a stream of noisy data.  It attempts to answer the
// two questions: One, is there a signal here? (Do we have the right channel?)
// Two, what is the constant added to every sample in the stream (we assume the
// constant is between 0 and 15).
//
// We are listening to a noisy channel which only transmits 10 bit numbers, all
// offset by some unknown constant, k.  The numbers are in the form k +
// 0bxxxxxyyyyy.  The y bits in consecutive signal numbers follow a pattern
// given by 16 pseudo-random numbers (we get these by hashing a seed key).
// This class detects whether the signal numbers are present in the data
// stream, and determines the last 5 bits of the constant, k.  The basic
// technique is to look for deltas between two numbers, where the lower 5 bits
// of the delta match some delta in the pseudo-random pattern.
class OffsetListener:
  offset-weights_ := List INDEXES_ --initial=0
  state-budget_ := List STATES_
  prev_ := 0
  prev-prev_ := 0
  sum_ := ?
  static MAX-WEIGHT ::= INDEXES_ * 256
  static DECAY ::= INDEXES_ >> 2
  static GOOD-MATCH-BONUS ::= INDEXES_ + (INDEXES_ >> 1)
  static POOR-MATCH-BONUS ::= INDEXES_
  static MIN-BUDGET ::= STATES_ >> 1

  constructor:
    sum_ = sha256 NOISE-KEY_
    sum_.size.repeat: sum_[it] &= INDEX-MASK_
    state-budget_.size.repeat: state-budget_[it] = List INDEXES_ --initial=0

  correspondance a b c d:
    return ((a - b) & INDEX-MASK_) == ((c - d) & INDEX-MASK_)

  add counter:
    counter &= INDEX-MASK_
    STATES_.repeat: | state |
      offset := (counter - sum_[state]) & INDEX-MASK_
      try-match_ state offset state - 1 counter prev_      GOOD-MATCH-BONUS
      try-match_ state offset state - 1 counter prev-prev_ POOR-MATCH-BONUS
      try-match_ state offset state - 2 counter prev_      POOR-MATCH-BONUS
      budget := state-budget_[state]
      INDEXES_.repeat:
        old-budget := budget[it]
        budget[it]++
    prev-prev_ = prev_
    prev_ = counter
    INDEXES_.repeat:
      old-weight := offset-weights_[it]
      // Clamp between 0 and MAX_WEIGHT
      offset-weights_[it] = old-weight <= DECAY ? 0 : (old-weight > MAX-WEIGHT ? MAX-WEIGHT : old-weight - DECAY)

  try-match_ state offset prev-state counter prev bonus:
    prev-state &= STATE-MASK_
    if correspondance sum_[state] sum_[prev-state] counter prev:
      if state-budget_[state][offset] >= MIN-BUDGET:
        state-budget_[state][offset] = 0
        offset-weights_[offset] += bonus

  k:
    winner := null
    INDEXES_.repeat:
      if offset-weights_[it] >= 1000:
        winner = it
    INDEXES_.repeat:
      if winner and winner != it and offset-weights_[it] > 250:
        // More than one possible result.  Reset the weights and try again.
        offset-weights_.size.repeat: offset-weights_[it] = 0
        return null
    return winner

MINIMAL-GOODNESS ::= 30

abstract class DataListener:
  // A list of how likely it is that we are in a given state.
  states_ := List STATES_ --initial=1
  next-states_ := List STATES_ --initial=1
  data_ := List STATES_ --initial=0
  data-weights_ := List STATES_ --initial=0
  wrote-from-start_ := false
  hash_ := ?
  old-best-index_ := STATES_ - 1
  health_ := 0
  coarse-offset_ := 64

  // The constant offset of the data.
  offset_ := 0

  constructor .offset_:
    hash_ = sha256 NOISE-KEY_
    hash_.size.repeat: hash_[it] &= INDEX-MASK_

  // Gets a 16 element array with some data we think was transmitted to us.  The first
  // byte is the packet index, and the last 5 are 5 bytes of data.
  abstract got-packet data

  corrupted-packet_:
    health_--
    // If we see too many corrupted packets this probably means the numbers are
    // offset by some factor of 32.  Try a different factor (up to 96).
    if health_ < -20:
      health_ = 0
      coarse-offset_ = (coarse-offset_ + INDEXES_) & 0x7f

  uncorrupted-packet_:
    health_++

  // We are currently in state (probability from_weight) and got a counter.
  try-counter_ from-weight counter state next-state bonus:
    next-state &= STATE-MASK_
    if hash_[next-state] == counter:
      points := bonus * from-weight
      if points > next-states_[next-state]: next-states_[next-state] = points

  add number:
    number -= coarse-offset_ + offset_
    if not 0 <= number < 1024: return

    counter := number & INDEX-MASK_
    datum := number >> 5
    STATES_.repeat: next-states_[it] = 0
    STATES_.repeat: | from |
      try-counter_ states_[from] counter from from + 1 128  // Next expected counter.
      try-counter_ states_[from] counter from from + 2  64  // Lost packet.
      try-counter_ states_[from] counter from from + 3  32  // Two lost packets.
      try-counter_ states_[from] counter from from + 4  16  // Three lost packets.
      try-counter_ states_[from] counter from from + 5  8   // 4 lost packets.
      try-counter_ states_[from] hash_[from] from from  32  // Spurious packet.
    total := 0
    next-states_.do: total += it
    if total == 0:
      // We have no idea which state we are in, so just put 16th of the probability in each bucket.
      next-states_.size.repeat: next-states_[it] = 16
    else:
      // Normalize so the probabilities add up to about 256.
      STATES_.repeat:
        next-states_[it] = (((next-states_[it] << 8) / total) + 1).to-int

    best-index := -1
    best-weight := -1
    // Find which state we think we are most likely in.
    STATES_.repeat:
      weight := next-states_[it]
      if weight > best-weight and weight > MINIMAL-GOODNESS:
        best-weight = weight
        best-index = it
    if best-index != -1 and best-weight > MINIMAL-GOODNESS:
      // At the start of a sequence, clear the data arrays.
      if best-index < old-best-index_ - (STATES_ >> 1):
        wrote-from-start_ = true
        STATES_.repeat:
          data_[it] = 0
          data-weights_[it] = 0
    // Record the data we are receiving in the best place in the data array.
    STATES_.repeat:
      weight := next-states_[it]
      if weight > data-weights_[it]:
        data-weights_[it] = weight
        data_[it] = datum

    if best-index != -1:
      // At the end of a sequence, output the data array (our best guess).
      if best-index == STATES_ - 1 and wrote-from-start_:
        all-good := true
        STATES_.repeat: if data-weights_[it] < MINIMAL-GOODNESS: all-good = false
        if all-good:
          output-data
          wrote-from-start_ = false
    else:
      wrote-from-start_ = false
    tmp := next-states_
    next-states_ = states_
    states_ = tmp
    if best-index != -1: old-best-index_ = best-index

  got-raw-packet data:
    // Override this to get the data before error correction in the cases where
    // the algorithm is relatively sure it got things right.

  output-data:
    // We have collected 16 instances of 5 bits.  We rearrange them so that we
    // have 5 16 bit words, each of which is reduced to an 11 bit word by error
    // correction.  If all 5 can be corrected then we may have good data.  The
    // first 48 bits are fed to SHA256 and the result is compared with the last 7
    // bits.  If that succeeds, we feed the 48 bits to the application in the
    // form of 6 bytes.
    bad-slots := 0
    STATES_.repeat: if data-weights_[it] < MINIMAL-GOODNESS: bad-slots++
    if bad-slots >= 2:
      return  // Don't waste time if 2 or more packets were lost.

    if bad-slots == 0:
      got-raw-packet data_  // Mainly for testing.

    forty-eight := ByteArray 6
    forty-eight-pos := 0
    expected-checksum := 0

    5.repeat: | bit |
      word := 0
      STATES_.repeat:
        word |= ((data_[it] >> bit) & 1) << it
      corrected := hamming.fix-16-11 word
      if not corrected:
        corrupted-packet_
        return
      // We have 11 fresh bits, which will be spread over 2 or 3 bytes.
      bit-pos := forty-eight-pos & 7
      byte-pos := forty-eight-pos >> 3
      while corrected != 0:
        if byte-pos < 6:
          forty-eight[byte-pos++] |= corrected << bit-pos
        else:
          expected-checksum = corrected
        corrected >>= (8 - bit-pos)
        bit-pos = 0
      forty-eight-pos += 11
    calculated-checksum := sha256 forty-eight
    if (calculated-checksum[0] & 0x7f) != expected-checksum:
      corrupted-packet_
      return
    else:
    got-packet forty-eight
    uncorrupted-packet_

// Divides a payload into packets of 5 bits with error correction, which can be
// sent over an unreliable link, and reassembled with a high probability.
// The transmission takes place in packets of 5 bytes.
// There can be up to MAX_PACKETS_ (256) packets.
// Each packet is with 8 bits of packet number, 40 bits of data
// and 7 bits of SHA256 checksum.
// First two packets are:
// Packet 0
//   uint8 packet_number // 0
//   uint16 size  // little-endian.
//   uint8 message_checksum_0_23[3]
//   uint7 packet_checksum
// Packet 1
//   uint8 packet_number // 1
//   uint8 message_checksum_24_64[5]
//   uint7 packet_checksum
// Packets 2-255
//   uint8 packet_number // 2-255
//   uint8 payload[5]
//   uint7 packet_checksum
// The 254 packets with 5-byte payloads can transport a message up to 1270 bytes.
// Each 55 bit packet is expanded up to 80 bits by Hamming 16 11 error correction
// and then sent in 16 5-bit packets.
class WifiDataEncoder:
  payload_ := ?
  unencoded-packet_ := ByteArray 6  // First 48 bits of the packet (last 7 bits are the checksum).
  encoded-packet_ := List 5         // 5 sixteen-bit values: 80 bits, after error correction added.
  message-checksum_ := ?

  packet-number_ := 0
  intra-packet-position_ := 0
  prng-data_ := ?

  constructor .payload_:
    assert: payload_.size <= (MAX-PACKETS_ - HEADER-PACKETS_) * PAYLOAD-PER-PACKET_  // 1270.
    message-checksum_ = sha256 payload_
    prng-data_ = sha256 NOISE-KEY_
    prng-data_.size.repeat: prng-data_[it] &= INDEX-MASK_
    reset

  // Restarts the data stream, so we can transmit it again.
  reset:
    packet-number_ = -1
    intra-packet-position_ = STATES_ - 1

  // Returns the next 10 bit value to transmit to the receiver, or null when
  // the payload has been sent.
  next-value:
    data := next-5-bit-value_
    if not data: return null
    result := SMALL-PACKET-LIMIT_ + (data << 5) + prng-data_[intra-packet-position_]
    return result

  // Returns the next 5-bit value to transmit to the receiver, or null when the
  // payload has been sent.  This is combined with the sequence number before
  // transmission.
  next-5-bit-value_:
    assert: packet-number_ <= (payload_.size + PAYLOAD-PER-PACKET_ - 1) / PAYLOAD-PER-PACKET_ + HEADER-PACKETS_
    intra-packet-position_++
    if intra-packet-position_ == STATES_:
      packet-number_++
      intra-packet-position_ = 0
      if packet-number_ >= ((payload_.size + PAYLOAD-PER-PACKET_ - 1) / PAYLOAD-PER-PACKET_) + HEADER-PACKETS_:
        return null
      fill-next-packet_
    result := 0
    5.repeat:
      result |= ((encoded-packet_[it] >> intra-packet-position_) & 1) << it
    return result

  fill-next-packet_:
    unencoded-packet_[0] = packet-number_
    if packet-number_ == 0:
      // Packet 0 has the size and the first three bytes of the checksum.
      unencoded-packet_[1] = payload_.size & 0xff
      unencoded-packet_[2] = payload_.size >> 8
      3.repeat: unencoded-packet_[3 + it] = message-checksum_[it]
    else if packet-number_ == 1:
      // Packet 1 has the next 5 bytes of the checksum.
      PAYLOAD-PER-PACKET_.repeat: unencoded-packet_[1 + it] = message-checksum_[3 + it]
    else:
      // The rest of the packets have the message, zero padded.
      location := (packet-number_ - HEADER-PACKETS_) * PAYLOAD-PER-PACKET_
      PAYLOAD-PER-PACKET_.repeat:
        index := location + it
        unencoded-packet_[1 + it] = index >= payload_.size ? 0 : payload_[index]
    packet-checksum := (sha256 unencoded-packet_)[0]
    out-posn := 0
    for posn := 0; posn < 55; posn += 11:
      byte-posn := posn >> 3
      bit-posn := posn & 7
      next-byte := byte-posn >= 5 ? packet-checksum : unencoded-packet_[byte-posn + 1]
      next-next-byte := byte-posn >= 4 ? packet-checksum : unencoded-packet_[byte-posn + 2]
      eleven-bits := (unencoded-packet_[byte-posn] >> bit-posn) | (next-byte << (8 - bit-posn)) | (next-next-byte << (16 - bit-posn))
      eleven-bits &= 0x7ff
      sixteen-bits := hamming.encode-16-11 eleven-bits
      encoded-packet_[out-posn++] = sixteen-bits

// Gets a payload divided up into 5 bit packets with noise, and transmitted repeatedly.
// Reassembles a byte array with the data transmitted.
class WifiDataDecoder extends DataListener:
  arrived-data_ := ?
  arrived-header_ := null
  arrived-packet-map_ := ?
  arrived-packets_ := 0
  offset-listener_ := ?

  // Override this to get notified when we think we have a acquired a signal.
  // Time to stop channel hopping.
  got-signal:

  // Override this to get the byte array when the whole message has arrived.
  got-message byte-array:

  // Format of arrived_ data mirrors the packet format, but without packet numbers:
  // 0-1     Length
  // 2-9     SHA256 checksum, first 64 bits.
  // 10-1280 Data

  constructor:
    arrived-data_ = ByteArray PAYLOAD-PER-PACKET_ * (MAX-PACKETS_ - HEADER-PACKETS_)
    arrived-packet-map_ = ByteArray MAX-PACKETS_
    offset-listener_ = OffsetListener
    super null

  add datum:
    if not offset_:
      offset-listener_.add datum
      offset_ = offset-listener_.k
      if offset_:
        got-signal
    else:
      super datum - SMALL-PACKET-LIMIT_

  got-packet data:
    packet-num := data[0]
    might-be-worth-checking-the-checksum := false
    if arrived-packet-map_[packet-num] == 0:
      arrived-packets_++
      might-be-worth-checking-the-checksum = true
    arrived-packet-map_[packet-num] = 1
    PAYLOAD-PER-PACKET_.repeat:
      byte := data[1 + it]
      idx := packet-num * PAYLOAD-PER-PACKET_ + it
      if arrived-data_[idx] != byte:
        arrived-data_[idx] = byte
        might-be-worth-checking-the-checksum = true
    if might-be-worth-checking-the-checksum and arrived-packet-map_[0] != 0:
      size := arrived-data_[0] + (arrived-data_[1] << 8)
      if (size + PAYLOAD-PER-PACKET_ - 1) / PAYLOAD-PER-PACKET_ == arrived-packets_ - HEADER-PACKETS_:
        // We have collected enough data, so that it is worth checking the SHA256
        // checksum to see if all data has arrived correctly.
        overhead := PAYLOAD-PER-PACKET_ * HEADER-PACKETS_
        just-the-data := arrived-data_.copy overhead overhead + size
        calculated-checksum := sha256 just-the-data
        8.repeat:
          if arrived-data_[HEADER-PACKETS_ + it] != calculated-checksum[it]:
            // The checksum failed, so keep receiving data, and eventually the
            // correct data will arrive and overwrite the wrong data we
            // currently have.
            return
        got-message just-the-data
