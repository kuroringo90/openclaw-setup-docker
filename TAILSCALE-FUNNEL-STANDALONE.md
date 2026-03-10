# Tailscale Funnel Standalone

Applicazione **indipendente e riutilizzabile** per esporre servizi locali su internet tramite Tailscale Funnel.

## 🎯 Caratteristiche

- ✅ **Indipendente**: Non legato a OpenClaw o altri servizi
- ✅ **Riutilizzabile**: Condividibile tra multipli progetti
- ✅ **Anti-duplicati**: Usa API Tailscale per evitare nodi duplicati
- ✅ **Persistente**: Stato salvato in `~/.tailscale-funnel/`
- ✅ **Auto-riavvio**: Restart policy `unless-stopped`

## 📦 Installazione

### 1. Clona o copia lo script

```bash
# Copia dallo repository OpenClaw
cp /path/to/openclaw/tailscale-funnel-standalone.sh /usr/local/bin/tailscale-funnel
chmod +x /usr/local/bin/tailscale-funnel
```

### 2. Ottieni le chiavi Tailscale

**TS_AUTHKEY** (per autenticazione):
```
https://login.tailscale.com/admin/settings/keys
→ Generate auth key
```

**TS_API_KEY** (per cleanup nodi duplicati - opzionale ma consigliato):
```
https://login.tailscale.com/admin/settings/api
→ Generate API key
```

### 3. Configura

```bash
tailscale-funnel start
```

Al primo avvio crea `~/.tailscale-funnel/.env`:

```env
# Tailscale Authentication Key
TS_AUTHKEY=tskey-auth-...

# Tailscale API Key (per cleanup nodi)
TS_API_KEY=api-...

# Tailnet name (opzionale)
TS_TAILNET=

# Hostname del nodo
TS_HOSTNAME=tailscale-funnel
```

Modifica il file con le tue chiavi.

## 🚀 Uso Rapido

```bash
# Avvia con servizio default (porta 18789)
tailscale-funnel start

# Avvia con servizio personalizzato
tailscale-funnel start grafana 3000

# Aggiungi altro servizio
tailscale-funnel add homeassistant 8123 /ha

# Mostra stato
tailscale-funnel status

# Mostra URL
tailscale-funnel url

# Pulisci nodi duplicati
tailscale-funnel cleanup
```

## 📋 Comandi

| Comando | Descrizione |
|---------|-------------|
| `start [name] [port]` | Avvia container e configura funnel |
| `stop` | Ferma container |
| `restart [name] [port]` | Riavvia container |
| `status` | Mostra stato completo |
| `add <name> <port> [path]` | Aggiungi servizio |
| `remove <name>` | Rimuovi servizi |
| `url` | Mostra Magic URL |
| `cleanup` | Elimina nodi duplicati via API |
| `shell` | Accedi alla shell del container |

## 🔧 Configurazione Multi-Servizio

### Esempio: Home Lab

```bash
# Avvio iniziale con servizio principale
tailscale-funnel start openclaw 18789

# Aggiungi Grafana
tailscale-funnel add grafana 3000 /grafana

# Aggiungi Home Assistant
tailscale-funnel add homeassistant 8123 /ha

# Aggiungi Node-RED
tailscale-funnel add node-red 1880 /node-red

# Aggiungi Plex
tailscale-funnel add plex 32400 /plex
```

**URL risultanti:**
```
https://tailscale-funnel.tailnet-id.ts.net/           → OpenClaw
https://tailscale-funnel.tailnet-id.ts.net/grafana    → Grafana
https://tailscale-funnel.tailnet-id.ts.net/ha         → Home Assistant
https://tailscale-funnel.tailnet-id.ts.net/node-red   → Node-RED
https://tailscale-funnel.tailnet-id.ts.net/plex       → Plex
```

## 🧹 Gestione Nodi Duplicati

### Problema

Ogni riavvio del container può creare un nuovo nodo Tailscale:
```
tailscale-funnel      (offline)
tailscale-funnel-1    (offline)
tailscale-funnel-2    (attivo)
```

### Soluzione Automatica

Lo script **pulisce automaticamente** i nodi duplicati ad ogni avvio se `TS_API_KEY` è configurata.

### Soluzione Manuale

```bash
# Pulisci nodi duplicati
tailscale-funnel cleanup

# Oppure dalla admin console
https://login.tailscale.com/admin/machines
→ Elimina nodi offline
```

## 🔗 Integrazione con Altri Progetti

### Docker Compose

Nel tuo `docker-compose.yml`:

