#!/usr/bin/env bash
# installer.sh - Paqet Server Deployment Script
# https://github.com/hanselime/paqet

set -euo pipefail

# Configuration defaults
INSTALL_DIR="/opt/paqet"
SERVICE_NAME="paqet-server"

# Network defaults
DEFAULT_PORT="9999"
DEFAULT_KCP_MODE="fast"
DEFAULT_ENCRYPTION="aes"
DEFAULT_LOG_LEVEL="info"
DEFAULT_LOCAL_FLAG="PA"

# Colors & helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Preflight checks
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (or with sudo)."
        exit 1
    fi
}

check_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
    x86_64 | amd64) PAQET_ARCH="amd64" ;;
    aarch64 | arm64) PAQET_ARCH="arm64" ;;
    *)
        error "Unsupported architecture: $ARCH"
        exit 1
        ;;
    esac
    info "Detected architecture: $ARCH"
}

check_network_tools() {
    for cmd in ip arp; do
        if ! command -v "$cmd" &>/dev/null; then
            error "Required command '$cmd' not found. Please install it."
            exit 1
        fi
    done
}

# User input with defaults
detect_network_info() {
    # Detect primary interface (first non-loopback, non-docker with an IPv4)
    local iface
    iface=$(ip -4 -o addr show | awk '$2 !~ /^(lo|docker|br-|veth)/ {print $2; exit}')
    iface="${iface:-eth0}"

    # Detect local IPv4
    local ipv4
    ipv4=$(ip -4 -o addr show dev "$iface" | awk '{print $4}' | head -1 | cut -d'/' -f1)
    ipv4="${ipv4:-}"

    # Detect gateway IP
    local gw
    gw=$(ip route show default | awk '/default/ {print $3}' | head -1)
    gw="${gw:-}"

    # Detect gateway MAC
    local mac=""
    if [[ -n "$gw" ]]; then
        ping -c 1 -W 1 "$gw" &>/dev/null || true
        mac=$(arp -n "$gw" 2>/dev/null | grep -i ether | awk '{print $3}')
    fi

    echo "$iface|$ipv4|$gw|$mac"
}

ask() {
    local prompt="$1" default="$2" varname="$3"
    local val=""
    if [[ -n "$default" ]]; then
        prompt="$prompt [$default]"
    fi
    prompt="$prompt: "
    read -rp "$prompt" val
    if [[ -z "$val" ]]; then
        val="$default"
    fi
    eval "$varname=\"\$val\""
}

prompt_server_port() {
    ask "Server listen port (non-standard recommended, e.g. 9999)" "$DEFAULT_PORT" SERVER_PORT
    if [[ "$SERVER_PORT" -lt 1 || "$SERVER_PORT" -gt 65535 ]] 2>/dev/null; then
        error "Invalid port number: $SERVER_PORT"
        exit 1
    fi
}

prompt_kcp_key() {
    echo ""
    info "A secret key is required for encrypted KCP transport."
    info "Client and server must use the same key."
    echo ""
    local default_key
    default_key=$(openssl rand -base64 24 2>/dev/null | tr -d '\n' || echo "change-me-use-random-key")
    ask "KCP encryption secret key" "$default_key" KCP_KEY
}

prompt_network_details() {
    local detected
    detected=$(detect_network_info)
    IFS='|' read -r DET_IFACE DET_IPV4 DET_GW DET_MAC <<<"$detected"

    echo ""
    info "Detected network: interface=$DET_IFACE, IP=$DET_IPV4, gateway=$DET_GW, MAC=$DET_MAC"
    echo ""

    ask "Network interface name" "$DET_IFACE" NET_INTERFACE
    ask "Server IPv4 address" "$DET_IPV4" NET_IPV4
    ask "Gateway/router MAC address" "$DET_MAC" NET_GW_MAC

    SERVER_IPV4_ADDR="${NET_IPV4}:${SERVER_PORT}"
}

prompt_kcp_mode() {
    echo ""
    info "KCP modes: normal | fast | fast2 | fast3 | manual"
    info "  fast    - good balance (recommended)"
    info "  fast3   - highest speed, more bandwidth"
    info "  normal  - conservative, TCP-like"
    ask "KCP mode" "$DEFAULT_KCP_MODE" KCP_MODE
}

