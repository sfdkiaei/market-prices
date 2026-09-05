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
#   - Makefile
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

CONFIG_DIR="${HOME_DIR}/.config/market-prices"
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

"${PIP_BIN}" install \
    requests \
    playwright

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
      "unit": "IRR"
    }
  },
  "chande": {
    "usd": {
      "value": null,
      "unit": "IRR"
    }
  }
}
EOF
fi

# -----------------------------------------------------------------------------
# Python service
# -----------------------------------------------------------------------------

info "Creating Python market price service..."

cat > "${PROJECT_DIR}/market_prices_service.py" <<'PYEOF'
#!/usr/bin/env python3

import json
import logging
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from datetime import datetime, timezone


# =============================================================================
# Configuration
# =============================================================================

PROJECT_DIR = Path(__file__).resolve().parent

CONFIG_DIR = Path(
    os.environ.get(
        "MARKET_PRICES_CONFIG_DIR",
        Path.home() / ".config" / "market-prices",
    )
)

INTERVAL_FILE = CONFIG_DIR / "update_interval"
CACHE_FILE = CONFIG_DIR / "market-prices.json"

SCRAPER = PROJECT_DIR / "market_scraper.py"

RUNNING = True


# =============================================================================
# Logging
# =============================================================================

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stderr,
)

logger = logging.getLogger("market-prices")


# =============================================================================
# Signal handling
# =============================================================================

def stop_handler(signum, frame):
    global RUNNING
    logger.info("Received signal %s. Stopping...", signum)
    RUNNING = False


signal.signal(signal.SIGTERM, stop_handler)
signal.signal(signal.SIGINT, stop_handler)


# =============================================================================
# Helpers
# =============================================================================

def get_interval():
    try:
        value = int(INTERVAL_FILE.read_text().strip())

        if value < 10:
            logger.warning(
                "Update interval too small (%s). Using 10 seconds.",
                value,
            )
            return 10

        return value

    except Exception:
        logger.warning(
            "Could not read update interval. Using 300 seconds."
        )
        return 300


