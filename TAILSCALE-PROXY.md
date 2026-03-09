# Tailscale Sidecar Condiviso per Multipli Servizi

Questa documentazione spiega come **riutilizzare lo stesso container Tailscale** per esporre multipli servizi locali su una singola tailnet.

## Architettura

```
┌─────────────────────────────────────────────────────────────┐
│                    Host Linux                               │
│                                                             │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │   Servizio A    │  │   Servizio B    │  │   Servizio  │ │
│  │   localhost:3000│  │   localhost:8080│  │   :9000     │ │
│  └────────┬────────┘  └────────┬────────┘  └──────┬──────┘ │
│           │                    │                   │        │
│           └────────────────────┼───────────────────┘        │
│                                │                            │
│                    ┌───────────▼────────────┐               │
│                    │  Tailscale Sidecar     │               │
│                    │  (container condiviso) │               │
│                    │  --network container:X │               │
│                    │                        │               │
│                    │  Funnel: 443           │               │
│                    │  Serve: /a → :3000     │               │
│                    │  Serve: /b → :8080     │               │
│                    │  Serve: /c → :9000     │               │
│                    └───────────┬────────────┘               │
└────────────────────────────────┼────────────────────────────┘
                                 │
               ┌─────────────────┼─────────────────┐
               │                 │                 │
        https://tailnet/   https://tailnet/  https://tailnet/
           /a                 /b                /c
```

## Requisiti

1. **Docker** installato e funzionante
2. **Tailscale account** (gratuito o paid)
3. **TS_AUTHKEY** valida da https://login.tailscale.com/admin/settings/keys

## Setup Iniziale

### 1. Crea un Container "Gateway"

Il sidecar Tailscale deve condividere il network con un container principale:

```bash
# Crea un container gateway minimale
docker run -d \
  --name tailscale-gateway \
  --network host \
  alpine/socat \
  sleep infinity
```

Oppure usa uno dei tuoi servizi esistenti come "gateway" (es. OpenClaw).

### 2. Avvia il Sidecar Tailscale

```bash
# Variabili
TAILSCALE_HOSTNAME="myproxy"
TS_AUTHKEY="tskey-auth-..."

# Avvia sidecar
docker run -d \
  --name tailscale-sidecar \
  --network container:tailscale-gateway \
  -e TS_AUTHKEY="${TS_AUTHKEY}" \
  tailscale/tailscale:latest \
  tailscaled --tun=userspace-networking

# Autentica
docker exec tailscale-sidecar tailscale up \
  --authkey="${TS_AUTHKEY}" \
  --hostname="${TAILSCALE_HOSTNAME}" \
  --force-reauth
```

### 3. Configura Funnel

```bash
# Abilita funnel sulla porta 443
docker exec tailscale-sidecar tailscale funnel --bg 443

# Verifica
docker exec tailscale-sidecar tailscale funnel status
```

## Configurare Servizi Multipli

### Opzione A: Path-based Routing (Consigliato)

Ogni servizio accessibile da un path diverso:

```bash
# Servizio A su porta 3000
docker exec tailscale-sidecar tailscale serve --bg --set-path /servizio-a 3000

# Servizio B su porta 8080
docker exec tailscale-sidecar tailscale serve --bg --set-path /servizio-b 8080

# Servizio C su porta 9000
docker exec tailscale-sidecar tailscale serve --bg --set-path /servizio-c 9000
```

**URL risultanti:**
- `https://myproxy.tailnet.ts.net/servizio-a`
- `https://myproxy.tailnet.ts.net/servizio-b`
- `https://myproxy.tailnet.ts.net/servizio-c`

### Opzione B: Subdomain Routing (se supportato)

```bash
# Configura handler diversi per path
docker exec tailscale-sidecar tailscale serve --bg 3000
docker exec tailscale-sidecar tailscale funnel --bg 443
```

Poi usa un reverse proxy (es. Caddy, Nginx) dentro il container gateway per instradare in base all'host.

## Script Helper per Nuovi Progetti

Crea uno script `tailscale-proxy.sh` nel tuo progetto:

