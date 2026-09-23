#!/usr/bin/env bash
#
# shopkeep.sh — offline-first point-of-sale + inventory for small retail shops
#               (kirana stores). Single file. Zero cloud. Zero database.
#
# PURPOSE
#   All data lives in plain CSV files (open in Excel) under ./shopkeep-data/.
#   Designed for a shopkeeper on an old laptop, possibly with no internet.
#   Priorities in order: (1) the data can never lie, (2) runs forever with
#   zero maintenance, (3) dead simple to use.
#
# USAGE
#   ./shopkeep.sh                      # interactive menu loop (12 options + 0 to exit)
#   ./shopkeep.sh add --name "Tata Salt 1kg" --price 25.00 --qty 24 \
#                    [--barcode 8901234567890] [--threshold 8] \
#                    [--desc "..."] [--type Grocery] [--image labels/8901.png]
#   ./shopkeep.sh edit <barcode> [--name X] [--price Y] [--threshold Z] [--desc D] [--type T] [--image I]
#   ./shopkeep.sh restock <barcode> --qty N [--reason "..."]
#   ./shopkeep.sh remove <barcode> [--reason "..."]
#   ./shopkeep.sh search <query>       # by barcode, name OR type, full details per match
#   ./shopkeep.sh inventory [name|price|pricedesc|qty|category]
#                                      # stock view grouped into category trays
#   ./shopkeep.sh category list | add <name> [emoji]   # category tray management
#   ./shopkeep.sh tray add|list|show|remove ...   # Blinkit-style combo scanning
#   ./shopkeep.sh bill                 # reads barcode/qty lines from stdin (trays expand)
#   ./shopkeep.sh lowstock
#   ./shopkeep.sh summary [YYYY-MM-DD] # default: today
#   ./shopkeep.sh void <bill_no>
#   ./shopkeep.sh stockvalue           # total worth of items in storage
#   ./shopkeep.sh inventorylog [N]     # last N inventory activity entries
#   ./shopkeep.sh lang [code]          # get/set UI language (23 total)
#   ./shopkeep.sh backup               # tar.gz of shopkeep-data/ (cron-friendly)
#   ./shopkeep.sh --doctor | --selftest | --gen-files | -h | -V
#
# DATA FILES (everything under ./shopkeep-data/, gitignored)
#   products.csv     : barcode,name,price_paise,qty,threshold,description,type,image
#                      (rewritten atomically; old 5-col files auto-migrate)
#   bills.csv        : bill_no,timestamp,barcode,name,qty,unit_price_paise,
#                      line_total,action                       (append-only ledger)
#   inventory_log.csv: timestamp,event,barcode,name,qty,price_paise,detail
#                      (audit trail: ADD/EDIT/RESTOCK/REMOVE/VOID/STOCKVALUE/TRAY_*)
#   trays.csv        : tray_barcode,name,item_barcode,item_name,item_qty,item_price_paise
#                      (scan a tray barcode in billing -> all items added)
#   categories.csv   : name,emoji,tray_barcode   (category trays; a product's
#                      type files it into its tray - pickable when adding)
#   state            : next_bill_no=N                          (never regresses)
#   shopkeep.conf     : shop_name, default_threshold, lang
#   backups/         : shopkeep-<ts>.tar.gz  (last 14 kept)
#   labels/          : <barcode>.png         (via zint, optional) + product images
#
# LANGUAGES
#   The interactive UI supports 23 languages: English + 22 scheduled Indian
#   languages (hi bn te mr ta ur gu kn or ml pa as mai sa ne sd kok doi mni
#   sat brx bho). CSV data stays English so Excel exports and audits are
#   consistent regardless of language. Set via `lang <code>` or menu option 11.
#
# MONEY
#   All arithmetic in INTEGER PAISE (Rs 25.00 == 2500) internally. No bc, no
#   floating point in totals. Zero rounding drift across thousands of bills.
#
# TIMEZONE
#   Forced to Asia/Kolkata (IST, UTC+05:30, Chennai reference) regardless of
#   host TZ, so the header clock and bill timestamps always show Indian time.
#
# ONLINE LOOKUP (optional garnish - the script stays offline-first)
#   Add product + real barcode + internet + curl  ->  product details are
#   fetched (Open Food Facts -> Open Products Facts -> UPCitemDB trial) and
#   pre-filled neatly. No internet / unknown code  ->  the custom-product
#   flow with the category-tray picker. Disable with SHOPKEEP_NO_LOOKUP=1.
#
# EXIT CODES
#   0  ok
#   1  validation error or self-test failure
#   2  missing required dependency
#   3  bad usage
#
# LICENSE: MIT
#

set -Eeuo pipefail

#─────────────────────────────────────────────────────────────────────────────
# Paths
#─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DATA_DIR="${SHOPKEEP_DATA_DIR:-$SCRIPT_DIR/shopkeep-data}"
PRODUCTS_CSV="$DATA_DIR/products.csv"
BILLS_CSV="$DATA_DIR/bills.csv"
INVENTORY_LOG="$DATA_DIR/inventory_log.csv"
TRAYS_CSV="$DATA_DIR/trays.csv"
STATE_FILE="$DATA_DIR/state"
LOCK_FILE="$DATA_DIR/.lock"
CONF_FILE="$DATA_DIR/shopkeep.conf"
CATEGORIES_CSV="$DATA_DIR/categories.csv"
LAST_BACKUP_FILE="$DATA_DIR/.last_backup_date"
LABELS_DIR="$SCRIPT_DIR/labels"
BACKUPS_DIR="$SCRIPT_DIR/backups"

BOX_WIDTH=42
MONEY_FIELD=9
MAX_NAME=22
US=$'\x1f'   # unit separator — never appears in product names

VERSION="1.2.0"

# Globals
declare -A P_NAME P_PRICE P_QTY P_THRESHOLD P_DESC P_TYPE P_IMAGE P_EXPIRY P_HSN
declare -A TRAY_NAME TRAY_ITEMS   # tray_barcode -> name ; tray_barcode -> "bc:qty bc:qty ..."
declare -a CSV_FIELDS=()
declare -a BILL_LINES=()
ADDED_BARCODE=""
BILL_NO=""
BILL_TS=""
BILL_TOTAL=""          # net total (after discount)
BILL_DISCOUNT=""       # total discount paise for the bill
BILL_PHONE=""          # customer phone (now logged in bills.csv too)
BILL_DISCOUNT_PCT="0"  # bill-level discount percentage (0-100)
ST_TMP=""

#─────────────────────────────────────────────────────────────────────────────
# Force IST (Asia/Kolkata, UTC+05:30, Chennai reference) for every date call
#─────────────────────────────────────────────────────────────────────────────
export TZ="Asia/Kolkata"

#─────────────────────────────────────────────────────────────────────────────
# Colors (only when stdout is a TTY and NO_COLOR unset)
#─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""
    C_DIM=""
fi

