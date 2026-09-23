# shopkeep.sh

> **Offline-first point-of-sale + inventory for Indian kirana stores.**
> Single-file Bash. Zero cloud. Zero database. All data in plain CSV files that open directly in Excel. Forced IST (Asia/Kolkata, UTC+05:30, Chennai reference) for every timestamp. Integer-paise money math — no floating-point drift across thousands of bills.

Version 1.2.0 · MIT License · Requires only Bash 4+ and coreutils.

---

## 📑 Table of contents

1. [Why shopkeep.sh?](#why-shopkeepsh)
2. [Quick start](#quick-start)
3. [Features at a glance](#features-at-a-glance)
4. [All CLI commands](#all-cli-commands)
5. [Interactive menu](#interactive-menu)
6. [Data files (CSV schemas)](#data-files-csv-schemas)
7. [Configuration (`shopkeep.conf`)](#configuration-shopkeepconf)
8. [Money handling](#money-handling)
9. [Timezone handling (IST/Chennai)](#timezone-handling-istchennai)
10. [Languages (23 Indian + English)](#languages-23-indian--english)
11. [Backup](#backup)
12. [Self-test](#self-test)
13. [Dependencies](#dependencies)
14. [Online barcode lookup](#online-barcode-lookup)
15. [Publishing to Open Products Facts](#publishing-to-open-products-facts)
16. [WhatsApp bill sending](#whatsapp-bill-sending)
17. [QR codes & EAN-13 labels](#qr-codes--ean-13-labels)
18. [Expiry tracking](#expiry-tracking)
19. [Returns / refunds](#returns--refunds)
20. [GSTIN & HSN (GST compliance)](#gstin--hsn-gst-compliance)
21. [Tray management (combo + category)](#tray-management-combo--category)
22. [How it fits with Blinkit/Zepto/Amazon/Flipkart](#how-it-fits-with-blinkitzeptonamazonflipkart)
23. [Security & privacy](#security--privacy)
24. [Limitations & honest caveats](#limitations--honest-caveats)
25. [License](#license)

---

## Why shopkeep.sh?

A kirana shop in India runs on three priorities, in this order:

1. **The data can never lie.** If a bill says 2 packets of salt were sold, the stock file must show 2 fewer packets — forever, even after a crash, even after a power cut, even if the shopkeeper's grandson runs the till.
2. **It runs forever with zero maintenance.** No database to vacuum, no cloud account to pay for, no upgrades to schedule. The same script should run on a 10-year-old laptop under a counter until the laptop dies.
3. **It is dead simple to use.** The shopkeeper types 2-digit numbers. The customers see a clean receipt. Excel can open the data directly.

shopkeep.sh was written for that reality. The original design was: *one Bash file, four CSV files, a single state file, no dependencies beyond Bash 4 and coreutils*. v1.2.0 adds expiry tracking, bill discounts, customer phone logging, GSTIN/HSN support, returns, WhatsApp sending, QR codes, and Open Products Facts publishing — all while keeping the single-file, zero-cloud philosophy.

---

## Quick start

```bash
chmod +x shopkeep.sh
./shopkeep.sh --doctor     # check dependencies & features
./shopkeep.sh --selftest   # run all 23 integrity tests

# One-time shop setup
./shopkeep.sh config shop_name "Anna Nagar Kirana"
./shopkeep.sh config gstin 33ABCDE1234F1Z5      # 15-char Indian GSTIN
./shopkeep.sh config address "12 Anna Salai, Chennai 600040"
./shopkeep.sh config phone "044-1234-5678"

# Add a product (with real EAN-13 barcode, expiry date, HSN code)
./shopkeep.sh add --name "Tata Salt 1kg" --price 25 --qty 24 \
    --barcode 8901234567890 --threshold 8 --type Staples \
    --expiry 2027-03-15 --hsn 2501 --publish

# Make a bill (reads "barcode qty" lines from stdin)
printf "8901234567890 2\n" | ./shopkeep.sh bill --phone 9876543210 --discount 5

# Send the bill on WhatsApp
./shopkeep.sh whatsapp 1

# See what's about to expire
./shopkeep.sh expiry 30

# Interactive menu (no args)
./shopkeep.sh
```

---

## Features at a glance

| Feature | Status |
|---|---|
| Offline-first (CSV only, opens in Excel) | ✅ |
| 23 Indian languages + English for the interactive UI | ✅ |
| Integer-paise money math (no float drift) | ✅ |
| IST (Asia/Kolkata) forced for every timestamp | ✅ |
| Append-only bills ledger (SELL / VOID / RETURN rows) | ✅ |
| Customer phone logged in bills.csv | ✅ |
| Per-line + bill-level discount support | ✅ |
| Expiry tracking with EXPIRED / NEAR EXPIRY reports | ✅ |
| Returns/refunds without voiding the original bill | ✅ |
| GSTIN + HSN codes printed on receipt (GST compliance) | ✅ |
| WhatsApp bill sending via wa.me deep-link | ✅ |
| QR code generation (zint -b 58) with SVG fallback | ✅ |
| EAN-13 retail labels (zint -b 13) for 12/13-digit barcodes | ✅ |
| Combo trays + Category trays (Blinkit-style scan-a-tray) | ✅ |
| Online barcode lookup (Open Food Facts / Open Products Facts / UPCitemDB) | ✅ |
| Publish your catalog to Open Products Facts (open data contribution) | ✅ |
| Daily auto-backup (tar.gz, last 14 kept) | ✅ |
| 23 self-tests covering every feature | ✅ |
| File locking (flock) for concurrent shopkeeper + assistant | ✅ |
| Atomic CSV writes (never half-written) | ✅ |

---

## All CLI commands

### Product management

```bash
# Add a product
./shopkeep.sh add --name "Tata Salt 1kg" --price 25.00 --qty 24 \
    [--barcode 8901234567890] [--threshold 8] [--desc "..."] \
    [--type Staples] [--image labels/8901.png] \
    [--expiry 2027-03-15] [--hsn 2501] [--publish]

# Edit any product field
./shopkeep.sh edit <barcode> [--name X] [--price Y] [--threshold Z] \
    [--desc D] [--type T] [--image I] [--expiry DATE] [--hsn H]
# (use --expiry - to clear the expiry date)

# Restock
./shopkeep.sh restock <barcode> --qty N [--reason "supplier delivery"]

# Remove a product (with confirmation prompt; use -y to skip)
./shopkeep.sh remove <barcode> [--reason "end of line"] [-y]

# Search by barcode, name, OR category
./shopkeep.sh search "salt"
```

### Billing

```bash
# Generate a bill (reads "barcode qty" lines from stdin, blank line to finish)
printf "8901234567890 2\n8901051001234 1\n\n" | \
    ./shopkeep.sh bill --phone 9876543210 --discount 5

# Void an entire bill (appends VOID rows + restores stock atomically)
./shopkeep.sh void <bill_no>

# Return specific items from a bill (appends RETURN rows + restores stock)
./shopkeep.sh return <bill_no> [--qty "bc1:qty,bc2:qty"] [--reason "damaged"]

# Send a bill receipt on WhatsApp (opens wa.me link in system browser)
./shopkeep.sh whatsapp [--print-url] <bill_no> [phone]
```

### Inventory views

```bash
./shopkeep.sh inventory [name|price|pricedesc|qty|category]   # stock view grouped into category trays
./shopkeep.sh lowstock                                           # deficit-sorted low-stock report
./shopkeep.sh expiry [days]                                      # expired + near-expiry (default horizon 14 days)
./shopkeep.sh stockvalue                                         # total worth of items in storage
./shopkeep.sh summary [YYYY-MM-DD]                               # daily sales summary (default: today)
./shopkeep.sh inventorylog [N]                                   # last N inventory activity entries (default 25)
```

### Tray & category management

```bash
./shopkeep.sh tray add <tray_barcode> --name "Combo" --items "bc1:qty,bc2:qty"
./shopkeep.sh tray list
./shopkeep.sh tray show <tray_barcode>
./shopkeep.sh tray remove <tray_barcode>

./shopkeep.sh category list
./shopkeep.sh category add <name> [emoji]
```

### Open data publishing

```bash
# Publish a single product to Open Products Facts (non-food) / Open Food Facts (food)
./shopkeep.sh publish <barcode>

# Publish ALL real retail barcodes in your catalog (skips internal 2xxx and category 3xxx)
./shopkeep.sh publish all

# Dry-run preview — no network, just shows what would be pushed where
./shopkeep.sh publish --dry-run all
```

### Shop config

```bash
./shopkeep.sh config                                    # list all settings
./shopkeep.sh config <key>                              # get one setting
./shopkeep.sh config <key> <value>                      # set a setting
# Keys: shop_name, gstin, address, phone, default_threshold, lang
```

### Labels & QR codes

```bash
# Generate a barcode label (EAN-13 for 13-digit retail barcodes; Code128 otherwise; SVG fallback)
./shopkeep.sh gen-label <barcode> [out.png]

# Generate a QR code (zint -b 58 with SVG fallback)
./shopkeep.sh gen-qr <data> [out.png]
```

### Languages

```bash
./shopkeep.sh lang                  # show current + list supported (23 Indian + English)
./shopkeep.sh lang hi               # switch the interactive UI to Hindi
./shopkeep.sh lang ta               # switch to Tamil
```

### Backup & maintenance

```bash
./shopkeep.sh backup                # tar.gz of shopkeep-data/ into backups/ (last 14 kept)
./shopkeep.sh --doctor              # dependency & data report
./shopkeep.sh --selftest            # 23 integrity tests
./shopkeep.sh --gen-files           # regenerate shopkeep.README.md
./shopkeep.sh -h | --help
./shopkeep.sh -V | --version
```

---

## Interactive menu

Run `./shopkeep.sh` with no arguments to enter the interactive menu (17 options + 0 to exit). The menu loop:

- Shows a header with shop name, current date/time in IST, and GSTIN (if set).
- Translates all visible strings into the configured language (23 Indian + English).
- Re-draws after each action.
- Each action asks "Press Enter to continue…" so the shopkeeper can read the result.

```
 Anna Nagar Kirana
 Wed 23 Sep 2026  16:53:18  IST
 GSTIN: 33ABCDE1234F1Z5
──────────────────────────────────────────
 1) New bill
 2) Add product
 3) Manage product (edit/restock/remove)
 4) Search inventory
 5) Stock inventory
 6) Low stock report
 7) Expiry report
 8) Daily sales summary
 9) Stock value
10) Void a bill
11) Return items
12) Tray (combo) management
13) Category trays
14) Send bill on WhatsApp
15) Backup now
16) Shop settings
17) Publish barcodes to Open Products Facts
18) Language
 0) Exit
Choose:
```

---

## Data files (CSV schemas)

Everything lives under `./shopkeep-data/` (gitignored by convention). All CSV files use RFC-4180-ish quoting — fields containing comma or quote are double-quoted, internal quotes doubled. **Every rewrite is atomic** (write to `file.csv.new` then `mv`).

### `products.csv` — 10 columns

```csv
barcode,name,price_paise,qty,threshold,description,type,image,expiry_date,hsn_code
8901234567890,"Tata Salt 1kg",2500,24,8,"Tata quality salt",Staples,labels/8901.png,2027-03-15,2501
8901051001234,"Amul Taaza 500ml",2750,6,3,"Amul pasteurised milk",Dairy,,2026-10-15,0401
```

- `barcode` — EAN-13 retail barcode (12-13 digits). Internal barcodes start with `2` (2000000000000+). Category tray barcodes start with `3` (3000000000000+).
- `price_paise` — integer paise (Rs 25.00 = 2500). No floating point.
- `expiry_date` — `YYYY-MM-DD` or empty (no expiry).
- `hsn_code` — Indian HSN/SAC code for GST (or empty).

### `bills.csv` — 10 columns, append-only ledger

```csv
bill_no,timestamp,barcode,name,qty,unit_price_paise,line_total,action,phone,discount_paise
1,2026-09-23 16:46:34,8901234567890,"Tata Salt 1kg",2,2500,4750,SELL,9876543210,250
1,2026-09-23 16:53:18,8901234567890,"Tata Salt 1kg",2,2500,4750,VOID,9876543210,250
```

- **Append-only** — no row is ever mutated. VOIDs and RETURNs append new rows that reference the same `bill_no`.
- `action` ∈ {`SELL`, `VOID`, `RETURN`}.
- `phone` — customer phone (logged so you can query bills by customer).
- `discount_paise` — discount amount applied to that line (0 if no discount).
- `line_total` is the **net** (post-discount) amount.

### `inventory_log.csv` — 7 columns, audit trail

```csv
timestamp,event,barcode,name,qty,price_paise,detail
2026-09-23 16:46:34,ADD,8901234567890,"Tata Salt 1kg",24,2500,"new product, threshold=8, type=Staples, tray=3000000000001, expiry=2027-03-15, hsn=2501"
2026-09-23 16:46:34,RESTOCK,8901234567890,"Tata Salt 1kg",5,2500,"stock 22 -> 27"
2026-09-23 16:53:18,VOID,8901234567890,"Tata Salt 1kg",2,2500,"voided bill #1"
2026-09-23 16:51:55,TRAY_REMOVE,9901,"Combo X",-,,"tray removed (items: 8001:1 8002:2)"
2026-09-23 17:00:00,PUBLISH,8901234567890,"Tata Salt 1kg",-,,"pushed to Open Food Facts (HTTP 200)"
```

`event` ∈ {`ADD`, `EDIT`, `RESTOCK`, `REMOVE`, `VOID`, `RETURN`, `STOCKVALUE`, `TRAY_ADD`, `TRAY_REMOVE`, `TRAY_NEW`, `PUBLISH`}.

### `trays.csv` — 6 columns (combo trays)

```csv
tray_barcode,name,item_barcode,item_name,item_qty,item_price_paise
9901,"Combo X",8001,"Item A",1,1000
9901,"Combo X",8002,"Item B",2,2000
```

Scan a tray barcode in billing → all member items added with multiplied qty.

### `categories.csv` — 3 columns (one tray per product category)

```csv
name,emoji,tray_barcode
Staples,🍚,3000000000001
Snacks,🍪,3000000000002
Beverages,🥤,3000000000003
Dairy,🥛,3000000000004
Spices,🌶️,3000000000005
Personal Care,🧼,3000000000006
Household,🧹,3000000000007
Fruits & Veggies,🍎,3000000000008
Bakery,🍞,3000000000009
Sweets & Spreads,🍫,3000000000010
Other,📦,3000000000011
```

A product's `type` field auto-files it into the matching category tray.

### `state`

```text
next_bill_no=42
```

Never regresses. Read at the start of every `commit_bill` / `void_bill` / `return` and incremented after a successful commit.

### `shopkeep.conf`

```text
shop_name=Anna Nagar Kirana
default_threshold=8
gstin=33ABCDE1234F1Z5
address=12 Anna Salai, Chennai 600040
phone=044-1234-5678
lang=en
```

### Backups & labels

- `backups/shopkeep-<YYYYMMDD-HHMMSS>.tar.gz` — last 14 kept, daily auto-backup at first command of the day.
- `labels/<barcode>.png` (via zint) or `.svg` (fallback) — generated by `gen-label`.
- `labels/qr-<timestamp>.svg` — generated by `gen-qr`.

---

## Configuration (`shopkeep.conf`)

Set via `./shopkeep.sh config <key> <value>`:

| Key | Purpose | Validation |
|---|---|---|
| `shop_name` | Shop name (printed on receipt header) | any string |
| `gstin` | 15-char Indian GSTIN (printed on receipt) | regex: `^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9]{1}Z[0-9A-Z]{1}$` |
| `address` | Shop address line (printed on receipt) | any string |
| `phone` | Shop phone (printed on receipt header) | any string |
| `default_threshold` | Default low-stock threshold for new products | non-negative integer |
| `lang` | UI language code (e.g., `en`, `hi`, `ta`) | one of the 23 supported codes |

---

## Money handling

All money is stored as **integer paise** (Rs 25.00 = `2500`). No `bc`, no floating point in totals.

```bash
rupees_to_paise "25"     →  2500
rupees_to_paise "25.5"   →  2550
rupees_to_paise "25.05" →  2505
rupees_to_paise "0.5"   →  50
rupees_to_paise "25."   →  2500
rupees_to_paise "abc"   →  error (return code 1)
rupees_to_paise "25.123"→  error (rejected — 3 fractional digits)
rupees_to_paise "-5"    →  error (rejected — negative)
```

Display is `Rs 25.00` (or `₹25.00` if the locale is UTF-8). Negative paise are formatted with a leading `-` (used for VOID reversals in `cmd_summary`).

**Why paise?** A kirana does 200+ bills/day. Over a year, that's 73,000 bills. Floating-point rounding drift on `0.10 + 0.20` = `0.30000000000000004` would, at the 1-paise level, cause the day-end summary to disagree with the bill ledger by a few rupees. With integer paise, the ledger and the summary always agree to the paise.

---

## Timezone handling (IST/Chennai)

`export TZ="Asia/Kolkata"` is set at the top of the script. **Every** `date` call also explicitly passes `TZ=Asia/Kolkata`:

```bash
ist_today()    { TZ=Asia/Kolkata date '+%Y-%m-%d'; }
now_date()     { LC_ALL=C TZ=Asia/Kolkata date '+%a %d %b %Y'; }
now_time()      { LC_ALL=C TZ=Asia/Kolkata date '+%H:%M:%S'; }
# log_event(), commit_bill(), void_bill(), backup_now(), cmd_summary(),
# cmd_stockvalue(), days_until() — all use TZ=Asia/Kolkata
```

This means:

- The interactive menu header clock always shows IST.
- Bill timestamps in `bills.csv` are always IST.
- Inventory log (`inventory_log.csv`) timestamps are always IST.
- Backup archive names use IST (`shopkeep-20260923-164653.tar.gz`).
- The `expiry` report's "today" reference is IST.

**Self-test verifies the offset**: `_st_tz_offset` compares `date -u` (UTC) against `TZ=Asia/Kolkata date` and asserts the difference is 19,800 seconds (5h 30m) ±60s slack. The original weak `_st_tz` only checked the env var was set; the new test proves the offset is correct.

---

## Languages (23 Indian + English)

The interactive UI supports **English + 22 scheduled Indian languages** (per the Indian Constitution):

| Code | Language | Code | Language | Code | Language |
|---|---|---|---|---|---|
| `en` | English | `mr` | Marathi | `kok` | Konkani |
| `hi` | Hindi | `ta` | Tamil | `doi` | Dogri |
| `bn` | Bengali | `ur` | Urdu | `mni` | Manipuri |
| `te` | Telugu | `gu` | Gujarati | `sat` | Santali |
| `or` | Odia | `kn` | Kannada | `brx` | Bodo |
| `pa` | Punjabi | `ml` | Malayalam | `bho` | Bhojpuri |
| `as` | Assamese | `sa` | Sanskrit | | |
| `mai` | Maithili | `ne` | Nepali | | |
| | | `sd` | Sindhi | | |

CSV data stays English so Excel exports and audits are consistent regardless of UI language. Only the interactive UI strings are translated. Set via `./shopkeep.sh lang <code>` or menu option 18.

**Display-width engine**: a custom terminal-width calculator (`_dw`) handles Indic combining marks (matras, viramas), CJK wide chars, and emoji — so a Devanagari label "कीमत:" lines up with "Price:" in the printed receipt.

---

## Backup

- **Automatic**: the first command of each day triggers `maybe_auto_backup`, which calls `backup_now` if no backup has been made today. The day is recorded in `shopkeep-data/.last_backup_date`.
- **Manual**: `./shopkeep.sh backup` or menu option 15.
- **Format**: `backups/shopkeep-<YYYYMMDD-HHMMSS>.tar.gz` (tar of `shopkeep-data/`).
- **Retention**: last 14 archives kept; older ones deleted.

```bash
$ ls backups/
shopkeep-20260922-090511.tar.gz
shopkeep-20260923-164653.tar.gz
```

---

## Self-test

`./shopkeep.sh --selftest` runs 23 tests in a tmp directory (no network, no webcam):

```
Running self-tests...
  PASS  money math (25.5->2550, etc.)
  PASS  CSV roundtrip (comma + quote)
  PASS  negative stock rejection
  PASS  atomic write + flock
  PASS  low stock sort order
  PASS  daily summary math
  PASS  remove + restock
  PASS  tray expansion
  PASS  display width engine
  PASS  category trays + emoji
  PASS  inventory sorting
  PASS  IST timezone enforced
  PASS  label SVG fallback
  PASS  category-tray barcode lookup
  PASS  expiry date math
  PASS  phone logged in bills.csv
  PASS  bill discount math
  PASS  whatsapp URL format
  PASS  QR SVG fallback
  PASS  GSTIN validation
  PASS  return flow + RETURN rows
  PASS  IST offset is +05:30
  PASS  publish dry-run routing

Self-test: 23 passed, 0 failed
```

Exit code 0 on all-pass, 1 on any failure. Each test is a small function (`_st_*`) that creates its own fixtures and cleans up via `ST_TMP` + the cleanup trap.

---

## Dependencies

### Required

| Tool | Where used | Install if missing |
|---|---|---|
| **Bash 4+** | assoc arrays, `${var,,}`, `${var:i:1}`, `printf -v` | default on most systems |
| **coreutils** (`printf`, `mv`, `rm`, `sort`, `head`, `cut`, `wc`, `date`, `mkdir`, `ls`) | everywhere | `sudo apt install coreutils` |
| **awk** | `cmd_inventory`, `cmd_summary`, `cmd_doctor`, etc. | `sudo apt install gawk` |
| **flock** (util-linux) | every read-modify-write | `sudo apt install util-linux` |

### Optional

| Tool | Where used | Install if missing |
|---|---|---|
| **curl** | online barcode lookup, publishing to Open Products Facts | `sudo apt install curl` |
| **tar** | backups | `sudo apt install tar` |
| **zbarcam** | webcam barcode scan (interactive `bill` flow) | `sudo apt install zbar-tools` |
| **zint** | PNG barcode + QR generation (SVG fallback works without it) | `sudo apt install zint` |

`./shopkeep.sh --doctor` tells you exactly what's installed and what's missing on the current machine.

---

## Online barcode lookup

When you add a product with a real EAN-13 barcode and have `curl` + internet, shopkeep.sh queries **three public, free, non-commercial APIs** in order and pre-fills the product name/brand/pack/category:

1. **Open Food Facts** (`world.openfoodfacts.org/api/v2/product/<bc>.json`) — food & groceries. The largest open food database in the world.
2. **Open Products Facts** (`world.openproductsfacts.org/api/v2/product/<bc>.json`) — non-food merchandise.
3. **UPCitemDB** (`upcitemdb.com/api/trial/lookup?upc=<bc>`) — general merchandise trial endpoint.

If all three fail (or no internet), it falls back to the custom-product flow with the category-tray picker. Disable with `SHOPKEEP_NO_LOOKUP=1`.

These three APIs are the only publicly accessible barcode databases that don't require authentication. **The proprietary catalogs of Blinkit/Zepto/Amazon/Flipkart are not accessible** — they don't expose public barcode lookup APIs.

---

## Publishing to Open Products Facts

**This is the open-data contribution feature** — your kirana catalog becomes part of the global open barcode database.

### How it works

When you run `./shopkeep.sh publish <barcode>` (or `publish all`, or `add --publish`):

1. The product is looked up from `products.csv`.
2. The category is checked by `opf_is_food_category()`:
   - **Food/grocery category** (Staples, Snacks, Dairy, Beverages, Spices, Bakery, Sweets, Fruits & Veggies, Frozen, Eggs, Baby food, Pet food) → POST to **Open Food Facts** (`world.openfoodfacts.org/cgi/product.pl`).
   - **Other category** (Electrical, Personal Care, Household, Stationery, etc.) → POST to **Open Products Facts** (`world.openproductsfacts.org/cgi/product.pl`).
3. The POST submits: `code`, `product_name`, `brands`, `categories`. (Pack size, image URL not submitted yet.)
4. The HTTP status is checked (2xx/3xx = success).
5. A `PUBLISH` event is appended to `inventory_log.csv`.

### Privacy

**No customer phone is ever published.** The phone is a separate concern (it's logged in `bills.csv` for the shopkeeper's own customer-bill lookup, and used in WhatsApp deep-links). Only the product's catalog fields (barcode, name, brand, category) are sent to the open database.

### Why do this?

Every scanner in the world — including any future app built by Blinkit/Zepto/Amazon/Flipkart or anyone else — reads from these open databases. By pushing your kirana catalog in, your barcodes become scannable anywhere. The more shops contribute, the better the open database gets.

### Dry-run preview

```bash
./shopkeep.sh publish --dry-run all
# ==> [dry-run] Would publish → Open Food Facts: code=8901234567890 name=Tata Salt 1kg brand=Tata cat=Staples
# ==> [dry-run] Would publish → Open Products Facts: code=8900000000017 name=Havells LED Bulb 9W brand=Havells cat=Electrical
# ==> Published: 2/2
```

Use `--dry-run` to preview without any network call.

### Internal vs retail barcodes

`publish all` only pushes **real retail EAN-13 barcodes** (12-13 digits, not starting with `2` (internal) or `3` (category tray)). Internal barcodes like `2000000000001` are skipped because they're shop-specific and not globally unique.

---

## WhatsApp bill sending

When you run `./shopkeep.sh whatsapp <bill_no> [phone]`:

1. The bill is reconstructed from `bills.csv` SELL rows into a plain-text message (shop name, GSTIN, bill no, IST timestamp, customer phone, item lines with totals, *TOTAL: Rs X.XX*, Thank you).
2. The phone is normalised — non-digits stripped, leading `91` (India country code) is added if missing.
3. The message is URL-encoded (`url_encode`).
4. The URL `https://wa.me/91XXXXXXXXXX?text=<encoded-message>` is opened in the system browser via `xdg-open` (Linux), `sensible-browser`, or `open` (macOS).
5. WhatsApp Web/App opens with the message prefilled — the shopkeeper (or customer) clicks send.

### Print the URL only (headless / CI)

```bash
./shopkeep.sh whatsapp --print-url 1 9876543210
# https://wa.me/919876543210?text=%2AAnna+Nagar+Kirana%2A%0A...
```

### Honest caveat

This is a **deep-link** approach — a human still clicks "Send" in WhatsApp. For fully automated sending (no human click), you'd need the **WhatsApp Cloud API** (Meta Business account + approved message template + registered phone number + per-message payment). That's beyond a Bash script for a kirana shop; the wa.me deep-link is the realistic free alternative.

---

## QR codes & EAN-13 labels

### EAN-13 retail labels (`gen-label`)

```bash
./shopkeep.sh gen-label 8901234567890 [out.png]
```

- For 12-13-digit barcodes → `zint -b 13` (EAN-13, the correct retail symbology — auto-computes the checksum digit).
- For other barcodes → `zint -b CODE128` (fallback).
- If `zint` is absent → SVG fallback that embeds the barcode number as text in an SVG box (not scannable, but a label).

### QR codes (`gen-qr`)

```bash
./shopkeep.sh gen-qr "https://example.com/bill/123" [out.png]
```

- `zint -b 58` (true QR code).
- SVG fallback with the data embedded as text if `zint` is absent.

### Why EAN-13 vs Code128

A 13-digit retail barcode (like `8901234567890`) is **EAN-13** by international standard (GS1). Code128 *can* encode it but most retail POS scanners expect EAN-13. Using EAN-13 means the label is scannable by ANY retail scanner — at your shop, at the distributor's warehouse, or at a future Blinkit-style dark store.

---

## Expiry tracking

### Add a product with expiry

```bash
./shopkeep.sh add --name "Amul Taaza 500ml" --price 27.50 --qty 6 \
    --barcode 8901051001234 --type Dairy --expiry 2026-10-15 --hsn 0401
```

### Edit the expiry later

```bash
./shopkeep.sh edit 8901051001234 --expiry 2026-11-30   # set new expiry
./shopkeep.sh edit 8901051001234 --expiry -            # clear the expiry
```

### Expiry report

```bash
./shopkeep.sh expiry           # 14-day horizon (default)
./shopkeep.sh expiry 90         # 90-day horizon
```

Output:
```
EXPIRY REPORT  (horizon: 14 days; today 2026-09-23)
────────────────────────────────────────────────────────────────
 EXPIRED
  🍞 Old Bread              8900000000017  2025-01-01  x4     630 days ago
 NEAR EXPIRY
  🥛 Amul Taaza 500ml       8901051001234  2026-10-15  x5     22 Days left
  🍚 Tata Salt 1kg          8901234567890  2027-03-15  x22    173 Days left
```

### Inventory markers

`./shopkeep.sh inventory` shows:
- ⏰ — expired
- ⏳ — near expiry (within horizon)
- ✅ — fresh
- 🔴 — out of stock
- ⚠️ — low stock (qty ≤ threshold)

### `show_product` and `search`

Both display the expiry date + computed days-left with color coding (red = expired, yellow = near, green = fresh).

---

## Returns / refunds

`return` is a **proper return** — it appends RETURN rows to `bills.csv` and restores stock, **without** voiding the original bill. This matters because:

- The original sale is preserved (for audits, for the customer's purchase history).
- The return is recorded as a separate event.
- You can return part of a bill (e.g., 2 of 5 items).
- The same bill can be returned in multiple tranches.
- Trying to return more than was sold is rejected.

```bash
# Return 2 of the 3 salt packets from bill #1
./shopkeep.sh return 1 --qty "8901234567890:2" --reason "customer changed mind"

# Return all items (default)
./shopkeep.sh return 1 --reason "wrong items"
```

A RETURN receipt is printed (with GSTIN, shop address, customer phone — just like a SELL receipt, but with the "RETURN" action label).

### Void vs Return — when to use which

| Situation | Use |
|---|---|
| Bill was created by mistake, customer never paid | `void <bill_no>` |
| Customer paid, took items, then returned some/all | `return <bill_no> --qty "bc:qty"` |
| Bill was correct but the wrong total was charged | `void <bill_no>` then re-bill correctly |

Void appends VOID rows for **every** SELL row of that bill. Return appends RETURN rows only for the items actually being returned.

---

## GSTIN & HSN (GST compliance)

For GST-registered shops, Indian law requires the shop's GSTIN on every B2B receipt. shopkeep.sh supports this end-to-end:

```bash
# Set your GSTIN (15-char Indian format)
./shopkeep.sh config gstin 33ABCDE1234F1Z5
```

The GSTIN is validated against the official Indian format regex: `^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9]{1}Z[0-9A-Z]{1}$` (2 digits state + 5 letters PAN + 4 digits + 1 letter + 1 digit + 'Z' + 1 alnum checksum).

Once set, **every receipt** prints it:

```
┌──────────────────────────────────────────┐
│            Anna Nagar Kirana             │
│      12 Anna Salai, Chennai 600040       │
│          GSTIN: 33ABCDE1234F1Z5          │
│            Ph: 044-1234-5678             │
│                Bill #0001                │
│           2026-09-23 16:46:34            │
│          Cust Ph: 9876543210             │
├──────────────────────────────────────────┤
│ Tata Salt 1kg x2                  Rs47.50│
├──────────────────────────────────────────┤
│ SUBTOTAL                          Rs50.00│
│ DISCOUNT (5%)                  -   Rs2.50│
│ NET PAYABLE                       Rs47.50│
│ Items: 1  Units: 2                       │
└──────────────────────────────────────────┘
```

### HSN/SAC codes per product

```bash
./shopkeep.sh add --name "Tata Salt 1kg" --price 25 --qty 24 \
    --barcode 8901234567890 --hsn 2501
```

HSN codes are stored per-product in `products.csv` and shown in `search` / `show_product`. (Per-line HSN printing on receipts is a future enhancement — current receipts print the shop GSTIN only.)

### Honest note on "government API"

India does **not** operate a public "retail barcode / consumer-bill submission" API. The realistic government touchpoints are:

- **GS1 India** (privately run, not government) — issues GTINs to *brands*, not shops. No shop push API.
- **GST e-invoicing API** (`einvoice1.gst.gov.in`) — only for **B2B** invoices ≥ ₹50,000 by GST-registered businesses, requires GSTIN + digital certificate + GSP intermediary. Not applicable to walk-in B2C retail.

So "pushing barcodes to government API when a kirana shop enters a bill" is a misconception. What **is** legally required is printing the shop's GSTIN on receipts — which shopkeep.sh does.

---

## Tray management (combo + category)

### Combo trays (Blinkit-style "scan-a-tray")

A combo tray is a virtual barcode that expands to multiple member items when scanned in billing:

```bash
./shopkeep.sh tray add 9901 --name "Snack Pack" --items "8901234567890:1,8901051001234:2"
./shopkeep.sh tray list
./shopkeep.sh tray show 9901
./shopkeep.sh tray remove 9901
```

In billing, scanning `9901 2` adds 2× Tata Salt and 4× Amul Taaza to the cart (each member qty multiplied by the tray scan count).

### Category trays (one tray per product category)

Every product's `type` field auto-files it into the matching category tray. The default seeded set:

| Tray | Emoji | Auto-files products with type |
|---|---|---|
| Staples | 🍚 | rice, atta, flour, dal, oil, salt, sugar, etc. |
| Snacks | 🍪 | biscuit, cookie, chip, wafer, namkeen |
| Beverages | 🥤 | tea, coffee, juice, drink, water, soda |
| Dairy | 🥛 | milk, curd, cheese, butter, ghee |
| Spices | 🌶️ | masala, chilli, turmeric, cardamom |
| Personal Care | 🧼 | soap, shampoo, tooth, cream |
| Household | 🧹 | detergent, tissue, mop, broom |
| Fruits & Veggies | 🍎 | fruit, vegetable, produce |
| Bakery | 🍞 | bread, bun, cake, pastry |
| Sweets & Spreads | 🍫 | chocolate, candy, jam, honey |
| Other | 📦 | (fallback) |

`./shopkeep.sh category list` shows all trays with their auto-generated barcodes and product counts.

### Tray barcode ranges

| Range | Use |
|---|---|
| `2000000000000`–`2999999999999` | Internal product barcodes (auto-generated when no `--barcode` given) |
| `3000000000000`–`3999999999999` | Category tray barcodes (one per category) |
| `8900000000000`–`8999999999999` | Real retail EAN-13 barcodes (Tata, Amul, etc. — assigned by GS1 India) |
| `9900`+ | Combo tray barcodes (user-defined) |

---

## How it fits with Blinkit/Zepto/Amazon/Flipkart

The user researched the actual APIs these companies use internally. Here's the neat list:

### 1. Commercial Computer Vision SDKs (high-end performance)

These are licensed, AI-powered software engines embedded directly into delivery and picker apps:

| SDK | What it's known for |
|---|---|
| **Scandit Data Capture SDK** | Scanning blurred, torn, or poorly lit barcodes; multi-scanning; heavy glare correction |
| **Dynamsoft Barcode Reader** | High-density multi-barcode batch scanning in a single camera frame |
| **Anyline Barcode Scanner SDK** | High-speed mobile data capture and rugged enterprise scanning |

### 2. Native & open-source APIs (cost-effective scaling)

Developer-friendly, cloud-or-edge APIs built into mobile operating systems:

| API | Use case |
|---|---|
| **Google ML Kit (Barcode Scanning API)** | Default, high-performance local scanning for Android apps; processes frames on-device for free |
| **Apple Vision Framework (VNDetectBarcodesRequest)** | Native iOS hardware-accelerated barcode + QR recognition |
| **ZXing ("Zebra Crossing") / ZBar** | Open-source, lightweight libraries for legacy systems / early-stage apps |

### 3. Industrial hardware APIs (warehouse & fulfilment centres)

For deep inventory tasks inside massive fulfilment centres — workers use rugged handheld devices:

| API | Device | What it does |
|---|---|---|
| **Zebra DataWedge API** | Zebra terminals | System-level API that talks to the physical laser imager for instantaneous point-and-shoot capture |
| **Honeywell Mobility SDK for Android** | Honeywell terminals | Broadcasts hardware-level scanner intents directly into inventory software |

### 4. Backend data-sync APIs

Once the barcode is decoded locally on the device, it's sent to the company's internal WMS/OMS via:

| Protocol | Use |
|---|---|
| **GraphQL APIs** | Fetch exact product data (price, imagery) with minimal payload, millisecond latency |
| **RESTful JSON Web APIs** | Standard internal warehouse APIs for posting transaction logs (e.g., shelf count 10 → 9) |

### Where shopkeep.sh fits

shopkeep.sh is **not** a competitor to Scandit/Dynamsoft/Zebra — those are enterprise SDKs costing thousands of dollars per year. shopkeep.sh is the **shop-side POS** that:

1. **Reads from the same open databases** (Open Food Facts / Open Products Facts) that any modern app — including ones built with the above SDKs — can read from.
2. **Contributes back to those open databases** via `publish` — making your kirana's barcodes scannable by ANY future app that reads the public data.
3. **Uses the free, public UPCitemDB trial endpoint** as a fallback when the open databases don't have a barcode.

So when you scan a Tata Salt barcode with shopkeep.sh's `online_lookup`, you get the same product data that an enterprise scanner at a Blinkit dark store would have — because both ultimately read from the same global open barcode databases (when they're not using their proprietary in-house catalog).

The enterprise SDKs (Scandit, Dynamsoft, Zebra DataWedge, Google ML Kit, Apple Vision) are the **scanner front-ends**; the open databases (Open Food Facts, Open Products Facts, UPCitemDB) are the **backend data sources**. shopkeep.sh integrates with the backend layer — read (via `online_lookup`) and write (via `publish`).

---

## Security & privacy

### What's stored locally

- All product data, bills, inventory log, trays, categories, state, and config — in plain CSV under `./shopkeep-data/`.
- The customer's phone number is logged in `bills.csv` (so you can query bills by customer) — this is **local only**, never sent anywhere.

### What's sent to the internet

| Operation | What's sent | Where |
|---|---|---|
| `online_lookup` (when adding a product) | just the barcode | Open Food Facts / Open Products Facts / UPCitemDB |
| `publish` (manual or `--publish` on add) | barcode + product name + brand + category | Open Food Facts (food) or Open Products Facts (non-food) |
| `whatsapp <bill_no>` | bill receipt text + customer phone (in the wa.me URL, which goes to WhatsApp) | WhatsApp (Meta) |

**Never sent anywhere**: stock counts, prices you charge, discount amounts, customer names (we don't store names), or your shop's internal financial data.

### File permissions

`shopkeep-data/` should be `chmod 700` (only the shopkeeper user can read/write). The script doesn't enforce this yet — run `chmod -R 700 shopkeep-data/` if you're on a shared machine.

### Backups

Backups contain the full `shopkeep-data/` including customer phones. Store them on encrypted media or a private cloud (Nextcloud, etc.) — not in a public S3 bucket.

---

## Limitations & honest caveats

1. **No multi-user auth.** The script uses `flock` for atomic file writes, but there's no per-user login. If two people run the script on the same machine, they share the same data. (For a real kirana with one counter, this is fine.)
2. **No automated WhatsApp.** The `whatsapp` command opens wa.me in a browser — a human clicks "Send". For automated sending, you need the WhatsApp Cloud API (Meta Business account + approved template + paid per message).
3. **No real government API push.** India has no public retail-barcode submission API. The realistic GST compliance is printing GSTIN on receipts — which is done.
4. **zint is optional.** Without `zint`, barcode/QR generation falls back to SVG files (which work in printers that support SVG, but aren't scannable themselves — they're labels with the number written as text). Install `zint` for real scannable PNG output.
5. **zbarcam is optional.** Without `zbarcam`, the webcam-scan prompt in the interactive bill flow does nothing — you can still type the barcode by hand.
6. **Publishing is best-effort.** The Open Food Facts / Open Products Facts servers may rate-limit, reject, or take time to index your submissions. Always check with `publish --dry-run` first.
7. **CSV is not a database.** For a kirana (a few thousand products, a few hundred bills/day), CSV is fine. If you scale to lakhs of products or bills, switch to SQLite (which `prisma` would give you for free in a different stack — but shopkeep.sh deliberately stays CSV-only for the "opens in Excel" property).
8. **One GSTIN per shop.** Multi-GSTIN chain stores aren't supported — run one `shopkeep-data/` per shop.

---

## License

MIT. The script is a single file — copy it, modify it, audit it, give it to your neighbouring kirana shop. The open databases it talks to (Open Food Facts, Open Products Facts, UPCitemDB) have their own terms — read them if you're a high-volume contributor.

---

*shopkeep.sh v1.2.0 — built for the kirana on the corner, by someone who's been to one.*
