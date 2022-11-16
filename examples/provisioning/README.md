# BLE Provisioning Example

This example `ble_provisioning.toit` shows how to make ESP32 module connect to designated Wi-Fi access point by PC or App of mobile phone.

## 1. Install Toit Requirements

Firstly you should compile to generate `toit.pkg`, run following command in the root folder of toit:

```
make
```
                                                                                                                                            
Then you could install toit requirement packets of `protobuf` in the `examples/provisioning` folder:

```
../../build/host/sdk/bin/toit.pkg install
```

## 2. Compile Application

Configure designated application by following steps in the root folder of toit:

```
make menuconfig
```

The configuration is as following:

```
Component config  --->
    Toit  --->
        (examples/provisioning/ble_provisioning.toit) Entry point
```

Run the following command to start to compile, download and flash the example:

```
make flash
```

## 3. Configure Access Point

There is an issue in BLE provisioning of esp-idf, it is that esp-idf only supports blocking mode which cause BLE protocol stack blocks for about 4 seconds without response for any outside request. To skip this issue, you should modify provisioning source code of PC and mobile APP. Please know that the supplied modification as following is the easiest method not the best method.

### 3.1 PC

You are suggested to use esp-idf v5.0 BLE provisioning tool, related operation steps are as following:

1. clone esp-idf

```
git clone --branch v5.0 --depth 1 https://github.com/espressif/esp-idf.git
```

2. install tools

```
cd esp-idf
./install.sh
. ./export.sh
```

3. modify script

Insert the following code between lines 212 and 213 of `tools/esp_prov/esp_prov.py`

```python
time.sleep(5)
```

4. run script

Please use your own device's service name instead of `$SERVICE_NAME`

```
python3 tools/esp_prov/esp_prov.py --transport ble --sec_ver 0 --service_name $SERVICE_NAME
```

### 3.2 App

Because this toit BLE provisioning has not supported security mode, so you are suggested to use older version of android APP, if you know how to modify the APP source code to select to use non-encrypt mode, it will be better to use the newest version. Following details just introduce how to skip BLE blocking issue.

1. clone esp-idf-provisioning-android

```
git clone --branch app-2.0.2 --depth 1 https://github.com/espressif/esp-idf-provisioning-android.git
```

2. modify code

Insert the following code in 594 line of `provisioning/src/main/java/com/espressif/provisioning/ESPDevice.java`:

```
try {
    sleep(5000);
} catch (InterruptedException e) {
}
```

3. compile and run

You can use your own Android development kit to compile, install it to your mobile phone, then use it to configure Wi-Fi access point for your ESP32.
