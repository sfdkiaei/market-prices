# Market Price Scraper

Extracts:

1. Trading Economics
   - Crude Oil
   - Gold
   - Silver

2. WallGold
   - Gold 18K (`gold18k`), in Iranian toman

3. Chande
   - USD / IRR price, in Iranian toman

## Install

```bash
python -m venv .venv
source .venv/bin/activate

pip install -r requirements.txt
playwright install chromium
```

On Debian/Ubuntu, if Chromium reports missing system libraries:

```bash
playwright install --with-deps chromium
```

## Run

```bash
python market_scraper.py --pretty
```

Save JSON:

```bash
python market_scraper.py --output prices.json --pretty
```

Increase timeout:

```bash
python market_scraper.py --timeout 30 --pretty
```

## Why the implementation is different per website

### Trading Economics

The commodity pages expose the current value as an `Actual` value. The scraper
fetches the three commodity pages and extracts that value.

### WallGold

The supplied HTML contains a site configuration pointing to:

- `/wp-content/uploads/wallgold/prices.json`
- `/wp-json/wgx/v1/data`

and identifies the 18K gold data key as `gold18k`.

The scraper therefore prefers the JSON snapshot instead of depending on the
presentation HTML. If that endpoint is unavailable, it falls back to the
`data-wgx-key="gold18k"` / `data-wgx-field="price"` HTML element.

### Chande

The supplied HTML is a Flutter application. The static HTML itself contains
the `/chart/USD` route but the live price is rendered after the application
loads.

Therefore Chande is scraped with Playwright and Chromium, using the rendered
page text rather than fragile Flutter DOM class names.

## Output example

```json
{
  "timestamp": "2026-09-02T00:00:00+00:00",
  "sources": {
    "tradingeconomics": {
      "crude_oil": {
        "value": 81.03,
        "unit": "USD/BBL"
      },
      "gold": {
        "value": 4608.86,
        "unit": "USD/t.oz"
      },
      "silver": {
        "value": 69.27,
        "unit": "USD/t.oz"
      }
    },
    "wallgold": {
      "value": 22225000,
      "unit": "TMN",
      "currency_name": "تومان"
    },
    "chande": {
      "value": 210000,
      "unit": "TMN",
      "currency_name": "تومان"
    }
  }
}
```

The numeric values in this example are illustrative; the script fetches fresh
values at runtime.

## Production recommendation

For periodic collection, run this script from cron/systemd/Kubernetes and
write each result to a time-series database or append-only JSON/CSV rather
than overwriting the same file.

The script intentionally returns `null` plus an `error` field when one source
fails, so a temporary failure on one website does not discard successful data
from the other sources.
