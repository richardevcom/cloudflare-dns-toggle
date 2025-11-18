[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-4.0%2B-green.svg)](https://www.gnu.org/software/bash/)
[![Cloudflare](https://img.shields.io/badge/Cloudflare-API-orange.svg)](https://api.cloudflare.com/)
[![Status](https://img.shields.io/badge/Cloudflare-Status-blue.svg)](https://www.cloudflarestatus.com/)

# Cloudflare DNS Proxy Auto-Toggle

**Automatically detect Cloudflare network outages and toggle DNS proxy status to keep your domains accessible.**

When Cloudflare's network experiences issues (like the [Nov 18, 2025 global outage](https://www.cloudflarestatus.com/)), domains behind the orange cloud become inaccessible. This script monitors your domains, detects Cloudflare 500/502/503 errors, and automatically disables the proxy (grey cloud) to route traffic directly to your origin. When Cloudflare recovers, it re-enables the proxy.

---

## Features

- 🔍 **Smart Health Detection** - Curls your domains to detect Cloudflare errors (500/502/503)
- 🔄 **Auto-Toggle Proxy** - Disables proxy when CF is down, re-enables when up
- 📋 **Interactive Domain Selection** - No config needed, pick from your DNS records
- 🔐 **Secure Credentials** - `.env` file for API tokens (never committed)
- 📊 **State Management** - Saves original proxy settings for rollback
- 🤖 **Monitor Mode** - Continuous health checks with auto-toggle
- ⚙️ **Systemd Service** - Run as background service with auto-restart
- 📝 **Minimal Logging** - Timestamped logs with health status

---

## Prerequisites

- `curl` and `jq` installed
- Cloudflare API Token with **Zone.DNS Edit** permissions
- Your Cloudflare Zone ID

---

## Quick Start

### 1. Clone & Setup

```bash
git clone git@github.com:richardevcom/cloudflare-dns-toggle.git
cd cloudflare-dns-toggle
chmod +x cloudflare-dns-toggle.sh
```

### 2. Configure Credentials

```bash
cp .env.example .env
nano .env  # Add your CF_API_TOKEN and CF_ZONE_ID
```

Get your credentials:
- **API Token:** https://dash.cloudflare.com/profile/api-tokens (create token with `Zone.DNS Edit` permission)
- **Zone ID:** Cloudflare Dashboard → Select your domain → Overview → Zone ID (right sidebar)

### 3. Run Your First Check

```bash
./cloudflare-dns-toggle.sh check example.com
```

---

## Usage

### Check Domain Health

```bash
# Single domain
./cloudflare-dns-toggle.sh check example.com

# Multiple domains
./cloudflare-dns-toggle.sh check example.com www.example.com api.example.com

# Interactive selection (prompts you to pick domains)
./cloudflare-dns-toggle.sh check
```

### Toggle Proxy Status

```bash
# Disable proxy (grey cloud) - direct to origin
./cloudflare-dns-toggle.sh disable example.com

# Enable proxy (orange cloud) - through Cloudflare
./cloudflare-dns-toggle.sh enable example.com

# Check current status
./cloudflare-dns-toggle.sh status example.com
```

### Monitor Mode (Auto-Toggle)

Continuously monitor domains and auto-toggle proxy based on health:

```bash
# Start monitoring with interactive selection
./cloudflare-dns-toggle.sh monitor

# Monitor specific domains
./cloudflare-dns-toggle.sh monitor example.com www.example.com
```

**Monitor behavior:**
- Checks domain health every 60 seconds (configurable in `.env`)
- If CF error detected (500/502/503) → disables proxy
- If domain returns healthy → re-enables proxy
- Respects Cloudflare rate limits (0.3s delay between domains)

### Install as Systemd Service

Run monitor mode as a background service:

```bash
./cloudflare-dns-toggle.sh install-service
```

**Service management:**
```bash
# Check service status
sudo systemctl status cloudflare-dns-toggle

# View live logs
sudo journalctl -u cloudflare-dns-toggle -f

# Stop service
sudo systemctl stop cloudflare-dns-toggle

# Restart service
sudo systemctl restart cloudflare-dns-toggle

# Disable service (stop auto-start)
sudo systemctl disable cloudflare-dns-toggle
```

### Restore Original Settings

Rollback to proxy settings saved before first toggle:

```bash
./cloudflare-dns-toggle.sh restore example.com
```

---

## Configuration

Edit `.env` to customize behavior:

```bash
# Required
CF_API_TOKEN=your_api_token_here
CF_ZONE_ID=your_zone_id_here

# Optional
CHECK_INTERVAL=60          # Seconds between health checks
AUTO_TOGGLE=true           # Auto-toggle proxy in monitor mode
LOG_FILE=/var/log/cloudflare-dns-toggle.log
```

---

## How It Works

1. **Health Check:** Script curls your domain (HTTPS) and checks HTTP status code
2. **Error Detection:** If status is 500/502/503 (Cloudflare errors) → domain marked as DOWN
3. **Proxy Toggle:** 
   - **DOWN:** Disables proxy (grey cloud) via Cloudflare API → traffic goes direct to origin
   - **UP:** Re-enables proxy (orange cloud) → traffic routed through Cloudflare
4. **State Management:** Original proxy settings saved to `.state.json` for rollback
5. **Rate Limiting:** 0.3s delay between API calls to respect Cloudflare limits (1200 req/5min)

---

## Troubleshooting

### Missing Dependencies

```bash
# Ubuntu/Debian
sudo apt install curl jq

# macOS
brew install curl jq

# Arch Linux
sudo pacman -S curl jq
```

### API Authentication Errors (401/403)

- Verify `CF_API_TOKEN` in `.env` is correct
- Check token has **Zone.DNS Edit** permission
- Confirm `CF_ZONE_ID` matches your domain's zone

### Rate Limiting (429)

Script includes 0.3s delays between requests. If you still hit rate limits:
- Increase `CHECK_INTERVAL` in `.env`
- Monitor fewer domains simultaneously

### Domain Still Down After Toggle

- DNS changes take 1-5 minutes to propagate
- Check your origin server is actually accessible (not behind firewall)
- Verify DNS record points to correct origin IP

---

## Security Notes

- ✅ **Never commit `.env`** - Already in `.gitignore`
- ✅ **Use API Tokens** (not Global API Key) - More secure, scoped permissions
- ✅ **Store tokens in `.env`** - Not in script or repo history
- ✅ **State file is local** - `.state.json` contains domain/record IDs only

---

## Cloudflare Network Status

Monitor Cloudflare's global network health:
- **Status Page:** https://www.cloudflarestatus.com/
- **RSS Feed:** https://www.cloudflarestatus.com/history.rss

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Author

**richardevcom**  
GitHub: [@richardevcom](https://github.com/richardevcom)

---

## Contributing

PRs welcome. For major changes, open an issue first to discuss.

---

**Built during the Nov 18, 2025 Cloudflare outage 🔥**
