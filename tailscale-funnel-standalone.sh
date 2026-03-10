#!/bin/bash
#
# Tailscale Funnel Standalone
# Gestione indipendente del sidecar Tailscale con API per evitare nodi duplicati
#
# REQUISITI:
#   - TS_AUTHKEY: chiave di autenticazione (da .env o ambiente)
#   - TS_API_KEY: API key per gestione nodi (opzionale, da admin console)
#   - TS_TAILNET: nome della tailnet (opzionale, auto-rilevato)
#
# USO:
#   ./tailscale-funnel-standalone.sh start [service_name] [port]
#   ./tailscale-funnel-standalone.sh stop
#   ./tailscale-funnel-standalone.sh restart
#   ./tailscale-funnel-standalone.sh status
#   ./tailscale-funnel-standalone.sh add <name> <port> [path]
#   ./tailscale-funnel-standalone.sh remove <name>
#   ./tailscale-funnel-standalone.sh cleanup    # Elimina nodi duplicati via API
#   ./tailscale-funnel-standalone.sh url        # Mostra URL Magic
#

set -euo pipefail

# ============================================
# CONFIGURAZIONE
# ============================================
CONTAINER_NAME="${TS_CONTAINER_NAME:-tailscale-funnel}"
IMAGE_NAME="tailscale/tailscale:latest"
DATA_DIR="${HOME}/.tailscale-funnel"
ENV_FILE="${DATA_DIR}/.env"
STATE_DIR="${DATA_DIR}/state"

# Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERRORE]${NC} $1"; }

# ============================================
# FUNZIONI DI UTILITÀ
# ============================================

init_dirs() {
    mkdir -p "${DATA_DIR}" "${STATE_DIR}"
    
    # Crea .env se non esiste
    if [[ ! -f "${ENV_FILE}" ]]; then
        cat > "${ENV_FILE}" << 'EOF'
# Tailscale Authentication Key (per avvio container)
# Ottieni da: https://login.tailscale.com/admin/settings/keys
TS_AUTHKEY=

# Tailscale API Key (per gestione nodi via API - opzionale)
# Ottieni da: https://login.tailscale.com/admin/settings/api
TS_API_KEY=

# Tailnet name (opzionale, auto-rilevato se vuoto)
TS_TAILNET=

# Hostname del nodo (default: tailscale-funnel)
TS_HOSTNAME=tailscale-funnel
EOF
        log_success "Creato ${ENV_FILE}"
    fi
    
    # Carica variabili da .env
    if [[ -f "${ENV_FILE}" ]]; then
        set -a
        source "${ENV_FILE}"
        set +a
    fi
}

check_prereqs() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker non trovato!"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "Docker non è in esecuzione!"
        exit 1
    fi
    
    if [[ -z "${TS_AUTHKEY:-}" ]]; then
        log_error "TS_AUTHKEY non impostata!"
        log_info "Imposta in ${ENV_FILE} o export TS_AUTHKEY=..."
        exit 1
    fi
}