prompt_encryption() {
    echo ""
    info "Encryption algorithms: aes, aes-128, aes-128-gcm, aes-192, salsa20, blowfish, twofish, etc."
    ask "Encryption algorithm" "$DEFAULT_ENCRYPTION" ENCRYPT_BLOCK
}

prompt_tcp_flags() {
    echo ""
    info "TCP flags control how paqet crafts packets to bypass firewalls."
    info "Common patterns: PA (Push+Ack), S (SYN), A (ACK), SA (SYN+ACK)"
    echo ""

    local local_default="${DEFAULT_LOCAL_FLAG}"

    ask "Local TCP flags (e.g. PA, S, A, SA)" "$local_default" LOCAL_FLAG
}

# Download & install
download_paqet() {
    local version
    version=$(curl -sI "https://github.com/hanselime/paqet/releases/latest" | sed -n 's/^location:.*\/tag\///p' | tr -d '\r')
    if [[ -z "$version" ]]; then
        error "Failed to fetch latest release version."
        exit 1
    fi

    local tarball="${INSTALL_DIR}/paqet.tar.gz"
    local url="https://github.com/hanselime/paqet/releases/download/${version}/paqet-linux-${PAQET_ARCH}-${version}.tar.gz"

    mkdir -p "$INSTALL_DIR"

    info "Downloading paqet ${version} for linux/${PAQET_ARCH}..."
    if curl -fSL --progress-bar "$url" -o "$tarball"; then
        tar -xzf "$tarball" -C "$INSTALL_DIR"
        rm -f "$tarball"

        # Archive contains e.g. paqet_linux_amd64 - rename to paqet
        for f in "${INSTALL_DIR}"/paqet_linux_*; do
            if [[ -f "$f" && "$(basename "$f")" != "paqet" ]]; then
                mv "$f" "${INSTALL_DIR}/paqet"
                break
            fi
        done

        chmod +x "${INSTALL_DIR}/paqet"
        info "Installed to ${INSTALL_DIR}/paqet (version ${version})"
    else
        error "Download failed."
        error "Available releases: https://github.com/hanselime/paqet/releases"
        exit 1
    fi
}

# Configuration generation
generate_config() {
    mkdir -p "$INSTALL_DIR"
    local config="${INSTALL_DIR}/server.yaml"

    cat >"$config" <<EOF
# Paqet Server Configuration

role: "server"

# Logging
log:
  level: "${DEFAULT_LOG_LEVEL}"

# Server listen
listen:
  addr: ":${SERVER_PORT}"

# Network interface
network:
  interface: "${NET_INTERFACE}"
  ipv4:
    addr: "${SERVER_IPV4_ADDR}"
    router_mac: "${NET_GW_MAC}"
  tcp:
    local_flag: ["${LOCAL_FLAG}"]

# Transport
transport:
  protocol: "kcp"
  conn: 1
  kcp:
    mode: "${KCP_MODE}"
    block: "${ENCRYPT_BLOCK}"
    key: "${KCP_KEY}"
EOF

    chmod 600 "$config"
    info "Configuration written to ${config}"
}

