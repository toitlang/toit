// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import crypto.sha256 show *
import crypto.hamming as hamming

prng_array:
  hash := sha256 NOISE_KEY_
  hash.size.repeat: hash[it] &= INDEX_MASK_
  return hash

class DataListenerTester extends DataListener:
  data_arrived := false

  constructor offset:
    super offset

  got_raw_packet data:
    data_arrived = true

  got_packet data:
    throw "Unused"

no_noise_data_test:
  prng := prng_array
  listener := OffsetListener
  offset := random 0 15
  10.repeat:
    16.repeat:
      listener.add prng[it] + offset + ((random 0 32) * 32)
  expect_equals offset listener.k

  data_listener := DataListenerTester offset

  5.repeat:
    16.repeat:
      data_listener.add prng[it] + offset + (("The correct data"[it] & 0x1f) << 5) + data_listener.coarse_offset_
  expect data_listener.data_arrived

inserted_random_data_test:
  prng := prng_array
  listener := OffsetListener
  offset := random 0 15
  10.repeat:
    16.repeat:
      listener.add prng[it] + offset + ((random 0 32) * 32)
      listener.add (random 0 1536)
  expect_equals offset listener.k

  data_listener := DataListenerTester offset

  5.repeat:
    16.repeat:
      data_listener.add prng[it] + offset + (("The correct data"[it] & 0x1f) << 5) + data_listener.coarse_offset_
      data_listener.add (random 0 1536)
  expect data_listener.data_arrived

main:
  set_random_seed "wifi"
  prng := prng_array
  test_no_noise prng
  test_no_noise_big_k prng
  test_present_present_missing_missing prng
  test_every_other_missing prng
  test_random_packets_missing prng
  test_every_other_packet_is_constant prng
  test_every_other_packet_is_random prng
  test_every_other_packet_is_random_and_one_quarter_are_missing prng
  test_every_other_packet_is_constant_and_one_quarter_are_missing prng
  no_noise_data_test
  inserted_random_data_test
  test_round_trip_x_percent_loss 17 0
  test_round_trip_x_percent_loss 0 51
  test_round_trip_x_percent_loss 17 51

test_no_noise prng:
  listener := OffsetListener
  10.repeat:
    16.repeat:
      listener.add prng[it] + 12 + ((random 0 32) * 32)
  expect_equals 12 listener.k

test_no_noise_big_k prng:
  listener := OffsetListener
  10.repeat:
    16.repeat:
      listener.add prng[it] + 44 + ((random 0 32) * 32)
  expect_equals 12 listener.k

test_present_present_missing_missing prng:
  listener := OffsetListener
  10.repeat:
    16.repeat:
      if (it % 4) < 2: listener.add prng[it] + 11 + ((random 0 32) * 32)
  expect_equals 11 listener.k

test_every_other_missing prng:
  // Only even packets get through.
  listener := OffsetListener
  10.repeat:
    16.repeat:
      if (it % 2) == 0: listener.add prng[it] + 15 + ((random 0 32) * 32)
  expect_equals 15 listener.k

  // Only odd packets get through.
  listener = OffsetListener
  10.repeat:
    16.repeat:
      if (it % 2) == 1: listener.add prng[it] + 0 + ((random 0 32) * 32)
  expect_equals 0 listener.k

test_random_packets_missing prng:
  // Only every second packet get through.
  listener := OffsetListener
  15.repeat:
    16.repeat:
      if (random 0 2) == 0: listener.add prng[it] + 15 + ((random 0 32) * 32)
  expect_equals 15 listener.k

  // Only every third packet gets through.
  listener = OffsetListener
  30.repeat:
    16.repeat:
      if (random 0 3) == 0: listener.add prng[it] + 1 + ((random 0 32) * 32)
  expect_equals 1 listener.k

  // Only every 4th packet gets through.
  listener = OffsetListener
  45.repeat:
    16.repeat:
      if (random 0 4) == 0: listener.add prng[it] + 1 + ((random 0 32) * 32)
  expect_equals 1 listener.k

  // Only every 5th packet gets through.
  listener = OffsetListener
  100.repeat:
    16.repeat:
      if (random 0 5) == 0: listener.add prng[it] + 1 + ((random 0 32) * 32)
  expect_equals 1 listener.k

