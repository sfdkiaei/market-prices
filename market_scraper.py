#!/usr/bin/env python3

import json
import logging
import os
import re
import shutil
import sys
import time
from datetime import datetime

import requests
from playwright.sync_api import sync_playwright


# =============================================================================
# Configuration
# =============================================================================

TRADING_ECONOMICS_URL = "https://tradingeconomics.com/commodities"

WALLGOLD_URL = "https://api.wallgold.ir/api/v1/price?side=buy&symbol=GLD_18C_750TMN"

CHANDE_URL = "https://chande.net/api/v1/prices/USD"

REQUEST_TIMEOUT = 20
BROWSER_TIMEOUT = 30

# An existing Chrome/Chromium installation is used; Playwright never
# downloads its own browser. Set MARKET_PRICES_CHROME to override the
# autodetected path.
CHROME_CANDIDATES = (
    "google-chrome",
    "google-chrome-stable",
    "chromium",
    "chromium-browser",
    "chrome",
)


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
# Chrome / Playwright
# =============================================================================


def find_chrome():
    """
    Locate an installed Chrome/Chromium binary.

    MARKET_PRICES_CHROME wins if it is set; the installer puts the browser
    it detected there via the systemd unit.
    """

    override = os.environ.get("MARKET_PRICES_CHROME")

    if override:
        if not os.access(override, os.X_OK):
            raise RuntimeError(
                f"MARKET_PRICES_CHROME is not executable: {override}"
            )

        return override

    for name in CHROME_CANDIDATES:
        path = shutil.which(name)

        if path:
            return path

    raise RuntimeError(
        "No Chrome/Chromium binary found. Install Google Chrome or "
        "Chromium, or set MARKET_PRICES_CHROME to its path."
    )


def create_browser(playwright):
    """
    Launch the existing Chrome/Chromium installation.

    No Playwright-managed Chromium and no ChromeDriver are required.
    """

    chrome_binary = find_chrome()

    logging.info(
        "Launching browser: %s",
        chrome_binary,
    )

    browser = playwright.chromium.launch(
        executable_path=chrome_binary,
        headless=True,
        args=[
            "--no-sandbox",
            "--disable-dev-shm-usage",
            "--disable-gpu",
            "--window-size=1920,1080",
            "--disable-blink-features=AutomationControlled",
            "--lang=en-US",
        ],
    )

    return browser


# =============================================================================
# Trading Economics
# =============================================================================


def extract_trading_economics(page):
    """
    Extract Crude Oil, Gold and Silver from the rendered
    Trading Economics commodities page.

    We intentionally inspect rendered DOM/table content instead
    of relying on Trading Economics internal JSON endpoints.
    """

    logging.info(
        "Opening Trading Economics in Chrome: %s",
        TRADING_ECONOMICS_URL,
    )

    page.goto(
        TRADING_ECONOMICS_URL,
        wait_until="domcontentloaded",
        timeout=BROWSER_TIMEOUT * 1000,
    )

    logging.info(
        "Trading Economics page loaded: %s",
        page.url,
    )

    # Allow dynamic content to settle.
    page.wait_for_timeout(3000)

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

    # -------------------------------------------------------------------------
    # First approach: inspect table rows.
    # -------------------------------------------------------------------------

    rows = page.locator("table tr")

    row_count = rows.count()

    logging.info(
        "Found %d table rows",
        row_count,
    )

    for index in range(row_count):
        try:
            row = rows.nth(index)

            cells = row.locator("th, td")

            cell_count = cells.count()

            if cell_count == 0:
                continue

            texts = []

            for cell_index in range(cell_count):
                text = cells.nth(cell_index).inner_text().strip()
                texts.append(text)

            if not texts:
                continue

            first_cell = texts[0].lower().strip()

            for name, key in wanted.items():
                if first_cell != name:
                    continue

                logging.info(
                    "Found Trading Economics row: %s",
                    texts,
                )

                # Usually:
                #
                # [Crude Oil, USD/Bbl, 90.60, ...]
                #
                # or:
                #
                # [Crude Oil, USD/Bbl, 90.60, 0.123, ...]

                for text in texts[1:]:
                    # Skip units.
                    if "/" in text:
                        continue

                    value = to_float(text)

                    if value is not None:
                        results[key]["value"] = value

                        logging.info(
                            "Trading Economics %s = %s",
                            key,
                            value,
                        )

                        break

        except Exception:
            continue

    # -------------------------------------------------------------------------
    # Second approach: inspect all visible page text.
    #
    # This handles cases where Trading Economics doesn't expose
    # the data in a conventional <table>.
    # -------------------------------------------------------------------------

    missing = [key for key, value in results.items() if value["value"] is None]

    if missing:
        logging.info(
            "Some Trading Economics values were not found in tables. "
            "Trying rendered page text."
        )

        try:
            body_text = page.locator("body").inner_text()
        except Exception:
            body_text = ""

        lines = [line.strip() for line in body_text.splitlines() if line.strip()]

        for i, line in enumerate(lines):
            normalized = line.lower().strip()

            for name, key in wanted.items():
                if key not in missing:
                    continue

                if normalized != name:
                    continue

                # Search following lines.
                for candidate in lines[i + 1 : i + 8]:
                    # Don't accidentally interpret a unit as a value.
                    if "/" in candidate:
                        continue

                    value = to_float(candidate)

                    if value is not None:
                        results[key]["value"] = value

                        logging.info(
                            "Trading Economics %s = %s",
                            key,
                            value,
                        )

                        break

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

    # -------------------------------------------------------------------------
    # Trading Economics
    # -------------------------------------------------------------------------

    try:
        with sync_playwright() as playwright:
            browser = None

            try:
                browser = create_browser(playwright)

                context = browser.new_context(
                    viewport={
                        "width": 1920,
                        "height": 1080,
                    },
                    locale="en-US",
                    user_agent=(
                        "Mozilla/5.0 (X11; Linux x86_64) "
                        "AppleWebKit/537.36 "
                        "(KHTML, like Gecko) "
                        "Chrome/151.0.0.0 Safari/537.36"
                    ),
                )

                page = context.new_page()

                result["tradingeconomics"] = extract_trading_economics(page)

            finally:
                if browser is not None:
                    try:
                        browser.close()
                    except Exception:
                        pass

    except Exception as exc:
        logging.exception(
            "Trading Economics failed: %s",
            exc,
        )

    # -------------------------------------------------------------------------
    # REST APIs
    # -------------------------------------------------------------------------

    session = create_requests_session()

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
