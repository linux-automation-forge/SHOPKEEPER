# shopkeep.sh — offline POS + inventory for kirana stores

A single-file Bash point-of-sale and inventory system for small retail shops.
No cloud. No database. No internet required. All data lives in **plain CSV
files that open directly in Excel**. Now with **23 UI languages** (English +
22 scheduled Indian languages).

---

## Where are my files stored?

Everything is under **`./shopkeep-data/`** (next to the script), gitignored.
The interactive menu shows this path at the top every time, and `--doctor`
prints the full path of every file:

```
Data directory:    /your/path/shopkeep-data
products.csv:      /your/path/shopkeep-data/products.csv       ← your product catalog + stock
bills.csv:         /your/path/shopkeep-data/bills.csv          ← the sales ledger (every line item)
inventory_log.csv: /your/path/shopkeep-data/inventory_log.csv  ← audit trail (who added what, when)
state:             /your/path/shopkeep-data/state             ← next bill number
config:            /your/path/shopkeep-data/shopkeep.conf      ← shop name, threshold, language
labels:            /your/path/labels/<barcode>.png            ← printable barcodes (if zint installed)
backups:           /your/path/backups/shopkeep-<ts>.tar.gz    ← last 14 backups
```

To open in Excel: just double-click `products.csv` or `bills.csv`. They are
standard CSV with proper quoting (product names with commas and quotes are
handled correctly).

> Tip: run `./shopkeep.sh --doctor` any time to see all file paths and counts.

---

## Quick start

```bash
chmod +x shopkeep.sh
./shopkeep.sh              # interactive menu (shows file paths on screen)
./shopkeep.sh --doctor     # check dependencies + see where files live
```

---

## Interactive menu (no arguments)

The menu now shows your data directory and has 8 options:

```
=== My Kirana Store ===
 Data directory: /your/path/shopkeep-data
 1) New bill            5) Void a bill
 2) Add product         6) Backup now
 3) Low stock report    7) Stock value
 4) Daily sales summary 8) Language
 0) Exit
```

---

## Languages (23 total)

The shopkeeper can pick their own language. India has 22 scheduled languages
plus English — all 23 are supported:

| # | Code | Language    | | # | Code | Language   |
|---|------|-------------|---|---|------|-----------|
| 1 | en   | English     | | 13| mai  | Maithili  |
| 2 | hi   | हिन्दी       | | 14| sa   | Sanskrit  |
| 3 | bn   | বাংলা        | | 15| ne   | Nepali    |
| 4 | te   | తెలుగు        | | 16| sd   | Sindhi    |
| 5 | mr   | मराठी        | | 17| kok  | Konkani   |
| 6 | ta   | தமிழ்        | | 18| doi  | Dogri     |
| 7 | ur   | اردو        | | 19| mni  | Manipuri  |
| 8 | gu   | ગુજરાતી       | | 20| sat  | Santali   |
| 9 | kn   | ಕನ್ನಡ         | | 21| brx  | Bodo      |
|10 | or   | ଓଡ଼ିଆ         | | 22| bho  | Bhojpuri  |
|11 | ml   | മലയാളം        | |   |      |           |
|12 | pa   | ਪੰਜਾਬੀ        | |   |      |           |

Set via menu option **8**, or from the command line:

```bash
./shopkeep.sh lang hi     # Hindi
./shopkeep.sh lang ta     # Tamil
./shopkeep.sh lang        # show current + full list
```

The choice is saved in `shopkeep.conf` and remembered next launch.

**Important:** CSV column names and bill rows stay English so that audits and
Excel exports are identical regardless of language. Only the interactive UI
(menu, prompts, receipt labels like TOTAL/Items/Units) is translated.

> Note: rendering Indian scripts (Devanagari, Tamil, Bengali, Ol Chiki, …)
> needs a UTF-8 terminal with the appropriate fonts. If a script doesn't
> render, fall back to `en`. The ₹ symbol is used in UTF-8 locales, `Rs` otherwise.

---

## How a bill is generated (the billing flow)

1. **Menu → 1) New bill** (or `printf 'barcode qty\n' | ./shopkeep.sh bill`).
2. For each item, **scan or type the barcode**:
   - Type the digits, e.g. `8901234567890`.
   - Or, if the item has no barcode / scanner, type `s:parle` to **search by
     name** and pick the matching product by number.
   - Press **Enter on a blank line** to finish the bill.
