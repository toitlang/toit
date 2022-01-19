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
import uart
import xmodem_1k
import experimental.exceptions show *

import .cellular
import .cellular_base

SOCKET_LEVEL_TCP_ ::= 6

CONNECTED_STATE_  ::= 1 << 0
READ_STATE_       ::= 1 << 1
CLOSE_STATE_      ::= 1 << 2

/**
Deprecated. Use package ublox-cellular (https://github.com/toitware/ublox-cellular).
*/
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
  cellular_/UBloxCellular
  id_ := ?

  error_ := 0

  constructor .cellular_ .id_:

  closed_:
    if id_: cellular_.sockets_.remove id_
    state_.set_state CLOSE_STATE_
    id_ = null

  get_id_:
    if not id_: throw "socket is closed"
    return id_

  /**
  Deprecated. Use package ublox-cellular (https://github.com/toitware/ublox-cellular).

  Will capture exceptions and translate to socket-related errors.
  */
  socket_call [block]:
    // Ensure no other socket call can come in between.
    cellular_.at_.do: | session |
      e := catch:
        return block.call session
      throw (last_error_ session e)
    unreachable

  /**
  Deprecated. Use package ublox-cellular (https://github.com/toitware/ublox-cellular).

  Returns the latest socket error (even if OK).
  */
  last_error_ session/at.Session original_error/string="" -> Exception:
    error/int := (session.set "+USOCTL" [get_id_, 1]).last[2]
    if error == 0: // OK
      throw (UnavailableException original_error)
    if error == 11: // EWOULDBLOCK / EAGAIN
      throw (UnavailableException original_error)
    throw (UnknownException "SOCKET ERROR $error ($original_error)")

class TcpSocket extends Socket_ implements tcp.Socket:
  static OPTION_TCP_NO_DELAY_   ::= 1
  static OPTION_TCP_KEEP_ALIVE_ ::= 2
  static CTRL_TCP_OUTGOING_ ::= 11

  static MAX_BUFFERED_ ::= 10240
  // Sara R4 only supports up to 1024 bytes per write.
  static MAX_SIZE_ ::= 1024

  peer_address/net.SocketAddress ::= ?

  set_no_delay value/bool:
    cellular_.at_.do: it.set "+USOSO" [get_id_, SOCKET_LEVEL_TCP_, OPTION_TCP_NO_DELAY_, value ? 1 : 0]

  constructor cellular/UBloxCellular id/int .peer_address:
    super cellular id

  local_address -> net.SocketAddress:
    return net.SocketAddress
      net.IpAddress.parse "127.0.0.1"
      0

  connect_:
    cmd ::= cellular_.async_socket_connect ? USOCO.async get_id_ peer_address : USOCO get_id_ peer_address
    cellular_.at_.do: it.send cmd
    state := cellular_.wait_for_urc_: state_.wait_for CONNECTED_STATE_
    if state & CONNECTED_STATE_ != 0: return
    throw "CONNECT_FAILED: $error_"

  read -> ByteArray?:
    while true:
      state := cellular_.wait_for_urc_: state_.wait_for READ_STATE_
      if state & CLOSE_STATE_ != 0:
        return null
      else if state & READ_STATE_ != 0:
        r := cellular_.at_.do: it.set "+USORD" [get_id_, 1024]
        out := r.single
        if out[1] > 0: return out[2]
        state_.clear READ_STATE_
      else:
        throw "SOCKET ERROR"

  write data from/int=0 to/int=data.size -> int:
    if to - from > MAX_SIZE_: to = from + MAX_SIZE_
    data = data[from..to]

    // There is no safe way to detect how much data was sent, if an EAGAIN (buffer full)
    // was encountered. Instead query how much date is buffered, so we never hit it.
    buffered := (cellular_.at_.do: it.set "+USOCTL" [get_id_, CTRL_TCP_OUTGOING_]).single[2]
    if buffered + data.size > MAX_BUFFERED_:
      // The buffer is full. Note that it can only drain at ~3.2 kbyte/s.
      sleep --ms=100
      // Update outgoing.
      return 0

    e := catch:
      socket_call: | session/at.Session |
        session.set "+USOWR" [get_id_, data.size] --data=data
      // Give processing time to other tasks, to avoid busy write-loop that starves readings.
      yield
      return data.size
    if e is UnavailableException: return 0
    throw e

  // Close the socket for write. The socket will still be able to read incoming data.
  close_write:
    throw "UNSUPPORTED"

  // Immediately close the socket and release any resources associated.
  close:
    if id_:
      id := id_
      closed_
      // Allow the close command to fail. If the socket has already been closed
      // but we haven't processed the notification yet, we sometimes get a
      // harmless 'operation not allowed' message that we ignore.
      catch --trace=(: it != "+CME ERROR: Operation not allowed []"):
        cellular_.at_.do:
          if not it.is_closed:
            it.send
              cellular_.async_socket_close ? USOCL.async id : USOCL id

  mtu -> int:
    // Observed that packages are fragmented into 1390 chunks.
    return 1390

