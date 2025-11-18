#!/usr/bin/env bash
#
# Cloudflare DNS Proxy Toggle Script
# Auto-detects Cloudflare network issues and toggles DNS proxy status
#
# Author: richardevcom
# License: MIT

set -euo pipefail

# ============================================================================
# Configuration & Constants
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
STATE_FILE="${SCRIPT_DIR}/.state.json"
DEFAULT_CHECK_INTERVAL=60
DEFAULT_LOG_FILE="${SCRIPT_DIR}/cloudflare-dns-toggle.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# Helper Functions
# ============================================================================

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} [${level}] ${msg}" | tee -a "${LOG_FILE:-$DEFAULT_LOG_FILE}" >&2
}

log_info() { log "INFO" "$@"; }
log_error() { log "ERROR" "$@"; }
log_warn() { log "WARN" "$@"; }

print_banner() {
    echo -e "${BLUE}"
    cat << "EOF"
   ____ _                 _  __ _                
  / ___| | ___  _   _  __| |/ _| | __ _ _ __ ___ 
 | |   | |/ _ \| | | |/ _` | |_| |/ _` | '__/ _ \
 | |___| | (_) | |_| | (_| |  _| | (_| | | |  __/
  \____|_|\___/ \__,_|\__,_|_| |_|\__,_|_|  \___|
                                                  
  DNS Proxy Toggle - Auto-detect CF outages
EOF
    echo -e "${NC}"
}

check_dependencies() {
    local deps=("curl" "jq")
    local missing=()
    
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        echo -e "${RED}Install them:${NC}"
        echo "  Ubuntu/Debian: sudo apt install curl jq"
        echo "  MacOS: brew install curl jq"
        echo "  Arch: sudo pacman -S curl jq"
        exit 1
    fi
}

load_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error ".env file not found: $ENV_FILE"
        echo -e "${YELLOW}Creating .env file from template...${NC}"
        
        if [[ -f "${SCRIPT_DIR}/.env.example" ]]; then
            cp "${SCRIPT_DIR}/.env.example" "$ENV_FILE"
            echo -e "${GREEN}✓ Created $ENV_FILE${NC}"
            echo -e "${YELLOW}⚠  Edit $ENV_FILE and add your credentials${NC}"
            exit 2
        else
            log_error ".env.example not found"
            exit 2
        fi
    fi
    
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    
    # Validate required variables
    : "${CF_API_TOKEN:?CF_API_TOKEN not set in .env}"
    
    # CF_ZONE_ID is optional - will auto-detect from domain if not set
    
    # Set defaults
    CHECK_INTERVAL="${CHECK_INTERVAL:-$DEFAULT_CHECK_INTERVAL}"
    LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"
    AUTO_TOGGLE="${AUTO_TOGGLE:-true}"
}

# ============================================================================
# Cloudflare API Functions
# ============================================================================

cf_api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    
    local response
    local http_code
    
    if [[ -n "$data" ]]; then
        response=$(curl -s -w "\n%{http_code}" -X "$method" \
            "https://api.cloudflare.com/client/v4${endpoint}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "$data")
    else
        response=$(curl -s -w "\n%{http_code}" -X "$method" \
            "https://api.cloudflare.com/client/v4${endpoint}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json")
    fi
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" != "200" ]]; then
        log_error "API call failed: HTTP $http_code"
        echo "$body" | jq -r '.errors[]?.message // "Unknown error"' >&2
        return 3
    fi
    
    echo "$body"
}

get_zone_id_from_domain() {
    local domain="$1"
    local base_domain
    
    # Try full domain first (for exact match)
    local response
    response=$(cf_api_call "GET" "/zones?name=${domain}" 2>/dev/null)
    local zone_id
    zone_id=$(echo "$response" | jq -r '.result[0].id // empty')
    
    if [[ -n "$zone_id" ]]; then
        echo "$zone_id"
        return 0
    fi
    
    # Extract base domain for subdomains (e.g., nurmebeer.com from brewing.nurmebeer.com)
    # Handle multi-level: sub.domain.com -> domain.com, sub.domain.co.uk -> domain.co.uk
    if [[ "$domain" =~ \. ]]; then
        # Get last 2 parts (handles most TLDs)
        base_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
        
        response=$(cf_api_call "GET" "/zones?name=${base_domain}" 2>/dev/null)
        zone_id=$(echo "$response" | jq -r '.result[0].id // empty')
        
        if [[ -n "$zone_id" ]]; then
            echo "$zone_id"
            return 0
        fi
    fi
    
    # Not found
    return 1
}

