// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import bytes
import crypto
import net
import net.udp as udp
import net.tcp as tcp
import at
import log
import monitor
import serial.ports.uart as uart
import xmodem_1k
import experimental.exceptions show *

import .cellular
import .cellular_base

CONNECTED_STATE_  ::= 1 << 0
READ_STATE_       ::= 1 << 1
CLOSE_STATE_      ::= 1 << 2

monitor SocketState_:
  state_/int := 0
  dirty_/bool := false

  wait_for state --error_state=CLOSE_STATE_:
    bits := (state | error_state)
    await: state_ & bits != 0
    dirty_ = false
    return state_ & bits

  set_state state:
    dirty_ = true
    state_ |= state

  clear state:
    // Guard against clearing inread state (e.g. if state was updated
    // in between wait_for and clear).
    if not dirty_:
      state_ &= ~state

class Socket_:
  state_ ::= SocketState_
  cellular_/SequansCellular ::= ?
  id_ := ?

  error_ := 0

  constructor .cellular_ .id_:

  closed_:
    state_.set_state CLOSE_STATE_

  get_id_:
    if not id_: throw "socket is closed"
    return id_

  /**
  Calls the given $block.
  Captures exceptions and translates them to socket-related errors.
  */
  socket_call [block]:
    // Ensure no other socket call can come in between.
    cellular_.at_.do: | session/at.Session |
      e := catch --trace:
        return block.call session
      throw (last_error_ session e)
    unreachable

  last_error_ cellular/at.Session original_error/string="":
    throw (UnknownException "SOCKET ERROR $original_error")

class TcpSocket extends Socket_ implements tcp.Socket:
  static MAX_SIZE_ ::= 1500
  static WRITE_TIMEOUT_ ::= Duration --s=5

  peer_address/net.SocketAddress ::= ?

  set_no_delay value/bool:

  constructor cellular id .peer_address:
    super cellular id

    socket_call: | session/at.Session |
      // Configure socket to allow 8s timeout, and use 10s for the overall
      // AT command.
      session.set "+SQNSCFG" [
        get_id_,
        cellular_.cid_,
        300,  // Packet size, unused. Default value.
        0,    // Idle timeout, disabled.
        80,   // Connection timeout, 8s.
        50,   // Data write timeout, 5s. Default value.
      ]

      result := session.send
        SQNSD.tcp get_id_ peer_address
      if result.code == "OK": state_.set_state CONNECTED_STATE_

  local_address -> net.SocketAddress:
    return net.SocketAddress
      net.IpAddress.parse "127.0.0.1"
      0

  connect_:
    state := cellular_.wait_for_urc_: state_.wait_for CONNECTED_STATE_
    if state & CONNECTED_STATE_ != 0: return
    throw "CONNECT_FAILED: $error_"

  read -> ByteArray?:
    while true:
      state := cellular_.wait_for_urc_: state_.wait_for READ_STATE_
      if state & CLOSE_STATE_ != 0:
        return null
      else if state & READ_STATE_ != 0:
        socket_call: | session/at.Session |
          r := session.set "+SQNSI" [get_id_]
          if r.single[3] > 0:
            r = session.set "+SQNSRECV" [get_id_, 1500]
            out := r.single
            return out[1]
        state_.clear READ_STATE_
      else:
        throw "SOCKET ERROR"

  write data from/int=0 to/int=data.size -> int:
    if to - from > MAX_SIZE_:
      to = from + MAX_SIZE_

    data = data[from..to]

    e := catch --unwind=(: it is not UnavailableException):
      socket_call:
        // Create a custom command, so we can experiment with the timeout.
        command ::= at.Command.set
            "+SQNSSENDEXT"
            --parameters=[get_id_, data.size]
            --data=data
            --timeout=WRITE_TIMEOUT_
        start ::= Time.monotonic_us
        it.send command
        elapsed ::= Time.monotonic_us - start
        if elapsed > at.Command.DEFAULT_TIMEOUT.in_us:
          cellular_.logger_.warn "slow tcp write" --tags={"time": "$(elapsed / 1_000) ms"}
      // Give processing time to other tasks, to avoid busy write-loop that starves readings.
      yield
      return data.size

    // Buffer full, wait for buffer to be drained.
    sleep --ms=100
    return 0

  /**
  Closes the socket for write. The socket is still be able to read incoming data.
  */
  close_write:
    throw "UNSUPPORTED"

  // Immediately close the socket and release any resources associated.
  close:
    if id_:
      id := id_
      closed_
      id_ = null
      cellular_.at_.do:
        if not it.is_closed:
          it.set "+SQNSH" [id]
      cellular_.sockets_.remove id

  mtu -> int:
    return 1500