```bash
#!/bin/bash
# tailscale-proxy.sh - Configura Tailscale per un nuovo servizio

set -euo pipefail

GATEWAY_CONTAINER="${GATEWAY_CONTAINER:-tailscale-gateway}"
SIDECAR_CONTAINER="${SIDECAR_CONTAINER:-tailscale-sidecar}"
SERVICE_NAME="${1:-myservice}"
SERVICE_PORT="${2:-8080}"
SERVICE_PATH="${3:-/${SERVICE_NAME}}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error() { echo -e "${RED}[ERRORE]${NC} $1"; }

check_prereqs() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${GATEWAY_CONTAINER}$"; then
        log_error "Gateway container non trovato: ${GATEWAY_CONTAINER}"
        exit 1
    fi
    
    if ! docker ps --format '{{.Names}}' | grep -q "^${SIDECAR_CONTAINER}$"; then
        log_error "Sidecar container non trovato: ${SIDECAR_CONTAINER}"
        exit 1
    fi
}

configure_service() {
    log_info "Configurazione servizio: ${SERVICE_NAME} → porta ${SERVICE_PORT}"
    
    # Configura serve con path-based routing
    if docker exec "${SIDECAR_CONTAINER}" tailscale serve --bg --set-path "${SERVICE_PATH}" "${SERVICE_PORT}" 2>&1; then
        log_success "Servizio configurato!"
    else
        log_error "Configurazione fallita"
        exit 1
    fi
    
    # Mostra URL
    local hostname
    hostname=$(docker exec "${SIDECAR_CONTAINER}" tailscale status --json 2>/dev/null | \
        grep -o '"DNSName"[^,]*' | head -1 | cut -d'"' -f4 | sed 's/\.$//')
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}Servizio disponibile:${NC}"
    echo -e "${YELLOW}https://${hostname}${SERVICE_PATH}${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
}

remove_service() {
    log_info "Rimozione servizio: ${SERVICE_NAME}"
    docker exec "${SIDECAR_CONTAINER}" tailscale serve reset 2>/dev/null || true
    log_success "Servizio rimosso"
}

show_status() {
    echo -e "${GREEN}=== Stato Tailscale Proxy ===${NC}"
    docker exec "${SIDECAR_CONTAINER}" tailscale serve status
    echo ""
    docker exec "${SIDECAR_CONTAINER}" tailscale funnel status
}

case "${4:-configure}" in
    configure|add)
        check_prereqs
        configure_service
        ;;
    remove|rm)
        check_prereqs
        remove_service
        ;;
    status|st)
        check_prereqs
        show_status
        ;;
    *)
        echo "Uso: $0 <service-name> <port> [path] [configure|remove|status]"
        echo ""
        echo "Esempi:"
        echo "  $0 myapp 3000 /app configure    # Aggiungi servizio"
        echo "  $0 myapp 3000 /app remove       # Rimuovi servizio"
        echo "  $0 status                       # Mostra stato"
        ;;
esac
```

Rendi eseguibile e usa:

```bash
chmod +x tailscale-proxy.sh

# Aggiungi un nuovo servizio
./tailscale-proxy.sh grafana 3000 /grafana

# Rimuovi un servizio
./tailscale-proxy.sh grafana 3000 /grafana remove

# Mostra stato
./tailscale-proxy.sh status
```

## Docker Compose Integration

Aggiungi al tuo `docker-compose.yml`:

```yaml
version: '3.8'

services:
  # Il tuo servizio principale
  myapp:
    image: myapp:latest
    container_name: myapp
    network_mode: host  # Condivide network con gateway
    # Oppure usa network condiviso:
    # container_name: tailscale-gateway
    # network_mode: "container:tailscale-gateway"

  # Gateway (se non esiste già)
  tailscale-gateway:
    image: alpine/socat
    container_name: tailscale-gateway
    command: sleep infinity
    network_mode: host
    restart: unless-stopped

  # Tailscale sidecar (condiviso)
  tailscale-sidecar:
    image: tailscale/tailscale:latest
    container_name: tailscale-sidecar
    network_mode: "container:tailscale-gateway"
    environment:
      - TS_AUTHKEY=${TS_AUTHKEY}
    command: tailscaled --tun=userspace-networking
    restart: unless-stopped
    depends_on:
      - tailscale-gateway
```

