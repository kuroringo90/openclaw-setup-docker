#!/bin/bash
#
# Tailscale Proxy Helper
# Configura Tailscale Funnel per multipli servizi
#
# USO:
#   ./tailscale-proxy.sh <servizio> <porta> [path] [azione]
#
# ESEMPI:
#   ./tailscale-proxy.sh grafana 3000 /grafana configure
#   ./tailscale-proxy.sh homeassistant 8123 /ha configure
#   ./tailscale-proxy.sh status
#

set -euo pipefail

# ============================================
# CONFIGURAZIONE
# ============================================
GATEWAY_CONTAINER="${GATEWAY_CONTAINER:-openclaw}"
SIDECAR_CONTAINER="${SIDECAR_CONTAINER:-openclaw-tailscale}"

# Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error() { echo -e "${RED}[ERRORE]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ============================================
# FUNZIONI
# ============================================

check_prereqs() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker non trovato!"
        exit 1
    fi

    if ! docker ps --format '{{.Names}}' | grep -q "^${GATEWAY_CONTAINER}$"; then
        log_error "Gateway container non trovato: ${GATEWAY_CONTAINER}"
        log_info "Avvia prima OpenClaw: ./openclaw-manager-tailscale.sh start"
        exit 1
    fi

    if ! docker ps --format '{{.Names}}' | grep -q "^${SIDECAR_CONTAINER}$"; then
        log_error "Sidecar container non trovato: ${SIDECAR_CONTAINER}"
        log_info "Avvia prima Tailscale: ./openclaw-manager-tailscale.sh start"
        exit 1
    fi
}

get_hostname() {
    local hostname
    hostname=$(docker exec "${SIDECAR_CONTAINER}" tailscale status --json 2>/dev/null | \
        grep -o '"DNSName"[^,]*' | head -1 | cut -d'"' -f4 | sed 's/\.$//')
    
    if [[ -z "$hostname" ]]; then
        hostname=$(docker exec "${SIDECAR_CONTAINER}" tailscale status 2>/dev/null | \
            grep -o '^[0-9.]*[[:space:]]*[^[:space:]]*' | awk '{print $2}' | head -1)
    fi
    
    echo "$hostname"
}

configure_service() {
    local service_name="$1"
    local service_port="$2"
    local service_path="${3:-/${service_name}}"

    log_info "Configurazione servizio: ${service_name} → porta ${service_port}"

    # Configura serve con path-based routing
    if docker exec "${SIDECAR_CONTAINER}" tailscale serve --bg --set-path "${service_path}" "${service_port}" 2>&1; then
        log_success "Servizio configurato!"
    else
        log_error "Configurazione fallita"
        exit 1
    fi

    # Abilita funnel sulla porta del servizio (NON 443!)
    # Funnel userà la stessa porta del serve
    docker exec "${SIDECAR_CONTAINER}" tailscale funnel --bg "${service_port}" 2>&1 || log_warn "Funnel potrebbe già essere attivo"

    # Mostra URL
    local hostname
    hostname=$(get_hostname)

    echo ""
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}Servizio disponibile:${NC}"
    echo -e "${BLUE}https://${hostname}${service_path}${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
}

remove_service() {
    local service_name="$1"
    local service_port="$2"
    local service_path="${3:-/${service_name}}"

    log_warn "⚠️  Questo rimuoverà TUTTA la configurazione serve"
    read -rp "Sei sicuro? (y/N): " confirm

    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        log_info "Rimozione configurazione serve..."
        docker exec "${SIDECAR_CONTAINER}" tailscale serve reset 2>/dev/null || true
        log_success "Servizio rimosso"
        log_warn "Nota: tutti i servizi sono stati rimossi, non solo ${service_name}"
    else
        log_info "Operazione annullata"
    fi
}

show_status() {
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║      STATO TAILSCALE PROXY             ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""

    # Gateway
    echo -e "${YELLOW}┌── Gateway ───────────────────────────┐${NC}"
    if docker ps --format '{{.Names}}' | grep -q "^${GATEWAY_CONTAINER}$"; then
        echo -e "│ ${GATEWAY_CONTAINER}: ${GREEN}✅ ATTIVO${NC}"
    else
        echo -e "│ ${GATEWAY_CONTAINER}: ${RED}❌ NON ATTIVO${NC}"
    fi
    echo -e "${YELLOW}└──────────────────────────────────────┘${NC}"
    echo ""

    # Sidecar
    echo -e "${YELLOW}┌── Tailscale Sidecar ─────────────────┐${NC}"
    if docker ps --format '{{.Names}}' | grep -q "^${SIDECAR_CONTAINER}$"; then
        echo -e "│ ${SIDECAR_CONTAINER}: ${GREEN}✅ ATTIVO${NC}"

        local hostname
        hostname=$(get_hostname)
        if [[ -n "$hostname" ]]; then
            echo -e "│ Hostname: ${BLUE}${hostname}${NC}"
        fi

        # Funnel status
        if docker exec "${SIDECAR_CONTAINER}" tailscale funnel status 2>&1 | grep -q "Available on the internet"; then
            echo -e "│ Funnel: ${GREEN}✅ ABILITATO${NC}"
        else
            echo -e "│ Funnel: ${YELLOW}⚠️ NON ABILITATO${NC}"
        fi
    else
        echo -e "│ ${SIDECAR_CONTAINER}: ${RED}❌ NON ATTIVO${NC}"
    fi
    echo -e "${YELLOW}└──────────────────────────────────────┘${NC}"
    echo ""

    # Servizi
    echo -e "${YELLOW}┌── Servizi Configurati ───────────────┐${NC}"
    docker exec "${SIDECAR_CONTAINER}" tailscale serve status 2>&1 | while read -r line; do
        echo -e "│ $line"
    done
    echo -e "${YELLOW}└──────────────────────────────────────┘${NC}"
    echo ""

    # URL
    local hostname
    hostname=$(get_hostname)
    if [[ -n "$hostname" ]]; then
        echo -e "${GREEN}URL Base: ${BLUE}https://${hostname}${NC}"
    fi
}

show_help() {
    cat << EOF
Tailscale Proxy Helper

Configura Tailscale Funnel per esporre multipli servizi locali.

USO:
    $0 <servizio> <porta> [path] [azione]

COMANDI:
    configure   Aggiungi un servizio (default)
    remove      Rimuovi tutti i servizi
    status      Mostra stato configurazione
    help        Mostra questo aiuto

ESEMPI:
    # Aggiungi Grafana su porta 3000
    $0 grafana 3000 /grafana

    # Aggiungi Home Assistant
    $0 homeassistant 8123 /ha

    # Aggiungi Node-RED
    $0 node-red 1880 /node-red

    # Mostra stato
    $0 status

    # Rimuovi tutti i servizi
    $0 any 0000 /any remove

NOTE:
    - Gateway: ${GATEWAY_CONTAINER}
    - Sidecar: ${SIDECAR_CONTAINER}
    - I servizi usano path-based routing
    - Funnel deve essere abilitato su porta 443

EOF
}

# ============================================
# MAIN
# ============================================

case "${1:-help}" in
    status|st)
        check_prereqs
        show_status
        ;;
    remove|rm|reset)
        check_prereqs
        remove_service "${2:-any}" "${3:-0000}" "${4:-/any}"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        check_prereqs
        configure_service "$1" "$2" "${3:-/$1}"
        ;;
esac
