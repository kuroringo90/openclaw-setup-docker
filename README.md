# OpenClaw Manager con Tailscale

Manager script per OpenClaw con integrazione Tailscale per accesso remoto sicuro.

## 🚀 Installazione Rapida

```bash
# 1. Clona o scarica lo script
git clone https://github.com/openclaw/openclaw.git
cd openclaw

# 2. Rendi eseguibile
chmod +x openclaw-manager-tailscale.sh

# 3. Ottieni Tailscale Auth Key
# Vai su: https://login.tailscale.com/admin/settings/keys
# Genera una auth key e copiala

# 4. Avvia!
./openclaw-manager-tailscale.sh start
```

## 🎉 Magic URL

Al **primo avvio**, lo script configura automaticamente:

1. ✅ OpenClaw container
2. ✅ Tailscale sidecar
3. ✅ Serve + Funnel
4. ✅ **Magic URL** da condividere

```
════════════════════════════════════════
🎉 MAGIC URL:
https://openclaw-prova.tailnet.ts.net/
════════════════════════════════════════
```

## 📋 Comandi

### OpenClaw

| Comando | Descrizione |
|---------|-------------|
| `start` | Avvia OpenClaw (+ auto Tailscale al primo avvio) |
| `stop` | Ferma OpenClaw |
| `restart` | Riavvia OpenClaw |
| `shell` | Entra nella shell del container |
| `logs` | Visualizza log in tempo reale |
| `status` | Stato OpenClaw |
| `backup` | Crea backup dei dati |
| `reset` | Elimina OpenClaw + dati |
| `update` | Aggiorna immagine Docker |

### Tailscale

| Comando | Descrizione |
|---------|-------------|
| `tailscale-start` | Avvia sidecar Tailscale |
| `tailscale-config` | Configura serve + funnel |
| `tunnel-url` | Mostra Magic URL |
| `status-full` | Stato completo (OpenClaw \| Tailscale \| Tunnel) |
| `full-reset` | Elimina TUTTO (OpenClaw + Tailscale + dati) |

## 🔧 Configurazione

### Variabili d'ambiente

Crea un file `.env` nella root del progetto:

```bash
cp .env.example .env
```

Modifica `.env` con la tua Tailscale Auth Key:

```env
TS_AUTHKEY=tskey-auth-xxxxx...
```

### Prerequisiti

- **Docker** installato e in esecuzione
- **docker-compose** installato
- **Tailscale account** (gratuito)

#### Installazione Docker (Arch Linux)

```bash
sudo pacman -S docker docker-compose
sudo systemctl enable --now docker
```

## 📖 Uso Tipico

### Primo Avvio

```bash
./openclaw-manager-tailscale.sh start
```

Lo script:
1. Scarica l'immagine OpenClaw (se non presente)
2. Crea il docker-compose.yml
3. Avvia OpenClaw
4. **Chiede la TS_AUTHKEY** (se non in .env)
5. Avvia Tailscale sidecar
6. Configura serve + funnel
7. **Mostra la Magic URL**

### Avvio Successivo

```bash
./openclaw-manager-tailscale.sh start
```

Lo script:
1. Verifica se OpenClaw è già in esecuzione
2. Avvia solo se necessario
3. Controlla se Tailscale sidecar è attivo

### Verifica Stato

```bash
./openclaw-manager-tailscale.sh status-full
```

Output esempio:

```
╔════════════════════════════════════════╗
║       STATO COMPLETO OPENCLAW          ║
╚════════════════════════════════════════╝

┌── OpenClaw ──────────────────────────┐
│ Stato:    ✅ IN ESECUZIONE
│ Health:   ✅ OK (18789)
└──────────────────────────────────────┘

┌── Tailscale ─────────────────────────┐
│ Sidecar:  ✅ ATTIVO
│ Status:   ✅ CONNESSO
└──────────────────────────────────────┘

┌── Tunnel ────────────────────────────┐
│ URL:      https://openclaw-prova.tailnet.ts.net/
│ Reach:    ✅ RAGGIUNGIBILE
└──────────────────────────────────────┘
```

### Accesso alla Shell

```bash
./openclaw-manager-tailscale.sh shell
```

Una volta dentro:

```bash
openclaw onboard       # Configurazione guidata
openclaw --help        # Aiuto
openclaw skills list   # Lista skills
```

### Backup

```bash
./openclaw-manager-tailscale.sh backup
```

Crea un backup in `~/openclaw-backups/`

## 🏗️ Architettura

```
┌─────────────────────────────────────────┐
│         Host (network_mode: host)       │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │      openclaw (container)       │    │
│  │  - Porta: 18789                 │    │
│  │  - Volume: ~/.openclaw/data     │    │
│  └─────────────────────────────────┘    │
│                    │                    │
│  ┌────────────────┴────────────────┐    │
│  │   openclaw-tailscale (sidecar)  │    │
│  │   --network container:openclaw  │    │
│  │   - tailscaled                  │    │
│  │   - serve / → 127.0.0.1:18789   │    │
│  │   - funnel 443                  │    │
│  └─────────────────────────────────┘    │
└─────────────────────────────────────────┘
                    │
                    ▼
         Tailscale Network
                    │
                    ▼
    https://hostname.tailnet.ts.net/
```

## 🔐 Sicurezza

- **Tailscale** cripta tutto il traffico
- **Auth Key** richiesta solo al primo avvio
- **Funnel** espone solo la porta 443
- **Serve** proxya solo localhost:18789

## 🛠️ Troubleshooting

### Tailscale non si connette

```bash
# Verifica lo stato
docker exec openclaw-tailscale tailscale status

# Riavvia il sidecar
docker rm -f openclaw-tailscale
./openclaw-manager-tailscale.sh tailscale-start
```

### Magic URL non raggiungibile

```bash
# Verifica il tunnel
./openclaw-manager-tailscale.sh tunnel-url

# Controlla i log Tailscale
docker logs openclaw-tailscale
```

### Problemi di permessi

Se il tuo UID non è 1000:

```bash
sudo chown -R 1000:1000 ~/.openclaw/data
```

## 📄 License

MIT License - vedi LICENSE per dettagli.

## 🔗 Link Utili

- [OpenClaw GitHub](https://github.com/openclaw/openclaw)
- [Tailscale Admin](https://login.tailscale.com/admin)
- [Tailscale Funnel Docs](https://tailscale.com/kb/1223/funnel)