3. Enter the **quantity** (default 1). The script checks you have enough in
   stock — it will **never sell more than you have** (no negative stock).
4. The bill is committed **atomically**:
   - All line items are appended to `bills.csv` FIRST (one row per line item,
     with the product name and unit price copied in — so old bills stay
     correct even if you change the price later).
   - Then stock is decremented in `products.csv` (atomic rewrite via
     `products.csv.new` → `mv`, under a `flock` lock).
   - If the stock update ever fails, VOID reversal rows are appended so the
     ledger can never lie.
   - The bill number is incremented under lock (two terminals can't get the
     same number).
5. A **box-drawing receipt** is printed with the shop name, bill no,
   timestamp, each line (`name x qty` + line total), the TOTAL, and unit/item
   counts.

Every bill row in `bills.csv` looks like:
```
bill_no,timestamp,barcode,name,qty,unit_price_paise,line_total,action
1,2025-01-10 10:00:00,8901234567890,Tata Salt 1kg,2,2500,5000,SELL
```
One row **per line item**, not per bill — same way real POS databases work.

---

## What is "threshold"?

`threshold` is the **low-stock reorder point** for each product. When the
current `qty` falls to or below `threshold`, the product appears in the
**Low stock report** (menu option 3 / `./shopkeep.sh lowstock`), sorted by how
bad the shortage is (biggest deficit first), color-coded:

- 🔴 **red** — qty is 0 (out of stock, reorder now)
- 🟡 **yellow** — qty below threshold
- 🔵 **cyan** — qty exactly at threshold (about to run out)

Example: if you set `threshold=8` for "Tata Salt 1kg" and you have 24 in stock,
it won't warn you. Sell down to 8 and it appears in the report. Hit 0 and it
shows red.

Set the default threshold in `shopkeep.conf` (`default_threshold=8`), or per
product with `--threshold` when adding.

---

## Stock value (total worth of items in storage)

Menu option **7** / `./shopkeep.sh stockvalue` computes the **total retail
value of everything currently in storage** — `sum of (price × qty)` across all
products — and shows a per-product table sorted by value. This is the
"capital sitting on your shelves" number. Each run also logs a `STOCKVALUE`
snapshot to `inventory_log.csv`.

---

## Inventory activity log (which item was added, and when)

`inventory_log.csv` is an **append-only audit trail** of stock events:

```
timestamp,event,barcode,name,qty,price_paise,detail
2025-01-10 10:00:00,ADD,8901,Tata Salt 1kg,24,2500,"new product, threshold=8"
2025-01-10 10:05:00,STOCKVALUE,-,all,-,87100,"inventory valuation snapshot"
2025-01-10 11:00:00,VOID,8901,Tata Salt 1kg,2,2500,"voided bill #1"
```

Events logged: `ADD` (product added), `VOID` (bill voided, per line item),
`STOCKVALUE` (valuation snapshot). Sales themselves live in `bills.csv`.

View the last entries with:
```bash
./shopkeep.sh inventorylog        # last 25
./shopkeep.sh inventorylog 50     # last 50
```

---

## Barcodes and QR / labels

- **Scanning:** if `zbarcam` is installed and a webcam is available, you can
  scan a product barcode with the webcam during "Add product". Otherwise just
  **type the barcode digits** — both paths store the product keyed by
  barcode in `products.csv`.
- **No barcode on the product?** Leave it blank → an **internal EAN-13** in
  the `2000000000000–2999999999999` range is auto-generated (EAN-13 prefix
  20–29 is the **globally reserved in-store range** real POS systems use), so
  every product is scannable.
- **Printing labels:** if `zint` is installed, "Add product" offers to render
  a **Code128** PNG to `labels/<barcode>.png` you can print and stick on the
  item. (The script uses `zint` for Code128, which most retail USB scanners
  read. QR codes aren't used because standard POS scanners read Code128/EAN,
  not QR — but `zint` can also produce QR if you extend the script.)

In this sandbox there is no webcam, so `zbarcam` is OFF — you type barcodes,
which works perfectly and stores values by barcode exactly the same way.

---

## Non-interactive (cron / scripting friendly)

