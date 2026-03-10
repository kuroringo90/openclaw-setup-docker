#!/bin/bash
#
# OpenClaw Docker Manager con Tailscale Integration
# https://github.com/openclaw/openclaw
#
# COMANDI EXTRA: tailscale-start, tailscale-config, tunnel-url, full-reset, status-full
#

set -euo pipefail

# ============================================
# CONFIGURAZIONE
# ============================================
CONTAINER_NAME="openclaw"
IMAGE_NAME="ghcr.io/openclaw/openclaw:latest"
DATA_DIR="${HOME}/.openclaw"
COMPOSE_FILE="${DATA_DIR}/docker-compose.yml"
ENV_FILE="${DATA_DIR}/.env"
TAILSCALE_CONTAINER="openclaw-tailscale"
TAILSCALE_HOSTNAME="steagent"

# Colori per output
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

check_prereqs() {
    log_info "Verifica prerequisiti..."

    if ! command -v docker &> /dev/null; then
        log_error "Docker non trovato! Installa con: sudo pacman -S docker"
        exit 1
    fi

    if ! docker info &> /dev/null; then
        log_error "Docker non è in esecuzione! Avvia con: sudo systemctl start docker"
        exit 1
    fi

    log_success "Prerequisiti OK"
}

# ============================================
# GESTIONE NODI DUPLICATI VIA API
# ============================================

cleanup_duplicate_nodes_api() {
    local hostname="${TAILSCALE_HOSTNAME:-openclaw}"
    
    # Carica API key da .env
    local api_key=""
    local tailnet=""
    
    if [[ -f "${ENV_FILE}" ]]; then
        api_key=$(grep -E "^TS_API_KEY=" "${ENV_FILE}" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || true)
        tailnet=$(grep -E "^TS_TAILNET=" "${ENV_FILE}" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || true)
    fi
    
    # Se non in .env, prova da ambiente
    api_key="${api_key:-${TS_API_KEY:-}}"
    tailnet="${tailnet:-${TS_TAILNET:-}}"
    
    if [[ -z "$api_key" ]]; then
        log_warn "TS_API_KEY non configurata: skip cleanup nodi duplicati"
        log_info "Aggiungi TS_API_KEY in ${ENV_FILE}"
        return 0
    fi
    
    if [[ -z "$tailnet" ]]; then
        log_warn "TS_TAILNET non configurata: skip cleanup nodi duplicati"
        log_info "Aggiungi TS_TAILNET in ${ENV_FILE}"
        return 0
    fi
    
    log_info "Verifica nodi duplicati per hostname: ${hostname}..."
    
    # Chiama API Tailscale per lista dispositivi
    local devices
    devices=$(curl -s -X GET \
        -u "${api_key}:" \
        "https://api.tailscale.com/api/v2/tailnet/${tailnet}/devices" \
        -H "Accept: application/json" \
        2>/dev/null || echo "")
    
    # Verifica risposta API
    if [[ -z "$devices" ]]; then
        log_warn "API: nessuna risposta"
        return 0
    fi
    
    if echo "$devices" | grep -q "not found"; then
        log_warn "API: tailnet '${tailnet}' non trovata"
        log_info "Verifica TS_TAILNET su https://login.tailscale.com/admin/settings/dns"
        return 0
    fi
    
    if echo "$devices" | grep -q "unauthorized"; then
        log_warn "API: non autorizzato"
        log_info "Verifica TS_API_KEY su https://login.tailscale.com/admin/settings/api"
        return 0
    fi
    
    # Trova nodi con hostname che inizia con TAILSCALE_HOSTNAME
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
                'id': device.get('id', ''),  # ID dispositivo (UUID)
                'nodeId': device.get('nodeId', ''),  # Node ID
                'name': name,
                'lastSeen': device.get('lastSeen', '')
            })
    # Ordina per lastSeen (più recente primo)
    nodes.sort(key=lambda x: x['lastSeen'] or '', reverse=True)
    for node in nodes:
        print(f\"{node['id']}|{node['nodeId']}|{node['name']}|{node['lastSeen'] or 'never'}\")
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" 2>&1)
    
    if [[ -z "$matching_nodes" ]] || echo "$matching_nodes" | grep -q "^ERROR:"; then
        log_warn "API: errore parsing risposta"
        return 0
    fi
    
    local node_count
    node_count=$(echo "$matching_nodes" | wc -l)
    
    if [[ $node_count -le 1 ]]; then
        log_success "Nessun nodo duplicato trovato"
        return 0
    fi
    
    log_warn "Trovati ${node_count} nodi con hostname '${hostname}':"
    echo "$matching_nodes" | while IFS='|' read -r id nodeid name lastseen; do
        echo "  - ${name} (last: ${lastseen})"
    done
    
    # Mantieni solo il più recente, elimina gli altri
    local first=true
    echo "$matching_nodes" | while IFS='|' read -r id nodeid name lastseen; do
        if [[ "$first" == true ]]; then
            first=false
            log_info "Mantengo nodo: ${name}"
        else
            log_info "Elimino nodo duplicato: ${name}..."
            
            # Usa l'ID dispositivo (UUID) per l'eliminazione
            local delete_response
            delete_response=$(curl -s -X DELETE \
                -u "${api_key}:" \
                "https://api.tailscale.com/api/v2/device/${id}" \
                -H "Accept: application/json" \
                2>/dev/null || echo "ERROR")
            
            if [[ "$delete_response" == "ERROR" ]] || [[ -n "$delete_response" && "$delete_response" != "{}" && ! "$delete_response" =~ "message.*deleted" ]]; then
                log_warn "Eliminazione fallita: ${delete_response}"
            else
                log_success "Eliminato: ${name}"
            fi
        fi
    done
    
    log_success "Cleanup completato!"
}