## Configurazione OpenClaw per Multipli Servizi

Se usi OpenClaw come gateway principale:

```bash
# OpenClaw già configurato come gateway
GATEWAY_CONTAINER="openclaw"
SIDECAR_CONTAINER="openclaw-tailscale"

# Aggiungi nuovo servizio
docker exec openclaw-tailscale tailscale serve --bg --set-path /grafana 3000
docker exec openclaw-tailscale tailscale serve --bg --set-path /node-red 1880

# URL:
# https://steagent.tail5d495.ts.net/grafana
# https://steagent.tail5d495.ts.net/node-red
```

## Troubleshooting

### Funnel non abilitato

```bash
# Abilita da admin console
https://login.tailscale.com/admin/settings/funnel

# Oppure via CLI
docker exec tailscale-sidecar tailscale funnel --bg 443
```

### Serve non funziona

```bash
# Resetta configurazione
docker exec tailscale-sidecar tailscale serve reset

# Ricrea handler
docker exec tailscale-sidecar tailscale serve --bg --set-path /myservice 8080
```

### Hostname duplicato

```bash
# Elimina nodi vecchi
https://login.tailscale.com/admin/machines

# Oppure forza re-auth
docker exec tailscale-sidecar tailscale up --force-reauth --hostname=myproxy
```

### Verifica connettività

```bash
# Stato sidecar
docker exec tailscale-sidecar tailscale status

# Test locale
curl -I http://127.0.0.1:8080

# Test funnel (da dispositivo Tailscale)
curl -I https://myproxy.tailnet.ts.net/myservice
```

## Best Practices

1. **Usa path descrittivi**: `/grafana`, `/node-red`, `/homeassistant`
2. **Documenta i servizi**: Crea un file `SERVICES.md` con tutti i servizi esposti
3. **Backup authkey**: Salva `TS_AUTHKEY` in un file `.env` sicuro
4. **Monitora sidecar**: Aggiungi health check per il container Tailscale
5. **Aggiorna regolarmente**: `docker pull tailscale/tailscale:latest`

## Esempio Completo: Home Lab

```bash
# Setup iniziale
export TS_AUTHKEY="tskey-auth-..."
export GATEWAY="tailscale-gateway"
export SIDECAR="tailscale-sidecar"

# Crea gateway
docker run -d --name ${GATEWAY} --network host alpine/socat sleep infinity

# Avvia sidecar
docker run -d \
  --name ${SIDECAR} \
  --network container:${GATEWAY} \
  -e TS_AUTHKEY="${TS_AUTHKEY}" \
  tailscale/tailscale:latest \
  tailscaled --tun=userspace-networking

docker exec ${SIDECAR} tailscale up --authkey="${TS_AUTHKEY}" --hostname=homelab --force-reauth
docker exec ${SIDECAR} tailscale funnel --bg 443

# Aggiungi servizi
docker exec ${SIDECAR} tailscale serve --bg --set-path /grafana 3000
docker exec ${SIDECAR} tailscale serve --bg --set-path /homeassistant 8123
docker exec ${SIDECAR} tailscale serve --bg --set-path /plex 32400
docker exec ${SIDECAR} tailscale serve --bg --set-path /pihole 8081

echo "Servizi disponibili:"
echo "  https://homelab.tailnet.ts.net/grafana"
echo "  https://homelab.tailnet.ts.net/homeassistant"
echo "  https://homelab.tailnet.ts.net/plex"
echo "  https://homelab.tailnet.ts.net/pihole"
```

## Riferimenti

- [Tailscale Funnel Docs](https://tailscale.com/kb/1223/funnel)
- [Tailscale Serve Docs](https://tailscale.com/kb/1247/funnel-serve-use-cases)
- [Container Networking](https://docs.docker.com/network/)
- [OpenClaw Manager](./README.md)
