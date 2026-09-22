// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

package org.toitlang.bletest;

import android.app.Activity;
import android.app.KeyguardManager;
import android.bluetooth.*;
import android.bluetooth.le.*;
import android.os.*;
import android.util.Log;
import android.view.WindowManager;
import android.widget.TextView;
import java.util.Arrays;
import java.util.Collections;
import java.util.UUID;

/** Explicit hardware regression app; never connects without a supplied target. */
public final class MainActivity extends Activity {
  private static final String TAG = "ToitBleTest";
  private static final UUID SERVICE = UUID.fromString("9f6c1000-8e2a-4b13-9e97-94f353eeb001");
  private static final UUID INPUT = UUID.fromString("9f6c1001-8e2a-4b13-9e97-94f353eeb001");
  private static final UUID ECHO = UUID.fromString("9f6c1002-8e2a-4b13-9e97-94f353eeb001");
  private static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
  private final Handler handler = new Handler(Looper.getMainLooper());
  private BluetoothLeScanner scanner;
  private BluetoothGatt gatt;
  private BluetoothGattCharacteristic input;
  private BluetoothGattCharacteristic echo;
  private TextView display;
  private String stage = "starting";
  private String runId;
  private int sequence;
  private int count;
  private int cycles;
  private int cycle;
  private String address;
  private boolean scanOnce;
  private boolean reuseGatt;
  private BluetoothDevice selectedDevice;
  private boolean acknowledged;
  private boolean notified;
  private boolean terminal;

  @Override public void onCreate(Bundle saved) {
    super.onCreate(saved);
    display = new TextView(this);
    setContentView(display);
    runId = getIntent().getStringExtra("run");
    guarded(() -> {
      address = getIntent().getStringExtra("address");
      count = getIntent().getIntExtra("count", 100);
      cycles = getIntent().getIntExtra("cycles", 1);
      scanOnce = getIntent().getBooleanExtra("scan_once", false);
      reuseGatt = getIntent().getBooleanExtra("reuse_gatt", false);
      check(!reuseGatt || scanOnce, "reuse_gatt requires scan_once");
      check(runId != null && runId.matches("[A-Za-z0-9_-]{1,64}"), "run id required");
      check(BluetoothAdapter.checkBluetoothAddress(address), "target address required");
      check(count >= 1 && count <= 1000, "count out of range");
      check(cycles >= 1 && cycles <= 100, "cycles out of range");
      BluetoothAdapter adapter = getSystemService(BluetoothManager.class).getAdapter();
      check(adapter != null && adapter.isEnabled(), "Bluetooth disabled");
      check(!getSystemService(KeyguardManager.class).isKeyguardLocked(), "unlock phone before starting test");
      getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
      scanner = adapter.getBluetoothLeScanner();
      report("START address=" + address + " count=" + count + " cycles=" + cycles
          + " sdk=" + Build.VERSION.SDK_INT + " scan_once=" + scanOnce
          + " reuse_gatt=" + reuseGatt);
      handler.postDelayed(() -> fail("deadline stage=" + stage), 120000L * cycles);
      startCycle();
    });
  }

  private final Runnable cycleDeadline = () -> fail("cycle deadline stage=" + stage);

  private void startCycle() {
    sequence = 0;
    input = null;
    echo = null;
    handler.postDelayed(cycleDeadline, 120000);
    if (reuseGatt && gatt != null) {
      stage = "connecting";
      report("CONNECT reused-gatt=true cycle=" + cycle);
      check(gatt.connect(), "reconnect not accepted");
      return;
    }
    if (scanOnce && selectedDevice != null) {
      report("CONNECT cached-device=true cycle=" + cycle);
      connect(selectedDevice);
      return;
    }
    stage = "scanning";
    scanner.startScan(Collections.singletonList(new ScanFilter.Builder()
        .setDeviceAddress(address).setServiceUuid(new ParcelUuid(SERVICE)).build()),
        new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scan);
  }

  private void connect(BluetoothDevice device) {
    check(gatt == null, "previous GATT client still open");
    stage = "connecting";
    gatt = device.connectGatt(MainActivity.this, false, callback,
        BluetoothDevice.TRANSPORT_LE, BluetoothDevice.PHY_LE_1M_MASK, handler);
    check(gatt != null, "connect returned null");
  }