def load_cache():
    try:
        with CACHE_FILE.open("r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def deep_merge(old, new):
    """
    Preserve old values when the scraper temporarily returns null.
    """

    if isinstance(old, dict) and isinstance(new, dict):
        result = dict(old)

        for key, value in new.items():
            if key in result:
                result[key] = deep_merge(result[key], value)
            else:
                result[key] = value

        return result

    if new is None:
        return old

    return new


def collect():
    logger.info("Running market scraper...")

    result = subprocess.run(
        [sys.executable, str(SCRAPER)],
        cwd=str(PROJECT_DIR),
        capture_output=True,
        text=True,
        timeout=180,
    )

    if result.stderr:
        for line in result.stderr.splitlines():
            logger.info("[scraper] %s", line)

    if result.returncode != 0:
        raise RuntimeError(
            f"market_scraper.py exited with code "
            f"{result.returncode}"
        )

    stdout = result.stdout.strip()

    if not stdout:
        raise RuntimeError("market_scraper.py returned empty output")

    return json.loads(stdout)


def save_result(result):
    old = load_cache()

    merged = deep_merge(old, result)

    # Always update timestamp when a successful scrape occurred.
    merged["timestamp"] = result.get(
        "timestamp",
        datetime.now(timezone.utc).astimezone().isoformat(),
    )

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    temp_file = CACHE_FILE.with_suffix(".tmp")

    with temp_file.open("w", encoding="utf-8") as f:
        json.dump(
            merged,
            f,
            ensure_ascii=False,
            indent=2,
        )
        f.write("\n")

    temp_file.replace(CACHE_FILE)


# =============================================================================
# Main loop
# =============================================================================

def main():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    logger.info("Market Prices service started")
    logger.info("User: %s", os.environ.get("USER", "unknown"))
    logger.info("Project: %s", PROJECT_DIR)
    logger.info("Config: %s", CONFIG_DIR)
    logger.info("Cache: %s", CACHE_FILE)

    while RUNNING:
        interval = get_interval()

        try:
            result = collect()
            save_result(result)

            logger.info(
                "Prices updated successfully. "
                "Next update in %s seconds.",
                interval,
            )

        except Exception as exc:
            logger.exception("Market price update failed: %s", exc)

        # Sleep in small increments so SIGTERM is handled quickly.
        remaining = interval

        while remaining > 0 and RUNNING:
            time.sleep(min(1, remaining))
            remaining -= 1

    logger.info("Market Prices service stopped.")


if __name__ == "__main__":
    main()
PYEOF

chmod +x "${PROJECT_DIR}/market_prices_service.py"

success "Python service created."

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

cat > "${EXTENSION_DIR}/metadata.json" <<EOF
{
    "uuid": "${EXTENSION_UUID}",
    "name": "Market Prices",
    "description": "Display market prices in the GNOME top bar",
    "version": 1,
    "shell-version": [
        "42",
        "43",
        "44",
        "45",
        "46",
        "47",
        "48",
        "49"
    ]
}
EOF

# -----------------------------------------------------------------------------
# GNOME extension JavaScript
# -----------------------------------------------------------------------------

cat > "${EXTENSION_DIR}/extension.js" <<'JSEOF'
const { GObject, St, Gio, GLib } = imports.gi;
const Main = imports.ui.main;
const PanelMenu = imports.ui.panelMenu;
const PopupMenu = imports.ui.popupMenu;

const CONFIG_DIR =
    GLib.build_filenamev([
        GLib.get_home_dir(),
        ".config",
        "market-prices"
    ]);

const CACHE_FILE =
    GLib.build_filenamev([
        CONFIG_DIR,
        "market-prices.json"
    ]);

const INTERVAL_FILE =
    GLib.build_filenamev([
        CONFIG_DIR,
        "update_interval"
    ]);


function readFile(path) {
    try {
        const file = Gio.File.new_for_path(path);
        const [ok, contents] = file.load_contents(null);

        if (!ok) {
            return null;
        }

        return imports.byteArray.toString(contents);
    } catch (e) {
        return null;
    }
}


function readJson() {
    const content = readFile(CACHE_FILE);

    if (!content) {
        return null;
    }

    try {
        return JSON.parse(content);
    } catch (e) {
        logError(e, "Could not parse market prices JSON");
        return null;
    }
}


function readInterval() {
    const content = readFile(INTERVAL_FILE);

    if (!content) {
        return 300;
    }

    const value = parseInt(content.trim(), 10);

    if (isNaN(value) || value < 10) {
        return 300;
    }

    return value;
}


function formatNumber(value) {
    if (value === null || value === undefined) {
        return "--";
    }

    const number = Number(value);

    if (isNaN(number)) {
        return "--";
    }

    return number.toLocaleString("en-US", {
        maximumFractionDigits: 2
    });
}


function formatUsd(value) {
    if (value === null || value === undefined) {
        return "--";
    }

    const number = Number(value);

    if (isNaN(number)) {
        return "--";
    }

    return "$" + number.toLocaleString("en-US", {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2
    });
}


const MarketPricesIndicator = GObject.registerClass(
class MarketPricesIndicator extends PanelMenu.Button {

    _init() {
        super._init(
            0.0,
            "Market Prices",
            false
        );

        this._label = new St.Label({
            text: "USD -- | 18K -- | Gold --",
            y_align: 2
        });

        this.add_child(this._label);

        this._updateTimer = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT,
            5,
            () => {
                this._refresh();
                return GLib.SOURCE_CONTINUE;
            }
        );

        this._refresh();
    }


    _clearMenu() {
        this.menu.removeAll();
    }


    _addPrice(title, value, unit) {
        const text = value === null || value === undefined
            ? "--"
            : `${formatNumber(value)} ${unit}`;

        const item = new PopupMenu.PopupMenuItem(
            `${title}: ${text}`
        );

        item.reactive = false;

        this.menu.addMenuItem(item);
    }


    _refresh() {
        const data = readJson();

        if (!data) {
            this._label.set_text(
                "USD -- | 18K -- | Gold --"
            );

            this._clearMenu();

            this._addPrice("USD", null, "IRR");
            this._addPrice("18K Gold", null, "IRR");
            this._addPrice("Gold", null, "USD/OZ");

            return GLib.SOURCE_CONTINUE;
        }

        const usd =
            data.chande &&
            data.chande.usd
                ? data.chande.usd.value
                : null;

        const gold18k =
            data.wallgold &&
            data.wallgold.gold_18k
                ? data.wallgold.gold_18k.value
                : null;

        const gold =
            data.tradingeconomics &&
            data.tradingeconomics.gold
                ? data.tradingeconomics.gold.value
                : null;

        const crude =
            data.tradingeconomics &&
            data.tradingeconomics.crude_oil
                ? data.tradingeconomics.crude_oil.value
                : null;

        const silver =
            data.tradingeconomics &&
            data.tradingeconomics.silver
                ? data.tradingeconomics.silver.value
                : null;


        // -------------------------------------------------------------
        // Top bar
        // -------------------------------------------------------------

        this._label.set_text(
            `USD ${formatNumber(usd)} | ` +
            `18K ${formatNumber(gold18k)} | ` +
            `Gold ${formatUsd(gold)}`
        );


        // -------------------------------------------------------------
        // Popup menu
        // -------------------------------------------------------------

        this._clearMenu();

        this._addPrice("USD", usd, "IRR");
        this._addPrice("18K Gold", gold18k, "IRR");
        this._addPrice("Gold", gold, "USD/OZ");

        this.menu.addMenuItem(
            new PopupMenu.PopupSeparatorMenuItem()
        );

        this._addPrice("Crude Oil", crude, "USD/BBL");
        this._addPrice("Silver", silver, "USD/OZ");

        this.menu.addMenuItem(
            new PopupMenu.PopupSeparatorMenuItem()
        );

        const updated =
            data.timestamp
                ? data.timestamp
                : "Unknown";

        const updatedItem =
            new PopupMenu.PopupMenuItem(
                `Updated: ${updated}`
            );

        updatedItem.reactive = false;

        this.menu.addMenuItem(updatedItem);

        return GLib.SOURCE_CONTINUE;
    }


    destroy() {
        if (this._updateTimer) {
            GLib.source_remove(this._updateTimer);
            this._updateTimer = null;
        }

        super.destroy();
    }
});


