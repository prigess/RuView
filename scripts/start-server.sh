#!/bin/bash
# Start the WiFi-DensePose sensing server

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default configuration
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"
HTTP_PORT="${HTTP_PORT:-8080}"
WS_PORT="${WS_PORT:-8765}"
UDP_PORT="${UDP_PORT:-5005}"
SOURCE="${SOURCE:-esp32}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --bind-addr) BIND_ADDR="$2"; shift 2 ;;
        --http-port) HTTP_PORT="$2"; shift 2 ;;
        --ws-port) WS_PORT="$2"; shift 2 ;;
        --udp-port) UDP_PORT="$2"; shift 2 ;;
        --source) SOURCE="$2"; shift 2 ;;
        --background) BACKGROUND=1; shift ;;
        --help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --bind-addr ADDR   Bind address (default: 0.0.0.0)"
            echo "  --http-port PORT   HTTP port (default: 8080)"
            echo "  --ws-port PORT     WebSocket port (default: 8765)"
            echo "  --udp-port PORT    UDP port for CSI data (default: 5005)"
            echo "  --source SOURCE    Data source: esp32, wifi, simulate (default: esp32)"
            echo "  --background       Run in background"
            echo ""
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

cd "$REPO_ROOT/v2"

# Build if not already built
if [ ! -f "target/release/sensing-server" ]; then
    echo "Building sensing server..."
    cargo build --release -p wifi-densepose-sensing-server
fi

echo "Starting WiFi-DensePose Sensing Server"
echo "======================================="
echo "  HTTP:      http://$BIND_ADDR:$HTTP_PORT"
echo "  WebSocket: ws://$BIND_ADDR:$WS_PORT/ws/sensing"
echo "  UDP:       $BIND_ADDR:$UDP_PORT"
echo "  Source:    $SOURCE"
echo ""

if [ "$BACKGROUND" = "1" ]; then
    LOG_FILE="/tmp/sensing-server.log"
    echo "Running in background. Log: $LOG_FILE"
    nohup cargo run --release -p wifi-densepose-sensing-server -- \
        --bind-addr "$BIND_ADDR" \
        --http-port "$HTTP_PORT" \
        --ws-port "$WS_PORT" \
        --udp-port "$UDP_PORT" \
        --source "$SOURCE" \
        > "$LOG_FILE" 2>&1 &
    echo "PID: $!"
    echo ""
    echo "Stop with: kill $!"
    echo "View logs: tail -f $LOG_FILE"
else
    echo "Press Ctrl+C to stop"
    echo ""
    cargo run --release -p wifi-densepose-sensing-server -- \
        --bind-addr "$BIND_ADDR" \
        --http-port "$HTTP_PORT" \
        --ws-port "$WS_PORT" \
        --udp-port "$UDP_PORT" \
        --source "$SOURCE"
fi
