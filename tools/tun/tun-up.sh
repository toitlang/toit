#!/bin/sh

set -e

sudo ip tuntap add tun0 mode tun

# To bring up a tun interface, use:
sudo ip link set tun0 up

# To assign an IP address to the tun interface, you can use:
sudo ip addr add 10.0.0.1/24 dev tun0