let indicator = null;


function init() {
}


function enable() {
    indicator = new MarketPricesIndicator();

    Main.panel.addToStatusArea(
        "market-prices",
        indicator,
        1,
        "right"
    );
}


function disable() {
    if (indicator) {
        indicator.destroy();
        indicator = null;
    }
}
JSEOF

success "GNOME extension created:"
echo "  ${EXTENSION_DIR}"

# -----------------------------------------------------------------------------
# Makefile
# -----------------------------------------------------------------------------

info "Creating Makefile..."

cat > "${PROJECT_DIR}/Makefile" <<EOF
# =============================================================================
# Market Prices
# =============================================================================

SERVICE := ${SERVICE_NAME}
EXTENSION := ${EXTENSION_UUID}
PROJECT_DIR := ${PROJECT_DIR}
CONFIG_DIR := ${CONFIG_DIR}
PYTHON := ${PYTHON_BIN}

.PHONY: install enable disable restart status logs interval refresh \
        extension-enable extension-disable service-enable service-disable \
        uninstall

install:
	@./install.sh

enable:
	@echo "Starting market price service..."
	@systemctl --user enable --now \$(SERVICE)
	@echo "Enabling GNOME extension..."
	@gnome-extensions enable \$(EXTENSION)
	@echo "Market prices enabled."

disable:
	@echo "Disabling GNOME extension..."
	@gnome-extensions disable \$(EXTENSION) || true
	@echo "Stopping market price service..."
	@systemctl --user disable --now \$(SERVICE) || true
	@echo "Market prices disabled."

extension-enable:
	@gnome-extensions enable \$(EXTENSION)

extension-disable:
	@gnome-extensions disable \$(EXTENSION) || true

service-enable:
	@systemctl --user enable --now \$(SERVICE)

service-disable:
	@systemctl --user disable --now \$(SERVICE) || true

restart:
	@systemctl --user restart \$(SERVICE)

status:
	@systemctl --user status \$(SERVICE)

logs:
	@journalctl --user -u \$(SERVICE) -f

interval:
	@test -n "\$(MINUTES)" || \
		(echo "Usage: make interval MINUTES=5"; exit 1)
	@echo "\$(( \$(MINUTES) * 60 ))" > "\$(CONFIG_DIR)/update_interval"
	@echo "Update interval set to \$(MINUTES) minutes."
	@systemctl --user restart \$(SERVICE)

refresh:
	@echo "Running scraper..."
	@\$(PYTHON) "\$(PROJECT_DIR)/market_scraper.py"

uninstall:
	@echo "Disabling extension..."
	@gnome-extensions disable \$(EXTENSION) 2>/dev/null || true
	@echo "Stopping service..."
	@systemctl --user disable --now \$(SERVICE) 2>/dev/null || true
	@rm -f "\$(HOME)/.config/systemd/user/\$(SERVICE)"
	@rm -rf "\$(HOME)/.local/share/gnome-shell/extensions/\$(EXTENSION)"
	@rm -rf "\$(CONFIG_DIR)"
	@systemctl --user daemon-reload
	@echo "Market Prices uninstalled."
EOF

success "Makefile created."

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