class UdpSocket extends Socket_ implements udp.Socket:
  remote_address_ := null

  constructor cellular/UBloxCellular id/int:
    super cellular id

  local_address -> net.SocketAddress:
    return net.SocketAddress
      net.IpAddress.parse "127.0.0.1"
      0

  connect address/net.SocketAddress:
    remote_address_ = address

  write data/ByteArray from=0 to=data.size -> int:
    if from != 0 or to != data.size: data = data.copy from to
    return send_ remote_address_ data

  read -> ByteArray?:
    msg := receive
    if not msg: return null
    return msg.data

  send datagram/udp.Datagram -> int:
    return send_ datagram.address datagram.data

  send_ address data -> int:
    if data.size > mtu: throw "PAYLOAD_TO_LARGE"
    res := cellular_.at_.do: it.set "+USOST" [get_id_, address.ip.stringify, address.port, data.size] --data=data
    return res.single[1]

  receive -> udp.Datagram?:
    while true:
      state := state_.wait_for READ_STATE_
      if state & CLOSE_STATE_ != 0:
        return null
      else if state & READ_STATE_ != 0:
        size := (cellular_.at_.do: it.set "+USORF" [get_id_, 0]).single[1]
        if size == 0:
          state_.clear READ_STATE_
          continue

        output := ByteArray size
        offset := 0
        ip := null
        port := null
        while offset < size:
          portion := (cellular_.at_.do: it.set "+USORF" [get_id_, 1024]).single
          output.replace offset portion[4]
          offset += portion[1]
          ip = net.IpAddress.parse portion[2]
          port = portion[3]
        return udp.Datagram
          output
          net.SocketAddress
            ip
            port
      else:
        throw "SOCKET ERROR"

  close:
    if id_:
      id := id_
      closed_
      cellular_.at_.do:
        if not it.is_closed:
          it.send
            USOCL id

  mtu -> int:
    // From spec, +USOST only allows sending 1024 bytes at a time.
    return 1024

  broadcast -> bool: return false

  broadcast= value/bool: throw "BROADCAST_UNSUPPORTED"