# ============================================
# ALTERNATIVA: CLEANUP VIA CLI (senza API)
# ============================================

cleanup_duplicate_nodes_cli() {
    local hostname="${TAILSCALE_HOSTNAME:-openclaw}"
    
    if ! is_container_running "${TAILSCALE_CONTAINER}"; then
        return 0
    fi
    
    log_info "Verifica nodi duplicati via CLI..."
    
    # Ottieni lista nodi da tailscale status
    local status_output
    status_output=$(docker exec "${TAILSCALE_CONTAINER}" tailscale status --json 2>/dev/null || true)
    
    if [[ -z "$status_output" ]]; then
        return 0
    fi
    
    # Conta nodi con hostname che corrisponde
    local node_count
    node_count=$(echo "$status_output" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    count = 0
    # Conta Self
    if 'Self' in data:
        name = data['Self'].get('HostName', '')
        if name.startswith('$hostname'):
            count += 1
    # Conta Peer
    for peer_id, peer in data.get('Peer', {}).items():
        name = peer.get('HostName', '')
        if name.startswith('$hostname'):
            count += 1
    print(count)
except:
    print('0')
" 2>/dev/null || echo "0")
    
    if [[ "$node_count" -le 1 ]]; then
        log_success "Nessun nodo duplicato rilevato via CLI"
        return 0
    fi
    
    log_warn "Trovati ${node_count} nodi con hostname '${hostname}'"
    log_info "Per pulire, usa Tailscale API o elimina manualmente da:"
    log_info "  https://login.tailscale.com/admin/machines"
    
    return 0
}

check_image() {
    if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${IMAGE_NAME}$"; then
        log_error "Immagine ${IMAGE_NAME} non trovata localmente!"
        log_info "Scaricala manualmente con: docker pull ${IMAGE_NAME}"
        exit 1
    fi
    log_success "Immagine locale trovata"
}

get_ts_authkey() {
    local authkey=""

    # 1. Prova da variabile d'ambiente
    if [[ -n "${TS_AUTHKEY:-}" ]]; then
        authkey="${TS_AUTHKEY}"
        log_info "TS_AUTHKEY trovata in ambiente"
    # 2. Prova da file .env
    elif [[ -f "${ENV_FILE}" ]]; then
        authkey=$(grep -E "^TS_AUTHKEY=" "${ENV_FILE}" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || true)
        if [[ -n "$authkey" ]]; then
            log_info "TS_AUTHKEY trovata in ${ENV_FILE}"
        fi
    fi

    # 3. Chiedi all'utente se non trovata
    if [[ -z "$authkey" ]]; then
        echo -e "${YELLOW}⚠️  TS_AUTHKEY non trovata${NC}"
        echo "Ottienila da: https://login.tailscale.com/admin/settings/keys"
        echo ""
        read -rp "Incolla TS_AUTHKEY (o premi INVIO per saltare Tailscale): " authkey
        if [[ -n "$authkey" ]]; then
            # Salva nel file .env
            mkdir -p "${DATA_DIR}"
            echo "TS_AUTHKEY=${authkey}" > "${ENV_FILE}"
            log_success "TS_AUTHKEY salvata in ${ENV_FILE}"
        fi
    fi

    echo "$authkey"
}

init_setup() {
    log_info "Inizializzazione setup..."

    mkdir -p "${DATA_DIR}/data"

    # Fix permessi: container usa UID 1000 (utente node)
    local uid=$(id -u)
    if [[ "$uid" != "1000" ]]; then
        log_warn "Il tuo UID è $uid, ma il container usa UID 1000"
        log_warn "Potresti avere problemi di permessi"
        log_warn "Soluzione: sudo chown -R 1000:1000 ${DATA_DIR}/data"
    fi

    # Genera docker-compose.yml
    cat > "${COMPOSE_FILE}" << EOF
services:
  openclaw:
    image: \${IMAGENAME}
    container_name: openclaw
    restart: unless-stopped
    network_mode: host
    volumes:
      - ~/.openclaw/data:/home/node/.openclaw
    environment:
      - NODE_ENV=production
    stdin_open: true
    tty: true
EOF
    log_success "Creato docker-compose.yml"

    # Genera .env se non esiste
    if [[ ! -f "${ENV_FILE}" ]]; then
        cat > "${ENV_FILE}" << 'EOF'
# Tailscale Authentication Key
# Ottieni da: https://login.tailscale.com/admin/settings/keys
TS_AUTHKEY=
EOF
        log_success "Creato ${ENV_FILE}"
    fi

    log_success "Setup completato"
}

is_openclaw_running() {
    docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

is_tailscale_running() {
    docker ps --format '{{.Names}}' | grep -q "^${TAILSCALE_CONTAINER}$"
}

check_openclaw_health() {
    if curl -s --max-time 2 http://127.0.0.1:18789 &> /dev/null; then
        return 0
    fi
    return 1
}

check_tailscale_status() {
    if is_tailscale_running; then
        if docker exec "${TAILSCALE_CONTAINER}" tailscale status &> /dev/null; then
            return 0
        fi
    fi
    return 1
}

get_magic_url() {
    if ! is_tailscale_running; then
        echo ""
        return
    fi

    local status_output
    status_output=$(docker exec "${TAILSCALE_CONTAINER}" tailscale status --json 2>/dev/null || true)

    if [[ -z "$status_output" ]]; then
        echo ""
        return
    fi

    # Estrai DNSName (già completo, es: ste-b550gamingxv2.tail5d495.ts.net.)
    local dnsname
    dnsname=$(echo "$status_output" | grep -o '"DNSName"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//' || true)

    if [[ -n "$dnsname" ]]; then
        echo "https://${dnsname}/"
    else
        # Fallback: usa hostname + tailnet.ts.net
        local hostname
        hostname=$(echo "$status_output" | grep -o '"Hostname"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || true)
        if [[ -n "$hostname" ]]; then
            echo "https://${hostname}.tailnet.ts.net/"
        else
            echo ""
        fi
    fi
}

# ============================================
# CONFIGURAZIONE OPENCLAW PER TAILSCALE
# ============================================

cleanup_duplicate_nodes() {
    # Pulisce i nodi Tailscale duplicati con lo stesso hostname
    if ! is_tailscale_running; then
        return 0
    fi

    log_info "Verifica nodi Tailscale duplicati..."

    # Ottieni lista nodi con hostname che iniziano con TAILSCALE_HOSTNAME
    local nodes
    nodes=$(docker exec "${TAILSCALE_CONTAINER}" tailscale status --json 2>/dev/null || true)

    if [[ -z "$nodes" ]]; then
        return 0
    fi

    # Conta quanti nodi hanno l'hostname configurato
    local node_count
    node_count=$(echo "$nodes" | grep -o "\"Hostname\"[[:space:]]*:[[:space:]]*\"${TAILSCALE_HOSTNAME}[^\"]*\"" | wc -l)

    if [[ $node_count -gt 1 ]]; then
        log_warn "Trovati $node_count nodi con hostname '${TAILSCALE_HOSTNAME}'"
        log_info "Per pulire, elimina i nodi offline da:"
        log_info "  https://login.tailscale.com/admin/machines"
    fi
}

apply_openclaw_tailscale_config() {
    local config_file="${DATA_DIR}/data/openclaw.json"

    # Solo se il file esiste già (configurazione persistente)
    if [[ ! -f "${config_file}" ]]; then
        return 0
    fi

    log_info "Verifica configurazione OpenClaw per Tailscale..."

    # Ottieni il tailnet domain da Tailscale se disponibile
    local tailnet_domain="tailnet.ts.net"
    if is_tailscale_running; then
        local ts_status
        ts_status=$(docker exec "${TAILSCALE_CONTAINER}" tailscale status --json 2>/dev/null || true)
        if [[ -n "$ts_status" ]]; then
            local dnsname
            dnsname=$(echo "$ts_status" | grep -o '"DNSName"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//' || true)
            if [[ -n "$dnsname" ]]; then
                # Estrai il dominio (tutto dopo il primo punto)
                tailnet_domain=$(echo "$dnsname" | cut -d'.' -f2-)
            fi
        fi
    fi

    # Usa Python per modificare il JSON in modo sicuro
    python3 << PYEOF
import json
import sys

config_file = "${config_file}"
hostname = "${TAILSCALE_HOSTNAME}"
tailnet_domain = "${tailnet_domain}"

try:
    with open(config_file, 'r') as f:
        config = json.load(f)

    modified = False

    # Aggiungi trustedProxies se manca
    if 'trustedProxies' not in config.get('gateway', {}):
        config.setdefault('gateway', {})['trustedProxies'] = ['0.0.0.0/0', '127.0.0.1/8']
        modified = True
        print("  + aggiunto trustedProxies")

    # Aggiungi controlUi.allowedOrigins se manca
    if 'controlUi' not in config.get('gateway', {}):
        config.setdefault('gateway', {}).setdefault('controlUi', {})['allowedOrigins'] = [
            'http://127.0.0.1:18789'
        ]
        modified = True
        print("  + aggiunto controlUi.allowedOrigins")
    else:
        # Aggiungi hostname Tailscale se manca
        origins = config['gateway']['controlUi'].get('allowedOrigins', [])
        tailscale_origin = f"https://{hostname}.{tailnet_domain}"
        if not any(hostname in o for o in origins):
            config['gateway']['controlUi']['allowedOrigins'].append(tailscale_origin)
            modified = True
            print(f"  + aggiunto {tailscale_origin} a allowedOrigins")

    if modified:
        with open(config_file, 'w') as f:
            json.dump(config, f, indent=2)
        print("  Configurazione aggiornata!")
    else:
        print("  Configurazione OK")

except Exception as e:
    print(f"  Errore: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ============================================
# COMANDI OPENCLAW
# ============================================

cmd_start() {
    check_prereqs
    check_image
    init_setup

    local first_run=false
    if ! is_openclaw_running; then
        first_run=true
    fi

    if is_openclaw_running; then
        log_warn "OpenClaw è già in esecuzione"
    else
        log_info "Avvio OpenClaw..."
        cd "${DATA_DIR}"
        export IMAGENAME="${IMAGE_NAME}"
        docker-compose up -d

        sleep 3
        if is_openclaw_running; then
            log_success "OpenClaw avviato!"
        else
            log_error "Avvio fallito!"
            exit 1
        fi
    fi

    # Applica configurazione OpenClaw per Tailscale (se necessario)
    apply_openclaw_tailscale_config

    # AVVIO TAILSCALE: Sempre (non solo al primo avvio)
    # La configurazione serve/funnel va riapplicata ad ogni avvio sidecar
    log_info "Verifica Tailscale sidecar..."
    
    if is_tailscale_running; then
        log_success "Tailscale sidecar già attivo"
    else
        # Tailscale non attivo: avvia se abbiamo authkey
        local authkey=""
        
        # Cerca authkey salvata
        if [[ -f "${ENV_FILE}" ]]; then
            authkey=$(grep -E "^TS_AUTHKEY=" "${ENV_FILE}" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || true)
        fi
        
        if [[ -n "$authkey" ]]; then
            log_info "Avvio Tailscale sidecar..."
            cmd_tailscale_start "$authkey"

            # Attendi autenticazione e configura serve/funnel
            sleep 3
            log_info "Configurazione Tailscale..."
            docker exec "${TAILSCALE_CONTAINER}" tailscale serve --bg 18789 >/dev/null 2>&1 || true
            docker exec "${TAILSCALE_CONTAINER}" tailscale funnel --bg 18789 >/dev/null 2>&1 || true

            # Verifica nodi duplicati
            cleanup_duplicate_nodes

            # Solo al primo avvio: mostra cerimonia Magic URL
            if [[ "$first_run" == true ]]; then
                sleep 2
                echo ""
                log_success "Configurazione completata!"
                echo -e "${CYAN}════════════════════════════════════════${NC}"
                echo -e "${GREEN}🎉 MAGIC URL:${NC}"
                local magic_url
                magic_url=$(get_magic_url)
                if [[ -n "$magic_url" ]]; then
                    echo -e "${BLUE}${magic_url}${NC}"
                else
                    echo -e "${YELLOW}URL in generazione, usa: ./openclaw-manager-tailscale.sh tunnel-url${NC}"
                fi
                echo -e "${CYAN}════════════════════════════════════════${NC}"
            fi
        else
            log_info "Nessuna TS_AUTHKEY: Tailscale non avviato"
            log_info "Per abilitare: ./openclaw-manager-tailscale.sh tailscale-start"
        fi
    fi

    # Mostra Magic URL se Tailscale è attivo (sempre)
    sleep 2
    if is_tailscale_running; then
        echo ""
        local magic_url
        magic_url=$(get_magic_url)
        if [[ -n "$magic_url" ]]; then
            echo -e "${GREEN}🌐 Magic URL: ${BLUE}${magic_url}${NC}"
        fi
    fi

    echo ""
    echo -e "${CYAN}Comandi:${NC}"
    echo "  ./openclaw-manager-tailscale.sh shell   # Entra nel container"
    echo "  ./openclaw-manager-tailscale.sh logs    # Vedi log"
    echo "  ./openclaw-manager-tailscale.sh status-full  # Stato completo"
}

cmd_stop() {
    check_prereqs

    # Ferma prima Tailscale (dipende da OpenClaw)
    if is_tailscale_running; then
        log_info "Arresto Tailscale sidecar..."
        docker rm -f "${TAILSCALE_CONTAINER}" >/dev/null 2>&1 || true
        log_success "Tailscale arrestato"
    fi

    if ! is_openclaw_running; then
        log_warn "OpenClaw non è in esecuzione"
        return 0
    fi

    log_info "Arresto OpenClaw..."
    cd "${DATA_DIR}" 2>/dev/null || true
    docker-compose down 2>/dev/null || docker stop "${CONTAINER_NAME}"
    log_success "OpenClaw arrestato"
}

cmd_restart() {
    log_info "Riavvio OpenClaw + Tailscale..."
    
    # Ferma Tailscale prima (dipende da OpenClaw)
    if is_tailscale_running; then
        docker rm -f "${TAILSCALE_CONTAINER}" >/dev/null 2>&1 || true
    fi
    
    # Ferma OpenClaw
    if is_openclaw_running; then
        cd "${DATA_DIR}" 2>/dev/null || true
        docker-compose down >/dev/null 2>&1 || docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    fi
    
    # Rimuove container OpenClaw
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    
    sleep 2
    
    # Riavvia tutto
    cmd_start
}

cmd_shell() {
    check_prereqs

    if ! is_openclaw_running; then
        log_error "OpenClaw non è in esecuzione! Avvia prima con: ./openclaw-manager-tailscale.sh start"
        exit 1
    fi

    log_info "Accesso alla shell..."
    echo -e "${CYAN}Comandi utili:${NC}"
    echo "  openclaw onboard       # Configurazione guidata"
    echo "  openclaw --help        # Aiuto"
    echo "  openclaw skills list   # Lista skills"
    echo "  exit                   # Uscire"
    echo ""
    docker exec -it "${CONTAINER_NAME}" /bin/sh
}

cmd_logs() {
    check_prereqs
    docker logs -f --tail 50 "${CONTAINER_NAME}" 2>/dev/null || log_error "Container non trovato"
}

cmd_status() {
    check_prereqs

    echo -e "${CYAN}=== Stato OpenClaw ===${NC}"

    if is_openclaw_running; then
        echo -e "Stato: ${GREEN}IN ESECUZIONE${NC}"
        docker ps --filter "name=${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}"
        
        # Health check
        if check_openclaw_health; then
            echo -e "Health: ${GREEN}OK (18789)${NC}"
        else
            echo -e "Health: ${YELLOW}NON RAGGIUNGIBILE${NC}"
        fi
    else
        echo -e "Stato: ${YELLOW}FERMO${NC}"
    fi

    echo ""
    echo -e "${CYAN}=== Dati ===${NC}"
    if [[ -d "${DATA_DIR}/data" ]]; then
        du -sh "${DATA_DIR}/data" 2>/dev/null | awk '{print "Dimensione: " $1}'
        ls -la "${DATA_DIR}/data/" 2>/dev/null | head -5
    else
        echo "Nessun dato"
    fi
}

cmd_backup() {
    check_prereqs

    local backup_dir="${HOME}/openclaw-backups"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${backup_dir}/openclaw_${timestamp}.tar.gz"

    mkdir -p "${backup_dir}"

    log_info "Backup in corso..."

    local was_running=false
    if is_openclaw_running; then
        was_running=true
        cmd_stop
    fi

    if [[ -d "${DATA_DIR}/data" ]]; then
        tar -czf "${backup_file}" -C "${DATA_DIR}" data
        log_success "Backup creato: ${backup_file}"
    else
        log_warn "Nessun dato da backuppare"
    fi

    if [[ "$was_running" == true ]]; then
        cmd_start
    fi
}

cmd_reset() {
    log_warn "⚠️  QUESTO ELIMINERÀ TUTTO:"
    log_warn "   - Container OpenClaw"
    log_warn "   - Tutti i dati in ~/.openclaw/data"
    log_warn "   - Configurazioni e API keys"
    echo ""
    read -rp "Scrivi 'ELIMINA' per confermare: " confirm

    if [[ "$confirm" == "ELIMINA" ]]; then
        log_info "Eliminazione in corso..."

        # Ferma e rimuovi container
        docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

        # Elimina dati
        if [[ -d "${DATA_DIR}" ]]; then
            rm -rf "${DATA_DIR}"
            log_success "Dati eliminati"
        fi

        log_success "Reset completato!"
        log_info "Per ricominciare: ./openclaw-manager-tailscale.sh start"
    else
        log_info "Reset annullato"
    fi
}

cmd_update() {
    log_info "Aggiornamento immagine..."
    docker pull "${IMAGE_NAME}"

    local was_running=false
    if is_openclaw_running; then
        was_running=true
        cmd_stop
    fi

    if [[ "$was_running" == true ]]; then
        cmd_start
    fi

    log_success "Aggiornamento completato"
}

# ============================================
# COMANDI TAILSCALE
# ============================================

cmd_tailscale_start() {
    local authkey="${1:-}"

    check_prereqs

    # ELIMINA NODI DUPLICATI PRIMA DI AVVIARE
    cleanup_duplicate_nodes_api

    # Cleanup container esistente (anche se fermo)
    if docker ps -a --format '{{.Names}}' | grep -q "^${TAILSCALE_CONTAINER}$"; then
        log_info "Rimozione container Tailscale esistente..."
        docker rm -f "${TAILSCALE_CONTAINER}" >/dev/null 2>&1 || true
        sleep 1
    fi

    if ! is_openclaw_running; then
        log_error "OpenClaw deve essere in esecuzione prima di avviare Tailscale!"
        log_info "Usa: ./openclaw-manager-tailscale.sh start"
        exit 1
    fi

    # Ottieni authkey se non fornita
    if [[ -z "$authkey" ]]; then
        authkey=$(get_ts_authkey)
    fi

    if [[ -z "$authkey" ]]; then
        log_error "TS_AUTHKEY richiesta!"
        exit 1
    fi

    log_info "Avvio Tailscale sidecar..."

    # Crea sidecar con --network container:openclaw
    # Usa userspace-networking perché condivide il network con openclaw
    # Hostname fisso per mantenere lo stesso nome nodo
    # Restart policy per riavvio automatico dopo reboot host
    local run_output
    if ! run_output=$(docker run -d \
        --name "${TAILSCALE_CONTAINER}" \
        --restart unless-stopped \
        --network container:"${CONTAINER_NAME}" \
        -e TS_AUTHKEY="${authkey}" \
        tailscale/tailscale:latest \
        tailscaled --tun=userspace-networking 2>&1); then
        log_error "Docker run fallito: ${run_output}"
        exit 1
    fi

    sleep 3

    if is_tailscale_running; then
        log_success "Tailscale sidecar avviato!"
        # Autenticazione esplicita con authkey e hostname fisso
        # --force-reauth sovrascrive il nodo esistente con lo stesso hostname
        log_info "Autenticazione in corso..."
        docker exec "${TAILSCALE_CONTAINER}" tailscale up --authkey="${authkey}" --timeout=30s --hostname="${TAILSCALE_HOSTNAME}" --force-reauth 2>&1 || log_warn "Autenticazione fallita, verifica la authkey"
    else
        log_error "Avvio Tailscale fallito!"
        log_info "Controlla i log: docker logs ${TAILSCALE_CONTAINER}"
        exit 1
    fi
}

cmd_tailscale_config() {
    check_prereqs

    if ! is_tailscale_running; then
        log_error "Tailscale sidecar non in esecuzione!"
        log_info "Usa: ./openclaw-manager-tailscale.sh tailscale-start"
        exit 1
    fi

    log_info "Configurazione Tailscale serve + funnel..."

    # Attendi che Tailscale sia pronto
    local retries=10
    local count=0
    while ! docker exec "${TAILSCALE_CONTAINER}" tailscale status &> /dev/null; do
        count=$((count + 1))
        if [[ $count -ge $retries ]]; then
            log_error "Tailscale non risponde"
            exit 1
        fi
        sleep 2
    done

    # Verifica se Tailscale è autenticato
    if ! docker exec "${TAILSCALE_CONTAINER}" tailscale status 2>&1 | grep -q "^[0-9]"; then
        log_error "Tailscale non autenticato"
        log_info "Rilancia: ./openclaw-manager-tailscale.sh tailscale-start"
        exit 1
    fi

    # Configura serve per esporre OpenClaw (porta 18789)
    log_info "Configura serve: porta 18789"
    docker exec "${TAILSCALE_CONTAINER}" tailscale serve --bg 18789 2>&1 || {
        log_warn "Serve non abilitato sulla tua tailnet"
        log_info "Abilitalo su: https://login.tailscale.com/admin/settings/serve"
    }

    # Configura funnel per accesso pubblico (internet, non solo tailnet)
    log_info "Configura funnel: 18789 (accesso pubblico)"
    docker exec "${TAILSCALE_CONTAINER}" tailscale funnel --bg 18789 2>&1 || log_warn "Funnel non disponibile"

    sleep 2

    log_success "Configurazione completata!"
}

cmd_tunnel_url() {
    check_prereqs

    if ! is_tailscale_running; then
        log_error "Tailscale sidecar non in esecuzione!"
        exit 1
    fi

    echo -e "${CYAN}=== Magic URL ===${NC}"

    local magic_url
    magic_url=$(get_magic_url)

    if [[ -n "$magic_url" ]]; then
        echo -e "${GREEN}${magic_url}${NC}"
        echo ""
        echo -e "${CYAN}Health check:${NC}"
        if curl -s --max-time 5 "$magic_url" &> /dev/null; then
            echo -e "Tunnel: ${GREEN}OK${NC}"
        else
            echo -e "Tunnel: ${YELLOW}Verifica manuale${NC}"
        fi
    else
        log_error "Impossibile ottenere Magic URL"
        log_info "Verifica con: docker exec ${TAILSCALE_CONTAINER} tailscale status"
        exit 1
    fi
}

cmd_devices() {
    check_prereqs

    if ! is_openclaw_running; then
        log_error "OpenClaw non in esecuzione!"
        exit 1
    fi

    case "${2:-list}" in
        list)
            log_info "Dispositivi in attesa di approvazione..."
            docker exec "${CONTAINER_NAME}" openclaw devices list
            ;;
        approve)
            if [[ -z "${3:-}" ]]; then
                log_error "Specifica l'ID richiesta: ./openclaw-manager-tailscale.sh devices approve <requestId>"
                exit 1
            fi
            log_info "Approvo dispositivo $3..."
            docker exec "${CONTAINER_NAME}" openclaw devices approve "$3"
            log_success "Dispositivo approvato!"
            ;;
        *)
            log_error "Uso: ./openclaw-manager-tailscale.sh devices [list|approve <id>]"
            exit 1
            ;;
    esac
}

cmd_status_full() {
    check_prereqs

    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       STATO COMPLETO OPENCLAW          ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo ""

    # OpenClaw
    echo -e "${BLUE}┌── OpenClaw ──────────────────────────┐${NC}"
    if is_openclaw_running; then
        echo -e "│ Stato:    ${GREEN}✅ IN ESECUZIONE${NC}"
        if check_openclaw_health; then
            echo -e "│ Health:   ${GREEN}✅ OK (18789)${NC}"
        else
            echo -e "│ Health:   ${YELLOW}⚠️ NON RAGGIUNGIBILE${NC}"
        fi
    else
        echo -e "│ Stato:    ${RED}❌ FERMO${NC}"
        echo -e "│ Health:   ${RED}❌ N/A${NC}"
    fi
    echo -e "${BLUE}└──────────────────────────────────────┘${NC}"
    echo ""

    # Tailscale
    echo -e "${BLUE}┌── Tailscale ─────────────────────────┐${NC}"
    if is_tailscale_running; then
        echo -e "│ Sidecar:  ${GREEN}✅ ATTIVO${NC}"
        if check_tailscale_status; then
            echo -e "│ Status:   ${GREEN}✅ CONNESSO${NC}"
        else
            echo -e "│ Status:   ${YELLOW}⚠️ IN ATTESA${NC}"
        fi
    else
        echo -e "│ Sidecar:  ${RED}❌ NON ATTIVO${NC}"
        echo -e "│ Status:   ${RED}❌ N/A${NC}"
    fi
    echo -e "${BLUE}└──────────────────────────────────────┘${NC}"
    echo ""

    # Tunnel
    echo -e "${BLUE}┌── Tunnel ────────────────────────────┐${NC}"
    if is_tailscale_running; then
        local magic_url
        magic_url=$(get_magic_url)
        if [[ -n "$magic_url" ]]; then
            echo -e "│ URL:      ${GREEN}${magic_url}${NC}"
            if curl -s --max-time 5 "$magic_url" &> /dev/null; then
                echo -e "│ Reach:    ${GREEN}✅ RAGGIUNGIBILE${NC}"
            else
                echo -e "│ Reach:    ${YELLOW}⚠️ VERIFICA MANUALE${NC}"
            fi
            
            # Mostra URL con token
            local auth_token=""
            local config_file="${DATA_DIR}/data/openclaw.json"
            if [[ -f "${config_file}" ]]; then
                auth_token=$(python3 -c "import json; c=json.load(open('${config_file}')); print(c.get('gateway',{}).get('auth',{}).get('token',''))" 2>/dev/null || true)
            fi
            
            if [[ -n "$auth_token" ]]; then
                echo -e "│ Token:    ${YELLOW}${auth_token}${NC}"
                echo -e "│ URL+Token: ${BLUE}${magic_url}?token=${auth_token}${NC}"
            fi
        else
            echo -e "│ URL:      ${YELLOW}⚠️ IN GENERAZIONE${NC}"
        fi
    else
        echo -e "│ Tunnel:   ${RED}❌ NON CONFIGURATO${NC}"
    fi
    echo -e "${BLUE}└──────────────────────────────────────┘${NC}"
    echo ""
}

cmd_full_reset() {
    log_warn "⚠️  QUESTO ELIMINERÀ TUTTO:"
    log_warn "   - Container OpenClaw"
    log_warn "   - Container Tailscale"
    log_warn "   - Tutti i dati in ~/.openclaw"
    log_warn "   - Configurazioni, API keys, Tailscale auth"
    echo ""
    read -rp "Scrivi 'ELIMINA' per confermare: " confirm

    if [[ "$confirm" == "ELIMINA" ]]; then
        log_info "Eliminazione in corso..."

        # Ferma container
        docker rm -f "${TAILSCALE_CONTAINER}" 2>/dev/null || true
        docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

        # Elimina dati
        if [[ -d "${DATA_DIR}" ]]; then
            rm -rf "${DATA_DIR}"
            log_success "Dati eliminati"
        fi

        log_success "Full reset completato!"
        log_info "Per ricominciare: ./openclaw-manager-tailscale.sh start"
    else
        log_info "Full reset annullato"
    fi
}

show_help() {
    cat << EOF
OpenClaw Docker Manager con Tailscale

COMANDI OPENCLAW:
    start      Avvia OpenClaw (+ auto Tailscale al primo avvio)
    stop       Ferma OpenClaw
    restart    Riavvia (rimuove e ricrea container)
    shell      Entra nella shell del container
    logs       Visualizza log
    status     Stato OpenClaw
    backup     Crea backup dei dati
    reset      ⚠️ Elimina OpenClaw + dati
    update     Aggiorna immagine Docker

COMANDI TAILSCALE:
    tailscale-start   Avvia sidecar Tailscale
    tailscale-config  Configura serve + funnel
    tunnel-url        Mostra Magic URL
    status-full       Stato completo (OpenClaw | Tailscale | Tunnel)
    full-reset        ⚠️ Elimina TUTTO (OpenClaw + Tailscale + dati)

COMANDI DISPOSITIVI:
    devices list      Lista dispositivi in attesa di approvazione
    devices approve   Approva un dispositivo (richiede requestId)

USO:
    ./openclaw-manager-tailscale.sh start
    # Primo avvio: configurazione automatica Tailscale
    # Avvio successivo: solo OpenClaw + check sidecar

    ./openclaw-manager-tailscale.sh status-full
    # Mostra stato completo con Magic URL e Token

    # Approvare nuovi dispositivi:
    ./openclaw-manager-tailscale.sh devices list
    ./openclaw-manager-tailscale.sh devices approve <requestId>

EOF
}

# ============================================
# MAIN
# ============================================

case "${1:-help}" in
    start)          cmd_start ;;
    stop)           cmd_stop ;;
    restart)        cmd_restart ;;
    shell|sh)       cmd_shell ;;
    logs|log)       cmd_logs ;;
    status|st)      cmd_status ;;
    backup|bk)      cmd_backup ;;
    reset|rm)       cmd_reset ;;
    update|up)      cmd_update ;;
    
    # Tailscale commands
    tailscale-start)    cmd_tailscale_start ;;
    tailscale-config)   cmd_tailscale_config ;;
    tunnel-url)         cmd_tunnel_url ;;
    status-full)        cmd_status_full ;;
    full-reset)         cmd_full_reset ;;

    # Device commands
    devices|dev)        cmd_devices ;;

    help|--help|-h) show_help ;;
    *)
        log_error "Comando sconosciuto: $1"
        show_help
        exit 1
        ;;
esac
