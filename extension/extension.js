const { GObject, St, Gio, GLib } = imports.gi;

const Main = imports.ui.main;
const PanelMenu = imports.ui.panelMenu;
const PopupMenu = imports.ui.popupMenu;


// The service writes here. GLib resolves XDG_CONFIG_HOME when it is set,
// and falls back to ~/.config otherwise.
const CONFIG_DIR =
    GLib.build_filenamev([
        GLib.get_user_config_dir(),
        "market-prices"
    ]);

const CACHE_FILE =
    GLib.build_filenamev([
        CONFIG_DIR,
        "market-prices.json"
    ]);

// The cache is a local file, so polling it is cheap. This is only how often
// the panel picks up new values, not how often prices are fetched.
const REFRESH_SECONDS = 5;

const PLACEHOLDER = "USD -- | 18K -- | Gold --";


function readJson(path) {
    try {
        const file = Gio.File.new_for_path(path);
        const [ok, contents] = file.load_contents(null);

        if (!ok) {
            return null;
        }

        const text = new TextDecoder("utf-8").decode(contents);

        return JSON.parse(text);

    } catch (e) {
        // A missing file is normal before the first scrape completes.
        return null;
    }
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


function formatTime(timestamp) {
    if (!timestamp) {
        return "--";
    }

    try {
        return new Date(timestamp).toLocaleTimeString("en-US", {
            hour: "2-digit",
            minute: "2-digit",
            second: "2-digit"
        });

    } catch (e) {
        return "--";
    }
}


function pick(section, key) {
    if (!section || !section[key]) {
        return null;
    }

    const entry = section[key];

    return entry.value === undefined ? null : entry.value;
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
            text: PLACEHOLDER,
            y_align: 2
        });

        this.add_child(this._label);

        this._updateTimer = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT,
            REFRESH_SECONDS,
            () => {
                this._refresh();
                return GLib.SOURCE_CONTINUE;
            }
        );

        this._refresh();
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
        const data = readJson(CACHE_FILE);

        this.menu.removeAll();

        if (!data) {
            this._label.set_text(PLACEHOLDER);

            this._addPrice("USD", null, "TMN");
            this._addPrice("18K Gold", null, "TMN");
            this._addPrice("Gold", null, "USD/OZ");

            this.menu.addMenuItem(
                new PopupMenu.PopupSeparatorMenuItem()
            );

            const waiting = new PopupMenu.PopupMenuItem(
                "Waiting for first update..."
            );

            waiting.reactive = false;

            this.menu.addMenuItem(waiting);

            return GLib.SOURCE_CONTINUE;
        }

        const te = data.tradingeconomics;

        const usd = pick(data.chande, "usd");
        const gold18k = pick(data.wallgold, "gold_18k");
        const gold = pick(te, "gold");
        const crude = pick(te, "crude_oil");
        const silver = pick(te, "silver");


        // ---------------------------------------------------------------
        // Top bar
        // ---------------------------------------------------------------

        this._label.set_text(
            `USD ${formatNumber(usd)} | ` +
            `18K ${formatNumber(gold18k)} | ` +
            `Gold ${formatUsd(gold)}`
        );


        // ---------------------------------------------------------------
        // Popup menu
        // ---------------------------------------------------------------

        this._addPrice("USD", usd, "TMN");
        this._addPrice("18K Gold", gold18k, "TMN");
        this._addPrice("Gold", gold, "USD/OZ");

        this.menu.addMenuItem(
            new PopupMenu.PopupSeparatorMenuItem()
        );

        this._addPrice("Crude Oil", crude, "USD/BBL");
        this._addPrice("Silver", silver, "USD/OZ");

        this.menu.addMenuItem(
            new PopupMenu.PopupSeparatorMenuItem()
        );

        const updatedItem = new PopupMenu.PopupMenuItem(
            `Updated: ${formatTime(data.timestamp)}`
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
