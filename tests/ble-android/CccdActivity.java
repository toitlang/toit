// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

package org.toitlang.bletest;

import android.app.Activity;
import android.app.KeyguardManager;
import android.bluetooth.*;
import android.bluetooth.le.*;
import android.content.*;
import android.os.*;
import android.util.Log;
import android.view.WindowManager;
import android.widget.TextView;
import java.util.Arrays;
import java.util.Collections;
import java.util.UUID;

/** Bonded subscription fixture; requires an explicitly selected board and phase. */
public final class CccdActivity extends Activity {
  private static UUID uuid(String shortId) {
    return UUID.fromString("0000" + shortId + "-0000-1000-8000-00805f9b34fb");
  }
  private final Handler handler = new Handler(Looper.getMainLooper());
  private final BluetoothGattCharacteristic[] values = new BluetoothGattCharacteristic[3];
  private final BluetoothGattDescriptor[] descriptors = new BluetoothGattDescriptor[3];
  private BluetoothGattCharacteristic control;
  private BluetoothLeScanner scanner;
  private BluetoothDevice device;
  private BluetoothGatt gatt;
  private TextView display;
  private String runId, address, phase, stage = "starting";
  private int cycle, descriptorIndex, writes, notifications, indications, changes;
  private boolean terminal, registered, controlAcknowledged;

