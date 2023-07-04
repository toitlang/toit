# Ethernet example
This example shows how to use the Ethernet interface on an ESP32.

It splits the ethernet provider from the client, allowing multiple
containers to access the ethernet.

The example is split into three files:
- [client.toit] - A client that uses the ethernet connection.
- [provider.toit] - A provider that provides the ethernet connection.
- [olimex_poe.toit] - A customized version of the Ethernet provider that
  powers on the ethernet chip when a client wants to connect.
