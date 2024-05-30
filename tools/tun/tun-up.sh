#!/bin/sh

set -e

sudo ip tuntap add tun0 mode tun

# To bring up a tun interface, use:
sudo ip link set tun0 up

# To assign an IP address to the tun interface, you can use:
sudo ip addr add 10.0.0.1/24 dev tun0

# Enable IP forwarding.
echo 1 > /proc/sys/net/ipv4/ip_forward
# Enable NAT.
iptables -t nat -A POSTROUTING -o eno1 -j MASQUERADE
# Allow forwarding traffic between tun0 and eno1.
iptables -A FORWARD -i tun0 -o eno1 -m state --state RELATED -j ACCEPT
iptables -A FORWARD -i tun0 -o eno1 -m state --state ESTABLISHED -j ACCEPT
iptables -A FORWARD -i eno1 -o tun0 -j ACCEPT

# Dump packets to and from dns.google.com on the tun0 interface
HOST=dns.google.com
tcpdump -i tun0 -n host $HOST