```yaml
version: '3.8'

services:
  # Il tuo servizio
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    network_mode: host
    restart: unless-stopped

  # Tailscale Funnel (condiviso)
  tailscale-funnel:
    image: tailscale/tailscale:latest
    container_name: tailscale-funnel
    network_mode: host
    volumes:
      - ~/.tailscale-funnel/state:/var/lib/tailscale
    environment:
      - TS_AUTHKEY=${TS_AUTHKEY}
    command: tailscaled --tun=userspace-networking --hostname=home-lab
    restart: unless-stopped
```

### Script di Progetto

Crea `scripts/setup-tunnel.sh` nel tuo progetto:

```bash
#!/bin/bash
# Setup tunnel per questo progetto

PROJECT_NAME="myapp"
PROJECT_PORT="3000"

# Verifica se tailscale-funnel è installato
if ! command -v tailscale-funnel &> /dev/null; then
    echo "Installa tailscale-funnel prima:"
    echo "  git clone .../openclaw"
    echo "  cp .../tailscale-funnel-standalone.sh /usr/local/bin/"
    exit 1
fi

# Aggiungi servizio
tailscale-funnel add "${PROJECT_NAME}" "${PROJECT_PORT}" "/${PROJECT_NAME}"

echo "Servizio disponibile su:"
tailscale-funnel url
```

### Variabili per Progetto

Ogni progetto può avere il proprio container:

```bash
# Progetto A
export TS_CONTAINER_NAME=project-a-funnel
export TS_HOSTNAME=project-a
tailscale-funnel start

# Progetto B
export TS_CONTAINER_NAME=project-b-funnel
export TS_HOSTNAME=project-b
tailscale-funnel start
```

## 📊 Stato e Monitoraggio

```bash
# Stato completo
tailscale-funnel status

# Solo URL
tailscale-funnel url

# Log container
docker logs tailscale-funnel

# Log Tailscale
docker exec tailscale-funnel tailscale status
```

## 🔐 Sicurezza

- **Funnel**: Espone servizi su internet (chiunque con l'URL può accedere)
- **Serve**: Solo tailnet (dispositivi Tailscale autorizzati)
- **API Key**: Salva in `.env` con permessi `600`

```bash
chmod 600 ~/.tailscale-funnel/.env
```

## 🛠️ Troubleshooting

### Container non si avvia

```bash
# Verifica Docker
docker info

# Verifica authkey
docker logs tailscale-funnel

# Riavvia
tailscale-funnel restart
```

### Nodi duplicati

```bash
# Cleanup automatico
tailscale-funnel cleanup

# Verifica TS_API_KEY
cat ~/.tailscale-funnel/.env | grep TS_API_KEY
```

### Funnel non abilitato

```bash
# Abilita da admin console
https://login.tailscale.com/admin/settings/funnel

# Oppure manualmente
docker exec tailscale-funnel tailscale funnel --bg 18789
```

### Servizio non raggiungibile

```bash
# Verifica locale
curl -I http://127.0.0.1:3000

# Verifica funnel
docker exec tailscale-funnel tailscale serve status

# Verifica connettività
tailscale-funnel url
```

## 📝 Esempi d'Uso

### 1. Sviluppo Web

```bash
# Esposti applicazione React
tailscale-funnel start myapp 3000

# URL: https://tailscale-funnel.tailnet-id.ts.net/
```

### 2. Dashboard Monitoring

```bash
# Grafana
tailscale-funnel add grafana 3000 /grafana

# Prometheus
tailscale-funnel add prometheus 9090 /prometheus

# Alertmanager
tailscale-funnel add alertmanager 9093 /alertmanager
```

### 3. Home Automation

```bash
# Home Assistant
tailscale-funnel add ha 8123 /ha

# Node-RED
tailscale-funnel add nodered 1880 /nodered

# MQTT Explorer (web)
tailscale-funnel add mqtt 8081 /mqtt
```

### 4. Media Server

```bash
# Plex
tailscale-funnel add plex 32400 /plex

# Jellyfin
tailscale-funnel add jellyfin 8096 /jellyfin

# Transmission
tailscale-funnel add transmission 9091 /transmission
```

## 📄 File Generati

```
~/.tailscale-funnel/
├── .env              # Configurazione (chiavi, hostname)
└── state/            # Stato Tailscale persistente
    └── tailscaled.state
```

## 🔗 Riferimenti

- [Tailscale Funnel Docs](https://tailscale.com/kb/1223/funnel)
- [Tailscale Serve Docs](https://tailscale.com/kb/1247/funnel-serve-use-cases)
- [Tailscale API Docs](https://tailscale.com/reference/api)
- [OpenClaw Manager](./README.md)

## 📞 Supporto

Per problemi o domande:
1. Controlla i log: `docker logs tailscale-funnel`
2. Verifica stato: `tailscale-funnel status`
3. Pulisci nodi: `tailscale-funnel cleanup`
4. Consulta docs: https://docs.openclaw.ai
