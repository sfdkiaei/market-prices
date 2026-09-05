const { St, Gio, GLib } = imports.gi;

const Main = imports.ui.main;
const PanelMenu = imports.ui.panelMenu;
const PopupMenu = imports.ui.popupMenu;


const DATA_FILE =
    "/home/farid/src/market_scraper/market-prices.json";

const REFRESH_SECONDS = 5;


class MarketPricesIndicator extends PanelMenu.Button {

    _init() {

        super._init(
            0.0,
            "Market Prices"
        );

        this.label = new St.Label({
            text: "USD -- | 18K -- | Gold --",
            y_align: 2,
        });

        this.add_child(
            this.label
        );

        this._buildMenu();

        this._timeoutId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT,
            REFRESH_SECONDS,
            () => {

                this._loadData();

                return GLib.SOURCE_CONTINUE;
            }
        );

        this._loadData();
    }


    // =========================================================================
    // Menu
    // =========================================================================

    _buildMenu() {

        this.menu.removeAll();

        this._oilItem =
            new PopupMenu.PopupMenuItem(
                "Crude Oil: --"
            );

        this._goldItem =
            new PopupMenu.PopupMenuItem(
                "Gold: --"
            );

        this._silverItem =
            new PopupMenu.PopupMenuItem(
                "Silver: --"
            );

        this._wallgoldItem =
            new PopupMenu.PopupMenuItem(
                "18K Gold: --"
            );

        this._usdItem =
            new PopupMenu.PopupMenuItem(
                "USD: --"
            );

        this._updatedItem =
            new PopupMenu.PopupMenuItem(
                "Updated: --",
                {
                    reactive: false,
                }
            );

        this._statusItem =
            new PopupMenu.PopupMenuItem(
                "Status: --",
                {
                    reactive: false,
                }
            );


        this.menu.addMenuItem(
            this._usdItem
        );

        this.menu.addMenuItem(
            this._wallgoldItem
        );

        this.menu.addMenuItem(
            this._goldItem
        );

        this.menu.addMenuItem(
            new PopupMenu.PopupSeparatorMenuItem()
        );

        this.menu.addMenuItem(
            this._oilItem
        );

        this.menu.addMenuItem(
            this._silverItem
        );

        this.menu.addMenuItem(
            new PopupMenu.PopupSeparatorMenuItem()
        );

        this.menu.addMenuItem(
            this._updatedItem
        );

        this.menu.addMenuItem(
            this._statusItem
        );
    }


    // =========================================================================
    // File reading
    // =========================================================================

    _loadData() {

        let file =
            Gio.file_new_for_path(
                DATA_FILE
            );

        try {

            file.load_contents_async(
                null,
                (source, result) => {

                    try {

                        let [
                            success,
                            contents
                        ] =
                            source.load_contents_finish(
                                result
                            );

                        if (!success) {
                            this._showError(
                                "Unable to read data"
                            );
                            return;
                        }

                        let decoder =
                            new TextDecoder(
                                "utf-8"
                            );

                        let text =
                            decoder.decode(
                                contents
                            );

                        let data =
                            JSON.parse(text);

                        this._update(
                            data
                        );

                    } catch (e) {

                        logError(
                            e,
                            "Failed to parse market-prices.json"
                        );

                        this._showError(
                            "Invalid data"
                        );
                    }
                }
            );

        } catch (e) {

            logError(
                e,
                "Failed to read market price file"
            );

            this._showError(
                "No data"
            );
        }
    }


    // =========================================================================
    // Formatting
    // =========================================================================

    _format(value, decimals = 0) {

        if (
            value === null ||
            value === undefined
        ) {
            return "--";
        }

        return Number(value).toLocaleString(
            "en-US",
            {
                minimumFractionDigits:
                    decimals,

                maximumFractionDigits:
                    decimals,
            }
        );
    }


    _formatTime(timestamp) {

        if (!timestamp) {
            return "--";
        }

        try {

            let date =
                new Date(timestamp);

            return date.toLocaleTimeString(
                "en-US",
                {
                    hour: "2-digit",
                    minute: "2-digit",
                    second: "2-digit",
                }
            );

        } catch (e) {

            return "--";
        }
    }


    // =========================================================================
    // Update UI
    // =========================================================================

    _update(data) {

        const te =
            data.tradingeconomics || {};

        const wallgold =
            data.wallgold || {};

        const chande =
            data.chande || {};


        const usd =
            chande.usd?.value;

        const gold18k =
            wallgold.gold_18k?.value;

        const gold =
            te.gold?.value;

        const oil =
            te.crude_oil?.value;

        const silver =
            te.silver?.value;


        // ---------------------------------------------------------------------
        // DEFAULT TOP BAR VALUES
        // ---------------------------------------------------------------------

        this.label.set_text(
            `USD ${this._format(usd)}  |  ` +
            `18K ${this._format(gold18k)}  |  ` +
            `Gold $${this._format(gold, 2)}`
        );


        // ---------------------------------------------------------------------
        // CLICK MENU
        // ---------------------------------------------------------------------

        this._usdItem.label.text =
            `USD: ${this._format(usd)} IRR`;

        this._wallgoldItem.label.text =
            `18K Gold: ${this._format(gold18k)} IRR`;

        this._goldItem.label.text =
            `Gold: $${this._format(gold, 2)}/OZ`;

        this._oilItem.label.text =
            `Crude Oil: $${this._format(oil, 2)}/BBL`;

        this._silverItem.label.text =
            `Silver: $${this._format(silver, 2)}/OZ`;


        this._updatedItem.label.text =
            `Updated: ${this._formatTime(
                data.timestamp
            )}`;


        this._statusItem.label.text =
            "Status: OK";
    }


    // =========================================================================
    // Error state
    // =========================================================================

    _showError(message) {

        this._statusItem.label.text =
            `Status: ${message}`;

        // Don't destroy or clear the existing prices.
        //
        // The last successful values remain visible.
    }


    // =========================================================================
    // Cleanup
    // =========================================================================

    destroy() {

        if (
            this._timeoutId !== null
        ) {

            GLib.source_remove(
                this._timeoutId
            );

            this._timeoutId = null;
        }

        super.destroy();
    }
}


let indicator = null;


function init() {
}


function enable() {

    indicator =
        new MarketPricesIndicator();

    Main.panel.addToStatusArea(
        "market-prices",
        indicator,
        1,
        "right"
    );
}


function disable() {

    if (indicator !== null) {

        indicator.destroy();

        indicator = null;
    }
}