```bash
# Add a product
./shopkeep.sh add --name "Tata Salt 1kg" --price 25.00 --qty 24 --barcode 8901234567890 --threshold 8
./shopkeep.sh add --name "Parle-G" --price 5 --qty 50      # auto barcode, default threshold

# Bill: feed "barcode qty" lines on stdin (qty defaults to 1)
printf '8901234567890 2\n8901234567891 1\n' | ./shopkeep.sh bill

# Reports
./shopkeep.sh lowstock
./shopkeep.sh stockvalue
./shopkeep.sh summary
./shopkeep.sh summary 2025-01-15
./shopkeep.sh inventorylog

# Fix a mistake (append-only — never deletes)
./shopkeep.sh void 7

# Backup (cron-friendly: tar.gz of shopkeep-data/, keep last 14)
./shopkeep.sh backup

# Language
./shopkeep.sh lang hi
```

---

## Data file schemas

### products.csv  (rewritten atomically on stock changes)
```
barcode,name,price_paise,qty,threshold
```
- `barcode` — digits only, the unique key. Internal 20-prefix EAN-13 if none.
- `price_paise` — integer paise (Rs 25.00 = 2500). No floats anywhere.
- Names may contain commas and quotes (RFC-4180-style CSV quoting).

### bills.csv  (append-only ledger — rows are NEVER edited or deleted)
```
bill_no,timestamp,barcode,name,qty,unit_price_paise,line_total,action
```
- One row per line item. `name` + `unit_price_paise` copied in for audit
  history (old bills stay correct after price changes).
- `action` is `SELL` or `VOID`. Voiding appends `VOID` rows + restores stock.

### inventory_log.csv  (append-only audit trail)
```
timestamp,event,barcode,name,qty,price_paise,detail
```
- Events: `ADD`, `VOID`, `STOCKVALUE`.

### state
```
next_bill_no=N
```

### shopkeep.conf
```
shop_name=My Kirana Store
default_threshold=8
lang=en
```

---

## How integrity is guaranteed

- **Money is integer paise.** "25.5" → exactly 2550. Zero rounding drift.
- **Every read-modify-write is `flock`-guarded** — two terminals can't
  double-sell stock (verified by a 10-parallel-bill stress test).
- **Atomic catalog rewrite:** `products.csv.new` → `mv` (rename is atomic on
  the same filesystem). A crash never leaves a half-written catalog.
- **Append-only ledger:** each `bills.csv` row is one `printf` append. Rows
  are never edited or deleted.
- **Billing atomicity:** SELL rows appended first, then stock decremented; if
  the stock update fails, VOID reversal rows are appended.
- **trap cleanup on EXIT:** no `.new` files or stale locks left behind.

---

## Dependencies

| Tool     | Purpose              | Required? | Install                       |
|----------|----------------------|-----------|-------------------------------|
| bash 4+  | runtime              | required  | (most systems have it)        |
| coreutils | file ops            | required  | `sudo apt install coreutils`  |
| awk     | reports              | required  | `sudo apt install gawk`       |
| flock    | locking              | required  | `sudo apt install util-linux` |
| zbarcam  | webcam barcode scan  | optional  | `sudo apt install zbar-tools` |
| zint     | print label PNGs     | optional  | `sudo apt install zint`       |
| tar      | backups              | optional  | `sudo apt install tar`        |

All optional tools degrade gracefully. Run `./shopkeep.sh --doctor` for a
full status report including which features are active/disabled and where
every data file lives.

---

## Backups

`./shopkeep.sh backup` (menu option 6) writes `backups/shopkeep-<timestamp>.tar.gz`
of `shopkeep-data/` and keeps the last 14. A backup also runs automatically on
the first menu launch of each new day.

---

## Honest limitations (v1 non-goals — by design)

- No taxes / discounts / customer CRM.
- No multi-terminal UI (the data model is concurrency-safe so this can be
  added later without migration).
- No multi-currency.
- Receipts print to stdout (pipe `bill` output to `lp` for paper).
- Translations cover the core interactive UI; some error messages and CSV
  data remain in English by design (audits stay consistent across languages).

These data formats were chosen so all of the above can be added later
**without any data migration**.

---

## License

MIT. See `shopkeep.requirements.txt` for the dependency list.