test_every_other_packet_is_constant prng:
  listener := OffsetListener
  10.repeat:
    16.repeat:
      listener.add prng[it] + 6 + ((random 0 32) * 32)
      listener.add 44 + ((random 0 32) * 32)
  expect_equals 6 listener.k

test_every_other_packet_is_random prng:
  listener := OffsetListener
  10.repeat:
    16.repeat:
      listener.add prng[it] + 3 + ((random 0 32) * 32)
      listener.add (random 0 31) + ((random 0 32) * 32)
  expect_equals 3 listener.k

test_every_other_packet_is_random_and_one_quarter_are_missing prng:
  listener := OffsetListener
  14.repeat:  // Takes a bit longer.
    16.repeat:
      if (it % 4) != 2: listener.add prng[it] + 3 + ((random 0 32) * 32)
      listener.add (random 0 31) + ((random 0 32) * 32)
  expect_equals 3 listener.k

test_every_other_packet_is_constant_and_one_quarter_are_missing prng:
  listener := OffsetListener
  15.repeat:  // Takes a lot longer.
    16.repeat:
      if (it % 4) != 2: listener.add prng[it] + 3 + ((random 0 32) * 32)
      listener.add 12 + ((random 0 32) * 32)
  expect_equals 3 listener.k

class TestStringDecoder extends WifiDataDecoder:
  msg := null
  got := false

  got_message byte_array:
    got = true
    msg = byte_array.to_string

// Loses 'loss' percent of packets, tests we still get the message.
// Inserts random packets 'insertion' percent of the time
test_round_trip_x_percent_loss loss insertion:
  decoder := TestStringDecoder
  MSG ::= "The correct message at $loss% loss and $insertion% insertion!"
  encoder := WifiDataEncoder MSG

  prng := prng_array

  offset := random 0 15

  ctr := 0
  while not decoder.got:
    value := encoder.next_value
    if not value:
      encoder.reset
      value = encoder.next_value
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
STATE_MASK_ ::= 0xf
INDEXES_ ::= 0x20  // Each state has an index in this range.
INDEX_MASK_ ::= 0x1f

// We hash this string to get a random-number sequence that helps us
// distinguish noise from signal.  This key has some nice properties
// where sequential packets don't have the same size.
NOISE_KEY_ ::= "hued"

HEADER_PACKETS_ ::= 2
BYTES_PER_PACKET_ ::= 6   // Not counting 7-bit packet checksum.
PAYLOAD_PER_PACKET_ ::= 5 // Not counting packet number.
MAX_PACKETS_ ::= 0x100

SMALL_PACKET_LIMIT_ ::= 96  // We ignore packets smaller than this, since they are likely noise.

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
  offset_weights_ := List INDEXES_ 0
  state_budget_ := List STATES_
  prev_ := 0
  prev_prev_ := 0
  sum_ := ?
  static MAX_WEIGHT ::= INDEXES_ * 256
  static DECAY ::= INDEXES_ >> 2
  static GOOD_MATCH_BONUS ::= INDEXES_ + (INDEXES_ >> 1)
  static POOR_MATCH_BONUS ::= INDEXES_
  static MIN_BUDGET ::= STATES_ >> 1

  constructor:
    sum_ = sha256 NOISE_KEY_
    sum_.size.repeat: sum_[it] &= INDEX_MASK_
    state_budget_.size.repeat: state_budget_[it] = List INDEXES_ 0

  correspondance a b c d:
    return ((a - b) & INDEX_MASK_) == ((c - d) & INDEX_MASK_)

  add counter:
    counter &= INDEX_MASK_
    STATES_.repeat: | state |
      offset := (counter - sum_[state]) & INDEX_MASK_
      try_match_ state offset state - 1 counter prev_      GOOD_MATCH_BONUS
      try_match_ state offset state - 1 counter prev_prev_ POOR_MATCH_BONUS
      try_match_ state offset state - 2 counter prev_      POOR_MATCH_BONUS
      budget := state_budget_[state]
      INDEXES_.repeat:
        old_budget := budget[it]
        budget[it]++
    prev_prev_ = prev_
    prev_ = counter
    INDEXES_.repeat:
      old_weight := offset_weights_[it]
      // Clamp between 0 and MAX_WEIGHT
      offset_weights_[it] = old_weight <= DECAY ? 0 : (old_weight > MAX_WEIGHT ? MAX_WEIGHT : old_weight - DECAY)

  try_match_ state offset prev_state counter prev bonus:
    prev_state &= STATE_MASK_
    if correspondance sum_[state] sum_[prev_state] counter prev:
      if state_budget_[state][offset] >= MIN_BUDGET:
        state_budget_[state][offset] = 0
        offset_weights_[offset] += bonus

  k:
    winner := null
    INDEXES_.repeat:
      if offset_weights_[it] >= 1000:
        winner = it
    INDEXES_.repeat:
      if winner and winner != it and offset_weights_[it] > 250:
        // More than one possible result.  Reset the weights and try again.
        offset_weights_.size.repeat: offset_weights_[it] = 0
        return null
    return winner

