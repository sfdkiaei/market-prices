#!/usr/bin/env python3

import html
import json
import logging
import re
import sys
import time
from datetime import datetime

import requests


# =============================================================================
# Configuration
# =============================================================================

TRADING_ECONOMICS_URL = "https://tradingeconomics.com/commodities"

WALLGOLD_URL = "https://api.wallgold.ir/api/v1/price?side=buy&symbol=GLD_18C_750TMN"

CHANDE_URL = "https://chande.net/api/v1/prices/USD"

REQUEST_TIMEOUT = 20

# Trading Economics sporadically answers the first request with 403
# before it hands out a session cookie; a couple of retries clear it.
TRADING_ECONOMICS_RETRIES = 3
RETRY_BACKOFF = 2


# =============================================================================
# Logging
# =============================================================================

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
    stream=sys.stderr,
)


# =============================================================================
# Helpers
# =============================================================================


def now_iso() -> str:
    """
    Return local time in ISO-8601 format.
    """
    return datetime.now().astimezone().isoformat(timespec="seconds")


def to_float(value):
    if value is None:
        return None

    if isinstance(value, (int, float)):
        return float(value)

    value = str(value).strip()

    # Remove thousands separators.
    value = value.replace(",", "")

    match = re.search(
        r"[-+]?\d+(?:\.\d+)?",
        value,
    )

    if not match:
        return None

    try:
        return float(match.group())
    except ValueError:
        return None


def create_requests_session():
    session = requests.Session()

    session.headers.update(
        {
            "User-Agent": (
                "Mozilla/5.0 (X11; Linux x86_64) "
                "AppleWebKit/537.36 "
                "(KHTML, like Gecko) "
                "Chrome/151.0.0.0 Safari/537.36"
            ),
            "Accept": "application/json",
        }
    )

    return session


# =============================================================================
# Trading Economics
# =============================================================================

# The commodities table is server-rendered, so a plain HTTP request is
# enough - no browser required. Each row looks like:
#
#   <tr data-symbol="CL1:COM" ...>
#       <td class="datatable-item-first">
#           <a href="/commodity/crude-oil"><b>Crude Oil</b></a>
#           <div style='font-size: 10px;'>USD/Bbl</div>
#       </td>
#       <td id="p" class="datatable-item">91.480</td>
#       ...
#   </tr>

TE_ROW_RE = re.compile(
    r'<tr\s+data-symbol="[^"]+"(.*?)</tr>',
    re.S,
)

TE_NAME_RE = re.compile(
    r"<b>(.*?)</b>",
    re.S,
)

TE_PRICE_RE = re.compile(
    r'<td[^>]*\bid="p"[^>]*>(.*?)</td>',
    re.S,
)


def strip_tags(markup):
    text = re.sub(r"<[^>]+>", " ", markup)

    return html.unescape(text).strip()


def fetch_trading_economics(session):
    """
    Fetch Crude Oil, Gold and Silver from the Trading Economics
    commodities page.

    We read the rendered table markup rather than relying on Trading
    Economics internal JSON endpoints.
    """

    logging.info(
        "Fetching Trading Economics: %s",
        TRADING_ECONOMICS_URL,
    )

    results = {
        "crude_oil": {
            "value": None,
            "unit": "USD/BBL",
        },
        "gold": {
            "value": None,
            "unit": "USD/OZ",
        },
        "silver": {
            "value": None,
            "unit": "USD/OZ",
        },
    }

    wanted = {
        "crude oil": "crude_oil",
        "gold": "gold",
        "silver": "silver",
    }

    markup = None

    for attempt in range(1, TRADING_ECONOMICS_RETRIES + 1):
        response = session.get(
            TRADING_ECONOMICS_URL,
            timeout=REQUEST_TIMEOUT,
            headers={
                "Accept": (
                    "text/html,application/xhtml+xml,"
                    "application/xml;q=0.9,*/*;q=0.8"
                ),
                "Accept-Language": "en-US,en;q=0.9",
            },
        )

        if response.status_code == 200:
            markup = response.text
            break

        logging.warning(
            "Trading Economics returned HTTP %d (attempt %d/%d)",
            response.status_code,
            attempt,
            TRADING_ECONOMICS_RETRIES,
        )

        if attempt < TRADING_ECONOMICS_RETRIES:
            time.sleep(RETRY_BACKOFF)

    if markup is None:
        raise RuntimeError(
            "Trading Economics did not return a usable page after "
            f"{TRADING_ECONOMICS_RETRIES} attempts"
        )

    for row in TE_ROW_RE.findall(markup):
        name_match = TE_NAME_RE.search(row)
        price_match = TE_PRICE_RE.search(row)

        if not name_match or not price_match:
            continue

        key = wanted.get(strip_tags(name_match.group(1)).lower())

        # The first matching row wins; some names reappear further
        # down the page.
        if key is None or results[key]["value"] is not None:
            continue

        value = to_float(strip_tags(price_match.group(1)))

        if value is None:
            continue

        results[key]["value"] = value

        logging.info(
            "Trading Economics %s = %s",
            key,
            value,
        )

    missing = sorted(
        key for key, item in results.items() if item["value"] is None
    )

    if missing:
        logging.warning(
            "Trading Economics values not found: %s",
            ", ".join(missing),
        )

    return results


