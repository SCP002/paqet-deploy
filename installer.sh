#!/usr/bin/env bash
# installer.sh - Paqet Server Deployment Script
# https://github.com/hanselime/paqet
#
# Usage:
#   installer.sh [--upgrade]
#
#   --upgrade        Only replace the paqet binary, keep the existing config
#                    and restart the service.

set -euo pipefail

# Configuration defaults
INSTALL_DIR="/opt/paqet"
SERVICE_NAME="paqet-server"
CONFIG_FILE="${INSTALL_DIR}/server.yaml"

# Runtime state
MODE="install" # install | upgrade (set by --upgrade or existing-install prompt)
PAQET_VERSION=""     # latest release tag, resolved before any prompts
INSTALLED_VERSION="" # version reported by the installed binary

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
    armv7* | armv8l | armhf) PAQET_ARCH="arm32" ;;
    *)
        error "Unsupported architecture: $ARCH"
        exit 1
        ;;
    esac
    info "Detected architecture: $ARCH"
}

check_required_tools() {
    for cmd in ip curl tar; do
        if ! command -v "$cmd" &>/dev/null; then
            error "Required command '$cmd' not found. Please install it."
            exit 1
        fi
    done
}

# User input with defaults
detect_network_info() {
    # Detect primary interface: the one carrying the default route, so it
    # matches the gateway detected below. Fall back to the first non-loopback,
    # non-container interface with an IPv4 address.
    local iface
    iface=$(ip route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    if [[ -z "$iface" ]]; then
        iface=$(ip -4 -o addr show | awk '$2 !~ /^(lo|docker|br-|veth)/ {print $2; exit}')
    fi
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
        mac=$(ip neigh show "$gw" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "lladdr") {print $(i + 1); exit}}')
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
    while true; do
        ask "Server listen port (non-standard recommended, e.g. 9999)" "$DEFAULT_PORT" SERVER_PORT
        if [[ "$SERVER_PORT" =~ ^[0-9]+$ ]] && ((10#$SERVER_PORT >= 1 && 10#$SERVER_PORT <= 65535)); then
            SERVER_PORT=$((10#$SERVER_PORT))
            return
        fi
        error "Invalid port number: $SERVER_PORT (must be 1-65535)"
    done
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
    if [[ -z "$DET_MAC" ]]; then
        warn "Could not detect the gateway MAC address."
        warn "Find it with: ip neigh show ${DET_GW:-<gateway-ip>}"
    fi
    while true; do
        ask "Gateway/router MAC address" "$DET_MAC" NET_GW_MAC
        if [[ "$NET_GW_MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
            break
        fi
        error "Invalid MAC address: '${NET_GW_MAC}' (expected format aa:bb:cc:dd:ee:ff)"
    done

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

prompt_mtu() {
    echo ""
    info "MTU (Maximum Transmission Unit) controls packet size."
    info "Default is 1100, which works well for most networks."
    ask "MTU" "1100" MTU
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
# Release asset names contain the version, so the latest tag is needed to build
# the download URL. Resolved before any prompts so a network failure exits early.
resolve_version() {
    PAQET_VERSION=$(curl -sI "https://github.com/hanselime/paqet/releases/latest" |
        sed -n 's/^[Ll]ocation:.*\/tag\///p' | tr -d '\r')
    if [[ -z "$PAQET_VERSION" ]]; then
        error "Failed to fetch latest release version."
        exit 1
    fi
    info "Latest paqet version: ${PAQET_VERSION}"
}

download_paqet() {
    local version="$PAQET_VERSION"
    local url="https://github.com/hanselime/paqet/releases/download/${version}/paqet-linux-${PAQET_ARCH}-${version}.tar.gz"

    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" EXIT

    mkdir -p "$INSTALL_DIR"

    info "Downloading paqet ${version} for linux/${PAQET_ARCH}..."
    if ! curl -fSL --progress-bar "$url" -o "${tmpdir}/paqet.tar.gz"; then
        error "Download failed: ${url}"
        error "Available releases: https://github.com/hanselime/paqet/releases"
        exit 1
    fi

    tar -xzf "${tmpdir}/paqet.tar.gz" -C "$tmpdir"

    # Archive contains e.g. paqet_linux_amd64 - install it as paqet
    local bin
    bin=$(find "$tmpdir" -maxdepth 1 -type f -name 'paqet_linux_*' | head -1)
    if [[ -z "$bin" ]]; then
        error "paqet binary not found in the release archive."
        exit 1
    fi

    # Install via a temp file + rename so a running binary is replaced atomically
    install -m 755 "$bin" "${INSTALL_DIR}/paqet.new"
    mv -f "${INSTALL_DIR}/paqet.new" "${INSTALL_DIR}/paqet"

    # "paqet version" prints e.g. "Version:    v1.0.0-alpha.21"
    INSTALLED_VERSION=$("${INSTALL_DIR}/paqet" version 2>/dev/null | awk '/^Version:/ {print $2; exit}' || true)
    INSTALLED_VERSION="${INSTALLED_VERSION:-$version}"
    info "Installed to ${INSTALL_DIR}/paqet (${version})"
}

# Configuration generation
generate_config() {
    mkdir -p "$INSTALL_DIR"
    local config="$CONFIG_FILE"

    cat >"$config" <<EOF
# paqet Server Configuration
# Role must be explicitly set
role: "server"

# Logging configuration
log:
  level: "${DEFAULT_LOG_LEVEL}"  # none, debug, info, warn, error, fatal

# Server listen configuration
listen:
  addr: ":${SERVER_PORT}"   # Server listen port (must match network.ipv4.addr port)
                            # WARNING: Do not use standard ports (80, 443, etc.) as iptables rules
                            # can affect outgoing server connections.

# Network interface settings
network:
  interface: "${NET_INTERFACE}"              # Network interface (eth0, ens3, en0, etc.)
  # guid: "\Device\NPF_{...}"                # Windows only (Npcap).

  # IPv4 configuration
  ipv4:
    addr: "${SERVER_IPV4_ADDR}"          # Server IPv4 and port (port must match listen.addr)
    router_mac: "${NET_GW_MAC}"          # Gateway/router MAC address

  # IPv6 configuration (optional)
  # ipv6:
    # addr: "[::1]:9999"                       # Server IPv6 and port (or remove if not using IPv6)
    # router_mac: "aa:bb:cc:dd:ee:ff"          # Gateway/router MAC address

  # TCP flags for packet crafting (optional - will use defaults)
  tcp:
    local_flag: ["${LOCAL_FLAG}"]                       # Local TCP flags (Push+Ack default)

  # PCAP settings (optional - will use defaults)
  # pcap:
    # sockbuf: 8388608                         # 8MB buffer (default for server)

# Transport protocol configuration
transport:
  protocol: "kcp"  # Transport protocol (currently only "kcp" supported)
  conn: 1          # Number of connections (1-256, default: 1)

  # KCP protocol settings
  kcp:
    mode: "${KCP_MODE}"              # KCP mode: normal, fast, fast2, fast3, manual

    # Manual mode parameters (only used when mode="manual")
    # nodelay: 1              # 0=disable, 1=enable
                              # Enable for lower latency & aggressive retransmission
                              # Disable for TCP-like conservative behavior

    # interval: 10            # Internal update timer interval in milliseconds (10-5000ms)
                              # Lower values increase responsiveness but raise CPU usage

    # resend: 2               # Fast retransmit trigger (0-2)
                              # 0 = disabled (wait for timeout only)
                              # 1 = most aggressive (retransmit after 1 ACK skip)
                              # 2 = aggressive (retransmit after 2 ACK skips)

    # nocongestion: 1         # Congestion control: 0=enabled, 1=disabled
                              # 0 = TCP-like fair congestion control (slow start, congestion avoidance)
                              # 1 = disable congestion control for maximum speed

    # wdelay: false           # Write batching behavior
                              # false = flush immediately (low latency, recommended for real-time)
                              # true = batch writes until next update interval (higher throughput)
                              # Controls when data is actually sent to the network

    # acknodelay: true        # ACK sending behavior
                              # true = send ACKs immediately when packets are received (lower latency)
                              # false = batch ACKs (more bandwidth efficient)
                              # Setting true reduces latency but increases bandwidth usage

    mtu: ${MTU}              # Maximum transmission unit (50-1500)
    # rcvwnd: 1024           # Receive window size (default for server)
    # sndwnd: 1024           # Send window size (default for server)

    # Encryption settings
    block: "${ENCRYPT_BLOCK}" # Encryption: aes, aes-128, aes-128-gcm, aes-192, salsa20, blowfish, twofish, cast5, 3des, tea, xtea, xor, sm4, none, null.
    key: "${KCP_KEY}"         # Secret key (must match client)

    # Buffer settings (optional)
    # smuxbuf: 4194304       # 4MB SMUX buffer
    # streambuf: 2097152     # 2MB stream buffer

    # smuxkalive: 2       # SMUX keepalive interval (seconds)
    # smuxktimeout: 8     # SMUX keepalive timeout (seconds)

# Optional Forward Error Correction (FEC) - currently disabled
# Use these only if you need FEC for very lossy networks:
#   dshard: 10    # Data shards for FEC
#   pshard: 3     # Parity shards for FEC
EOF

    chmod 600 "$config"
    info "Configuration written to ${config}"
}

# iptables firewall rules
print_manual_firewall_rules() {
    echo ""
    echo "  iptables -t raw -A PREROUTING -p tcp --dport ${SERVER_PORT} -j NOTRACK -m comment --comment \"paqet\""
    echo "  iptables -t raw -A OUTPUT -p tcp --sport ${SERVER_PORT} -j NOTRACK -m comment --comment \"paqet\""
    echo "  iptables -t mangle -A OUTPUT -p tcp --sport ${SERVER_PORT} --tcp-flags RST RST -j DROP -m comment --comment \"paqet\""
    echo ""
}

# Add a rule unless it already exists. Usage: add_rule <table> <chain> <rule args...>
add_rule() {
    local table="$1" chain="$2" desc="$3"
    shift 3
    if iptables -t "$table" -C "$chain" "$@" -m comment --comment "paqet" 2>/dev/null; then
        warn "${desc} rule already exists for port ${SERVER_PORT}, skipping."
    else
        iptables -t "$table" -A "$chain" "$@" -m comment --comment "paqet"
        info "${desc} rule added."
    fi
}

save_firewall_rules() {
    if command -v netfilter-persistent &>/dev/null; then
        # Debian/Ubuntu with iptables-persistent: saves and reloads at boot
        netfilter-persistent save >/dev/null
        info "Rules saved with netfilter-persistent (restored at boot)."
    elif systemctl list-unit-files iptables.service &>/dev/null &&
        systemctl list-unit-files iptables.service | grep -q '^iptables\.service'; then
        # RHEL/CentOS/Fedora with iptables-services
        iptables-save >/etc/sysconfig/iptables
        systemctl enable iptables &>/dev/null || true
        info "Rules saved to /etc/sysconfig/iptables (restored at boot by iptables.service)."
    else
        mkdir -p /etc/iptables
        iptables-save >/etc/iptables/rules.v4
        warn "Rules saved to /etc/iptables/rules.v4, but nothing on this system loads them at boot."
        warn "Install a loader to make them persistent:"
        warn "  Debian/Ubuntu: apt install iptables-persistent"
        warn "  RHEL/Fedora:   dnf install iptables-services && systemctl enable iptables"
    fi
}

setup_firewall() {
    echo ""
    warn "PAQET REQUIRES iptables RULES to prevent kernel interference."
    warn "Without these, incoming TCP RST packets will break connections."
    echo ""

    local confirm
    ask "Apply iptables rules for port ${SERVER_PORT}?" "yes" confirm

    case "$confirm" in
    y | Y | yes | Yes | YES)
        if ! command -v iptables &>/dev/null; then
            error "'iptables' command not found, cannot apply rules."
            warn "Install iptables, then add these rules manually:"
            print_manual_firewall_rules
            return
        fi

        info "Applying iptables rules..."
        # NOTRACK incoming traffic on server port
        add_rule raw PREROUTING "NOTRACK PREROUTING" -p tcp --dport "$SERVER_PORT" -j NOTRACK
        # NOTRACK outgoing traffic from server port
        add_rule raw OUTPUT "NOTRACK OUTPUT" -p tcp --sport "$SERVER_PORT" -j NOTRACK
        # DROP TCP RST packets from server port
        add_rule mangle OUTPUT "RST DROP" -p tcp --sport "$SERVER_PORT" --tcp-flags RST RST -j DROP

        if command -v iptables-save &>/dev/null; then
            local persist
            ask "Save iptables rules for persistence across reboots?" "yes" persist
            case "$persist" in
            y | Y | yes | Yes | YES) save_firewall_rules ;;
            esac
        fi
        ;;
    *)
        warn "Skipping firewall configuration. You MUST add these rules manually:"
        print_manual_firewall_rules
        ;;
    esac
}

# Systemd service
# Check that the service is still running a few seconds after (re)start, so
# config errors (e.g. after an upgrade) are reported instead of a false success.
verify_service() {
    sleep 3
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        info "Service is running: ${SERVICE_NAME}"
        return 0
    fi
    error "Service ${SERVICE_NAME} failed to start. Recent logs:"
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null || true
    error "Fix the problem, then run: systemctl restart ${SERVICE_NAME}"
    exit 1
}

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
ExecStart=${INSTALL_DIR}/paqet run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable "$SERVICE_NAME"
        # restart (not start) so a re-run picks up the new binary and config
        systemctl restart "$SERVICE_NAME"
        info "Service created and enabled: ${SERVICE_NAME}"
        verify_service
        ;;
    *)
        info "No systemd service created."
        info "Run manually: ${INSTALL_DIR}/paqet run -c ${CONFIG_FILE}"
        ;;
    esac
}

# Summary
print_summary() {
    echo ""
    echo "  Paqet Server Installation Complete"
    echo ""
    echo "  Version:      ${INSTALLED_VERSION}"
    echo "  Binary:       ${INSTALL_DIR}/paqet"
    echo "  Config:       ${CONFIG_FILE}"
    echo "  Listen:       :${SERVER_PORT}"
    echo "  Interface:    ${NET_INTERFACE}"
    echo "  KCP mode:     ${KCP_MODE}"
    echo "  Encryption:   ${ENCRYPT_BLOCK}"
    echo "  KCP Key:      ${KCP_KEY}"
    echo "  MTU:          ${MTU}"
    echo "  TCP flags:    [${LOCAL_FLAG}]"
    echo ""
    warn "Copy the KCP secret key and port to your client config."
    echo ""
    if systemctl is-enabled "$SERVICE_NAME" &>/dev/null; then
        echo "  Service:  systemctl status ${SERVICE_NAME}"
    fi
}

# Upgrade: replace the binary only, keep config and firewall rules
run_upgrade() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "No existing config found at ${CONFIG_FILE}; run without --upgrade to install."
        exit 1
    fi

    local old_version=""
    if [[ -x "${INSTALL_DIR}/paqet" ]]; then
        old_version=$("${INSTALL_DIR}/paqet" version 2>/dev/null | awk '/^Version:/ {print $2; exit}' || true)
    fi
    info "Current version: ${old_version:-unknown}"

    download_paqet

    if systemctl is-enabled "$SERVICE_NAME" &>/dev/null; then
        systemctl restart "$SERVICE_NAME"
        info "Service restarted: ${SERVICE_NAME}"
        verify_service
    else
        warn "No ${SERVICE_NAME} systemd service found; restart paqet manually."
    fi

    echo ""
    echo "  Paqet Server Upgrade Complete"
    echo ""
    echo "  Version:      ${old_version:-unknown} -> ${INSTALLED_VERSION}"
    echo "  Binary:       ${INSTALL_DIR}/paqet"
    echo "  Config:       ${CONFIG_FILE} (unchanged)"
    echo ""
}

# Arguments
usage() {
    cat <<EOF
Usage: installer.sh [--upgrade]

  --upgrade        Only replace the paqet binary, keep the existing config
                   and restart the service.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --upgrade)
            MODE="upgrade"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            error "Unknown argument: $1"
            usage
            exit 1
            ;;
        esac
    done
}

# Offer an upgrade when an existing install is detected
check_existing_install() {
    [[ "$MODE" == "install" && -f "$CONFIG_FILE" ]] || return 0

    echo ""
    warn "An existing paqet config was found at ${CONFIG_FILE}."
    info "  upgrade   - replace the binary only, keep config and key (recommended)"
    info "  reinstall - overwrite config and generate a new key (clients must be updated)"
    info "  abort     - exit without changes"
    local choice
    ask "What would you like to do? (upgrade/reinstall/abort)" "upgrade" choice

    case "$choice" in
    u | upgrade) MODE="upgrade" ;;
    r | reinstall) MODE="install" ;;
    *)
        info "Aborted, nothing changed."
        exit 0
        ;;
    esac
}

# Main
main() {
    parse_args "$@"

    echo ""
    echo "  Paqet Server Installer"
    echo ""

    check_root
    check_arch
    check_required_tools
    check_existing_install
    resolve_version

    if [[ "$MODE" == "upgrade" ]]; then
        run_upgrade
        return
    fi

    echo ""
    info "Step 1/7: Server port"
    prompt_server_port

    info "Step 2/7: Network configuration"
    prompt_network_details

    info "Step 3/7: KCP encryption key"
    prompt_kcp_key

    info "Step 4/7: KCP mode & encryption"
    prompt_kcp_mode
    prompt_encryption

    info "Step 5/7: MTU"
    prompt_mtu

    info "Step 6/7: TCP flags for packet crafting"
    prompt_tcp_flags

    info "Step 7/7: Download & install"
    download_paqet
    generate_config
    setup_firewall
    setup_service
    print_summary
}

main "$@"