MINIMAL_GOODNESS ::= 30

abstract class DataListener:
  // A list of how likely it is that we are in a given state.
  states_ := List STATES_ 1
  next_states_ := List STATES_ 1
  data_ := List STATES_ 0
  data_weights_ := List STATES_ 0
  wrote_from_start_ := false
  hash_ := ?
  old_best_index_ := STATES_ - 1
  health_ := 0
  coarse_offset_ := 64

  // The constant offset of the data.
  offset_ := 0

  constructor .offset_:
    hash_ = sha256 NOISE_KEY_
    hash_.size.repeat: hash_[it] &= INDEX_MASK_

  // Gets a 16 element array with some data we think was transmitted to us.  The first
  // byte is the packet index, and the last 5 are 5 bytes of data.
  abstract got_packet data

  corrupted_packet_:
    health_--
    // If we see too many corrupted packets this probably means the numbers are
    // offset by some factor of 32.  Try a different factor (up to 96).
    if health_ < -20:
      health_ = 0
      coarse_offset_ = (coarse_offset_ + INDEXES_) & 0x7f

  uncorrupted_packet_:
    health_++

  // We are currently in state (probability from_weight) and got a counter.
  try_counter_ from_weight counter state next_state bonus:
    next_state &= STATE_MASK_
    if hash_[next_state] == counter:
      points := bonus * from_weight
      if points > next_states_[next_state]: next_states_[next_state] = points

  add number:
    number -= coarse_offset_ + offset_
    if not 0 <= number < 1024: return

    counter := number & INDEX_MASK_
    datum := number >> 5
    STATES_.repeat: next_states_[it] = 0
    STATES_.repeat: | from |
      try_counter_ states_[from] counter from from + 1 128  // Next expected counter.
      try_counter_ states_[from] counter from from + 2  64  // Lost packet.
      try_counter_ states_[from] counter from from + 3  32  // Two lost packets.
      try_counter_ states_[from] counter from from + 4  16  // Three lost packets.
      try_counter_ states_[from] counter from from + 5  8   // 4 lost packets.
      try_counter_ states_[from] hash_[from] from from  32  // Spurious packet.
    total := 0
    next_states_.do: total += it
    if total == 0:
      // We have no idea which state we are in, so just put 16th of the probability in each bucket.
      next_states_.size.repeat: next_states_[it] = 16
    else:
      // Normalize so the probabilities add up to about 256.
      STATES_.repeat:
        next_states_[it] = (((next_states_[it] << 8) / total) + 1).to_int

    best_index := -1
    best_weight := -1
    // Find which state we think we are most likely in.
    STATES_.repeat:
      weight := next_states_[it]
      if weight > best_weight and weight > MINIMAL_GOODNESS:
        best_weight = weight
        best_index = it
    if best_index != -1 and best_weight > MINIMAL_GOODNESS:
      // At the start of a sequence, clear the data arrays.
      if best_index < old_best_index_ - (STATES_ >> 1):
        wrote_from_start_ = true
        STATES_.repeat:
          data_[it] = 0
          data_weights_[it] = 0
    // Record the data we are receiving in the best place in the data array.
    STATES_.repeat:
      weight := next_states_[it]
      if weight > data_weights_[it]:
        data_weights_[it] = weight
        data_[it] = datum

    if best_index != -1:
      // At the end of a sequence, output the data array (our best guess).
      if best_index == STATES_ - 1 and wrote_from_start_:
        all_good := true
        STATES_.repeat: if data_weights_[it] < MINIMAL_GOODNESS: all_good = false
        if all_good:
          output_data
          wrote_from_start_ = false
    else:
      wrote_from_start_ = false
    tmp := next_states_
    next_states_ = states_
    states_ = tmp
    if best_index != -1: old_best_index_ = best_index

  got_raw_packet data:
    // Override this to get the data before error correction in the cases where
    // the algorithm is relatively sure it got things right.

  output_data:
    // We have collected 16 instances of 5 bits.  We rearrange them so that we
    // have 5 16 bit words, each of which is reduced to an 11 bit word by error
    // correction.  If all 5 can be corrected then we may have good data.  The
    // first 48 bits are fed to SHA256 and the result is compared with the last 7
    // bits.  If that succeeds, we feed the 48 bits to the application in the
    // form of 6 bytes.
    bad_slots := 0
    STATES_.repeat: if data_weights_[it] < MINIMAL_GOODNESS: bad_slots++
    if bad_slots >= 2:
      return  // Don't waste time if 2 or more packets were lost.

    if bad_slots == 0:
      got_raw_packet data_  // Mainly for testing.

    forty_eight := ByteArray 6
    forty_eight_pos := 0
    expected_checksum := 0

    5.repeat: | bit |
      word := 0
      STATES_.repeat:
        word |= ((data_[it] >> bit) & 1) << it
      corrected := hamming.fix_16_11 word
      if not corrected:
        corrupted_packet_
        return
      // We have 11 fresh bits, which will be spread over 2 or 3 bytes.
      bit_pos := forty_eight_pos & 7
      byte_pos := forty_eight_pos >> 3
      while corrected != 0:
        if byte_pos < 6:
          forty_eight[byte_pos++] |= corrected << bit_pos
        else:
          expected_checksum = corrected
        corrected >>= (8 - bit_pos)
        bit_pos = 0
      forty_eight_pos += 11
    calculated_checksum := sha256 forty_eight
    if (calculated_checksum[0] & 0x7f) != expected_checksum:
      corrupted_packet_
      return
    else:
    got_packet forty_eight
    uncorrupted_packet_

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
  unencoded_packet_ := ByteArray 6  // First 48 bits of the packet (last 7 bits are the checksum).
  encoded_packet_ := List 5         // 5 sixteen-bit values: 80 bits, after error correction added.
  message_checksum_ := ?

  packet_number_ := 0
  intra_packet_position_ := 0
  prng_data_ := ?

  constructor .payload_:
    assert: payload_.size <= (MAX_PACKETS_ - HEADER_PACKETS_) * PAYLOAD_PER_PACKET_  // 1270.
    message_checksum_ = sha256 payload_
    prng_data_ = sha256 NOISE_KEY_
    prng_data_.size.repeat: prng_data_[it] &= INDEX_MASK_
    reset

  // Restarts the data stream, so we can transmit it again.
  reset:
    packet_number_ = -1
    intra_packet_position_ = STATES_ - 1

  // Returns the next 10 bit value to transmit to the receiver, or null when
  // the payload has been sent.
  next_value:
    data := next_5_bit_value_
    if not data: return null
    result := SMALL_PACKET_LIMIT_ + (data << 5) + prng_data_[intra_packet_position_]
    return result

  // Returns the next 5-bit value to transmit to the receiver, or null when the
  // payload has been sent.  This is combined with the sequence number before
  // transmission.
  next_5_bit_value_:
    assert: packet_number_ <= (payload_.size + PAYLOAD_PER_PACKET_ - 1) / PAYLOAD_PER_PACKET_ + HEADER_PACKETS_
    intra_packet_position_++
    if intra_packet_position_ == STATES_:
      packet_number_++
      intra_packet_position_ = 0
      if packet_number_ >= ((payload_.size + PAYLOAD_PER_PACKET_ - 1) / PAYLOAD_PER_PACKET_) + HEADER_PACKETS_:
        return null
      fill_next_packet_
    result := 0
    5.repeat:
      result |= ((encoded_packet_[it] >> intra_packet_position_) & 1) << it
    return result

  fill_next_packet_:
    unencoded_packet_[0] = packet_number_
    if packet_number_ == 0:
      // Packet 0 has the size and the first three bytes of the checksum.
      unencoded_packet_[1] = payload_.size & 0xff
      unencoded_packet_[2] = payload_.size >> 8
      3.repeat: unencoded_packet_[3 + it] = message_checksum_[it]
    else if packet_number_ == 1:
      // Packet 1 has the next 5 bytes of the checksum.
      PAYLOAD_PER_PACKET_.repeat: unencoded_packet_[1 + it] = message_checksum_[3 + it]
    else:
      // The rest of the packets have the message, zero padded.
      location := (packet_number_ - HEADER_PACKETS_) * PAYLOAD_PER_PACKET_
      PAYLOAD_PER_PACKET_.repeat:
        index := location + it
        unencoded_packet_[1 + it] = index >= payload_.size ? 0 : payload_[index]
    packet_checksum := (sha256 unencoded_packet_)[0]
    out_posn := 0
    for posn := 0; posn < 55; posn += 11:
      byte_posn := posn >> 3
      bit_posn := posn & 7
      next_byte := byte_posn >= 5 ? packet_checksum : unencoded_packet_[byte_posn + 1]
      next_next_byte := byte_posn >= 4 ? packet_checksum : unencoded_packet_[byte_posn + 2]
      eleven_bits := (unencoded_packet_[byte_posn] >> bit_posn) | (next_byte << (8 - bit_posn)) | (next_next_byte << (16 - bit_posn))
      eleven_bits &= 0x7ff
      sixteen_bits := hamming.encode_16_11 eleven_bits
      encoded_packet_[out_posn++] = sixteen_bits

