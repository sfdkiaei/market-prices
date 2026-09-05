#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# Market Prices - Complete Installer
#
# Installs:
#   - Python virtual environment
#   - Python market price service
#   - systemd user service
#   - GNOME Shell extension
#   - configuration
#
# Usage:
#   ./install.sh
#   make enable
#   make disable
#   make interval MINUTES=5
#   make logs
# =============================================================================

# -----------------------------------------------------------------------------
# User / paths
# -----------------------------------------------------------------------------

USERNAME="$(id -un)"
HOME_DIR="${HOME:?HOME is not set}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VENV_DIR="${PROJECT_DIR}/.venv"

CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME_DIR}/.config}/market-prices"
SYSTEMD_DIR="${HOME_DIR}/.config/systemd/user"

EXTENSION_UUID="market-prices@local"
EXTENSION_DIR="${HOME_DIR}/.local/share/gnome-shell/extensions/${EXTENSION_UUID}"

SERVICE_NAME="market-prices.service"
SERVICE_FILE="${SYSTEMD_DIR}/${SERVICE_NAME}"

CONFIG_INTERVAL="${CONFIG_DIR}/update_interval"
CACHE_FILE="${CONFIG_DIR}/market-prices.json"

PYTHON_BIN="${VENV_DIR}/bin/python"
PIP_BIN="${VENV_DIR}/bin/pip"

CHROME_BIN=""

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warning() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

die() {
    error "$*"
    exit 1
}

# -----------------------------------------------------------------------------
# Check environment
# -----------------------------------------------------------------------------

info "Installing Market Prices for user: ${USERNAME}"
info "Home directory: ${HOME_DIR}"
info "Project directory: ${PROJECT_DIR}"

if [[ "$(uname -s)" != "Linux" ]]; then
    die "This installer currently supports Linux only."
fi

if ! command -v python3 >/dev/null 2>&1; then
    die "python3 is not installed."
fi

if ! command -v systemctl >/dev/null 2>&1; then
    die "systemctl is not available."
fi

if ! command -v gnome-extensions >/dev/null 2>&1; then
    warning "gnome-extensions command was not found."
    warning "The Python service will still be installed."
fi

for required in \
    "market_scraper.py" \
    "market_prices_service.py" \
    "requirements.txt" \
    "extension/extension.js" \
    "extension/metadata.json"
do
    if [[ ! -f "${PROJECT_DIR}/${required}" ]]; then
        die "Missing ${required} in ${PROJECT_DIR}.
This does not look like a complete checkout of the repository."
    fi
done

# -----------------------------------------------------------------------------
# Find Google Chrome
# -----------------------------------------------------------------------------

