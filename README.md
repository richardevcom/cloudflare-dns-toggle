# Cloudflare DNS Proxy Toggle

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Cloudflare Status](https://img.shields.io/badge/CF-Status-orange.svg)](https://www.cloudflarestatus.com/)

Auto-detects Cloudflare outages and toggles DNS proxy to keep domains accessible. When CF throws 500/502/503 errors, script disables proxy (grey cloud) to route direct to origin. Re-enables when healthy.

Built during the Nov 18, 2025 CF outage.

## Setup

```bash
git clone git@github.com:richardevcom/cloudflare-dns-toggle.git
cd cloudflare-dns-toggle
cp .env.example .env
# Edit .env with your CF_API_TOKEN and CF_ZONE_ID
chmod +x cloudflare-dns-toggle.sh
```

**Get credentials:**
- API Token: https://dash.cloudflare.com/profile/api-tokens (needs `Zone.DNS Edit`)
- Zone ID: CF Dashboard → domain → Overview (right sidebar)

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

# Interactive mode (pick domains from DNS records)
./cloudflare-dns-toggle.sh monitor

# Install as systemd service
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
CF_ZONE_ID=your_zone_id
CHECK_INTERVAL=60      # seconds
AUTO_TOGGLE=true
LOG_FILE=/var/log/cloudflare-dns-toggle.log
```

## Security

- Never commit `.env` (already in `.gitignore`)
- Use API tokens, not Global API Key
- Script never echoes credentials

## License

MIT - [richardevcom](https://github.com/richardevcom)
