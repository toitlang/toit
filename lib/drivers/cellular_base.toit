// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import log
import at
import uart
import net
import monitor

import .cellular

REGISTRATION_DENIED_ERROR ::= "registration denied"

/**
Deprecated. Use package cellular (https://github.com/toitware/cellular).

Base functionality of Cellular modems, encapsulating the generic functionality.

Major things that are not implemented in the base is:
  * Chip configurations, e.g. bands and RATs.
  * TCP/UDP/IP stack.
*/
abstract class CellularBase implements Cellular:
  sockets_/Map ::= {:}
  logger_ ::= (log.default.with_name "driver").with_name "cellular"

  uart_/uart.Port
  at_session_/at.Session
  at_/at.Locker

  default_baud_rate/int
  preferred_baud_rate/int?
  cid_ := 1

  failed_to_connect/bool := false

  constants/Constants

  use_psm/bool := true

  is_lte_connection_ := false

  /** Deprecated. Use package cellular (https://github.com/toitware/cellular). */
  constructor
      .uart_
      .at_session_
      --logger=log.default
      --.constants
      --.default_baud_rate=Cellular.DEFAULT_BAUD_RATE
      --.preferred_baud_rate=null
      --.use_psm:

    at_ = at.Locker at_session_

  abstract iccid -> string

  abstract configure apn --bands/List?=null --rats=null

  abstract close -> none

  support_gsm_ -> bool:
    return false

  model:
    r := at_.do: it.action "+CGMM"
    return r.last.first

  version:
    r := at_.do: it.action "+CGMR"
    return r.last.first

  is_connected -> bool:
    with_timeout --ms=5_000:
      at_.do: | session/at.Session |
        while true:
          res := session.read "+CEREG"
          state := res.last[1]
          // Registered to home network (1) or roaming (5).
          if state == 1 or state == 5: return true
          // State (4) is unknown, wait and see it if resolves.
          if state != 4: return false
          sleep --ms=250
    return false

  scan_for_operators -> List:
    operators := []
    at_.do: | session/at.Session |
      result := session.send COPS.scan
      operators = result.last

    result := []
    operators.do: | o |
      if o is List and o.size == 5 and o[1] is string and o[0] != 3:  // 3 = operator forbidden.
        rat := o[4] is int ? o[4] : null
        result.add
          Operator o[3] --rat=rat
    return result

  connect_psm:
    e := catch:
      at_.do: | session/at.Session |
        wait_for_connected_ session null
    if e:
      logger_.warn "error connecting to operator" --tags={"error": "$e"}

  connect --operator/Operator?=null -> bool:
    is_connected := false

    at_.do: | session/at.Session |
      if not operator:
        session.send COPS.automatic

      // Set operator after enabling the radio.
      is_connected = wait_for_connected_ session operator

    return is_connected

  // TODO(Lau): Support the other operator formats than numeric.
  get_connected_operator -> Operator?:
    catch --trace:
      at_.do: | session/at.Session |
        res := (session.send COPS.read).last
        if res.size == 4 and res[1] == COPS.FORMAT_NUMERIC and res[2] is string and res[2].size == 5:
          return Operator res[2]
    return null

  detach:
    at_.do: it.send COPS.deregister

  signal_strength -> float?:
    e := catch:
      res := at_.do: it.action "+CSQ"
      signal_power := res.single[0]
      if signal_power == 99: return null
      return signal_power / 31.0
    logger_.info "failed to read signal strength" --tags={"error": "$e"}
    return null

  wait_for_ready:
    at_.do: wait_for_ready_ it

  enable_radio:
    at_.do: | session/at.Session |
      session.send CFUN.online

  disable_radio -> none:
    at_.do: | session/at.Session |
      disable_radio_ session

  disable_radio_ session/at.Session:
    session.send CFUN.offline

  is_radio_enabled_ session/at.Session:
    result := session.send CFUN.get
    return result.single.first == "1"

  get_apn_ session/at.Session:
    ctx := session.read "+CGDCONT"
    ctx.responses.do:
      if it.first == cid_: return it[2]
    return ""

  set_apn_ session/at.Session apn:
    session.set "+CGDCONT" [cid_, "IP", apn]

  wait_for_ready_ session/at.Session:
    power_on
    while true:
      if select_baud_ session: break

  enter_configuration_mode_ session/at.Session:
    disable_radio_ session
    wait_for_sim_ session

  select_baud_ session/at.Session --count=5:
    preferred := preferred_baud_rate or default_baud_rate
    baud_rates := [preferred, default_baud_rate]
    count.repeat:
      baud_rates.do: | rate |
        uart_.set_baud_rate rate
        if is_ready_ session:
          // Apply the preferred baud rate.
          if rate != preferred:
            set_baud_rate_ session preferred
          return true
    return false

  is_ready_ session/at.Session:
    response := session.action "" --timeout=(Duration --ms=250) --no-check

    if response == null:
      // By sleeping for even a little while here, we get a check for whether or
      // not we're past any deadline set by the caller of this method. The sleep
      // inside the is_ready call isn't enough, because it is wrapped in a catch
      // block. If we're out of time, we will throw a DEADLINE_EXCEEDED exception.
      sleep --ms=10
      return false

    // Wait for data to be flushed.
    sleep --ms=100

    // Disable echo.
    session.action "E0"
    // Verbose errors.
    session.set "+CMEE" [2]
    // TODO(anders): This is where we want to use an optional PIN:
    //   session.set "+CPIN" ["1234"]

    return true

  wait_for_sim_ session/at.Session:
    // Wait up to 10 seconds for the SIM to be initialized.
    40.repeat:
      catch --unwind=(: it == DEADLINE_EXCEEDED_ERROR):
        r := session.read "+CPIN"
        return
      sleep --ms=250

  wait_for_urc_ --session/at.Session?=null [block]:
    while true:
      catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
        with_timeout --ms=1000:
          return block.call
      // Ping every second
      if session: session.action "" --no-check
      else: at_.do: it.action "" --no-check

  set_up_wait_for_ session/at.Session cmd/string connected/monitor.Latch  --on_connect/Lambda=(:: null) -> none:
    session.register_urc cmd ::
      if it.first == 1 or it.first == 5:
        connected.set true
        on_connect.call
      if it.first == 3: connected.set REGISTRATION_DENIED_ERROR
      if it.first == 80: connected.set "connection lost"

  check_connected_ session/at.Session cmd/string connected/monitor.Latch --on_connect/Lambda=(:: null) -> bool:
      res := session.read cmd
      state := res.last[1]
      if state == 1 or state == 5:
        connected.set true
        on_connect.call
        return true
      return false

  wait_for_connected_ session/at.Session operator/Operator? -> bool:
    connected := monitor.Latch

    failed_to_connect = false
    is_lte_connection_ = false

    set_up_wait_for_ session "+CEREG" connected
    if support_gsm_:
      set_up_wait_for_ session "+CGREG" connected --on_connect=::
        is_lte_connection_ = true
        use_psm = false

    try:
      if operator:
        timeout := Duration --us=(task.deadline - Time.monotonic_us)
        result := session.send
          COPS.manual operator.op --timeout=timeout --rat=operator.rat

      // Enable events.
      session.set "+CEREG" [2]
      if support_gsm_: session.set "+CGREG" [2]

      // Make sure we didn't miss the connect event before we set +CEREG=2.
      check_connected_ session "+CEREG" connected
      if support_gsm_:
        check_connected_ session "+CGREG" connected --on_connect=::
          is_lte_connection_ = true
          use_psm = false

      result := wait_for_urc_ --session=session: connected.get
      if result is string:
        failed_to_connect = true
        logger_.debug "connection failed" --tags={"error": result}
        return false
    finally:
      session.unregister_urc "+CEREG"
      if support_gsm_: session.unregister_urc "+CGREG"

    on_connected_ session

    return true

  abstract set_baud_rate_ session/at.Session baud_rate/int
  abstract network_interface -> net.Interface

  // Dummy implementations.
  power_on -> none:
  power_off -> none:
  reset -> none:
  recover_modem -> none:
    power_off

  /** Called when the driver has connected. */
  abstract on_connected_ session/at.Session

