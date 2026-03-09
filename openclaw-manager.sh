#!/bin/bash
#
# OpenClaw Docker Manager per Arch Linux
# https://github.com/openclaw/openclaw
#

set -euo pipefail

# ============================================
# CONFIGURAZIONE
# ============================================
CONTAINER_NAME="openclaw"
IMAGE_NAME="ghcr.io/openclaw/openclaw:latest"
DATA_DIR="${HOME}/.openclaw"
COMPOSE_FILE="${DATA_DIR}/docker-compose.yml"

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

init_setup() {
    log_info "Inizializzazione setup..."
    
    mkdir -p "${DATA_DIR}/data"
    
    # Fix permessi: container usa UID 1000 (utente node)
    # Se il tuo UID è 1000, funziona automaticamente
    # Altrimenti i dati potrebbero avere permessi errati
    local uid=$(id -u)
    if [[ "$uid" != "1000" ]]; then
        log_warn "Il tuo UID è $uid, ma il container usa UID 1000"
        log_warn "Potresti avere problemi di permessi"
        log_warn "Soluzione: sudo chown -R 1000:1000 ${DATA_DIR}/data"
    fi
    
    if [[ ! -f "${COMPOSE_FILE}" ]]; then
        cat > "${COMPOSE_FILE}" << 'EOF'
services:
  openclaw:
    image: ghcr.io/openclaw/openclaw:latest
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
    fi
    
    log_success "Setup completato"
}

# ============================================
# COMANDI
# ============================================

cmd_start() {
    check_prereqs
    check_image
    init_setup
    
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_warn "OpenClaw è già in esecuzione!"
        return 0
    fi
    
    log_info "Avvio OpenClaw..."
    cd "${DATA_DIR}"
    docker-compose up -d
    
    sleep 2
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_success "OpenClaw avviato!"
        echo -e "${CYAN}Comandi:${NC}"
        echo "  ./openclaw-manager.sh shell   # Entra nel container"
        echo "  ./openclaw-manager.sh logs    # Vedi log"
    else
        log_error "Avvio fallito!"
        exit 1
    fi
}

cmd_stop() {
    check_prereqs
    
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
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
    
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_error "OpenClaw non è in esecuzione! Avvia prima con: ./openclaw-manager.sh start"
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
    
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "Stato: ${GREEN}IN ESECUZIONE${NC}"
        docker ps --filter "name=${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}"
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
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
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
        log_info "Per ricominciare: ./openclaw-manager.sh start"
    else
        log_info "Reset annullato"
    fi
}

cmd_update() {
    log_info "Aggiornamento immagine..."
    docker pull "${IMAGE_NAME}"
    
    local was_running=false
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        was_running=true
        cmd_stop
    fi
    
    if [[ "$was_running" == true ]]; then
        cmd_start
    fi
    
    log_success "Aggiornamento completato"
}

show_help() {
    cat << EOF
OpenClaw Docker Manager

COMANDI:
    start      Avvia OpenClaw
    stop       Ferma OpenClaw
    restart    Riavvia (rimuove e ricrea container)
    shell      Entra nella shell del container
    logs       Visualizza log
    status     Stato e informazioni
    backup     Crea backup dei dati
    reset      ⚠️ Elimina TUTTO (container + dati)
    update     Aggiorna immagine Docker
    help       Mostra aiuto

USO:
    ./openclaw-manager.sh start
    ./openclaw-manager.sh shell
    # poi: openclaw onboard

EOF
}

# ============================================
# MAIN
# ============================================

case "${1:-help}" in
    start)      cmd_start ;;
    stop)       cmd_stop ;;
    restart)    cmd_restart ;;
    shell|sh)   cmd_shell ;;
    logs|log)   cmd_logs ;;
    status|st)  cmd_status ;;
    backup|bk)  cmd_backup ;;
    reset|rm)   cmd_reset ;;
    update|up)  cmd_update ;;
    help|--help|-h) show_help ;;
    *)
        log_error "Comando sconosciuto: $1"
        show_help
        exit 1
        ;;
esac