# iptables firewall rules
setup_firewall() {
    echo ""
    warn "PAQET REQUIRES iptables RULES to prevent kernel interference."
    warn "Without these, incoming TCP RST packets will break connections."
    echo ""

    local confirm
    ask "Apply iptables rules for port ${SERVER_PORT}?" "yes" confirm

    case "$confirm" in
    y | Y | yes | Yes | YES)
        info "Applying iptables rules..."

        # NOTRACK incoming traffic on server port
        if iptables -t raw -C PREROUTING -p tcp --dport "$SERVER_PORT" -j NOTRACK -m comment --comment "paqet" 2>/dev/null; then
            warn "NOTRACK PREROUTING rule already exists for port ${SERVER_PORT}, skipping."
        else
            iptables -t raw -A PREROUTING -p tcp --dport "$SERVER_PORT" -j NOTRACK -m comment --comment "paqet"
            info "NOTRACK PREROUTING rule added."
        fi

        # NOTRACK outgoing traffic from server port
        if iptables -t raw -C OUTPUT -p tcp --sport "$SERVER_PORT" -j NOTRACK -m comment --comment "paqet" 2>/dev/null; then
            warn "NOTRACK OUTPUT rule already exists for port ${SERVER_PORT}, skipping."
        else
            iptables -t raw -A OUTPUT -p tcp --sport "$SERVER_PORT" -j NOTRACK -m comment --comment "paqet"
            info "NOTRACK OUTPUT rule added."
        fi

        # DROP TCP RST packets from server port
        if iptables -t mangle -C OUTPUT -p tcp --sport "$SERVER_PORT" --tcp-flags RST RST -j DROP -m comment --comment "paqet" 2>/dev/null; then
            warn "RST DROP rule already exists for port ${SERVER_PORT}, skipping."
        else
            iptables -t mangle -A OUTPUT -p tcp --sport "$SERVER_PORT" --tcp-flags RST RST -j DROP -m comment --comment "paqet"
            info "RST DROP rule added."
        fi

        if command -v iptables-save &>/dev/null; then
            local persist
            ask "Save iptables rules for persistence across reboots?" "yes" persist
            case "$persist" in
            y | Y | yes | Yes | YES)
                mkdir -p /etc/iptables
                iptables-save >/etc/iptables/rules.v4
                info "Rules saved to /etc/iptables/rules.v4"
                ;;
            esac
        fi
        ;;
    *)
        warn "Skipping firewall configuration. You MUST add these rules manually:"
        echo ""
        echo "  iptables -t raw -A PREROUTING -p tcp --dport ${SERVER_PORT} -j NOTRACK -m comment --comment \"paqet\""
        echo "  iptables -t raw -A OUTPUT -p tcp --sport ${SERVER_PORT} -j NOTRACK -m comment --comment \"paqet\""
        echo "  iptables -t mangle -A OUTPUT -p tcp --sport ${SERVER_PORT} --tcp-flags RST RST -j DROP -m comment --comment \"paqet\""
        echo ""
        ;;
    esac
}

# Systemd service
setup_service() {
    echo ""
    local confirm
    ask "Create a systemd service for automatic startup?" "yes" confirm

    case "$confirm" in
    y | Y | yes | Yes | YES)
        local unit="/etc/systemd/system/${SERVICE_NAME}.service"

        cat >"$unit" <<EOF
[Unit]
Description=Paqet Server (encrypted KCP transport)
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/paqet run -c ${INSTALL_DIR}/server.yaml
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable --now "$SERVICE_NAME"
        info "Service created, enabled and started: ${SERVICE_NAME}"
        info "Status: systemctl status ${SERVICE_NAME}"
        ;;
    *)
        info "No systemd service created."
        info "Run manually: ${INSTALL_DIR}/paqet run -c ${INSTALL_DIR}/server.yaml"
        ;;
    esac
}

# Summary
print_summary() {
    echo ""
    echo "  Paqet Server Installation Complete"
    echo ""
    echo "  Binary:       ${INSTALL_DIR}/paqet"
    echo "  Config:       ${INSTALL_DIR}/server.yaml"
    echo "  Listen:       :${SERVER_PORT}"
    echo "  Interface:    ${NET_INTERFACE}"
    echo "  KCP mode:     ${KCP_MODE}"
    echo "  Encryption:   ${ENCRYPT_BLOCK}"
    echo "  TCP flags:   [${LOCAL_FLAG}]"
    echo ""
    warn "Copy the KCP secret key and port to your client config."
    echo ""
    if systemctl is-enabled "$SERVICE_NAME" &>/dev/null; then
        echo "  Service:  systemctl status ${SERVICE_NAME}"
    fi
}

# Main
main() {
    echo ""
    echo "  Paqet Server Installer"
    echo ""

    check_root
    check_arch
    check_network_tools

    echo ""
    info "Step 1/5: Server port"
    prompt_server_port

    info "Step 2/5: Network configuration"
    prompt_network_details

    info "Step 3/5: KCP encryption key"
    prompt_kcp_key

    info "Step 4/5: KCP mode & encryption"
    prompt_kcp_mode
    prompt_encryption

    info "Step 5/6: TCP flags for packet crafting"
    prompt_tcp_flags

    info "Step 6/6: Download & install"
    download_paqet
    generate_config
    setup_firewall
    setup_service
    print_summary
}

main "$@"
