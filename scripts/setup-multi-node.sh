#!/bin/bash
# Multi-Node ESP32-S3 Setup Script
# Automates firmware build, flash, provision, and server start

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  $1"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
}

print_step() {
    echo -e "${GREEN}▶${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Detect OS
detect_os() {
    case "$(uname -s)" in
        Linux*)     OS=Linux;;
        Darwin*)    OS=Mac;;
        MINGW*|MSYS*|CYGWIN*) OS=Windows;;
        *)          OS=Unknown;;
    esac
    echo "$OS"
}

# Find ESP32 devices
find_esp32_ports() {
    local OS=$(detect_os)
    case "$OS" in
        Linux)
            ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true
            ;;
        Mac)
            ls /dev/cu.usbserial* /dev/cu.SLAB* /dev/tty.usbserial* 2>/dev/null || true
            ;;
        Windows)
            # In Git Bash/MSYS, COM ports appear as /dev/ttyS*
            ls /dev/ttyS* 2>/dev/null | grep -v ttyS0 || true
            ;;
    esac
}

# Main menu
main_menu() {
    print_header "RuView Multi-Node Setup"
    echo ""
    echo "This script will help you set up a multi-node ESP32-S3 deployment."
    echo ""
    echo "Options:"
    echo "  1) Full setup (build, flash, provision, start server)"
    echo "  2) Build firmware only"
    echo "  3) Flash nodes only"
    echo "  4) Provision nodes only"
    echo "  5) Start sensing server only"
    echo "  6) Identify connected ESP32 devices"
    echo "  7) Exit"
    echo ""
    read -p "Select option [1-7]: " choice

    case $choice in
        1) full_setup ;;
        2) build_firmware ;;
        3) flash_nodes ;;
        4) provision_nodes ;;
        5) start_server ;;
        6) identify_devices ;;
        7) exit 0 ;;
        *) print_error "Invalid option"; main_menu ;;
    esac
}

# Full setup
full_setup() {
    print_header "Full Setup"
    build_firmware
    flash_nodes
    provision_nodes
    start_server
}

# Build firmware
build_firmware() {
    print_header "Building ESP32-S3 Firmware"

    cd "$REPO_ROOT/firmware/esp32-csi-node"

    if command -v docker &> /dev/null; then
        print_step "Building with Docker ESP-IDF..."
        docker run --rm -v "$(pwd)":/project -w /project \
            espressif/idf:v5.4 \
            idf.py build
        print_success "Firmware built successfully"
    elif command -v idf.py &> /dev/null; then
        print_step "Building with native ESP-IDF..."
        idf.py build
        print_success "Firmware built successfully"
    else
        print_error "Neither Docker nor ESP-IDF found!"
        print_warn "Install Docker or ESP-IDF v5.4 to build firmware"
        exit 1
    fi

    cd "$REPO_ROOT"
}

# Flash nodes
flash_nodes() {
    print_header "Flashing ESP32-S3 Nodes"

    local ports=$(find_esp32_ports)

    if [ -z "$ports" ]; then
        print_error "No ESP32 devices found!"
        print_warn "Connect your ESP32-S3 devices and try again"
        return 1
    fi

    echo "Detected devices:"
    echo "$ports" | nl
    echo ""

    for port in $ports; do
        read -p "Flash device on $port? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            print_step "Flashing $port..."
            "$SCRIPT_DIR/flash-node.sh" "$port"
            print_success "Flashed $port"
        fi
    done
}

# Provision nodes
provision_nodes() {
    print_header "Provisioning WiFi Credentials"

    # Get WiFi credentials
    read -p "WiFi SSID: " wifi_ssid
    read -sp "WiFi Password: " wifi_pass
    echo ""

    # Get server IP
    local default_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || ipconfig getifaddr en0 2>/dev/null || echo "192.168.1.100")
    read -p "Server IP [$default_ip]: " server_ip
    server_ip=${server_ip:-$default_ip}

    local ports=$(find_esp32_ports)

    if [ -z "$ports" ]; then
        print_error "No ESP32 devices found!"
        return 1
    fi

    for port in $ports; do
        read -p "Provision device on $port? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            print_step "Provisioning $port..."
            "$SCRIPT_DIR/provision-node.sh" "$port" "$wifi_ssid" "$wifi_pass" "$server_ip"
            print_success "Provisioned $port"
        fi
    done
}

# Start server
start_server() {
    print_header "Starting Sensing Server"

    cd "$REPO_ROOT/v2"

    # Check if already built
    if [ ! -f "target/release/sensing-server" ]; then
        print_step "Building sensing server..."
        cargo build --release -p wifi-densepose-sensing-server
    fi

    # Get bind address
    read -p "Bind to all interfaces (0.0.0.0)? [Y/n]: " bind_all
    if [[ "$bind_all" =~ ^[Nn]$ ]]; then
        bind_addr="127.0.0.1"
    else
        bind_addr="0.0.0.0"
    fi

    print_step "Starting server on $bind_addr:8080..."
    echo ""
    echo "Server will start in foreground. Press Ctrl+C to stop."
    echo "UI available at: http://$bind_addr:8080"
    echo ""

    cargo run --release -p wifi-densepose-sensing-server -- \
        --bind-addr "$bind_addr" \
        --source esp32 \
        --http-port 8080 \
        --udp-port 5005
}

# Identify devices
identify_devices() {
    print_header "Identifying ESP32 Devices"

    local ports=$(find_esp32_ports)

    if [ -z "$ports" ]; then
        print_error "No ESP32 devices found!"
        return 1
    fi

    echo "Detected devices:"
    local i=1
    for port in $ports; do
        echo "  $i) $port"
        ((i++))
    done
    echo ""

    read -p "Monitor which device? (enter number or 'all'): " selection

    if [ "$selection" = "all" ]; then
        print_warn "Monitoring all devices (each in separate window requires multiple terminals)"
        for port in $ports; do
            echo "Run in separate terminal: python -m serial.tools.miniterm $port 115200"
        done
    else
        local port_array=($ports)
        local selected_port=${port_array[$((selection-1))]}
        if [ -n "$selected_port" ]; then
            print_step "Monitoring $selected_port (press Ctrl+] to exit)..."
            python -m serial.tools.miniterm "$selected_port" 115200
        else
            print_error "Invalid selection"
        fi
    fi
}

# Run main menu
main_menu