class UdpSocket extends Socket_ implements udp.Socket:
  remote_address_ := null
  port_/int

  constructor cellular/SequansCellular id/int .port_/int:
    super cellular id

  local_address -> net.SocketAddress:
    return net.SocketAddress
      net.IpAddress.parse "127.0.0.1"
      port_

  connect address/net.SocketAddress:
    remote_address_ = address

    socket_call: | session/at.Session |
      session.send
        SQNSD.udp get_id_ port_ remote_address_

  write data/ByteArray from=0 to=data.size -> int:
    if from != 0 or to != data.size: data = data[from..to]
    return send_ remote_address_ data

  read -> ByteArray?:
    msg := receive
    if not msg: return null
    return msg.data

  send datagram/udp.Datagram -> int:
    return send_ datagram.address datagram.data

  send_ address data -> int:
    if data.size > mtu: throw "PAYLOAD_TO_LARGE"
    if not remote_address_: throw "NOT_CONNECTED"
    if address != remote_address_: throw "WRONG_ADDRESS"
    res := cellular_.at_.do: it.set "+SQNSSENDEXT" [get_id_, data.size] --data=data
    return data.size

  receive -> udp.Datagram?:
    while true:
      state := state_.wait_for READ_STATE_
      if state & CLOSE_STATE_ != 0:
        return null
      else if state & READ_STATE_ != 0:
        socket_call: | session/at.Session |
          r := session.set "+SQNSI" [get_id_]
          if r.single[3] > 0:
            r = session.set "+SQNSRECV" [get_id_, 1500]
            out := r.single
            return udp.Datagram
              out[1]
              remote_address_
        state_.clear READ_STATE_
      else:
        throw "SOCKET ERROR"

  close:
    if id_:
      id := id_
      id_ = null
      closed_
      cellular_.at_.do:
        if not it.is_closed:
          it.set "+SQNSH" [id]
      cellular_.sockets_.remove id

  mtu -> int:
    return 1500

  broadcast -> bool: return false

  broadcast= value/bool: throw "BROADCAST_UNSUPPORTED"

/**
Base driver for Sequans Cellular devices, communicating over CAT-NB1 and/or CAT-M1.
*/
abstract class SequansCellular extends CellularBase:
  tcp_connect_mutex_ ::= monitor.Mutex

  closed_/monitor.Latch ::= monitor.Latch

  /**
  Called when the driver should reset.
  */
  abstract on_reset session/at.Session

  constructor
      uart/uart.Port
      --logger=log.default
      --default_baud_rate=Cellular.DEFAULT_BAUD_RATE
      --preferred_baud_rate=null
      --use_psm:
    at_session := configure_at_ uart logger

    super uart at_session
      --constants = SequansConstants
      --default_baud_rate=default_baud_rate
      --preferred_baud_rate=preferred_baud_rate
      --use_psm=use_psm

    at_session_.register_urc "+SQNSRING"::
      sockets_.get it[0]
        --if_present=: it.state_.set_state READ_STATE_

    at_session_.register_urc "+SQNSH"::
      sockets_.get it[0]
        --if_present=: it.state_.set_state CLOSE_STATE_

    at_session_.register_urc "+SQNSSHDN"::
      closed_.set null

  static configure_at_ uart logger -> at.Session:
    session := at.Session
      uart
      uart
      --logger=logger
      --data_marker='>'
      --command_delay=Duration --ms=20

    session.add_ok_termination "CONNECT"
    session.add_error_termination "+CME ERROR"
    session.add_error_termination "+CMS ERROR"
    session.add_error_termination "NO CARRIER"

    session.add_response_parser "+SQNSRECV" :: | reader |
      line := reader.read_bytes_until '\r'
      parts := at.parse_response line
      if parts[1] == 0:
        [0]
      else:
        reader.skip 1  // Skip '\n'.
        [parts[1], reader.read_bytes parts[1]]

    session.add_response_parser "+SQNBANDSEL" :: | reader |
      line := reader.read_bytes_until session.s3
      at.parse_response line --plain

    session.add_response_parser "+SQNDNSLKUP" :: | reader |
      line := reader.read_bytes_until session.s3
      at.parse_response line --plain

    return session

  close:
    try:
      sockets_.values.do: it.closed_
      at_.do:
        if not it.is_closed:
          it.send CFUN.offline
          if false:
            // TODO(kasper): Shutting down seems to get us in trouble. After this,
            // the Monarch chips stops responding to AT commands - even after unplugging
            // it and waiting for a while? Weird.
            it.send SQNSSHDN
            // Wait for definitive shutdown as indicated by receiving
            // the +SQNSSHDN URC message.
            closed_.get
    finally:
      at_session_.close
      uart_.close

  iccid:
    r := at_.do: it.read "+SQNCCID"
    return r.last[0]

  // Overriden since it doesn't appear to support deregister.
  detach:

  // Override disable_radio, as the SIM cannot be accessed unless airplane mode is used.
  disable_radio_ session/at.Session:
    session.send CFUN.airplane

  // Override scan_for_operators as the Monarch modem fails when scanning for operators.
  scan_for_operators -> List:
    return []

  // Override can_scan_for_operators as the Monarch modem fails when connecting to specific operators.
  can_connect_to_operator -> bool:
    return false

  configure apn --bands=null --rats=null:
    at_.do: | session/at.Session |
      // Set connection arguments.
      should_reboot := false
      while true:
        if should_reboot: wait_for_ready_ session

        enter_configuration_mode_ session

        should_reboot = false

        session.set "+CPSMS" [0]
        session.set "+CEDRXS" [0]
        // Disable UART Break events in case of delayed URCs (default is to break after
        // 100ms).
        session.set "+SQNIBRCFG" [0]
        // Put the modem into deep-sleep mode after 100ms of low RTS.
        session.set "+SQNIPSCFG" [1, 100]

        if bands:
          bands_str := ""
          bands.size.repeat:
            if it > 0: bands_str += ","
            bands_str += bands[it].stringify
          set_band_mask_ session bands_str

        if (get_apn_ session) != apn:
          set_apn_ session apn
          should_reboot = true

        if should_reboot:
          reboot_ session
          continue

        break

  set_band_mask_ session/at.Session bands/string:
    // Set mask for m1.
    session.set "+SQNBANDSEL" [0, "standard", bands] --check=false
    // Set mask for nbiot.
    session.set "+SQNBANDSEL" [1, "standard", bands] --check=false

  reset:
    detach
    // Factory reset.
    at_.do: | session/at.Session |
      session.send RestoreFactoryDefaults
      session.action "^RESET"
      wait_for_ready_ session

  reboot_ session/at.Session:
    on_reset session
    wait_for_ready_ session

  set_baud_rate_ session/at.Session baud_rate/int:
    // NOP for Sequans devices.

  network_interface -> net.Interface:
    return Interface_ this