get_dns_records() {
    local zone_id="$1"
    log_info "Fetching DNS records for zone: $zone_id"
    
    cf_api_call "GET" "/zones/${zone_id}/dns_records?type=A,AAAA,CNAME"
}

get_record_by_name() {
    local zone_id="$1"
    local domain="$2"
    
    cf_api_call "GET" "/zones/${zone_id}/dns_records?name=${domain}"
}

update_proxy_status() {
    local zone_id="$1"
    local record_id="$2"
    local proxied="$3"
    
    local data
    data=$(jq -n --argjson proxied "$proxied" '{proxied: $proxied}')
    
    cf_api_call "PATCH" "/zones/${zone_id}/dns_records/${record_id}" "$data"
}

# ============================================================================
# Domain Health Check
# ============================================================================

check_domain_health() {
    local domain="$1"
    local response
    
    # Get both status code and headers
    response=$(curl -sS -w "\n%{http_code}\n" -H "User-Agent: cloudflare-dns-toggle/1.0" \
        --max-time 10 "https://${domain}" 2>&1 || echo -e "\n000\n")
    
    local http_code
    http_code=$(echo "$response" | tail -n 1)
    local headers_and_body
    headers_and_body=$(echo "$response" | head -n -1)
    
    # Check for CF-RAY header (indicates request went through CF)
    local has_cf_ray
    has_cf_ray=$(echo "$headers_and_body" | grep -i "cf-ray:" || echo "")
    
    # Cloudflare network errors: 500/502/503 WITH CF branding
    # Origin errors: 520-527 (CF couldn't reach origin)
    if [[ "$http_code" =~ ^(520|521|522|523|524|525|526|527)$ ]]; then
        # Origin server issue - don't toggle, this won't help
        echo "origin-down|$http_code"
    elif [[ "$http_code" =~ ^(500|502|503)$ ]] && [[ -n "$has_cf_ray" ]]; then
        # Check if it's CF-branded error (CF network issue) or origin error passing through
        if echo "$headers_and_body" | grep -qi "cloudflare"; then
            echo "cf-down|$http_code"  # Cloudflare network issue - toggle will help
        else
            echo "origin-down|$http_code"  # Origin returning 500 - toggle won't help
        fi
    elif [[ "$http_code" == "000" ]]; then
        echo "unreachable|000"
    elif [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        echo "up|$http_code"
    else
        # Other errors (4xx, etc.) - site is "working" from CF perspective
        echo "up|$http_code"
    fi
}

# ============================================================================
# Interactive Domain Selection
# ============================================================================

select_domains() {
    if [[ -z "${CF_ZONE_ID:-}" ]]; then
        log_error "CF_ZONE_ID not set and cannot auto-discover without domain"
        echo -e "${YELLOW}Provide domain as argument or set CF_ZONE_ID in .env${NC}"
        exit 4
    fi
    
    local records
    records=$(get_dns_records "$CF_ZONE_ID")
    
    if [[ $(echo "$records" | jq -r '.result | length') -eq 0 ]]; then
        log_error "No DNS records found in zone"
        exit 4
    fi
    
    echo -e "\n${BLUE}Available DNS Records:${NC}"
    echo "$records" | jq -r '.result[] | "\(.name) (\(.type)) - Proxied: \(.proxied)"' | nl
    
    echo -e "\n${YELLOW}Enter domain numbers to monitor (space-separated, or 'all'):${NC}"
    read -r selection
    
    local selected_domains=()
    
    if [[ "$selection" == "all" ]]; then
        mapfile -t selected_domains < <(echo "$records" | jq -r '.result[].name')
    else
        for num in $selection; do
            local domain
            domain=$(echo "$records" | jq -r ".result[$((num-1))].name")
            if [[ "$domain" != "null" ]]; then
                selected_domains+=("$domain")
            fi
        done
    fi
    
    if [[ ${#selected_domains[@]} -eq 0 ]]; then
        log_error "No valid domains selected"
        exit 4
    fi
    
    printf '%s\n' "${selected_domains[@]}"
}

# ============================================================================
# State Management
# ============================================================================

save_state() {
    local domain="$1"
    local record_id="$2"
    local original_proxied="$3"
    
    local state
    if [[ -f "$STATE_FILE" ]]; then
        state=$(cat "$STATE_FILE")
    else
        state="{}"
    fi
    
    state=$(echo "$state" | jq \
        --arg domain "$domain" \
        --arg record_id "$record_id" \
        --argjson proxied "$original_proxied" \
        '.[$domain] = {record_id: $record_id, original_proxied: $proxied, timestamp: now | floor}')
    
    echo "$state" > "$STATE_FILE"
}

get_state() {
    local domain="$1"
    
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "null"
        return
    fi
    
    jq -r --arg domain "$domain" '.[$domain] // null' "$STATE_FILE"
}

# ============================================================================
# Core Toggle Logic
# ============================================================================

toggle_domain() {
    local domain="$1"
    local desired_state="$2"  # "enable" or "disable"
    
    log_info "Processing domain: $domain"
    
    # Auto-detect zone if not set
    local zone_id="${CF_ZONE_ID:-}"
    if [[ -z "$zone_id" ]]; then
        log_info "Auto-detecting zone for $domain..."
        zone_id=$(get_zone_id_from_domain "$domain")
        if [[ -z "$zone_id" ]]; then
            log_error "Could not find zone for $domain"
            return 4
        fi
        log_info "Detected zone: $zone_id"
    fi
    
    # Get DNS record
    local record
    record=$(get_record_by_name "$zone_id" "$domain")
    
    if [[ $(echo "$record" | jq -r '.result | length') -eq 0 ]]; then
        log_error "Domain not found: $domain"
        return 4
    fi
    
    local record_id
    local current_proxied
    record_id=$(echo "$record" | jq -r '.result[0].id')
    current_proxied=$(echo "$record" | jq -r '.result[0].proxied')
    
    # Save original state if not exists
    local state
    state=$(get_state "$domain")
    if [[ "$state" == "null" ]]; then
        save_state "$domain" "$record_id" "$current_proxied"
    fi
    
    # Determine target state
    local target_proxied
    if [[ "$desired_state" == "enable" ]]; then
        target_proxied="true"
    else
        target_proxied="false"
    fi
    
    # Check if change needed
    if [[ "$current_proxied" == "$target_proxied" ]]; then
        log_info "Domain $domain already in desired state (proxied=$target_proxied)"
        return 0
    fi
    
    # Apply change
    log_info "Toggling proxy for $domain: $current_proxied → $target_proxied"
    update_proxy_status "$zone_id" "$record_id" "$target_proxied"
    
    echo -e "${GREEN}✓ Updated $domain (proxied=$target_proxied)${NC}"
}

# ============================================================================
# Monitor Mode
# ============================================================================

monitor_domains() {
    local domains=("$@")
    
    echo -e "${BLUE}Starting monitor mode...${NC}"
    echo -e "Check interval: ${CHECK_INTERVAL}s"
    echo -e "Domains: ${domains[*]}"
    echo -e "Press Ctrl+C to stop\n"
    
    while true; do
        for domain in "${domains[@]}"; do
            local health_result
            health_result=$(check_domain_health "$domain")
            local health_status="${health_result%%|*}"
            local http_code="${health_result##*|}"
            
            case "$health_status" in
                "cf-down")
                    log_warn "⚠️  $domain - Cloudflare network error (HTTP $http_code)"
                    if [[ "$AUTO_TOGGLE" == "true" ]]; then
                        log_info "Disabling proxy to bypass CF..."
                        toggle_domain "$domain" "disable"
                    fi
                    ;;
                "origin-down")
                    log_error "✗ $domain - Origin server error (HTTP $http_code)"
                    log_info "Not toggling proxy - issue is with origin server, not Cloudflare"
                    ;;
                "up")
                    if [[ "$http_code" == "200" ]]; then
                        log_info "✓ $domain - OK (HTTP $http_code)"
                    else
                        log_info "✓ $domain - Responding (HTTP $http_code)"
                    fi
                    if [[ "$AUTO_TOGGLE" == "true" ]]; then
                        toggle_domain "$domain" "enable"
                    fi
                    ;;
                "unreachable")
                    log_error "✗ $domain - Unreachable (connection failed)"
                    ;;
            esac
            
            sleep 0.3  # Rate limit between domains
        done
        
        sleep "$CHECK_INTERVAL"
    done
}