# =============================================================================
# WallGold
# =============================================================================


def fetch_wallgold(session):
    logging.info(
        "Fetching WallGold: %s",
        WALLGOLD_URL,
    )

    response = session.get(
        WALLGOLD_URL,
        timeout=REQUEST_TIMEOUT,
    )

    response.raise_for_status()

    data = response.json()

    try:
        value = data["result"]["price"]

    except (KeyError, TypeError):
        logging.exception("Unexpected WallGold response")

        value = None

    logging.info(
        "WallGold gold_18k = %s",
        value,
    )

    return {
        "gold_18k": {
            "value": value,
            "unit": "TMN",
        }
    }


# =============================================================================
# Chande
# =============================================================================


def fetch_chande(session):
    logging.info(
        "Fetching Chande: %s",
        CHANDE_URL,
    )

    response = session.get(
        CHANDE_URL,
        timeout=REQUEST_TIMEOUT,
    )

    response.raise_for_status()

    data = response.json()

    # IMPORTANT:
    #
    # priceBuy = Rial price
    # priceToman = Toman price
    #
    # We use priceBuy.

    value = data.get("priceBuy")

    logging.info(
        "Chande USD buy price = %s",
        value,
    )

    return {
        "usd": {
            "value": int(value) // 10,
            "unit": "TMN",
        }
    }


# =============================================================================
# Main collector
# =============================================================================


def collect():
    result = {
        "timestamp": now_iso(),
        "tradingeconomics": {
            "crude_oil": {
                "value": None,
                "unit": "USD/BBL",
            },
            "gold": {
                "value": None,
                "unit": "USD/OZ",
            },
            "silver": {
                "value": None,
                "unit": "USD/OZ",
            },
        },
        "wallgold": {
            "gold_18k": {
                "value": None,
                "unit": "TMN",
            },
        },
        "chande": {
            "usd": {
                "value": None,
                "unit": "TMN",
            },
        },
    }

    session = create_requests_session()

    # -------------------------------------------------------------------------
    # Trading Economics
    # -------------------------------------------------------------------------

    try:
        result["tradingeconomics"] = fetch_trading_economics(session)

    except Exception as exc:
        logging.exception(
            "Trading Economics failed: %s",
            exc,
        )

    # -------------------------------------------------------------------------
    # REST APIs
    # -------------------------------------------------------------------------

    try:
        result["wallgold"] = fetch_wallgold(session)

    except Exception as exc:
        logging.exception(
            "WallGold failed: %s",
            exc,
        )

    try:
        result["chande"] = fetch_chande(session)

    except Exception as exc:
        logging.exception(
            "Chande failed: %s",
            exc,
        )

    return result


# =============================================================================
# Entry point
# =============================================================================

if __name__ == "__main__":
    try:
        result = collect()

        # IMPORTANT:
        # stdout contains ONLY JSON.
        # Logging goes to stderr.

        print(
            json.dumps(
                result,
                ensure_ascii=False,
                indent=2,
            )
        )

    except KeyboardInterrupt:
        sys.exit(130)

    except Exception as exc:
        logging.exception(
            "Fatal error: %s",
            exc,
        )

        sys.exit(1)