find_chrome() {
    local candidates=(
        "/usr/bin/google-chrome"
        "/usr/bin/google-chrome-stable"
        "/usr/bin/chrome"
        "/usr/bin/chromium"
        "/usr/bin/chromium-browser"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    if command -v google-chrome >/dev/null 2>&1; then
        command -v google-chrome
        return 0
    fi

    if command -v google-chrome-stable >/dev/null 2>&1; then
        command -v google-chrome-stable
        return 0
    fi

    if command -v chromium >/dev/null 2>&1; then
        command -v chromium
        return 0
    fi

    return 1
}

CHROME_BIN="$(find_chrome || true)"

if [[ -z "$CHROME_BIN" ]]; then
    die "Google Chrome/Chromium was not found.

Install Google Chrome first, then run:

    ./install.sh"
fi

success "Browser found: ${CHROME_BIN}"

# -----------------------------------------------------------------------------
# Create directories
# -----------------------------------------------------------------------------

info "Creating directories..."

mkdir -p "${CONFIG_DIR}"
mkdir -p "${SYSTEMD_DIR}"
mkdir -p "${EXTENSION_DIR}"

# -----------------------------------------------------------------------------
# Python virtual environment
# -----------------------------------------------------------------------------

if [[ ! -d "${VENV_DIR}" ]]; then
    info "Creating Python virtual environment..."
    python3 -m venv "${VENV_DIR}"
else
    info "Python virtual environment already exists."
fi

if [[ ! -x "${PYTHON_BIN}" ]]; then
    die "Python virtual environment is invalid: ${VENV_DIR}"
fi

# -----------------------------------------------------------------------------
# Install Python dependencies
# -----------------------------------------------------------------------------

info "Installing Python dependencies..."

"${PIP_BIN}" install --upgrade pip >/dev/null

"${PIP_BIN}" install -r "${PROJECT_DIR}/requirements.txt"

success "Python dependencies installed."

# -----------------------------------------------------------------------------
# Verify Playwright + system Chrome
# -----------------------------------------------------------------------------

info "Testing Playwright with system Chrome..."

if ! "${PYTHON_BIN}" - <<PY
from playwright.sync_api import sync_playwright

chrome = "${CHROME_BIN}"

with sync_playwright() as p:
    browser = p.chromium.launch(
        headless=True,
        executable_path=chrome,
    )
    page = browser.new_page()
    page.goto("https://example.com", wait_until="domcontentloaded", timeout=30000)
    assert page.title()
    browser.close()

print("Playwright + Chrome OK")
PY
then
    die "Playwright could not launch ${CHROME_BIN}."
fi

success "Playwright + system Chrome verified."

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

if [[ ! -f "${CONFIG_INTERVAL}" ]]; then
    echo "300" > "${CONFIG_INTERVAL}"
    info "Default update interval: 5 minutes"
else
    info "Existing update interval preserved."
fi

# -----------------------------------------------------------------------------
# Initial cache
# -----------------------------------------------------------------------------

if [[ ! -f "${CACHE_FILE}" ]]; then
    cat > "${CACHE_FILE}" <<'EOF'
{
  "timestamp": null,
  "tradingeconomics": {
    "crude_oil": {
      "value": null,
      "unit": "USD/BBL"
    },
    "gold": {
      "value": null,
      "unit": "USD/OZ"
    },
    "silver": {
      "value": null,
      "unit": "USD/OZ"
    }
  },
  "wallgold": {
    "gold_18k": {
      "value": null,
      "unit": "TMN"
    }
  },
  "chande": {
    "usd": {
      "value": null,
      "unit": "TMN"
    }
  }
}
EOF
fi

# -----------------------------------------------------------------------------
# Python service
# -----------------------------------------------------------------------------

info "Installing Python market price service..."

chmod +x "${PROJECT_DIR}/market_prices_service.py"
chmod +x "${PROJECT_DIR}/market_scraper.py"

success "Python service ready."

# -----------------------------------------------------------------------------
# systemd user service
# -----------------------------------------------------------------------------

info "Creating systemd user service..."

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Market Prices Collector
After=graphical-session.target
Wants=graphical-session.target

[Service]
Type=simple

WorkingDirectory=${PROJECT_DIR}

ExecStart=${PYTHON_BIN} ${PROJECT_DIR}/market_prices_service.py

Restart=on-failure
RestartSec=10

Environment=HOME=${HOME_DIR}
Environment=USER=${USERNAME}
Environment=MARKET_PRICES_CONFIG_DIR=${CONFIG_DIR}
Environment=MARKET_PRICES_CHROME=${CHROME_BIN}

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

success "systemd service created:"
echo "  ${SERVICE_FILE}"

# -----------------------------------------------------------------------------
# GNOME extension metadata
# -----------------------------------------------------------------------------

info "Creating GNOME extension..."

install -m 644 "${PROJECT_DIR}/extension/metadata.json" \
    "${EXTENSION_DIR}/metadata.json"

# -----------------------------------------------------------------------------
# GNOME extension JavaScript
# -----------------------------------------------------------------------------

install -m 644 "${PROJECT_DIR}/extension/extension.js" \
    "${EXTENSION_DIR}/extension.js"

success "GNOME extension installed:"
echo "  ${EXTENSION_DIR}"

# -----------------------------------------------------------------------------
# systemd reload
# -----------------------------------------------------------------------------

info "Reloading systemd user manager..."

systemctl --user daemon-reload

success "systemd user manager reloaded."

# -----------------------------------------------------------------------------
# Verify extension
# -----------------------------------------------------------------------------

if command -v gnome-extensions >/dev/null 2>&1; then

    if gnome-extensions list | grep -Fxq "${EXTENSION_UUID}"; then
        success "GNOME extension detected: ${EXTENSION_UUID}"
    else
        warning "GNOME extension was installed, but GNOME did not list it yet."
        warning "This can happen if GNOME Shell has not refreshed its extension registry."
        warning "Try:"
        echo
        echo "    gnome-extensions list | grep market-prices"
        echo
    fi
fi

# -----------------------------------------------------------------------------
# Final output
# -----------------------------------------------------------------------------

echo
echo "=============================================================="
echo " Market Prices installation complete"
echo "=============================================================="
echo
echo "User:"
echo "  ${USERNAME}"
echo
echo "Project:"
echo "  ${PROJECT_DIR}"
echo
echo "Python:"
echo "  ${PYTHON_BIN}"
echo
echo "Chrome:"
echo "  ${CHROME_BIN}"
echo
echo "Configuration:"
echo "  ${CONFIG_DIR}"
echo
echo "Update interval:"
echo "  ${CONFIG_INTERVAL}"
echo
echo "Cache:"
echo "  ${CACHE_FILE}"
echo
echo "Systemd:"
echo "  ${SERVICE_FILE}"
echo
echo "GNOME extension:"
echo "  ${EXTENSION_DIR}"
echo
echo "=============================================================="
echo
echo "Commands:"
echo
echo "  make enable"
echo "  make disable"
echo "  make status"
echo "  make logs"
echo "  make restart"
echo "  make interval MINUTES=5"
echo "  make refresh"
echo "  make uninstall"
echo
echo "=============================================================="
echo