class SequansConstants implements Constants:
  RatCatM1 -> int?: return null

class Interface_ extends net.Interface:
  static FREE_PORT_RANGE ::= 1 << 14

  cellular_/SequansCellular
  tcp_connect_mutex_ ::= monitor.Mutex
  free_port_ := 0

  constructor .cellular_:

  resolve host/string -> List:
    // First try parsing it as an ip.
    catch:
      return [net.IpAddress.parse host]

    cellular_.at_.do:
      result := it.send
        SQNDNSLKUP host
      return result.single[1..].map: net.IpAddress.parse it
    unreachable

  udp_open -> udp.Socket:
    return udp_open --port=null

  udp_open --port/int? -> udp.Socket:
    id := socket_id_
    if not port or port == 0:
      // Best effort for rolling a free port.
      port = FREE_PORT_RANGE + free_port_++ % FREE_PORT_RANGE
    socket := UdpSocket cellular_ id port
    cellular_.sockets_.update id --if_absent=(: socket): throw "socket already exists"
    return socket

  tcp_connect address/net.SocketAddress -> tcp.Socket:
    id := socket_id_
    socket := TcpSocket cellular_ id address
    cellular_.sockets_.update id --if_absent=(: socket): throw "socket already exists"

    catch --unwind=(: socket.error_ = 1; true): socket.connect_

    return socket

  tcp_listen port/int -> tcp.ServerSocket:
    throw "UNIMPLEMENTED"

  socket_id_ -> int:
    6.repeat:
      if not cellular_.sockets_.contains it + 1: return it + 1
    throw
      ResourceExhaustedException "no more sockets available"

class SQNDNSLKUP extends at.Command:
  static TIMEOUT ::= Duration --s=20

  constructor host/string:
    super.set "+SQNDNSLKUP" --parameters=[host] --timeout=TIMEOUT

class SQNSSHDN extends at.Command:
  static TIMEOUT ::= Duration --s=10

  constructor:
    super.set "+SQNSSHDN" --timeout=TIMEOUT

class SQNSD extends at.Command:
  static TCP_TIMEOUT ::= Duration --s=20

  constructor.tcp id/int address/net.SocketAddress:
    super.set
      "+SQNSD"
      --parameters=[id, 0, address.port, address.ip.stringify, 0, 0, 1]
      --timeout=TCP_TIMEOUT

  constructor.udp id/int local_port/int address/net.SocketAddress:
    super.set
      "+SQNSD"
      --parameters=[id, 1, address.port, address.ip.stringify, 0, local_port, 1, 0]

class RestoreFactoryDefaults extends at.Command:
  static TIMEOUT ::= Duration --s=10

  constructor:
    super.action "&F" --timeout=TIMEOUT