  private void check(boolean condition, String message) {
    if (!condition) throw new IllegalStateException(message);
  }
  private void guarded(Runnable action) {
    if (terminal) return;
    try { action.run(); } catch (Exception error) { fail(error.toString()); }
  }
  private void report(String message) {
    String line = "run=" + runId + " " + message;
    Log.i(TAG, line);
    display.setText(line);
  }
  private void fail(String message) {
    if (terminal) return;
    terminal = true;
    report("FAIL stage=" + stage + " " + message);
    cleanup();
  }
  private void cleanup() {
    getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    handler.removeCallbacksAndMessages(null);
    try { if (scanner != null) scanner.stopScan(scan); } catch (Exception ignored) { }
    if (gatt != null) { gatt.disconnect(); gatt.close(); gatt = null; }
  }
  @Override public void onDestroy() {
    if (!terminal) fail("activity destroyed");
    super.onDestroy();
  }
  private byte[] payload(int value) {
    return new byte[] {(byte)value, (byte)(value >> 8), (byte)(value >> 16),
        (byte)(value >> 24), 'T', 'o', 'i', 't', 'H', 'C', 'I'};
  }
  private void writeNext() {
    acknowledged = false;
    notified = false;
    stage = "echo";
    check(gatt.writeCharacteristic(input, payload(sequence),
        BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothStatusCodes.SUCCESS, "write not accepted");
  }
  private void advance() {
    if (!acknowledged || !notified) return;
    sequence++;
    if (sequence % 10 == 0) report("ECHO count=" + sequence);
    if (sequence == count) {
      stage = "final-read";
      check(gatt.readCharacteristic(echo), "final read not accepted");
    } else writeNext();
  }
  private final ScanCallback scan = new ScanCallback() {
    @Override public void onScanFailed(int code) { handler.post(() -> fail("scan=" + code)); }
    @Override public void onScanResult(int type, ScanResult result) {
      handler.post(() -> guarded(() -> {
        if (!stage.equals("scanning")) return;
        scanner.stopScan(this);
        report("SCAN matched=true");
        selectedDevice = result.getDevice();
        connect(selectedDevice);
      }));
    }
  };
  private final BluetoothGattCallback callback = new BluetoothGattCallback() {
    @Override public void onConnectionStateChange(BluetoothGatt g, int status, int state) {
      guarded(() -> {
        check(g == gatt, "stale connection callback");
        check(status == BluetoothGatt.GATT_SUCCESS, "connection status=" + status);
        if (state == BluetoothProfile.STATE_CONNECTED) {
          check(stage.equals("connecting"), "unexpected connection");
          stage = "discovering";
          check(g.discoverServices(), "discovery not accepted");
        } else if (state == BluetoothProfile.STATE_DISCONNECTED) {
          check(stage.equals("disconnecting"), "unexpected disconnect");
          handler.removeCallbacks(cycleDeadline);
          if (!reuseGatt || cycle + 1 == cycles) {
            g.close();
            gatt = null;
          }
          report("CYCLE cycle=" + cycle + " exchanges=" + sequence + " initial-read=true final-read=true unsubscribed=true disconnected=true");
          cycle++;
          if (cycle == cycles) {
            terminal = true;
            report("PASS exchanges=" + (count * cycles) + " cycles=" + cycles + " initial-read=true final-read=true unsubscribed=true disconnected=true");
            cleanup();
          } else {
            stage = "between-cycles";
            // Leave room for Android's per-app scan-start rate limit.
            handler.postDelayed(() -> guarded(() -> startCycle()), 7000);
          }
        }
      });
    }
    @Override public void onServicesDiscovered(BluetoothGatt g, int status) {
      guarded(() -> {
        check(g == gatt, "stale discovery callback");
        check(stage.equals("discovering") && status == 0, "discovery status=" + status);
        BluetoothGattService service = g.getService(SERVICE);
        check(service != null, "service missing");
        input = service.getCharacteristic(INPUT);
        echo = service.getCharacteristic(ECHO);
        check(input != null && echo != null && echo.getDescriptor(CCCD) != null, "attributes missing");
        stage = "initial-read";
        check(g.readCharacteristic(echo), "initial read not accepted");
      });
    }
    @Override public void onCharacteristicRead(BluetoothGatt g, BluetoothGattCharacteristic c, byte[] value, int status) {
      guarded(() -> {
        check(g == gatt, "stale read callback");
        check(c == echo && status == 0, "read status=" + status);
        if (stage.equals("initial-read")) {
          check(Arrays.equals(value, new byte[] {0x70, 0x17}), "initial value mismatch");
          stage = "subscribing";
          check(g.setCharacteristicNotification(echo, true), "local subscription failed");
          check(g.writeDescriptor(echo.getDescriptor(CCCD), BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == 0,
              "subscribe not accepted");
        } else {
          check(stage.equals("final-read") && Arrays.equals(value, payload(count - 1)), "final value mismatch");
          stage = "unsubscribing";
          check(g.writeDescriptor(echo.getDescriptor(CCCD), BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE) == 0,
              "unsubscribe not accepted");
        }
      });
    }
    @Override public void onDescriptorWrite(BluetoothGatt g, BluetoothGattDescriptor d, int status) {
      guarded(() -> {
        check(g == gatt, "stale descriptor callback");
        check(d == echo.getDescriptor(CCCD) && status == 0, "descriptor status=" + status);
        if (stage.equals("subscribing")) writeNext();
        else {
          check(stage.equals("unsubscribing"), "unexpected descriptor reply");
          check(g.setCharacteristicNotification(echo, false), "local unsubscribe failed");
          stage = "disconnecting";
          g.disconnect();
        }
      });
    }
    @Override public void onCharacteristicWrite(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
      guarded(() -> {
        check(g == gatt, "stale write callback");
        check(stage.equals("echo") && c == input && status == 0 && !acknowledged, "write callback mismatch status=" + status);
        acknowledged = true;
        advance();
      });
    }
    @Override public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic c, byte[] value) {
      guarded(() -> {
        check(g == gatt, "stale notification callback");
        check(stage.equals("echo") && c == echo && !notified && Arrays.equals(value, payload(sequence)),
            "notification mismatch sequence=" + sequence);
        notified = true;
        advance();
      });
    }
  };
}