/**
Deprecated. Use package ublox-cellular (https://github.com/toitware/ublox-cellular).

Base driver for u-blox Cellular devices, communicating over CAT-NB1 and/or CAT-M1.
*/
abstract class UBloxCellular extends CellularBase:
  static RAT_CAT_M1_        ::= 7
  static RAT_CAT_NB1_       ::= 8

  config_/Map

  cat_m1/bool
  cat_nb1/bool
  async_socket_connect/bool
  async_socket_close/bool

  /**
  Deprecated. Use package ublox-cellular (https://github.com/toitware/ublox-cellular).
  
  Called when the driver should reset.
  */
  abstract on_reset session/at.Session

  constructor
      uart/uart.Port
      --logger=log.default
      --config/Map={:}
      --.cat_m1=false
      --.cat_nb1=false
      --default_baud_rate=Cellular.DEFAULT_BAUD_RATE
      --preferred_baud_rate=null
      --.async_socket_connect=false
      --.async_socket_close=false
      --use_psm:
    config_ = config
    at_session := configure_at_ uart logger

    super uart at_session
      --constants=UBloxConstants
      --default_baud_rate=default_baud_rate
      --preferred_baud_rate=preferred_baud_rate
      --use_psm=use_psm

    // TCP read event.
    at_session.register_urc "+UUSORD"::
      sockets_.get it[0]
        --if_present=: it.state_.set_state READ_STATE_

    // UDP read event.
    at_session.register_urc "+UUSORF"::
      sockets_.get it[0]
        --if_present=: it.state_.set_state READ_STATE_

    // Socket closed event
    at_session.register_urc "+UUSOCL"::
      sockets_.get it[0]
        --if_present=: it.closed_

    at_session.register_urc "+UUSOCO":: | args |
      sockets_.get args[0]
        --if_present=: | socket |
          if args[1] == 0:
            // Success.
            if socket.error_ == 0:
              socket.state_.set_state CONNECTED_STATE_
            else:
              // The connection was aborted.
              socket.close
          else:
            socket.error_ = args[1]
            socket.closed_

  static configure_at_ uart logger:
    at := at.Session uart uart
      --logger=logger
      --data_delay=Duration --ms=50
      --command_delay=Duration --ms=20

    at.add_error_termination "+CME ERROR"
    at.add_error_termination "+CMS ERROR"

    at.add_response_parser "+USORF" :: | reader |
      id := int.parse
          reader.read_until ','
      if (reader.byte 0) == '"':
        // Data response.
        reader.skip 1
        ip := reader.read_until '"'
        reader.skip 1
        port := int.parse
            reader.read_until ','
        length := int.parse
            reader.read_until ','
        reader.skip 1  // Skip "
        data := reader.read_bytes length
        reader.read_bytes_until at.s3
        [id, length, ip, port, data]  // Return value.
      else:
        // Length-only response.
        length := int.parse
            reader.read_until at.s3
        [id, length]  // Return value.

    at.add_response_parser "+USORD" :: | reader |
      id := int.parse
          reader.read_until ','
      if (reader.byte 0) == '"':
        // 0-length response.
        reader.read_bytes_until at.s3
        [id, 0]  // Return value.
      else:
        // Data response.
        length := int.parse
            reader.read_until ','
        reader.skip 1  // Skip "
        data := reader.read_bytes length
        reader.read_bytes_until at.s3
        [id, data.size, data]  // Return value.

    // Custom parsing as ICCID is returned as integer but larger than 64bit.
    at.add_response_parser "+CCID" :: | reader |
      iccid := reader.read_until at.s3
      [iccid]  // Return value.

    at.add_response_parser "+UFWUPD" :: | reader |
      state := reader.read_until at.s3
      [state]  // Return value.

    at.add_response_parser "+UFWSTATUS" :: | reader |
      status := reader.read_until at.s3
      (status.split ",").map --in_place: it.trim  // Return value.

    return at

  transfer_file [block]:
    // Enter file write mode.
    at_.do: it.send UFWUPD

    at_.do: it.pause: | uart |
      writer := xmodem_1k.Writer uart
      block.call writer
      writer.done

    // Wait for AT interface to become active again.
    wait_for_ready

  install_file:
    at_.do: it.action "+UFWINSTALL"
    wait_for_ready

  install_status:
    return (at_.do: it.read "+UFWSTATUS").single

  close:
    try:
      sockets_.values.do: it.closed_
      at_.do:
        if not it.is_closed and (not use_psm or failed_to_connect or is_lte_connection_):
          it.send CPWROFF
    finally:
      at_session_.close
      uart_.close

  iccid:
    r := at_.do: it.read "+CCID"
    return r.single[0]

  sleep_:
    at_.do: it.set "+UPSV" [4]

  should_set_mno_ session/at.Session mno -> bool:
    current_mno := get_mno_ session
    if mno == 1:
      return current_mno == 0

    return current_mno != mno

  configure apn --mno=100 --bands=null --rats=null:
    at_.do: | session/at.Session |
      should_reboot := false
      while true:
        if should_reboot: wait_for_ready_ session

        enter_configuration_mode_ session

        should_reboot = false

        if mno and should_set_mno_ session mno:
          set_mno_ session mno
          reboot_ session
          continue

        rat := []
        if cat_m1: rat.add RAT_CAT_M1_
        if cat_nb1: rat.add RAT_CAT_NB1_
        if (get_rat_ session) != rat:

          set_rat_ session rat
          should_reboot = true

        if bands:
          mask := 0
          bands.do: mask |= 1 << (it - 1)
          if not is_band_mask_set_ session mask:
            set_band_mask_ session mask
            should_reboot = true

        if (get_apn_ session) != apn:
          set_apn_ session apn
          should_reboot = true

        if apply_configs_ session:
          should_reboot = true

        if should_reboot:
          reboot_ session
          continue

        configure_psm_ session --enable=use_psm

        break

  configure_psm_ session/at.Session --enable/bool --periodic_tau/string="00111000":
    psm_target := enable ? 1 : 0

    session.send_non_check
      at.Command.set "+CEDRXS" --parameters=[0]
    psm_value := session.read "+CPSMS"
    psv_value := session.read "+UPSV"
    if psm_value.single[0] == psm_target and psv_value.single[0] == psm_target: return

    if enable:
      session.set "+UPSV" [4]
      session.set "+CPSMS" [1, null, null, periodic_tau, "00000000"]
    else:
      session.set "+UPSV" [0]
      session.set "+CPSMS" [0]


  apply_configs_ session/at.Session -> bool:
    changed := false
    config_.do: | key expected |
      if apply_config_ session key expected: changed = true
    return changed

  apply_config_ session/at.Session key expected -> bool:
    values := session.read key
    line := values.last
    (min line.size expected.size).repeat:
      if line[it] != expected[it]:
        session.set key expected
        return true
    return false

  get_mno_ session/at.Session:
    result := session.read "+UMNOPROF"
    return result.single[0]

  set_mno_ session/at.Session mno:
    session.set "+UMNOPROF" [mno]

  is_band_mask_set_ session/at.Session mask/int:
    result := session.read "+UBANDMASK"
    values := result.single
    // There may be multiple masks, validate all.
    for i := 1; i < values.size; i+=2:
      if values[i] != mask: return false
    return true

  set_band_mask_ session/at.Session mask:
    // Set mask for both m1 and nbiot.
    if cat_m1: session.set "+UBANDMASK" [0, mask]
    if cat_nb1: session.set "+UBANDMASK" [1, mask]

  get_rat_ session/at.Session -> List:
    result := session.read "+URAT"
    return result.single

  set_rat_ session/at.Session rat/List:
    session.set "+URAT" rat

  reset:
    detach
    // Reset of MNO will clear connction-related configurations.
    at_.do: | session/at.Session |
      set_mno_ session 0

  reboot_ session/at.Session:
    on_reset session
    wait_for_ready_ session

  set_baud_rate_  session/at.Session baud_rate:
    session.set "+IPR" [baud_rate]
    uart_.set_baud_rate baud_rate
    sleep --ms=100

  network_interface -> net.Interface:
    return Interface_ this

  test_tx_:
    // Test routine for entering test most and broadcasting 23dBm on channel 20
    // for 5 seconds at a time. Useful for EMC testing.
    at_.do: it.set "+UTEST" [1]
    reboot_ at_session_
    at_.do: it.set "+UTEST" [1]
    at_.do: it.read "+UTEST"
    at_.do: it.read "+CFUN"

    while true:
      at_.do: it.set "+UTEST" [3,124150,23,null,null,5000]