/** Deprecated. Use package cellular (https://github.com/toitware/cellular). */
interface Constants:
  RatCatM1 -> int?

/** Deprecated. Use package cellular (https://github.com/toitware/cellular). */
class CFUN extends at.Command:
  static TIMEOUT ::= Duration --m=3

  constructor.offline:
    super.set "+CFUN" --parameters=[0] --timeout=TIMEOUT

  constructor.online --reset=false:
    params := [1]
    if reset: params.add 1
    super.set "+CFUN" --parameters=params --timeout=TIMEOUT

  constructor.airplane:
    super.set "+CFUN" --parameters=[4] --timeout=TIMEOUT

  constructor.reset --reset_sim/bool=false:
    super.set "+CFUN" --parameters=[reset_sim ? 16 : 15] --timeout=TIMEOUT

  constructor.get:
    super.read "+CFUN" --timeout=TIMEOUT

/** Deprecated. Use package cellular (https://github.com/toitware/cellular). */
class COPS extends at.Command:
  // COPS times out after 180s, but since it can be aborted, any timeout can be used.
  static TIMEOUT ::= Duration --m=3
  static FORMAT_NUMERIC ::= 2

  constructor.manual operator --timeout=TIMEOUT --rat=null:
    args := [1, FORMAT_NUMERIC, operator]
    if rat: args.add rat
    super.set "+COPS" --parameters=args --timeout=timeout

  constructor.automatic --timeout=TIMEOUT:
    super.set "+COPS" --parameters=[0, FORMAT_NUMERIC] --timeout=timeout

  constructor.deregister:
    super.set "+COPS" --parameters=[2]

  constructor.scan --timeout=TIMEOUT:
    super.test "+COPS" --timeout=timeout

  constructor.read --timeout=TIMEOUT:
    super.read "+COPS" --timeout=timeout
