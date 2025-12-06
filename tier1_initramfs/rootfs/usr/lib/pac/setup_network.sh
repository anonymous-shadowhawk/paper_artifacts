#!/bin/sh

setup_network() {
    echo "[NETWORK] Setting up network interface..."
    
    modprobe virtio_net 2>/dev/null || true
    modprobe virtio_pci 2>/dev/null || true
    
    ip link set lo up 2>/dev/null || true
    
    for iface in eth0 enp0s3 enp0s4; do
        if ip link show "$iface" >/dev/null 2>&1; then
            echo "[NETWORK] Found interface: $iface"
            
            ip link set "$iface" up
            
            if command -v udhcpc >/dev/null 2>&1; then
                echo "[NETWORK] Trying DHCP..."
                udhcpc -i "$iface" -n -q -t 3 2>/dev/null
                
                sleep 1
                if ip addr show "$iface" | grep -q "inet "; then
                    echo "[NETWORK] DHCP successful - IP configured"
                    
                    if ! ip route | grep -q "default"; then
                        ip route add default via 10.0.2.2 2>/dev/null || true
                    fi
                    
                    return 0
                else
                    echo "[NETWORK] DHCP failed - no IP address assigned"
                fi
            fi
            
            echo "[NETWORK] Configuring static IP..."
            ip addr add 10.0.2.15/24 dev "$iface" 2>/dev/null || true
            ip route add default via 10.0.2.2 2>/dev/null || true
            echo "nameserver 10.0.2.3" > /etc/resolv.conf
            
            if ip addr show "$iface" | grep -q "10.0.2.15"; then
                echo "[NETWORK] Static IP configured: 10.0.2.15/24"
                return 0
            else
                echo "[NETWORK] ERROR: Failed to configure IP"
                return 1
            fi
        fi
    done
    
    echo "[NETWORK] Warning: No network interface found"
    return 1
}

test_network() {
    ping -c 1 -W 2 10.0.2.2 >/dev/null 2>&1 && \
        echo "[NETWORK] Connectivity OK" && return 0
    
    echo "[NETWORK] No connectivity"
    return 1
}

if [ "${0##*/}" = "setup_network.sh" ]; then
    setup_network
    test_network
fi