# ============================================================================
# Systemd Service Setup
# ============================================================================

install_service() {
    local domains="$1"
    local service_file="/etc/systemd/system/cloudflare-dns-toggle.service"
    
    echo -e "${YELLOW}Creating systemd service...${NC}"
    
    local service_content
    service_content=$(cat <<EOF
[Unit]
Description=Cloudflare DNS Proxy Auto-Toggle
After=network.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${SCRIPT_DIR}/cloudflare-dns-toggle.sh monitor ${domains}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
)
    
    echo "$service_content" | sudo tee "$service_file" > /dev/null
    sudo systemctl daemon-reload
    sudo systemctl enable cloudflare-dns-toggle.service
    sudo systemctl start cloudflare-dns-toggle.service
    
    echo -e "${GREEN}✓ Service installed and started${NC}"
    echo -e "\nUseful commands:"
    echo "  sudo systemctl status cloudflare-dns-toggle"
    echo "  sudo journalctl -u cloudflare-dns-toggle -f"
    echo "  sudo systemctl stop cloudflare-dns-toggle"
}

# ============================================================================
# CLI Interface
# ============================================================================

show_usage() {
    cat << EOF
Usage: $(basename "$0") <command> [domains...]

Commands:
  check [domains...]   Check health status of domains
  enable [domains...]  Enable Cloudflare proxy (orange cloud)
  disable [domains...] Disable Cloudflare proxy (grey cloud)
  status [domains...]  Show current proxy status
  monitor [domains...] Start monitoring mode (auto-toggle)
  restore [domains...] Restore original proxy settings
  install-service      Install systemd service for auto-monitoring

If no domains specified, interactive selection will be shown.

Examples:
  $(basename "$0") check example.com
  $(basename "$0") disable example.com www.example.com
  $(basename "$0") monitor
  $(basename "$0") install-service

Environment:
  Configure credentials in .env file (see .env.example)

EOF
}