  private boolean initial() { return phase.equals("pair") && cycle == 0; }
  private void check(boolean condition, String message) {
    if (!condition) throw new IllegalStateException(message);
  }
  private void report(String message) {
    String line = "run=" + runId + " " + message;
    Log.i("ToitBleCccd", line);
    display.setText(line);
  }
  private void guarded(Runnable action) {
    if (terminal) return;
    try { action.run(); } catch (Exception error) { fail(error.toString()); }
  }
  private void fail(String message) {
    if (terminal) return;
    terminal = true;
    report("FAIL cycle=" + cycle + " stage=" + stage + " " + message);
    cleanup();
  }
  private void cleanup() {
    handler.removeCallbacksAndMessages(null);
    getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    try { if (scanner != null) scanner.stopScan(scan); } catch (Exception ignored) { }
    if (gatt != null) { gatt.disconnect(); gatt.close(); gatt = null; }
    if (registered) { unregisterReceiver(bonds); registered = false; }
  }
  @Override public void onDestroy() {
    if (!terminal) fail("activity destroyed");
    super.onDestroy();
  }
  @Override public void onCreate(Bundle saved) {
    super.onCreate(saved);
    display = new TextView(this);
    setContentView(display);
    guarded(() -> {
      runId = getIntent().getStringExtra("run");
      address = getIntent().getStringExtra("address");
      phase = getIntent().getStringExtra("phase");
      check(runId != null && runId.matches("[A-Za-z0-9_-]{1,64}"), "run id required");
      check(BluetoothAdapter.checkBluetoothAddress(address), "target address required");
      check("pair".equals(phase) || "resume".equals(phase), "pair/resume phase required");
      check(!getSystemService(KeyguardManager.class).isKeyguardLocked(), "unlock phone first");
      BluetoothAdapter adapter = getSystemService(BluetoothManager.class).getAdapter();
      check(adapter != null && adapter.isEnabled(), "Bluetooth disabled");
      scanner = adapter.getBluetoothLeScanner();
      IntentFilter filter = new IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED);
      filter.addAction(BluetoothDevice.ACTION_PAIRING_REQUEST);
      registerReceiver(bonds, filter, Context.RECEIVER_EXPORTED);
      registered = true;
      getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
      report("START phase=" + phase + " address=" + address + " cycles=2 sdk=" + Build.VERSION.SDK_INT);
      handler.postDelayed(() -> fail("overall deadline"), 120000);
      stage = "scanning";
      scanner.startScan(Collections.singletonList(new ScanFilter.Builder()
          .setDeviceAddress(address).setServiceUuid(new ParcelUuid(uuid("fff0"))).build()),
          new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scan);
    });
  }
  private final ScanCallback scan = new ScanCallback() {
    @Override public void onScanFailed(int code) { handler.post(() -> fail("scan=" + code)); }
    @Override public void onScanResult(int type, ScanResult result) {
      handler.post(() -> guarded(() -> {
        if (!stage.equals("scanning")) return;
        scanner.stopScan(this);
        device = result.getDevice();
        connect();
      }));
    }
  };
  private void connect() {
    check(gatt == null, "previous client open");
    check(device.getBondState() == (initial() ? BluetoothDevice.BOND_NONE : BluetoothDevice.BOND_BONDED),
        "unexpected retained bond state");
    notifications = indications = changes = writes = descriptorIndex = 0;
    controlAcknowledged = false;
    stage = "connecting";
    report("CONNECT cycle=" + cycle + " resumed=" + !initial());
    gatt = device.connectGatt(this, false, callbacks, BluetoothDevice.TRANSPORT_LE,
        BluetoothDevice.PHY_LE_1M_MASK, handler);
    check(gatt != null, "connect not accepted");
  }
  private final BroadcastReceiver bonds = new BroadcastReceiver() {
    @Override public void onReceive(Context context, Intent intent) {
      guarded(() -> {
        BluetoothDevice target = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice.class);
        if (device == null || !device.equals(target)) return;
        if (BluetoothDevice.ACTION_PAIRING_REQUEST.equals(intent.getAction())) {
          check(initial() && stage.equals("bonding"), "fresh pairing forbidden on resumption");
          int variant = intent.getIntExtra(BluetoothDevice.EXTRA_PAIRING_VARIANT, -1);
          int number = intent.getIntExtra(BluetoothDevice.EXTRA_PAIRING_KEY, -1);
          check(variant == BluetoothDevice.PAIRING_VARIANT_PASSKEY_CONFIRMATION && number >= 0,
              "Numeric Comparison required");
          report("NUMERIC value=" + number + " system-confirmation-required=true");
          return;
        }
        int state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1);
        if (initial() && stage.equals("bonding")) {
          check(state != BluetoothDevice.BOND_NONE, "bonding failed");
          if (state == BluetoothDevice.BOND_BONDED) discover();
        } else check(state == BluetoothDevice.BOND_BONDED, "retained bond changed");
      });
    }
  };
  private void discover() {
    stage = "discovering";
    check(gatt.discoverServices(), "discovery not accepted");
  }
  private BluetoothGattCharacteristic characteristic(BluetoothGattService service, String id) {
    check(service != null, "missing service");
    BluetoothGattCharacteristic value = service.getCharacteristic(uuid(id));
    check(value != null, "missing characteristic " + id);
    return value;
  }
  private byte[] expectedDescriptor() { return new byte[] {(byte)(descriptorIndex == 0 ? 1 : 2), 0}; }
  private void readDescriptor() {
    stage = "descriptor-read";
    check(gatt.readDescriptor(descriptors[descriptorIndex]), "descriptor read not accepted");
  }
  private void nextDescriptor() {
    descriptorIndex++;
    if (descriptorIndex < 3) { readDescriptor(); return; }
    stage = "updates";
    check(gatt.writeCharacteristic(control, new byte[] {1}, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
        == BluetoothStatusCodes.SUCCESS, "control not accepted");
  }
  private void finishUpdates() {
    if (!controlAcknowledged || notifications != 20 || indications != 20 || changes != 1) return;
    check(writes == (initial() ? 2 : 0) || (initial() && writes == 3), "CCCD write count");
    stage = "disconnecting";
    // Give the server time to receive Android's final ATT confirmation.
    handler.postDelayed(() -> guarded(() -> gatt.disconnect()), 200);
  }
  private final BluetoothGattCallback callbacks = new BluetoothGattCallback() {
    @Override public void onConnectionStateChange(BluetoothGatt client, int status, int state) {
      guarded(() -> {
        check(client == gatt && status == BluetoothGatt.GATT_SUCCESS, "connection status=" + status);
        if (state == BluetoothProfile.STATE_CONNECTED) {
          check(stage.equals("connecting"), "unexpected connection");
          if (initial()) {
            stage = "bonding";
            check(device.createBond(), "bonding not accepted");
          } else discover();
        } else if (state == BluetoothProfile.STATE_DISCONNECTED) {
          check(stage.equals("disconnecting"), "unexpected disconnect");
          check(device.getBondState() == BluetoothDevice.BOND_BONDED, "bond not retained");
          client.close(); gatt = null;
          report("CYCLE cycle=" + cycle + " resumed=" + !initial() + " notifications=20 indications=20 service-changed=1 app-cccd-writes=" + writes + " bonded=true disconnected=true");
          cycle++;
          if (cycle == 2) {
            terminal = true;
            report("PASS phase=" + phase + " cycles=2 notifications=40 indications=40 service-changed=2 bonded=true");
            cleanup();
          } else {
            stage = "between-cycles";
            handler.postDelayed(() -> guarded(() -> connect()), 7000);
          }
        }
      });
    }
    @Override public void onServicesDiscovered(BluetoothGatt client, int status) {
      guarded(() -> {
        check(client == gatt && stage.equals("discovering") && status == 0, "discovery failed");
        BluetoothGattService service = client.getService(uuid("fff0"));
        values[0] = characteristic(service, "fff1");
        values[1] = characteristic(service, "fff2");
        values[2] = characteristic(client.getService(uuid("1801")), "2a05");
        control = characteristic(service, "fff3");
        for (int i = 0; i < 3; i++) {
          descriptors[i] = values[i].getDescriptor(uuid("2902"));
          check(descriptors[i] != null, "missing CCCD");
          if (i < 2) check(client.setCharacteristicNotification(values[i], true), "local listener failed");
        }
        readDescriptor();
      });
    }
    @Override public void onDescriptorRead(BluetoothGatt client, BluetoothGattDescriptor descriptor,
                                           int status, byte[] value) {
      guarded(() -> {
        check(client == gatt && descriptor == descriptors[descriptorIndex] && status == 0,
            "descriptor read failed status=" + status);
        byte[] expected = expectedDescriptor();
        if (stage.equals("descriptor-verify")) {
          check(Arrays.equals(value, expected), "written CCCD mismatch");
          nextDescriptor();
          return;
        }
        check(stage.equals("descriptor-read"), "unexpected descriptor callback");
        if (!initial()) {
          check(Arrays.equals(value, expected), "CCCD was not retained");
          nextDescriptor();
        } else if (descriptorIndex == 2 && Arrays.equals(value, expected)) {
          report("SERVICE_CHANGED configured-by-android=true");
          nextDescriptor();
        } else {
          check(Arrays.equals(value, new byte[] {0, 0}), "fresh CCCD not empty");
          stage = "descriptor-write";
          writes++;
          check(client.writeDescriptor(descriptor, expected) == BluetoothStatusCodes.SUCCESS, "CCCD write rejected");
        }
      });
    }
    @Override public void onDescriptorWrite(BluetoothGatt client, BluetoothGattDescriptor descriptor, int status) {
      guarded(() -> {
        check(client == gatt && stage.equals("descriptor-write") && descriptor == descriptors[descriptorIndex]
            && status == 0 && initial(), "unexpected CCCD write callback status=" + status);
        stage = "descriptor-verify";
        check(client.readDescriptor(descriptor), "CCCD verification rejected");
      });
    }
    @Override public void onCharacteristicWrite(BluetoothGatt client, BluetoothGattCharacteristic value, int status) {
      guarded(() -> {
        check(client == gatt && stage.equals("updates") && value == control && status == 0 && !controlAcknowledged,
            "control write failed status=" + status);
        controlAcknowledged = true;
        finishUpdates();
      });
    }
    @Override public void onCharacteristicChanged(BluetoothGatt client, BluetoothGattCharacteristic value, byte[] data) {
      guarded(() -> {
        check(client == gatt && stage.equals("updates"), "unexpected update");
        int kind = value == values[0] ? 0 : value == values[1] ? 1 : -1;
        check(kind >= 0, "unexpected update characteristic");
        int sequence = kind == 0 ? notifications : indications;
        check(sequence < 20 && Arrays.equals(data, new byte[] {(byte)cycle, (byte)sequence, (byte)(42 + kind)}),
            "update sequence mismatch");
        if (kind == 0) notifications++; else indications++;
        finishUpdates();
      });
    }
    @Override public void onServiceChanged(BluetoothGatt client) {
      guarded(() -> {
        check(client == gatt && stage.equals("updates") && changes == 0, "unexpected Service Changed");
        changes++;
        finishUpdates();
      });
    }
  };
}
