# Cloudflare DNS Proxy Toggle

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-4.0+-green.svg)](https://www.gnu.org/software/bash/)
[![Cloudflare](https://img.shields.io/badge/Cloudflare-API-orange.svg)](https://developers.cloudflare.com/api/)
[![Status Page](https://img.shields.io/badge/Status-Monitor-blue.svg)](https://www.cloudflarestatus.com/)

Auto-detects Cloudflare outages and toggles DNS proxy to keep domains accessible. When CF throws 500/502/503 errors, script disables proxy (grey cloud) to route direct to origin. Re-enables when healthy.

Built during the [Nov 18, 2025 CF outage incident](https://www.cloudflarestatus.com/incidents/8gmgl950y3h7).

## Setup

```bash
git clone git@github.com:richardevcom/cloudflare-dns-toggle.git
cd cloudflare-dns-toggle
cp .env.example .env
# Edit .env with your CF_API_TOKEN (CF_ZONE_ID is optional)
chmod +x cloudflare-dns-toggle.sh
```

**Get credentials:**
- API Token: https://dash.cloudflare.com/profile/api-tokens (needs `Zone.DNS Edit`)
- Zone ID: Optional - auto-detected from domain (or set manually in CF Dashboard → Overview)

## Usage

```bash
# Health check
./cloudflare-dns-toggle.sh check example.com

# Toggle proxy
./cloudflare-dns-toggle.sh disable example.com  # grey cloud
./cloudflare-dns-toggle.sh enable example.com   # orange cloud

# Check status
./cloudflare-dns-toggle.sh status example.com

# Monitor mode (auto-toggle every 60s)
./cloudflare-dns-toggle.sh monitor example.com

# Quiet mode (minimal output, logs only errors/changes)
./cloudflare-dns-toggle.sh monitor --quiet example.com
./cloudflare-dns-toggle.sh monitor -q example.com

# Background with nohup
nohup ./cloudflare-dns-toggle.sh monitor -q example.com &

# Interactive mode (pick domains from DNS records)
./cloudflare-dns-toggle.sh monitor

# Install as systemd service (runs in quiet mode)
./cloudflare-dns-toggle.sh install-service

# Rollback to original state
./cloudflare-dns-toggle.sh restore example.com
```

## How it works

1. Curls domain over HTTPS
2. If 500/502/503 → disables proxy via CF API
3. If 2xx → re-enables proxy
4. Saves original state to `.state.json` for rollback

Monitor mode checks every 60s (configurable in `.env`), respects CF rate limits.

## Dependencies

- `curl`
- `jq`

Install: `sudo apt install curl jq` (Ubuntu/Debian) or `brew install curl jq` (macOS)

## Troubleshooting

**401/403 errors:** Check API token permissions (needs `Zone.DNS Edit`)

**Rate limiting:** Increase `CHECK_INTERVAL` in `.env` or monitor fewer domains

**DNS not updating:** Changes take 1-5 min to propagate

## Config

Edit `.env`:
```bash
CF_API_TOKEN=your_token
# CF_ZONE_ID=your_zone_id  # Optional - auto-detected from domain
CHECK_INTERVAL=60      # seconds
AUTO_TOGGLE=true
LOG_FILE=./cloudflare-dns-toggle.log  # local dir (or /var/log/ for system-wide)
```

Verify your token:
```bash
curl "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer your_api_token_here"
```

## Background Monitoring

**Option 1: nohup (simple)**
```bash
nohup ./cloudflare-dns-toggle.sh monitor -q domain1.com domain2.com &
tail -f cloudflare-dns-toggle.log
# Stop: pkill -f cloudflare-dns-toggle
```

**Option 2: systemd service (production)**
```bash
./cloudflare-dns-toggle.sh install-service domain1.com domain2.com
sudo systemctl status cloudflare-dns-toggle
sudo journalctl -u cloudflare-dns-toggle -f
```

**Option 3: screen/tmux**
```bash
screen -S cf-monitor
./cloudflare-dns-toggle.sh monitor -q domain1.com domain2.com
# Detach: Ctrl+A then D
# Reattach: screen -r cf-monitor
```

## Security

```bash
# Secure permissions
chmod 600 .env              # Only owner can read/write
chmod 700 cloudflare-dns-toggle.sh  # Only owner can execute
```

## License

MIT - [richardevcom](https://github.com/richardevcom)