main() {
    if [[ $# -eq 0 ]]; then
        print_banner
        show_usage
        exit 0
    fi
    
    local command="$1"
    shift
    
    # Commands that don't need env
    case "$command" in
        help|-h|--help)
            show_usage
            exit 0
            ;;
    esac
    
    check_dependencies
    load_env
    
    # Get domains
    local domains=()
    if [[ $# -eq 0 ]]; then
        mapfile -t domains < <(select_domains)
    else
        domains=("$@")
    fi
    
    case "$command" in
        check)
            for domain in "${domains[@]}"; do
                # Get proxy status first
                local zone_id="${CF_ZONE_ID:-}"
                if [[ -z "$zone_id" ]]; then
                    zone_id=$(get_zone_id_from_domain "$domain" 2>/dev/null)
                fi
                
                local proxy_status="unknown"
                if [[ -n "$zone_id" ]]; then
                    local record
                    record=$(get_record_by_name "$zone_id" "$domain" 2>/dev/null)
                    local proxied
                    proxied=$(echo "$record" | jq -r '.result[0].proxied // "unknown"')
                    if [[ "$proxied" == "true" ]]; then
                        proxy_status="🟠 proxied"
                    elif [[ "$proxied" == "false" ]]; then
                        proxy_status="☁️  direct"
                    fi
                fi
                
                # Get health status
                local health_result
                health_result=$(check_domain_health "$domain")
                local health_status="${health_result%%|*}"
                local http_code="${health_result##*|}"
                
                # Build status message
                case "$health_status" in
                    "up")
                        if [[ "$http_code" == "200" ]]; then
                            echo -e "${GREEN}✓${NC} $domain [$proxy_status] - OK (HTTP $http_code)"
                        elif [[ "$http_code" =~ ^40[134]$ ]]; then
                            local msg="Forbidden"
                            [[ "$http_code" == "404" ]] && msg="Not Found"
                            [[ "$http_code" == "401" ]] && msg="Unauthorized"
                            echo -e "${YELLOW}⚠${NC} $domain [$proxy_status] - $msg (HTTP $http_code)"
                        else
                            echo -e "${GREEN}✓${NC} $domain [$proxy_status] - Responding (HTTP $http_code)"
                        fi
                        ;;
                    "cf-down")
                        echo -e "${RED}✗${NC} $domain [$proxy_status] - Cloudflare network error (HTTP $http_code)"
                        ;;
                    "origin-down")
                        local origin_msg="Origin server error"
                        [[ "$http_code" == "520" ]] && origin_msg="Origin returned empty response"
                        [[ "$http_code" == "521" ]] && origin_msg="Origin refused connection"
                        [[ "$http_code" == "522" ]] && origin_msg="Origin connection timeout"
                        [[ "$http_code" == "523" ]] && origin_msg="Origin unreachable"
                        [[ "$http_code" == "524" ]] && origin_msg="Origin timeout"
                        [[ "$http_code" == "525" ]] && origin_msg="SSL handshake failed"
                        [[ "$http_code" == "526" ]] && origin_msg="Invalid SSL certificate"
                        [[ "$http_code" == "527" ]] && origin_msg="Railgun error"
                        echo -e "${YELLOW}⚠${NC} $domain [$proxy_status] - $origin_msg (HTTP $http_code)"
                        ;;
                    "unreachable")
                        echo -e "${RED}✗${NC} $domain [$proxy_status] - Unreachable (connection failed)"
                        ;;
                esac
            done
            ;;
        enable)
            for domain in "${domains[@]}"; do
                toggle_domain "$domain" "enable"
            done
            ;;
        disable)
            for domain in "${domains[@]}"; do
                toggle_domain "$domain" "disable"
            done
            ;;
        status)
            for domain in "${domains[@]}"; do
                # Auto-detect zone if not set
                local zone_id="${CF_ZONE_ID:-}"
                if [[ -z "$zone_id" ]]; then
                    zone_id=$(get_zone_id_from_domain "$domain")
                    [[ -z "$zone_id" ]] && { log_error "Zone not found for $domain"; continue; }
                fi
                
                local record
                record=$(get_record_by_name "$zone_id" "$domain")
                local proxied
                proxied=$(echo "$record" | jq -r '.result[0].proxied')
                if [[ "$proxied" == "true" ]]; then
                    echo -e "$domain: ${GREEN}Proxied (🟠)${NC}"
                else
                    echo -e "$domain: ${YELLOW}DNS Only (☁️)${NC}"
                fi
            done
            ;;
        monitor)
            monitor_domains "${domains[@]}"
            ;;
        restore)
            for domain in "${domains[@]}"; do
                local state
                state=$(get_state "$domain")
                if [[ "$state" == "null" ]]; then
                    log_warn "No saved state for $domain"
                    continue
                fi
                
                local original_proxied
                original_proxied=$(echo "$state" | jq -r '.original_proxied')
                local desired_state
                if [[ "$original_proxied" == "true" ]]; then
                    desired_state="enable"
                else
                    desired_state="disable"
                fi
                
                toggle_domain "$domain" "$desired_state"
            done
            ;;
        install-service)
            install_service "${domains[*]}"
            ;;
        *)
            echo -e "${RED}Unknown command: $command${NC}"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