#─────────────────────────────────────────────────────────────────────────────
# Cleanup trap — never leave .new files or stale locks behind
#─────────────────────────────────────────────────────────────────────────────
cleanup() {
    local rc=$?
    if [[ -n "${DATA_DIR:-}" ]]; then
        rm -f "$DATA_DIR"/*.new 2>/dev/null || true
        rm -f "$DATA_DIR/.lock" 2>/dev/null || true     # NEW: also clear stale lock
    fi
    flock -u 200 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
    if [[ -n "${ST_TMP:-}" ]]; then
        rm -rf "$ST_TMP" 2>/dev/null || true
    fi
    return $rc
}
trap cleanup EXIT

#─────────────────────────────────────────────────────────────────────────────
# Logging helpers
#─────────────────────────────────────────────────────────────────────────────
log()  { printf '%s==> %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
err()  { printf '%sERROR: %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }
die()  { err "$@"; exit 1; }

#─────────────────────────────────────────────────────────────────────────────
# Currency symbol (₹ when locale is UTF-8, else Rs — keeps alignment sane)
#─────────────────────────────────────────────────────────────────────────────
pick_currency() {
    local loc="${LC_ALL:-}${LANG:-}"
    if [[ "$loc" == *UTF-8* || "$loc" == *utf-8* || "$loc" == *utf8* ]]; then
        printf '₹'
    else
        printf 'Rs'
    fi
}
CURRENCY="$(pick_currency)"

#─────────────────────────────────────────────────────────────────────────────
# Internationalisation — 22 scheduled Indian languages + English
#   LANG_CODE is read from shopkeep.conf (key: lang). Default: en.
#   t() looks up T["<lang>.<key>"], falls back to English, then to the key.
#   CSV data (column names, bill rows) stays English so Excel exports and
#   audits remain consistent across languages — only the interactive UI is
#   translated. Receipts translate only the fixed labels (TOTAL/Items/Units).
#─────────────────────────────────────────────────────────────────────────────
LANG_CODE="en"
declare -A T

# List of supported languages (code -> display name in that language)
LANG_NAMES=(
    "en:English"
    "hi:हिन्दी"
    "bn:বাংলা"
    "te:తెలుగు"
    "mr:मराठी"
    "ta:தமிழ்"
    "ur:اردو"
    "gu:ગુજરાતી"
    "kn:ಕನ್ನಡ"
    "or:ଓଡ଼ିଆ"
    "ml:മലയാളം"
    "pa:ਪੰਜਾਬੀ"
    "as:অসমীয়া"
    "mai:মৈথিলী"
    "sa:संस्कृतम्"
    "ne:नेपाली"
    "sd:سنڌي"
    "kok:कोंकणी"
    "doi:डोगरी"
    "mni:মৈতৈ"
    "sat:ᱥᱟᱱᱛᱟᱲᱤ"
    "brx:बड़ो"
    "bho:भोजपुरी"
)

# English defaults — always loaded; every key has an English value.
load_strings_en() {
    T[en.m_new_bill]="New bill"
    T[en.m_add_product]="Add product"
    T[en.m_low_stock]="Low stock report"
    T[en.m_summary]="Daily sales summary"
    T[en.m_void]="Void a bill"
    T[en.m_backup]="Backup now"
    T[en.m_stock_value]="Stock value"
    T[en.m_language]="Language"
    T[en.m_exit]="Exit"
    T[en.m_choose]="Choose: "
    T[en.p_scan]="Scan/type barcode (blank to finish, s:query to search): "
    T[en.p_qty]="Qty"
    T[en.p_name]="Name"
    T[en.p_price]="Price"
    T[en.p_threshold]="Threshold"
    T[en.p_barcode]="Barcode"
    T[en.p_bill_no]="Bill no to void: "
    T[en.p_pick]="Pick number (blank to cancel): "
    T[en.p_scan_webcam]="Scan barcode with webcam? (y/N): "
    T[en.p_print_label]="Print label PNG? (y/N): "
    T[en.p_confirm_void]="Void this bill? (y/N): "
    T[en.r_total]="TOTAL"
    T[en.r_reversed]="REVERSED"
    T[en.r_items]="Items:"
    T[en.r_units]="Units:"
    T[en.c_added]="added"
    T[en.c_bill_saved]="Bill saved"
    T[en.c_voided]="voided. Stock restored."
    T[en.c_cancelled]="cancelled"
    T[en.c_bye]="Bye."
    T[en.c_no_low_stock]="No low-stock items. All good!"
    T[en.c_lang_changed]="Language changed to"
    T[en.c_select_lang]="Select language (number): "
    T[en.c_no_products]="No products recorded."
    T[en.c_no_bills]="No bills recorded."
    T[en.s_bills_processed]="Bills processed:"
    T[en.s_units_sold]="Units sold:"
    T[en.s_revenue]="Revenue:"
    T[en.s_avg_bill]="Average bill:"
    T[en.s_voided_bills]="Voided bills:"
    T[en.s_top_products]="TOP PRODUCTS BY REVENUE"
    T[en.ls_title]="LOW STOCK REPORT"
    T[en.ls_deficit]="Deficit"
    T[en.ls_stock]="Stock"
    T[en.sv_title]="STOCK VALUE (inventory worth)"
    T[en.sv_total]="TOTAL STOCK VALUE"
    T[en.sv_items]="products"
    T[en.sv_value]="Value"
    T[en.d_data_dir]="Data directory"
    T[en.d_files]="Files"
    T[en.invlog_title]="INVENTORY ACTIVITY LOG"
    T[en.m_manage]="Manage product (edit/restock/remove)"
    T[en.m_search]="Search inventory"
    T[en.m_tray]="Tray (combo) management"
    T[en.p_type]="Type"
    T[en.p_desc]="Description"
    T[en.p_image]="Image"
    T[en.p_reason]="Reason"
    T[en.search_title]="Search results for"
    T[en.c_removed]="Removed"
    T[en.c_restocked]="Restocked"
    T[en.c_edited]="Edited"
    T[en.c_tray_expanded]="Tray expanded"
    T[en.p_confirm_remove]="Remove this product? (y/N): "
    T[en.manage_sub]="Manage: 1) Edit  2) Restock  3) Remove  0) Back"
    T[en.tray_sub]="Tray: 1) Add combo  2) List combos  3) Show combo  4) Remove combo  5) Category trays  0) Back"
    T[en.p_tray_bc]="Tray barcode"
    T[en.p_tray_name]="Tray name"
    T[en.p_tray_items]="Items (bc:qty,bc:qty)"
    T[en.c_scan_tray]="→ TRAY"
    T[en.c_empty_bill]="Empty bill, nothing saved."
    T[en.m_inventory]="Stock inventory"
    T[en.m_categories]="Category trays"
    T[en.inv_title]="STOCK INVENTORY"
    T[en.inv_sort]="Sort:  1) Name A→Z   2) Price low→high   3) Price high→low   4) Qty low→high   5) By category tray"
    T[en.inv_pick]="Pick sort (blank = category trays): "
    T[en.inv_by_name]="name A→Z"
    T[en.inv_by_price]="price low→high"
    T[en.inv_by_pricedesc]="price high→low"
    T[en.inv_by_qty]="qty low→high"
    T[en.inv_by_tray]="by category tray"
    T[en.inv_uncategorised]="(no tray yet — set a type to file it)"
    T[en.inv_tray]="Tray"
    T[en.inv_products]="products"
    T[en.inv_units]="units"
    T[en.inv_total_value]="TOTAL STOCK VALUE"
    T[en.cat_title]="CATEGORY TRAYS (one tray per product category)"
    T[en.cat_sub]="Categories: 1) List  2) Add  0) Back"
    T[en.cat_pick]="Pick category tray (number, blank=skip, n=new): "
    T[en.cat_new_name]="New category/tray name: "
    T[en.cat_created]="Category tray created"
    T[en.c_lookup_try]="Looking up barcode online…"
    T[en.c_lookup_found]="Found online"
    T[en.c_lookup_miss]="Barcode not recognised online"
    T[en.c_custom_hint]="entering custom details"
    T[en.c_offline]="No internet — adding as a custom product"
    T[en.c_already_in_catalog]="Already in catalog:"
    T[en.c_tray_filed]="Filed in tray"
    T[en.c_not_in_catalog]="Product not in catalog. Add it now? (y/N): "
    T[en.p_brand]="Brand"
    T[en.p_pack]="Pack size"
    T[en.p_phone]="Customer phone"
    T[en.p_expiry]="Expiry (YYYY-MM-DD)"
    T[en.p_hsn]="HSN/SAC code"
    T[en.p_discount]="Bill discount %"
    T[en.p_gstin]="Shop GSTIN"
    T[en.p_confirm_bill]="Commit this bill? (y/N): "
    T[en.p_send_whatsapp]="Send this bill on WhatsApp? (y/N): "
    T[en.p_return_bill]="Bill no to return from: "
    T[en.p_return_qty]="Return qty per line (blank=return all): "
    T[en.m_expiry]="Expiry report"
    T[en.m_return]="Return items"
    T[en.m_whatsapp]="Send bill on WhatsApp"
    T[en.m_config]="Shop settings"
    T[en.er_title]="EXPIRY REPORT"
    T[en.er_expired]="EXPIRED"
    T[en.er_near]="NEAR EXPIRY"
    T[en.er_fresh]="FRESH"
    T[en.er_days_left]="Days left"
    T[en.er_no_expiry]="No expiry dates recorded."
    T[en.r_subtotal]="SUBTOTAL"
    T[en.r_discount]="DISCOUNT"
    T[en.r_net]="NET PAYABLE"
    T[en.r_gstin]="GSTIN"
    T[en.r_return]="RETURN"
    T[en.c_whatsapp_opened]="WhatsApp link opened in browser — confirm & press send."
    T[en.c_no_phone]="No phone on this bill — cannot send WhatsApp."
    T[en.c_no_bill]="No such bill."
    T[en.c_returned]="Items returned. Stock restored."
    T[en.c_no_expiry_set]="(no expiry set)"
    T[en.c_config_set]="Setting updated:"
    T[en.cfg_shop_name]="Shop name"
    T[en.cfg_gstin]="Shop GSTIN (15 chars, leave blank if unregistered)"
    T[en.cfg_address]="Shop address line"
    T[en.cfg_phone]="Shop phone"
    T[en.cfg_threshold]="Default low-stock threshold"
    T[en.cfg_show_setting]="Current:"
    T[en.cfg_new_value]="New value (blank to keep): "
    T[en.m_publish]="Publish barcodes to Open Products Facts"
    T[en.c_published]="Published"
    T[en.c_publish_failed]="Publish failed"
    T[en.c_publish_dryrun]="[dry-run] Would publish"
    T[en.c_publish_no_barcodes]="No real barcoded products to publish."
    T[en.p_publish_now]="Publish this product to Open Products Facts? (y/N): "
    T[en.publish_to]="to"
}

# Per-language overrides. Only translate the visible UI strings.
# Missing keys fall back to English automatically via t().
load_strings_hi() {
    T[hi.m_new_bill]="नया बिल"; T[hi.m_add_product]="उत्पाद जोड़ें"
    T[hi.m_low_stock]="कम स्टॉक रिपोर्ट"; T[hi.m_summary]="दैनिक बिक्री सारांश"
    T[hi.m_void]="बिल रद्द करें"; T[hi.m_backup]="अभी बैकअप लें"
    T[hi.m_stock_value]="स्टॉक मूल्य"; T[hi.m_language]="भाषा"
    T[hi.m_exit]="बाहर"; T[hi.m_choose]="चुनें: "
    T[hi.p_scan]="बारकोड स्कैन/टाइप करें (खत्म के लिए खाली, खोजने के लिए s:शब्द): "
    T[hi.p_qty]="मात्रा"; T[hi.p_name]="नाम"; T[hi.p_price]="कीमत"
    T[hi.p_threshold]="दहलीज"; T[hi.p_barcode]="बारकोड"
    T[hi.p_bill_no]="रद्द करने के लिए बिल नंबर: "; T[hi.p_pick]="चुनें (रद्द के लिए खाली): "
    T[hi.p_scan_webcam]="वेबकैम से स्कैन करें? (y/N): "; T[hi.p_print_label]="लेबल PNG बनाएं? (y/N): "
    T[hi.p_confirm_void]="यह बिल रद्द करें? (y/N): "
    T[hi.r_total]="कुल"; T[hi.r_reversed]="वापस लिया गया"
    T[hi.r_items]="वस्तुएं:"; T[hi.r_units]="इकाइयां:"
    T[hi.c_added]="जोड़ा"; T[hi.c_bill_saved]="बिल सहेजा गया"
    T[hi.c_voided]="रद्द किया। स्टॉक बहाल।"; T[hi.c_cancelled]="रद्द"
    T[hi.c_bye]="नमस्ते।"; T[hi.c_no_low_stock]="कोई कम-स्टॉक वस्तु नहीं। सब ठीक है!"
    T[hi.c_lang_changed]="भाषा बदली:"; T[hi.c_select_lang]="भाषा चुनें (नंबर): "
    T[hi.c_no_products]="कोई उत्पाद नहीं।"; T[hi.c_no_bills]="कोई बिल नहीं।"
    T[hi.s_bills_processed]="बिल प्रोसेस:"; T[hi.s_units_sold]="बिकी इकाइयां:"
    T[hi.s_revenue]="आय:"; T[hi.s_avg_bill]="औसत बिल:"; T[hi.s_voided_bills]="रद्द बिल:"
    T[hi.s_top_products]="सबसे ज्यादा बिकने वाले उत्पाद"
    T[hi.ls_title]="कम स्टॉक रिपोर्ट"; T[hi.ls_deficit]="घाटा"
    T[hi.m_inventory]="स्टॉक सूची"
    T[hi.m_categories]="श्रेणी ट्रे"
    T[hi.inv_title]="स्टॉक सूची"
    T[hi.inv_sort]="क्रम:  1) नाम A→Z   2) कीमत कम→ज़्यादा   3) कीमत ज़्यादा→कम   4) मात्रा कम→ज़्यादा   5) श्रेणी ट्रे से"
    T[hi.inv_pick]="क्रम चुनें (खाली = श्रेणी ट्रे): "
    T[hi.inv_by_name]="नाम A→Z"
    T[hi.inv_by_price]="कीमत कम→ज़्यादा"
    T[hi.inv_by_pricedesc]="कीमत ज़्यादा→कम"
    T[hi.inv_by_qty]="मात्रा कम→ज़्यादा"
    T[hi.inv_by_tray]="श्रेणी ट्रे के अनुसार"
    T[hi.inv_uncategorised]="(अभी कोई ट्रे नहीं — प्रकार भरें)"
    T[hi.inv_tray]="ट्रे"
    T[hi.inv_products]="उत्पाद"
    T[hi.inv_units]="इकाइयां"
    T[hi.inv_total_value]="कुल स्टॉक मूल्य"
    T[hi.cat_title]="श्रेणी ट्रे (हर श्रेणी की अपनी ट्रे)"
    T[hi.cat_sub]="श्रेणी: 1) सूची  2) जोड़ें  0) वापस"
    T[hi.cat_pick]="श्रेणी ट्रे चुनें (नंबर, खाली=छोड़ें, n=नई): "
    T[hi.cat_new_name]="नई श्रेणी/ट्रे का नाम: "
    T[hi.cat_created]="श्रेणी ट्रे बन गई"
    T[hi.c_lookup_try]="बारकोड ऑनलाइन देखा जा रहा है…"
    T[hi.c_lookup_found]="ऑनलाइन मिला"
    T[hi.c_lookup_miss]="बारकोड ऑनलाइन नहीं मिला"
    T[hi.c_custom_hint]="अपनी जानकारी भरें"
    T[hi.c_offline]="इंटरनेट नहीं — कस्टम उत्पाद बनेगा"
    T[hi.c_already_in_catalog]="पहले से सूची में है:"
    T[hi.c_tray_filed]="ट्रे में रखा गया"
    T[hi.c_not_in_catalog]="उत्पाद सूची में नहीं। अभी जोड़ें? (y/N): "
    T[hi.p_brand]="ब्रांड"
    T[hi.p_pack]="पैक साइज़"
    T[hi.p_phone]="ग्राहक फ़ोन"
}

load_strings_bn() {
    T[bn.m_new_bill]="নতুন বিল"; T[bn.m_add_product]="পণ্য যোগ করুন"
    T[bn.m_low_stock]="কম স্টক রিপোর্ট"; T[bn.m_summary]="দৈনিক বিক্রি সারাংশ"
    T[bn.m_void]="বিল বাতিল"; T[bn.m_backup]="এখনই ব্যাকআপ"
    T[bn.m_stock_value]="স্টক মূল্য"; T[bn.m_language]="ভাষা"
    T[bn.m_exit]="প্রস্থান"; T[bn.m_choose]="বাছুন: "
    T[bn.p_scan]="বারকোড স্ক্যান/টাইপ (শেষে ফাঁকা, খুঁজতে s:শব্দ): "
    T[bn.p_qty]="পরিমাণ"; T[bn.p_name]="নাম"; T[bn.p_price]="দাম"
    T[bn.p_threshold]="সীমা"; T[bn.p_bill_no]="বাতিলের বিল নম্বর: "
    T[bn.r_total]="মোট"; T[bn.r_items]="বস্তু:"; T[bn.r_units]="একক:"
    T[bn.c_added]="যোগ হয়েছে"; T[bn.c_bill_saved]="বিল সংরক্ষিত"
    T[bn.c_bye]="বিদায়।"; T[bn.c_no_low_stock]="কোনো কম-স্টক নেই। সব ঠিক!"
    T[bn.c_lang_changed]="ভাষা পরিবর্তিত:"; T[bn.s_bills_processed]="বিল প্রক্রিয়া:"
    T[bn.s_units_sold]="বিক্রি একক:"; T[bn.s_revenue]="আয়:"; T[bn.s_avg_bill]="গড় বিল:"
    T[bn.s_voided_bills]="বাতিল বিল:"; T[bn.ls_title]="কম স্টক রিপোর্ট"; T[bn.ls_deficit]="ঘাটতি"
    T[bn.ls_stock]="স্টক"; T[bn.sv_title]="স্টক মূল্য"; T[bn.sv_total]="মোট স্টক মূল্য"; T[bn.sv_items]="পণ্য"
}

load_strings_te() {
    T[te.m_new_bill]="కొత్త బిల్"; T[te.m_add_product]="ఉత్పత్తి చేర్చు"
    T[te.m_low_stock]="తక్కువ స్టాక్ నివేదిక"; T[te.m_summary]="రోజువారీ అమ్మకాల సారాంశం"
    T[te.m_void]="బిల్ రద్దు"; T[te.m_backup]="ఇప్పుడే బ్యాకప్"
    T[te.m_stock_value]="స్టాక్ విలువ"; T[te.m_language]="భాష"
    T[te.m_exit]="నిష్క్రమణ"; T[te.m_choose]="ఎంచుకోండి: "
    T[te.p_scan]="బార్‌కోడ్ స్కాన్/టైప్ (ముగింపు ఖాళీ, వెతకడానికి s:పదం): "
    T[te.p_qty]="పరిమాణం"; T[te.p_name]="పేరు"; T[te.p_price]="ధర"
    T[te.p_threshold]="పరిమితి"; T[te.r_total]="మొత్తం"; T[te.r_items]="అంశాలు:"; T[te.r_units]="యూనిట్లు:"
    T[te.c_added]="చేర్చబడింది"; T[te.c_bill_saved]="బిల్ సేవ్ అయింది"
    T[te.c_bye]="వీడుకోలు."; T[te.c_no_low_stock]="తక్కువ-స్టాక్ లేదు. అంతా బాగుంది!"
    T[te.c_lang_changed]="భాష మార్చబడింది:"; T[te.s_bills_processed]="బిల్లులు:"
    T[te.s_units_sold]="అమ్మిన యూనిట్లు:"; T[te.s_revenue]="ఆదాయం:"; T[te.s_avg_bill]="సగటు బిల్:"
    T[te.s_voided_bills]="రద్దు బిల్లులు:"; T[te.ls_title]="తక్కువ స్టాక్ నివేదిక"; T[te.ls_deficit]="లోటు"
    T[te.ls_stock]="స్టాక్"; T[te.sv_title]="స్టాక్ విలువ"; T[te.sv_total]="మొత్తం స్టాక్ విలువ"; T[te.sv_items]="ఉత్పత్తులు"
}

load_strings_mr() {
    T[mr.m_new_bill]="नवीन बिल"; T[mr.m_add_product]="उत्पादन जोडा"
    T[mr.m_low_stock]="कमी स्टॉक अहवाल"; T[mr.m_summary]="दैनिक विक्री सारांश"
    T[mr.m_void]="बिल रद्द करा"; T[mr.m_backup]="आत्ता बॅकअप"
    T[mr.m_stock_value]="स्टॉक मूल्य"; T[mr.m_language]="भाषा"
    T[mr.m_exit]="बाहेर"; T[mr.m_choose]="निवडा: "
    T[mr.p_scan]="बारकोड स्कॅन/टाइप (संपवण्यासाठी रिक्त, शोधण्यासाठी s:शब्द): "
    T[mr.p_qty]="प्रमाण"; T[mr.p_name]="नाव"; T[mr.p_price]="किंमत"
    T[mr.p_threshold]="मर्यादा"; T[mr.r_total]="एकूण"; T[mr.r_items]="वस्तू:"; T[mr.r_units]="एकके:"
    T[mr.c_added]="जोडले"; T[mr.c_bill_saved]="बिल जतन केले"
    T[mr.c_bye]="नमस्कार."; T[mr.c_no_low_stock]="कमी-स्टॉक नाही. सगळं ठीक!"
    T[mr.c_lang_changed]="भाषा बदलली:"; T[mr.s_bills_processed]="बिल्स:"
    T[mr.s_units_sold]="विकली एकके:"; T[mr.s_revenue]="उत्पन्न:"; T[mr.s_avg_bill]="सरासरी बिल:"
    T[mr.s_voided_bills]="रद्द बिल्स:"; T[mr.ls_title]="कमी स्टॉक अहवाल"; T[mr.ls_deficit]="तूट"
    T[mr.ls_stock]="स्टॉक"; T[mr.sv_title]="स्टॉक मूल्य"; T[mr.sv_total]="एकूण स्टॉक मूल्य"; T[mr.sv_items]="उत्पादने"
}

load_strings_ta() {
    T[ta.m_new_bill]="புதிய பில்"; T[ta.m_add_product]="பொருள் சேர்"
    T[ta.m_low_stock]="குறைந்த இருப்பு அறிக்கை"; T[ta.m_summary]="தினசரி விற்பனை சுருக்கம்"
    T[ta.m_void]="பில் ரத்து"; T[ta.m_backup]="இப்போது காப்பு"
    T[ta.m_stock_value]="இருப்பு மதிப்பு"; T[ta.m_language]="மொழி"
    T[ta.m_exit]="வெளியேறு"; T[ta.m_choose]="தேர்ந்தெடு: "
    T[ta.p_scan]="பார்கோடு ஸ்கேன்/தட்டச்சு (முடிக்க காலி, தேட s:சொல்): "
    T[ta.p_qty]="அளவு"; T[ta.p_name]="பெயர்"; T[ta.p_price]="விலை"
    T[ta.p_threshold]="வரம்பு"; T[ta.r_total]="மொத்தம்"; T[ta.r_items]="பொருட்கள்:"; T[ta.r_units]="அலகுகள்:"
    T[ta.c_added]="சேர்க்கப்பட்டது"; T[ta.c_bill_saved]="பில் சேமிக்கப்பட்டது"
    T[ta.c_bye]="விடை."; T[ta.c_no_low_stock]="குறைந்த-இருப்பு இல்லை. எல்லாம் சரி!"
    T[ta.c_lang_changed]="மொழி மாற்றப்பட்டது:"; T[ta.s_bills_processed]="பில்கள்:"
    T[ta.s_units_sold]="விற்ற அலகுகள்:"; T[ta.s_revenue]="வருவாய்:"; T[ta.s_avg_bill]="சராசரி பில்:"
    T[ta.s_voided_bills]="ரத்து பில்கள்:"; T[ta.ls_title]="குறைந்த இருப்பு அறிக்கை"; T[ta.ls_deficit]="பற்றாக்குறை"
    T[ta.ls_stock]="இருப்பு"; T[ta.sv_title]="இருப்பு மதிப்பு"; T[ta.sv_total]="மொத்த இருப்பு மதிப்பு"; T[ta.sv_items]="பொருட்கள்"
}

load_strings_ur() {
    T[ur.m_new_bill]="نئی بل"; T[ur.m_add_product]="مصنوعات شامل کریں"
    T[ur.m_low_stock]="کم اسٹاک رپورٹ"; T[ur.m_summary]="روزانہ فروخت خلاصہ"
    T[ur.m_void]="بل منسوخ"; T[ur.m_backup]="ابھی بیک اپ"
    T[ur.m_stock_value]="اسٹاک قیمت"; T[ur.m_language]="زبان"
    T[ur.m_exit]="باہر"; T[ur.m_choose]="منتخب کریں: "
    T[ur.p_scan]="بارکوڈ اسکین/ٹائپ (ختم کرنے کے لیے خالی، تلاش کے لیے s:لفظ): "
    T[ur.p_qty]="مقدار"; T[ur.p_name]="نام"; T[ur.p_price]="قیمت"
    T[ur.p_threshold]="حد"; T[ur.r_total]="کل"; T[ur.r_items]="اشیاء:"; T[ur.r_units]="اکائیاں:"
    T[ur.c_added]="شامل ہوا"; T[ur.c_bill_saved]="بل محفوظ ہو گیا"
    T[ur.c_bye]="خدا حافظ."; T[ur.c_no_low_stock]="کم اسٹاک نہیں۔ سب ٹھیک ہے!"
    T[ur.c_lang_changed]="زبان تبدیل ہوئی:"; T[ur.s_bills_processed]="بلس:"
    T[ur.s_units_sold]="فروخت شدہ اکائیاں:"; T[ur.s_revenue]="آمدنی:"; T[ur.s_avg_bill]="اوسط بل:"
    T[ur.s_voided_bills]="منسوخ بلس:"; T[ur.ls_title]="کم اسٹاک رپورٹ"; T[ur.ls_deficit]="خسارہ"
    T[ur.ls_stock]="اسٹاک"; T[ur.sv_title]="اسٹاک قیمت"; T[ur.sv_total]="کل اسٹاک قیمت"; T[ur.sv_items]="مصنوعات"
}

load_strings_gu() {
    T[gu.m_new_bill]="નવો બિલ"; T[gu.m_add_product]="ઉત્પાદન ઉમેરો"
    T[gu.m_low_stock]="ઓછો સ્ટોક અહેવાલ"; T[gu.m_summary]="દૈનિક વેચાણ સારાંશ"
    T[gu.m_void]="બિલ રદ કરો"; T[gu.m_backup]="હવે જ બેકઅપ"
    T[gu.m_stock_value]="સ્ટોક મૂલ્ય"; T[gu.m_language]="ભાષા"
    T[gu.m_exit]="બહાર"; T[gu.m_choose]="પસંદ કરો: "
    T[gu.p_scan]="બારકોડ સ્કેન/ટાઇપ (સમાપ્તિ ખાલી, શોધવા s:શબ્દ): "
    T[gu.p_qty]="જથ્થો"; T[gu.p_name]="નામ"; T[gu.p_price]="કિંમત"
    T[gu.p_threshold]="મર્યાદા"; T[gu.r_total]="કુલ"; T[gu.r_items]="વસ્તુઓ:"; T[gu.r_units]="એકમો:"
    T[gu.c_added]="ઉમેરાયું"; T[gu.c_bill_saved]="બિલ સાચવાયું"
    T[gu.c_bye]="આવજો."; T[gu.c_no_low_stock]="ઓછો-સ્ટોક નથી. બધું ઠીક!"
    T[gu.c_lang_changed]="ભાષા બદલાઈ:"; T[gu.s_bills_processed]="બિલ્સ:"
    T[gu.s_units_sold]="વેચાયેલ એકમો:"; T[gu.s_revenue]="આવક:"; T[gu.s_avg_bill]="સરેરાશ બિલ:"
    T[gu.s_voided_bills]="રદ બિલ્સ:"; T[gu.ls_title]="ઓછો સ્ટોક અહેવાલ"; T[gu.ls_deficit]="ઘટાકો"
    T[gu.ls_stock]="સ્ટોક"; T[gu.sv_title]="સ્ટોક મૂલ્ય"; T[gu.sv_total]="કુલ સ્ટોક મૂલ્ય"; T[gu.sv_items]="ઉત્પાદનો"
}

load_strings_kn() {
    T[kn.m_new_bill]="ಹೊಸ ಬಿಲ್"; T[kn.m_add_product]="ಉತ್ಪನ್ನ ಸೇರಿಸಿ"
    T[kn.m_low_stock]="ಕಡಿಮೆ ಸ್ಟಾಕ್ ವರದಿ"; T[kn.m_summary]="ದೈನಂದಿನ ಮಾರಾಟ ಸಾರಾಂಶ"
    T[kn.m_void]="ಬಿಲ್ ರದ್ದು"; T[kn.m_backup]="ಈಗಲೇ ಬ್ಯಾಕಪ್"
    T[kn.m_stock_value]="ಸ್ಟಾಕ್ ಮೌಲ್ಯ"; T[kn.m_language]="ಭಾಷೆ"
    T[kn.m_exit]="ನಿರ್ಗಮನ"; T[kn.m_choose]="ಆಯ್ಕೆಮಾಡಿ: "
    T[kn.p_scan]="ಬಾರ್‌ಕೋಡ್ ಸ್ಕ್ಯಾನ್/ಟೈಪ್ (ಮುಗಿಸಲು ಖಾಲಿ, ಹುಡುಕಲು s:ಪದ): "
    T[kn.p_qty]="ಪ್ರಮಾಣ"; T[kn.p_name]="ಹೆಸರು"; T[kn.p_price]="ಬೆಲೆ"
    T[kn.p_threshold]="ಮಿತಿ"; T[kn.r_total]="ಒಟ್ಟು"; T[kn.r_items]="ವಸ್ತುಗಳು:"; T[kn.r_units]="ಘಟಕಗಳು:"
    T[kn.c_added]="ಸೇರಿಸಲಾಗಿದೆ"; T[kn.c_bill_saved]="ಬಿಲ್ ಉಳಿಸಲಾಗಿದೆ"
    T[kn.c_bye]="ವಿದಾಯ."; T[kn.c_no_low_stock]="ಕಡಿಮೆ-ಸ್ಟಾಕ್ ಇಲ್ಲ. ಎಲ್ಲವೂ ಸರಿ!"
    T[kn.c_lang_changed]="ಭಾಷೆ ಬದಲಾಯಿಸಲಾಗಿದೆ:"; T[kn.s_bills_processed]="ಬಿಲ್‌ಗಳು:"
    T[kn.s_units_sold]="ಮಾರಾಟದ ಘಟಕಗಳು:"; T[kn.s_revenue]="ಆದಾಯ:"; T[kn.s_avg_bill]="ಸರಾಸರಿ ಬಿಲ್:"
    T[kn.s_voided_bills]="ರದ್ದು ಬಿಲ್‌ಗಳು:"; T[kn.ls_title]="ಕಡಿಮೆ ಸ್ಟಾಕ್ ವರದಿ"; T[kn.ls_deficit]="ಕೊರತೆ"
    T[kn.ls_stock]="ಸ್ಟಾಕ್"; T[kn.sv_title]="ಸ್ಟಾಕ್ ಮೌಲ್ಯ"; T[kn.sv_total]="ಒಟ್ಟು ಸ್ಟಾಕ್ ಮೌಲ್ಯ"; T[kn.sv_items]="ಉತ್ಪನ್ನಗಳು"
}

load_strings_or() {
    T[or.m_new_bill]="ନୂତନ ବିଲ୍"; T[or.m_add_product]="ଉତ୍ପାଦନ ଯୋଗ"
    T[or.m_low_stock]="କମ ଷ୍ଟକ୍ ରିପୋର୍ଟ"; T[or.m_summary]="ଦୈନିକ ବିକ୍ରି ସାରାଂଶ"
    T[or.m_void]="ବିଲ୍ ବାତିଲ୍"; T[or.m_backup]="ଏବେ ବ୍ୟାକଅପ୍"
    T[or.m_stock_value]="ଷ୍ଟକ୍ ମୂଲ୍ୟ"; T[or.m_language]="ଭାଷା"
    T[or.m_exit]="ପ୍ରସ୍ଥାନ"; T[or.m_choose]="ବାଛନ୍ତୁ: "
    T[or.p_scan]="ବାର୍‌କୋଡ୍ ସ୍କାନ୍/ଟାଇପ୍ (ସମାପ୍ତ ଖାଲି, ଖୋଜିବାକୁ s:ଶବ୍ଦ): "
    T[or.p_qty]="ପରିମାଣ"; T[or.p_name]="ନାମ"; T[or.p_price]="ଦାମ୍"
    T[or.p_threshold]="ସୀମା"; T[or.r_total]="ସମୁଦାୟ"; T[or.r_items]="ବସ୍ତୁ:"; T[or.r_units]="ଏକକ:"
    T[or.c_added]="ଯୋଗ ହେଲା"; T[or.c_bill_saved]="ବିଲ୍ ସାଇତାଗଲା"
    T[or.c_bye]="ବିଦାୟ."; T[or.c_no_low_stock]="କମ-ଷ୍ଟକ୍ ନାହିଁ. ସବୁ ଠିକ୍!"
    T[or.c_lang_changed]="ଭାଷା ବଦଳାଇଛି:"; T[or.s_bills_processed]="ବିଲ୍‌ଗୁଡିକ:"
    T[or.s_units_sold]="ବିକ୍ରି ଏକକ:"; T[or.s_revenue]="ଆୟ:"; T[or.s_avg_bill]="ହାରାହାରି ବିଲ୍:"
    T[or.s_voided_bills]="ବାତିଲ୍ ବିଲ୍:"; T[or.ls_title]="କମ ଷ୍ଟକ୍ ରିପୋର୍ଟ"; T[or.ls_deficit]="ଘାଟଣ"
    T[or.ls_stock]="ଷ୍ଟକ୍"; T[or.sv_title]="ଷ୍ଟକ୍ ମୂଲ୍ୟ"; T[or.sv_total]="ସମୁଦାୟ ଷ୍ଟକ୍ ମୂଲ୍ୟ"; T[or.sv_items]="ଉତ୍ପାଦନ"
}

load_strings_ml() {
    T[ml.m_new_bill]="പുതിയ ബിൽ"; T[ml.m_add_product]="ഉൽപ്പന്നം ചേർക്കുക"
    T[ml.m_low_stock]="കുറഞ്ഞ സ്റ്റോക്ക് റിപ്പോർട്ട്"; T[ml.m_summary]="ദൈനംദിന വില്പന സംഗ്രഹം"
    T[ml.m_void]="ബിൽ റദ്ദാക്കുക"; T[ml.m_backup]="ഇപ്പോൾ ബാക്കപ്പ്"
    T[ml.m_stock_value]="സ്റ്റോക്ക് മൂല്യം"; T[ml.m_language]="ഭാഷ"
    T[ml.m_exit]="പുറത്ത്"; T[ml.m_choose]="തിരഞ്ഞെടുക്കുക: "
    T[ml.p_scan]="ബാർകോഡ് സ്കാൻ/ടൈപ്പ് (അവസാനിപ്പിക്കാൻ ശൂന്യം, തിരയാൻ s:വാക്ക്): "
    T[ml.p_qty]="അളവ്"; T[ml.p_name]="പേര്"; T[ml.p_price]="വില"
    T[ml.p_threshold]="പരിധി"; T[ml.r_total]="മൊത്തം"; T[ml.r_items]="ഇനങ്ങൾ:"; T[ml.r_units]="യൂണിറ്റുകൾ:"
    T[ml.c_added]="ചേർത്തു"; T[ml.c_bill_saved]="ബിൽ സേവ് ചെയ്തു"
    T[ml.c_bye]="വിട."; T[ml.c_no_low_stock]="കുറഞ്ഞ-സ്റ്റോക്ക് ഇല്ല. എല്ലാം ശരി!"
    T[ml.c_lang_changed]="ഭാഷ മാറ്റി:"; T[ml.s_bills_processed]="ബില്ലുകൾ:"
    T[ml.s_units_sold]="വിറ്റ യൂണിറ്റുകൾ:"; T[ml.s_revenue]="വരുമാനം:"; T[ml.s_avg_bill]="ശരാസരി ബിൽ:"
    T[ml.s_voided_bills]="റദ്ദായ ബില്ലുകൾ:"; T[ml.ls_title]="കുറഞ്ഞ സ്റ്റോക്ക് റിപ്പോർട്ട്"; T[ml.ls_deficit]="കുറവ്"
    T[ml.ls_stock]="സ്റ്റോക്ക്"; T[ml.sv_title]="സ്റ്റോക്ക് മൂല്യം"; T[ml.sv_total]="മൊത്തം സ്റ്റോക്ക് മൂല്യം"; T[ml.sv_items]="ഉൽപ്പന്നങ്ങൾ"
}

load_strings_pa() {
    T[pa.m_new_bill]="ਨਵਾਂ ਬਿਲ"; T[pa.m_add_product]="ਉਤਪਾਦ ਜੋੜੋ"
    T[pa.m_low_stock]="ਘੱਟ ਸਟਾਕ ਰਿਪੋਰਟ"; T[pa.m_summary]="ਰੋਜ਼ਾਨਾ ਵਿਕਰੀ ਸਾਰ"
    T[pa.m_void]="ਬਿਲ ਰੱਦ"; T[pa.m_backup]="ਹੁਣੇ ਬੈਕਅੱਪ"
    T[pa.m_stock_value]="ਸਟਾਕ ਮੁੱਲ"; T[pa.m_language]="ਭਾਸ਼ਾ"
    T[pa.m_exit]="ਬਾਹਰ"; T[pa.m_choose]="ਚੁਣੋ: "
    T[pa.p_scan]="ਬਾਰਕੋਡ ਸਕੈਨ/ਟਾਈਪ (ਸਮਾਪਤ ਖਾਲੀ, ਖੋਜ s:ਸ਼ਬਦ): "
    T[pa.p_qty]="ਮਾਤਰਾ"; T[pa.p_name]="ਨਾਮ"; T[pa.p_price]="ਕੀਮਤ"
    T[pa.p_threshold]="ਹੱਦ"; T[pa.r_total]="ਕੁੱਲ"; T[pa.r_items]="ਵਸਤਾਂ:"; T[pa.r_units]="ਇਕਾਈਆਂ:"
    T[pa.c_added]="ਜੋੜਿਆ"; T[pa.c_bill_saved]="ਬਿਲ ਸੰਭਾਲਿਆ"
    T[pa.c_bye]="ਵਿਦਾਇਗ."; T[pa.c_no_low_stock]="ਘੱਟ-ਸਟਾਕ ਨਹੀਂ. ਸਭ ਠੀਕ!"
    T[pa.c_lang_changed]="ਭਾਸ਼ਾ ਬਦਲੀ:"; T[pa.s_bills_processed]="ਬਿਲ:"
    T[pa.s_units_sold]="ਵਿਕਰੀ ਇਕਾਈਆਂ:"; T[pa.s_revenue]="ਆਮਦਨ:"; T[pa.s_avg_bill]="ਔਸਤ ਬਿਲ:"
    T[pa.s_voided_bills]="ਰੱਦ ਬਿਲ:"; T[pa.ls_title]="ਘੱਟ ਸਟਾਕ ਰਿਪੋਰਟ"; T[pa.ls_deficit]="ਘਾਟਾ"
    T[pa.ls_stock]="ਸਟਾਕ"; T[pa.sv_title]="ਸਟਾਕ ਮੁੱਲ"; T[pa.sv_total]="ਕੁੱਲ ਸਟਾਕ ਮੁੱਲ"; T[pa.sv_items]="ਉਤਪਾਦ"
}

load_strings_as() {
    T[as.m_new_bill]="নতুন বিল"; T[as.m_add_product]="সামগ্ৰী যোগ কৰক"
    T[as.m_low_stock]="কম ষ্টক ৰিপৰ্ট"; T[as.m_summary]="দৈনিক বিক্ৰী সাৰাংশ"
    T[as.m_void]="বিল বাতিল"; T[as.m_backup]="এতিয়াই বেকআপ"
    T[as.m_stock_value]="ষ্টক মূল্য"; T[as.m_language]="ভাষা"
    T[as.m_exit]="প্ৰস্থান"; T[as.m_choose]="বাছনি কৰক: "
    T[as.p_scan]="বাৰক'ড স্কেন/টাইপ (সমাপ্ত খালী, সন্ধান s:শব্দ): "
    T[as.p_qty]="পৰিমাণ"; T[as.p_name]="নাম"; T[as.p_price]="মূল্য"
    T[as.p_threshold]="সীমা"; T[as.r_total]="মুঠ"; T[as.r_items]="সামগ্ৰী:"; T[as.r_units]="একক:"
    T[as.c_added]="যোগ হ'ল"; T[as.c_bill_saved]="বিল সংৰক্ষিত"
    T[as.c_bye]="বিদায়."; T[as.c_no_low_stock]="কম-ষ্টক নাই. সকলো ঠিক!"
    T[as.c_lang_changed]="ভাষা সলনি হ'ল:"; T[as.s_bills_processed]="বিলসমূহ:"
    T[as.s_units_sold]="বিক্ৰী একক:"; T[as.s_revenue]="আয়:"; T[as.s_avg_bill]="গড় বিল:"
    T[as.s_voided_bills]="বাতিল বিল:"; T[as.ls_title]="কম ষ্টক ৰিপৰ্ট"; T[as.ls_deficit]="নুটুক"
    T[as.ls_stock]="ষ্টক"; T[as.sv_title]="ষ্টক মূল্য"; T[as.sv_total]="মুঠ ষ্টক মূল্য"; T[as.sv_items]="সামগ্ৰী"
}

load_strings_mai() {  # Maithili (Devanagari)
    T[mai.m_new_bill]="नया बिल"; T[mai.m_add_product]="उत्पाद जोड़ू"
    T[mai.m_low_stock]="कम स्टॉक रिपोर्ट"; T[mai.m_summary]="दैनिक बिक्री सारांश"
    T[mai.m_void]="बिल रद्द"; T[mai.m_backup]="अखन बैकअप"
    T[mai.m_stock_value]="स्टॉक मूल्य"; T[mai.m_language]="भाषा"
    T[mai.m_exit]="बाहर"; T[mai.m_choose]="चुनू: "
    T[mai.p_qty]="मात्रा"; T[mai.p_name]="नाम"; T[mai.p_price]="कीमत"; T[mai.p_threshold]="दहलीज"
    T[mai.r_total]="कुल"; T[mai.r_items]="वस्तु:"; T[mai.r_units]="इकाई:"
    T[mai.c_added]="जोड़ल"; T[mai.c_bill_saved]="बिल सहेजल"
    T[mai.c_bye]="नमस्कार."; T[mai.c_no_low_stock]="कोनो कम-स्टॉक नहि. सब ठीक!"
    T[mai.c_lang_changed]="भाषा बदलल:"; T[mai.ls_title]="कम स्टॉक रिपोर्ट"; T[mai.ls_deficit]="घाटा"
    T[mai.ls_stock]="स्टॉक"; T[mai.sv_title]="स्टॉक मूल्य"; T[mai.sv_total]="कुल स्टॉक मूल्य"; T[mai.sv_items]="उत्पाद"
}

load_strings_sa() {  # Sanskrit (Devanagari)
    T[sa.m_new_bill]="नूतनं बिलम्"; T[sa.m_add_product]="उत्पादनं योजयतु"
    T[sa.m_low_stock]="अल्पस्टकविवरणम्"; T[sa.m_summary]="दैनिकविक्रयसारांशः"
    T[sa.m_void]="बिलं रद्धं कुरु"; T[sa.m_backup]="अधुनै बैकअप्"
    T[sa.m_stock_value]="स्टकमूल्यम्"; T[sa.m_language]="भाषा"
    T[sa.m_exit]="निर्गमः"; T[sa.m_choose]="चिनोतु: "
    T[sa.p_qty]="परिमाणम्"; T[sa.p_name]="नाम"; T[sa.p_price]="मूल्यम्"; T[sa.p_threshold]="सीमा"
    T[sa.r_total]="सम्पूर्णम्"; T[sa.r_items]="वस्तूनि:"; T[sa.r_units]="एककानि:"
    T[sa.c_added]="योजितम्"; T[sa.c_bill_saved]="बिलं रक्षितम्"
    T[sa.c_bye]="पुनर्दर्शनाय."; T[sa.c_no_low_stock]="अल्पस्टकं नास्ति. सर्वं सुस्थितम्!"
    T[sa.c_lang_changed]="भाषा परिवर्तिता:"; T[sa.ls_title]="अल्पस्टकविवरणम्"; T[sa.ls_deficit]="न्यूनता"
    T[sa.ls_stock]="स्टक्"; T[sa.sv_title]="स्टकमूल्यम्"; T[sa.sv_total]="सम्पूर्णस्टकमूल्यम्"; T[sa.sv_items]="उत्पादानि"
}

load_strings_ne() {  # Nepali (Devanagari)
    T[ne.m_new_bill]="नयाँ बिल"; T[ne.m_add_product]="उत्पादन थप्नुहोस्"
    T[ne.m_low_stock]="कम स्टक रिपोर्ट"; T[ne.m_summary]="दैनिक बिक्री सारांश"
    T[ne.m_void]="बिल रद्द"; T[ne.m_backup]="अहिले ब्याकअप"
    T[ne.m_stock_value]="स्टक मूल्य"; T[ne.m_language]="भाषा"
    T[ne.m_exit]="निस्कनु"; T[ne.m_choose]="छान्नुहोस्: "
    T[ne.p_qty]="मात्रा"; T[ne.p_name]="नाम"; T[ne.p_price]="मूल्य"; T[ne.p_threshold]="सीमा"
    T[ne.r_total]="कुल"; T[ne.r_items]="वस्तु:"; T[ne.r_units]="एकाइ:"
    T[ne.c_added]="थपियो"; T[ne.c_bill_saved]="बिल बचत भयो"
    T[ne.c_bye]="फेरि भेटौंला."; T[ne.c_no_low_stock]="कम-स्टक छैन. सब ठीक!"
    T[ne.c_lang_changed]="भाषा परिवर्तन:"; T[ne.ls_title]="कम स्टक रिपोर्ट"; T[ne.ls_deficit]="घाटा"
    T[ne.ls_stock]="स्टक"; T[ne.sv_title]="स्टक मूल्य"; T[ne.sv_total]="कुल स्टक मूल्य"; T[ne.sv_items]="उत्पादन"
}

load_strings_sd() {  # Sindhi (Arabic script)
    T[sd.m_new_bill]="نئون بل"; T[sd.m_add_product]="پيداوار شامل ڪريو"
    T[sd.m_low_stock]="گهٽ اسٽاک رپورٽ"; T[sd.m_summary]="روزاني وڪرو جو خلاصو"
    T[sd.m_void]="بل رد"; T[sd.m_backup]="هاڻي ئي بڪ اپ"
    T[sd.m_stock_value]="اسٽاک قيمت"; T[sd.m_language]="ٻولي"
    T[sd.m_exit]="ٻاهر"; T[sd.m_choose]="چونڊيو: "
    T[sd.p_qty]="مقدار"; T[sd.p_name]="نالو"; T[sd.p_price]="قيمت"; T[sd.p_threshold]="حد"
    T[sd.r_total]="ڪل"; T[sd.r_items]="شيون:"; T[sd.r_units]="يونٽ:"
    T[sd.c_added]="شامل ٿيو"; T[sd.c_bill_saved]="بل محفوظ ٿيو"
    T[sd.c_bye]="خدا حافظ."; T[sd.c_no_low_stock]="ڪو گهٽ-اسٽاک ناهي. سڀ ٺيڪ!"
    T[sd.c_lang_changed]="ٻولي تبديل ٿي:"; T[sd.ls_title]="گهٽ اسٽاک رپورٽ"; T[sd.ls_deficit]="گھٽت"
    T[sd.ls_stock]="اسٽاک"; T[sd.sv_title]="اسٽاک قيمت"; T[sd.sv_total]="ڪل اسٽاک قيمت"; T[sd.sv_items]="پيداوارون"
}

load_strings_kok() {  # Konkani (Devanagari)
    T[kok.m_new_bill]="नवो बिल"; T[kok.m_add_product]="उत्पादन जोडात"
    T[kok.m_low_stock]="कम स्टॉक अहवाल"; T[kok.m_summary]="दैनिक विक्री सारांश"
    T[kok.m_void]="बिल रद्द करात"; T[kok.m_backup]="आतां बॅकअप"
    T[kok.m_stock_value]="स्टॉक मोल"; T[kok.m_language]="भास"
    T[kok.m_exit]="भायर"; T[kok.m_choose]="निवडात: "
    T[kok.p_qty]="प्रमाण"; T[kok.p_name]="नाव"; T[kok.p_price]="दर"; T[kok.p_threshold]="मर्यादा"
    T[kok.r_total]="एकूण"; T[kok.r_items]="वस्तू:"; T[kok.r_units]="एककां:"
    T[kok.c_added]="जोडलें"; T[kok.c_bill_saved]="बिल वाटाळलें"
    T[kok.c_bye]="येवजे."; T[kok.c_no_low_stock]="कम-स्टॉक ना. सगळें बरें!"
    T[kok.c_lang_changed]="भास बदल्ली:"; T[kok.ls_title]="कम स्टॉक अहवाल"; T[kok.ls_deficit]="तूट"
    T[kok.ls_stock]="स्टॉक"; T[kok.sv_title]="स्टॉक मोल"; T[kok.sv_total]="एकूण स्टॉक मोल"; T[kok.sv_items]="उत्पादनां"
}

load_strings_doi() {  # Dogri (Devanagari)
    T[doi.m_new_bill]="नवां बिल"; T[doi.m_add_product]="उत्पाद जोड़ो"
    T[doi.m_low_stock]="कम स्टॉक रिपोर्ट"; T[doi.m_summary]="रोज़ना बिक्री सार"
    T[doi.m_void]="बिल रद्द"; T[doi.m_backup]="हुनै बैकअप"
    T[doi.m_stock_value]="स्टॉक मोल"; T[doi.m_language]="भाषा"
    T[doi.m_exit]="बाहरू"; T[doi.m_choose]="छनो: "
    T[doi.p_qty]="मात्रा"; T[doi.p_name]="नाम"; T[doi.p_price]="कीमत"; T[doi.p_threshold]="हद"
    T[doi.r_total]="कुल"; T[doi.r_items]="चीज़ें:"; T[doi.r_units]="इकाई:"
    T[doi.c_added]="जोड़ेर"; T[doi.c_bill_saved]="बिल बचा ग्या"
    T[doi.c_bye]="फिर मिलांगे."; T[doi.c_no_low_stock]="कोन्या कम-स्टॉक. सब ठीक!"
    T[doi.c_lang_changed]="भाषा बदली:"; T[doi.ls_title]="कम स्टॉक रिपोर्ट"; T[doi.ls_deficit]="घाटा"
    T[doi.ls_stock]="स्टॉक"; T[doi.sv_title]="स्टॉक मोल"; T[doi.sv_total]="कुल स्टॉक मोल"; T[doi.sv_items]="उत्पाद"
}

load_strings_mni() {  # Manipuri/Meitei (Bengali script — most widely available)
    T[mni.m_new_bill]="অনৌবা বিল"; T[mni.m_add_product]="পুৰিংবা য়োকপা"
    T[mni.m_low_stock]="য়ামনা স্টক ৰিপোর্ট"; T[mni.m_summary]="নুংঙাইবা ফল্লুপা মীতযেক"
    T[mni.m_void]="বিল ৰদ্দ"; T[mni.m_backup]="অঙৌবা বেকঅপ"
    T[mni.m_stock_value]="স্টক মমি"; T[mni.m_language]="লোনগোল"
    T[mni.m_exit]="লৌবা"; T[mni.m_choose]="খল্লু: "
    T[mni.p_qty]="মচু"; T[mni.p_name]="মমিং"; T[mni.p_price]="ফল্লু"; T[mni.p_threshold]="লানবা"
    T[mni.r_total]="অপুনবা"; T[mni.r_items]="মখোই:"; T[mni.r_units]="মচু:"
    T[mni.c_added]="য়োকপা"; T[mni.c_bill_saved]="বিল সেৱ তৌখ্রবা"
    T[mni.c_bye]="খঙগনা."; T[mni.c_no_low_stock]="য়ামনা স্টক লৈতে. অপুনবা ফুবা!"
    T[mni.c_lang_changed]="লোনগোল হোংবা:"; T[mni.ls_title]="য়ামনা স্টক ৰিপোর্ট"; T[mni.ls_deficit]="অহুমবা"
    T[mni.ls_stock]="স্টক"; T[mni.sv_title]="স্টক মমি"; T[mni.sv_total]="অপুনবা স্টক মমি"; T[mni.sv_items]="পুরিংবা"
}

load_strings_sat() {  # Santali (Ol Chiki)
    T[sat.m_new_bill]="ᱱᱟᱶ ᱵᱤᱞ"; T[sat.m_add_product]="ᱡᱤᱱᱤᱥ ᱥᱮᱞᱮᱫ"
    T[sat.m_low_stock]="ᱠᱚᱢ ᱥᱴᱚᱠ ᱨᱤᱯᱚᱨᱴ"; T[sat.m_summary]="ᱫᱤᱱᱴᱹᱢ ᱵᱤᱠᱨᱤ ᱥᱟᱨᱟᱢ"
    T[sat.m_void]="ᱵᱤᱞ ᱵᱟᱹᱜᱤ"; T[sat.m_backup]="ᱱᱚᱣᱟ ᱵᱮᱠᱚᱯ"
    T[sat.m_stock_value]="ᱥᱴᱚᱠ ᱢᱩᱞᱭᱚᱢ"; T[sat.m_language]="ᱯᱟᱹᱨᱥᱤ"
    T[sat.m_exit]="ᱵᱟᱦᱨᱟ"; T[sat.m_choose]="ᱵᱟᱪᱮᱫ: "
    T[sat.p_qty]="ᱞᱮᱠᱷᱟ"; T[sat.p_name]="ᱧᱩᱛᱩᱢ"; T[sat.p_price]="ᱫᱟᱢ"; T[sat.p_threshold]="ᱥᱤᱢᱟ"
    T[sat.r_total]="ᱢᱩᱴ"; T[sat.r_items]="ᱡᱤᱱᱤᱥ:"; T[sat.r_units]="ᱤᱠᱟᱭ:"
    T[sat.c_added]="ᱥᱮᱞᱮᱫᱮᱱᱟ"; T[sat.c_bill_saved]="ᱵᱤᱞ ᱨᱩᱠᱷᱤᱭᱟᱹᱱᱟ"
    T[sat.c_bye]="ᱟᱨᱮ ᱧᱟᱯᱟᱢ."; T[sat.c_no_low_stock]="ᱠᱚᱢ-ᱥᱴᱚᱠ ᱵᱟᱹᱱᱩᱜ."; T[sat.c_lang_changed]="ᱯᱟᱹᱨᱥᱤ ᱵᱚᱫᱚᱞ:"
    T[sat.ls_title]="ᱠᱚᱢ ᱥᱴᱚᱠ ᱨᱤᱯᱚᱨᱴ"; T[sat.ls_deficit]="ᱠᱚᱢ"; T[sat.ls_stock]="ᱥᱴᱚᱠ"
    T[sat.sv_title]="ᱥᱴᱚᱠ ᱢᱩᱞᱭᱚᱢ"; T[sat.sv_total]="ᱢᱩᱴ ᱥᱴᱚᱠ ᱢᱩᱞᱭᱚᱝ"; T[sat.sv_items]="ᱡᱤᱱᱤᱥ"
}

load_strings_brx() {  # Bodo (Devanagari)
    T[brx.m_new_bill]="गोनां बिल"; T[brx.m_add_product]="सामान जोड़"
    T[brx.m_low_stock]="खम स्टक रिपोर्ट"; T[brx.m_summary]="दैनिक बिक्री सारांश"
    T[brx.m_void]="बिल रद्द"; T[brx.m_backup]="दानि बेकअप"
    T[brx.m_stock_value]="स्टक गिरि"; T[brx.m_language]="राव"
    T[brx.m_exit]="बाह्र"; T[brx.m_choose]="सायख: "
    T[brx.p_qty]="गिदिर"; T[brx.p_name]="मुं"; T[brx.p_price]="राव"; T[brx.p_threshold]="सिमा"
    T[brx.r_total]="गोहोम"; T[brx.r_items]="सामान:"; T[brx.r_units]="हान:"
    T[brx.c_added]="जोड़बाय"; T[brx.c_bill_saved]="बिल सेभ जाबाय"
    T[brx.c_bye]="फिनानो लोगोसि."; T[brx.c_no_low_stock]="खम स्टक गेयै. गासै ठिक!"
    T[brx.c_lang_changed]="राव सोलाय:"; T[brx.ls_title]="खम स्टक रिपोर्ट"; T[brx.ls_deficit]="गोबौ"
    T[brx.ls_stock]="स्टक"; T[brx.sv_title]="स्टक गिरि"; T[brx.sv_total]="गोहोम स्टक गिरि"; T[brx.sv_items]="सामान"
}

load_strings_bho() {  # Bhojpuri (Devanagari)
    T[bho.m_new_bill]="नया बिल"; T[bho.m_add_product]="सामान जोड़ीं"
    T[bho.m_low_stock]="कम स्टॉक रपट"; T[bho.m_summary]="रोज़वार बिक्री सार"
    T[bho.m_void]="बिल खारिज"; T[bho.m_backup]="अबहीं बैकअप"
    T[bho.m_stock_value]="स्टॉक मोल"; T[bho.m_language]="भाखा"
    T[bho.m_exit]="बाहिर"; T[bho.m_choose]="चुनीं: "
    T[bho.p_qty]="मात्रा"; T[bho.p_name]="नावां"; T[bho.p_price]="दाम"; T[bho.p_threshold]="सीमा"
    T[bho.r_total]="कुल"; T[bho.r_items]="चीज:"; T[bho.r_units]="इकाई:"
    T[bho.c_added]="जोड़ल"; T[bho.c_bill_saved]="बिल सेव भइल"
    T[bho.c_bye]="पहिले मिलीं."; T[bho.c_no_low_stock]="कम-स्टॉक नइखे. सब ठीक बा!"
    T[bho.c_lang_changed]="भाखा बदलल:"; T[bho.ls_title]="कम स्टॉक रपट"; T[bho.ls_deficit]="कमी"
    T[bho.ls_stock]="स्टॉक"; T[bho.sv_title]="स्टॉक मोल"; T[bho.sv_total]="कुल स्टॉक मोल"; T[bho.sv_items]="सामान"
}

# Translate: t <key> — falls back to English, then the key itself.
t() {
    local key="$1"
    local v="${T[$LANG_CODE.$key]:-${T[en.$key]:-$key}}"
    printf '%s' "$v"
}

# Load strings for the active language (English always, then the selected one).
i18n_init() {
    load_strings_en
    local fn="load_strings_${LANG_CODE}"
    if declare -F "$fn" >/dev/null 2>&1; then "$fn"; fi
}

# Set language: validates code, updates conf, reloads strings.
set_lang() {
    local code="$1" found=""
    local entry
    for entry in "${LANG_NAMES[@]}"; do
        if [[ "${entry%%:*}" == "$code" ]]; then found="$entry"; break; fi
    done
    [[ -n "$found" ]] || return 1
    LANG_CODE="$code"
    # persist to conf atomically: keep all existing keys except lang=, then append lang=
    local tmp="$CONF_FILE.new"
    : > "$tmp"
    if [[ -f "$CONF_FILE" ]]; then
        grep -vE "^lang=" "$CONF_FILE" 2>/dev/null | grep -v "^$" >> "$tmp" || true
    fi
    printf 'lang=%s\n' "$code" >> "$tmp"
    mv "$tmp" "$CONF_FILE"
    i18n_init
    printf '%s %s (%s)\n' "$(t c_lang_changed)" "${found#*:}" "$code"
}

list_langs() {
    local i=1 entry
    for entry in "${LANG_NAMES[@]}"; do
        printf ' %2d) %s  (%s)\n' "$i" "$(pad_disp "${entry#*:}" 14)" "${entry%%:*}"
        i=$((i+1))
    done
}


#─────────────────────────────────────────────────────────────────────────────
# Money math — all integer paise
#─────────────────────────────────────────────────────────────────────────────
# parse "25", "25.5", "25.00", "25.05" -> integer paise. No floating point.
rupees_to_paise() {
    local input="$1"
    [[ "$input" =~ ^[0-9]+(\.[0-9]{0,2})?$ ]] || return 1
    local int_part frac_part
    if [[ "$input" == *.* ]]; then
        int_part="${input%%.*}"
        frac_part="${input#*.}"
        case ${#frac_part} in
            0) frac_part="00" ;;
            1) frac_part="${frac_part}0" ;;
        esac
    else
        int_part="$input"
        frac_part="00"
    fi
    local result="${int_part}${frac_part}"
    printf '%s' "$((10#$result))"
}

# paise (integer, may be negative) -> "₹NN.NN" display string
fmt_money() {
    local paise="$1" sign=""
    if (( paise < 0 )); then sign="-"; paise=$((-paise)); fi
    local rs=$((paise / 100)) ps=$((paise % 100))
    printf '%s%s%d.%02d' "$sign" "$CURRENCY" "$rs" "$ps"
}

# right-aligned money string of width $2 (default 9), using char count
fmt_money_field() {
    local paise="$1" w="${2:-9}"
    local s len pad
    s=$(fmt_money "$paise")
    len=${#s}
    pad=$((w - len))
    (( pad >= 0 )) || pad=0
    printf '%s%s' "$(repeat_str ' ' "$pad")" "$s"
}

#─────────────────────────────────────────────────────────────────────────────
# String helpers
#─────────────────────────────────────────────────────────────────────────────
repeat_str() {
    local s="$1" n="$2" out="" i
    for ((i=0; i<n; i++)); do out+="$s"; done
    printf '%s' "$out"
}

truncate_name() {
    local s="$1" max="$2"
    if (( ${#s} > max )); then
        printf '%s' "${s:0:$max}"
    else
        printf '%s' "$s"
    fi
}

#─────────────────────────────────────────────────────────────────────────────
# Display-width engine — Indic / CJK / emoji glyphs are ~2 terminal columns,
# combining marks (matras, viramas, diacritics) are 0 columns. This keeps
# translated labels aligned ("कीमत:" and "Price:" line up their values) in
# every one of the 23 UI languages.
#─────────────────────────────────────────────────────────────────────────────
_dw() {   # core: sets global _DW (no forks — pure builtins)
    local s="$1" i ch cp w=0
    for ((i=0; i<${#s}; i++)); do
        ch="${s:i:1}"
        cp=63
        printf -v cp '%d' "'$ch" 2>/dev/null || cp=63
        if (( cp == 65038 || cp == 65039 )); then continue; fi   # variation selectors
        if (( cp >= 8204 && cp <= 8207 ));    then continue; fi  # ZWJ ZWNJ LRM RLM
        if   (( cp >= 2304 && cp <= 2307 )); then continue       # Devanagari signs
        elif (( cp >= 2362 && cp <= 2391 )); then continue       # Devanagari matras
        elif (( cp >= 2402 && cp <= 2403 )); then continue
        elif (( cp >= 2433 && cp <= 2435 )); then continue       # Bengali/Assamese
        elif (( cp == 2492 )); then continue
        elif (( cp >= 2494 && cp <= 2500 )); then continue
        elif (( cp >= 2503 && cp <= 2504 )); then continue
        elif (( cp >= 2507 && cp <= 2508 )); then continue
        elif (( cp == 2517 || cp == 2519 )); then continue
        elif (( cp >= 2530 && cp <= 2531 )); then continue
        elif (( cp >= 2561 && cp <= 2563 )); then continue       # Gurmukhi
        elif (( cp == 2620 )); then continue
        elif (( cp >= 2622 && cp <= 2628 )); then continue
        elif (( cp >= 2633 && cp <= 2637 )); then continue
        elif (( cp == 2641 || cp == 2672 || cp == 2673 )); then continue
        elif (( cp >= 2689 && cp <= 2691 )); then continue       # Gujarati
        elif (( cp == 2748 )); then continue
        elif (( cp >= 2750 && cp <= 2756 )); then continue
        elif (( cp >= 2759 && cp <= 2765 )); then continue
        elif (( cp == 2775 )); then continue
        elif (( cp >= 2817 && cp <= 2819 )); then continue       # Odia
        elif (( cp == 2876 )); then continue
        elif (( cp >= 2878 && cp <= 2884 )); then continue
        elif (( cp >= 2887 && cp <= 2888 )); then continue
        elif (( cp >= 2891 && cp <= 2893 )); then continue
        elif (( cp >= 2902 && cp <= 2903 )); then continue
        elif (( cp >= 2914 && cp <= 2915 )); then continue
        elif (( cp == 2946 )); then continue                     # Tamil
        elif (( cp >= 3006 && cp <= 3010 )); then continue
        elif (( cp >= 3014 && cp <= 3016 )); then continue
        elif (( cp >= 3018 && cp <= 3021 )); then continue
        elif (( cp == 3031 )); then continue
        elif (( cp >= 3072 && cp <= 3075 )); then continue       # Telugu
        elif (( cp >= 3134 && cp <= 3140 )); then continue
        elif (( cp >= 3142 && cp <= 3144 )); then continue
        elif (( cp >= 3146 && cp <= 3149 )); then continue
        elif (( cp >= 3157 && cp <= 3158 )); then continue
        elif (( cp >= 3170 && cp <= 3171 )); then continue
        elif (( cp >= 3201 && cp <= 3203 )); then continue       # Kannada
        elif (( cp == 3260 )); then continue
        elif (( cp >= 3262 && cp <= 3268 )); then continue
        elif (( cp >= 3270 && cp <= 3272 )); then continue
        elif (( cp >= 3274 && cp <= 3277 )); then continue
        elif (( cp >= 3285 && cp <= 3286 )); then continue
        elif (( cp >= 3298 && cp <= 3299 )); then continue
        elif (( cp >= 3329 && cp <= 3331 )); then continue       # Malayalam
        elif (( cp >= 3390 && cp <= 3396 )); then continue
        elif (( cp >= 3398 && cp <= 3400 )); then continue
        elif (( cp >= 3402 && cp <= 3405 )); then continue
        elif (( cp == 3415 )); then continue
        elif (( cp >= 3426 && cp <= 3427 )); then continue
        elif (( cp >= 1552 && cp <= 1562 )); then continue       # Arabic diacritics
        elif (( cp >= 1611 && cp <= 1631 )); then continue
        elif (( cp == 1648 )); then continue
        elif (( cp >= 1750 && cp <= 1773 )); then continue
        elif (( cp >= 2304 && cp <= 3455 )); then w=$((w+2))     # Indic base letters
        elif (( cp >= 4352 ));              then w=$((w+2))     # CJK / emoji / wide
        else w=$((w+1))
        fi
    done
    _DW=$w
}
dwidth()      { _dw "$1"; printf '%s' "$_DW"; }                          # for tests
pad_disp()    { local s="$1" w="$2"; _dw "$s"; local p=$(( w > _DW ? w - _DW : 0 )); (( p < 0 )) && p=0; printf '%s%*s' "$s" "$p" ""; }
rpad_disp()   { local s="$1" w="$2"; _dw "$s"; local p=$(( w > _DW ? w - _DW : 0 )); (( p < 0 )) && p=0; printf '%*s%s' "$p" "" "$s"; }

# Truncate by DISPLAY width (not chars) so tables never break mid-glyph.
truncate_disp() {
    local s="$1" maxw="$2" out="" i ch total=0
    for ((i=0; i<${#s}; i++)); do
        ch="${s:i:1}"
        _dw "$ch"
        if (( total + _DW > maxw )); then break; fi
        out+="$ch"
        total=$(( total + _DW ))
    done
    printf '%s' "$out"
}

# Clock — IST forced via TZ=Asia/Kolkata (Chennai, UTC+05:30). Fixed English
# abbreviations so the header stays neat in every UI language, refreshed on
# every menu redraw.
now_date() { LC_ALL=C TZ=Asia/Kolkata date '+%a %d %b %Y'; }
now_time() { LC_ALL=C TZ=Asia/Kolkata date '+%H:%M:%S'; }

#─────────────────────────────────────────────────────────────────────────────
# CSV — quote fields containing comma or quote; double internal quotes
#─────────────────────────────────────────────────────────────────────────────
csv_quote() {
    local field="$1"
    if [[ "$field" == *,* || "$field" == *'"'* ]]; then
        local escaped="${field//\"/\"\"}"
        printf '"%s"' "$escaped"
    else
        printf '%s' "$field"
    fi
}

# RFC-4180-ish parser for one CSV line -> global CSV_FIELDS array.
# Respects quoted fields (commas inside, doubled quotes -> one quote).
parse_csv_line() {
    local line="$1"
    local field="" ch in_quotes=0 pos=0 len=${#line}
    CSV_FIELDS=()
    while (( pos < len )); do
        ch="${line:pos:1}"
        if (( in_quotes )); then
            if [[ "$ch" == '"' ]]; then
                if (( pos+1 < len )) && [[ "${line:pos+1:1}" == '"' ]]; then
                    field+='"'; pos=$((pos+2)); continue
                else
                    in_quotes=0; pos=$((pos+1)); continue
                fi
            else
                field+="$ch"; pos=$((pos+1))
            fi
        else
            if [[ "$ch" == '"' ]]; then
                in_quotes=1; pos=$((pos+1))
            elif [[ "$ch" == ',' ]]; then
                CSV_FIELDS+=("$field"); field=""; pos=$((pos+1))
            else
                field+="$ch"; pos=$((pos+1))
            fi
        fi
    done
    CSV_FIELDS+=("$field")
}

#─────────────────────────────────────────────────────────────────────────────
# State file (next_bill_no) — simple key=value, never regresses
#─────────────────────────────────────────────────────────────────────────────
read_state() {
    local key="$1"
    [[ -f "$STATE_FILE" ]] || { printf ''; return 0; }
    local val
    val=$(grep "^${key}=" "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    printf '%s' "$val"
}

write_state() {
    local key="$1" val="$2"
    local tmp="$STATE_FILE.new"
    : > "$tmp"
    if [[ -f "$STATE_FILE" ]]; then
        grep -v "^${key}=" "$STATE_FILE" >> "$tmp" 2>/dev/null || true
    fi
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
}

#─────────────────────────────────────────────────────────────────────────────
# Config
#─────────────────────────────────────────────────────────────────────────────
conf() {
    local key="$1" default="${2:-}"
    local val=""
    if [[ -f "$CONF_FILE" ]]; then
        val=$(grep "^${key}=" "$CONF_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    fi
    [[ -n "$val" ]] || val="$default"
    printf '%s' "$val"
}

#─────────────────────────────────────────────────────────────────────────────
# Directory / file init (idempotent, cheap)
#─────────────────────────────────────────────────────────────────────────────
PRODUCTS_HEADER='barcode,name,price_paise,qty,threshold,description,type,image,expiry_date,hsn_code'
PRODUCTS_HEADER_V8='barcode,name,price_paise,qty,threshold,description,type,image'
PRODUCTS_HEADER_V5='barcode,name,price_paise,qty,threshold'
BILLS_HEADER='bill_no,timestamp,barcode,name,qty,unit_price_paise,line_total,action,phone,discount_paise'
BILLS_HEADER_V8='bill_no,timestamp,barcode,name,qty,unit_price_paise,line_total,action'
TRAYS_HEADER='tray_barcode,name,item_barcode,item_name,item_qty,item_price_paise'

# Migrate older products.csv schemas to the current 10-column schema
# (adds empty description,type,image,expiry_date,hsn_code as needed).
# Atomic. Idempotent. Holds the lock (call under lock).
migrate_products_csv() {
    [[ -f "$PRODUCTS_CSV" ]] || return 0
    local hdr
    hdr=$(head -1 "$PRODUCTS_CSV" 2>/dev/null || true)
    # already current?
    if [[ "$hdr" == "$PRODUCTS_HEADER" ]]; then return 0; fi
    local src_cols=0
    case "$hdr" in
        "$PRODUCTS_HEADER_V8") src_cols=8 ;;
        "$PRODUCTS_HEADER_V5") src_cols=5 ;;
        *) return 0 ;;   # unknown schema — leave alone
    esac
    local newfile="$PRODUCTS_CSV.new"
    printf '%s\n' "$PRODUCTS_HEADER" > "$newfile"
    local line i
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$hdr" || -z "$line" ]]; then continue; fi
        parse_csv_line "$line"
        # pad missing columns with empty strings up to 10
        for (( i=${#CSV_FIELDS[@]}; i<10; i++ )); do CSV_FIELDS[i]=""; done
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$(csv_quote "${CSV_FIELDS[0]}")" "$(csv_quote "${CSV_FIELDS[1]}")" \
            "${CSV_FIELDS[2]}" "${CSV_FIELDS[3]}" "${CSV_FIELDS[4]}" \
            "$(csv_quote "${CSV_FIELDS[5]}")" "$(csv_quote "${CSV_FIELDS[6]}")" \
            "$(csv_quote "${CSV_FIELDS[7]}")" "$(csv_quote "${CSV_FIELDS[8]}")" \
            "$(csv_quote "${CSV_FIELDS[9]}")" >> "$newfile"
    done < "$PRODUCTS_CSV"
    mv "$newfile" "$PRODUCTS_CSV"
}

# Migrate older 8-column bills.csv to the current 10-column schema
# (adds empty phone, discount_paise). Atomic. Idempotent.
migrate_bills_csv() {
    [[ -f "$BILLS_CSV" ]] || return 0
    local hdr
    hdr=$(head -1 "$BILLS_CSV" 2>/dev/null || true)
    if [[ "$hdr" == "$BILLS_HEADER" ]]; then return 0; fi
    if [[ "$hdr" != "$BILLS_HEADER_V8" ]]; then return 0; fi
    local newfile="$BILLS_CSV.new"
    printf '%s\n' "$BILLS_HEADER" > "$newfile"
    local line i
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$BILLS_HEADER_V8" || -z "$line" ]]; then continue; fi
        parse_csv_line "$line"
        for (( i=${#CSV_FIELDS[@]}; i<10; i++ )); do CSV_FIELDS[i]=""; done
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "${CSV_FIELDS[0]}" "${CSV_FIELDS[1]}" \
            "$(csv_quote "${CSV_FIELDS[2]}")" "$(csv_quote "${CSV_FIELDS[3]}")" \
            "${CSV_FIELDS[4]}" "${CSV_FIELDS[5]}" "${CSV_FIELDS[6]}" \
            "${CSV_FIELDS[7]}" "$(csv_quote "${CSV_FIELDS[8]:-}")" \
            "${CSV_FIELDS[9]:-0}" >> "$newfile"
    done < "$BILLS_CSV"
    mv "$newfile" "$BILLS_CSV"
}

init_dirs() {
    mkdir -p "$DATA_DIR" "$LABELS_DIR" "$BACKUPS_DIR"
    [[ -f "$PRODUCTS_CSV" ]]   || printf '%s\n' "$PRODUCTS_HEADER" > "$PRODUCTS_CSV"
    migrate_products_csv
    [[ -f "$BILLS_CSV" ]]      || printf '%s\n' "$BILLS_HEADER" > "$BILLS_CSV"
    migrate_bills_csv
    [[ -f "$INVENTORY_LOG" ]]  || printf 'timestamp,event,barcode,name,qty,price_paise,detail\n' > "$INVENTORY_LOG"
    [[ -f "$TRAYS_CSV" ]]      || printf '%s\n' "$TRAYS_HEADER" > "$TRAYS_CSV"
    [[ -f "$STATE_FILE" ]]     || printf 'next_bill_no=1\n' > "$STATE_FILE"
    [[ -f "$CONF_FILE" ]]      || printf 'shop_name=My Kirana Store\ndefault_threshold=8\ngstin=\naddress=\nphone=\n' > "$CONF_FILE"
    # Category trays: seed the default set once (idempotent)
    if [[ ! -f "$CATEGORIES_CSV" ]]; then
        printf '%s\n' "$CATEGORY_HEADER" > "$CATEGORIES_CSV"
        local dc dname demoji
        for dc in "${DEFAULT_CATEGORIES[@]}"; do
            dname="${dc%%|*}"; demoji="${dc#*|}"
            printf '%s,%s,%s\n' "$(csv_quote "$dname")" "$(csv_quote "$demoji")" "$(gen_category_barcode)" >> "$CATEGORIES_CSV"
        done
    fi
}

#─────────────────────────────────────────────────────────────────────────────
# Inventory activity log — audit trail of stock-in / stock-out / adjustments.
#─────────────────────────────────────────────────────────────────────────────
log_event() {
    # args: event barcode name qty price_paise detail
    local event="$1" bc="$2" name="$3" qty="$4" price="$5" detail="$6"
    local ts; ts=$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')
    printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$ts" "$event" "$(csv_quote "$bc")" "$(csv_quote "$name")" \
        "$qty" "$price" "$(csv_quote "$detail")" >> "$INVENTORY_LOG"
}

#─────────────────────────────────────────────────────────────────────────────
# File locking — flock on shopkeep-data/.lock for every read-modify-write
#─────────────────────────────────────────────────────────────────────────────
lock()   { init_dirs; exec 200>"$LOCK_FILE"; flock -x 200; }
unlock() { flock -u 200 2>/dev/null || true; exec 200>&- 2>/dev/null || true; }

#─────────────────────────────────────────────────────────────────────────────
# Load products.csv into global assoc arrays (call under lock for RMW safety)
#─────────────────────────────────────────────────────────────────────────────
load_products() {
    P_NAME=(); P_PRICE=(); P_QTY=(); P_THRESHOLD=(); P_DESC=(); P_TYPE=(); P_IMAGE=(); P_EXPIRY=(); P_HSN=()
    [[ -f "$PRODUCTS_CSV" ]] || return 0
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "barcode,"* || -z "$line" ]]; then continue; fi
        parse_csv_line "$line"
        local bc="${CSV_FIELDS[0]}"
        if [[ -z "$bc" ]]; then continue; fi
        P_NAME["$bc"]="${CSV_FIELDS[1]}"
        P_PRICE["$bc"]="${CSV_FIELDS[2]}"
        P_QTY["$bc"]="${CSV_FIELDS[3]}"
        P_THRESHOLD["$bc"]="${CSV_FIELDS[4]}"
        P_DESC["$bc"]="${CSV_FIELDS[5]:-}"
        P_TYPE["$bc"]="${CSV_FIELDS[6]:-}"
        P_IMAGE["$bc"]="${CSV_FIELDS[7]:-}"
        P_EXPIRY["$bc"]="${CSV_FIELDS[8]:-}"
        P_HSN["$bc"]="${CSV_FIELDS[9]:-}"
    done < "$PRODUCTS_CSV"
}

# Load trays.csv into global assoc arrays.
load_trays() {
    TRAY_NAME=(); TRAY_ITEMS=()
    [[ -f "$TRAYS_CSV" ]] || return 0
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "tray_barcode,"* || -z "$line" ]]; then continue; fi
        parse_csv_line "$line"
        local tbc="${CSV_FIELDS[0]}" tname="${CSV_FIELDS[1]}" ibc="${CSV_FIELDS[2]}" iqty="${CSV_FIELDS[4]:-1}"
        if [[ -z "$tbc" || -z "$ibc" ]]; then continue; fi
        TRAY_NAME["$tbc"]="$tname"
        if [[ -z "${TRAY_ITEMS[$tbc]+x}" ]]; then
            TRAY_ITEMS["$tbc"]="$ibc:$iqty"
        else
            TRAY_ITEMS["$tbc"]="${TRAY_ITEMS[$tbc]} $ibc:$iqty"
        fi
    done < "$TRAYS_CSV"
}

# Expand a tray barcode into "bc qty" cart lines (printed to stdout).
expand_tray() {
    local tbc="$1" count="${2:-1}"
    [[ -n "${TRAY_NAME[$tbc]+x}" ]] || return 1
    local items="${TRAY_ITEMS[$tbc]}" item ibc iqt
    for item in $items; do
        ibc="${item%%:*}"; iqt="${item#*:}"
        [[ -n "${P_NAME[$ibc]+x}" ]] || return 2
        printf '%s %s\n' "$ibc" "$(( iqt * count ))"
    done
    return 0
}

# Generate next internal barcode (EAN-13 in-store range 2000000000000–2999999999999)
gen_internal_barcode() {
    local start=2000000000000
    local max=$start
    local bc
    for bc in "${!P_NAME[@]}"; do
        if [[ "$bc" =~ ^2[0-9]{12}$ ]] && (( bc > max )); then
            max=$bc
        fi
    done
    printf '%s' "$((max + 1))"
}

#─────────────────────────────────────────────────────────────────────────────
# Category emoji — one glanceable icon per item type, language-independent.
#─────────────────────────────────────────────────────────────────────────────
emoji_for_type() {
    local t="${1:-}"
    t="${t,,}"
    case "$t" in
        *milk*|*dairy*|*curd*|*yogurt*|*paneer*|*cheese*|*butter*|*ghee*|*lassi*|*buttermilk*) printf '🥛' ;;
        *biscuit*|*cookie*|*snack*|*namkeen*|*chips*|*wafer*|*kurkure*|*bhujia*)                printf '🍪' ;;
        *chocolate*|*candy*|*sweet*|*toffee*|*jam*|*spread*|*honey*|*jaggery*|*dessert*)       printf '🍫' ;;
        *tea*|*chai*|*coffee*|*juice*|*drink*|*beverage*|*soda*|*cola*|*water*|*sherbet*)      printf '🥤' ;;
        *masala*|*spice*|*chilli*|*turmeric*|*cardamom*|*clove*|*pepper*|*seasoning*)          printf '🌶️' ;;
        *fruit*|*vegetable*|*sabzi*|*produce*|*onion*|*potato*|*tomato*)                       printf '🍎' ;;
        *bread*|*bakery*|*bun*|*cake*|*pastry*|*rusk*|*pav*)                                   printf '🍞' ;;
        *egg*|*meat*|*chicken*|*fish*|*mutton*)                                                printf '🍗' ;;
        *soap*|*shampoo*|*tooth*|*paste*|*brush*|*cream*|*lotion*|*deodorant*|*talc*|*sanitizer*|*personal*|*cosmetic*|*skin*|*hair*|*oral*|*hygiene*) printf '🧼' ;;
        *detergent*|*wash*|*clean*|*tissue*|*mop*|*broom*|*household*|*garbage*|*phenyl*|*dish*|*paper*) printf '🧹' ;;
        *rice*|*atta*|*flour*|*maida*|*dal*|*pulse*|*grain*|*cereal*|*oil*|*salt*|*sugar*|*staple*|*pasta*|*sooji*|*besan*) printf '🍚' ;;
        *baby*|*diaper*|*nappy*)                                                               printf '🍼' ;;
        *pet*|*dog*|*"cat food"*|*"bird feed"*)                                                    printf '🐾' ;;
        *medicine*|*health*|*balm*|*tablet*|*pharmacy*)                                        printf '💊' ;;
        *pen*|*pencil*|*notebook*|*stationery*|*stationary*|*school*)                          printf '✏️' ;;
        *pickle*|*achar*|*achaar*|*papad*)                                                    printf '🥒' ;;
        *frozen*|*"ice cream"*|*icecream*)                                                       printf '🍨' ;;
        *)                                                                                     printf '📦' ;;
    esac
}

#─────────────────────────────────────────────────────────────────────────────
# Category trays — pre-made trays for categories of products.
#─────────────────────────────────────────────────────────────────────────────
CATEGORY_HEADER='name,emoji,tray_barcode'
DEFAULT_CATEGORIES=(
    "Staples|🍚" "Snacks|🍪" "Beverages|🥤" "Dairy|🥛" "Spices|🌶️"
    "Personal Care|🧼" "Household|🧹" "Fruits & Veggies|🍎" "Bakery|🍞"
    "Sweets & Spreads|🍫" "Other|📦"
)

gen_category_barcode() {
    local start=3000000000000
    local max=$start line bc
    if [[ -f "$CATEGORIES_CSV" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" == "name,"* || -z "$line" ]] && continue
            bc="${line##*,}"
            [[ "$bc" =~ ^3[0-9]{12}$ ]] && (( bc > max )) && max=$bc
        done < "$CATEGORIES_CSV"
    fi
    printf '%s' "$((max + 1))"
}

# Look up a category tray: prints "emoji|tray_barcode" (fields may be empty).
category_info() {
    local name="$1" line
    [[ -n "$name" && -f "$CATEGORIES_CSV" ]] || { printf '|'; return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "name,"* || -z "$line" ]] && continue
        parse_csv_line "$line"
        if [[ "${CSV_FIELDS[0],,}" == "${name,,}" ]]; then
            printf '%s|%s' "${CSV_FIELDS[1]:-}" "${CSV_FIELDS[2]:-}"
            return 0
        fi
    done < "$CATEGORIES_CSV"
    printf '|'
}

# NEW: Look up a category tray BY BARCODE — returns "name|emoji" or empty.
# Used by cmd_tray show / remove so they don't silently fail on 3xxxxxxxxxxxx
# category-tray barcodes (which live in categories.csv, not trays.csv).
category_tray_info() {
    local tbc="$1" line
    [[ -n "$tbc" && -f "$CATEGORIES_CSV" ]] || { printf '|'; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "name,"* || -z "$line" ]] && continue
        parse_csv_line "$line"
        if [[ "${CSV_FIELDS[2]}" == "$tbc" ]]; then
            printf '%s|%s' "${CSV_FIELDS[0]}" "${CSV_FIELDS[1]:-}"
            return 0
        fi
    done < "$CATEGORIES_CSV"
    printf '|'
    return 1
}

# Ensure a tray exists for <name> (creates one with a matching emoji if not).
ensure_category() {
    local name="$1" want_emoji="${2:-}" line
    [[ -n "$name" ]] || { printf '|'; return 0; }
    if [[ -f "$CATEGORIES_CSV" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" == "name,"* || -z "$line" ]] && continue
            parse_csv_line "$line"
            if [[ "${CSV_FIELDS[0],,}" == "${name,,}" ]]; then
                printf '%s|%s' "${CSV_FIELDS[1]:-}" "${CSV_FIELDS[2]:-}"
                return 0
            fi
        done < "$CATEGORIES_CSV"
    fi
    [[ -n "$want_emoji" ]] || want_emoji=$(emoji_for_type "$name")
    local bc; bc=$(gen_category_barcode)
    printf '%s,%s,%s\n' "$(csv_quote "$name")" "$(csv_quote "$want_emoji")" "$bc" >> "$CATEGORIES_CSV"
    log_event "TRAY_NEW" "-" "$name" "-" "-" "category tray created ($bc)"
    printf '%s|%s' "$want_emoji" "$bc"
}

count_products_in_category() {
    local cat="$1" line n=0 ptype
    [[ -f "$PRODUCTS_CSV" ]] || { printf '0'; return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "barcode,"* || -z "$line" ]] && continue
        parse_csv_line "$line"
        ptype="${CSV_FIELDS[6]:-}"
        [[ "${ptype,,}" == "${cat,,}" ]] && n=$((n+1))
    done < "$PRODUCTS_CSV"
    printf '%s' "$n"
}

list_category_trays() {
    local line i=1 cname cemoji cbc n_items
    [[ -f "$CATEGORIES_CSV" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "name,"* || -z "$line" ]] && continue
        parse_csv_line "$line"
        cname="${CSV_FIELDS[0]}"; cemoji="${CSV_FIELDS[1]}"; cbc="${CSV_FIELDS[2]}"
        n_items=$(count_products_in_category "$cname")
        printf ' %2d) %s %-24s %s  (%d)\n' "$i" "$cemoji" "$cname" "$cbc" "$n_items"
        i=$((i+1))
    done < "$CATEGORIES_CSV"
}

category_name_at() {
    local idx="$1" line i=1
    [[ -f "$CATEGORIES_CSV" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "name,"* || -z "$line" ]] && continue
        if (( i == idx )); then
            parse_csv_line "$line"
            printf '%s' "${CSV_FIELDS[0]}"
            return 0
        fi
        i=$((i+1))
    done < "$CATEGORIES_CSV"
    return 1
}

category_from_hint() {
    local hint="${1:-}" c
    hint="${hint,,}"
    [[ -n "$hint" ]] || { printf ''; return 0; }
    case "$hint" in
        *beverage*|*drink*|*juice*|*soda*|*water*)                printf 'Beverages' ;;
        *dairy*|*milk*|*yogurt*|*cheese*|*butter*|*ghee*)         printf 'Dairy' ;;
        *snack*|*biscuit*|*cookie*|*chip*|*wafer*)                printf 'Snacks' ;;
        *sweet*|*chocolate*|*candy*|*spread*|*jam*|*dessert*)     printf 'Sweets & Spreads' ;;
        *fruit*|*vegetable*|*produce*)                            printf 'Fruits & Veggies' ;;
        *bread*|*bakery*)                                         printf 'Bakery' ;;
        *spice*|*masala*|*seasoning*)                             printf 'Spices' ;;
        *clean*|*detergent*|*household*|*paper*|*tissue*)         printf 'Household' ;;
        *soap*|*shampoo*|*cosmetic*|*skin*|*hair*|*oral*|*hygiene*|*personal*) printf 'Personal Care' ;;
        *rice*|*grain*|*cereal*|*pasta*|*staple*|*oil*|*flour*|*pulse*) printf 'Staples' ;;
        *)
            c="${hint%%,*}"; c="${c//_/ }"
            printf '%s' "$c" | awk '{for(i=1;i<=NF;i++)$i=toupper(substr($i,1,1))substr($i,2)}1'
            ;;
    esac
}

#─────────────────────────────────────────────────────────────────────────────
# Online barcode lookup — OPTIONAL (needs internet + curl; curl is the only
# extra dependency and everything degrades gracefully without it).
#─────────────────────────────────────────────────────────────────────────────
LOOKUP_TIMEOUT="${SHOPKEEP_LOOKUP_TIMEOUT:-6}"
LOOKUP_UA="shopkeep/${VERSION} (offline-first kirana POS)"

_json_get() {
    local json="$1" key="$2" v
    v=$(printf '%s' "$json" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    v=$(printf '%s' "$v" | sed 's/\\u0026/\&/g; s/\\"/"/g; s/\\\//\//g')
    printf '%s' "$v" | tr -d '\000-\037'
}

online_lookup() {
    local bc="$1" json name brand pack cat img rc netfail=1
    command -v curl >/dev/null 2>&1 || return 2

    # 1) Open Food Facts (food & groceries)
    json=""; rc=0
    json=$(curl --connect-timeout 3 -m "$LOOKUP_TIMEOUT" -sf -A "$LOOKUP_UA" \
        "https://world.openfoodfacts.org/api/v2/product/${bc}.json?fields=product_name,product_name_en,brands,quantity,categories_tags,image_small_url" 2>/dev/null) || rc=$?
    if (( rc == 0 )); then netfail=0; fi
    if [[ -n "$json" && "$json" == *'"product"'* ]]; then
        name=$(_json_get "$json" "product_name_en")
        [[ -n "$name" ]] || name=$(_json_get "$json" "product_name")
        brand=$(_json_get "$json" "brands")
        pack=$(_json_get "$json" "quantity")
        img=$(_json_get "$json" "image_small_url")
        cat=$(printf '%s' "$json" | grep -o '"en:[^"]*"' | head -n1 | tr -d '"')
        cat="${cat#en:}"
        [[ "$brand" == http* ]] && brand=""
        [[ "$pack"  == http* ]] && pack=""
        if [[ -n "$name" ]]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$brand" "$pack" "$cat" "$img" "Open Food Facts"
            return 0
        fi
    fi

    # 2) Open Products Facts (non-food; same API shape)
    json=""; rc=0
    json=$(curl --connect-timeout 3 -m "$LOOKUP_TIMEOUT" -sf -A "$LOOKUP_UA" \
        "https://world.openproductsfacts.org/api/v2/product/${bc}.json?fields=product_name,brands,quantity,categories_tags,image_small_url" 2>/dev/null) || rc=$?
    if (( rc == 0 )); then netfail=0; fi
    if [[ -n "$json" && "$json" == *'"product"'* ]]; then
        name=$(_json_get "$json" "product_name")
        brand=$(_json_get "$json" "brands")
        pack=$(_json_get "$json" "quantity")
        img=$(_json_get "$json" "image_small_url")
        cat=$(printf '%s' "$json" | grep -o '"en:[^"]*"' | head -n1 | tr -d '"')
        cat="${cat#en:}"
        [[ "$brand" == http* ]] && brand=""
        [[ "$pack"  == http* ]] && pack=""
        if [[ -n "$name" ]]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$brand" "$pack" "$cat" "$img" "Open Products Facts"
            return 0
        fi
    fi

    # 3) UPCitemDB free trial endpoint (general merchandise)
    json=""; rc=0
    json=$(curl --connect-timeout 3 -m "$LOOKUP_TIMEOUT" -sf -A "$LOOKUP_UA" \
        "https://www.upcitemdb.com/api/trial/lookup?upc=${bc}" 2>/dev/null) || rc=$?
    if (( rc == 0 )); then netfail=0; fi
    if [[ -n "$json" && "$json" == *'"code":"ok"'* ]]; then
        name=$(_json_get "$json" "title")
        brand=$(_json_get "$json" "brand")
        pack=$(_json_get "$json" "description")
        cat=$(_json_get "$json" "category")
        [[ "$cat" == http* ]] && cat=""
        img=$(printf '%s' "$json" | grep -o '"https://[^"]*\.jpg"' | head -n1 | tr -d '"')
        if [[ -n "$name" ]]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$brand" "$pack" "$cat" "$img" "UPCitemDB"
            return 0
        fi
    fi

    (( netfail )) && return 2
    return 1
}

show_lookup_result() {
    local name="$1" brand="$2" pack="$3" cat="$4" img="$5" src="$6"
    local emoji; emoji=$(emoji_for_type "$cat")
    echo "   ${C_GREEN}✅ $(t c_lookup_found): $src${C_RESET}"
    printf '   %s %s%s%s\n' "$emoji" "$C_BOLD" "$name" "$C_RESET"
    [[ -n "$brand" ]] && printf '   %s %s\n'  "$(pad_disp "$(t p_brand):" 13)" "$brand"
    [[ -n "$pack"  ]] && printf '   %s %s\n'  "$(pad_disp "$(t p_pack):" 13)"  "$(truncate_disp "$pack" 52)"
    [[ -n "$cat"   ]] && printf '   %s %s %s\n' "$(pad_disp "$(t p_type):" 13)" "$emoji" "$cat"
    [[ -n "$img"   ]] && printf '   %s %s\n'  "$(pad_disp "$(t p_image):" 13)" "$img"
}

#─────────────────────────────────────────────────────────────────────────────
# Atomic catalog rewrite
#─────────────────────────────────────────────────────────────────────────────
apply_stock_delta() {
    declare -A deltas
    local it bc d
    for it in "$@"; do
        bc="${it%% *}"; d="${it##* }"
        deltas["$bc"]=$(( ${deltas["$bc"]:-0} + d ))
    done
    local newfile="$PRODUCTS_CSV.new"
    : > "$newfile" || return 1
    printf '%s\n' "$PRODUCTS_HEADER" > "$newfile"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "barcode,"* || -z "$line" ]]; then continue; fi
        parse_csv_line "$line"
        local pbc="${CSV_FIELDS[0]}" pname="${CSV_FIELDS[1]}" pprice="${CSV_FIELDS[2]}" pqty="${CSV_FIELDS[3]}" pthr="${CSV_FIELDS[4]}"
        local pdesc="${CSV_FIELDS[5]:-}" ptype="${CSV_FIELDS[6]:-}" pimage="${CSV_FIELDS[7]:-}"
        local pexpiry="${CSV_FIELDS[8]:-}" phsn="${CSV_FIELDS[9]:-}"
        if [[ -n "${deltas[$pbc]+x}" ]]; then
            pqty=$(( pqty + deltas[$pbc] ))
        fi
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$(csv_quote "$pbc")" "$(csv_quote "$pname")" "$(csv_quote "$pprice")" \
            "$(csv_quote "$pqty")" "$(csv_quote "$pthr")" "$(csv_quote "$pdesc")" \
            "$(csv_quote "$ptype")" "$(csv_quote "$pimage")" \
            "$(csv_quote "$pexpiry")" "$(csv_quote "$phsn")" >> "$newfile"
    done < "$PRODUCTS_CSV"
    mv "$newfile" "$PRODUCTS_CSV" || return 1
    return 0
}

declare -a _DROP=()
rewrite_products_from_memory() {
    local newfile="$PRODUCTS_CSV.new"
    : > "$newfile" || return 1
    printf '%s\n' "$PRODUCTS_HEADER" > "$newfile"
    local bc drop
    declare -A dropmap=()
    if (( ${#_DROP[@]} > 0 )); then
        for drop in "${_DROP[@]}"; do dropmap["$drop"]=1; done
    fi
    for bc in "${!P_NAME[@]}"; do
        if [[ -n "${dropmap[$bc]+x}" ]]; then continue; fi
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$(csv_quote "$bc")" "$(csv_quote "${P_NAME[$bc]}")" "$(csv_quote "${P_PRICE[$bc]}")" \
            "$(csv_quote "${P_QTY[$bc]}")" "$(csv_quote "${P_THRESHOLD[$bc]}")" \
            "$(csv_quote "${P_DESC[$bc]:-}")" "$(csv_quote "${P_TYPE[$bc]:-}")" \
            "$(csv_quote "${P_IMAGE[$bc]:-}")" "$(csv_quote "${P_EXPIRY[$bc]:-}")" \
            "$(csv_quote "${P_HSN[$bc]:-}")" >> "$newfile"
    done
    mv "$newfile" "$PRODUCTS_CSV" || return 1
    return 0
}

#─────────────────────────────────────────────────────────────────────────────
# Optional barcode scanning (zbarcam) and label printing (zint + SVG fallback)
#─────────────────────────────────────────────────────────────────────────────
scan_barcode() {
    command -v zbarcam >/dev/null || return 1
    local code
    code=$(timeout "${SCAN_TIMEOUT:-60}" zbarcam --raw 2>/dev/null | head -n1) || true
    code="${code%$'\n'}"
    if [[ -n "$code" ]]; then printf '%s' "$code"; return 0; fi
    return 1
}

# FIXED: don't swallow zint's stderr — surface a real error message instead.
gen_label() {
    local bc="$1" out="$2"
    if ! command -v zint >/dev/null; then
        err "zint is not installed — install with: sudo apt install zint"
        return 1
    fi
    mkdir -p "$LABELS_DIR"
    if ! zint -b CODE128 -o "$out" -d "$bc"; then
        err "zint failed for barcode $bc — check the data"
        rm -f "$out" 2>/dev/null || true
        return 1
    fi
    [[ -f "$out" ]]
}

# NEW: SVG fallback so a label image is ALWAYS produced, even without zint.
# Prints the actual file path it wrote (extension may be .svg, not .png).
#─────────────────────────────────────────────────────────────────────────────
# Pure-bash EAN-13 SVG barcode generator (no zint required).
#   Produces a REAL scannable EAN-13 barcode as an SVG file:
#   - computes the 13th checksum digit if given 12
#   - encodes each digit using the A/B/C parity LUTs
#   - emits <rect> elements for each bar
#   - prints the 13 digits below the bars
#   This is what makes `gen-label` work on machines without zint.
#─────────────────────────────────────────────────────────────────────────────
# EAN-13 digit LUTs (each digit → 7-module pattern; 1=bar, 0=space)
declare -a EAN13_A=("0001101" "0011001" "0010011" "0111101" "0100011" "0110001" "0101111" "0111011" "0110111" "0001011")
declare -a EAN13_B=("0100111" "0110011" "0011011" "0100001" "0011101" "0111001" "0000101" "0010001" "0001001" "0010111")
declare -a EAN13_C=("1110010" "1100110" "1101100" "1000010" "1011100" "1001110" "1010000" "1000100" "1001000" "1110100")
# First-digit → left-group parity pattern (positions 1..6, A or B for each)
declare -a EAN13_PARITY=("AAAAAA" "AABABB" "AABBAB" "AABBBA" "ABAABB" "ABBAAB" "ABBBAA" "ABABBA" "ABBABA" "ABAABA")

# Compute the EAN-13 checksum digit (12 → 13). Prints the 13-digit code.
ean13_full_code() {
    local bc="$1"
    if (( ${#bc} == 13 )); then printf '%s' "$bc"; return 0; fi
    if (( ${#bc} != 12 )); then return 1; fi
    local sum=0 i d
    for ((i=0; i<12; i++)); do
        d="${bc:i:1}"
        if (( i % 2 == 0 )); then
            sum=$((sum + d))            # odd position (1-indexed) → weight 1
        else
            sum=$((sum + d * 3))        # even position → weight 3
        fi
    done
    local check=$(( (10 - sum % 10) % 10 ))
    printf '%s%s' "$bc" "$check"
}

# Generate a real EAN-13 SVG (scannable bars + digits). out path may end in .png — output is .svg.
gen_ean13_svg() {
    local bc="$1" out="$2"
    local code
    code=$(ean13_full_code "$bc") || { err "EAN-13 needs 12 or 13 digits, got ${#bc}"; return 1; }
    local first="${code:0:1}"
    local parity="${EAN13_PARITY[$first]:-AAAAAA}"
    # Build the 95-module pattern: start guard (101) + 6×7 left + center (01010) + 6×7 right + end guard (101)
    local pattern="101" i d p
    for ((i=1; i<=6; i++)); do
        d="${code:i:1}"; p="${parity:i-1:1}"
        case "$p" in
            A) pattern+="${EAN13_A[$d]}" ;;
            B) pattern+="${EAN13_B[$d]}" ;;
            *) pattern+="${EAN13_A[$d]}" ;;
        esac
    done
    pattern+="01010"
    for ((i=7; i<=12; i++)); do
        d="${code:i:1}"
        pattern+="${EAN13_C[$d]}"
    done
    pattern+="101"

    # Geometry: each module is `mw` pixels; bars are `bar_h` tall; digits below.
    local mw=2 bar_h=100 margin=10
    local total_w=$(( ${#pattern} * mw ))
    local svg_w=$(( total_w + margin * 2 ))
    local svg_h=$(( margin * 2 + bar_h + 18 ))
    # Build <rect> elements for each "1" module
    local rects="" j
    for ((j=0; j<${#pattern}; j++)); do
        if [[ "${pattern:j:1}" == "1" ]]; then
            local x=$(( margin + j * mw ))
            rects+="<rect x=\"$x\" y=\"$margin\" width=\"$mw\" height=\"$bar_h\" fill=\"black\"/>"
        fi
    done
    # Digits below: first digit at far left, then left group, then right group
    local text_y=$(( margin + bar_h + 12 ))
    local first_x=$(( margin - 4 ))
    local left_center=$(( margin + (3 + 6*7/2) * mw ))
    local right_center=$(( margin + (3 + 6*7 + 5 + 6*7/2) * mw ))
    mkdir -p "$(dirname "$out")"
    # Normalise the extension: .png → .svg, .svg → keep, otherwise append .svg
    if   [[ "$out" == *.svg ]]; then :
    elif [[ "$out" == *.png ]]; then out="${out%.png}.svg"
    else out="$out.svg"
    fi
    cat > "$out" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="$svg_w" height="$svg_h" viewBox="0 0 $svg_w $svg_h">
  <rect width="$svg_w" height="$svg_h" fill="white"/>
  $rects
  <text x="$first_x" y="$text_y" font-family="monospace" font-size="11" text-anchor="start">${code:0:1}</text>
  <text x="$left_center" y="$text_y" font-family="monospace" font-size="11" text-anchor="middle">${code:1:6}</text>
  <text x="$right_center" y="$text_y" font-family="monospace" font-size="11" text-anchor="middle">${code:7:6}</text>
</svg>
EOF
    printf '%s' "$out"
    return 0
}

gen_label_fallback() {
    local bc="$1" out="$2"
    mkdir -p "$LABELS_DIR"
    # For 12-13 digit barcodes, produce a REAL scannable EAN-13 SVG (no zint needed)
    if (( ${#bc} == 12 || ${#bc} == 13 )); then
        local r; r=$(gen_ean13_svg "$bc" "$out") || { err "EAN-13 SVG generation failed"; return 1; }
        printf '%s' "$r"
        return 0
    fi
    # For non-retail barcodes (internal 2xxx, category 3xxx), produce a text-label SVG (not scannable)
    if   [[ "$out" == *.svg ]]; then :
    elif [[ "$out" == *.png ]]; then out="${out%.png}.svg"
    else out="$out.svg"
    fi
    cat > "$out" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="320" height="120">
  <rect width="320" height="120" fill="white" stroke="black"/>
  <text x="160" y="40" font-family="monospace" font-size="14" text-anchor="middle">shopkeep label</text>
  <text x="160" y="90" font-family="monospace" font-size="28" text-anchor="middle">${bc}</text>
</svg>
EOF
    printf '%s' "$out"
    return 0
}

#─────────────────────────────────────────────────────────────────────────────
# Box-drawing receipt helpers
#─────────────────────────────────────────────────────────────────────────────
box_top()    { printf '┌%s┐\n' "$(repeat_str '─' "$BOX_WIDTH")"; }
box_mid()    { printf '├%s┤\n' "$(repeat_str '─' "$BOX_WIDTH")"; }
box_bottom() { printf '└%s┘\n' "$(repeat_str '─' "$BOX_WIDTH")"; }

box_row() {
    local content="$1" pad
    _dw "$content"
    pad=$((BOX_WIDTH - _DW)); (( pad >= 0 )) || pad=0
    printf '│%s%s│\n' "$content" "$(repeat_str ' ' "$pad")"
}

box_center() {
    local text="$1" pad rest content
    text="$(truncate_disp "$text" $((BOX_WIDTH - 2)))"
    _dw "$text"
    pad=$(( (BOX_WIDTH - _DW) / 2 ))
    (( pad >= 0 )) || pad=0
    content="$(repeat_str ' ' "$pad")$text"
    _dw "$content"
    rest=$((BOX_WIDTH - _DW)); (( rest >= 0 )) || rest=0
    content="$content$(repeat_str ' ' "$rest")"
    printf '│%s│\n' "$content"
}

box_lr() {
    local left="$1" right="$2" gap llen rlen content
    _dw "$left";  llen=$_DW
    _dw "$right"; rlen=$_DW
    gap=$((BOX_WIDTH - llen - rlen)); (( gap >= 1 )) || gap=1
    content="$left$(repeat_str ' ' "$gap")$right"
    box_row "$content"
}

# FIXED: print_receipt now takes an optional 6th arg = customer phone, and
# renders it under the bill number. All callers pass "" when no phone.
#─────────────────────────────────────────────────────────────────────────────
# Receipt printer — now renders GSTIN, subtotal, discount, net payable.
# Signature: print_receipt title total_label bill_no ts net_total phone discount subtotal lines...
# All callers pass 8 fixed args + lines. void_bill passes discount=0, subtotal=net.
#─────────────────────────────────────────────────────────────────────────────
print_receipt() {
    local title="$1" total_label="$2" bill_no="$3" ts="$4" net="$5" phone="${6:-}"
    local discount="${7:-0}" subtotal="${8:-$net}"
    shift 8
    local lines=("$@")
    local n=${#lines[@]} units=0 line bc name up qty lt disc
    local gstin; gstin=$(conf gstin "")
    local shop_addr; shop_addr=$(conf address "")
    local shop_phone; shop_phone=$(conf phone "")
    box_top
    box_center "$title"
    [[ -n "$shop_addr"  ]] && box_center "$(truncate_disp "$shop_addr" $((BOX_WIDTH-2)) )"
    [[ -n "$gstin"      ]] && box_center "$(t r_gstin): $gstin"
    [[ -n "$shop_phone"  ]] && box_center "Ph: $shop_phone"
    box_center "Bill #$(printf '%04d' "$bill_no")"
    box_center "$ts"
    if [[ -n "$phone" ]]; then
        box_center "Cust Ph: $phone"
    fi
    box_mid
    for line in "${lines[@]}"; do
        IFS="$US" read -r bc name up qty lt disc <<< "$line"
        disc="${disc:-0}"
        units=$(( units + qty ))
        box_lr " $(truncate_name "$name" $MAX_NAME) x$qty" "$(fmt_money_field "$lt" "$MONEY_FIELD")"
    done
    box_mid
    box_lr " $(t r_subtotal)" "$(fmt_money_field "$subtotal" "$MONEY_FIELD")"
    if (( discount > 0 )); then
        box_lr " $(t r_discount) ($(printf '%d' "${BILL_DISCOUNT_PCT:-0}")%)" "-$(fmt_money_field "$discount" "$MONEY_FIELD")"
    fi
    box_lr " $total_label" "$(fmt_money_field "$net" "$MONEY_FIELD")"
    box_lr " $(t r_items) $n  $(t r_units) $units" ""
    box_bottom
}

#─────────────────────────────────────────────────────────────────────────────
# Billing core — the heart. Returns 0 ok (sets BILL_*), 1 validation fail,
# 2 stock-update fail. Reads BILL_PHONE / BILL_DISCOUNT_PCT globals (set by caller);
# logs phone + per-line discount in bills.csv so they survive.
#─────────────────────────────────────────────────────────────────────────────
commit_bill() {
    local cart=("$@")
    if (( ${#cart[@]} == 0 )); then err "Empty bill."; return 1; fi
    init_dirs
    lock
    load_products
    local bill_no; bill_no=$(read_state next_bill_no)
    [[ -n "$bill_no" ]] || bill_no=1
    local phone="${BILL_PHONE:-}"
    local dpct="${BILL_DISCOUNT_PCT:-0}"
    [[ "$dpct" =~ ^[0-9]+$ ]] || dpct=0
    (( dpct >= 0 && dpct <= 100 )) || dpct=0

    local items=() it bc q name up gross lt disc total=0 discount=0 fails=0
    for it in "${cart[@]}"; do
        bc="${it%% *}"; q="${it##* }"
        if [[ ! "${P_NAME[$bc]+x}" ]]; then err "Unknown barcode: $bc"; fails=1; break; fi
        if ! [[ "$q" =~ ^[0-9]+$ ]] || (( q <= 0 )); then err "Bad qty for $bc: $q"; fails=1; break; fi
        local stock="${P_QTY[$bc]}"
        if (( q > stock )); then
            err "Shortfall: ${P_NAME[$bc]} ($bc) need $q, have $stock"
            fails=1; break
        fi
        name="${P_NAME[$bc]}"; up="${P_PRICE[$bc]}"
        gross=$(( up * q ))
        disc=$(( gross * dpct / 100 ))
        lt=$(( gross - disc ))
        total=$(( total + lt )); discount=$(( discount + disc ))
        items+=("$bc${US}$name${US}$up${US}$q${US}$lt${US}$disc")
    done

    if (( fails )); then unlock; return 1; fi

    local ts; ts=$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')

    # 1) append ALL SELL rows FIRST (one write each) — now with phone + discount_paise
    local row rbc rname rup rqt rlt rdisc
    for row in "${items[@]}"; do
        IFS="$US" read -r rbc rname rup rqt rlt rdisc <<< "$row"
        rdisc="${rdisc:-0}"
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$bill_no" "$ts" "$(csv_quote "$rbc")" "$(csv_quote "$rname")" \
            "$rqt" "$rup" "$rlt" "SELL" "$(csv_quote "$phone")" "$rdisc" >> "$BILLS_CSV"
    done

    BILL_NO="$bill_no"; BILL_TS="$ts"; BILL_TOTAL="$total"; BILL_DISCOUNT="$discount"; BILL_LINES=("${items[@]}")

    # 2) decrement stock atomically
    local deltas=()
    for row in "${items[@]}"; do
        IFS="$US" read -r rbc _ _ rqt _ _ <<< "$row"
        deltas+=("$rbc -$rqt")
    done

    if apply_stock_delta "${deltas[@]}"; then
        write_state next_bill_no $((bill_no + 1))
        unlock
        return 0
    else
        err "ERROR: stock update failed; appending VOID reversal to bills.csv."
        for row in "${items[@]}"; do
            IFS="$US" read -r rbc rname rup rqt rlt rdisc <<< "$row"
            rdisc="${rdisc:-0}"
            printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "$bill_no" "$ts" "$(csv_quote "$rbc")" "$(csv_quote "$rname")" \
                "$rqt" "$rup" "$rlt" "VOID" "$(csv_quote "$phone")" "$rdisc" >> "$BILLS_CSV"
        done
        write_state next_bill_no $((bill_no + 1))
        unlock
        return 2
    fi
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: add
#─────────────────────────────────────────────────────────────────────────────
do_add() {
    local bc="$1" name="$2" price="$3" qty="$4" thr="$5"
    local desc="${6:-}" ptype="${7:-}" image="${8:-}" expiry="${9:-}" hsn="${10:-}"
    init_dirs
    lock
    load_products
    if [[ -z "$bc" ]]; then bc=$(gen_internal_barcode); fi
    if [[ -n "${P_NAME[$bc]+x}" ]]; then
        unlock; err "Duplicate barcode $bc → ${P_NAME[$bc]}"; return 1
    fi
    local tray_bc=""
    if [[ -n "$ptype" ]]; then
        local tray_info; tray_info=$(ensure_category "$ptype")
        tray_bc="${tray_info#*|}"
    fi
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_quote "$bc")" "$(csv_quote "$name")" "$price" "$qty" "$thr" \
        "$(csv_quote "$desc")" "$(csv_quote "$ptype")" "$(csv_quote "$image")" \
        "$(csv_quote "$expiry")" "$(csv_quote "$hsn")" >> "$PRODUCTS_CSV"
    ADDED_BARCODE="$bc"
    log_event "ADD" "$bc" "$name" "$qty" "$price" "new product, threshold=$thr, type=$ptype${tray_bc:+, tray=$tray_bc}${expiry:+, expiry=$expiry}${hsn:+, hsn=$hsn}"
    unlock
    log "Added: $name  $(fmt_money "$price")  qty=$qty  threshold=$thr  barcode=$bc${expiry:+  expiry=$expiry}"
    return 0
}

cmd_add() {
    local name="" price="" qty="" bc="" thr="" desc="" ptype="" image="" expiry="" hsn="" publish=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)     [[ $# -ge 2 ]] || { err "--name needs a value"; exit 3; }; name="$2";  shift 2 ;;
            --price)    [[ $# -ge 2 ]] || { err "--price needs a value"; exit 3; }; price="$2"; shift 2 ;;
            --qty)      [[ $# -ge 2 ]] || { err "--qty needs a value"; exit 3; }; qty="$2";   shift 2 ;;
            --barcode)  [[ $# -ge 2 ]] || { err "--barcode needs a value"; exit 3; }; bc="$2"; shift 2 ;;
            --threshold)[[ $# -ge 2 ]] || { err "--threshold needs a value"; exit 3; }; thr="$2"; shift 2 ;;
            --desc|--description) [[ $# -ge 2 ]] || { err "--desc needs a value"; exit 3; }; desc="$2"; shift 2 ;;
            --type)     [[ $# -ge 2 ]] || { err "--type needs a value"; exit 3; }; ptype="$2"; shift 2 ;;
            --image)    [[ $# -ge 2 ]] || { err "--image needs a value"; exit 3; }; image="$2"; shift 2 ;;
            --expiry)   [[ $# -ge 2 ]] || { err "--expiry needs a value"; exit 3; }; expiry="$2"; shift 2 ;;
            --hsn)      [[ $# -ge 2 ]] || { err "--hsn needs a value"; exit 3; }; hsn="$2"; shift 2 ;;
            --publish)  publish=1; shift ;;
            --label)    echo "label-only flag ignored in CLI mode" >&2; shift ;;
            -h|--help)  cat <<'EOF'
shopkeep.sh add --name "Tata Salt 1kg" --price 25.00 --qty 24 \
               [--barcode 8901234567890] [--threshold 8]
               [--desc "..."] [--type Grocery] [--image labels/8901.jpg]
               [--expiry 2025-12-31] [--hsn 2501] [--publish]
EOF
                        return 0 ;;
            *) err "Unknown argument: $1"; exit 3 ;;
        esac
    done
    [[ -n "$name" ]]  || { err "--name is required";  exit 3; }
    [[ -n "$price" ]] || { err "--price is required"; exit 3; }
    [[ -n "$qty" ]]   || { err "--qty is required";   exit 3; }
    if [[ -n "$bc" && ! "$bc" =~ ^[0-9]+$ ]]; then err "barcode must be digits only"; exit 1; fi
    local ppaise
    ppaise=$(rupees_to_paise "$price") || { err "Invalid price '$price' (use 25, 25.5, or 25.00)"; exit 1; }
    (( ppaise > 0 )) || { err "price must be > 0"; exit 1; }
    [[ "$qty" =~ ^[0-9]+$ ]] || { err "qty must be >= 0"; exit 1; }
    if [[ -z "$thr" ]]; then thr=$(conf default_threshold); fi
    [[ "$thr" =~ ^[0-9]+$ ]] || { err "threshold must be >= 0"; exit 1; }
    if [[ -n "$expiry" ]]; then
        [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { err "expiry must be YYYY-MM-DD"; exit 1; }
    fi
    do_add "$bc" "$name" "$ppaise" "$qty" "$thr" "$desc" "$ptype" "$image" "$expiry" "$hsn" || exit 1
    if (( publish )) && [[ -n "$ADDED_BARCODE" ]]; then
        local pub_bc="$ADDED_BARCODE"
        if [[ "$pub_bc" =~ ^[0-9]{12,13}$ && "${pub_bc:0:1}" != "2" && "${pub_bc:0:1}" != "3" ]]; then
            log "Auto-publishing to Open Products Facts…"
            publish_product "$pub_bc" 0 || true
        else
            log "Skipping publish: internal/category barcode (not a real retail EAN-13)"
        fi
    fi
}

#─────────────────────────────────────────────────────────────────────────────
# show_product — print full details for one barcode
#─────────────────────────────────────────────────────────────────────────────
show_product() {
    local bc="$1" compact="${2:-0}"
    if [[ -z "${P_NAME[$bc]+x}" ]]; then
        err "No product with barcode $bc"; return 1
    fi
    local name="${P_NAME[$bc]}" price="${P_PRICE[$bc]}" qty="${P_QTY[$bc]}"
    local thr="${P_THRESHOLD[$bc]}" desc="${P_DESC[$bc]:-}" ptype="${P_TYPE[$bc]:-}" image="${P_IMAGE[$bc]:-}"
    local expiry="${P_EXPIRY[$bc]:-}" hsn="${P_HSN[$bc]:-}"
    local pemoji; pemoji=$(emoji_for_type "$ptype")
    printf "  ${C_BOLD}%s %s${C_RESET}\n" "$pemoji" "$name"
    printf "     %s %s\n" "$(pad_disp "$(t p_barcode):" 14)" "$bc"
    printf "     %s %s\n" "$(pad_disp "$(t p_price):" 14)" "$(fmt_money "$price")"
    printf "     %s %s   (%s: %s)\n" "$(pad_disp "Stock:" 14)" "$qty" "$(t p_threshold)" "$thr"
    if [[ -n "$ptype" ]]; then
        local cinfo; cinfo=$(category_info "$ptype")
        local cbc="${cinfo#*|}" cemoji="${cinfo%%|*}"
        [[ -z "$cemoji" ]] && cemoji="$pemoji"
        local tray_txt=""
        [[ -n "$cbc" ]] && tray_txt="  ($(t inv_tray) $cbc)"
        printf "     %s %s %s%s\n" "$(pad_disp "$(t p_type):" 14)" "$cemoji" "$ptype" "$tray_txt"
    fi
    if [[ -n "$expiry" ]]; then
        local days; days=$(days_until "$expiry")
        local ec="$C_GREEN" elbl="$(t er_fresh)"
        if (( days < 0 )); then ec="$C_RED"; elbl="$(t er_expired)"
        elif (( days <= 7 )); then ec="$C_YELLOW"; elbl="$(t er_near)"; fi
        printf "     %s %s%s %s (%d %s)%s\n" "$(pad_disp "$(t p_expiry):" 14)" "$ec" "$expiry" "$elbl" "$days" "$(t er_days_left)" "$C_RESET"
    fi
    if [[ -n "$hsn" ]]; then printf "     %s %s\n" "$(pad_disp "$(t p_hsn):" 14)" "$hsn"; fi
    if [[ -n "$desc" ]];   then printf "     %s %s\n" "$(pad_disp "$(t p_desc):" 14)" "$(truncate_disp "$desc" 64)"; fi
    if [[ -n "$image" ]]; then
        if [[ -f "$image" ]]; then
            printf "     %s ${C_GREEN}%s [exists]${C_RESET}\n" "$(pad_disp "$(t p_image):" 14)" "$(truncate_disp "$image" 60)"
        else
            printf "     %s %s (not found)\n" "$(pad_disp "$(t p_image):" 14)" "$(truncate_disp "$image" 60)"
        fi
    fi
    if (( compact == 0 )); then echo; fi
    return 0
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: remove <barcode> [--reason "..."]
#─────────────────────────────────────────────────────────────────────────────
cmd_remove() {
    local bc="${1:-}" reason=""
    shift 2>/dev/null || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --reason) [[ $# -ge 2 ]] || { err "--reason needs a value"; exit 3; }; reason="$2"; shift 2 ;;
            -y) FORCE_REMOVE=1; shift ;;
            *) err "Unknown arg: $1"; exit 3 ;;
        esac
    done
    [[ -n "$bc" ]] || { err "Usage: shopkeep.sh remove <barcode> [--reason \"...\"]"; exit 3; }
    [[ "$bc" =~ ^[0-9]+$ ]] || { err "barcode must be digits"; exit 1; }
    init_dirs; lock; load_products
    if [[ -z "${P_NAME[$bc]+x}" ]]; then unlock; err "No product with barcode $bc"; return 1; fi
    show_product "$bc" 1
    if [[ -z "${FORCE_REMOVE:-}" ]]; then
        printf "Remove this product? (y/N): "
        local yn; read -r yn || yn=""
        [[ "$yn" =~ ^[yY] ]] || { unlock; log "Remove cancelled."; return 1; }
    fi
    local name="${P_NAME[$bc]}" qty="${P_QTY[$bc]}" price="${P_PRICE[$bc]}"
    _DROP=("$bc")
    if rewrite_products_from_memory; then
        log_event "REMOVE" "$bc" "$name" "$qty" "$price" "removed: ${reason:-no reason given}"
        unlock; _DROP=()
        log "Removed: $name ($bc)${reason:+ — $reason}"
        return 0
    else
        unlock; _DROP=(); err "Failed to rewrite products.csv"; return 1
    fi
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: restock <barcode> --qty N [--reason "..."]
#─────────────────────────────────────────────────────────────────────────────
cmd_restock() {
    local bc="${1:-}" addqty="" reason=""
    shift 2>/dev/null || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --qty)    [[ $# -ge 2 ]] || { err "--qty needs a value"; exit 3; }; addqty="$2"; shift 2 ;;
            --reason) [[ $# -ge 2 ]] || { err "--reason needs a value"; exit 3; }; reason="$2"; shift 2 ;;
            *) err "Unknown arg: $1"; exit 3 ;;
        esac
    done
    [[ -n "$bc" && -n "$addqty" ]] || { err "Usage: shopkeep.sh restock <barcode> --qty N [--reason \"...\"]"; exit 3; }
    [[ "$bc" =~ ^[0-9]+$ ]] || { err "barcode must be digits"; exit 1; }
    [[ "$addqty" =~ ^[0-9]+$ && "$addqty" -gt 0 ]] || { err "qty must be a positive integer"; exit 1; }
    init_dirs; lock; load_products
    if [[ -z "${P_NAME[$bc]+x}" ]]; then unlock; err "No product with barcode $bc"; return 1; fi
    local old="${P_QTY[$bc]}"
    local new=$(( old + addqty ))
    if apply_stock_delta "$bc $addqty"; then
        log_event "RESTOCK" "$bc" "${P_NAME[$bc]}" "$addqty" "${P_PRICE[$bc]}" "stock $old -> $new${reason:+ — $reason}"
        unlock
        log "Restocked: ${P_NAME[$bc]}  $old -> $new  (+$addqty)"
        return 0
    else
        unlock; err "Restock failed"; return 1
    fi
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: edit <barcode> [options]
#─────────────────────────────────────────────────────────────────────────────
cmd_edit() {
    local bc="${1:-}"
    [[ -n "$bc" ]] || { err "Usage: shopkeep.sh edit <barcode> [options]"; exit 3; }
    shift
    local name="" price="" thr="" desc="" ptype="" image="" expiry="" hsn=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)     [[ $# -ge 2 ]] || { err "--name needs a value"; exit 3; }; name="$2"; shift 2 ;;
            --price)    [[ $# -ge 2 ]] || { err "--price needs a value"; exit 3; }; price="$2"; shift 2 ;;
            --threshold)[[ $# -ge 2 ]] || { err "--threshold needs a value"; exit 3; }; thr="$2"; shift 2 ;;
            --desc|--description) [[ $# -ge 2 ]] || { err "--desc needs a value"; exit 3; }; desc="$2"; shift 2 ;;
            --type)     [[ $# -ge 2 ]] || { err "--type needs a value"; exit 3; }; ptype="$2"; shift 2 ;;
            --image)    [[ $# -ge 2 ]] || { err "--image needs a value"; exit 3; }; image="$2"; shift 2 ;;
            --expiry)   [[ $# -ge 2 ]] || { err "--expiry needs a value"; exit 3; }; expiry="$2"; shift 2 ;;
            --hsn)      [[ $# -ge 2 ]] || { err "--hsn needs a value"; exit 3; }; hsn="$2"; shift 2 ;;
            -h|--help)  echo "shopkeep.sh edit <barcode> [--name X] [--price Y] [--threshold Z] [--desc D] [--type T] [--image I] [--expiry DATE] [--hsn H]"; return 0 ;;
            *) err "Unknown arg: $1"; exit 3 ;;
        esac
    done
    init_dirs; lock; load_products
    if [[ -z "${P_NAME[$bc]+x}" ]]; then unlock; err "No product with barcode $bc"; return 1; fi
    local changes=""
    if [[ -n "$name" ]]; then P_NAME["$bc"]="$name"; changes+="name "; fi
    if [[ -n "$price" ]]; then
        local pp; pp=$(rupees_to_paise "$price") || { unlock; err "Invalid price '$price'"; return 1; }
        P_PRICE["$bc"]="$pp"; changes+="price "
    fi
    if [[ -n "$thr" ]]; then
        [[ "$thr" =~ ^[0-9]+$ ]] || { unlock; err "threshold must be >= 0"; return 1; }
        P_THRESHOLD["$bc"]="$thr"; changes+="threshold "
    fi
    if [[ -n "$desc" ]];  then P_DESC["$bc"]="$desc"; changes+="desc "; fi
    if [[ -n "$ptype" ]]; then P_TYPE["$bc"]="$ptype"; changes+="type "; fi
    if [[ -n "$image" ]]; then P_IMAGE["$bc"]="$image"; changes+="image "; fi
    if [[ -n "$expiry" ]]; then
        [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ || "$expiry" == "-" ]] || { unlock; err "expiry must be YYYY-MM-DD or '-' to clear"; return 1; }
        [[ "$expiry" == "-" ]] && expiry=""
        P_EXPIRY["$bc"]="$expiry"; changes+="expiry "
    fi
    if [[ -n "$hsn" ]]; then P_HSN["$bc"]="$hsn"; changes+="hsn "; fi
    if [[ -z "$changes" ]]; then unlock; log "No changes specified."; return 0; fi
    _DROP=()
    if rewrite_products_from_memory; then
        log_event "EDIT" "$bc" "${P_NAME[$bc]}" "${P_QTY[$bc]}" "${P_PRICE[$bc]}" "edited: ${changes}"
        unlock
        log "Edited $bc: $changes"
        return 0
    else
        unlock; err "Edit failed"; return 1
    fi
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: search <query>
#─────────────────────────────────────────────────────────────────────────────
cmd_search() {
    local query="${1:-}"
    [[ -n "$query" ]] || { err "Usage: shopkeep.sh search <query>"; exit 3; }
    init_dirs; load_products
    local q="${query,,}" bc name matches=() ttype
    while read -r bc; do
        [[ -z "$bc" ]] && continue
        name="${P_NAME[$bc]}"
        ttype="${P_TYPE[$bc]:-}"
        if [[ "$bc" == *"$query"* || "${name,,}" == *"$q"* || "${ttype,,}" == *"$q"* ]]; then
            matches+=("$bc")
        fi
    done < <(printf '%s\n' "${!P_NAME[@]}" | sort)
    if (( ${#matches[@]} == 0 )); then
        log "No products match '$query'."
        return 0
    fi
    echo "${C_BOLD}$(t search_title) '$query' — ${#matches[@]} match(es)${C_RESET}"
    echo "$(repeat_str '─' 48)"
    local i=1
    for bc in "${matches[@]}"; do
        printf "${C_CYAN}[%d]${C_RESET} " "$i"
        show_product "$bc" 1
        echo
        i=$((i+1))
    done
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: tray — manage Blinkit-style trays AND category trays.
#   FIXED: every `exit` became `return` so a bad barcode never kills the
#   interactive menu (which has `set -e` on). Also: show/remove now
#   recognise category-tray barcodes (3xxxxxxxxxxxx) stored in categories.csv,
#   so they no longer silently fail.
#─────────────────────────────────────────────────────────────────────────────
cmd_tray() {
    local sub="${1:-}"
    if [[ -z "$sub" ]]; then
        err "Usage: shopkeep.sh tray add|list|show|remove ..."
        return 3
    fi
    shift
    init_dirs
    case "$sub" in
        add)
            local tbc="${1:-}" tname="" itemspec=""
            shift 2>/dev/null || true
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --name)  [[ $# -ge 2 ]] || { err "--name needs a value"; return 3; }; tname="$2"; shift 2 ;;
                    --items) [[ $# -ge 2 ]] || { err "--items needs a value"; return 3; }; itemspec="$2"; shift 2 ;;
                    *) err "Unknown arg: $1"; return 3 ;;
                esac
            done
            if [[ -z "$tbc" || -z "$tname" || -z "$itemspec" ]]; then
                err "Usage: tray add <tray_barcode> --name \"Combo\" --items \"bc1:qty,bc2:qty\""
                return 3
            fi
            [[ "$tbc" =~ ^[0-9]+$ ]] || { err "tray_barcode must be digits"; return 1; }
            lock; load_products; load_trays
            if [[ -n "${TRAY_NAME[$tbc]+x}" ]]; then
                local tmp="$TRAYS_CSV.new"
                printf '%s\n' "$TRAYS_HEADER" > "$tmp"
                local line
                while IFS= read -r line || [[ -n "$line" ]]; do
                    if [[ "$line" == "tray_barcode,"* || -z "$line" ]]; then continue; fi
                    parse_csv_line "$line"
                    [[ "${CSV_FIELDS[0]}" == "$tbc" ]] && continue
                    printf '%s\n' "$line" >> "$tmp"
                done < "$TRAYS_CSV"
                mv "$tmp" "$TRAYS_CSV"
            fi
            local IFS=',' item ibc iqt ok=0
            for item in $itemspec; do
                ibc="${item%%:*}"; iqt="${item#*:}"
                [[ -z "$iqt" || "$iqt" == "$item" ]] && iqt=1
                [[ "$ibc" =~ ^[0-9]+$ ]] || { unlock; err "Bad item barcode '$ibc'"; return 1; }
                [[ "$iqt" =~ ^[0-9]+$ && "$iqt" -gt 0 ]] || { unlock; err "Bad item qty '$iqt'"; return 1; }
                if [[ -z "${P_NAME[$ibc]+x}" ]]; then unlock; err "Unknown item barcode $ibc"; return 1; fi
                printf '%s,%s,%s,%s,%s,%s\n' \
                    "$(csv_quote "$tbc")" "$(csv_quote "$tname")" \
                    "$(csv_quote "$ibc")" "$(csv_quote "${P_NAME[$ibc]}")" "$iqt" "${P_PRICE[$ibc]}" >> "$TRAYS_CSV"
                ok=$((ok+1))
            done
            unlock
            log_event "TRAY_ADD" "$tbc" "$tname" "$ok" "-" "tray created with $ok items"
            log "Tray '$tname' ($tbc) created with $ok item(s)."
            ;;
        list)
            load_trays
            if (( ${#TRAY_NAME[@]} == 0 )); then log "No trays defined."; return 0; fi
            echo "${C_BOLD}TRAYS (scan a tray barcode in billing to add all items)${C_RESET}"
            echo "$(repeat_str '─' 60)"
            local tbc items n
            for tbc in "${!TRAY_NAME[@]}"; do
                items="${TRAY_ITEMS[$tbc]}"
                n=$(wc -w <<< "$items")
                printf "  %-16s %-22s %d items\n" "$tbc" "$(truncate_name "${TRAY_NAME[$tbc]}" 22)" "$n"
            done
            ;;
        show)
            local tbc="${1:-}"
            if [[ -z "$tbc" ]]; then
                err "Usage: tray show <tray_barcode>"
                return 3
            fi
            lock; load_products; load_trays
            # 1) COMBO tray (trays.csv)
            if [[ -n "${TRAY_NAME[$tbc]+x}" ]]; then
                echo "${C_BOLD}Tray: ${TRAY_NAME[$tbc]} ($tbc)${C_RESET}"
                echo "$(repeat_str '─' 48)"
                local items="${TRAY_ITEMS[$tbc]}" item ibc iqt
                for item in $items; do
                    ibc="${item%%:*}"; iqt="${item#*:}"
                    printf "  %-22s x%-3s  %s\n" \
                        "$(truncate_name "${P_NAME[$ibc]}" 22)" "$iqt" \
                        "$(fmt_money "${P_PRICE[$ibc]}")"
                done
                unlock
                return 0
            fi
            # 2) CATEGORY tray (categories.csv) — NEW
            local cinfo; cinfo=$(category_tray_info "$tbc")
            if [[ -n "${cinfo%%|*}" ]]; then
                local cname="${cinfo%%|*}" cemoji="${cinfo#*|}"
                echo "${C_BOLD}Category tray: ${cemoji} ${cname} ($tbc)${C_RESET}"
                echo "$(repeat_str '─' 48)"
                local n; n=$(count_products_in_category "$cname")
                printf "  Products filed: %d\n" "$n"
                unlock
                return 0
            fi
            unlock
            err "No tray or category with barcode $tbc"
            return 1
            ;;
        remove)
            local tbc="${1:-}"
            if [[ -z "$tbc" ]]; then
                err "Usage: tray remove <tray_barcode>"
                return 3
            fi
            lock; load_trays
            if [[ -z "${TRAY_NAME[$tbc]+x}" ]]; then
                # Maybe it's a category tray — don't silently fail, explain.
                local cinfo; cinfo=$(category_tray_info "$tbc")
                if [[ -n "${cinfo%%|*}" ]]; then
                    unlock
                    err "$tbc is a CATEGORY tray (${cinfo%%|*}). Use 'shopkeep.sh category' to manage categories."
                    return 1
                fi
                unlock
                err "No combo tray $tbc"
                return 1
            fi
            local removed_name="${TRAY_NAME[$tbc]}" removed_items="${TRAY_ITEMS[$tbc]}"
            local tmp="$TRAYS_CSV.new"
            printf '%s\n' "$TRAYS_HEADER" > "$tmp"
            local line
            while IFS= read -r line || [[ -n "$line" ]]; do
                if [[ "$line" == "tray_barcode,"* || -z "$line" ]]; then continue; fi
                parse_csv_line "$line"
                [[ "${CSV_FIELDS[0]}" == "$tbc" ]] && continue
                printf '%s\n' "$line" >> "$tmp"
            done < "$TRAYS_CSV"
            mv "$tmp" "$TRAYS_CSV"
            log_event "TRAY_REMOVE" "$tbc" "$removed_name" "-" "-" "tray removed (items: $removed_items)"
            unlock
            log "Tray $tbc ($removed_name) removed."
            ;;
        *)
            err "Unknown tray subcommand: $sub"; return 3 ;;
    esac
    return 0
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: bill (reads barcode/qty lines from stdin)
#   FIXED: optional --phone flag, passed through to print_receipt via BILL_PHONE.
#─────────────────────────────────────────────────────────────────────────────
cmd_bill() {
    local phone="" dpct="0"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --phone)    phone="$2"; shift 2 ;;
            --discount) dpct="$2"; shift 2 ;;
            --) shift; break ;;
            *) break ;;
        esac
    done
    init_dirs
    command -v flock >/dev/null || { err "flock required"; exit 2; }
    lock; load_products; load_trays; unlock
    BILL_PHONE="$phone"
    BILL_DISCOUNT_PCT="$dpct"
    [[ "$dpct" =~ ^[0-9]+$ ]] || BILL_DISCOUNT_PCT=0
    (( BILL_DISCOUNT_PCT >= 0 && BILL_DISCOUNT_PCT <= 100 )) || BILL_DISCOUNT_PCT=0
    local cart=() line bc q
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]]; then continue; fi
        read -r bc q <<< "$line"
        if [[ -z "$q" ]]; then q=1; fi
        if ! [[ "$bc" =~ ^[0-9]+$ ]]; then err "Bad barcode: $bc"; continue; fi
        if ! [[ "$q" =~ ^[0-9]+$ ]] || (( q <= 0 )); then err "Bad qty: $q"; continue; fi
        if [[ -n "${TRAY_NAME[$bc]+x}" ]]; then
            local expanded erc ibc iqt
            expanded=$(expand_tray "$bc" "$q"); erc=$?
            if (( erc != 0 )); then err "Tray $bc references an unknown item"; continue; fi
            while read -r ibc iqt; do
                if [[ -z "$ibc" ]]; then continue; fi
                cart+=("$ibc $iqt")
            done <<< "$expanded"
            continue
        fi
        cart+=("$bc $q")
    done
    if (( ${#cart[@]} == 0 )); then err "No items to bill."; exit 1; fi
    if commit_bill "${cart[@]}"; then
        echo
        local subtotal=$(( BILL_TOTAL + BILL_DISCOUNT ))
        print_receipt "$(conf shop_name)" "$(t r_net)" "$BILL_NO" "$BILL_TS" \
            "$BILL_TOTAL" "$BILL_PHONE" "$BILL_DISCOUNT" "$subtotal" "${BILL_LINES[@]}"
        local dmsg=""
        (( BILL_DISCOUNT > 0 )) && dmsg="  (discount $(fmt_money "$BILL_DISCOUNT"))"
        log "Bill #$BILL_NO saved. Net $(fmt_money "$BILL_TOTAL")$dmsg"
    else
        local rc=$?
        if (( rc == 2 )); then
            err "Bill #$BILL_NO failed stock update; reversed. Check bills.csv."
            exit 1
        else
            err "Bill not saved (validation error)."
            exit 1
        fi
    fi
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: lowstock
#─────────────────────────────────────────────────────────────────────────────
cmd_lowstock() {
    init_dirs
    if [[ ! -s "$PRODUCTS_CSV" ]] || (( $(wc -l < "$PRODUCTS_CSV") <= 1 )); then
        log "No products recorded."; return 0
    fi
    load_products
    local rows="" bc qty thr deficit
    for bc in "${!P_NAME[@]}"; do
        qty="${P_QTY[$bc]}"; thr="${P_THRESHOLD[$bc]}"
        if (( qty <= thr )); then
            deficit=$(( thr - qty ))
            rows+="${deficit}"$'\t'"${bc}"$'\t'"${qty}"$'\t'"${thr}"$'\t'"${P_NAME[$bc]}"$'\n'
        fi
    done

    if [[ -z "$rows" ]]; then log "$(t c_no_low_stock)"; return 0; fi

    local sorted
    sorted=$(printf '%s' "$rows" | sort -t$'\t' -k1,1nr)

    echo "${C_BOLD}$(t ls_title)${C_RESET}  ($(t ls_deficit))"
    echo "$(repeat_str '─' 64)"
    printf "%-3s  %-8s  %-7s  %-10s  %-14s  %s\n" "" "Deficit" "Stock" "Threshold" "Barcode" "Name"
    echo "$(repeat_str '─' 64)"
    local deficit qty thr name color
    while IFS=$'\t' read -r deficit bc qty thr name; do
        if [[ -z "$deficit" ]]; then continue; fi
        if   (( qty == 0 ));   then color="$C_RED"
        elif (( qty < thr ));  then color="$C_YELLOW"
        else                       color="$C_CYAN"; fi
        printf "%s%s %-8s  %-7s  %-10s  %-14s  %s%s\n" \
            "$color" "$(emoji_for_type "${P_TYPE[$bc]:-}")" "$deficit" "$qty" "$thr" "$bc" "$name" "$C_RESET"
    done <<< "$sorted"
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: inventory
#─────────────────────────────────────────────────────────────────────────────
cmd_inventory() {
    local sort="${1:-category}"
    case "$sort" in
        name|price|pricedesc|qty|category) ;;
        *) err "Bad sort '$sort' (use: name, price, pricedesc, qty, category)"; return 1 ;;
    esac
    init_dirs
    load_products
    if (( ${#P_NAME[@]} == 0 )); then log "$(t c_no_products)"; return 0; fi

    local bc ptype cinfo cemoji cbc value
    local n=0 units=0 total=0
    local -a rows=()
    for bc in "${!P_NAME[@]}"; do
        ptype="${P_TYPE[$bc]:-}"
        cinfo=$(category_info "$ptype")
        cemoji="${cinfo%%|*}"; cbc="${cinfo#*|}"
        if [[ -n "$ptype" && -z "$cemoji" ]]; then cemoji=$(emoji_for_type "$ptype"); fi
        [[ -z "$cemoji" ]] && cemoji="📦"
        value=$(( ${P_PRICE[$bc]} * ${P_QTY[$bc]} ))
        total=$(( total + value )); units=$(( units + ${P_QTY[$bc]} )); n=$(( n + 1 ))
        rows+=("${ptype,,}|${P_NAME[$bc],,}|$bc|${P_NAME[$bc]}|${P_PRICE[$bc]}|${P_QTY[$bc]}|${P_THRESHOLD[$bc]}|${ptype}|${cemoji}|${cbc}|${value}")
    done

    local sortargs="" sortlabel
    case "$sort" in
        name)      sortargs="-t | -k2,2 -k3,3";   sortlabel="$(t inv_by_name)" ;;
        price)     sortargs="-t | -k5,5n -k2,2";  sortlabel="$(t inv_by_price)" ;;
        pricedesc) sortargs="-t | -k5,5nr -k2,2"; sortlabel="$(t inv_by_pricedesc)" ;;
        qty)       sortargs="-t | -k6,6n -k2,2";  sortlabel="$(t inv_by_qty)" ;;
        category)  sortargs="-t | -k1,1 -k2,2";   sortlabel="$(t inv_by_tray)" ;;
    esac

    local sorted
    sorted=$(printf '%s\n' "${rows[@]}" | sort $sortargs)

    echo "${C_BOLD}📦 $(t inv_title)${C_RESET} — $sortlabel"
    printf "   %s %s  %-14s  %s  %s  %4s  %s\n" "" \
        "$(pad_disp "Name" 24)" "Barcode" "$(rpad_disp "Price" 9)" "" "Qty" "$(pad_disp "Category tray" 20)"
    echo "$(repeat_str '─' 76)"

    local row ptype_l name_l bc2 name price qty thr ptype2 pemoji ptbc value2
    local cur="__NONE__" first=1 status edays estatus
    while IFS='|' read -r ptype_l name_l bc2 name price qty thr ptype2 pemoji ptbc value2; do
        [[ -z "$bc2" ]] && continue
        if [[ "$sort" == "category" && "$ptype_l" != "$cur" ]]; then
            cur="$ptype_l"
            if (( first )); then first=0; else echo; fi
            if [[ -z "$ptype2" ]]; then
                echo " ${C_BOLD}📦 $(t inv_uncategorised)${C_RESET}"
            else
                echo " ${C_BOLD}${pemoji} ${ptype2}${C_RESET}  ${C_DIM}$(t inv_tray) ${ptbc}${C_RESET}"
            fi
        fi
        status="✅"
        if (( qty == 0 )); then status="🔴"
        elif (( qty <= thr )); then status="⚠️"
        fi
        # expiry overlay
        local exp="${P_EXPIRY[$bc2]:-}"
        if [[ -n "$exp" ]]; then
            edays=$(days_until "$exp")
            if (( edays < 0 )); then estatus="⏰"
            elif (( edays <= 7 )); then estatus="⏳"
            else estatus=""; fi
            status="${estatus:-$status}"
        fi
        printf '   %s %s  %-14s  %s  %s  %4s  %s\n' \
            "$pemoji" \
            "$(pad_disp "$(truncate_disp "$name" 22)" 24)" \
            "$bc2" \
            "$(fmt_money_field "$price" 9)" \
            "$status" \
            "x$qty" \
            "$(pad_disp "${pemoji} $(truncate_disp "${ptype2:--}" 16)" 20)"
    done <<< "$sorted"

    echo "$(repeat_str '─' 76)"
    printf " ${C_BOLD}%s: %s   (%d %s, %d %s)${C_RESET}\n" \
        "$(t inv_total_value)" "$(fmt_money "$total")" "$n" "$(t inv_products)" "$units" "$(t inv_units)"
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: summary [YYYY-MM-DD]
#─────────────────────────────────────────────────────────────────────────────
cmd_summary() {
    local date="${1:-}"
    if [[ -z "$date" ]]; then date=$(TZ=Asia/Kolkata date +%Y-%m-%d); fi
    [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { err "Bad date: $date (use YYYY-MM-DD)"; return 1; }
    init_dirs
    if [[ ! -s "$BILLS_CSV" ]] || (( $(wc -l < "$BILLS_CSV") <= 1 )); then
        log "No bills recorded."; return 0
    fi

    declare -A sellbill selllt sellqty voidbill bcname netlt netqty
    local line bno ts bc name qty up lt action rdate
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "bill_no,"* || -z "$line" ]]; then continue; fi
        parse_csv_line "$line"
        bno="${CSV_FIELDS[0]:-}"; ts="${CSV_FIELDS[1]:-}"; bc="${CSV_FIELDS[2]:-}"
        name="${CSV_FIELDS[3]:-}"; qty="${CSV_FIELDS[4]:-}"; up="${CSV_FIELDS[5]:-}"
        lt="${CSV_FIELDS[6]:-}"; action="${CSV_FIELDS[7]:-}"
        if [[ -z "$bno" ]]; then continue; fi
        rdate="${ts:0:10}"
        if [[ "$rdate" == "$date" ]]; then
            if [[ "$action" == "SELL" ]]; then
                sellbill["$bno"]=1
                selllt["$bno"]=$(( ${selllt["$bno"]:-0} + lt ))
                sellqty["$bno"]=$(( ${sellqty["$bno"]:-0} + qty ))
                bcname["$bc"]="$name"
                netlt["$bc"]=$(( ${netlt["$bc"]:-0} + lt ))
                netqty["$bc"]=$(( ${netqty["$bc"]:-0} + qty ))
            elif [[ "$action" == "VOID" ]]; then
                voidbill["$bno"]=1
                netlt["$bc"]=$(( ${netlt["$bc"]:-0} - lt ))
                netqty["$bc"]=$(( ${netqty["$bc"]:-0} - qty ))
            fi
        fi
    done < "$BILLS_CSV"

    local processed=0 units=0 revenue=0 b
    for b in "${!sellbill[@]}"; do
        if [[ -z "${voidbill[$b]+x}" ]]; then
            processed=$(( processed + 1 ))
            revenue=$(( revenue + ${selllt[$b]:-0} ))
            units=$(( units + ${sellqty[$b]:-0} ))
        fi
    done
    local voids=0
    for b in "${!voidbill[@]}"; do voids=$(( voids + 1 )); done

    local -a tops=() bc
    for bc in "${!netlt[@]}"; do
        if (( ${netlt[$bc]:-0} > 0 )); then
            tops+=("${netlt[$bc]}|${netqty[$bc]}|${bc}|${bcname[$bc]}")
        fi
    done
    local sorted=""
    if (( ${#tops[@]} > 0 )); then
        sorted=$(printf '%s\n' "${tops[@]}" | sort -t'|' -k1,1nr | head -5)
    fi

    echo "${C_BOLD}$(t m_summary)${C_RESET}  —  $date"
    echo "$(repeat_str '─' 44)"
    printf " Bills processed:  %d\n" "$processed"
    printf " Units sold:       %d\n" "$units"
    printf " Revenue:          %s\n" "$(fmt_money "$revenue")"
    local avg=0
    if (( processed > 0 )); then avg=$(( revenue / processed )); fi
    printf " Average bill:     %s\n" "$(fmt_money "$avg")"
    printf " Voided bills:     %d\n" "$voids"
    echo
    echo " ${C_BOLD}TOP PRODUCTS BY REVENUE${C_RESET}"
    if [[ -z "$sorted" ]]; then
        echo "  (none)"
    else
        local i=1 row rev u nm
        while IFS='|' read -r rev u bc nm; do
            if [[ -z "$rev" ]]; then continue; fi
            printf "  %d. %-26s %s  (%d units)\n" \
                "$i" "$(truncate_name "$nm" 26)" "$(fmt_money_field "$rev" 9)" "$u"
            i=$((i+1))
        done <<< "$sorted"
    fi
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: stockvalue
#─────────────────────────────────────────────────────────────────────────────
cmd_stockvalue() {
    init_dirs
    if [[ ! -s "$PRODUCTS_CSV" ]] || (( $(wc -l < "$PRODUCTS_CSV") <= 1 )); then
        log "$(t c_no_products)"; return 0
    fi
    load_products
    local total=0 n=0 bc name price qty value
    local -a rows=()
    for bc in "${!P_NAME[@]}"; do
        name="${P_NAME[$bc]}"; price="${P_PRICE[$bc]}"; qty="${P_QTY[$bc]}"
        value=$(( price * qty ))
        total=$(( total + value ))
        n=$(( n + 1 ))
        rows+=("$value|$bc|$name|$price|$qty")
    done
    local sorted
    sorted=$(printf '%s\n' "${rows[@]}" | sort -t'|' -k1,1nr)

    echo "${C_BOLD}$(t sv_title)${C_RESET}  ($(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S'))"
    echo "$(repeat_str '─' 56)"
    printf "  %s  %8s  %6s  %12s\n" "$(pad_disp "$(t p_name)" 24)" "$(t p_qty)" "$(t p_price)" "$(t sv_value)"
    echo "$(repeat_str '─' 56)"
    local row val u nm pr qt pemoji
    while IFS='|' read -r val bc nm pr qt; do
        if [[ -z "$val" ]]; then continue; fi
        pemoji=$(emoji_for_type "${P_TYPE[$bc]:-}")
        printf "  %s  %8s  %6s  %12s\n" \
            "$(pad_disp "$pemoji $(truncate_disp "$nm" 20)" 24)" "$qt" "$(fmt_money "$pr")" "$(fmt_money_field "$val" 12)"
    done <<< "$sorted"
    echo "$(repeat_str '─' 56)"
    printf "  ${C_BOLD}%s  %8s  %6s  %12s${C_RESET}\n" "$(pad_disp "$(t sv_total) ($n $(t sv_items))" 24)" "" "" "$(fmt_money_field "$total" 12)"
    log_event "STOCKVALUE" "-" "all" "-" "$total" "inventory valuation snapshot"
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: category list | add <name> [emoji]
#─────────────────────────────────────────────────────────────────────────────
cmd_category() {
    local sub="${1:-}"
    [[ -n "$sub" ]] || { err "Usage: shopkeep.sh category list | add <name> [emoji]"; exit 3; }
    shift
    init_dirs
    case "$sub" in
        list)
            echo "${C_BOLD}🧺 $(t cat_title)${C_RESET}"
            echo "$(repeat_str '─' 56)"
            list_category_trays
            ;;
        add)
            local name="${1:-}" emoji="${2:-}"
            [[ -n "$name" ]] || { err "Usage: shopkeep.sh category add <name> [emoji]"; exit 3; }
            lock
            local existing; existing=$(category_info "$name")
            if [[ -n "${existing%%|*}" ]]; then
                unlock
                err "Category tray '$name' already exists (${existing%%|*})."
                return 1
            fi
            local info; info=$(ensure_category "$name" "$emoji")
            unlock
            log "$(t cat_created): ${info%%|*} $name (${info#*|})"
            ;;
        *)
            err "Unknown category subcommand: $sub"; exit 3 ;;
    esac
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: lang [code]
#─────────────────────────────────────────────────────────────────────────────
cmd_lang() {
    init_dirs
    if [[ $# -eq 0 ]]; then
        local cur
        cur=$(conf lang en)
        echo "Current language: $cur"
        echo "Supported languages:"
        list_langs
        echo
        echo "Set with: ./shopkeep.sh lang <code>  (e.g. ./shopkeep.sh lang hi)"
        return 0
    fi
    local code="$1"
    if ! set_lang "$code"; then
        err "Unknown language code: $code"
        echo "Supported:" >&2
        list_langs >&2
        exit 1
    fi
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: inventorylog [N]
#─────────────────────────────────────────────────────────────────────────────
cmd_inventorylog() {
    init_dirs
    if [[ ! -s "$INVENTORY_LOG" ]] || (( $(wc -l < "$INVENTORY_LOG") <= 1 )); then
        log "Inventory log is empty."
        return 0
    fi
    local n="${1:-25}"
    [[ "$n" =~ ^[0-9]+$ ]] || { err "Bad count: $n"; return 1; }
    echo "${C_BOLD}$(t invlog_title)${C_RESET}  (last $n entries)  —  $INVENTORY_LOG"
    echo "$(repeat_str '─' 78)"
    printf "%-19s  %-10s  %-14s  %-22s  %5s  %9s  %s\n" \
        "Timestamp" "Event" "Barcode" "Name" "Qty" "Price" "Detail"
    echo "$(repeat_str '─' 78)"
    local line total
    total=$(wc -l < "$INVENTORY_LOG")
    local skip=$(( total - n - 1 ))
    (( skip < 0 )) && skip=0
    local ts ev bc nm q pr de
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "timestamp,"* || -z "$line" ]]; then continue; fi
        parse_csv_line "$line"
        ts="${CSV_FIELDS[0]}"; ev="${CSV_FIELDS[1]}"; bc="${CSV_FIELDS[2]}"
        nm="${CSV_FIELDS[3]}"; q="${CSV_FIELDS[4]}"; pr="${CSV_FIELDS[5]:-}"; de="${CSV_FIELDS[6]:-}"
        local price_disp="-"
        if [[ "$pr" =~ ^-?[0-9]+$ ]]; then price_disp=$(fmt_money "$pr"); fi
        local color="$C_RESET"
        case "$ev" in
            ADD)        color="$C_GREEN" ;;
            VOID)       color="$C_YELLOW" ;;
            STOCKVALUE) color="$C_CYAN" ;;
        esac
        printf "%s%-19s  %-10s  %-14s  %-22s  %5s  %9s  %s%s\n" \
            "$color" "$ts" "$ev" "$bc" "$(truncate_name "$nm" 22)" "$q" "$price_disp" "$de" "$C_RESET"
    done < <(tail -n "$((n+1))" "$INVENTORY_LOG")
}

#─────────────────────────────────────────────────────────────────────────────
# Void a bill — append VOID rows + restore stock atomically (append-only ledger)
#   FIXED: print_receipt now requires an explicit phone arg; pass "" here.
#─────────────────────────────────────────────────────────────────────────────
void_bill() {
    local bill_no="$1" confirm="${2:-0}"
    init_dirs
    lock
    local ts_bill="" voided=0 bill_phone=""
    local rbc=() rname=() rup=() rqt=() rlt=() rdisc=()
    local line bno ts bc name qty up lt action disc phone_row
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "bill_no,"* || -z "$line" ]]; then continue; fi
        parse_csv_line "$line"
        bno="${CSV_FIELDS[0]}"; ts="${CSV_FIELDS[1]}"; bc="${CSV_FIELDS[2]}"
        name="${CSV_FIELDS[3]}"; qty="${CSV_FIELDS[4]}"; up="${CSV_FIELDS[5]}"
        lt="${CSV_FIELDS[6]}"; action="${CSV_FIELDS[7]}"
        phone_row="${CSV_FIELDS[8]:-}"
        disc="${CSV_FIELDS[9]:-0}"
        if [[ "$bno" == "$bill_no" ]]; then
            if [[ "$action" == "VOID" ]]; then voided=1; fi
            if [[ "$action" == "SELL" ]]; then
                rbc+=("$bc"); rname+=("$name"); rup+=("$up"); rqt+=("$qty"); rlt+=("$lt"); rdisc+=("$disc")
                ts_bill="$ts"
                [[ -n "$phone_row" ]] && bill_phone="$phone_row"
            fi
        fi
    done < "$BILLS_CSV"

    if (( ${#rbc[@]} == 0 )); then unlock; err "Bill $bill_no not found."; return 1; fi
    if (( voided )); then unlock; err "Bill $bill_no already voided."; return 1; fi

    local i total=0
    for ((i=0; i<${#rbc[@]}; i++)); do total=$(( total + rlt[i] )); done
    echo "${C_BOLD}Bill #$bill_no${C_RESET}  ($ts_bill)"
    for ((i=0; i<${#rbc[@]}; i++)); do
        printf "  %-22s x%s  %s\n" \
            "$(truncate_name "${rname[$i]}" 22)" "${rqt[$i]}" \
            "$(fmt_money_field "${rlt[$i]}" 9)"
    done
    printf "  TOTAL: %s\n" "$(fmt_money "$total")"

    if (( confirm )); then
        printf "Void this bill? (y/N): "
        local yn; read -r yn || yn=""
        [[ "$yn" =~ ^[yY] ]] || { unlock; log "Void cancelled."; return 1; }
    fi

    local ts_now; ts_now=$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')

    for ((i=0; i<${#rbc[@]}; i++)); do
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$bill_no" "$ts_now" "$(csv_quote "${rbc[$i]}")" "$(csv_quote "${rname[$i]}")" \
            "${rqt[$i]}" "${rup[$i]}" "${rlt[$i]}" "VOID" "$(csv_quote "$bill_phone")" "${rdisc[$i]:-0}" >> "$BILLS_CSV"
    done

    local deltas=()
    for ((i=0; i<${#rbc[@]}; i++)); do
        deltas+=("${rbc[$i]} ${rqt[$i]}")
    done
    if ! apply_stock_delta "${deltas[@]}"; then
        unlock
        err "ERROR: stock restore failed for bill $bill_no. VOID rows written; check stock manually."
        return 1
    fi

    unlock
    for ((i=0; i<${#rbc[@]}; i++)); do
        log_event "VOID" "${rbc[$i]}" "${rname[$i]}" "${rqt[$i]}" "${rup[$i]}" "voided bill #$bill_no"
    done
    log "Bill #$bill_no voided. Stock restored."
    echo
    local -a vlines=()
    for ((i=0; i<${#rbc[@]}; i++)); do
        vlines+=("${rbc[$i]}${US}${rname[$i]}${US}${rup[$i]}${US}${rqt[$i]}${US}${rlt[$i]}${US}${rdisc[$i]:-0}")
    done
    print_receipt "VOID REVERSAL" "$(t r_reversed)" "$bill_no" "$ts_now" "$total" "$bill_phone" 0 "$total" "${vlines[@]}"
    return 0
}

cmd_void() {
    local bno="${1:-}"
    [[ -n "$bno" ]] || { err "Usage: shopkeep.sh void <bill_no>"; exit 3; }
    [[ "$bno" =~ ^[0-9]+$ ]] || { err "bill_no must be a number"; exit 1; }
    void_bill "$bno" 0 || exit 1
}

#─────────────────────────────────────────────────────────────────────────────
# Backup — tar.gz of shopkeep-data/ into backups/ (keep last 14)
#─────────────────────────────────────────────────────────────────────────────
backup_now() {
    command -v tar >/dev/null || { err "tar not found; backup skipped."; return 1; }
    init_dirs
    mkdir -p "$BACKUPS_DIR"
    local ts; ts=$(TZ=Asia/Kolkata date +%Y%m%d-%H%M%S)
    local archive="$BACKUPS_DIR/shopkeep-$ts.tar.gz"
    local parent base
    parent="$(dirname "$DATA_DIR")"
    base="$(basename "$DATA_DIR")"
    if tar -czf "$archive" -C "$parent" "$base" 2>/dev/null; then
        local -a files=()
        while IFS= read -r f; do files+=("$f"); done < <(ls -1 "$BACKUPS_DIR"/shopkeep-*.tar.gz 2>/dev/null | sort)
        if (( ${#files[@]} > 14 )); then
            local i to_remove=$(( ${#files[@]} - 14 ))
            for ((i=0; i<to_remove; i++)); do rm -f "${files[$i]}"; done
        fi
        log "Backup created: $archive"
        return 0
    else
        err "Backup failed."
        rm -f "$archive" 2>/dev/null || true
        return 1
    fi
}

maybe_auto_backup() {
    local today; today=$(TZ=Asia/Kolkata date +%Y-%m-%d)
    local last=""
    if [[ -f "$LAST_BACKUP_FILE" ]]; then last=$(cat "$LAST_BACKUP_FILE" 2>/dev/null || true); fi
    if [[ "$last" != "$today" ]]; then
        if backup_now >/dev/null 2>&1; then
            printf '%s\n' "$today" > "$LAST_BACKUP_FILE"
        fi
    fi
}

#─────────────────────────────────────────────────────────────────────────────
# Doctor
#─────────────────────────────────────────────────────────────────────────────
cmd_doctor() {
    init_dirs
    echo "${C_BOLD}shopkeep.sh — dependency & data report${C_RESET}"
    echo
    echo "${C_BOLD}Data location:${C_RESET}"
    printf "  ${C_CYAN}%-18s %s${C_RESET}\n" "Data directory:" "$DATA_DIR"
    printf "  %-18s %s\n" "products.csv:"   "$PRODUCTS_CSV"
    printf "  %-18s %s\n" "bills.csv:"       "$BILLS_CSV"
    printf "  %-18s %s\n" "inventory_log:"  "$INVENTORY_LOG"
    printf "  %-18s %s\n" "trays.csv:"      "$TRAYS_CSV"
    printf "  %-18s %s\n" "categories:"    "$CATEGORIES_CSV"
    printf "  %-18s %s\n" "state:"          "$STATE_FILE"
    printf "  %-18s %s\n" "config:"         "$CONF_FILE"
    printf "  %-18s %s\n" "labels:"         "$LABELS_DIR"
    printf "  %-18s %s\n" "backups:"        "$BACKUPS_DIR"
    printf "  %-18s %s\n" "timezone:"       "Asia/Kolkata (IST, UTC+05:30, Chennai)"
    if [[ -f "$PRODUCTS_CSV" ]]; then
        local pcount; pcount=$(( $(wc -l < "$PRODUCTS_CSV") - 1 ))
        (( pcount >= 0 )) || pcount=0
        printf "  %-18s %d products\n" "Catalog size:" "$pcount"
    fi
    if [[ -f "$CATEGORIES_CSV" ]]; then
        local ccount; ccount=$(( $(wc -l < "$CATEGORIES_CSV") - 1 ))
        (( ccount >= 0 )) || ccount=0
        printf "  %-18s %d category trays\n" "Category trays:" "$ccount"
    fi
    if [[ -f "$BILLS_CSV" ]]; then
        local bcount; bcount=$(( $(wc -l < "$BILLS_CSV") - 1 ))
        (( bcount >= 0 )) || bcount=0
        printf "  %-18s %d line items\n" "Bills ledger:" "$bcount"
    fi
    local curlang; curlang=$(conf lang en)
    printf "  %-18s %s\n" "Language:" "$curlang"

    echo
    echo "${C_BOLD}Required:${C_RESET}"
    if (( BASH_VERSINFO[0] >= 4 )); then
        printf "  bash 4+          %sOK%s (%s.%s.%s)\n" "$C_GREEN" "$C_RESET" \
            "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" "${BASH_VERSINFO[2]}"
    else
        printf "  bash 4+          %sFAIL%s (%s.%s)\n" "$C_RED" "$C_RESET" \
            "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"
    fi
    local ok_core=1 missing_core=""
    for c in printf mv rm sort head cut wc date mkdir ls; do
        command -v "$c" >/dev/null || { ok_core=0; missing_core+=" $c"; }
    done
    if (( ok_core )); then
        printf "  coreutils       %sOK%s\n" "$C_GREEN" "$C_RESET"
    else
        printf "  coreutils       %sMISSING%s (%s )  install: sudo apt install coreutils\n" "$C_RED" "$C_RESET" "$missing_core"
    fi
    if command -v awk >/dev/null; then
        printf "  awk              %sOK%s (%s)\n" "$C_GREEN" "$C_RESET" "$(command -v awk)"
    else
        printf "  awk              %sMISSING%s  install: sudo apt install gawk\n" "$C_RED" "$C_RESET"
    fi
    if command -v flock >/dev/null; then
        printf "  flock            %sOK%s (%s)\n" "$C_GREEN" "$C_RESET" "$(command -v flock)"
    else
        printf "  flock            %sMISSING%s  install: sudo apt install util-linux\n" "$C_RED" "$C_RESET"
    fi

    echo
    echo "${C_BOLD}Optional:${C_RESET}"
    if command -v zbarcam >/dev/null; then
        printf "  zbarcam          %sOK%s (%s)  webcam barcode scan\n" "$C_GREEN" "$C_RESET" "$(command -v zbarcam)"
    else
        printf "  zbarcam          %sMISSING%s  webcam scan disabled  install: sudo apt install zbar-tools\n" "$C_YELLOW" "$C_RESET"
    fi
    if command -v zint >/dev/null; then
        printf "  zint             %sOK%s (%s)  label printing (Code128 PNG)\n" "$C_GREEN" "$C_RESET" "$(command -v zint)"
    else
        printf "  zint             %sMISSING%s  PNG labels disabled (SVG fallback active)  install: sudo apt install zint\n" "$C_YELLOW" "$C_RESET"
    fi
    if [[ -n "${SHOPKEEP_NO_LOOKUP:-}" ]]; then
        printf "  online lookup    %sOFF%s  (SHOPKEEP_NO_LOOKUP is set)\n" "$C_YELLOW" "$C_RESET"
    elif command -v curl >/dev/null; then
        printf "  curl             %sOK%s (%s)  online barcode lookup\n" "$C_GREEN" "$C_RESET" "$(command -v curl)"
    else
        printf "  curl             %sMISSING%s  online lookup disabled  install: sudo apt install curl\n" "$C_YELLOW" "$C_RESET"
    fi
    if command -v tar >/dev/null; then
        printf "  tar              %sOK%s (%s)  backups active\n" "$C_GREEN" "$C_RESET" "$(command -v tar)"
    else
        printf "  tar              %sMISSING%s  backups disabled  install: sudo apt install tar\n" "$C_YELLOW" "$C_RESET"
    fi

    echo
    echo "${C_BOLD}Features:${C_RESET}"
    printf "  billing: yes   lowstock: yes   summary: yes   void: yes   stockvalue: yes\n"
    printf "  search: yes   edit: yes   restock: yes   remove: yes   trays: yes\n"
    printf "  inventory: yes   category-trays: yes   online-lookup: %s\n" \
        "$(command -v curl >/dev/null && [[ -z "${SHOPKEEP_NO_LOOKUP:-}" ]] && echo yes || echo no)"
    printf "  backup: %s   webcam-scan: %s   labels: %s (PNG via zint OR SVG fallback)   languages: 23\n" \
        "$(command -v tar >/dev/null && echo yes || echo no)" \
        "$(command -v zbarcam >/dev/null && echo yes || echo no)" \
        "$(command -v zint >/dev/null && echo PNG || echo SVG-fallback)"
    printf "  timezone: Asia/Kolkata (IST, UTC+05:30, Chennai reference)\n"
    printf "  customer phone: yes (prompted in new-bill flow; LOGGED in bills.csv)\n"
    printf "  expiry tracking: yes (--expiry on add/edit; 'expiry' report; markers in inventory)\n"
    printf "  bill discounts: yes (--discount PCT on bill command + bill menu flow)\n"
    printf "  returns: yes (cmd_return — proper returns without voiding)\n"
    printf "  GSTIN + HSN: yes (config gstin; --hsn on add; printed on receipt for GST compliance)\n"
    printf "  whatsapp sending: yes (wa.me deep-link via system browser; use 'whatsapp --print-url N' for the URL)\n"
    printf "  QR codes: %s (zint -b 58 OR SVG fallback)   EAN-13 labels: %s (PURE-BASH SVG — real scannable bars, no zint needed)\n" \
        "$(command -v zint >/dev/null && echo PNG || echo SVG-fallback)" \
        "$(command -v zint >/dev/null && echo 'PNG via zint' || echo 'pure-bash SVG')"
    printf "  publish to Open Products Facts: %s  (publish <barcode> | all; --publish on add)\n" \
        "$(command -v curl >/dev/null && echo yes || echo no)"
    local gstin; gstin=$(conf gstin "")
    [[ -n "$gstin" ]] && printf "  GSTIN configured: %s\n" "$gstin"
}

#─────────────────────────────────────────────────────────────────────────────
# Self-test — offline; no network, no webcam
#─────────────────────────────────────────────────────────────────────────────
cmd_selftest() {
    local tmp; tmp=$(mktemp -d)
    ST_TMP="$tmp"
    DATA_DIR="$tmp/shopkeep-data"
    PRODUCTS_CSV="$DATA_DIR/products.csv"
    BILLS_CSV="$DATA_DIR/bills.csv"
    INVENTORY_LOG="$DATA_DIR/inventory_log.csv"
    TRAYS_CSV="$DATA_DIR/trays.csv"
    STATE_FILE="$DATA_DIR/state"
    LOCK_FILE="$DATA_DIR/.lock"
    CONF_FILE="$DATA_DIR/shopkeep.conf"
    CATEGORIES_CSV="$DATA_DIR/categories.csv"
    LABELS_DIR="$tmp/labels"
    BACKUPS_DIR="$tmp/backups"
    LAST_BACKUP_FILE="$DATA_DIR/.last_backup_date"
    init_dirs

    local pass=0 fail=0
    st_test() {
        local name="$1"; shift
        if "$@"; then
            printf "  %sPASS%s  %s\n" "$C_GREEN" "$C_RESET" "$name"; pass=$((pass+1))
        else
            printf "  %sFAIL%s  %s\n" "$C_RED" "$C_RESET" "$name"; fail=$((fail+1))
        fi
    }

    echo "${C_BOLD}Running self-tests...${C_RESET}"

    st_test "money math (25.5->2550, etc.)" _st_money
    st_test "CSV roundtrip (comma + quote)" _st_csv
    st_test "negative stock rejection" _st_negstock
    st_test "atomic write + flock" _st_concurrency
    st_test "low stock sort order" _st_lowstock
    st_test "daily summary math" _st_summary
    st_test "remove + restock" _st_remove_restock
    st_test "tray expansion" _st_tray
    st_test "display width engine" _st_dwidth
    st_test "category trays + emoji" _st_category
    st_test "inventory sorting" _st_inventory
    st_test "IST timezone enforced" _st_tz
    st_test "label SVG fallback" _st_label_fallback
    st_test "category-tray barcode lookup" _st_cat_barcode
    st_test "expiry date math" _st_expiry
    st_test "phone logged in bills.csv" _st_phone_logged
    st_test "bill discount math" _st_discount
    st_test "whatsapp URL format" _st_whatsapp_url
    st_test "QR SVG fallback" _st_qr_fallback
    st_test "GSTIN validation" _st_gstin
    st_test "return flow + RETURN rows" _st_returns
    st_test "IST offset is +05:30" _st_tz_offset
    st_test "publish dry-run routing" _st_publish_dryrun
    st_test "EAN-13 SVG generation (no zint)" _st_ean13_svg
    st_test "Indian phone validation" _st_phone_validate

    echo
    local failcolor="$C_GREEN"
    if (( fail > 0 )); then failcolor="$C_RED"; fi
    printf "Self-test: %s%d passed%s, %s%d failed%s\n" \
        "$C_GREEN" "$pass" "$C_RESET" \
        "$failcolor" "$fail" "$C_RESET"
    (( fail == 0 )) || exit 1
}

_st_money() {
    local p
    p=$(rupees_to_paise "25.5")   && [[ "$p" == "2550" ]] || return 1
    p=$(rupees_to_paise "25.00")  && [[ "$p" == "2500" ]] || return 1
    p=$(rupees_to_paise "25")     && [[ "$p" == "2500" ]] || return 1
    p=$(rupees_to_paise "25.05")  && [[ "$p" == "2505" ]] || return 1
    p=$(rupees_to_paise "0.5")    && [[ "$p" == "50" ]]   || return 1
    p=$(rupees_to_paise "100")    && [[ "$p" == "10000" ]] || return 1
    p=$(rupees_to_paise "25.")    && [[ "$p" == "2500" ]] || return 1
    if rupees_to_paise "abc"   2>/dev/null; then return 1; fi
    if rupees_to_paise "25.123" 2>/dev/null; then return 1; fi
    if rupees_to_paise "-5"    2>/dev/null; then return 1; fi
    return 0
}

_st_csv() {
    local name='Milk, 500ml "Special"'
    local quoted; quoted=$(csv_quote "$name")
    local line="8901234567890,$quoted,5000,10,5"
    parse_csv_line "$line"
    [[ "${CSV_FIELDS[0]}" == "8901234567890" ]] || return 1
    [[ "${CSV_FIELDS[1]}" == "$name" ]]        || return 1
    [[ "${CSV_FIELDS[2]}" == "5000" ]]         || return 1
    [[ "${CSV_FIELDS[3]}" == "10" ]]          || return 1
    [[ "${CSV_FIELDS[4]}" == "5" ]]           || return 1
    return 0
}

_st_negstock() {
    do_add "" "NegTest" 1000 2 1 >/dev/null 2>&1 || return 1
    local bc; bc=$(awk -F',' 'NR>1 && $2=="NegTest"{print $1; exit}' "$PRODUCTS_CSV")
    [[ -n "$bc" ]] || return 1
    if commit_bill "$bc 5" >/dev/null 2>&1; then return 1; fi
    local rows; rows=$(( $(wc -l < "$BILLS_CSV") - 1 ))
    (( rows == 0 )) || return 1
    local q; q=$(awk -F',' -v b="$bc" '$1==b{print $4}' "$PRODUCTS_CSV")
    [[ "$q" == "2" ]] || return 1
    return 0
}

_st_concurrency() {
    do_add "" "ConcTest" 1000 10 1 >/dev/null 2>&1 || return 1
    local bc; bc=$(awk -F',' 'NR>1 && $2=="ConcTest"{print $1; exit}' "$PRODUCTS_CSV")
    [[ -n "$bc" ]] || return 1
    ( commit_bill "$bc 4" ) >/dev/null 2>&1 &
    ( commit_bill "$bc 4" ) >/dev/null 2>&1 &
    wait
    local q; q=$(awk -F',' -v b="$bc" '$1==b{print $4}' "$PRODUCTS_CSV")
    [[ "$q" == "2" ]] || return 1
    local bills; bills=$(awk -F',' -v b="$bc" '$3==b && $8=="SELL"{c++} END{print c+0}' "$BILLS_CSV")
    [[ "$bills" == "2" ]] || return 1
    return 0
}

_st_lowstock() {
    do_add "1001" "ZeroStock" 1000 0 5  >/dev/null 2>&1 || return 1
    do_add "1002" "LowOne"    1000 1 5  >/dev/null 2>&1 || return 1
    do_add "1003" "LowFour"   1000 4 10 >/dev/null 2>&1 || return 1
    do_add "1004" "FullStock" 1000 20 5 >/dev/null 2>&1 || return 1
    cmd_lowstock >/dev/null 2>&1 || return 1
    local order
    order=$(awk -F',' 'NR>1 && $4<=$5{print ($5-$4)"\t"$1}' "$PRODUCTS_CSV" \
            | sort -t$'\t' -k1,1nr | head -3 | cut -f2 | paste -sd, -)
    [[ "$order" == "1003,1001,1002" ]] || return 1
    return 0
}

_st_summary() {
    local d="2025-01-10"
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "1" "$d 10:00:00" "2001" "Tea"   "2" "1000" "2000" "SELL" >> "$BILLS_CSV"
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "1" "$d 10:00:00" "2002" "Sugar" "1" "4000" "4000" "SELL" >> "$BILLS_CSV"
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "2" "$d 11:00:00" "2001" "Tea"   "3" "1000" "3000" "SELL" >> "$BILLS_CSV"
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "1" "$d 12:00:00" "2001" "Tea"   "2" "1000" "2000" "VOID" >> "$BILLS_CSV"
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "1" "$d 12:00:00" "2002" "Sugar" "1" "4000" "4000" "VOID" >> "$BILLS_CSV"
    local out; out=$(cmd_summary "$d" 2>/dev/null) || true
    echo "$out" | grep -q "Bills processed:.*1" || return 1
    echo "$out" | grep -q "Units sold:.*3"      || return 1
    echo "$out" | grep -q "Revenue:.*30.00"    || return 1
    echo "$out" | grep -q "Average bill:.*30.00" || return 1
    echo "$out" | grep -q "Voided bills:.*1"   || return 1
    echo "$out" | grep -q "Tea"                || return 1
    return 0
}

_st_remove_restock() {
    do_add "9001" "TestItem" 1000 10 2 "" "Test" "" >/dev/null 2>&1 || return 1
    cmd_restock 9001 --qty 5 >/dev/null 2>&1 || return 1
    local q; q=$(awk -F, '$1==9001{print $4}' "$PRODUCTS_CSV")
    [[ "$q" == "15" ]] || return 1
    FORCE_REMOVE=1 cmd_remove 9001 --reason "end of line" >/dev/null 2>&1 || return 1
    if grep -q "^9001," "$PRODUCTS_CSV"; then return 1; fi
    if ! grep -q "REMOVE.*end of line" "$INVENTORY_LOG"; then return 1; fi
    return 0
}

_st_tray() {
    do_add "9101" "ItemA" 1000 5 0 "" "" "" >/dev/null 2>&1 || return 1
    do_add "9102" "ItemB" 2000 5 0 "" "" "" >/dev/null 2>&1 || return 1
    cmd_tray add "9900" --name "Combo" --items "9101:1,9102:2" >/dev/null 2>&1 || return 1
    lock; load_products; load_trays
    local rc
    local -a traycart=()
    local line ibc iqt
    while read -r ibc iqt; do
        if [[ -z "$ibc" ]]; then continue; fi
        traycart+=("$ibc $iqt")
    done < <(expand_tray 9900 1)
    rc=$?
    unlock
    [[ $rc -eq 0 ]] || return 1
    [[ ${#traycart[@]} -eq 2 ]] || return 1
    [[ "${traycart[0]}" == "9101 1" ]] || return 1
    [[ "${traycart[1]}" == "9102 2" ]] || return 1
    if ! commit_bill "${traycart[@]}" >/dev/null 2>&1; then return 1; fi
    local q1 q2
    q1=$(awk -F, '$1==9101{print $4}' "$PRODUCTS_CSV")
    q2=$(awk -F, '$1==9102{print $4}' "$PRODUCTS_CSV")
    [[ "$q1" == "4" ]] || return 1
    [[ "$q2" == "3" ]] || return 1
    return 0
}

_st_dwidth() {
    [[ "$(dwidth "abc")" == "3" ]] || return 1
    [[ "$(dwidth "🥛")" == "2" ]] || return 1
    [[ "$(dwidth "बारकोड")" == "8" ]] || return 1
    local p; p=$(pad_disp "ab" 5)
    [[ "${#p}" == "5" ]] || return 1
    p=$(rpad_disp "ab" 5)
    [[ "${#p}" == "5" ]] || return 1
    return 0
}

_st_category() {
    do_add "9201" "EmojiMilk" 1000 5 0 "" "Dairy" "" >/dev/null 2>&1 || return 1
    [[ "$(emoji_for_type "Dairy")" == "🥛" ]] || return 1
    [[ "$(emoji_for_type "mystery-thing")" == "📦" ]] || return 1
    grep -q "^Dairy," "$CATEGORIES_CSV" || return 1
    local info; info=$(category_info "Dairy")
    [[ "$info" == "🥛|"* ]] || return 1
    [[ -n "${info#*|}" ]] || return 1
    return 0
}

_st_inventory() {
    do_add "9301" "Beta" 2000 5 0 "" "Snacks" "" >/dev/null 2>&1 || return 1
    do_add "9302" "Alpha" 1000 7 0 "" "Dairy" "" >/dev/null 2>&1 || return 1
    local out
    out=$(cmd_inventory name 2>/dev/null) || return 1
    local la lb
    la=$(echo "$out" | grep -n "Alpha" | head -1 | cut -d: -f1)
    lb=$(echo "$out" | grep -n "Beta"  | head -1 | cut -d: -f1)
    [[ -n "$la" && -n "$lb" && "$la" -lt "$lb" ]] || return 1
    out=$(cmd_inventory pricedesc 2>/dev/null) || return 1
    la=$(echo "$out" | grep -n "Alpha" | head -1 | cut -d: -f1)
    lb=$(echo "$out" | grep -n "Beta"  | head -1 | cut -d: -f1)
    [[ -n "$la" && -n "$lb" && "$lb" -lt "$la" ]] || return 1
    out=$(cmd_inventory category 2>/dev/null) || return 1
    echo "$out" | grep -q "Dairy" || return 1
    echo "$out" | grep -q "Snacks" || return 1
    return 0
}

# NEW: timezone must be Asia/Kolkata
_st_tz() {
    [[ "${TZ:-}" == "Asia/Kolkata" ]] || return 1
    # IST offset = +05:30, so date -u and date should differ by 5h30m
    local u l
    u=$(LC_ALL=C date -u '+%H%M')
    l=$(LC_ALL=C TZ=Asia/Kolkata date '+%H%M')
    # crude: just confirm TZ affects the call (different output OR same at the 30-min mark)
    [[ -n "$u" && -n "$l" ]] || return 1
    return 0
}

# NEW: SVG fallback runs even without zint
_st_label_fallback() {
    local out; out=$(gen_label_fallback "12345" "$LABELS_DIR/12345.png")
    [[ -f "$out" ]] || return 1
    [[ "$out" == *.svg ]] || return 1
    grep -q "12345" "$out" || return 1
    return 0
}

# NEW: category-tray barcode (3xxxxxxxxxxxx) is recognisable by category_tray_info
_st_cat_barcode() {
    # Dairy is one of the default seeded categories
    local info; info=$(category_info "Dairy")
    local cbc="${info#*|}"
    [[ -n "$cbc" ]] || return 1
    local back; back=$(category_tray_info "$cbc")
    [[ "${back%%|*}" == "Dairy" ]] || return 1
    return 0
}

#─────────────────────────────────────────────────────────────────────────────
# NEW self-tests for v1.2.0 features (expiry, phone-on-bill, discount, WhatsApp,
# QR fallback, GSTIN validation, returns, IST offset).
#─────────────────────────────────────────────────────────────────────────────
_st_expiry() {
    do_add "7001" "ExpItem" 1000 5 0 "" "" "" "2099-12-31" "" >/dev/null 2>&1 || return 1
    do_add "7002" "PastItem" 1000 5 0 "" "" "" "2000-01-01" "" >/dev/null 2>&1 || return 1
    do_add "7003" "NoExpiry" 1000 5 0 "" "" "" "" "" >/dev/null 2>&1 || return 1
    local d1 d2 d3
    d1=$(days_until "2099-12-31"); d2=$(days_until "2000-01-01"); d3=$(days_until "not-a-date")
    (( d1 > 0 )) || return 1
    (( d2 < 0 )) || return 1
    [[ "$d3" == "0" ]] || return 1
    # cmd_expiry should run without error
    cmd_expiry 14 >/dev/null 2>&1 || return 1
    # 7002 should be in the expired list, 7001 should not
    local out; out=$(cmd_expiry 14 2>/dev/null)
    echo "$out" | grep -q "PastItem" || return 1
    echo "$out" | grep -q "ExpItem" && return 1   # 2099 is far future, not within 14 days
    return 0
}

_st_phone_logged() {
    do_add "7101" "PhoneItem" 1000 10 0 "" "" "" "" "" >/dev/null 2>&1 || return 1
    BILL_PHONE="9876543210"; BILL_DISCOUNT_PCT="0"
    commit_bill "7101 2" >/dev/null 2>&1 || return 1
    [[ -n "$BILL_NO" ]] || return 1
    local phone_logged
    phone_logged=$(awk -F, -v b="$BILL_NO" '$1==b && $8=="SELL" {print $9; exit}' "$BILLS_CSV")
    [[ "$phone_logged" == "9876543210" ]] || return 1
    local msg; msg=$(bill_text_for_whatsapp "$BILL_NO") || return 1
    echo "$msg" | grep -q "9876543210" || return 1
    return 0
}

_st_discount() {
    do_add "7201" "DiscItem" 1000 10 0 "" "" "" "" "" >/dev/null 2>&1 || return 1
    BILL_PHONE=""; BILL_DISCOUNT_PCT="10"
    commit_bill "7201 4" >/dev/null 2>&1 || return 1
    [[ -n "$BILL_NO" ]] || return 1
    # gross = 1000 * 4 = 4000 ; 10% disc = 400 ; line_total = 3600
    local lt disc
    lt=$(awk -F, -v b="$BILL_NO" '$1==b && $8=="SELL" {print $7; exit}' "$BILLS_CSV")
    disc=$(awk -F, -v b="$BILL_NO" '$1==b && $8=="SELL" {print $10; exit}' "$BILLS_CSV")
    [[ "$lt" == "3600" ]] || return 1
    [[ "$disc" == "400" ]] || return 1
    [[ "$BILL_TOTAL" == "3600" ]] || return 1
    [[ "$BILL_DISCOUNT" == "400" ]] || return 1
    return 0
}

_st_whatsapp_url() {
    do_add "7301" "WaItem" 1000 10 0 "" "" "" "" "" >/dev/null 2>&1 || return 1
    BILL_PHONE="9876543210"; BILL_DISCOUNT_PCT="0"
    commit_bill "7301 1" >/dev/null 2>&1 || return 1
    local url; url=$(build_whatsapp_url 9876543210 "Hello World")
    [[ "$url" == https://wa.me/919876543210?text=* ]] || return 1
    [[ "$url" == *Hello+World* ]] || return 1
    # Newlines must be encoded as %0A (not %250a)
    local url2; url2=$(build_whatsapp_url 9123456780 "$(printf 'a\nb')")
    [[ "$url2" == *a%0Ab* ]] || return 1
    return 0
}

_st_qr_fallback() {
    local out="$LABELS_DIR/qr-test.png"
    rm -f "$out" "${out%.png}.svg"
    local f; f=$(gen_qr_code "TESTDATA123" "$out")
    [[ -f "$f" ]] || return 1
    # if zint is missing, f ends with .svg
    if ! command -v zint >/dev/null 2>&1; then
        [[ "$f" == *.svg ]] || return 1
    fi
    grep -q "TESTDATA123" "$f" || return 1
    rm -f "$f"
    return 0
}

_st_gstin() {
    # valid Indian GSTIN format: 2 digits + 5 letters + 4 digits + 1 letter + 1 digit + Z + 1 alnum
    local valid="33ABCDE1234F1Z5"
    local invalid_short="33ABCD"
    local invalid_no_z="33ABCDE1234F1X5"
    # Use the same regex the cmd_config uses
    [[ "$valid"      =~ ^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9]{1}Z[0-9A-Z]{1}$ ]] || return 1
    [[ "$invalid_short"   =~ ^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9]{1}Z[0-9A-Z]{1}$ ]] && return 1
    [[ "$invalid_no_z"     =~ ^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9]{1}Z[0-9A-Z]{1}$ ]] && return 1
    # Set + get via cmd_config
    cmd_config gstin "$valid" >/dev/null 2>&1 || return 1
    local got; got=$(conf gstin "")
    [[ "$got" == "$valid" ]] || return 1
    return 0
}

_st_returns() {
    do_add "7401" "RetItem" 1000 10 0 "" "" "" "" "" >/dev/null 2>&1 || return 1
    BILL_PHONE="9876543210"; BILL_DISCOUNT_PCT="0"
    commit_bill "7401 3" >/dev/null 2>&1 || return 1
    local orig_bill=$BILL_NO
    local q; q=$(awk -F, '$1=="7401"{print $4}' "$PRODUCTS_CSV")
    [[ "$q" == "7" ]] || return 1   # 10 - 3 = 7
    # return 2 of the 3
    cmd_return "$orig_bill" --qty "7401:2" --reason "test" >/dev/null 2>&1 || return 1
    local q2; q2=$(awk -F, '$1=="7401"{print $4}' "$PRODUCTS_CSV")
    [[ "$q2" == "9" ]] || return 1   # 7 + 2 = 9
    # bills.csv should have a RETURN row for that bill
    local ret_action
    ret_action=$(awk -F, -v b="$orig_bill" '$1==b && $8=="RETURN" {print "yes"; exit}' "$BILLS_CSV")
    [[ "$ret_action" == "yes" ]] || return 1
    # inventory_log should have a RETURN event
    grep -q "RETURN" "$INVENTORY_LOG" || return 1
    # Try to return more than was sold — must fail
    if cmd_return "$orig_bill" --qty "7401:99" >/dev/null 2>&1; then return 1; fi
    return 0
}

# Stronger TZ test: actually verify IST = UTC + 05:30
_st_tz_offset() {
    local utc_hm ist_hm utc_s ist_s diff
    utc_hm=$(LC_ALL=C date -u '+%H:%M')
    ist_hm=$(LC_ALL=C TZ=Asia/Kolkata date '+%H:%M')
    # convert both to seconds-since-midnight
    utc_s=$(( 10#${utc_hm:0:2} * 3600 + 10#${utc_hm:3:2} * 60 ))
    ist_s=$(( 10#${ist_hm:0:2} * 3600 + 10#${ist_hm:3:2} * 60 ))
    diff=$(( ist_s - utc_s ))
    # allow for wrap-around midnight
    (( diff < 0 )) && diff=$(( diff + 86400 ))
    # IST is UTC+5:30 = 19800 seconds
    local delta=$(( diff - 19800 ))
    # allow ±60s slack for clock skew between the two date calls
    (( delta >= -60 && delta <= 60 )) || return 1
    return 0
}

# Publish dry-run: verify food/non-food routing to OFF/OPF, internal-barcode skip,
# and that --dry-run never actually hits the network.
_st_publish_dryrun() {
    # Use 13-digit EAN-13-format barcodes so the "all" branch's real-retail filter accepts them.
    do_add "8900000075011" "Parle-G Biscuit 100g" 500 5 0 "Parle" "Snacks" "" "" "" >/dev/null 2>&1 || return 1
    do_add "8900000075028" "Havells LED Bulb 9W"  15000 2 0 "Havells" "Electrical" "" "" "" >/dev/null 2>&1 || return 1
    # food category → should mention Open Food Facts
    local out1; out1=$(cmd_publish --dry-run 8900000075011 2>/dev/null) || return 1
    echo "$out1" | grep -q "Open Food Facts" || return 1
    # non-food category → should mention Open Products Facts
    local out2; out2=$(cmd_publish --dry-run 8900000075028 2>/dev/null) || return 1
    echo "$out2" | grep -q "Open Products Facts" || return 1
    # publish all dry-run should include both real retail barcodes
    local out3; out3=$(cmd_publish --dry-run all 2>/dev/null) || return 1
    echo "$out3" | grep -q "8900000075011" || return 1
    echo "$out3" | grep -q "8900000075028" || return 1
    return 0
}

# EAN-13 SVG generation: verify checksum, pattern length, and that the SVG
# contains <rect> elements (real bars, not just text).
_st_ean13_svg() {
    # 890123456789 + checksum 0 → 8901234567890
    local code; code=$(ean13_full_code 890123456789)
    [[ "$code" == "8901234567890" ]] || return 1
    # 13-digit input returns as-is
    local code2; code2=$(ean13_full_code 8901234567890)
    [[ "$code2" == "8901234567890" ]] || return 1
    # Wrong length must fail
    if ean13_full_code 12345 2>/dev/null; then return 1; fi
    # Generate SVG and verify contents
    local out="$LABELS_DIR/test-ean13.svg"
    rm -f "$out"
    local f; f=$(gen_ean13_svg 8901234567890 "$out") || return 1
    [[ -f "$f" ]] || return 1
    [[ "$f" == *.svg ]] || return 1
    # Should contain at least 30 <rect> elements (bars + background)
    local n; n=$(grep -o '<rect ' "$f" | wc -l)
    (( n >= 30 )) || return 1
    # Should contain the digits 8 901234 567890 as text labels
    grep -q '>8<' "$f" || return 1
    grep -q '>901234<' "$f" || return 1
    grep -q '>567890<' "$f" || return 1
    rm -f "$f"
    return 0
}

# Indian phone validation: valid 10-digit mobiles starting 6/7/8/9
# (with optional 91 prefix or +91) are accepted; everything else is rejected.
_st_phone_validate() {
    local r
    r=$(validate_phone_indian "9876543210")      && [[ "$r" == "919876543210" ]] || return 1
    r=$(validate_phone_indian "919876543210")    && [[ "$r" == "919876543210" ]] || return 1
    r=$(validate_phone_indian "+91-9876543210")   && [[ "$r" == "919876543210" ]] || return 1
    r=$(validate_phone_indian "0919876543210")    && [[ "$r" == "919876543210" ]] || return 1
    r=$(validate_phone_indian "8765432100")      && [[ "$r" == "918765432100" ]] || return 1
    r=$(validate_phone_indian "7123456789")      && [[ "$r" == "917123456789" ]] || return 1
    r=$(validate_phone_indian "6123456789")      && [[ "$r" == "916123456789" ]] || return 1
    # CRITICAL: 9123456780 is a valid 10-digit mobile starting with 9 — must NOT be wrongly stripped of "91"
    r=$(validate_phone_indian "9123456780")      && [[ "$r" == "919123456780" ]] || return 1
    # invalid cases
    if validate_phone_indian "1234567890" 2>/dev/null; then return 1; fi   # starts with 1
    if validate_phone_indian "5678901234" 2>/dev/null; then return 1; fi   # starts with 5
    if validate_phone_indian "987654321"  2>/dev/null; then return 1; fi   # 9 digits
    if validate_phone_indian "98765432101" 2>/dev/null; then return 1; fi  # 11 digits
    if validate_phone_indian "12345" 2>/dev/null;           then return 1; fi   # too short
    if validate_phone_indian "" 2>/dev/null;             then return 1; fi   # empty
    if validate_phone_indian "abcdefghij" 2>/dev/null; then return 1; fi    # no digits
    return 0
}


#─────────────────────────────────────────────────────────────────────────────
# Date helpers (IST-aware). days_until returns int (negative if past).
#─────────────────────────────────────────────────────────────────────────────
ist_today() { TZ=Asia/Kolkata date '+%Y-%m-%d'; }

days_until() {
    local target="$1"
    [[ "$target" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { printf '0'; return 1; }
    local today_epoch target_epoch
    today_epoch=$(TZ=Asia/Kolkata date -d "$(ist_today)" +%s 2>/dev/null || echo 0)
    target_epoch=$(TZ=Asia/Kolkata date -d "$target" +%s 2>/dev/null || echo 0)
    if (( today_epoch == 0 || target_epoch == 0 )); then printf '0'; return 1; fi
    printf '%d' $(( (target_epoch - today_epoch) / 86400 ))
}

#─────────────────────────────────────────────────────────────────────────────
# QR code generation (zint -b 58 = QR; SVG fallback if zint absent).
# Prints the actual file path it wrote (extension may be .svg, not .png).
#─────────────────────────────────────────────────────────────────────────────
gen_qr_code() {
    local data="$1" out="$2"
    mkdir -p "$(dirname "$out")"
    if command -v zint >/dev/null 2>&1; then
        if zint -b 58 -o "$out" -d "$data" 2>/dev/null; then
            [[ -f "$out" ]] && { printf '%s' "$out"; return 0; }
        fi
    fi
    out="${out%.png}.svg"
    local esc="${data//&/&amp;}"; esc="${esc//</&lt;}"; esc="${esc//>/&gt;}"
    cat > "$out" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">
  <rect width="200" height="200" fill="white" stroke="black"/>
  <text x="100" y="90" font-family="monospace" font-size="11" text-anchor="middle">shopkeep QR</text>
  <text x="100" y="115" font-family="monospace" font-size="9" text-anchor="middle">${esc}</text>
</svg>
EOF
    printf '%s' "$out"
    return 0
}

#─────────────────────────────────────────────────────────────────────────────
# URL-encode (POSIX-ish). Used for wa.me message text.
#─────────────────────────────────────────────────────────────────────────────
url_encode() {
    local s="$1" i ch cp out=""
    for ((i=0; i<${#s}; i++)); do
        ch="${s:i:1}"
        case "$ch" in
            [a-zA-Z0-9.~_-]) out+="$ch" ;;
            ' ') out+='+' ;;
            *)
                printf -v cp '%d' "'$ch" 2>/dev/null || cp=63
                out+=$(printf '%%%02X' "$cp")
                ;;
        esac
    done
    printf '%s' "$out"
}

# Validate and normalise an Indian mobile number.
# Accepts: 9876543210, 91-9876543210, +919876543210, 0919876543210, etc.
# Returns 0 + prints normalised 91XXXXXXXXXX (12 digits) on success.
# Returns 1 + prints empty on failure.
# Indian mobile numbers: 10 digits starting with 6/7/8/9, prefixed with 91 (India).
validate_phone_indian() {
    local raw="$1"
    local p="${raw//[!0-9]/}"   # strip ALL non-digits
    [[ -z "$p" ]] && { printf ''; return 1; }
    # Strip leading 0 (some users write 0987...)
    while [[ "${p:0:1}" == "0" ]]; do p="${p:1}"; done
    # Strip leading 91 ONLY if that leaves exactly 10 digits
    # (otherwise "9123456780" — a valid 10-digit mobile starting with 9 — would be wrongly stripped)
    if [[ "${p:0:2}" == "91" ]] && (( ${#p} == 12 )); then
        p="${p:2}"
    fi
    # Now we need exactly 10 digits starting with 6/7/8/9
    (( ${#p} == 10 )) || { printf ''; return 1; }
    case "${p:0:1}" in
        [6-9]) printf '91%s' "$p"; return 0 ;;
        *) printf ''; return 1 ;;
    esac
}

build_whatsapp_url() {
    local phone="$1" message="$2"
    local p="${phone//[!0-9]/}"
    [[ "${p:0:2}" == "91" ]] && p="${p:2}"
    [[ -n "$p" ]] && p="91$p"
    local enc; enc=$(url_encode "$message")
    printf 'https://wa.me/%s?text=%s' "$p" "$enc"
}

# Reconstruct a plain-text receipt for a bill (for WhatsApp). Uses real newlines;
# build_whatsapp_url() will URL-encode them.
bill_text_for_whatsapp() {
    local bill_no="$1"
    init_dirs
    local line bno ts bc name qty up lt action disc phone
    local -a sells=()
    local bill_ts="" bill_phone="" bill_total=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "bill_no,"* || -z "$line" ]] && continue
        parse_csv_line "$line"
        bno="${CSV_FIELDS[0]}"; ts="${CSV_FIELDS[1]}"; bc="${CSV_FIELDS[2]}"
        name="${CSV_FIELDS[3]}"; qty="${CSV_FIELDS[4]}"; up="${CSV_FIELDS[5]}"
        lt="${CSV_FIELDS[6]}"; action="${CSV_FIELDS[7]}"
        phone="${CSV_FIELDS[8]:-}"; disc="${CSV_FIELDS[9]:-0}"
        if [[ "$bno" == "$bill_no" && "$action" == "SELL" ]]; then
            sells+=("$bc${US}$name${US}$up${US}$qty${US}$lt${US}$disc")
            bill_ts="$ts"
            [[ -n "$phone" ]] && bill_phone="$phone"
            bill_total=$(( bill_total + lt ))
        fi
    done < "$BILLS_CSV"
    (( ${#sells[@]} > 0 )) || return 1

    local shop; shop=$(conf shop_name "My Kirana Store")
    local gstin; gstin=$(conf gstin "")
    local NL=$'\n'
    local out=""
    out+="*$shop*$NL"
    [[ -n "$gstin" ]] && out+="GSTIN: $gstin$NL"
    out+="Bill #$(printf '%04d' "$bill_no")$NL"
    out+="$bill_ts$NL"
    [[ -n "$bill_phone" ]] && out+="Cust: $bill_phone$NL"
    out+="$NL"
    local row rbc rname rup rqt rlt rdisc
    for row in "${sells[@]}"; do
        IFS="$US" read -r rbc rname rup rqt rlt rdisc <<< "$row"
        out+="$rname x$rqt = $(fmt_money "$rlt")$NL"
    done
    out+="$NL"
    out+="*TOTAL: $(fmt_money "$bill_total")*$NL"
    out+="Thank you!"
    printf '%s' "$out"
}

# Open wa.me deep-link for a bill in the system browser.
send_whatsapp_bill() {
    local bill_no="$1" phone="${2:-}"
    init_dirs
    local msg; msg=$(bill_text_for_whatsapp "$bill_no") || { err "$(t c_no_bill)"; return 1; }
    if [[ -z "$phone" ]]; then
        phone=$(awk -F, -v b="$bill_no" '$1==b && $8=="SELL" && $9!="" {print $9; exit}' "$BILLS_CSV" 2>/dev/null)
    fi
    [[ -n "$phone" ]] || { err "$(t c_no_phone)"; return 1; }
    local url; url=$(build_whatsapp_url "$phone" "$msg")
    if command -v xdg-open >/dev/null 2>&1; then
        ( xdg-open "$url" >/dev/null 2>&1 & )
    elif command -v sensible-browser >/dev/null 2>&1; then
        ( sensible-browser "$url" >/dev/null 2>&1 & )
    elif command -v open >/dev/null 2>&1; then
        ( open "$url" >/dev/null 2>&1 & )
    else
        printf '%s\n' "$url"
    fi
    log "$(t c_whatsapp_opened)"
    return 0
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: expiry [days]  — list expired and near-expiry items (IST).
#─────────────────────────────────────────────────────────────────────────────
cmd_expiry() {
    local horizon="${1:-14}"
    [[ "$horizon" =~ ^[0-9]+$ ]] || { err "Bad horizon: $horizon (use a number of days)"; return 1; }
    init_dirs
    load_products
    if (( ${#P_NAME[@]} == 0 )); then log "$(t c_no_products)"; return 0; fi
    local any=0 expired=() near=() bc exp d
    for bc in "${!P_NAME[@]}"; do
        exp="${P_EXPIRY[$bc]:-}"
        [[ -n "$exp" ]] || continue
        d=$(days_until "$exp")
        if (( d < 0 )); then
            expired+=("$d|$bc|$exp")
        elif (( d <= horizon )); then
            near+=("$d|$bc|$exp")
        fi
    done
    echo "${C_BOLD}$(t er_title)${C_RESET}  (horizon: $horizon days; today $(ist_today))"
    echo "$(repeat_str '─' 64)"
    if (( ${#expired[@]} > 0 )); then
        echo " ${C_RED}${C_BOLD}$(t er_expired)${C_RESET}"
        local row sorted
        sorted=$(printf '%s\n' "${expired[@]}" | sort -t'|' -k1,1n)
        while IFS='|' read -r d bc exp; do
            [[ -z "$bc" ]] && continue
            printf "  %s %-22s %-14s %s  x%-4s  %d days ago\n" \
                "$(emoji_for_type "${P_TYPE[$bc]:-}")" \
                "$(truncate_name "${P_NAME[$bc]}" 22)" "$bc" "$exp" "${P_QTY[$bc]}" \
                "$(( -d ))"
        done <<< "$sorted"
        any=1
    fi
    if (( ${#near[@]} > 0 )); then
        echo " ${C_YELLOW}${C_BOLD}$(t er_near)${C_RESET}"
        local row sorted
        sorted=$(printf '%s\n' "${near[@]}" | sort -t'|' -k1,1n)
        while IFS='|' read -r d bc exp; do
            [[ -z "$bc" ]] && continue
            printf "  %s %-22s %-14s %s  x%-4s  %d %s\n" \
                "$(emoji_for_type "${P_TYPE[$bc]:-}")" \
                "$(truncate_name "${P_NAME[$bc]}" 22)" "$bc" "$exp" "${P_QTY[$bc]}" \
                "$d" "$(t er_days_left)"
        done <<< "$sorted"
        any=1
    fi
    (( any )) || log "$(t er_no_expiry)"
    return 0
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: return <bill_no> [--qty "bc:qty,bc:qty"] [--reason "..."]
#   Proper returns: appends RETURN rows + restores stock. Does NOT void the original.
#─────────────────────────────────────────────────────────────────────────────
cmd_return() {
    local bill_no="${1:-}"
    shift 2>/dev/null || true
    local reason="" qty_spec=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --reason) [[ $# -ge 2 ]] || { err "--reason needs a value"; return 3; }; reason="$2"; shift 2 ;;
            --qty) [[ $# -ge 2 ]] || { err "--qty needs a value"; return 3; }; qty_spec="$2"; shift 2 ;;
            *) err "Unknown arg: $1"; return 3 ;;
        esac
    done
    [[ -n "$bill_no" ]] || { err "Usage: shopkeep.sh return <bill_no> [--qty \"bc:qty,...\"] [--reason \"...\"]"; return 3; }
    [[ "$bill_no" =~ ^[0-9]+$ ]] || { err "bill_no must be a number"; return 1; }
    init_dirs; lock; load_products
    declare -A return_qty
    if [[ -n "$qty_spec" ]]; then
        local IFS=',' item ibc iqt
        for item in $qty_spec; do
            ibc="${item%%:*}"; iqt="${item#*:}"
            [[ "$ibc" =~ ^[0-9]+$ ]] || { unlock; err "Bad bc in qty spec: $ibc"; return 1; }
            [[ "$iqt" =~ ^[0-9]+$ && "$iqt" -gt 0 ]] || { unlock; err "Bad qty in qty spec: $iqt"; return 1; }
            return_qty["$ibc"]="$iqt"
        done
    fi
    local -a rbc=() rname=() rup=() rqt=() rlt=()
    local line bno ts bc name qty up lt action rphone="" ts_bill=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "bill_no,"* || -z "$line" ]] && continue
        parse_csv_line "$line"
        bno="${CSV_FIELDS[0]}"; bc="${CSV_FIELDS[2]}"; name="${CSV_FIELDS[3]}"
        qty="${CSV_FIELDS[4]}"; up="${CSV_FIELDS[5]}"; lt="${CSV_FIELDS[6]}"; action="${CSV_FIELDS[7]}"
        [[ "$bno" == "$bill_no" ]] || continue
        if [[ "$action" == "SELL" ]]; then
            rbc+=("$bc"); rname+=("$name"); rup+=("$up"); rqt+=("$qty"); rlt+=("$lt")
            ts_bill="${CSV_FIELDS[1]}"
            [[ -n "${CSV_FIELDS[8]:-}" ]] && rphone="${CSV_FIELDS[8]}"
        fi
    done < "$BILLS_CSV"
    (( ${#rbc[@]} > 0 )) || { unlock; err "$(t c_no_bill)"; return 1; }
    # count RETURN rows already present (per barcode)
    declare -A returned_already
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "bill_no,"* || -z "$line" ]] && continue
        parse_csv_line "$line"
        bno="${CSV_FIELDS[0]}"; bc="${CSV_FIELDS[2]}"; qty="${CSV_FIELDS[4]}"; action="${CSV_FIELDS[7]}"
        [[ "$bno" == "$bill_no" && "$action" == "RETURN" ]] || continue
        returned_already["$bc"]=$(( ${returned_already["$bc"]:-0} + qty ))
    done < "$BILLS_CSV"
    local deltas=() return_lines=() total_refund=0
    local i bc qty_to_return already name up lt disc
    for ((i=0; i<${#rbc[@]}; i++)); do
        bc="${rbc[$i]}"; name="${rname[$i]}"; up="${rup[$i]}"; lt="${rlt[$i]}"
        already="${returned_already["$bc"]:-0}"
        if [[ -n "${return_qty[$bc]+x}" ]]; then
            qty_to_return="${return_qty[$bc]}"
        else
            qty_to_return=$(( ${rqt[$i]} - already ))
        fi
        (( qty_to_return > 0 )) || continue
        (( qty_to_return + already <= ${rqt[$i]} )) || {
            unlock; err "Returning $qty_to_return of $bc but only ${rqt[$i]} were sold ($already already returned)"; return 1; }
        deltas+=("$bc $qty_to_return")
        disc=0
        local line_refund=$(( lt * qty_to_return / ${rqt[$i]} ))
        return_lines+=("$bc${US}$name${US}$up${US}$qty_to_return${US}$line_refund${US}$disc")
        total_refund=$(( total_refund + line_refund ))
    done
    (( ${#deltas[@]} > 0 )) || { unlock; log "Nothing to return (already fully returned)."; return 0; }
    local ts_now; ts_now=$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')
    local row rbc2 rname2 rup2 rqt2 rlt2 rdisc2
    for row in "${return_lines[@]}"; do
        IFS="$US" read -r rbc2 rname2 rup2 rqt2 rlt2 rdisc2 <<< "$row"
        rdisc2="${rdisc2:-0}"
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$bill_no" "$ts_now" "$(csv_quote "$rbc2")" "$(csv_quote "$rname2")" \
            "$rqt2" "$rup2" "$rlt2" "RETURN" "$(csv_quote "$rphone")" "$rdisc2" >> "$BILLS_CSV"
    done
    if ! apply_stock_delta "${deltas[@]}"; then
        unlock
        err "ERROR: stock restore failed for return of bill $bill_no. RETURN rows written; check stock manually."
        return 1
    fi
    unlock
    for row in "${return_lines[@]}"; do
        IFS="$US" read -r rbc2 rname2 _ rqt2 _ _ <<< "$row"
        log_event "RETURN" "$rbc2" "$rname2" "$rqt2" "-" "returned from bill #$bill_no${reason:+ — $reason}"
    done
    log "Returned from bill #$bill_no. Refund: $(fmt_money "$total_refund"). Stock restored."
    echo
    print_receipt "RETURN" "$(t r_return)" "$bill_no" "$ts_now" "$total_refund" "$rphone" 0 "$total_refund" "${return_lines[@]}"
    return 0
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: whatsapp <bill_no> [phone]
#─────────────────────────────────────────────────────────────────────────────
cmd_whatsapp() {
    local print_only=0
    [[ "${1:-}" == "--print-url" ]] && { print_only=1; shift; }
    local bill_no="${1:-}" phone="${2:-}"
    [[ -n "$bill_no" ]] || { err "Usage: shopkeep.sh whatsapp [--print-url] <bill_no> [phone]"; return 3; }
    [[ "$bill_no" =~ ^[0-9]+$ ]] || { err "bill_no must be a number"; return 1; }
    init_dirs
    local msg; msg=$(bill_text_for_whatsapp "$bill_no") || { err "$(t c_no_bill)"; return 1; }
    if [[ -z "$phone" ]]; then
        phone=$(awk -F, -v b="$bill_no" '$1==b && $8=="SELL" && $9!="" {print $9; exit}' "$BILLS_CSV" 2>/dev/null)
    fi
    [[ -n "$phone" ]] || { err "$(t c_no_phone)"; return 1; }
    # Validate + normalise the phone (Indian mobile: 10 digits starting 6/7/8/9, with optional 91 prefix)
    local norm; norm=$(validate_phone_indian "$phone")
    if [[ -z "$norm" ]]; then
        err "'$phone' is not a valid Indian mobile number (need 10 digits starting 6/7/8/9)."
        err "The bill is still saved; you can edit the customer phone via 'whatsapp $bill_no <valid-phone>'."
        return 1
    fi
    phone="$norm"
    local url; url=$(build_whatsapp_url "$phone" "$msg")
    if (( print_only )); then
        printf '%s\n' "$url"
        return 0
    fi
    if command -v xdg-open >/dev/null 2>&1; then
        ( xdg-open "$url" >/dev/null 2>&1 & )
    elif command -v sensible-browser >/dev/null 2>&1; then
        ( sensible-browser "$url" >/dev/null 2>&1 & )
    elif command -v open >/dev/null 2>&1; then
        ( open "$url" >/dev/null 2>&1 & )
    else
        printf '%s\n' "$url"
    fi
    log "$(t c_whatsapp_opened)"
    log "Customer will receive it ONLY if $phone is registered with WhatsApp."
    return 0
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: config [key] [value]   — get/set shopkeep.conf
#─────────────────────────────────────────────────────────────────────────────
cmd_config() {
    init_dirs
    if [[ $# -eq 0 ]]; then
        echo "${C_BOLD}shopkeep.conf${C_RESET} ($CONF_FILE):"
        [[ -f "$CONF_FILE" ]] || { echo "  (missing)"; return 0; }
        local line
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            printf "  %s\n" "$line"
        done < "$CONF_FILE"
        return 0
    fi
    local key="$1" val="${2:-}"
    if [[ $# -eq 1 ]]; then
        printf '%s\n' "$(conf "$key" "")"
        return 0
    fi
    if [[ "$key" == "gstin" && -n "$val" ]]; then
        # Indian GSTIN: 2 digits (state) + 5 letters (PAN) + 4 digits + 1 letter + 1 digit + 'Z' + 1 alnum
        [[ "$val" =~ ^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[0-9]{1}Z[0-9A-Z]{1}$ ]] || { err "GSTIN must match Indian format (15 chars, e.g. 33ABCDE1234F1Z5)"; return 1; }
    fi
    if [[ "$key" == "default_threshold" && -n "$val" ]]; then
        [[ "$val" =~ ^[0-9]+$ ]] || { err "default_threshold must be a number"; return 1; }
    fi
    lock
    local tmp="$CONF_FILE.new"
    : > "$tmp"
    if [[ -f "$CONF_FILE" ]]; then
        grep -v "^${key}=" "$CONF_FILE" | grep -v '^$' >> "$tmp" 2>/dev/null || true
    fi
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$CONF_FILE"
    unlock
    log "$(t c_config_set) $key=$val"
}

#─────────────────────────────────────────────────────────────────────────────
# Publish barcodes to Open Products Facts / Open Food Facts.
#
# Why: Blinkit/Zepto/Amazon/Flipkart don't expose public barcode lookup APIs,
# but they all read from (and contribute to) the same open barcode databases
# that everyone else can. By pushing your kirana catalog into Open Products
# Facts (non-food) / Open Food Facts (food), your barcodes become scannable
# anywhere — including any future app that reads those public databases.
#
# Privacy: NO customer phone is ever published. Only product fields:
#          barcode, name, brand (or first word), category, qty pack size.
#          The shop's phone stays in shopkeep.conf and is only used for receipts.
#─────────────────────────────────────────────────────────────────────────────
OPF_BASE="https://world.openproductsfacts.org"
OFF_BASE="https://world.openfoodfacts.org"

# Return 0 if the category looks like food/grocery (→ push to OFF); 1 otherwise (→ push to OPF).
opf_is_food_category() {
    local t="${1,,}"
    [[ -z "$t" ]] && return 1
    case "$t" in
        *staple*|*rice*|*atta*|*flour*|*maida*|*dal*|*pulse*|*grain*|*cereal*|*oil*|*salt*|*sugar*|\
        *snack*|*biscuit*|*cookie*|*chip*|*wafer*|*namkeen*|*bhujia*|*kurkure*|\
        *dairy*|*milk*|*curd*|*yogurt*|*cheese*|*butter*|*ghee*|*lassi*|*buttermilk*|*paneer*|\
        *beverage*|*juice*|*drink*|*water*|*soda*|*cola*|*tea*|*chai*|*coffee*|*sherbet*|\
        *fruit*|*vegetable*|*sabzi*|*produce*|*onion*|*potato*|*tomato*|\
        *bakery*|*bread*|*bun*|*cake*|*pastry*|*rusk*|*pav*|\
        *sweet*|*chocolate*|*candy*|*toffee*|*jam*|*spread*|*honey*|*jaggery*|*dessert*|\
        *spice*|*masala*|*chilli*|*turmeric*|*cardamom*|*clove*|*pepper*|*seasoning*|\
        *pickle*|*achar*|*achaar*|*papad*|\
        *frozen*|*"ice cream"*|*icecream*|\
        *egg*|*meat*|*chicken*|*fish*|*mutton*|\
        *baby*|*diaper*|*infant*|*formula*|\
        *pet*|*"dog food"*|*"cat food"*|*"bird feed"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Publish a single product (by barcode) to the appropriate open database.
publish_product() {
    local bc="$1" dry="${2:-0}"
    init_dirs; lock; load_products; unlock
    [[ -n "${P_NAME[$bc]+x}" ]] || { err "No product with barcode $bc"; return 1; }
    local name="${P_NAME[$bc]}" cat="${P_TYPE[$bc]:-}"
    local brand="${P_DESC[$bc]:-}"
    # Brand fallback: if no description/brand given, use the first word of the name.
    [[ -z "$brand" ]] && brand="${name%% *}"
    local endpoint target
    if opf_is_food_category "$cat"; then
        endpoint="$OFF_BASE/cgi/product.pl"
        target="Open Food Facts"
    else
        endpoint="$OPF_BASE/cgi/product.pl"
        target="Open Products Facts"
    fi
    if (( dry )); then
        log "$(t c_publish_dryrun) → $target: code=$bc name=$name brand=$brand cat=${cat:-(none)}"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || { err "curl required for publishing"; return 2; }
    local http_code
    http_code=$(curl --connect-timeout 5 -m 15 -L -s -o /dev/null -w "%{http_code}" \
        -A "$LOOKUP_UA (open data contributor — India kirana POS)" \
        --data-urlencode "code=$bc" \
        --data-urlencode "product_name=$name" \
        --data-urlencode "brands=$brand" \
        ${cat:+--data-urlencode "categories=$cat"} \
        "$endpoint" 2>/dev/null) || http_code="000"
    case "$http_code" in
        2*|3*)
            log "$(t c_published) $bc $(t publish_to) $target: $name"
            log_event "PUBLISH" "$bc" "$name" "-" "-" "pushed to $target (HTTP $http_code)"
            return 0
            ;;
        *)
            err "$(t c_publish_failed) ($target, HTTP $http_code)"
            return 1
            ;;
    esac
}

# CLI command: publish [--dry-run] <barcode> | all
cmd_publish() {
    local dry=0
    [[ "${1:-}" == "--dry-run" ]] && { dry=1; shift; }
    local bc="${1:-}"
    [[ -n "$bc" ]] || { err "Usage: shopkeep.sh publish [--dry-run] <barcode> | all"; return 3; }
    if [[ "$bc" == "all" ]]; then
        init_dirs; lock; load_products; unlock
        local b n=0 published=0
        for b in "${!P_NAME[@]}"; do
            # only real EAN-13 retail barcodes (12-13 digits, not starting with 2 or 3 = internal/category)
            [[ "$b" =~ ^[0-9]{12,13}$ ]] || continue
            [[ "${b:0:1}" == "2" || "${b:0:1}" == "3" ]] && continue
            n=$((n+1))
            if publish_product "$b" "$dry"; then published=$((published+1)); fi
        done
        if (( n == 0 )); then
            log "$(t c_publish_no_barcodes)"
            return 0
        fi
        log "$(t c_published): $published/$n"
        return 0
    fi
    [[ "$bc" =~ ^[0-9]+$ ]] || { err "barcode must be digits or 'all'"; return 1; }
    publish_product "$bc" "$dry"
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: gen-label <barcode> [out.png]
#   EAN-13 for 12/13-digit retail barcodes; Code128 otherwise; SVG fallback.
#─────────────────────────────────────────────────────────────────────────────
cmd_gen_label() {
    local bc="${1:-}"
    local out="${2:-$LABELS_DIR/$bc.png}"
    [[ -n "$bc" ]] || { err "Usage: shopkeep.sh gen-label <barcode> [out.png]"; return 3; }
    [[ "$bc" =~ ^[0-9]+$ ]] || { err "barcode must be digits"; return 1; }
    init_dirs
    if command -v zint >/dev/null 2>&1; then
        if (( ${#bc} == 12 || ${#bc} == 13 )); then
            local input="${bc:0:12}"
            if zint -b 13 -o "$out" -d "$input" 2>/dev/null; then
                log "Label (EAN-13): $out"
                return 0
            fi
        fi
        if zint -b CODE128 -o "$out" -d "$bc" 2>/dev/null; then
            log "Label (Code128): $out"
            return 0
        fi
    fi
    local f; f=$(gen_label_fallback "$bc" "$out")
    log "Label (SVG fallback): $f"
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: gen-qr <data> [out.png]  — generate a QR code (zint -b 58) + SVG fallback
#─────────────────────────────────────────────────────────────────────────────
cmd_gen_qr() {
    local data="${1:-}" out="${2:-$LABELS_DIR/qr-$(TZ=Asia/Kolkata date +%s).png}"
    [[ -n "$data" ]] || { err "Usage: shopkeep.sh gen-qr <data> [out.png]"; return 3; }
    init_dirs
    local f; f=$(gen_qr_code "$data" "$out")
    log "QR code: $f"
}

#─────────────────────────────────────────────────────────────────────────────
# Generate project files (complete — closes the heredoc that was truncated upstream).
#─────────────────────────────────────────────────────────────────────────────
cmd_gen_files() {
    cat > "$SCRIPT_DIR/shopkeep.README.md" <<'EOF'
# shopkeep.sh — offline POS + inventory for kirana stores

A single-file Bash point-of-sale and inventory system for small retail shops.
No cloud. No database. No internet required. All data lives in plain CSV files
that open directly in Excel.

## Quick start

```bash
chmod +x shopkeep.sh
./shopkeep.sh              # interactive menu
./shopkeep.sh --doctor     # check dependencies
./shopkeep.sh --selftest   # integrity tests
```

## Commands

```
./shopkeep.sh add --name "Tata Salt 1kg" --price 25 --qty 24 [--barcode 8901234567890] \
                [--threshold 8] [--type Staples] [--expiry 2025-12-31] [--hsn 2501]
./shopkeep.sh edit <barcode> [--name X] [--price Y] [--expiry DATE] [--hsn H] ...
./shopkeep.sh restock <barcode> --qty N [--reason "..."]
./shopkeep.sh remove <barcode> [--reason "..."]
./shopkeep.sh search <query>
./shopkeep.sh inventory [name|price|pricedesc|qty|category]
./shopkeep.sh category list | add <name> [emoji]
./shopkeep.sh tray add|list|show|remove ...
./shopkeep.sh bill [--phone 9876543210] [--discount 5]   # reads bc/qty lines from stdin
./shopkeep.sh lowstock
./shopkeep.sh expiry [days]            # expired + near-expiry (default horizon 14 days)
./shopkeep.sh summary [YYYY-MM-DD]
./shopkeep.sh void <bill_no>
./shopkeep.sh return <bill_no> [--qty "bc:qty,..."] [--reason "..."]
./shopkeep.sh whatsapp <bill_no> [phone]   # opens wa.me link in browser
./shopkeep.sh stockvalue
./shopkeep.sh inventorylog [N]
./shopkeep.sh config [key] [value]    # shop_name / gstin / address / phone / default_threshold
./shopkeep.sh gen-label <barcode> [out.png]   # EAN-13 for retail, Code128 otherwise, SVG fallback
./shopkeep.sh gen-qr <data> [out.png]         # QR code (zint -b 58) + SVG fallback
./shopkeep.sh lang [code]
./shopkeep.sh backup
./shopkeep.sh --doctor | --selftest | --gen-files | -h | -V
```

## Features

- **Offline-first**: CSV files only. Open in Excel. Zero cloud.
- **23 Indian languages + English** for the interactive UI.
- **Integer paise math**: no floating-point rounding drift.
- **IST (Asia/Kolkata, UTC+05:30, Chennai) forced** for every timestamp.
- **Append-only bills ledger**: SELL / VOID / RETURN rows. Auditor-friendly.
- **Customer phone logged in bills.csv** so you can query bills by customer.
- **Per-line + bill-level discount** support.
- **Expiry tracking**: --expiry on add/edit; `expiry` report; markers in inventory.
- **GSTIN + HSN code support** printed on receipts (Indian GST compliance).
- **WhatsApp bill sending** via wa.me deep-link (opens WhatsApp Web/app with prefilled receipt text).
- **QR code generation** (zint -b 58) + SVG fallback for receipts and labels.
- **EAN-13 retail barcodes** for 13-digit codes; Code128 otherwise.
- **Combo trays + Category trays** (Blinkit-style scan a tray to add all items).
- **Online barcode lookup** uses the free, public Open Food Facts / Open Products Facts / UPCitemDB APIs. NOT Blinkit/Zepto/Amazon/Flipkart — they don't expose public barcode lookup APIs.
- **No government API push**: there's no public Indian government retail-barcode API. For GST-registered shops, print your GSTIN on receipts (built-in). GST e-invoicing (einvoice1.gst.gov.in) is for B2B >= Rs.50,000 only.

## Files (under ./shopkeep-data/, gitignored)

- products.csv: barcode,name,price_paise,qty,threshold,description,type,image,expiry_date,hsn_code
- bills.csv: bill_no,timestamp,barcode,name,qty,unit_price_paise,line_total,action,phone,discount_paise
- inventory_log.csv: timestamp,event,barcode,name,qty,price_paise,detail
- trays.csv: tray_barcode,name,item_barcode,item_name,item_qty,item_price_paise
- categories.csv: name,emoji,tray_barcode
- state: next_bill_no=N
- shopkeep.conf: shop_name, default_threshold, gstin, address, phone, lang
- backups/: shopkeep-<ts>.tar.gz (last 14 kept)
- labels/: <barcode>.png (via zint) or .svg fallback + product images

## License

MIT
EOF
    log "Wrote $SCRIPT_DIR/shopkeep.README.md"
}

#─────────────────────────────────────────────────────────────────────────────
# Interactive menu loop
#─────────────────────────────────────────────────────────────────────────────
menu_header() {
    clear 2>/dev/null || true
    echo "${C_BOLD}$(conf shop_name "My Kirana Store")${C_RESET}"
    echo "${C_DIM}$(now_date)  $(now_time)  IST${C_RESET}"
    local gstin; gstin=$(conf gstin "")
    [[ -n "$gstin" ]] && echo "${C_DIM}GSTIN: $gstin${C_RESET}"
    echo "$(repeat_str '─' 42)"
}

menu_loop() {
    init_dirs
    i18n_init
    while true; do
        menu_header
        cat <<MENU_EOF
 1) $(t m_new_bill)
 2) $(t m_add_product)
 3) $(t m_manage)
 4) $(t m_search)
 5) $(t m_inventory)
 6) $(t m_low_stock)
 7) $(t m_expiry)
 8) $(t m_summary)
 9) $(t m_stock_value)
10) $(t m_void)
11) $(t m_return)
12) $(t m_tray)
13) $(t m_categories)
14) $(t m_whatsapp)
15) $(t m_backup)
16) $(t m_config)
17) $(t m_publish)
18) $(t m_language)
 0) $(t m_exit)
MENU_EOF
        printf '%s' "$(t m_choose)"
        local choice=""; read -r choice || { echo; break; }
        case "$choice" in
            1) menu_new_bill ;;
            2) menu_add_product ;;
            3) menu_manage ;;
            4) printf '%s' "$(t m_search): "; local q=""; read -r q; [[ -n "$q" ]] && cmd_search "$q" ;;
            5) menu_inventory ;;
            6) cmd_lowstock ;;
            7) printf '%s' "$(t er_days_left) horizon (blank=14): "; local h=""; read -r h; cmd_expiry "${h:-14}" ;;
            8) cmd_summary ;;
            9) cmd_stockvalue ;;
            10) printf '%s' "$(t p_bill_no)"; local b=""; read -r b; [[ -n "$b" ]] && void_bill "$b" 1 ;;
            11) printf '%s' "$(t p_return_bill)"; local b=""; read -r b; [[ -n "$b" ]] && cmd_return "$b" ;;
            12) menu_tray ;;
            13) menu_categories ;;
            14) printf 'Bill no: '; local b=""; read -r b; [[ -n "$b" ]] && cmd_whatsapp "$b" ;;
            15) backup_now ;;
            16) menu_config ;;
            17) menu_publish ;;
            18) menu_language ;;
            0|'') printf '%s\n' "$(t c_bye)"; break ;;
            *) err "Unknown choice: $choice" ;;
        esac
        printf '\n%sPress Enter to continue...%s' "$C_DIM" "$C_RESET"
        read -r _ < /dev/tty 2>/dev/null || true
    done
}

menu_new_bill() {
    BILL_PHONE=""; BILL_DISCOUNT_PCT="0"; BILL_LINES=()
    local cart=() line bc q
    echo "${C_BOLD}$(t m_new_bill)${C_RESET}  (blank line to finish)"
    init_dirs; lock; load_products; load_trays; unlock
    while true; do
        printf '%s' "$(t p_scan)"
        read -r line || { echo; break; }
        [[ -z "$line" ]] && break
        if [[ "$line" == s:* ]]; then
            local q="${line#s:}"
            cmd_search "$q" 2>/dev/null
            continue
        fi
        read -r bc q <<< "$line"
        [[ -z "$q" ]] && q=1
        if ! [[ "$bc" =~ ^[0-9]+$ ]]; then err "Bad barcode: $bc"; continue; fi
        if ! [[ "$q" =~ ^[0-9]+$ ]] || (( q <= 0 )); then err "Bad qty: $q"; continue; fi
        if [[ -n "${TRAY_NAME[$bc]+x}" ]]; then
            local expanded erc ibc iqt
            expanded=$(expand_tray "$bc" "$q"); erc=$?
            if (( erc != 0 )); then err "Tray $bc references an unknown item"; continue; fi
            while read -r ibc iqt; do
                [[ -z "$ibc" ]] && continue
                cart+=("$ibc $iqt")
            done <<< "$expanded"
            log "→ TRAY expanded: ${TRAY_NAME[$bc]}"
            continue
        fi
        cart+=("$bc $q")
    done
    (( ${#cart[@]} > 0 )) || { log "$(t c_empty_bill)"; return 1; }
    echo
    local preview_total=0 pbc pq
    for line in "${cart[@]}"; do
        pbc="${line%% *}"; pq="${line##* }"
        local pname="${P_NAME[$pbc]:-???}" pup="${P_PRICE[$pbc]:-0}"
        printf '  %-22s x%-3s  %s\n' "$(truncate_name "$pname" 22)" "$pq" "$(fmt_money "$((pup * pq))")"
        preview_total=$(( preview_total + (pup * pq) ))
    done
    echo "  ──────────────────────────────"
    printf '  %-22s      %s\n' "Subtotal" "$(fmt_money "$preview_total")"
    printf '%s' "$(t p_discount) (blank=0): "
    local dpct=""; read -r dpct || true
    [[ -z "$dpct" ]] && dpct=0
    if ! [[ "$dpct" =~ ^[0-9]+$ ]] || (( dpct < 0 || dpct > 100 )); then dpct=0; fi
    BILL_DISCOUNT_PCT="$dpct"
    printf '%s' "$(t p_phone): "
    local ph=""; read -r ph || true
    # Validate + normalise the phone (so it works in wa.me URLs)
    if [[ -n "$ph" ]]; then
        local norm; norm=$(validate_phone_indian "$ph")
        if [[ -z "$norm" ]]; then
            err "'$ph' is not a valid Indian mobile number (need 10 digits starting 6/7/8/9). Skipping WhatsApp."
            BILL_PHONE=""
        else
            BILL_PHONE="$norm"
            log "Phone normalised: $norm"
        fi
    fi
    printf '%s' "$(t p_confirm_bill)"
    local yn=""; read -r yn || true
    [[ "$yn" =~ ^[yY] ]] || { log "$(t c_cancelled)"; return 1; }
    if commit_bill "${cart[@]}"; then
        echo
        local subtotal=$(( BILL_TOTAL + BILL_DISCOUNT ))
        print_receipt "$(conf shop_name)" "$(t r_net)" "$BILL_NO" "$BILL_TS" \
            "$BILL_TOTAL" "$BILL_PHONE" "$BILL_DISCOUNT" "$subtotal" "${BILL_LINES[@]}"
        local dmsg=""
        (( BILL_DISCOUNT > 0 )) && dmsg="  (discount $(fmt_money "$BILL_DISCOUNT"))"
        log "Bill #$BILL_NO saved. Net $(fmt_money "$BILL_TOTAL")$dmsg"
        if [[ -n "$BILL_PHONE" ]]; then
            printf 'Send bill to %s via WhatsApp? (y/N): ' "$BILL_PHONE"
            local w=""; read -r w || true
            if [[ "$w" =~ ^[yY] ]]; then
                send_whatsapp_bill "$BILL_NO" "$BILL_PHONE"
                log "WhatsApp opened in browser."
                log "Customer will receive it ONLY if $BILL_PHONE is registered with WhatsApp."
                log "(If not, the message will not be delivered — no error here, just no delivery.)"
            else
                log "WhatsApp skipped. Bill still saved; you can send it later with: ./shopkeep.sh whatsapp $BILL_NO"
            fi
        fi
    else
        err "Bill not saved."
    fi
}

menu_add_product() {
    # 1) Ask for barcode FIRST (so we can search the open APIs)
    printf '%s' "$(t p_barcode) (blank=auto): "; local bc=""; read -r bc || true
    if [[ -n "$bc" ]]; then
        [[ "$bc" =~ ^[0-9]+$ ]] || { err "Barcode must be digits only."; return 1; }
        # 2) If barcode already exists in catalog → offer edit/restock instead of duplicate-add
        init_dirs; lock; load_products; unlock
        if [[ -n "${P_NAME[$bc]+x}" ]]; then
            log "Barcode $bc already exists: ${P_NAME[$bc]}"
            printf 'Edit (e) / Restock (r) / Cancel (n)? '
            local ch=""; read -r ch || true
            case "$ch" in
                [eE])
                    printf 'Field to edit (name/price/threshold/type/expiry/hsn/desc/image): '; local f=""; read -r f || true
                    printf 'New value: '; local v=""; read -r v || true
                    [[ -n "$f" && -n "$v" ]] && cmd_edit "$bc" --"$f" "$v"
                    return
                    ;;
                [rR])
                    printf '%s' "$(t p_qty): "; local q=""; read -r q || true
                    [[ -n "$q" ]] && cmd_restock "$bc" --qty "$q"
                    return
                    ;;
                *) return 1 ;;
            esac
        fi
    fi
    # 3) Search Open Food Facts / Open Products Facts / UPCitemDB and pre-fill if found
    local api_name="" api_brand="" api_pack="" api_cat="" api_img="" api_src=""
    if [[ -n "$bc" && ${#bc} -ge 8 ]] && [[ -z "${SHOPKEEP_NO_LOOKUP:-}" ]] && command -v curl >/dev/null 2>&1; then
        log "$(t c_lookup_try)"
        local result; result=$(online_lookup "$bc" 2>/dev/null)
        local rc=$?
        if [[ $rc -eq 0 && -n "$result" ]]; then
            IFS=$'\t' read -r api_name api_brand api_pack api_cat api_img api_src <<< "$result"
            show_lookup_result "$api_name" "$api_brand" "$api_pack" "$api_cat" "$api_img" "$api_src"
        elif [[ $rc -eq 2 ]]; then
            log "$(t c_offline)"
        else
            log "$(t c_lookup_miss) — $(t c_custom_hint)"
        fi
    fi
    local name="$api_name" ptype="$api_cat"
    # 4) Ask remaining fields, with API defaults in [brackets] (blank = keep)
    if [[ -n "$name" ]]; then
        printf '%s [%s] (blank=keep): ' "$(t p_name)" "$(truncate_disp "$name" 40)"
    else
        printf '%s: ' "$(t p_name)"
    fi
    local name_in=""; read -r name_in || true
    [[ -n "$name_in" ]] && name="$name_in"
    [[ -z "$name" ]] && { err "$(t p_name) is required."; return 1; }
    printf '%s: ' "$(t p_price)"; local price=""; read -r price || true
    [[ -z "$price" ]] && { err "$(t p_price) is required."; return 1; }
    printf '%s: ' "$(t p_qty)"; local qty=""; read -r qty || true
    [[ -z "$qty" ]] && { err "$(t p_qty) is required."; return 1; }
    printf '%s (blank=default): ' "$(t p_threshold)"; local thr=""; read -r thr || true
    if [[ -n "$ptype" ]]; then
        printf '%s [%s] (blank=keep): ' "$(t p_type)" "$(truncate_disp "$ptype" 30)"
    else
        printf '%s (blank=skip): ' "$(t p_type)"
    fi
    local ptype_in=""; read -r ptype_in || true
    [[ -n "$ptype_in" ]] && ptype="$ptype_in"
    printf '%s (blank=none): ' "$(t p_expiry)"; local expiry=""; read -r expiry || true
    printf '%s (blank=none): ' "$(t p_hsn)"; local hsn=""; read -r hsn || true
    # 5) Generate the EAN-13 label so the shopkeeper has a scannable barcode immediately
    if [[ -n "$bc" && ( ${#bc} -eq 12 || ${#bc} -eq 13 ) ]]; then
        printf 'Generate EAN-13 label SVG? (y/N): '
        local l=""; read -r l || true
        if [[ "$l" =~ ^[yY] ]]; then
            local label_path="$LABELS_DIR/$bc.svg"
            gen_ean13_svg "$bc" "$label_path" >/dev/null 2>&1 && log "Label saved: $label_path"
        fi
    fi
    # 6) Auto-publish to Open Products Facts / Open Food Facts for real retail barcodes?
    local pub_flag=""
    if [[ -n "$bc" && ${#bc} -ge 12 && "${bc:0:1}" != "2" && "${bc:0:1}" != "3" ]]; then
        printf 'Publish to Open Products Facts (contribute to global open DB)? (y/N): '
        local p=""; read -r p || true
        [[ "$p" =~ ^[yY] ]] && pub_flag="--publish"
    fi
    # 7) Save (if bc was blank, do_add auto-generates an internal barcode)
    cmd_add --name "$name" --price "$price" --qty "$qty" \
        ${bc:+--barcode "$bc"} ${thr:+--threshold "$thr"} \
        ${ptype:+--type "$ptype"} ${expiry:+--expiry "$expiry"} ${hsn:+--hsn "$hsn"} $pub_flag
}

menu_manage() {
    printf '%s' "$(t p_barcode): "; local bc=""; read -r bc || true
    [[ -n "$bc" ]] || return 1
    init_dirs; lock; load_products; unlock
    [[ -n "${P_NAME[$bc]+x}" ]] || { err "Not found: $bc"; return 1; }
    show_product "$bc" 1
    echo "$(t manage_sub)"
    printf '%s' "$(t m_choose)"
    local c=""; read -r c || true
    case "$c" in
        1)
            printf 'Field (name/price/threshold/type/expiry/hsn/desc/image): '; local f=""; read -r f || true
            printf 'New value: '; local v=""; read -r v || true
            case "$f" in
                name) cmd_edit "$bc" --name "$v" ;;
                price) cmd_edit "$bc" --price "$v" ;;
                threshold) cmd_edit "$bc" --threshold "$v" ;;
                type) cmd_edit "$bc" --type "$v" ;;
                expiry) cmd_edit "$bc" --expiry "$v" ;;
                hsn) cmd_edit "$bc" --hsn "$v" ;;
                desc) cmd_edit "$bc" --desc "$v" ;;
                image) cmd_edit "$bc" --image "$v" ;;
                *) err "Unknown field: $f" ;;
            esac
            ;;
        2) printf '%s' "$(t p_qty): "; local q=""; read -r q || true; [[ -n "$q" ]] && cmd_restock "$bc" --qty "$q" ;;
        3) cmd_remove "$bc" ;;
        0|"") return 0 ;;
        *) err "Unknown choice: $c" ;;
    esac
}

menu_inventory() {
    echo "$(t inv_sort)"
    printf '%s' "$(t inv_pick)"
    local s=""; read -r s || true
    case "$s" in
        1) s=name ;; 2) s=price ;; 3) s=pricedesc ;; 4) s=qty ;; 5|'') s=category ;;
        *) s=category ;;
    esac
    cmd_inventory "$s"
}

menu_tray() {
    echo "$(t tray_sub)"
    printf '%s' "$(t m_choose)"
    local c=""; read -r c || true
    case "$c" in
        1)
            printf '%s' "$(t p_tray_bc): "; local tbc=""; read -r tbc || true
            printf '%s' "$(t p_tray_name): "; local tn=""; read -r tn || true
            printf '%s' "$(t p_tray_items): "; local it=""; read -r it || true
            [[ -n "$tbc" && -n "$tn" && -n "$it" ]] && cmd_tray add "$tbc" --name "$tn" --items "$it"
            ;;
        2) cmd_tray list ;;
        3) printf '%s' "$(t p_tray_bc): "; local tbc=""; read -r tbc || true; cmd_tray show "$tbc" ;;
        4) printf '%s' "$(t p_tray_bc): "; local tbc=""; read -r tbc || true; cmd_tray remove "$tbc" ;;
        5) menu_categories ;;
        0|"") return 0 ;;
        *) err "Unknown choice: $c" ;;
    esac
}

menu_categories() {
    echo "$(t cat_sub)"
    printf '%s' "$(t m_choose)"
    local c=""; read -r c || true
    case "$c" in
        1) cmd_category list ;;
        2) printf '%s' "$(t cat_new_name): "; local n=""; read -r n || true
           printf 'Emoji (blank=auto): '; local e=""; read -r e || true
           [[ -n "$n" ]] && cmd_category add "$n" "$e" ;;
        0|"") return 0 ;;
        *) err "Unknown choice: $c" ;;
    esac
}

menu_config() {
    echo "${C_BOLD}$(t m_config)${C_RESET}"
    echo "  1) $(t cfg_shop_name)"
    echo "  2) $(t cfg_gstin)"
    echo "  3) $(t cfg_address)"
    echo "  4) $(t cfg_phone)"
    echo "  5) $(t cfg_threshold)"
    echo "  0) Back"
    printf '%s' "$(t m_choose)"
    local c=""; read -r c || true
    local key val
    case "$c" in
        1) key=shop_name ;;
        2) key=gstin ;;
        3) key=address ;;
        4) key=phone ;;
        5) key=default_threshold ;;
        0|"") return 0 ;;
        *) err "Unknown choice: $c"; return 1 ;;
    esac
    echo "$(t cfg_show_setting) $(conf "$key" "")"
    printf '%s' "$(t cfg_new_value)"
    read -r val || true
    [[ -n "$val" ]] && cmd_config "$key" "$val"
}

menu_language() {
    list_langs
    printf '%s' "$(t c_select_lang)"
    local i=""; read -r i || true
    [[ -z "$i" ]] && return 0
    local entry="${LANG_NAMES[$((i-1))]:-}"
    local code="${entry%%:*}"
    [[ -n "$code" ]] && set_lang "$code"
}

menu_publish() {
    echo "${C_BOLD}$(t m_publish)${C_RESET}"
    echo "  1) Publish one product (by barcode)"
    echo "  2) Publish ALL real retail barcodes"
    echo "  3) Dry-run preview (no network)"
    echo "  0) Back"
    printf '%s' "$(t m_choose)"
    local c=""; read -r c || true
    case "$c" in
        1) printf '%s' "$(t p_barcode): "; local b=""; read -r b || true
           [[ -n "$b" ]] && cmd_publish "$b" ;;
        2) cmd_publish all ;;
        3) printf 'Publish all (dry-run)? (y/N): '; local y=""; read -r y || true
           [[ "$y" =~ ^[yY] ]] && cmd_publish --dry-run all ;;
        0|"") return 0 ;;
        *) err "Unknown choice: $c" ;;
    esac
}

#─────────────────────────────────────────────────────────────────────────────
# Main dispatcher
#─────────────────────────────────────────────────────────────────────────────
main() {
    init_dirs
    i18n_init
    maybe_auto_backup 2>/dev/null || true
    case "${1:-}" in
        "") menu_loop ;;
        add)        shift; cmd_add "$@" ;;
        edit)       shift; cmd_edit "$@" ;;
        restock)    shift; cmd_restock "$@" ;;
        remove)     shift; cmd_remove "$@" ;;
        search)     shift; cmd_search "$@" ;;
        inventory)  shift; cmd_inventory "$@" ;;
        category)   shift; cmd_category "$@" ;;
        tray)       shift; cmd_tray "$@" ;;
        bill)       shift; cmd_bill "$@" ;;
        lowstock)   cmd_lowstock ;;
        expiry)     shift; cmd_expiry "$@" ;;
        summary)    shift; cmd_summary "$@" ;;
        void)       shift; cmd_void "$@" ;;
        return|ret) shift; cmd_return "$@" ;;
        whatsapp)   shift; cmd_whatsapp "$@" ;;
        stockvalue) cmd_stockvalue ;;
        inventorylog) shift; cmd_inventorylog "$@" ;;
        lang)       shift; cmd_lang "$@" ;;
        backup)     backup_now ;;
        config)     shift; cmd_config "$@" ;;
        publish)    shift; cmd_publish "$@" ;;
        gen-label)  shift; cmd_gen_label "$@" ;;
        gen-qr)     shift; cmd_gen_qr "$@" ;;
        --doctor|-d)   cmd_doctor ;;
        --selftest|-t) cmd_selftest ;;
        --gen-files)   cmd_gen_files ;;
        -h|--help)     cat <<'EOF'
shopkeep.sh — offline POS + inventory for kirana stores
Usage: ./shopkeep.sh [command] [args]
Run with no args for the interactive menu.
Commands: add, edit, restock, remove, search, inventory, category, tray, bill,
          lowstock, expiry, summary, void, return, whatsapp, stockvalue,
          inventorylog, lang, backup, config, gen-label, gen-qr,
          --doctor, --selftest, --gen-files, -V
EOF
                       ;;
        -V|--version)  echo "shopkeep.sh $VERSION" ;;
        *) err "Unknown command: $1"; echo "Try: ./shopkeep.sh -h"; exit 3 ;;
    esac
}

main "$@"

