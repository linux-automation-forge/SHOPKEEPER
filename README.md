# shopkeep.sh — offline POS + inventory for kirana stores

A single-file Bash point-of-sale and inventory system for small retail shops.
No cloud. No database. No internet required. All data lives in plain CSV files
that open directly in Excel.

## User story

Sunita runs a kirana store. Her old laptop has no internet most of the day. She
needs to: ring up sales quickly, know what's running low, see how much she sold
today, fix a mistake she made on a bill, and never lose her data if the power
cuts out mid-sale. `shopkeep.sh` does exactly that, and nothing more — on
purpose.

## Quick start

```bash
chmod +x shopkeep.sh
./shopkeep.sh              # interactive menu
./shopkeep.sh --doctor     # check dependencies
```

## Usage

### Interactive menu (no arguments)

```
 1) 🧾 New bill      2) ➕ Add product    3) ✏️ Manage product
 4) 🔍 Search        5) 📦 Inventory      6) ⚠️ Low stock
 7) 📊 Summary       8) ↩️ Void           9) 💰 Stock value
10) 🧺 Trays        11) 💾 Backup       12) 🌐 Language    0) 🚪 Exit
```

### Non-interactive (cron / scripting friendly)

```bash
# Add a product (barcode auto-assigned if omitted; internal 20-prefix EAN-13)
./shopkeep.sh add --name "Tata Salt 1kg" --price 25.00 --qty 24
./shopkeep.sh add --name "Parle-G" --price 5 --qty 50 --barcode 8901234567890 --threshold 10

# Bill: feed "barcode qty" lines on stdin (qty defaults to 1 if omitted)
printf '8901234567890 2\n8901234567891 1\n' | ./shopkeep.sh bill

# Low stock report
./shopkeep.sh lowstock

# Stock inventory — grouped under category trays, or sorted
./shopkeep.sh inventory
./shopkeep.sh inventory price

# Category trays (categories of products, each with its own emoji + barcode)
./shopkeep.sh category list
./shopkeep.sh category add "Cosmetics" "💄"

# Daily summary (default: today)
./shopkeep.sh summary
./shopkeep.sh summary 2025-01-15

# Void a bill (append-only — nothing is ever deleted)
./shopkeep.sh void 7

# Maintenance
./shopkeep.sh --doctor
./shopkeep.sh --selftest
./shopkeep.sh --gen-files
./shopkeep.sh -h
./shopkeep.sh -V
```

## Data file schemas (under `./shopkeep-data/`)

### products.csv  (rewritten atomically on stock changes)
```
barcode,name,price_paise,qty,threshold,description,type,image
```
- `type` is the product's CATEGORY — it files the product into its category
  tray. Unknown types auto-create a tray with a matching emoji.
- `barcode` — digits only, the unique key. Products without a manufacturer
  barcode get an internal code in the **2000000000000–2999999999999** range
  (EAN-13 prefix 20–29 is the globally reserved in-store range — same trick
  real POS systems use), so every product is scannable.
- `price_paise` — integer paise (Rs 25.00 = 2500). No floats anywhere.
- Names may contain commas and quotes (proper RFC-4180-style CSV quoting).

### bills.csv  (append-only ledger — rows are NEVER edited or deleted)
```
bill_no,timestamp,barcode,name,qty,unit_price_paise,line_total,action
```
- ONE ROW PER LINE ITEM, not per bill (mirrors how real POS databases normalize).
- `name` + `unit_price_paise` are copied INTO the row so historical bills stay
  correct even after a price change later (audit history).
- `action` is `SELL` or `VOID`. Voiding appends `VOID` rows for the bill's line
  items and restores stock — nothing is ever deleted.

### state
```
next_bill_no=N
```
The next bill number to use. Persisted, never regresses. Bill-number increment
is `flock`-guarded read-modify-write.

### shopkeep.conf
```
shop_name=My Kirana Store
default_threshold=8
```

### categories.csv  (category trays)
```
name,emoji,tray_barcode
```
- Pre-made trays for categories of products: Staples 🍚, Snacks 🍪,
  Beverages 🥤, Dairy 🥛, Spices 🌶️, Personal Care 🧼, Household 🧹,
  Fruits & Veggies 🍎, Bakery 🍞, Sweets & Spreads 🍫, Other 📦.
- Adding a product with a type FILES it into that tray ("writes it down in
  that tray"). In the Add flow you pick the tray from a numbered list — or
  type `n` to create a brand-new custom tray with its own emoji + barcode.
- `inventory` groups every product under its tray so you always see where
  things belong, sortable by name (A→Z), price (both ways) or qty.

## Real product lookup (optional garnish)

With internet + curl, `Add product` with a REAL barcode looks it up on Open
Food Facts, then Open Products Facts, then UPCitemDB (free trial endpoint),
and pre-fills name / brand / pack size / category neatly — you only add your
price, stock and threshold. Unknown code or no internet? The custom-product
flow takes over: type the details, pick the category tray, done. Disable any
time with `SHOPKEEP_NO_LOOKUP=1`. The script stays offline-first: the lookup
is never required, and every other feature works fully without it.

## How integrity is guaranteed

- **Money is integer paise.** "25.5" → exactly 2550. Zero rounding drift across
  thousands of bills. Rupees are produced only at display time.
- **Every read-modify-write of products.csv and state is `flock`-guarded.** Two
  billing terminals open at once cannot double-sell stock.
- **Atomic catalog rewrite:** `products.csv.new` is written in the same
  directory, then `mv`'d over the original (rename is atomic on the same
  filesystem). A crash can never leave a half-written products.csv.
- **Append-only ledger:** each bills.csv row is a single `printf` append. Rows
  are never edited or deleted.
- **Billing atomicity:** all SELL rows are appended FIRST, then stock is
  decremented. If the stock update fails, the script appends VOID reversal rows
  so the ledger can never lie (a bill never exists without its stock movement).
- **trap cleanup on EXIT:** no `.new` files, no stale locks left behind.

## Money math (critical)

All arithmetic is in integer paise internally. `rupees_to_paise` parses "25",
"25.5", and "25.00" into exactly 2500 / 2550 / 2500 using pure string
manipulation — no `bc`, no floating point. Sums are integer sums.

## Optional dependencies

| Tool     | Purpose              | Install                       |
|----------|----------------------|-------------------------------|
| zbarcam  | webcam barcode scan  | `sudo apt install zbar-tools` |
| zint     | print label PNGs     | `sudo apt install zint`       |
| tar      | backups              | `sudo apt install tar`        |

All three degrade gracefully: if missing, the feature is simply disabled and
`--doctor` reports it. Required: bash 4+, coreutils, awk, flock.

## Backups

`./shopkeep.sh backup` (menu option 6) writes `backups/shopkeep-<timestamp>.tar.gz`
of `shopkeep-data/` and keeps the last 14. A backup also runs automatically on
the first menu launch of each new day.

## Honest limitations (v1 non-goals — by design)

- No taxes / discounts / customer CRM.
- No multi-terminal UI (the data model is concurrency-safe so this can be
  added later without migration).
- No multi-currency.
- Receipts are printed to stdout; printing to a physical printer is out of
  scope (pipe `bill` output to `lp` if you want paper).
- The script is single-file by design; it may invoke `zint` and `zbarcam`
  directly as binaries but depends on no other scripts.

These data formats were deliberately chosen so all of the above can be added
later **without any data migration**.

## License

MIT. See LICENSE.
