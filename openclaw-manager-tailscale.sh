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

    # PRIMO AVVIO: Auto Tailscale
    if [[ "$first_run" == true ]]; then
        log_info "Primo avvio rilevato: configurazione automatica Tailscale..."
        
        local authkey
        authkey=$(get_ts_authkey)
        
        if [[ -n "$authkey" ]]; then
            cmd_tailscale_start "$authkey"
            sleep 2
            cmd_tailscale_config
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
        else
            log_warn "Tailscale saltato (nessuna authkey)"
        fi
    else
        # Avvio successivo: check sidecar
        if ! is_tailscale_running; then
            log_info "Tailscale sidecar non attivo. Avvia con: ./openclaw-manager-tailscale.sh tailscale-start"
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
    cmd_stop
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
    sleep 1
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
    local run_output
    if ! run_output=$(docker run -d \
        --name "${TAILSCALE_CONTAINER}" \
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
        # Autenticazione esplicita con authkey
        log_info "Autenticazione in corso..."
        docker exec "${TAILSCALE_CONTAINER}" tailscale up --authkey="${authkey}" --timeout=30s 2>&1 || log_warn "Autenticazione fallita, verifica la authkey"
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

USO:
    ./openclaw-manager-tailscale.sh start
    # Primo avvio: configurazione automatica Tailscale
    # Avvio successivo: solo OpenClaw + check sidecar

    ./openclaw-manager-tailscale.sh status-full
    # Mostra stato completo con Magic URL

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
    
    help|--help|-h) show_help ;;
    *)
        log_error "Comando sconosciuto: $1"
        show_help
        exit 1
        ;;
esac
