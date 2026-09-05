# =============================================================================
# Market Prices
# =============================================================================

SERVICE := market-prices.service
EXTENSION := market-prices@local

# Derived at runtime so this works from any checkout, for any user.
PROJECT_DIR := $(patsubst %/,%,$(dir $(realpath $(firstword $(MAKEFILE_LIST)))))
CONFIG_DIR ?= $(or $(XDG_CONFIG_HOME),$(HOME)/.config)/market-prices
PYTHON := $(PROJECT_DIR)/.venv/bin/python

.PHONY: install enable disable restart status logs interval refresh         extension-enable extension-disable service-enable service-disable         uninstall

install:
	@./install.sh

enable:
	@echo "Starting market price service..."
	@systemctl --user enable --now $(SERVICE)
	@echo "Enabling GNOME extension..."
	@gnome-extensions enable $(EXTENSION)
	@echo "Market prices enabled."

disable:
	@echo "Disabling GNOME extension..."
	@gnome-extensions disable $(EXTENSION) || true
	@echo "Stopping market price service..."
	@systemctl --user disable --now $(SERVICE) || true
	@echo "Market prices disabled."

extension-enable:
	@gnome-extensions enable $(EXTENSION)

extension-disable:
	@gnome-extensions disable $(EXTENSION) || true

service-enable:
	@systemctl --user enable --now $(SERVICE)

service-disable:
	@systemctl --user disable --now $(SERVICE) || true

restart:
	@systemctl --user restart $(SERVICE)

status:
	@systemctl --user status $(SERVICE)

logs:
	@journalctl --user -u $(SERVICE) -f

interval:
	@test -n "$(MINUTES)" || 		(echo "Usage: make interval MINUTES=5"; exit 1)
	@echo "$$(( $(MINUTES) * 60 ))" > "$(CONFIG_DIR)/update_interval"
	@echo "Update interval set to $(MINUTES) minutes."
	@systemctl --user restart $(SERVICE)

refresh:
	@echo "Running scraper..."
	@$(PYTHON) "$(PROJECT_DIR)/market_scraper.py"

uninstall:
	@echo "Disabling extension..."
	@gnome-extensions disable $(EXTENSION) 2>/dev/null || true
	@echo "Stopping service..."
	@systemctl --user disable --now $(SERVICE) 2>/dev/null || true
	@rm -f "$(HOME)/.config/systemd/user/$(SERVICE)"
	@rm -rf "$(HOME)/.local/share/gnome-shell/extensions/$(EXTENSION)"
	@rm -rf "$(CONFIG_DIR)"
	@systemctl --user daemon-reload
	@echo "Market Prices uninstalled."