// Gets a payload divided up into 5 bit packets with noise, and transmitted repeatedly.
// Reassembles a byte array with the data transmitted.
class WifiDataDecoder extends DataListener:
  arrived_data_ := ?
  arrived_header_ := null
  arrived_packet_map_ := ?
  arrived_packets_ := 0
  offset_listener_ := ?

  // Override this to get notified when we think we have a acquired a signal.
  // Time to stop channel hopping.
  got_signal:

  // Override this to get the byte array when the whole message has arrived.
  got_message byte_array:

  // Format of arrived_ data mirrors the packet format, but without packet numbers:
  // 0-1     Length
  // 2-9     SHA256 checksum, first 64 bits.
  // 10-1280 Data

  constructor:
    arrived_data_ = ByteArray PAYLOAD_PER_PACKET_ * (MAX_PACKETS_ - HEADER_PACKETS_)
    arrived_packet_map_ = ByteArray MAX_PACKETS_
    offset_listener_ = OffsetListener
    super null

  add datum:
    if not offset_:
      offset_listener_.add datum
      offset_ = offset_listener_.k
      if offset_:
        got_signal
    else:
      super datum - SMALL_PACKET_LIMIT_

  got_packet data:
    packet_num := data[0]
    might_be_worth_checking_the_checksum := false
    if arrived_packet_map_[packet_num] == 0:
      arrived_packets_++
      might_be_worth_checking_the_checksum = true
    arrived_packet_map_[packet_num] = 1
    PAYLOAD_PER_PACKET_.repeat:
      byte := data[1 + it]
      idx := packet_num * PAYLOAD_PER_PACKET_ + it
      if arrived_data_[idx] != byte:
        arrived_data_[idx] = byte
        might_be_worth_checking_the_checksum = true
    if might_be_worth_checking_the_checksum and arrived_packet_map_[0] != 0:
      size := arrived_data_[0] + (arrived_data_[1] << 8)
      if (size + PAYLOAD_PER_PACKET_ - 1) / PAYLOAD_PER_PACKET_ == arrived_packets_ - HEADER_PACKETS_:
        // We have collected enough data, so that it is worth checking the SHA256
        // checksum to see if all data has arrived correctly.
        overhead := PAYLOAD_PER_PACKET_ * HEADER_PACKETS_
        just_the_data := arrived_data_.copy overhead overhead + size
        calculated_checksum := sha256 just_the_data
        8.repeat:
          if arrived_data_[HEADER_PACKETS_ + it] != calculated_checksum[it]:
            // The checksum failed, so keep receiving data, and eventually the
            // correct data will arrive and overwrite the wrong data we
            // currently have.
            return
        got_message just_the_data