is_container_running() {
    docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

get_tailnet_name() {
    if [[ -n "${TS_TAILNET:-}" ]]; then
        echo "${TS_TAILNET}"
        return
    fi
    
    # Auto-rileva da tailscale status
    if is_container_running; then
        local status
        status=$(docker exec "${CONTAINER_NAME}" tailscale status --json 2>/dev/null || true)
        if [[ -n "$status" ]]; then
            local dnsname
            dnsname=$(echo "$status" | grep -o '"DNSName"[^,]*' | head -1 | cut -d'"' -f4 | sed 's/\.$//')
            if [[ -n "$dnsname" ]]; then
                # Estrai tailnet da dnsname (es: hostname.tailnet-id.ts.net → tailnet-id)
                echo "$dnsname" | cut -d'.' -f2
                return
            fi
        fi
    fi
    
    echo ""
}

get_node_id() {
    local hostname="${1:-${TS_HOSTNAME:-tailscale-funnel}}"
    
    if is_container_running; then
        local status
        status=$(docker exec "${CONTAINER_NAME}" tailscale status --json 2>/dev/null || true)
        if [[ -n "$status" ]]; then
            # Cerca nodo con hostname specifico
            local peer_info
            peer_info=$(echo "$status" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for peer_id, peer in data.get('Peer', {}).items():
        if peer.get('HostName', '').startswith('$hostname'):
            print(peer_id)
            break
    else:
        # Cerca Self
        if 'Self' in data:
            print(data['Self'].get('ID', ''))
except:
    pass
" 2>/dev/null || true)
            if [[ -n "$peer_info" ]]; then
                echo "$peer_info"
                return
            fi
        fi
    fi
    
    echo ""
}

# ============================================
# GESTIONE NODI DUPLICATI VIA API
# ============================================

cleanup_duplicate_nodes_api() {
    local hostname="${TS_HOSTNAME:-tailscale-funnel}"
    local api_key="${TS_API_KEY:-}"
    local tailnet="${TS_TAILNET:-}"
    
    if [[ -z "$api_key" ]]; then
        log_warn "TS_API_KEY non impostata: impossibile usare API per cleanup"
        log_info "Ottieni API key da: https://login.tailscale.com/admin/settings/api"
        return 0
    fi
    
    if [[ -z "$tailnet" ]]; then
        tailnet=$(get_tailnet_name)
        if [[ -z "$tailnet" ]]; then
            log_error "Impossibile determinare tailnet name"
            return 1
        fi
    fi
    
    log_info "Ricerca nodi duplicati per hostname: ${hostname}..."
    
    # Chiama API Tailscale per lista dispositivi
    local devices
    devices=$(curl -s -u "${api_key}:" \
        "https://api.tailscale.com/api/v2/tailnet/${tailnet}/devices" \
        2>/dev/null || echo "")
    
    if [[ -z "$devices" ]]; then
        log_error "Chiamata API fallita"
        return 1
    fi
    
    # Trova nodi con hostname che inizia con TS_HOSTNAME
    local matching_nodes
    matching_nodes=$(echo "$devices" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    nodes = []
    for device in data.get('devices', []):
        name = device.get('name', '')
        if name.startswith('$hostname'):
            nodes.append({
                'id': device.get('id', ''),
                'name': name,
                'lastSeen': device.get('lastSeen', '')
            })
    # Ordina per lastSeen (più recente primo)
    nodes.sort(key=lambda x: x['lastSeen'], reverse=True)
    for node in nodes:
        print(f\"{node['id']}|{node['name']}|{node['lastSeen']}\")
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" 2>&1)
    
    if [[ -z "$matching_nodes" ]] || echo "$matching_nodes" | grep -q "^ERROR:"; then
        log_error "Errore parsing API response"
        return 1
    fi
    
    local node_count
    node_count=$(echo "$matching_nodes" | wc -l)
    
    if [[ $node_count -le 1 ]]; then
        log_success "Nessun nodo duplicato trovato"
        return 0
    fi
    
    log_warn "Trovati ${node_count} nodi con hostname '${hostname}':"
    echo "$matching_nodes" | while IFS='|' read -r id name lastseen; do
        echo "  - ${name} (ID: ${id}, last: ${lastseen})"
    done
    
    # Mantieni solo il più recente, elimina gli altri
    local first=true
    echo "$matching_nodes" | while IFS='|' read -r id name lastseen; do
        if [[ "$first" == true ]]; then
            first=false
            log_info "Mantengo nodo: ${name}"
        else
            log_info "Elimino nodo duplicato: ${name}..."
            
            local delete_response
            delete_response=$(curl -s -X DELETE \
                -u "${api_key}:" \
                "https://api.tailscale.com/api/v2/device/${id}" \
                2>/dev/null || echo "ERROR")
            
            if [[ "$delete_response" == "ERROR" ]] || [[ -n "$delete_response" && "$delete_response" != "{}" ]]; then
                log_error "Eliminazione fallita per ${name}"
            else
                log_success "Eliminato: ${name}"
            fi
        fi
    done
    
    log_success "Cleanup completato!"
}

# ============================================
# COMANDI PRINCIPALI
# ============================================

cmd_start() {
    init_dirs
    check_prereqs
    
    local service_name="${1:-funnel}"
    local service_port="${2:-18789}"
    
    # Cleanup nodi duplicati prima di avviare
    cleanup_duplicate_nodes_api
    
    if is_container_running; then
        log_warn "Container già in esecuzione"
    else
        log_info "Avvio container Tailscale Funnel..."
        
        docker run -d \
            --name "${CONTAINER_NAME}" \
            --restart unless-stopped \
            --network host \
            -v "${STATE_DIR}:/var/lib/tailscale" \
            -e TS_AUTHKEY="${TS_AUTHKEY}" \
            "${IMAGE_NAME}" \
            tailscaled --tun=userspace-networking --hostname="${TS_HOSTNAME:-tailscale-funnel}"
        
        sleep 3
        
        if ! is_container_running; then
            log_error "Avvio fallito!"
            docker logs "${CONTAINER_NAME}" 2>&1 | tail -20
            exit 1
        fi
        
        log_success "Container avviato!"
    fi
    
    # Autenticazione
    log_info "Autenticazione in corso..."
    docker exec "${CONTAINER_NAME}" tailscale up \
        --authkey="${TS_AUTHKEY}" \
        --hostname="${TS_HOSTNAME:-tailscale-funnel}" \
        --force-reauth \
        --timeout=60s 2>&1 || log_warn "Autenticazione fallita, verifica authkey"
    
    # Configura funnel per il servizio
    log_info "Configurazione funnel per ${service_name}:${service_port}..."
    docker exec "${CONTAINER_NAME}" tailscale serve --bg "${service_port}" 2>&1 || true
    docker exec "${CONTAINER_NAME}" tailscale funnel --bg "${service_port}" 2>&1 || true
    
    sleep 2
    
    # Mostra URL
    cmd_url
    
    log_success "Setup completato!"
}

cmd_stop() {
    init_dirs
    
    if ! is_container_running; then
        log_warn "Container non in esecuzione"
        return 0
    fi
    
    log_info "Arresto container..."
    docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    log_success "Container arrestato"
}

cmd_restart() {
    cmd_stop
    sleep 2
    cmd_start "$@"
}

cmd_status() {
    init_dirs
    
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    TAILSCALE FUNNEL STANDALONE         ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo ""
    
    # Container
    echo -e "${BLUE}┌── Container ─────────────────────────┐${NC}"
    if is_container_running; then
        echo -e "│ Stato: ${GREEN}✅ IN ESECUZIONE${NC}"
        docker ps --filter "name=${CONTAINER_NAME}" --format "table │ {{.Names}}\t{{.Status}}" | tail -1
    else
        echo -e "│ Stato: ${RED}❌ FERMO${NC}"
    fi
    echo -e "${BLUE}└──────────────────────────────────────┘${NC}"
    echo ""
    
    # Tailscale
    echo -e "${BLUE}┌── Tailscale ─────────────────────────┐${NC}"
    if is_container_running; then
        local status
        status=$(docker exec "${CONTAINER_NAME}" tailscale status 2>&1 || true)
        
        if echo "$status" | grep -q "^[0-9]"; then
            echo -e "│ Stato: ${GREEN}✅ CONNESSO${NC}"
            
            local hostname
            hostname=$(docker exec "${CONTAINER_NAME}" tailscale status --json 2>/dev/null | \
                grep -o '"DNSName"[^,]*' | head -1 | cut -d'"' -f4 | sed 's/\.$//' || true)
            if [[ -n "$hostname" ]]; then
                echo -e "│ Hostname: ${BLUE}${hostname}${NC}"
            fi
        else
            echo -e "│ Stato: ${YELLOW}⚠️ NON AUTENTICATO${NC}"
        fi
        
        # Funnel
        local funnel_status
        funnel_status=$(docker exec "${CONTAINER_NAME}" tailscale funnel status 2>&1 || true)
        if echo "$funnel_status" | grep -qE "(Funnel on|Available on the internet)"; then
            echo -e "│ Funnel: ${GREEN}✅ ABILITATO${NC}"
        else
            echo -e "│ Funnel: ${YELLOW}⚠️ NON ABILITATO${NC}"
        fi
    else
        echo -e "│ Stato: ${RED}❌ NON DISPONIBILE${NC}"
    fi
    echo -e "${BLUE}└──────────────────────────────────────┘${NC}"
    echo ""
    
    # Servizi
    echo -e "${BLUE}┌── Servizi ───────────────────────────┐${NC}"
    if is_container_running; then
        docker exec "${CONTAINER_NAME}" tailscale serve status 2>&1 | while read -r line; do
            echo -e "│ ${line}"
        done
    else
        echo -e "│ ${RED}Container non in esecuzione${NC}"
    fi
    echo -e "${BLUE}└──────────────────────────────────────┘${NC}"
}

cmd_add() {
    init_dirs
    
    local name="${1:-}"
    local port="${2:-}"
    local path="${3:-/${name}}"
    
    if [[ -z "$name" || -z "$port" ]]; then
        log_error "Uso: $0 add <name> <port> [path]"
        exit 1
    fi
    
    if ! is_container_running; then
        log_error "Container non in esecuzione!"
        exit 1
    fi
    
    log_info "Aggiunta servizio: ${name} → porta ${port}"
    
    docker exec "${CONTAINER_NAME}" tailscale serve --bg --set-path "${path}" "${port}" 2>&1 || {
        log_error "Configurazione fallita"
        exit 1
    }
    
    docker exec "${CONTAINER_NAME}" tailscale funnel --bg "${port}" 2>&1 || log_warn "Funnel potrebbe già essere attivo"
    
    log_success "Servizio aggiunto!"
    cmd_url
}

cmd_remove() {
    init_dirs
    
    local name="${1:-}"
    
    if [[ -z "$name" ]]; then
        log_error "Uso: $0 remove <name>"
        exit 1
    fi
    
    if ! is_container_running; then
        log_error "Container non in esecuzione!"
        exit 1
    fi
    
    log_warn "⚠️  Questo rimuoverà TUTTA la configurazione serve"
    read -rp "Sei sicuro? (y/N): " confirm
    
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        docker exec "${CONTAINER_NAME}" tailscale serve reset 2>/dev/null || true
        log_success "Servizi rimossi"
    else
        log_info "Operazione annullata"
    fi
}

cmd_url() {
    init_dirs
    
    if ! is_container_running; then
        log_error "Container non in esecuzione!"
        exit 1
    fi
    
    echo -e "${CYAN}=== Magic URL ===${NC}"
    
    local hostname
    hostname=$(docker exec "${CONTAINER_NAME}" tailscale status --json 2>/dev/null | \
        grep -o '"DNSName"[^,]*' | head -1 | cut -d'"' -f4 | sed 's/\.$//' || true)
    
    if [[ -n "$hostname" ]]; then
        echo -e "${GREEN}https://${hostname}/${NC}"
        
        # Test connettività
        if curl -s --max-time 5 "https://${hostname}/" &>/dev/null; then
            echo -e "Status: ${GREEN}✅ RAGGIUNGIBILE${NC}"
        else
            echo -e "Status: ${YELLOW}⚠️ Verifica manuale${NC}"
        fi
    else
        log_error "Impossibile ottenere hostname"
    fi
}

cmd_cleanup() {
    init_dirs
    cleanup_duplicate_nodes_api
}

cmd_shell() {
    init_dirs
    
    if ! is_container_running; then
        log_error "Container non in esecuzione!"
        exit 1
    fi
    
    log_info "Accesso alla shell..."
    docker exec -it "${CONTAINER_NAME}" /bin/sh
}

show_help() {
    cat << EOF
Tailscale Funnel Standalone

Gestione indipendente del sidecar Tailscale con API per evitare nodi duplicati.

COMANDI:
    start [name] [port]     Avvia container e configura funnel
    stop                    Ferma container
    restart [name] [port]   Riavvia container
    status                  Mostra stato
    add <name> <port> [path] Aggiungi servizio
    remove <name>           Rimuovi servizi
    url                     Mostra Magic URL
    cleanup                 Elimina nodi duplicati via API
    shell                   Accedi alla shell del container
    help                    Mostra questo aiuto

VARIABILI D'AMBIENTE:
    TS_AUTHKEY      Chiave di autenticazione (obbligatoria)
    TS_API_KEY      API key per gestione nodi (opzionale)
    TS_TAILNET      Nome tailnet (opzionale, auto-rilevato)
    TS_HOSTNAME     Hostname del nodo (default: tailscale-funnel)
    TS_CONTAINER_NAME  Nome container (default: tailscale-funnel)

ESEMPI:
    # Avvio con servizio default
    $0 start

    # Avvio con servizio personalizzato
    $0 start grafana 3000

    # Aggiungi altro servizio
    $0 add homeassistant 8123 /ha

    # Pulisci nodi duplicati
    $0 cleanup

    # Mostra stato
    $0 status

CONFIGURAZIONE:
    Modifica ${ENV_FILE} per impostare:
    - TS_AUTHKEY: da https://login.tailscale.com/admin/settings/keys
    - TS_API_KEY: da https://login.tailscale.com/admin/settings/api

EOF
}

# ============================================
# MAIN
# ============================================

case "${1:-help}" in
    start)      cmd_start "${2:-funnel}" "${3:-18789}" ;;
    stop)       cmd_stop ;;
    restart)    cmd_restart "${2:-funnel}" "${3:-18789}" ;;
    status|st)  cmd_status ;;
    add)        cmd_add "$2" "$3" "$4" ;;
    remove|rm)  cmd_remove "$2" ;;
    url)        cmd_url ;;
    cleanup)    cmd_cleanup ;;
    shell|sh)   cmd_shell ;;
    help|--help|-h) show_help ;;
    *)
        log_error "Comando sconosciuto: $1"
        show_help
        exit 1
        ;;
esac
