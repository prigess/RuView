#!/bin/bash
# Orange Pi 5 Pro System Health Check for RuView
# Run this on the Orange Pi to assess load and supportability

echo "=============================================="
echo "  RuView Orange Pi 5 Pro Health Check"
echo "=============================================="
echo ""

# 1. CPU Load
echo "=== CPU Load ==="
uptime
echo ""
echo "Per-core usage:"
mpstat -P ALL 1 1 2>/dev/null || top -bn1 | head -5
echo ""

# 2. Memory Usage
echo "=== Memory Usage ==="
free -h
echo ""

# 3. CPU Temperature (critical for sustained operation)
echo "=== Temperature ==="
for zone in /sys/class/thermal/thermal_zone*/temp; do
    name=$(dirname $zone)
    name=$(cat ${name}/type 2>/dev/null || echo "zone")
    temp=$(cat $zone 2>/dev/null)
    if [ -n "$temp" ]; then
        temp_c=$((temp / 1000))
        echo "  $name: ${temp_c}°C"
    fi
done
echo ""

# 4. NPU Status (RK3588)
echo "=== NPU Status ==="
if [ -e /dev/rknpu0 ]; then
    echo "  NPU device: Available (/dev/rknpu0)"
    if [ -e /sys/kernel/debug/rknpu/version ]; then
        echo "  Driver version: $(cat /sys/kernel/debug/rknpu/version 2>/dev/null)"
    fi
    if [ -e /sys/kernel/debug/rknpu/load ]; then
        echo "  NPU load: $(cat /sys/kernel/debug/rknpu/load 2>/dev/null)"
    fi
    if [ -e /sys/class/devfreq/fdab0000.npu/cur_freq ]; then
        freq=$(cat /sys/class/devfreq/fdab0000.npu/cur_freq 2>/dev/null)
        echo "  NPU frequency: $((freq / 1000000)) MHz"
    fi
else
    echo "  NPU device: Not detected (driver may need to be loaded)"
    echo "  Try: sudo modprobe rknpu"
fi
echo ""

# 5. RuView Process
echo "=== RuView Server Process ==="
ps aux | grep -E "(sensing-server|ruview)" | grep -v grep || echo "  Server not running"
echo ""

# 6. Network (UDP packets for CSI)
echo "=== Network Stats (UDP port 5005) ==="
ss -u -a | grep 5005 || netstat -anu | grep 5005 || echo "  No UDP listener on 5005"
echo ""

# 7. Disk I/O
echo "=== Disk Usage ==="
df -h / /opt 2>/dev/null | head -5
echo ""

# 8. GPU (Mali G610)
echo "=== GPU Status ==="
if [ -e /sys/class/devfreq/fb000000.gpu/cur_freq ]; then
    freq=$(cat /sys/class/devfreq/fb000000.gpu/cur_freq 2>/dev/null)
    echo "  GPU frequency: $((freq / 1000000)) MHz"
fi
cat /sys/class/devfreq/fb000000.gpu/load 2>/dev/null && echo "  (GPU load above)"
echo ""

# 9. ESP32 Node Connectivity
echo "=== Active ESP32 Nodes ==="
curl -s http://localhost:3022/api/v1/nodes 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    nodes = data.get('nodes', [])
    print(f'  Total nodes: {len(nodes)}')
    for n in nodes:
        print(f'    Node {n.get(\"id\",\"?\")}: RSSI={n.get(\"rssi\",\"?\")} dBm, frames={n.get(\"frame_count\",\"?\")}')
except:
    print('  Could not fetch node data')
" || echo "  API not reachable"
echo ""

# 10. Recommendations
echo "=== Health Assessment ==="
# Check temperature
max_temp=0
for zone in /sys/class/thermal/thermal_zone*/temp; do
    temp=$(cat $zone 2>/dev/null)
    if [ -n "$temp" ] && [ "$temp" -gt "$max_temp" ]; then
        max_temp=$temp
    fi
done
max_temp_c=$((max_temp / 1000))

# Check memory
mem_used_pct=$(free | grep Mem | awk '{print int($3/$2 * 100)}')

# Check load
load=$(cat /proc/loadavg | awk '{print $1}')
cores=$(nproc)

echo "  Max temperature: ${max_temp_c}°C"
if [ "$max_temp_c" -gt 75 ]; then
    echo "    ⚠️  WARNING: High temperature - consider better cooling"
elif [ "$max_temp_c" -gt 60 ]; then
    echo "    ✓ Warm but acceptable"
else
    echo "    ✓ Good thermal performance"
fi

echo "  Memory usage: ${mem_used_pct}%"
if [ "$mem_used_pct" -gt 80 ]; then
    echo "    ⚠️  WARNING: High memory usage"
else
    echo "    ✓ Memory OK"
fi

echo "  CPU load: $load (${cores} cores)"
echo ""
echo "=== NPU Acceleration Recommendation ==="
if [ -e /dev/rknpu0 ]; then
    echo "  NPU is available! To enable acceleration:"
    echo "    1. Convert models to RKNN format (see docs/NPU-ACCELERATION-ORANGEPI.md)"
    echo "    2. Set: export RUVIEW_USE_NPU=1"
    echo "    3. Expected speedup: 5-10x for inference"
else
    echo "  NPU not available. Install driver:"
    echo "    sudo apt install -y rockchip-rknpu2"
    echo "    sudo modprobe rknpu"
fi
echo ""
echo "=============================================="
echo "  Check complete!"
echo "=============================================="