class UBloxConstants implements Constants:
  RatCatM1 -> int?: return null

class Interface_ extends net.Interface:
  cellular_/UBloxCellular
  tcp_connect_mutex_ ::= monitor.Mutex

  constructor .cellular_:

  resolve host/string -> List:
    // First try parsing it as an ip.
    catch:
      return [net.IpAddress.parse host]

    // Async resolve is not supported on this device.
    res := cellular_.at_.do: it.send
      UDNSRN.sync host
    return res.single.map: net.IpAddress.parse it

  udp_open -> udp.Socket:
    return udp_open --port=null

  udp_open --port/int? -> udp.Socket:
    if port and port != 0: throw "cannot bind to custom port"
    res := cellular_.at_.do: it.set "+USOCR" [17]
    id := res.single[0]
    socket := UdpSocket cellular_ id
    cellular_.sockets_.update id --if_absent=(: socket): throw "socket already exists"
    return socket

  tcp_connect address/net.SocketAddress -> tcp.Socket:
    res := cellular_.at_.do: it.set "+USOCR" [6]
    id := res.single[0]

    socket := TcpSocket cellular_ id address
    cellular_.sockets_.update id --if_absent=(: socket): throw "socket already exists"

    if not cellular_.async_socket_connect: socket.state_.set_state CONNECTED_STATE_

    // The chip only supports one connecting socket at a time.
    tcp_connect_mutex_.do:
      catch --unwind=(: socket.error_ = 1; true): socket.connect_

    return socket

  tcp_listen port/int -> tcp.ServerSocket:
    throw "UNIMPLEMENTED"

  address -> net.IpAddress:
    unreachable

  close:

class UDNSRN extends at.Command:
  static TIMEOUT ::= Duration --s=70

  constructor.sync host/string:
    super.set "+UDNSRN" --parameters=[0, host] --timeout=TIMEOUT

class CPWROFF extends at.Command:
  static TIMEOUT ::= Duration --s=40

  constructor:
    super.action "+CPWROFF" --timeout=TIMEOUT

class USOCL extends at.Command:
  static TIMEOUT ::= Duration --s=120

  constructor id/int:
    super.set "+USOCL" --parameters=[id] --timeout=TIMEOUT

  constructor.async id/int:
    super.set "+USOCL" --parameters=[id, 1]

class UFWUPD extends at.Command:
  static TIMEOUT ::= Duration --s=20

  constructor:
    super.set "+UFWUPD" --parameters=[3] --timeout=TIMEOUT

class USOCO extends at.Command:
  static TIMEOUT ::= Duration --s=130

  constructor id/int address/net.SocketAddress:
    super.set "+USOCO" --parameters=[id, address.ip.stringify, address.port] --timeout=TIMEOUT

  constructor.async id/int address/net.SocketAddress:
    super.set "+USOCO" --parameters=[id, address.ip.stringify, address.port, 1]
