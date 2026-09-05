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
