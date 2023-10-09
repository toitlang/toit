sudo ip netns add ns1

sudo ip link add veth0 type veth peer name veth1
sudo ip link set veth1 netns ns1
   
sudo ip -n ns1 addr add 10.0.0.42/24 dev veth1
   
sudo ip link set veth0 up
sudo ip -n ns1 link set veth1 up
   
sudo ip netns exec ns1 ./prog1

sudo ip netns exec ns1 route add default veth1

sudo ip link set lo up
