# Market Prices

A GNOME desktop market-price indicator for Linux.

A Python scraper collects prices, a systemd **user** service runs it on an
interval and writes a JSON cache, and a GNOME Shell extension reads that cache
and shows the values in the top bar.

```
market_scraper.py            one-shot scrape, prints JSON to stdout
        |
        v
market_prices_service.py     systemd user service; runs the scraper on a loop,
        |                    merges + writes the cache atomically
        v
~/.config/market-prices/market-prices.json
        |
        v
GNOME extension              top bar label + popup menu (re-reads every 5s)
(market-prices@local)
```

## Tracked prices

| Source | Value | Key in JSON | Unit |
| --- | --- | --- | --- |
| Trading Economics | Crude Oil | `tradingeconomics.crude_oil` | USD/BBL |
| Trading Economics | Gold | `tradingeconomics.gold` | USD/OZ |
| Trading Economics | Silver | `tradingeconomics.silver` | USD/OZ |
| WallGold | Gold 18K (750) | `wallgold.gold_18k` | Toman |
| Chande | USD / IRR | `chande.usd` | Toman |

## Requirements

- Linux with systemd (user services)
- GNOME Shell 42–49 (for the top-bar indicator; the service works without it)
- Python 3

## Install

```bash
git clone https://github.com/sfdkiaei/market-prices.git
cd market-prices
./install.sh
make enable
```

The checkout can live anywhere; nothing assumes a particular path or
username. `install.sh` is idempotent and does the following:

1. Verifies the checkout is complete.
2. Creates `.venv/` and installs `requirements.txt`.
3. Seeds `~/.config/market-prices/` with `update_interval` (default `300`)
   and an empty `market-prices.json`.
4. Writes the systemd unit `~/.config/systemd/user/market-prices.service`,
   pointing at this checkout.
5. Copies `extension/` to
   `~/.local/share/gnome-shell/extensions/market-prices@local/`.

The installer writes nothing into the project directory except `.venv/`.
Because the systemd unit records absolute paths, re-run `./install.sh` if you
move the checkout.

On X11, reload GNOME Shell with <kbd>Alt</kbd>+<kbd>F2</kbd> → `r`. On
Wayland, log out and back in.

## Make targets

| Target | Effect |
| --- | --- |
| `make install` | Run `./install.sh` |
| `make enable` | Start + enable the service and enable the extension |
| `make disable` | Stop the service and disable the extension |
| `make restart` | Restart the service |
| `make status` | `systemctl --user status market-prices.service` |
| `make logs` | Follow the journal for the service |
| `make interval MINUTES=5` | Set the update interval and restart the service |
| `make refresh` | Run the scraper once, printing JSON to the terminal |
| `make service-enable` / `service-disable` | Service only |
| `make extension-enable` / `extension-disable` | Extension only |
| `make uninstall` | Remove the unit, the extension and `~/.config/market-prices/` |

## Running the scraper directly

`market_scraper.py` takes no arguments. It prints one JSON document to stdout;
all logging goes to stderr, so the output is safe to pipe.

```bash
.venv/bin/python market_scraper.py > prices.json
```

## Output format

```json
{
  "timestamp": "2026-09-05T12:26:00+03:30",
  "tradingeconomics": {
    "crude_oil": { "value": 81.03, "unit": "USD/BBL" },
    "gold":      { "value": 4608.86, "unit": "USD/OZ" },
    "silver":    { "value": 69.27, "unit": "USD/OZ" }
  },
  "wallgold": {
    "gold_18k": { "value": 22225000, "unit": "TMN" }
  },
  "chande": {
    "usd": { "value": 210000, "unit": "TMN" }
  }
}
```

The numbers above are illustrative. Any source that fails leaves its
`value` as `null` rather than aborting the run, so one broken website never
discards the other sources.

Iranian values are in **toman** (`TMN`) throughout — Chande's rial `priceBuy`
is divided by 10 at fetch time.

## Why each source is fetched differently

### Trading Economics

The commodities table is server-rendered, so a plain HTTP request is enough
and no browser is involved. The scraper walks the `<tr data-symbol="...">`
rows, matches the row's `<b>` label against `crude oil` / `gold` / `silver`,
and reads the price from that row's `<td id="p">` cell. The first matching
row wins, since some names reappear further down the page. No internal
Trading Economics JSON endpoint is used.

The site sporadically answers the first request with `403` before it hands
out a session cookie, so the fetch is retried a few times; once the session
exists the endpoint is stable.

### WallGold

WallGold exposes a public price API:

```
https://api.wallgold.ir/api/v1/price?side=buy&symbol=GLD_18C_750TMN
```

The price is read from `result.price`.

### Chande

Chande's site is a Flutter application whose static HTML contains no prices,
but it is backed by a JSON API:

```
https://chande.net/api/v1/prices/USD
```

`priceBuy` is in rial and is divided by 10 to give toman.

## Configuration

| What | Where |
| --- | --- |
| Update interval (seconds) | `~/.config/market-prices/update_interval` — default `300`, minimum `10` |
| Price cache | `~/.config/market-prices/market-prices.json` |
| Config dir override | `MARKET_PRICES_CONFIG_DIR` env var (set in the systemd unit) |
| Config dir location | Honours `XDG_CONFIG_HOME`, else `~/.config` |

The interval file is re-read on every loop iteration, so `make interval` takes
effect on the next cycle even without the restart it performs.

### Cache merging

The service deep-merges each scrape into the existing cache and keeps the old
value wherever the new one is `null`. A transient failure therefore leaves the
last known price on screen instead of blanking it, while `timestamp` always
reflects the most recent successful run.

## Repository layout

| File | Role |
| --- | --- |
| `market_scraper.py` | One-shot scraper; the only file you edit to change sources |
| `market_prices_service.py` | Service loop run by systemd |
| `extension/` | GNOME Shell extension (`extension.js`, `metadata.json`) |
| `install.sh` | Installer: venv, systemd unit, extension |
| `Makefile` | Day-to-day commands; derives all paths at runtime |
| `requirements.txt` | Python dependencies, installed into `.venv/` by `install.sh` |

## Troubleshooting

**No indicator in the top bar** — check that the extension is listed and
enabled:

```bash
gnome-extensions list | grep market-prices
gnome-extensions info market-prices@local
```

Then reload GNOME Shell (see [Install](#install)).

**Indicator shows `--`** — the cache has no values yet. Check the service:

```bash
make status
make logs
```

**Trading Economics values are `null`** — run the scraper by hand and read
the log it writes to stderr; a repeated `HTTP 403` means the retries were
exhausted, and a changed table layout shows up as `values not found`:

```bash
make refresh
```

**Extension errors** — GNOME Shell logs them to the journal:

```bash
journalctl --user -f -o cat /usr/bin/gnome-shell
```

## Production note

For long-term collection, point the service at a time-series database or an
append-only JSON/CSV log instead of overwriting a single cache file.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
