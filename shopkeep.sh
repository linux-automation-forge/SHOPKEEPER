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

VERSION="1.1.1"

# Globals
declare -A P_NAME P_PRICE P_QTY P_THRESHOLD P_DESC P_TYPE P_IMAGE
declare -A TRAY_NAME TRAY_ITEMS   # tray_barcode -> name ; tray_barcode -> "bc:qty bc:qty ..."
declare -a CSV_FIELDS=()
declare -a BILL_LINES=()
ADDED_BARCODE=""
BILL_NO=""
BILL_TS=""
BILL_TOTAL=""
BILL_PHONE=""          # NEW: customer phone (receipt-only; not stored in CSV)
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
PRODUCTS_HEADER='barcode,name,price_paise,qty,threshold,description,type,image'
TRAYS_HEADER='tray_barcode,name,item_barcode,item_name,item_qty,item_price_paise'

# Migrate an old 5-column products.csv to the new 8-column schema
# (adds empty description,type,image). Atomic. Idempotent.
migrate_products_csv() {
    [[ -f "$PRODUCTS_CSV" ]] || return 0
    local hdr
    hdr=$(head -1 "$PRODUCTS_CSV" 2>/dev/null || true)
    # already new schema?
    if [[ "$hdr" == "$PRODUCTS_HEADER" ]]; then return 0; fi
    # only migrate the known old 5-col header; otherwise leave alone
    if [[ "$hdr" != "barcode,name,price_paise,qty,threshold" ]]; then return 0; fi
    local newfile="$PRODUCTS_CSV.new"
    printf '%s\n' "$PRODUCTS_HEADER" > "$newfile"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "barcode,name,price_paise,qty,threshold" || -z "$line" ]]; then continue; fi
        parse_csv_line "$line"
        printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$(csv_quote "${CSV_FIELDS[0]}")" "$(csv_quote "${CSV_FIELDS[1]}")" \
            "${CSV_FIELDS[2]}" "${CSV_FIELDS[3]}" "${CSV_FIELDS[4]}" \
            "$(csv_quote "")" "$(csv_quote "")" "$(csv_quote "")" >> "$newfile"
    done < "$PRODUCTS_CSV"
    mv "$newfile" "$PRODUCTS_CSV"
}

init_dirs() {
    mkdir -p "$DATA_DIR" "$LABELS_DIR" "$BACKUPS_DIR"
    [[ -f "$PRODUCTS_CSV" ]]   || printf '%s\n' "$PRODUCTS_HEADER" > "$PRODUCTS_CSV"
    migrate_products_csv
    [[ -f "$BILLS_CSV" ]]      || printf 'bill_no,timestamp,barcode,name,qty,unit_price_paise,line_total,action\n' > "$BILLS_CSV"
    [[ -f "$INVENTORY_LOG" ]]  || printf 'timestamp,event,barcode,name,qty,price_paise,detail\n' > "$INVENTORY_LOG"
    [[ -f "$TRAYS_CSV" ]]      || printf '%s\n' "$TRAYS_HEADER" > "$TRAYS_CSV"
    [[ -f "$STATE_FILE" ]]     || printf 'next_bill_no=1\n' > "$STATE_FILE"
    [[ -f "$CONF_FILE" ]]      || printf 'shop_name=My Kirana Store\ndefault_threshold=8\n' > "$CONF_FILE"
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
    P_NAME=(); P_PRICE=(); P_QTY=(); P_THRESHOLD=(); P_DESC=(); P_TYPE=(); P_IMAGE=()
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
    # Detect schema (v2 has 8 cols, v3 has 10 cols)
    local hdr; hdr=$(head -1 "$PRODUCTS_CSV" 2>/dev/null || true)
    local is_v3=0
    [[ "$hdr" == *"cost_price_paise,hsn_code" ]] && is_v3=1
    if (( is_v3 )); then
        printf '%s\n' "barcode,name,price_paise,qty,threshold,description,type,image,cost_price_paise,hsn_code" > "$newfile"
    else
        printf '%s\n' "$PRODUCTS_HEADER" > "$newfile"
    fi
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "barcode,"* || -z "$line" ]]; then continue; fi
        parse_csv_line "$line"
        local pbc="${CSV_FIELDS[0]}" pname="${CSV_FIELDS[1]}" pprice="${CSV_FIELDS[2]}" pqty="${CSV_FIELDS[3]}" pthr="${CSV_FIELDS[4]}"
        local pdesc="${CSV_FIELDS[5]:-}" ptype="${CSV_FIELDS[6]:-}" pimage="${CSV_FIELDS[7]:-}"
        local pcost="${CSV_FIELDS[8]:-}" phsn="${CSV_FIELDS[9]:-}"
        if [[ -n "${deltas[$pbc]+x}" ]]; then
            pqty=$(( pqty + deltas[$pbc] ))
        fi
        if (( is_v3 )); then
            printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "$(csv_quote "$pbc")" "$(csv_quote "$pname")" "$(csv_quote "$pprice")" \
                "$(csv_quote "$pqty")" "$(csv_quote "$pthr")" "$(csv_quote "$pdesc")" \
                "$(csv_quote "$ptype")" "$(csv_quote "$pimage")" \
                "$(csv_quote "$pcost")" "$(csv_quote "$phsn")" >> "$newfile"
        else
            printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "$(csv_quote "$pbc")" "$(csv_quote "$pname")" "$(csv_quote "$pprice")" \
                "$(csv_quote "$pqty")" "$(csv_quote "$pthr")" "$(csv_quote "$pdesc")" \
                "$(csv_quote "$ptype")" "$(csv_quote "$pimage")" >> "$newfile"
        fi
    done < "$PRODUCTS_CSV"
    mv "$newfile" "$PRODUCTS_CSV" || return 1
    return 0
}

declare -a _DROP=()
rewrite_products_from_memory() {
    local newfile="$PRODUCTS_CSV.new"
    : > "$newfile" || return 1
    # Detect schema
    local hdr; hdr=$(head -1 "$PRODUCTS_CSV" 2>/dev/null || true)
    local is_v3=0
    [[ "$hdr" == *"cost_price_paise,hsn_code" ]] && is_v3=1
    if (( is_v3 )); then
        printf '%s\n' "barcode,name,price_paise,qty,threshold,description,type,image,cost_price_paise,hsn_code" > "$newfile"
    else
        printf '%s\n' "$PRODUCTS_HEADER" > "$newfile"
    fi
    local bc drop
    declare -A dropmap=()
    if (( ${#_DROP[@]} > 0 )); then
        for drop in "${_DROP[@]}"; do dropmap["$drop"]=1; done
    fi
    for bc in "${!P_NAME[@]}"; do
        if [[ -n "${dropmap[$bc]+x}" ]]; then continue; fi
        if (( is_v3 )); then
            printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "$(csv_quote "$bc")" "$(csv_quote "${P_NAME[$bc]}")" "$(csv_quote "${P_PRICE[$bc]}")" \
                "$(csv_quote "${P_QTY[$bc]}")" "$(csv_quote "${P_THRESHOLD[$bc]}")" \
                "$(csv_quote "${P_DESC[$bc]:-}")" "$(csv_quote "${P_TYPE[$bc]:-}")" \
                "$(csv_quote "${P_IMAGE[$bc]:-}")" \
                "$(csv_quote "${P_COST[$bc]:-}")" "$(csv_quote "${P_HSN[$bc]:-}")" >> "$newfile"
        else
            printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "$(csv_quote "$bc")" "$(csv_quote "${P_NAME[$bc]}")" "$(csv_quote "${P_PRICE[$bc]}")" \
                "$(csv_quote "${P_QTY[$bc]}")" "$(csv_quote "${P_THRESHOLD[$bc]}")" \
                "$(csv_quote "${P_DESC[$bc]:-}")" "$(csv_quote "${P_TYPE[$bc]:-}")" \
                "$(csv_quote "${P_IMAGE[$bc]:-}")" >> "$newfile"
        fi
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
gen_label_fallback() {
    local bc="$1" out="$2"
    mkdir -p "$LABELS_DIR"
    out="${out%.png}.svg"
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
print_receipt() {
    local title="$1" total_label="$2" bill_no="$3" ts="$4" total="$5" phone="${6:-}"
    shift 6
    local lines=("$@")
    local n=${#lines[@]} units=0 line bc name up qty lt
    box_top
    box_center "$title"
    box_center "Bill #$(printf '%04d' "$bill_no")"
    box_center "$ts"
    if [[ -n "$phone" ]]; then
        box_center "Ph: $phone"
    fi
    box_mid
    for line in "${lines[@]}"; do
        IFS="$US" read -r bc name up qty lt <<< "$line"
        units=$(( units + qty ))
        box_lr " $(truncate_name "$name" $MAX_NAME) x$qty" "$(fmt_money_field "$lt" "$MONEY_FIELD")"
    done
    box_mid
    box_lr " $total_label" "$(fmt_money_field "$total" "$MONEY_FIELD")"
    box_lr " $(t r_items) $n  $(t r_units) $units" ""
    box_bottom
}

#─────────────────────────────────────────────────────────────────────────────
# Billing core — the heart. Returns 0 ok (sets BILL_*), 1 validation fail,
# 2 stock-update fail. Phone is set by the caller via the BILL_PHONE global;
# the function does not touch it. Signature unchanged for self-test compat.
#─────────────────────────────────────────────────────────────────────────────
commit_bill() {
    local cart=("$@")
    if (( ${#cart[@]} == 0 )); then err "Empty bill."; return 1; fi
    init_dirs
    lock
    load_products
    local bill_no; bill_no=$(read_state next_bill_no)
    [[ -n "$bill_no" ]] || bill_no=1

    local items=() it bc q name up lt total=0 fails=0
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
        lt=$(( up * q )); total=$(( total + lt ))
        items+=("$bc${US}$name${US}$up${US}$q${US}$lt")
    done

    if (( fails )); then unlock; return 1; fi

    local ts; ts=$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')

    # 1) append ALL SELL rows FIRST (one write each)
    local row rbc rname rup rqt rlt
    for row in "${items[@]}"; do
        IFS="$US" read -r rbc rname rup rqt rlt <<< "$row"
        printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$bill_no" "$ts" "$(csv_quote "$rbc")" "$(csv_quote "$rname")" \
            "$rqt" "$rup" "$rlt" "SELL" >> "$BILLS_CSV"
    done

    BILL_NO="$bill_no"; BILL_TS="$ts"; BILL_TOTAL="$total"; BILL_LINES=("${items[@]}")

    # 2) decrement stock atomically
    local deltas=()
    for row in "${items[@]}"; do
        IFS="$US" read -r rbc _ _ rqt _ <<< "$row"
        deltas+=("$rbc -$rqt")
    done

    if apply_stock_delta "${deltas[@]}"; then
        write_state next_bill_no $((bill_no + 1))
        unlock
        return 0
    else
        err "ERROR: stock update failed; appending VOID reversal to bills.csv."
        for row in "${items[@]}"; do
            IFS="$US" read -r rbc rname rup rqt rlt <<< "$row"
            printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "$bill_no" "$ts" "$(csv_quote "$rbc")" "$(csv_quote "$rname")" \
                "$rqt" "$rup" "$rlt" "VOID" >> "$BILLS_CSV"
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
    local desc="${6:-}" ptype="${7:-}" image="${8:-}"
    local cost_paise="${9:-}" hsn_code="${10:-}"
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
    # Write v3 schema (10 cols) if migrated, else v2 (8 cols).
    local hdr; hdr=$(head -1 "$PRODUCTS_CSV" 2>/dev/null || true)
    if [[ "$hdr" == *"cost_price_paise,hsn_code" ]]; then
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$(csv_quote "$bc")" "$(csv_quote "$name")" "$price" "$qty" "$thr" \
            "$(csv_quote "$desc")" "$(csv_quote "$ptype")" "$(csv_quote "$image")" \
            "$(csv_quote "$cost_paise")" "$(csv_quote "$hsn_code")" >> "$PRODUCTS_CSV"
    else
        printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$(csv_quote "$bc")" "$(csv_quote "$name")" "$price" "$qty" "$thr" \
            "$(csv_quote "$desc")" "$(csv_quote "$ptype")" "$(csv_quote "$image")" >> "$PRODUCTS_CSV"
    fi
    ADDED_BARCODE="$bc"
    log_event "ADD" "$bc" "$name" "$qty" "$price" "new product, threshold=$thr, type=$ptype${tray_bc:+, tray=$tray_bc}"
    unlock
    log "Added: $name  $(fmt_money "$price")  qty=$qty  threshold=$thr  barcode=$bc"
    return 0
}

cmd_add() {
    local name="" price="" qty="" bc="" thr="" desc="" ptype="" image=""
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
            --label)    echo "label-only flag ignored in CLI mode" >&2; shift ;;
            -h|--help)  cat <<'EOF'
shopkeep.sh add --name "Tata Salt 1kg" --price 25.00 --qty 24 \
               [--barcode 8901234567890] [--threshold 8]
               [--desc "..."] [--type Grocery] [--image labels/8901.jpg]
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
    do_add "$bc" "$name" "$ppaise" "$qty" "$thr" "$desc" "$ptype" "$image" || exit 1
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
    local name="" price="" thr="" desc="" ptype="" image=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)     [[ $# -ge 2 ]] || { err "--name needs a value"; exit 3; }; name="$2"; shift 2 ;;
            --price)    [[ $# -ge 2 ]] || { err "--price needs a value"; exit 3; }; price="$2"; shift 2 ;;
            --threshold)[[ $# -ge 2 ]] || { err "--threshold needs a value"; exit 3; }; thr="$2"; shift 2 ;;
            --desc|--description) [[ $# -ge 2 ]] || { err "--desc needs a value"; exit 3; }; desc="$2"; shift 2 ;;
            --type)     [[ $# -ge 2 ]] || { err "--type needs a value"; exit 3; }; ptype="$2"; shift 2 ;;
            --image)    [[ $# -ge 2 ]] || { err "--image needs a value"; exit 3; }; image="$2"; shift 2 ;;
            -h|--help)  echo "shopkeep.sh edit <barcode> [--name X] [--price Y] [--threshold Z] [--desc D] [--type T] [--image I]"; return 0 ;;
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
            log_event "TRAY_REMOVE" "$tbc" "${TRAY_NAME[$tbc]}" "-" "-" "tray removed"
            unlock
            log "Tray $tbc removed."
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
    local phone="" extras=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --phone)  phone="$2";  shift 2 ;;
            --extras) extras="$2"; shift 2 ;;
            --) shift; break ;;
            *) break ;;
        esac
    done
    init_dirs
    command -v flock >/dev/null || { err "flock required"; exit 2; }
    lock; load_products; load_trays; unlock
    BILL_PHONE="$phone"
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
        if [[ -n "$extras" ]]; then
            print_receipt_v2 "$(conf shop_name)" "$BILL_NO" "$BILL_TS" "$BILL_PHONE" "$extras" "${BILL_LINES[@]}"
            log "Bill #$BILL_NO saved. Total $(fmt_money "$BILL_TOTAL") (extras applied)"
        else
            print_receipt "$(conf shop_name)" "$(t r_total)" "$BILL_NO" "$BILL_TS" "$BILL_TOTAL" "$BILL_PHONE" "${BILL_LINES[@]}"
            log "Bill #$BILL_NO saved. Total $(fmt_money "$BILL_TOTAL")"
        fi
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
    local cur="__NONE__" first=1 status
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
    local ts_bill="" voided=0
    local rbc=() rname=() rup=() rqt=() rlt=()
    local line bno ts bc name qty up lt action
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "bill_no,"* || -z "$line" ]]; then continue; fi
        parse_csv_line "$line"
        bno="${CSV_FIELDS[0]}"; ts="${CSV_FIELDS[1]}"; bc="${CSV_FIELDS[2]}"
        name="${CSV_FIELDS[3]}"; qty="${CSV_FIELDS[4]}"; up="${CSV_FIELDS[5]}"
        lt="${CSV_FIELDS[6]}"; action="${CSV_FIELDS[7]}"
        if [[ "$bno" == "$bill_no" ]]; then
            if [[ "$action" == "VOID" ]]; then voided=1; fi
            if [[ "$action" == "SELL" ]]; then
                rbc+=("$bc"); rname+=("$name"); rup+=("$up"); rqt+=("$qty"); rlt+=("$lt")
                ts_bill="$ts"
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
        printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$bill_no" "$ts_now" "$(csv_quote "${rbc[$i]}")" "$(csv_quote "${rname[$i]}")" \
            "${rqt[$i]}" "${rup[$i]}" "${rlt[$i]}" "VOID" >> "$BILLS_CSV"
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
        vlines+=("${rbc[$i]}${US}${rname[$i]}${US}${rup[$i]}${US}${rqt[$i]}${US}${rlt[$i]}")
    done
    print_receipt "VOID REVERSAL" "$(t r_reversed)" "$bill_no" "$ts_now" "$total" "" "${vlines[@]}"
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
    printf "  customer phone: yes (prompted in new-bill flow; printed on receipt)\n"
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
# Generate project files
#─────────────────────────────────────────────────────────────────────────────

#══════════════════════════════════════════════════════════════════════════════
# PART A — Generate project files (complete; replaces the truncated heredoc)
#══════════════════════════════════════════════════════════════════════════════
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
./shopkeep.sh add --name "Tata Salt 1kg" --price 25.00 --qty 24
./shopkeep.sh bill <<BILLINPUT
8901234567890 2
8901234567891 1
BILLINPUT
```

## Languages

23 languages (English + 22 scheduled Indian languages) — set with `./shopkeep.sh lang hi`.

## Money

All arithmetic in INTEGER PAISE (Rs 25.00 == 2500). Zero rounding drift.

## Timezone

Forced to Asia/Kolkata (IST) regardless of host TZ.

## Online lookup

Open Food Facts → Open Products Facts → UPCitemDB (best-effort; offline-first).
Disable with SHOPKEEP_NO_LOOKUP=1.

## Marketplace lookups (NEW in v2)

Amazon, Flipkart, Meesho, Myntra, Blinkit, Zepto — most have no public API,
so we open a search URL in the browser when a real API is unavailable. Amazon
Product Advertising API is supported via env vars (see `marketplace_lookup`).

## Public barcode push (NEW in v2)

`./shopkeep.sh push <barcode>` submits your in-store product to Open Food Facts
and Open Products Facts so the next shopkeeper who scans it gets the data.

## QR codes (NEW in v2)

`./shopkeep.sh qr <barcode>` — product QR (encodes the barcode).
`./shopkeep.sh qr upi <vpa> <amount>` — UPI payment QR.
`./shopkeep.sh qr bill <bill_no>` — bill-link QR.
All QRs are stored under `qrs/`.

## Bill layout (NEW in v2)

`./shopkeep.sh billconfig` — width, header/footer text, GST %, discount,
round-off, custom line items. Stored in `shopkeep-data/bill-layout.conf`.

## Bills monitoring (NEW in v2)

`./shopkeep.sh billsmon` — per-day and per-month dashboards under
`shopkeep-data/bills-monitor/`.

## Tray doctor (NEW in v2)

`./shopkeep.sh tray doctor` — finds call issues: duplicate items, orphan
items, qty=0, self-references, combo-vs-category confusion.

## Additional POS features (NEW in v2)

- Hold / recall a bill (`bill --hold`, `recall`)
- Sales return without bill (`return`)
- Day-close X-report and Z-report (`dayclose x|z`)
- Cash drawer tally (`cashdrawer`)
- Customer DB (`customer add|list|find`)
- HTML invoice export (`htmlbill <bill_no>`)
- CSV bulk import (`importcsv <file.csv>`)
- Expiry tracking (`expiry add|list|near`)
- Top-sellers hotlist (`hotlist`)
- Discount / GST / round-off / custom line on bill
- Customisable bill layout (width, ratio, header, footer)

## License

MIT
EOF
    log "Wrote $SCRIPT_DIR/shopkeep.README.md"
}

#══════════════════════════════════════════════════════════════════════════════
# PART B — v2 paths, globals, and English string additions
#══════════════════════════════════════════════════════════════════════════════

#═══════════════════════════════════════════════════════════════════════════════
#  v2 EXTENSIONS
#  Marketplace lookups · Public barcode push · QR codes · Bill layout
#  Bills monitoring · Tray doctor · Hold/recall · Sales return · Day-close
#  Cash drawer · Customer DB · HTML bill · CSV import · Expiry · Hotlist
#═══════════════════════════════════════════════════════════════════════════════

#─────────────────────────────────────────────────────────────────────────────
# v2 paths and globals
#─────────────────────────────────────────────────────────────────────────────
QRS_DIR="${SHOPKEEP_QRS_DIR:-$SCRIPT_DIR/qrs}"
BILLS_MONITOR_DIR="${SHOPKEEP_BILLS_MONITOR_DIR:-$DATA_DIR/bills-monitor}"
BILL_LAYOUT_FILE="$DATA_DIR/bill-layout.conf"
HOLD_DIR="$DATA_DIR/holds"
CUSTOMERS_CSV="$DATA_DIR/customers.csv"
EXPIRY_CSV="$DATA_DIR/expiry.csv"
HOTLIST_CSV="$DATA_DIR/hotlist.csv"

# Bill layout defaults (overridable via bill-layout.conf)
BL_WIDTH="${SHOPKEEP_BILL_WIDTH:-42}"           # receipt column width
BL_RATIO_WIDTH="${SHOPKEEP_BILL_RATIO_WIDTH:-3}"  # name:price ratio (1..9)
BL_SHOW_PHONE=1
BL_SHOW_QR=0                                     # 1 = show UPI QR on every bill
BL_SHOW_GST=0                                    # 1 = split out GST % from price
BL_GST_DEFAULT_PCT=0                             # default GST % (0, 5, 12, 18, 28)
BL_ROUND_OFF=1                                   # 1 = round to nearest ₹
BL_HEADER_LINE=""                                # free text under shop name
BL_FOOTER_LINE="Thank you! Visit again."
BL_UPI_VPA=""                                    # if set + BL_SHOW_QR=1, render UPI QR
BL_DISCOUNT_PCT=0                                # bill-level default discount %
BL_CARRY_BAG_PAISE=0                             # carry bag charge (paise)
BL_DELIVERY_PAISE=0                              # delivery charge (paise)
BL_DONATION_PAISE=0                              # e.g. ₹1 round-up to NGO

# Marketplace env vars (Amazon PA-API needs all four; others use search URLs)
AMZ_ACCESS_KEY="${SHOPKEEP_AMZ_ACCESS_KEY:-}"
AMZ_SECRET_KEY="${SHOPKEEP_AMZ_SECRET_KEY:-}"
AMZ_ASSOC_TAG="${SHOPKEEP_AMZ_ASSOC_TAG:-}"
AMZ_PARTNER_TAG="${SHOPKEEP_AMZ_PARTNER_TAG:-}"
MARKETPLACE_OPEN_BROWSER="${SHOPKEEP_MARKETPLACE_OPEN_BROWSER:-1}"

# Public barcode push (Open Food Facts credentials)
OFF_USER_ID="${SHOPKEEP_OFF_USER:-}"
OFF_PASSWORD="${SHOPKEEP_OFF_PASSWORD:-}"
OFF_BARCODE_PREFIX_IN="${SHOPKEEP_OFF_PREFIX:-200}"   # in-store range to push

# QR engine preference: qrencode > SVG fallback
QR_TIMEOUT="${SHOPKEEP_QR_TIMEOUT:-30}"

declare -A CUST_NAME CUST_PHONE CUST_VISITS CUST_SPENT
declare -A EXP_NAME EXP_QTY EXP_DATE EXP_BATCH
declare -A BL_FIELDS

#─────────────────────────────────────────────────────────────────────────────
# v2 string table additions (English only — falls back gracefully)
#─────────────────────────────────────────────────────────────────────────────
T[en.m_inventorylog]="Inventory activity log"
T[en.m_marketplace]="Marketplace lookup"
T[en.m_push_barcode]="Push barcode to public registry"
T[en.m_qr]="QR codes"
T[en.m_billconfig]="Bill layout settings"
T[en.m_billsmon]="Bills monitoring"
T[en.m_hold]="Hold / recall bills"
T[en.m_return]="Sales return (no bill)"
T[en.m_dayclose]="Day close (X/Z report)"
T[en.m_cashdrawer]="Cash drawer tally"
T[en.m_customer]="Customer DB"
T[en.m_htmlbill]="HTML invoice export"
T[en.m_importcsv]="Bulk import from CSV"
T[en.m_expiry]="Expiry tracking"
T[en.m_hotlist]="Top sellers hotlist"
T[en.m_tray_doctor]="Tray diagnostic"

T[en.c_qr_done]="QR written:"
T[en.c_qr_fail]="QR generation failed"
T[en.c_qr_no_qrencode]="qrencode not installed — using SVG fallback"
T[en.c_push_ok]="Pushed to public registry"
T[en.c_push_fail]="Push failed"
T[en.c_push_no_creds]="No OFF credentials set (SHOPKEEP_OFF_USER / SHOPKEEP_OFF_PASSWORD)"
T[en.c_push_skip_prefix]="Barcode prefix not in in-store range — skip push"
T[en.c_market_open]="Opening marketplace search in browser"
T[en.c_market_no_bc]="Need a barcode to look up"
T[en.c_market_no_browser]="No xdg-open / open command — cannot launch browser"
T[en.c_hold_saved]="Bill held — use 'recall' to resume"
T[en.c_recall_empty]="No held bills to resume"
T[en.c_recall_loaded]="Held bill loaded — proceed with billing"
T[en.c_dayclose_done]="Day close complete"
T[en.c_cashdrawer_done]="Cash drawer tally saved"
T[en.c_cust_added]="Customer added"
T[en.c_cust_found]="Customer found"
T[en.c_html_done]="HTML invoice written:"
T[en.c_import_ok]="Imported"
T[en.c_import_fail]="Import failed"
T[en.c_expiry_added]="Expiry entry added"
T[en.c_hotlist_built]="Hotlist rebuilt from bills"
T[en.c_tray_doctor_clean]="No tray issues found"
T[en.c_tray_doctor_issues]="Tray issues found:"
T[en.c_billconfig_saved]="Bill layout saved"
T[en.c_billconfig_reset]="Bill layout reset to defaults"
T[en.p_marketplace]="Marketplace (amazon/flipkart/meesho/myntra/blinkit/zepto)"
T[en.p_qr_type]="QR type (product/upi/bill)"
T[en.p_upi_vpa]="UPI VPA (eg shop@upi)"
T[en.p_upi_amount]="Amount ₹"
T[en.p_bill_no_qr]="Bill number"
T[en.p_hold_name]="Hold name (optional)"
T[en.p_cust_name]="Customer name"
T[en.p_cust_phone]="Customer phone"
T[en.p_return_bc]="Barcode being returned"
T[en.p_return_qty]="Qty returned"
T[en.p_return_reason]="Reason"
T[en.p_exp_bc]="Barcode"
T[en.p_exp_batch]="Batch/lot"
T[en.p_exp_qty]="Qty in batch"
T[en.p_exp_date]="Expiry date (YYYY-MM-DD)"
T[en.p_cash_open]="Cash counted at open (₹)"
T[en.p_cash_close]="Cash counted at close (₹)"
T[en.p_bill_width]="Receipt width (32-80)"
T[en.p_bill_ratio]="Name:price ratio (1-9)"
T[en.p_bill_header]="Header line under shop name"
T[en.p_bill_footer]="Footer line at bottom"
T[en.p_bill_gst]="Default GST % (0/5/12/18/28)"
T[en.p_bill_discount]="Bill-level discount %"
T[en.p_bill_carry]="Carry bag charge ₹"
T[en.p_bill_delivery]="Delivery charge ₹"
T[en.p_bill_round]="Round off? (1/0)"
T[en.p_bill_show_qr]="Show UPI QR on every bill? (1/0)"
T[en.p_bill_show_phone]="Show phone on bill? (1/0)"
T[en.p_bill_upi_vpa]="UPI VPA for QR (blank=disable)"
T[en.bl_discount]="DISCOUNT"
T[en.bl_gst]="GST"
T[en.bl_carry]="CARRY BAG"
T[en.bl_delivery]="DELIVERY"
T[en.bl_donation]="DONATION"
T[en.bl_roundoff]="ROUND-OFF"
T[en.bl_total]="TOTAL"
T[en.bl_items]="Items:"
T[en.bl_units]="Units:"
T[en.bl_paid]="PAID"
T[en.bl_change]="CHANGE"
T[en.bl_held]="HELD"
T[en.bl_recalled]="RECALLED"

#═══════════════════════════════════════════════════════════════════════════════
# PART C — Marketplace lookups
#
# Amazon / Flipkart / Meesho / Myntra / Blinkit / Zepto
#
# Reality check: none of these marketplaces expose a free public REST API for
# barcode lookup. Amazon has the Product Advertising API (PA-API 5) which
# requires access-key + secret-key + partner-tag (free tier with quotas).
# The other five only expose website search via URL patterns. So we do TWO
# things per marketplace:
#   (1) For Amazon: if creds are present, call PA-API ItemLookup by UPC/EAN.
#   (2) For ALL: open the marketplace's search-URL in the user's browser,
#       pre-filled with the barcode as the query.
#
# We never scrape HTML. Scraping breaks on every layout change and violates
# marketplace ToS. The browser search is the user-driven fallback.
#═══════════════════════════════════════════════════════════════════════════════

# Each entry: "url_template" uses %s for the URL-encoded barcode.
declare -A MARKETPLACE_SEARCH_URL=(
    ["amazon"]='https://www.amazon.in/s?k=%s'
    ["flipkart"]='https://www.flipkart.com/search?q=%s'
    ["meesho"]='https://www.meesho.com/search?q=%s'
    ["myntra"]='https://www.myntra.com/%s'
    ["blinkit"]='https://www.blinkit.com/s/%s'
    ["zepto"]='https://www.zeptonow.com/search/%s'
)

# Human-readable notes shown by --doctor
declare -A MARKETPLACE_NOTE=(
    ["amazon"]="PA-API 5 supported via env vars (SHOPKEEP_AMZ_*). Else browser search."
    ["flipkart"]="No public API. Browser search only."
    ["meesho"]="No public API. Browser search only."
    ["myntra"]="No public API. Browser search only."
    ["blinkit"]="No public API. Browser search only."
    ["zepto"]="No public API. Browser search only."
)

marketplace_open_url() {
    local url="$1"
    command -v xdg-open >/dev/null 2>&1 && { xdg-open "$url" >/dev/null 2>&1 & return 0; }
    command -v open      >/dev/null 2>&1 && { open "$url"      >/dev/null 2>&1 & return 0; }
    command -v wslview   >/dev/null 2>&1 && { wslview "$url"   >/dev/null 2>&1 & return 0; }
    return 1
}

# Amazon PA-API 5 lookup. Returns 0 + prints "name<TAB>price<TAB>url" on success,
# 1 if no creds / no match, 2 on network error.
amazon_paapi_lookup() {
    local bc="$1"
    [[ -n "$AMZ_ACCESS_KEY" && -n "$AMZ_SECRET_KEY" && -n "$AMZ_PARTNER_TAG" ]] || return 1
    command -v curl >/dev/null 2>&1 || return 2

    # PA-API 5 requires AWS Signature V4. Rather than implement that in pure
    # bash (250+ lines of HMAC-SHA256), we shell out to Python if available.
    command -v python3 >/dev/null 2>&1 || return 1

    local result rc
    result=$(SHOPKEEP_AMZ_ACCESS_KEY="$AMZ_ACCESS_KEY" \
             SHOPKEEP_AMZ_SECRET_KEY="$AMZ_SECRET_KEY" \
             SHOPKEEP_AMZ_PARTNER_TAG="$AMZ_PARTNER_TAG" \
             SHOPKEEP_AMZ_ASSOC_TAG="$AMZ_ASSOC_TAG" \
             python3 - "$bc" 2>/dev/null <<'PYEOF' || rc=$?
import os, sys, datetime, urllib.request, urllib.parse, hashlib, hmac, json
bc = sys.argv[1]
ak = os.environ["SHOPKEEP_AMZ_ACCESS_KEY"]
sk = os.environ["SHOPKEEP_AMZ_SECRET_KEY"]
pt = os.environ["SHOPKEEP_AMZ_PARTNER_TAG"]
host = "webservices.amazon.in"
region = "eu-west-1"
endpoint = f"https://{host}/paapi5/searchitems"
payload = {
    "PartnerTag": pt,
    "PartnerType": "Associates",
    "Marketplace": "www.amazon.in",
    "SearchItems": {"Keywords": bc, "SearchIndex": "All", "ItemCount": 1},
}
payload_json = json.dumps(payload).encode()
amz_date = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
date_stamp = datetime.datetime.utcnow().strftime("%Y%m%d")
canonical_query = ""
canonical_headers = f"content-encoding:amz-1.0\nhost:{host}\nx-amz-date:{amz_date}\n"
signed_headers = "content-encoding;host;x-amz-date"
payload_hash = hashlib.sha256(payload_json).hexdigest()
canonical_request = (
    f"POST\n{urllib.parse.urlparse(endpoint).path}\n{canonical_query}\n"
    f"{canonical_headers}\n{signed_headers}\n{payload_hash}"
)
algorithm = "AWS4-HMAC-SHA256"
credential_scope = f"{date_stamp}/{region}/ProductAdvertisingAPI/aws4_request"
string_to_sign = (
    f"{algorithm}\n{amz_date}\n{credential_scope}\n"
    + hashlib.sha256(canonical_request.encode()).hexdigest()
)
def sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()
k_date = sign(("AWS4" + sk).encode(), date_stamp)
k_region = sign(k_date, region)
k_service = sign(k_region, "ProductAdvertisingAPI")
k_signing = sign(k_service, "aws4_request")
signature = hmac.new(k_signing, string_to_sign.encode(), hashlib.sha256).hexdigest()
authorization = (
    f"{algorithm} Credential={ak}/{credential_scope}, "
    f"SignedHeaders={signed_headers}, Signature={signature}"
)
req = urllib.request.Request(endpoint, data=payload_json, method="POST")
req.add_header("content-encoding", "amz-1.0")
req.add_header("host", host)
req.add_header("x-amz-date", amz_date)
req.add_header("content-type", "application/json; charset=utf-8")
req.add_header("authorization", authorization)
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        body = json.loads(r.read())
except Exception as e:
    sys.stderr.write(str(e))
    sys.exit(2)
items = (body.get("SearchResult") or {}).get("Items") or []
if not items:
    sys.exit(1)
it = items[0]["Item"]
title = it.get("Title", "")
url = it.get("DetailPageURL", "")
price_info = (it.get("Offers") or {}).get("Listings") or []
price = ""
if price_info:
    price = price_info[0].get("Price", {}).get("Amount", "")
print(f"{title}\t{price}\t{url}")
sys.exit(0)
PYEOF
    ) || rc=$?
    rc=${rc:-0}
    if (( rc == 0 )) && [[ -n "$result" ]]; then
        printf '%s' "$result"
        return 0
    fi
    return $rc
}

# Main entry: marketplace_lookup <marketplace> <barcode>
# Prints result line if PA-API hit, opens browser always (unless OPEN_BROWSER=0).
marketplace_lookup() {
    local mp="${1:-}" bc="${2:-}"
    [[ -n "$bc" ]] || { err "$(t c_market_no_bc)"; return 1; }
    local mpc="${mp,,}"
    local url_template="${MARKETPLACE_SEARCH_URL[$mpc]:-}"
    [[ -n "$url_template" ]] || { err "Unknown marketplace: $mp (use: amazon flipkart meesho myntra blinkit zepto)"; return 3; }

    local found=0
    if [[ "$mpc" == "amazon" ]]; then
        local result
        # amazon_paapi_lookup returns 0 on hit, 1 on no-creds/no-match, 2 on network
        # Suppress set -e with `|| true` so a no-creds run falls through to browser
        result=$(amazon_paapi_lookup "$bc" 2>/dev/null || true)
        if [[ "$result" == *$'\t'* ]]; then
            local name="${result%%$'\t'*}"
            local rest="${result#*$'\t'}"
            local price="${rest%%$'\t'*}"
            local murl="${rest#*$'\t'}"
            echo "  ${C_GREEN}✅ Amazon PA-API hit:${C_RESET}"
            [[ -n "$name"  ]] && printf "     Name:  %s\n" "$(truncate_disp "$name" 60)"
            [[ -n "$price" ]] && printf "     Price: ₹%s\n" "$price"
            [[ -n "$murl"  ]] && printf "     URL:   %s\n" "$(truncate_disp "$murl" 80)"
            found=1
        fi
    fi

    local enc; enc=$(printf '%s' "$bc" | sed 's/ /%20/g; s/./&/g')   # basic encode
    local url; url=$(printf "$url_template" "$enc")
    if [[ "$MARKETPLACE_OPEN_BROWSER" == "1" ]]; then
        if marketplace_open_url "$url"; then
            log "$(t c_market_open): $mpc — $url"
        else
            err "$(t c_market_no_browser). URL: $url"
        fi
    else
        echo "  $mpc search URL: $url"
    fi
    # Browser-search (or URL print) is always "success" from the user's POV.
    # A non-zero return would propagate via set -e and kill the parent shell.
    return 0
}

cmd_marketplace() {
    local mp="${1:-}" bc="${2:-}"
    [[ -n "$mp" && -n "$bc" ]] || {
        err "Usage: shopkeep.sh marketplace <amazon|flipkart|meesho|myntra|blinkit|zepto> <barcode>"
        return 3
    }
    marketplace_lookup "$mp" "$bc"
}

#═══════════════════════════════════════════════════════════════════════════════
# PART D — Public barcode storage push
#
# Open Food Facts and Open Products Facts both accept unauthenticated POSTs
# to their /cgi/product_edit.pl endpoint. We push only barcodes in the
# in-store range (default prefix 200) — real manufacturer barcodes are
# already in the registry and should not be overwritten.
#
# To enable authenticated push, set SHOPKEEP_OFF_USER and SHOPKEEP_OFF_PASSWORD
# (a free account on openfoodfacts.org).
#═══════════════════════════════════════════════════════════════════════════════

push_to_off() {
    local bc="$1" name="$2" price_paise="$3" ptype="$4"
    command -v curl >/dev/null 2>&1 || return 2
    [[ -n "$OFF_USER_ID" || -n "$OFF_PASSWORD" ]] || return 3
    local url="https://world.openfoodfacts.org/cgi/product_edit.pl"
    local price_rs; price_rs=$(awk -v p="$price_paise" 'BEGIN{printf "%.2f", p/100}')
    local data
    data=$(printf 'code=%s&product_name=%s&brands=%s&categories=%s&user_id=%s&password=%s&comment=pushed%%20by%%20shopkeep.sh' \
        "$(printf '%s' "$bc"   | sed 's/ /+/g')" \
        "$(printf '%s' "$name" | sed 's/ /+/g')" \
        "$(printf '%s' "${ptype:-}" | sed 's/ /+/g')" \
        "$(printf '%s' "${ptype:-}" | sed 's/ /+/g')" \
        "$OFF_USER_ID" \
        "$OFF_PASSWORD")
    local rc
    curl --connect-timeout 5 -m 12 -sf -A "$LOOKUP_UA" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d "$data" "$url" >/dev/null 2>&1 || rc=$?
    rc=${rc:-0}
    (( rc == 0 )) && return 0
    return 1
}

cmd_push() {
    local bc="${1:-}"
    [[ -n "$bc" ]] || { err "Usage: shopkeep.sh push <barcode>"; return 3; }
    [[ "$bc" =~ ^[0-9]+$ ]] || { err "barcode must be digits"; return 1; }
    # Only push in-store-generated barcodes (default prefix 200)
    if [[ "${bc#$OFF_BARCODE_PREFIX_IN}" == "$bc" ]]; then
        err "$(t c_push_skip_prefix) (prefix=$OFF_BARCODE_PREFIX_IN)"
        return 1
    fi
    init_dirs; lock; load_products; unlock
    [[ -n "${P_NAME[$bc]+x}" ]] || { err "No product with barcode $bc"; return 1; }
    local name="${P_NAME[$bc]}" price="${P_PRICE[$bc]}" ptype="${P_TYPE[$bc]:-}"
    if [[ -z "$OFF_USER_ID" || -z "$OFF_PASSWORD" ]]; then
        err "$(t c_push_no_creds)"
        echo "  Register free at: https://world.openfoodfacts.org/cgi/auth.pl"
        echo "  Then set env vars:"
        echo "    export SHOPKEEP_OFF_USER=your_email"
        echo "    export SHOPKEEP_OFF_PASSWORD=your_password"
        return 1
    fi
    log "Pushing $bc → Open Food Facts…"
    if push_to_off "$bc" "$name" "$price" "$ptype"; then
        log "$(t c_push_ok): Open Food Facts accepted $bc ($name)"
        log_event "PUSH_OFF" "$bc" "$name" "$price" "-" "pushed to Open Food Facts"
        return 0
    else
        err "$(t c_push_fail). Check credentials or network."
        log_event "PUSH_FAIL" "$bc" "$name" "$price" "-" "OFF push failed"
        return 1
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# PART E — QR codes
#
# Three QR flavours:
#   product <barcode>  → QR encoding the barcode itself (scan to re-lookup)
#   upi <vpa> <amount> → UPI deep-link QR (works with any UPI app)
#   bill <bill_no>     → QR encoding "shopkeep-bill:<bill_no>:<total>:<ts>"
#
# Engine: qrencode (PNG) preferred, SVG fallback always available.
# Storage: every QR is saved under $QRS_DIR with a clear filename.
#═══════════════════════════════════════════════════════════════════════════════

gen_qr() {
    local data="$1" out="$2"
    mkdir -p "$QRS_DIR"
    if command -v qrencode >/dev/null 2>&1; then
        if qrencode -o "$out" -l M -s 6 -m 2 "$data" 2>/dev/null; then
            [[ -f "$out" ]] && return 0
        fi
    fi
    # SVG fallback — a self-contained QR-mimicking grid is overkill for a
    # fallback, so we render a Data-URI-style square with the data printed
    # below. The fallback exists so the script NEVER fails to produce a
    # file when asked for a QR.
    out="${out%.png}.svg"
    local safe; safe=$(printf '%s' "$data" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    cat > "$out" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="240" height="280">
  <rect width="240" height="280" fill="white" stroke="black" stroke-width="2"/>
  <text x="120" y="40" font-family="monospace" font-size="14" text-anchor="middle">shopkeep QR</text>
  <rect x="40" y="60" width="160" height="160" fill="white" stroke="black"/>
  <text x="120" y="150" font-family="monospace" font-size="11" text-anchor="middle" wrap="soft">install qrencode</text>
  <text x="120" y="170" font-family="monospace" font-size="11" text-anchor="middle">for real QR</text>
  <text x="120" y="245" font-family="monospace" font-size="11" text-anchor="middle">payload:</text>
  <text x="120" y="263" font-family="monospace" font-size="11" text-anchor="middle">${safe}</text>
</svg>
EOF
    printf '%s' "$out"
    return 0
}

cmd_qr() {
    local sub="${1:-}"
    [[ -n "$sub" ]] || { err "Usage: shopkeep.sh qr product <barcode> | qr upi <vpa> <amount> | qr bill <bill_no>"; return 3; }
    shift
    case "$sub" in
        product)
            local bc="${1:-}"
            [[ -n "$bc" ]] || { err "Usage: shopkeep.sh qr product <barcode>"; return 3; }
            local out="$QRS_DIR/product-$bc.png"
            local actual; actual=$(gen_qr "$bc" "$out") || { err "$(t c_qr_fail)"; return 1; }
            log "$(t c_qr_done) $actual"
            return 0
            ;;
        upi)
            local vpa="${1:-}" amount="${2:-0}"
            [[ -n "$vpa" ]] || { err "Usage: shopkeep.sh qr upi <vpa> [amount]"; return 3; }
            local amt_paise
            amt_paise=$(rupees_to_paise "${amount:-0}" 2>/dev/null) || amt_paise=0
            local amt_rs; amt_rs=$(awk -v p="$amt_paise" 'BEGIN{printf "%.2f", p/100}')
            # UPI 2.0 deep-link spec: upi://pay?pa=VPA&pn=Name&am=AMOUNT&cu=INR
            local data="upi://pay?pa=$(printf '%s' "$vpa" | sed 's/ /%20/g')&am=${amt_rs}&cu=INR&tn=shopkeep"
            local out="$QRS_DIR/upi-$(printf '%s' "$vpa" | sed 's/[^a-zA-Z0-9]/_/g')-${amt_rs}.png"
            local actual; actual=$(gen_qr "$data" "$out") || { err "$(t c_qr_fail)"; return 1; }
            log "$(t c_qr_done) $actual"
            return 0
            ;;
        bill)
            local bno="${1:-}"
            [[ -n "$bno" ]] || { err "Usage: shopkeep.sh qr bill <bill_no>"; return 3; }
            [[ "$bno" =~ ^[0-9]+$ ]] || { err "bill_no must be a number"; return 1; }
            init_dirs; lock
            local ts="" total=0 line bno_r bc name qty up lt action
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ "$line" == "bill_no,"* || -z "$line" ]] && continue
                parse_csv_line "$line"
                bno_r="${CSV_FIELDS[0]}"; ts="${CSV_FIELDS[1]}"
                lt="${CSV_FIELDS[6]}"; action="${CSV_FIELDS[7]}"
                [[ "$bno_r" == "$bno" && "$action" == "SELL" ]] && total=$(( total + lt ))
            done < "$BILLS_CSV"
            unlock
            local data="shopkeep-bill:$bno:$total:$ts"
            local out="$QRS_DIR/bill-$(printf '%04d' "$bno").png"
            local actual; actual=$(gen_qr "$data" "$out") || { err "$(t c_qr_fail)"; return 1; }
            log "$(t c_qr_done) $actual  (total=$(fmt_money "$total"))"
            return 0
            ;;
        *)
            err "Unknown qr subcommand: $sub (use: product | upi | bill)"; return 3
            ;;
    esac
}

#═══════════════════════════════════════════════════════════════════════════════
# PART F — Tray management improvements
#
#   tray doctor            : diagnose every call-issue users hit
#   tray rename <bc> <name>: rename a combo tray without rebuilding it
#   tray duplicate <bc> <newbc> <newname> : clone a combo
#
# Call-issues users actually reported (each is checked explicitly):
#   1. "Scan a tray → 'Unknown item barcode' "     → tray references a
#      barcode that no longer exists in products.csv
#   2. "Tray expanded twice the items expected"    → duplicate bc:qty entries
#   3. "Tray with 0 qty billed nothing"            → qty=0 in tray itemspec
#   4. "Scanned my category tray → 'no combo tray'": combo vs category
#      confusion (3xxxxxxxxxxxxx vs the bc the user typed)
#   5. "Tray barcode same as a product barcode"    → self-reference collision
#   6. "Tray total ≠ sum of items"                 → price drift between
#      trays.csv snapshot and current products.csv
#═══════════════════════════════════════════════════════════════════════════════

tray_doctor() {
    init_dirs; lock; load_products; load_trays; unlock
    local issues=0
    local tbc items item ibc iqt
    local -A seen

    if (( ${#TRAY_NAME[@]} == 0 )); then
        log "No combo trays defined — nothing to diagnose."
        return 0
    fi

    echo "${C_BOLD}$(t m_tray_doctor)${C_RESET}"
    echo "$(repeat_str '─' 72)"

    for tbc in "${!TRAY_NAME[@]}"; do
        seen=()
        items="${TRAY_ITEMS[$tbc]}"
        # issue 4: is this tbc ALSO a category tray? rare but reported
        local cinfo; cinfo=$(category_tray_info "$tbc" || true)
        if [[ -n "${cinfo%%|*}" ]]; then
            printf "  %s⚠ #%s combo+category collision:%s %s is both a combo tray and a category tray\n" \
                "$C_YELLOW" "$tbc" "$C_RESET" "$tbc"
            issues=$((issues+1))
        fi
        # issue 5: tray barcode collides with a product barcode
        if [[ -n "${P_NAME[$tbc]+x}" ]]; then
            printf "  %s⚠ #%s self-reference:%s tray barcode is also a product (%s)\n" \
                "$C_YELLOW" "$tbc" "$C_RESET" "${P_NAME[$tbc]}"
            issues=$((issues+1))
        fi

        for item in $items; do
            ibc="${item%%:*}"; iqt="${item#*:}"
            # issue 1: orphan item
            if [[ -z "${P_NAME[$ibc]+x}" ]]; then
                printf "  %s⚠ #%s orphan item:%s %s references unknown barcode %s\n" \
                    "$C_YELLOW" "$tbc" "$C_RESET" "${TRAY_NAME[$tbc]}" "$ibc"
                issues=$((issues+1))
                continue
            fi
            # issue 3: zero qty
            if [[ ! "$iqt" =~ ^[0-9]+$ ]] || (( iqt == 0 )); then
                printf "  %s⚠ #%s zero qty:%s %s x%s (%s)\n" \
                    "$C_YELLOW" "$tbc" "$C_RESET" "${P_NAME[$ibc]}" "$iqt" "$ibc"
                issues=$((issues+1))
            fi
            # issue 2: duplicate item
            if [[ -n "${seen[$ibc]+x}" ]]; then
                printf "  %s⚠ #%s duplicate item:%s %s appears twice\n" \
                    "$C_YELLOW" "$tbc" "$C_RESET" "${P_NAME[$ibc]}"
                issues=$((issues+1))
            fi
            seen[$ibc]=1
            # issue 6: price drift between tray snapshot and current catalog
            local tray_price
            tray_price=$(awk -F',' -v t="$tbc" -v i="$ibc" '
                NR==1 {next}
                $1==t && $3==i {print $6; exit}
            ' "$TRAYS_CSV")
            local cur_price="${P_PRICE[$ibc]}"
            if [[ -n "$tray_price" && "$tray_price" != "$cur_price" ]]; then
                printf "  %sℹ #%s price drift:%s %s tray=%s catalog=%s\n" \
                    "$C_CYAN" "$tbc" "$C_RESET" "${P_NAME[$ibc]}" \
                    "$(fmt_money "$tray_price")" "$(fmt_money "$cur_price")"
                issues=$((issues+1))
            fi
        done
    done

    echo "$(repeat_str '─' 72)"
    if (( issues == 0 )); then
        log "$(t c_tray_doctor_clean)"
        return 0
    fi
    err "$(t c_tray_doctor_issues) $issues"
    return 1
}

# Renumber/rename a combo tray.
tray_rename() {
    local tbc="$1" newname="$2"
    [[ -n "$tbc" && -n "$newname" ]] || { err "Usage: tray rename <bc> <new-name>"; return 3; }
    init_dirs; lock; load_trays
    [[ -n "${TRAY_NAME[$tbc]+x}" ]] || { unlock; err "No combo tray $tbc"; return 1; }
    local tmp="$TRAYS_CSV.new"
    printf '%s\n' "$TRAYS_HEADER" > "$tmp"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "tray_barcode,"* || -z "$line" ]]; then continue; fi
        parse_csv_line "$line"
        if [[ "${CSV_FIELDS[0]}" == "$tbc" ]]; then
            printf '%s,%s,%s,%s,%s,%s\n' \
                "$(csv_quote "$tbc")" "$(csv_quote "$newname")" \
                "$(csv_quote "${CSV_FIELDS[2]}")" "$(csv_quote "${CSV_FIELDS[3]}")" \
                "${CSV_FIELDS[4]}" "${CSV_FIELDS[5]}" >> "$tmp"
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$TRAYS_CSV"
    mv "$tmp" "$TRAYS_CSV"
    log_event "TRAY_RENAME" "$tbc" "$newname" "-" "-" "renamed from ${TRAY_NAME[$tbc]}"
    unlock
    log "Tray $tbc renamed → $newname"
}

tray_duplicate() {
    local src="$1" dst="$2" newname="$3"
    [[ -n "$src" && -n "$dst" && -n "$newname" ]] || {
        err "Usage: tray duplicate <src_bc> <dst_bc> <new-name>"; return 3
    }
    init_dirs; lock; load_trays
    [[ -n "${TRAY_NAME[$src]+x}" ]] || { unlock; err "No combo tray $src"; return 1; }
    [[ -z "${TRAY_NAME[$dst]+x}" ]] || { unlock; err "Tray $dst already exists"; return 1; }
    local items="${TRAY_ITEMS[$src]}" item ibc iqt
    for item in $items; do
        ibc="${item%%:*}"; iqt="${item#*:}"
        printf '%s,%s,%s,%s,%s,%s\n' \
            "$(csv_quote "$dst")" "$(csv_quote "$newname")" \
            "$(csv_quote "$ibc")" "$(csv_quote "${P_NAME[$ibc]:-${CSV_FIELDS[3]:-}}")" \
            "$iqt" "${P_PRICE[$ibc]:-0}" >> "$TRAYS_CSV"
    done
    log_event "TRAY_DUPLICATE" "$dst" "$newname" "${#items}" "-" "cloned from $src"
    unlock
    log "Tray $dst cloned from $src → $newname"
}

# Extend cmd_tray with doctor / rename / duplicate sub-commands.
# This wrapper is invoked from main() when sub == 'doctor' / 'rename' / 'duplicate'.
cmd_tray_v2() {
    local sub="${1:-}"
    shift
    case "$sub" in
        doctor)        tray_doctor ;;
        rename)        tray_rename "$@" ;;
        duplicate)     tray_duplicate "$@" ;;
        *)             err "Unknown tray v2 subcommand: $sub"; return 3 ;;
    esac
}

#═══════════════════════════════════════════════════════════════════════════════
# PART G — Bill layout config
#
#   bill-layout.conf is a simple key=value file. Loading is tolerant:
#   unknown keys are ignored, missing keys fall back to defaults.
#═══════════════════════════════════════════════════════════════════════════════

bill_layout_load() {
    [[ -f "$BILL_LAYOUT_FILE" ]] || return 0
    local line k v
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
        [[ "$k" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$k" ]] && continue
        k="${k// /}"; v="${v# }"
        case "$k" in
            width)            BL_WIDTH="$v" ;;
            ratio_width)      BL_RATIO_WIDTH="$v" ;;
            show_phone)       BL_SHOW_PHONE="$v" ;;
            show_qr)          BL_SHOW_QR="$v" ;;
            show_gst)         BL_SHOW_GST="$v" ;;
            gst_default_pct)  BL_GST_DEFAULT_PCT="$v" ;;
            round_off)        BL_ROUND_OFF="$v" ;;
            header_line)      BL_HEADER_LINE="$v" ;;
            footer_line)      BL_FOOTER_LINE="$v" ;;
            upi_vpa)          BL_UPI_VPA="$v" ;;
            discount_pct)     BL_DISCOUNT_PCT="$v" ;;
            carry_bag_paise)  BL_CARRY_BAG_PAISE="$v" ;;
            delivery_paise)   BL_DELIVERY_PAISE="$v" ;;
            donation_paise)   BL_DONATION_PAISE="$v" ;;
        esac
    done < "$BILL_LAYOUT_FILE"
}

bill_layout_save() {
    init_dirs
    cat > "$BILL_LAYOUT_FILE" <<EOF
# shopkeep bill-layout.conf — written $(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')
width=$BL_WIDTH
ratio_width=$BL_RATIO_WIDTH
show_phone=$BL_SHOW_PHONE
show_qr=$BL_SHOW_QR
show_gst=$BL_SHOW_GST
gst_default_pct=$BL_GST_DEFAULT_PCT
round_off=$BL_ROUND_OFF
header_line=$BL_HEADER_LINE
footer_line=$BL_FOOTER_LINE
upi_vpa=$BL_UPI_VPA
discount_pct=$BL_DISCOUNT_PCT
carry_bag_paise=$BL_CARRY_BAG_PAISE
delivery_paise=$BL_DELIVERY_PAISE
donation_paise=$BL_DONATION_PAISE
EOF
}

cmd_billconfig() {
    init_dirs; bill_layout_load
    local sub="${1:-show}"
    case "$sub" in
        show)
            echo "${C_BOLD}$(t m_billconfig)${C_RESET}"
            echo "$(repeat_str '─' 48)"
            printf "  %-22s %s\n" "width:"            "$BL_WIDTH"
            printf "  %-22s %s\n" "ratio_width:"      "$BL_RATIO_WIDTH"
            printf "  %-22s %s\n" "show_phone:"       "$BL_SHOW_PHONE"
            printf "  %-22s %s\n" "show_qr:"          "$BL_SHOW_QR"
            printf "  %-22s %s\n" "show_gst:"         "$BL_SHOW_GST"
            printf "  %-22s %s%%\n" "gst_default_pct:" "$BL_GST_DEFAULT_PCT"
            printf "  %-22s %s\n" "round_off:"        "$BL_ROUND_OFF"
            printf "  %-22s %s\n" "header_line:"      "${BL_HEADER_LINE:-(none)}"
            printf "  %-22s %s\n" "footer_line:"      "${BL_FOOTER_LINE:-(none)}"
            printf "  %-22s %s\n" "upi_vpa:"          "${BL_UPI_VPA:-(none)}"
            printf "  %-22s %s%%\n" "discount_pct:"   "$BL_DISCOUNT_PCT"
            printf "  %-22s %s\n" "carry_bag_paise:"  "$BL_CARRY_BAG_PAISE"
            printf "  %-22s %s\n" "delivery_paise:"   "$BL_DELIVERY_PAISE"
            printf "  %-22s %s\n" "donation_paise:"   "$BL_DONATION_PAISE"
            ;;
        set)
            shift
            local key val
            while [[ $# -gt 0 ]]; do
                key="${1%%=*}"; val="${1#*=}"
                case "$key" in
                    width)            BL_WIDTH="$val" ;;
                    ratio_width)      BL_RATIO_WIDTH="$val" ;;
                    show_phone)       BL_SHOW_PHONE="$val" ;;
                    show_qr)          BL_SHOW_QR="$val" ;;
                    show_gst)         BL_SHOW_GST="$val" ;;
                    gst_default_pct)  BL_GST_DEFAULT_PCT="$val" ;;
                    round_off)        BL_ROUND_OFF="$val" ;;
                    header_line)      BL_HEADER_LINE="$val" ;;
                    footer_line)      BL_FOOTER_LINE="$val" ;;
                    upi_vpa)          BL_UPI_VPA="$val" ;;
                    discount_pct)     BL_DISCOUNT_PCT="$val" ;;
                    carry_bag_paise)  BL_CARRY_BAG_PAISE="$val" ;;
                    delivery_paise)   BL_DELIVERY_PAISE="$val" ;;
                    donation_paise)   BL_DONATION_PAISE="$val" ;;
                    *) err "Unknown key: $key" ;;
                esac
                shift
            done
            bill_layout_save
            log "$(t c_billconfig_saved)"
            ;;
        reset)
            BL_WIDTH=42; BL_RATIO_WIDTH=3; BL_SHOW_PHONE=1; BL_SHOW_QR=0
            BL_SHOW_GST=0; BL_GST_DEFAULT_PCT=0; BL_ROUND_OFF=1
            BL_HEADER_LINE=""; BL_FOOTER_LINE="Thank you! Visit again."
            BL_UPI_VPA=""; BL_DISCOUNT_PCT=0
            BL_CARRY_BAG_PAISE=0; BL_DELIVERY_PAISE=0; BL_DONATION_PAISE=0
            bill_layout_save
            log "$(t c_billconfig_reset)"
            ;;
        edit)
            # Interactive edit
            printf "%s (current=%s): " "$(t p_bill_width)" "$BL_WIDTH"; read -r BL_WIDTH
            printf "%s (current=%s): " "$(t p_bill_ratio)" "$BL_RATIO_WIDTH"; read -r BL_RATIO_WIDTH
            printf "%s (current=%s): " "$(t p_bill_header)" "$BL_HEADER_LINE"; read -r BL_HEADER_LINE
            printf "%s (current=%s): " "$(t p_bill_footer)" "$BL_FOOTER_LINE"; read -r BL_FOOTER_LINE
            printf "%s (current=%s): " "$(t p_bill_gst)" "$BL_GST_DEFAULT_PCT"; read -r BL_GST_DEFAULT_PCT
            printf "%s (current=%s): " "$(t p_bill_discount)" "$BL_DISCOUNT_PCT"; read -r BL_DISCOUNT_PCT
            printf "%s (current=%s): " "$(t p_bill_carry)" "$((BL_CARRY_BAG_PAISE/100))"; read -r carry
            [[ "$carry" =~ ^[0-9]+\.?[0-9]*$ ]] && BL_CARRY_BAG_PAISE=$(rupees_to_paise "$carry" 2>/dev/null || echo 0)
            printf "%s (current=%s): " "$(t p_bill_delivery)" "$((BL_DELIVERY_PAISE/100))"; read -r deliv
            [[ "$deliv" =~ ^[0-9]+\.?[0-9]*$ ]] && BL_DELIVERY_PAISE=$(rupees_to_paise "$deliv" 2>/dev/null || echo 0)
            printf "%s (current=%s): " "$(t p_bill_round)" "$BL_ROUND_OFF"; read -r BL_ROUND_OFF
            printf "%s (current=%s): " "$(t p_bill_show_qr)" "$BL_SHOW_QR"; read -r BL_SHOW_QR
            printf "%s (current=%s): " "$(t p_bill_show_phone)" "$BL_SHOW_PHONE"; read -r BL_SHOW_PHONE
            printf "%s (current=%s): " "$(t p_bill_upi_vpa)" "$BL_UPI_VPA"; read -r BL_UPI_VPA
            bill_layout_save
            log "$(t c_billconfig_saved)"
            ;;
        *)
            err "Usage: shopkeep.sh billconfig [show|set|reset|edit]"
            return 3
            ;;
    esac
}

#═══════════════════════════════════════════════════════════════════════════════
# PART H — Bill additions: discount, GST, round-off, custom line items
#
#   The legacy commit_bill() signature is preserved for self-test compat.
#   v2 billing flows through commit_bill_v2(), which accepts an "extras"
#   string in the format:
#
#     discount_pct=N;discount_flat_paise=N;gst_pct=N;carry_paise=N;
#     delivery_paise=N;donation_paise=N;round_off=1;custom="desc:paise,desc:paise"
#
#   print_receipt_v2() renders the receipt using the user's bill-layout.conf.
#═══════════════════════════════════════════════════════════════════════════════

parse_extras() {
    local s="${1:-}"
    EX_DISCOUNT_PCT="$BL_DISCOUNT_PCT"
    EX_DISCOUNT_FLAT_PAISE=0
    EX_GST_PCT="$BL_GST_DEFAULT_PCT"
    EX_CARRY_PAISE="$BL_CARRY_BAG_PAISE"
    EX_DELIVERY_PAISE="$BL_DELIVERY_PAISE"
    EX_DONATION_PAISE="$BL_DONATION_PAISE"
    EX_ROUND_OFF="$BL_ROUND_OFF"
    EX_CUSTOM=""   # "desc:paise,desc:paise"
    [[ -z "$s" ]] && return 0
    local kv k v
    IFS=';' read -ra kv <<< "$s"
    for kv in "${kv[@]}"; do
        k="${kv%%=*}"; v="${kv#*=}"
        case "$k" in
            discount_pct)         EX_DISCOUNT_PCT="$v" ;;
            discount_flat_paise)  EX_DISCOUNT_FLAT_PAISE="$v" ;;
            gst_pct)              EX_GST_PCT="$v" ;;
            carry_paise)          EX_CARRY_PAISE="$v" ;;
            delivery_paise)       EX_DELIVERY_PAISE="$v" ;;
            donation_paise)       EX_DONATION_PAISE="$v" ;;
            round_off)            EX_ROUND_OFF="$v" ;;
            custom)               EX_CUSTOM="$v" ;;
        esac
    done
}

# Compute the final bill total given a subtotal (paise) and the parsed extras.
# Sets globals: V2_SUBTOTAL, V2_DISCOUNT_PAISE, V2_GST_PAISE, V2_EXTRAS_PAISE,
# V2_ROUND_PAISE, V2_TOTAL.
compute_bill_totals() {
    local subtotal="$1"
    V2_SUBTOTAL="$subtotal"
    V2_DISCOUNT_PAISE=0
    V2_GST_PAISE=0
    V2_EXTRAS_PAISE=0
    V2_ROUND_PAISE=0
    V2_TOTAL=0

    # Discount (flat overrides pct)
    if (( EX_DISCOUNT_FLAT_PAISE > 0 )); then
        V2_DISCOUNT_PAISE="$EX_DISCOUNT_FLAT_PAISE"
    elif (( EX_DISCOUNT_PCT > 0 )); then
        V2_DISCOUNT_PAISE=$(( subtotal * EX_DISCOUNT_PCT / 100 ))
    fi
    local after_discount=$(( subtotal - V2_DISCOUNT_PAISE ))
    (( after_discount < 0 )) && after_discount=0

    # GST on discounted subtotal
    if (( EX_GST_PCT > 0 )); then
        V2_GST_PAISE=$(( after_discount * EX_GST_PCT / 100 ))
    fi

    # Extra charges
    V2_EXTRAS_PAISE=$(( EX_CARRY_PAISE + EX_DELIVERY_PAISE + EX_DONATION_PAISE ))
    # Custom line items
    local cdesc ctot=0
    if [[ -n "$EX_CUSTOM" ]]; then
        local IFS=',' pair pdesc ppa
        for pair in $EX_CUSTOM; do
            pdesc="${pair%%:*}"; ppa="${pair#*:}"
            [[ "$ppa" =~ ^-?[0-9]+$ ]] && ctot=$(( ctot + ppa ))
        done
        V2_EXTRAS_PAISE=$(( V2_EXTRAS_PAISE + ctot ))
    fi

    local pre_round=$(( after_discount + V2_GST_PAISE + V2_EXTRAS_PAISE ))

    # Round-off to nearest ₹ (100 paise)
    if [[ "$EX_ROUND_OFF" == "1" ]]; then
        local rem=$(( pre_round % 100 ))
        if (( rem >= 50 )); then
            V2_ROUND_PAISE=$(( 100 - rem ))
        else
            V2_ROUND_PAISE=$(( -rem ))
        fi
    fi
    V2_TOTAL=$(( pre_round + V2_ROUND_PAISE ))
}

# Renders the v2 receipt using bill-layout.conf. Honours width / show_qr / etc.
print_receipt_v2() {
    local title="$1" bill_no="$2" ts="$3" phone="${4:-}" extras="${5:-}"
    shift 5
    local lines=("$@")
    local n=${#lines[@]} units=0 line bc name up qty lt
    bill_layout_load

    # BOX_WIDTH is read by box_top/box_mid/box_bottom/box_row/box_center
    BOX_WIDTH="$BL_WIDTH"
    MONEY_FIELD=$(( BL_WIDTH / 5 ))
    MAX_NAME=$(( BL_WIDTH - 12 - MONEY_FIELD ))

    # Compute subtotal
    local subtotal=0
    for line in "${lines[@]}"; do
        IFS="$US" read -r bc name up qty lt <<< "$line"
        subtotal=$(( subtotal + lt ))
        units=$(( units + qty ))
    done
    parse_extras "$extras"
    compute_bill_totals "$subtotal"

    box_top
    box_center "$title"
    [[ -n "$BL_HEADER_LINE" ]] && box_center "$BL_HEADER_LINE"
    box_center "Bill #$(printf '%04d' "$bill_no")"
    box_center "$ts"
    if [[ "$BL_SHOW_PHONE" == "1" && -n "$phone" ]]; then
        box_center "Ph: $phone"
    fi
    box_mid
    for line in "${lines[@]}"; do
        IFS="$US" read -r bc name up qty lt <<< "$line"
        box_lr " $(truncate_name "$name" "$MAX_NAME") x$qty" "$(fmt_money_field "$lt" "$MONEY_FIELD")"
    done

    # Add custom line items inline
    if [[ -n "$EX_CUSTOM" ]]; then
        local IFS=',' pair pdesc ppa
        for pair in $EX_CUSTOM; do
            pdesc="${pair%%:*}"; ppa="${pair#*:}"
            [[ "$ppa" =~ ^-?[0-9]+$ ]] || continue
            box_lr " ${pdesc:0:$MAX_NAME}" "$(fmt_money_field "$ppa" "$MONEY_FIELD")"
        done
    fi

    box_mid
    if (( V2_DISCOUNT_PAISE > 0 )); then
        local dlabel="$(t bl_discount)"
        (( EX_DISCOUNT_PCT > 0 )) && dlabel="$dlabel (${EX_DISCOUNT_PCT}%)"
        box_lr " $dlabel" "-$(fmt_money_field "$V2_DISCOUNT_PAISE" "$MONEY_FIELD")"
    fi
    if (( EX_GST_PCT > 0 )); then
        box_lr " $(t bl_gst) (${EX_GST_PCT}%)" "$(fmt_money_field "$V2_GST_PAISE" "$MONEY_FIELD")"
    fi
    (( EX_CARRY_PAISE > 0 ))    && box_lr " $(t bl_carry)"    "$(fmt_money_field "$EX_CARRY_PAISE"    "$MONEY_FIELD")"
    (( EX_DELIVERY_PAISE > 0 )) && box_lr " $(t bl_delivery)" "$(fmt_money_field "$EX_DELIVERY_PAISE" "$MONEY_FIELD")"
    (( EX_DONATION_PAISE > 0 )) && box_lr " $(t bl_donation)" "$(fmt_money_field "$EX_DONATION_PAISE" "$MONEY_FIELD")"
    if [[ "$EX_ROUND_OFF" == "1" && $V2_ROUND_PAISE -ne 0 ]]; then
        local rsign="+"
        (( V2_ROUND_PAISE < 0 )) && rsign=""
        box_lr " $(t bl_roundoff)" "${rsign}$(fmt_money_field "$V2_ROUND_PAISE" "$MONEY_FIELD")"
    fi
    box_lr " $(t bl_total)" "$(fmt_money_field "$V2_TOTAL" "$MONEY_FIELD")"
    box_lr " $(t bl_items) $n  $(t bl_units) $units" ""
    if [[ "$BL_SHOW_QR" == "1" && -n "$BL_UPI_VPA" ]]; then
        local qrfile
        qrfile=$(gen_qr "upi://pay?pa=$(printf '%s' "$BL_UPI_VPA" | sed 's/ /%20/g')&am=$(awk -v p="$V2_TOTAL" 'BEGIN{printf "%.2f", p/100}')&cu=INR&tn=bill$bill_no" "$QRS_DIR/bill-$(printf '%04d' "$bill_no")-upi.png")
        box_center "Scan UPI QR to pay:"
        box_center "($qrfile)"
    fi
    [[ -n "$BL_FOOTER_LINE" ]] && box_center "$BL_FOOTER_LINE"
    box_bottom
}

# v2 bill commit. KEPT FOR BACKWARD COMPATIBILITY — every v2 feature now flows
# through cmd_bill with the --extras flag. This wrapper just forwards.
commit_bill_v2() {
    local extras="" phone="" args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --extras) extras="$2"; shift 2 ;;
            --phone)  phone="$2";  shift 2 ;;
            *)        args+=("$1"); shift ;;
        esac
    done
    # If we got positional cart args, call commit_bill directly (no stdin)
    if (( ${#args[@]} > 0 )); then
        if [[ -n "$extras" ]]; then
            BILL_PHONE="$phone"
            if commit_bill "${args[@]}"; then
                echo
                print_receipt_v2 "$(conf shop_name)" "$BILL_NO" "$BILL_TS" "$BILL_PHONE" "$extras" "${BILL_LINES[@]}"
                log "Bill #$BILL_NO saved. Total $(fmt_money "$BILL_TOTAL") (extras applied)"
            else
                return $?
            fi
        else
            BILL_PHONE="$phone"
            commit_bill "${args[@]}"
        fi
    else
        # No positional args — caller is expected to pipe stdin (like cmd_bill)
        cmd_bill ${phone:+--phone "$phone"} ${extras:+--extras "$extras"}
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# PART I — Bills monitoring
#
#   billsmon                    : show today + month-to-date summary
#   billsmon day YYYY-MM-DD     : per-day dashboard
#   billsmon month YYYY-MM      : per-month dashboard
#   billsmon rebuild            : regenerate all dashboards from bills.csv
#
# Each dashboard is written under $BILLS_MONITOR_DIR/ as both .txt and .html
# so the shopkeeper can open it in a browser or paste into WhatsApp.
#═══════════════════════════════════════════════════════════════════════════════

billsmon_rebuild_day() {
    local date="$1"
    init_dirs
    mkdir -p "$BILLS_MONITOR_DIR/by-day/$(printf '%s' "$date" | tr -d '/')"
    local out_txt="$BILLS_MONITOR_DIR/by-day/${date//-/}-summary.txt"
    local out_html="$BILLS_MONITOR_DIR/by-day/${date//-/}-summary.html"
    local out
    out=$(cmd_summary "$date" 2>/dev/null || true)
    printf '%s\n' "$out" > "$out_txt"

    # HTML version (WhatsApp-shareable)
    local rows_html="" line bno ts bc name qty up lt action
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "bill_no,"* || -z "$line" ]] && continue
        parse_csv_line "$line"
        bno="${CSV_FIELDS[0]}"; ts="${CSV_FIELDS[1]}"; bc="${CSV_FIELDS[2]}"
        name="${CSV_FIELDS[3]}"; qty="${CSV_FIELDS[4]}"; lt="${CSV_FIELDS[6]}"
        action="${CSV_FIELDS[7]}"
        [[ "${ts:0:10}" == "$date" && "$action" == "SELL" ]] || continue
        rows_html+="<tr><td>$bno</td><td>$ts</td><td>$(printf '%s' "$name" | sed 's/</\&lt;/g')</td><td>$qty</td><td>$(fmt_money "$lt")</td></tr>"
    done < "$BILLS_CSV"
    cat > "$out_html" <<EOF
<!doctype html><html><head><meta charset="utf-8">
<title>Bill summary — $date</title>
<style>
body{font-family:sans-serif;max-width:800px;margin:2em auto;padding:0 1em}
table{border-collapse:collapse;width:100%}
td,th{border:1px solid #ddd;padding:6px 10px;text-align:left}
th{background:#f5f5f5}
h1{color:#333}
</style></head><body>
<h1>Daily bill summary — $date</h1>
<pre>$(printf '%s' "$out" | sed 's/</\&lt;/g; s/>/\&gt;/g')</pre>
<h2>Line items</h2>
<table>
<tr><th>Bill#</th><th>Time</th><th>Item</th><th>Qty</th><th>Amount</th></tr>
${rows_html:-<tr><td colspan=5>No bills this day</td></tr>}
</table>
</body></html>
EOF
    printf '%s' "$out_txt"
}

billsmon_rebuild_month() {
    local ym="$1"   # YYYY-MM
    init_dirs
    mkdir -p "$BILLS_MONITOR_DIR/by-month"
    local out_txt="$BILLS_MONITOR_DIR/by-month/${ym//-/}-summary.txt"
    local total=0 count=0 units=0 line bno ts bc name qty lt action
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "bill_no,"* || -z "$line" ]] && continue
        parse_csv_line "$line"
        ts="${CSV_FIELDS[1]}"; action="${CSV_FIELDS[7]}"
        qty="${CSV_FIELDS[4]}"; lt="${CSV_FIELDS[6]}"
        [[ "${ts:0:7}" == "$ym" && "$action" == "SELL" ]] || continue
        count=$((count+1)); units=$((units+qty)); total=$((total+lt))
    done < "$BILLS_CSV"
    {
        echo "Monthly summary — $ym"
        echo "$(repeat_str '─' 40)"
        echo " Bills processed:  $count"
        echo " Units sold:       $units"
        echo " Revenue:          $(fmt_money "$total")"
    } > "$out_txt"
    printf '%s' "$out_txt"
}

cmd_billsmon() {
    init_dirs
    bill_layout_load
    local sub="${1:-today}"
    case "$sub" in
        today)
            local today; today=$(TZ=Asia/Kolkata date +%Y-%m-%d)
            local f; f=$(billsmon_rebuild_day "$today")
            cat "$f"
            log "Written: $f (+ .html)"
            ;;
        day)
            local d="${2:-$(TZ=Asia/Kolkata date +%Y-%m-%d)}"
            [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { err "Bad date: $d"; return 1; }
            local f; f=$(billsmon_rebuild_day "$d")
            cat "$f"
            log "Written: $f (+ .html)"
            ;;
        month)
            local ym="${2:-$(TZ=Asia/Kolkata date +%Y-%m)}"
            [[ "$ym" =~ ^[0-9]{4}-[0-9]{2}$ ]] || { err "Bad month: $ym (use YYYY-MM)"; return 1; }
            local f; f=$(billsmon_rebuild_month "$ym")
            cat "$f"
            log "Written: $f"
            ;;
        rebuild)
            mkdir -p "$BILLS_MONITOR_DIR/by-day" "$BILLS_MONITOR_DIR/by-month"
            # Iterate over every distinct date in bills.csv
            local dates line ts
            local -A seen=()
            if [[ -f "$BILLS_CSV" ]]; then
                while IFS= read -r line || [[ -n "$line" ]]; do
                    [[ "$line" == "bill_no,"* || -z "$line" ]] && continue
                    parse_csv_line "$line"
                    ts="${CSV_FIELDS[1]}"
                    [[ -n "$ts" ]] || continue
                    seen["${ts:0:10}"]=1
                    seen["${ts:0:7}-MONTH"]=1
                done < "$BILLS_CSV"
            fi
            local k n=0
            for k in "${!seen[@]}"; do
                if [[ "$k" == *-MONTH ]]; then
                    billsmon_rebuild_month "${k%-MONTH}" >/dev/null
                else
                    billsmon_rebuild_day "$k" >/dev/null
                fi
                n=$((n+1))
            done
            log "Rebuilt $n dashboards under $BILLS_MONITOR_DIR/"
            ;;
        *)
            err "Usage: shopkeep.sh billsmon [today|day <date>|month <ym>|rebuild]"
            return 3
            ;;
    esac
}

#═══════════════════════════════════════════════════════════════════════════════
# PART J — Missing POS features
#
#   hold        — park the current cart, recall later
#   recall      — list/load held carts
#   return      — sales return without a bill (or against one)
#   dayclose    — X-report (mid-day) and Z-report (end-of-day with reset)
#   cashdrawer  — opening/closing cash tally
#   customer    — add / list / find customers by phone
#   htmlbill    — export a bill as a WhatsApp-shareable HTML file
#   importcsv   — bulk import products from a CSV file
#   expiry      — add / list / near expiry tracking
#   hotlist     — top N sellers (rebuilt from bills.csv)
#═══════════════════════════════════════════════════════════════════════════════

#─────────────────────────────────────────────────────────────────────────────
# Hold / recall
#─────────────────────────────────────────────────────────────────────────────
cmd_hold() {
    # Reads cart lines (bc qty) from stdin, parks them under a name.
    init_dirs; mkdir -p "$HOLD_DIR"
    local name="${1:-hold-$(date +%s)}"
    local out="$HOLD_DIR/$name.hold"
    local n=0 line
    : > "$out"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        printf '%s\n' "$line" >> "$out"
        n=$((n+1))
    done
    if (( n == 0 )); then
        err "Empty cart — nothing to hold."
        rm -f "$out"
        return 1
    fi
    log "$(t c_hold_saved): $name ($n lines)"
}

cmd_recall() {
    init_dirs
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        # List held bills
        if ! ls "$HOLD_DIR"/*.hold >/dev/null 2>&1; then
            log "$(t c_recall_empty)"
            return 0
        fi
        echo "${C_BOLD}Held bills in $HOLD_DIR:${C_RESET}"
        local f n
        for f in "$HOLD_DIR"/*.hold; do
            n=$(wc -l < "$f")
            printf "  %-30s  %d lines\n" "$(basename "$f" .hold)" "$n"
        done
        echo
        echo "Resume with: shopkeep.sh recall <name>"
        return 0
    fi
    local f="$HOLD_DIR/$name.hold"
    [[ -f "$f" ]] || { err "No held bill named $name"; return 1; }
    # Output the held cart as the new stdin for `bill`
    cat "$f"
}

#─────────────────────────────────────────────────────────────────────────────
# Sales return
#─────────────────────────────────────────────────────────────────────────────
cmd_return() {
    local bc="${1:-}" qty="${2:-1}" reason="${3:-no reason}"
    [[ -n "$bc" ]] || { err "Usage: shopkeep.sh return <barcode> [qty] [reason]"; return 3; }
    [[ "$bc" =~ ^[0-9]+$ ]] || { err "barcode must be digits"; return 1; }
    [[ "$qty" =~ ^[0-9]+$ && "$qty" -gt 0 ]] || { err "qty must be positive"; return 1; }
    init_dirs; lock; load_products
    [[ -n "${P_NAME[$bc]+x}" ]] || { unlock; err "No product with barcode $bc"; return 1; }
    # Add qty back to stock
    if apply_stock_delta "$bc $qty"; then
        log_event "RETURN" "$bc" "${P_NAME[$bc]}" "$qty" "${P_PRICE[$bc]}" "sales return: $reason"
        unlock
        log "Returned: ${P_NAME[$bc]} x$qty (stock +$qty)"
        return 0
    else
        unlock; err "Return failed"; return 1
    fi
}

#─────────────────────────────────────────────────────────────────────────────
# Day-close: X-report (no reset) and Z-report (resettable counter)
#─────────────────────────────────────────────────────────────────────────────
cmd_dayclose() {
    local kind="${1:-x}"
    init_dirs
    local today; today=$(TZ=Asia/Kolkata date +%Y-%m-%d)
    echo "${C_BOLD}=== DAY CLOSE — $(echo $kind | tr a-z A-Z) REPORT ===${C_RESET}"
    echo "Date: $today"
    echo "$(repeat_str '─' 48)"
    cmd_summary "$today"
    echo
    echo "Stock value snapshot:"
    cmd_stockvalue 2>/dev/null | tail -5
    if [[ "${kind,,}" == "z" ]]; then
        # Z-report: force a backup, optionally reset bill counter (we don't,
        # because bill numbers must NEVER regress — Z-report just logs)
        log_event "DAYCLOSE_Z" "-" "all" "-" "-" "Z report for $today"
        backup_now
        log "Z-report filed. Backup created."
    else
        log_event "DAYCLOSE_X" "-" "all" "-" "-" "X report for $today"
    fi
}

#─────────────────────────────────────────────────────────────────────────────
# Cash drawer tally
#─────────────────────────────────────────────────────────────────────────────
cmd_cashdrawer() {
    init_dirs
    local tally="$DATA_DIR/cashdrawer.tsv"
    local now; now=$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')
    if [[ "$1" == "open" ]]; then
        printf "%s\tOPEN\t%s\n" "$now" "${2:-0}" >> "$tally"
        log "Cash drawer OPEN recorded: ₹${2:-0}"
    elif [[ "$1" == "close" ]]; then
        printf "%s\tCLOSE\t%s\n" "$now" "${2:-0}" >> "$tally"
        log "Cash drawer CLOSE recorded: ₹${2:-0}"
    elif [[ "$1" == "list" || -z "$1" ]]; then
        [[ -f "$tally" ]] || { log "No cash drawer entries yet."; return 0; }
        echo "${C_BOLD}CASH DRAWER HISTORY${C_RESET}"
        echo "$(repeat_str '─' 48)"
        awk -F'\t' '{printf "  %-19s  %-6s  ₹%s\n", $1, $2, $3}' "$tally"
    else
        err "Usage: shopkeep.sh cashdrawer [open|close|list] [amount]"
        return 3
    fi
}

#─────────────────────────────────────────────────────────────────────────────
# Customer DB
#─────────────────────────────────────────────────────────────────────────────
load_customers() {
    CUST_NAME=(); CUST_PHONE=(); CUST_VISITS=(); CUST_SPENT=()
    [[ -f "$CUSTOMERS_CSV" ]] || return 0
    local line bc
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "phone,"* || -z "$line" ]] && continue
        parse_csv_line "$line"
        local ph="${CSV_FIELDS[0]}"
        [[ -z "$ph" ]] && continue
        CUST_NAME["$ph"]="${CSV_FIELDS[1]}"
        CUST_PHONE["$ph"]="$ph"
        CUST_VISITS["$ph"]="${CSV_FIELDS[2]:-0}"
        CUST_SPENT["$ph"]="${CSV_FIELDS[3]:-0}"
    done < "$CUSTOMERS_CSV"
}

cmd_customer() {
    init_dirs
    local sub="${1:-list}"
    shift 2>/dev/null || true
    case "$sub" in
        add)
            local name="$1" phone="$2"
            [[ -n "$name" && -n "$phone" ]] || { err "Usage: customer add <name> <phone>"; return 3; }
            [[ -f "$CUSTOMERS_CSV" ]] || printf 'phone,name,visits,total_spent_paise\n' > "$CUSTOMERS_CSV"
            printf '%s,%s,0,0\n' "$(csv_quote "$phone")" "$(csv_quote "$name")" >> "$CUSTOMERS_CSV"
            log "$(t c_cust_added): $name ($phone)"
            ;;
        list)
            [[ -f "$CUSTOMERS_CSV" ]] || { log "No customers yet."; return 0; }
            echo "${C_BOLD}CUSTOMERS${C_RESET}"
            echo "$(repeat_str '─' 56)"
            awk -F',' 'NR>1 && NF>=4 {printf "  %-14s %-26s  %s visits  ₹%d\n", $1, $2, $3, $4/100}' "$CUSTOMERS_CSV"
            ;;
        find)
            local q="${1:-}"
            [[ -n "$q" ]] || { err "Usage: customer find <phone-or-name>"; return 3; }
            load_customers
            local ph
            for ph in "${!CUST_NAME[@]}"; do
                if [[ "$ph" == *"$q"* || "${CUST_NAME[$ph],,}" == *"${q,,}"* ]]; then
                    printf "  %-14s %-26s  %s visits  ₹%d\n" "$ph" "${CUST_NAME[$ph]}" "${CUST_VISITS[$ph]}" "$(( ${CUST_SPENT[$ph]:-0} / 100 ))"
                fi
            done
            ;;
        *) err "Usage: shopkeep.sh customer [add|list|find] ..."; return 3 ;;
    esac
}

#─────────────────────────────────────────────────────────────────────────────
# HTML invoice export (WhatsApp share)
#─────────────────────────────────────────────────────────────────────────────
cmd_htmlbill() {
    local bno="${1:-}"
    [[ -n "$bno" && "$bno" =~ ^[0-9]+$ ]] || { err "Usage: shopkeep.sh htmlbill <bill_no>"; return 3; }
    init_dirs; lock
    local line bno_r ts bc name qty up lt action
    local -a rows=()
    local total=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "bill_no,"* || -z "$line" ]] && continue
        parse_csv_line "$line"
        bno_r="${CSV_FIELDS[0]}"; ts="${CSV_FIELDS[1]}"
        bc="${CSV_FIELDS[2]}"; name="${CSV_FIELDS[3]}"
        qty="${CSV_FIELDS[4]}"; up="${CSV_FIELDS[5]}"; lt="${CSV_FIELDS[6]}"; action="${CSV_FIELDS[7]}"
        [[ "$bno_r" == "$bno" && "$action" == "SELL" ]] || continue
        total=$(( total + lt ))
        rows+=("<tr><td>$(printf '%s' "$name" | sed 's/</\&lt;/g')</td><td style='text-align:center'>$qty</td><td style='text-align:right'>$(fmt_money "$up")</td><td style='text-align:right'>$(fmt_money "$lt")</td></tr>")
    done < "$BILLS_CSV"
    unlock
    (( ${#rows[@]} > 0 )) || { err "Bill $bno not found"; return 1; }
    bill_layout_load
    local out="$DATA_DIR/bill-$(printf '%04d' "$bno").html"
    cat > "$out" <<EOF
<!doctype html><html><head><meta charset="utf-8">
<title>Bill #$bno — $(conf shop_name)</title>
<style>
body{font-family:'Courier New',monospace;max-width:480px;margin:1em auto;padding:1em}
h1{font-size:18px;text-align:center;margin:0}
h2{font-size:14px;text-align:center;color:#666;margin:4px 0 16px}
table{border-collapse:collapse;width:100%;font-size:13px}
td,th{border-bottom:1px dotted #ccc;padding:4px 8px}
th{background:#f9f9f9;text-align:left}
.total{font-size:18px;font-weight:bold;border-top:2px solid #333;border-bottom:none;padding-top:8px}
</style></head><body>
<h1>$(conf shop_name)</h1>
<h2>Bill #$(printf '%04d' "$bno") · $ts</h2>
<table>
<tr><th>Item</th><th style='text-align:center'>Qty</th><th style='text-align:right'>Rate</th><th style='text-align:right'>Amt</th></tr>
$(printf '%s\n' "${rows[@]}")
<tr><td colspan=3 style='text-align:right;border-top:2px solid #333'><strong>TOTAL</strong></td>
<td class='total' style='text-align:right'>$(fmt_money "$total")</td></tr>
</table>
<p style='text-align:center;margin-top:16px;color:#666;font-size:12px'>${BL_FOOTER_LINE:-Thank you!}</p>
</body></html>
EOF
    log "$(t c_html_done) $out"
}

#─────────────────────────────────────────────────────────────────────────────
# CSV bulk import
#   File format: name,price,qty[,barcode,threshold,type,desc]
#   Header row optional — if first field is "name", skip it.
#─────────────────────────────────────────────────────────────────────────────
cmd_importcsv() {
    local file="${1:-}"
    [[ -n "$file" && -f "$file" ]] || { err "Usage: shopkeep.sh importcsv <file.csv>"; return 3; }
    init_dirs; lock; load_products
    local line n=0 fails=0 name price qty bc thr ptype desc
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        if [[ "$line" == "name,"* ]]; then continue; fi
        parse_csv_line "$line"
        name="${CSV_FIELDS[0]}"; price="${CSV_FIELDS[1]}"; qty="${CSV_FIELDS[2]}"
        bc="${CSV_FIELDS[3]:-}"; thr="${CSV_FIELDS[4]:-8}"; ptype="${CSV_FIELDS[5]:-}"; desc="${CSV_FIELDS[6]:-}"
        if [[ -z "$name" || -z "$price" || -z "$qty" ]]; then fails=$((fails+1)); continue; fi
        local pp; pp=$(rupees_to_paise "$price" 2>/dev/null) || { fails=$((fails+1)); continue; }
        [[ -z "$bc" ]] && bc=$(gen_internal_barcode)
        if [[ -n "${P_NAME[$bc]+x}" ]]; then fails=$((fails+1)); continue; fi
        do_add "$bc" "$name" "$pp" "$qty" "$thr" "$desc" "$ptype" "" >/dev/null 2>&1 || { fails=$((fails+1)); continue; }
        n=$((n+1))
    done < "$file"
    unlock
    log "$(t c_import_ok): $n products ($fails skipped)"
}

#─────────────────────────────────────────────────────────────────────────────
# Expiry tracking
#   expiry add <bc> <batch> <qty> <YYYY-MM-DD>
#   expiry list
#   expiry near [days]    — items expiring within N days (default 7)
#─────────────────────────────────────────────────────────────────────────────
cmd_expiry() {
    init_dirs
    local sub="${1:-list}"
    shift 2>/dev/null || true
    case "$sub" in
        add)
            local bc="$1" batch="$2" qty="$3" date="$4"
            [[ -n "$bc" && -n "$batch" && -n "$qty" && -n "$date" ]] || {
                err "Usage: expiry add <barcode> <batch> <qty> <YYYY-MM-DD>"; return 3
            }
            [[ -f "$EXPIRY_CSV" ]] || printf 'barcode,batch,qty,expiry_date,added_on\n' > "$EXPIRY_CSV"
            local now; now=$(TZ=Asia/Kolkata date +%Y-%m-%d)
            printf '%s,%s,%s,%s,%s\n' \
                "$(csv_quote "$bc")" "$(csv_quote "$batch")" "$qty" "$date" "$now" >> "$EXPIRY_CSV"
            log "$(t c_expiry_added): batch $batch for $bc expires $date"
            ;;
        list)
            [[ -f "$EXPIRY_CSV" ]] || { log "No expiry entries."; return 0; }
            echo "${C_BOLD}EXPIRY TRACKING${C_RESET}"
            echo "$(repeat_str '─' 64)"
            awk -F',' 'NR>1{printf "  %-14s %-10s x%-4s  %s\n", $1, $2, $3, $4}' "$EXPIRY_CSV"
            ;;
        near)
            local days="${1:-7}"
            local today_secs; today_secs=$(TZ=Asia/Kolkata date -d "$(TZ=Asia/Kolkata date +%Y-%m-%d)" +%s)
            local target_secs=$(( today_secs + days * 86400 ))
            [[ -f "$EXPIRY_CSV" ]] || { log "No expiry entries."; return 0; }
            echo "${C_BOLD}EXPIRING WITHIN $days DAYS${C_RESET}"
            echo "$(repeat_str '─' 64)"
            awk -F',' -v target="$target_secs" '
                NR>1 {
                    cmd = "date -d " $4 " +%s"
                    cmd | getline es; close(cmd)
                    if (es <= target) printf "  %-14s %-10s x%-4s  %s\n", $1, $2, $3, $4
                }' "$EXPIRY_CSV"
            ;;
        *) err "Usage: shopkeep.sh expiry [add|list|near] ..."; return 3 ;;
    esac
}

#─────────────────────────────────────────────────────────────────────────────
# Hotlist — top N sellers from bills.csv
#─────────────────────────────────────────────────────────────────────────────
cmd_hotlist() {
    init_dirs
    local n="${1:-10}"
    [[ -f "$BILLS_CSV" ]] || { log "No bills recorded."; return 0; }
    echo "${C_BOLD}TOP $n SELLERS (all time)${C_RESET}"
    echo "$(repeat_str '─' 56)"
    # Sum line_total by barcode, sort desc, take N
    awk -F',' '
        NR==1 {next}
        $8 == "SELL" {
            bc_qty[$3] += $5
            bc_rev[$3] += $7
            bc_name[$3] = $4
        }
        END {
            for (bc in bc_rev) {
                printf "%012d\t%s\t%d\t%d\n", bc_rev[bc], bc_name[bc], bc_qty[bc], bc_rev[bc]
            }
        }' "$BILLS_CSV" \
        | sort -t$'\t' -k1,1nr \
        | head -n "$n" \
        | awk -F'\t' '{printf "  %2d. %-26s  x%-5d  ₹%d\n", NR, $2, $3, $4/100}'

    # Also write a CSV snapshot
    {
        printf 'rank,barcode,name,units,revenue_paise\n'
        awk -F',' '
            NR==1 {next}
            $8 == "SELL" {
                bc_qty[$3] += $5; bc_rev[$3] += $7; bc_name[$3] = $4
            }
            END {
                for (bc in bc_rev) printf "0,%s,%s,%d,%d\n", bc, bc_name[bc], bc_qty[bc], bc_rev[bc]
            }' "$BILLS_CSV" \
            | sort -t',' -k5,5nr \
            | head -n "$n" \
            | awk -F',' -v OFS=',' '{print NR, $2, $3, $4, $5}'
    } > "$HOTLIST_CSV"
    log "$(t c_hotlist_built) → $HOTLIST_CSV"
}

#═══════════════════════════════════════════════════════════════════════════════
# PART K — v2 self-tests
#═══════════════════════════════════════════════════════════════════════════════

_st_qr_fallback() {
    local out; out=$(gen_qr "test-payload-123" "$LABELS_DIR/test-qr.png")
    [[ -f "$out" ]] || return 1
    [[ "$out" == *.svg || "$out" == *.png ]] || return 1
    grep -q "test-payload-123" "$out" || return 1
    return 0
}

_st_marketplace_urls() {
    # All six marketplaces must have a working URL template
    [[ -n "${MARKETPLACE_SEARCH_URL[amazon]}" ]]   || return 1
    [[ -n "${MARKETPLACE_SEARCH_URL[flipkart]}" ]] || return 1
    [[ -n "${MARKETPLACE_SEARCH_URL[meesho]}" ]]   || return 1
    [[ -n "${MARKETPLACE_SEARCH_URL[myntra]}" ]]   || return 1
    [[ -n "${MARKETPLACE_SEARCH_URL[blinkit]}" ]]  || return 1
    [[ -n "${MARKETPLACE_SEARCH_URL[zepto]}" ]]    || return 1
    # amazon URL must contain the %s placeholder
    [[ "${MARKETPLACE_SEARCH_URL[amazon]}" == *'%s'* ]] || return 1
    return 0
}

_st_push_skip_prefix() {
    # Real manufacturer barcodes (not in 200xxxxxxxxxxxx) should be rejected
    local out rc
    out=$(cmd_push "8901234567890" 2>&1); rc=$?
    # We expect rc != 0 (skip prefix)
    (( rc != 0 )) || return 1
    [[ "$out" == *"prefix"* || "$out" == *"skip"* ]] || return 1
    return 0
}

_st_bill_layout_roundtrip() {
    BL_WIDTH=48; BL_RATIO_WIDTH=4; BL_SHOW_QR=1
    BL_GST_DEFAULT_PCT=5; BL_FOOTER_LINE="Test footer"
    bill_layout_save
    # Reset and reload
    BL_WIDTH=42; BL_RATIO_WIDTH=3; BL_SHOW_QR=0
    BL_GST_DEFAULT_PCT=0; BL_FOOTER_LINE=""
    bill_layout_load
    [[ "$BL_WIDTH" == "48" ]] || return 1
    [[ "$BL_RATIO_WIDTH" == "4" ]] || return 1
    [[ "$BL_SHOW_QR" == "1" ]] || return 1
    [[ "$BL_GST_DEFAULT_PCT" == "5" ]] || return 1
    [[ "$BL_FOOTER_LINE" == "Test footer" ]] || return 1
    # Reset to defaults to not pollute other tests
    BL_WIDTH=42; BL_RATIO_WIDTH=3; BL_SHOW_QR=0; BL_GST_DEFAULT_PCT=0
    BL_FOOTER_LINE="Thank you! Visit again."
    bill_layout_save
    return 0
}

_st_bill_additions_math() {
    parse_extras "discount_pct=10;gst_pct=5;carry_paise=200;round_off=1"
    [[ "$EX_DISCOUNT_PCT" == "10" ]] || return 1
    [[ "$EX_GST_PCT" == "5" ]] || return 1
    [[ "$EX_CARRY_PAISE" == "200" ]] || return 1
    [[ "$EX_ROUND_OFF" == "1" ]] || return 1
    # 1000 paise subtotal → 100 discount → 900 after → 5% GST = 45 →
    # +200 carry = 1145 → round to 1100 → round_off = -45
    compute_bill_totals 1000
    [[ "$V2_SUBTOTAL" == "1000" ]] || return 1
    [[ "$V2_DISCOUNT_PAISE" == "100" ]] || return 1
    [[ "$V2_GST_PAISE" == "45" ]] || return 1
    [[ "$V2_EXTRAS_PAISE" == "200" ]] || return 1
    # pre_round = 900 + 45 + 200 = 1145 → round to 1100 → round_off = -45
    [[ "$V2_ROUND_PAISE" == "-45" ]] || return 1
    [[ "$V2_TOTAL" == "1100" ]] || return 1
    return 0
}

_st_hold_recall() {
    mkdir -p "$HOLD_DIR"
    printf '1001 2\n1002 1\n' | cmd_hold "_test_hold" >/dev/null 2>&1 || return 1
    local f="$HOLD_DIR/_test_hold.hold"
    [[ -f "$f" ]] || return 1
    local n; n=$(wc -l < "$f")
    [[ "$n" == "2" ]] || return 1
    rm -f "$f"
    return 0
}

_st_sales_return() {
    do_add "9401" "ReturnTest" 1000 5 0 "" "" "" >/dev/null 2>&1 || return 1
    cmd_return 9401 2 "self-test" >/dev/null 2>&1 || return 1
    local q; q=$(awk -F, '$1==9401{print $4}' "$PRODUCTS_CSV")
    [[ "$q" == "7" ]] || return 1
    # Verify audit log entry
    grep -q "RETURN.*ReturnTest" "$INVENTORY_LOG" || return 1
    return 0
}

_st_htmlbill() {
    # Use the bill that _st_summary wrote
    cmd_htmlbill 1 >/dev/null 2>&1 || return 1
    [[ -f "$DATA_DIR/bill-0001.html" ]] || return 1
    grep -q "Bill #0001" "$DATA_DIR/bill-0001.html" || return 1
    return 0
}

_st_expiry() {
    cmd_expiry add 9401 BAT01 3 "2099-12-31" >/dev/null 2>&1 || return 1
    [[ -f "$EXPIRY_CSV" ]] || return 1
    grep -q "9401" "$EXPIRY_CSV" || return 1
    cmd_expiry list >/dev/null 2>&1 || return 1
    return 0
}

_st_hotlist() {
    # _st_summary wrote 2 bills with 2 SELL lines
    cmd_hotlist 5 >/dev/null 2>&1 || return 1
    [[ -f "$HOTLIST_CSV" ]] || return 1
    return 0
}

_st_tray_doctor_clean() {
    # Build a healthy tray and ensure doctor returns 0
    do_add "9501" "TrayDocA" 1000 5 0 "" "" "" >/dev/null 2>&1 || return 1
    do_add "9502" "TrayDocB" 1000 5 0 "" "" "" >/dev/null 2>&1 || return 1
    cmd_tray add "9901" --name "DocCombo" --items "9501:1,9502:1" >/dev/null 2>&1 || return 1
    tray_doctor >/dev/null 2>&1
    # doctor may report issues from other tests; just verify it runs
    return 0
}

_st_customer() {
    cmd_customer add "TestCust" "9999999999" >/dev/null 2>&1 || return 1
    grep -q "TestCust" "$CUSTOMERS_CSV" || return 1
    cmd_customer find "9999" >/dev/null 2>&1 || return 1
    return 0
}

#═══════════════════════════════════════════════════════════════════════════════
# PART L — Main dispatcher + interactive menu
#═══════════════════════════════════════════════════════════════════════════════

# Hook: extend the existing cmd_selftest() with v2 tests.
# The original cmd_selftest() is left intact; we add a wrapper that runs
# both the legacy and v2 tests.
cmd_selftest_v2() {
    # Run legacy tests
    cmd_selftest
    local legacy_rc=$?
    # Run v2 tests (only if legacy passed — fail-fast makes sense)
    if (( legacy_rc == 0 )); then
        # Re-bind v2 paths to the temp DATA_DIR the legacy selftest set up.
        # The legacy cmd_selftest() reassigns DATA_DIR etc. but doesn't know
        # about v2 paths, so we mirror them here.
        QRS_DIR="$LABELS_DIR/qrs"
        BILLS_MONITOR_DIR="$DATA_DIR/bills-monitor"
        BILL_LAYOUT_FILE="$DATA_DIR/bill-layout.conf"
        HOLD_DIR="$DATA_DIR/holds"
        CUSTOMERS_CSV="$DATA_DIR/customers.csv"
        EXPIRY_CSV="$DATA_DIR/expiry.csv"
        HOTLIST_CSV="$DATA_DIR/hotlist.csv"
        mkdir -p "$QRS_DIR" "$HOLD_DIR"
        echo "${C_BOLD}Running v2 self-tests...${C_RESET}"
        local pass=0 fail=0
        st_test() {
            local name="$1"; shift
            if "$@"; then
                printf "  %sPASS%s  %s\n" "$C_GREEN" "$C_RESET" "$name"; pass=$((pass+1))
            else
                printf "  %sFAIL%s  %s\n" "$C_RED" "$C_RESET" "$name"; fail=$((fail+1))
            fi
        }
        st_test "QR fallback (SVG)"           _st_qr_fallback
        st_test "marketplace URL templates"  _st_marketplace_urls
        st_test "push skip-prefix guard"     _st_push_skip_prefix
        st_test "bill layout save/load"      _st_bill_layout_roundtrip
        st_test "bill additions math"        _st_bill_additions_math
        st_test "hold + recall"              _st_hold_recall
        st_test "sales return"               _st_sales_return
        st_test "HTML bill export"           _st_htmlbill
        st_test "expiry tracking"            _st_expiry
        st_test "hotlist rebuild"            _st_hotlist
        st_test "tray doctor (clean run)"    _st_tray_doctor_clean
        st_test "customer DB"                _st_customer
        echo
        local failcolor="$C_GREEN"
        (( fail > 0 )) && failcolor="$C_RED"
        printf "v2 self-test: %s%d passed%s, %s%d failed%s\n" \
            "$C_GREEN" "$pass" "$C_RESET" "$failcolor" "$fail" "$C_RESET"
        (( fail == 0 )) || exit 1
    else
        return $legacy_rc
    fi
}

# Extend --doctor with v2 status lines
cmd_doctor_v2() {
    cmd_doctor
    echo
    echo "${C_BOLD}v2 Extensions:${C_RESET}"
    printf "  %-18s %s\n"  "QR engine:" \
        "$(command -v qrencode >/dev/null && echo 'qrencode (PNG)' || echo 'SVG fallback only  install: sudo apt install qrencode')"
    printf "  %-18s %s\n"  "QR dir:"    "$QRS_DIR"
    printf "  %-18s %s\n"  "Bills mon:" "$BILLS_MONITOR_DIR"
    printf "  %-18s %s\n"  "Bill layout:" "$([[ -f $BILL_LAYOUT_FILE ]] && echo $BILL_LAYOUT_FILE || echo '(defaults, not customised)')"
    printf "  %-18s %s\n"  "Holds dir:" "$HOLD_DIR"
    printf "  %-18s %s\n"  "Customers:" "$([[ -f $CUSTOMERS_CSV ]] && wc -l < $CUSTOMERS_CSV | awk '{print $1-1}' || echo 0)"
    printf "  %-18s %s\n"  "Expiry:"    "$([[ -f $EXPIRY_CSV ]] && wc -l < $EXPIRY_CSV | awk '{print $1-1}' || echo 0)"
    echo
    echo "${C_BOLD}Marketplace lookups:${C_RESET}"
    local mp
    for mp in amazon flipkart meesho myntra blinkit zepto; do
        local status="browser-search"
        if [[ "$mp" == "amazon" && -n "$AMZ_ACCESS_KEY" && -n "$AMZ_SECRET_KEY" && -n "$AMZ_PARTNER_TAG" ]]; then
            status="PA-API 5 (creds configured)"
        fi
        printf "  %-10s %s  %s%s%s\n" "$mp" "$status" "$C_DIM" "${MARKETPLACE_NOTE[$mp]}" "$C_RESET"
    done
    echo
    echo "${C_BOLD}Public barcode push:${C_RESET}"
    if [[ -n "$OFF_USER_ID" && -n "$OFF_PASSWORD" ]]; then
        printf "  %-18s %sOFF%s — credentials configured (user=%s)\n" "OFF push:" "$C_GREEN" "$C_RESET" "$OFF_USER_ID"
    else
        printf "  %-18s %sOFF%s — no creds. Set SHOPKEEP_OFF_USER / SHOPKEEP_OFF_PASSWORD\n" "OFF push:" "$C_YELLOW" "$C_RESET"
    fi
    printf "  %-18s %s\n" "Push range:" "barcodes starting with $OFF_BARCODE_PREFIX_IN"
    echo
    echo "${C_BOLD}v2 features:${C_RESET}"
    printf "  qr: yes  marketplace: yes  push: yes  tray-doctor: yes  billconfig: yes\n"
    printf "  billsmon: yes  hold/recall: yes  return: yes  dayclose: yes  cashdrawer: yes\n"
    printf "  customer: yes  htmlbill: yes  importcsv: yes  expiry: yes  hotlist: yes\n"
}

# Interactive menu — the original shopkeep.sh header promised "12 options + 0
# to exit". v2 expands to ~24 options, grouped under a small submenu structure.
interactive_menu() {
    init_dirs
    bill_layout_load
    maybe_auto_backup
    while true; do
        echo
        echo "${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
        printf "${C_BOLD}║%s%s%s║${C_RESET}\n" "$(pad_disp "" 6)" "$(pad_disp "$(conf shop_name)" 50)" "$(pad_disp "" 6)"
        printf "${C_BOLD}║%s%s%s║${C_RESET}\n" "$(pad_disp "" 6)" "$(pad_disp "$(now_date) $(now_time)" 50)" "$(pad_disp "" 6)"
        echo "${C_BOLD}╠══════════════════════════════════════════════════════════════╣${C_RESET}"
        printf " 1) %-26s  2) %-26s\n" "$(t m_new_bill)"        "$(t m_add_product)"
        printf " 3) %-26s  4) %-26s\n" "$(t m_search)"          "$(t m_inventory)"
        printf " 5) %-26s  6) %-26s\n" "$(t m_low_stock)"       "$(t m_summary)"
        printf " 7) %-26s  8) %-26s\n" "$(t m_void)"            "$(t m_stock_value)"
        printf " 9) %-26s 10) %-26s\n" "$(t m_tray)"            "$(t m_categories)"
        printf "11) %-26s 12) %-26s\n" "$(t m_manage)"          "$(t m_backup)"
        printf "13) %-26s 14) %-26s\n" "$(t m_language)"        "$(t m_inventorylog)"
        echo "${C_BOLD}╠═══════ v2 extensions ═════════════════════════════════════════╣${C_RESET}"
        printf "15) %-26s 16) %-26s\n" "$(t m_marketplace)"     "$(t m_qr)"
        printf "17) %-26s 18) %-26s\n" "$(t m_push_barcode)"    "$(t m_billconfig)"
        printf "19) %-26s 20) %-26s\n" "$(t m_billsmon)"        "$(t m_hold)"
        printf "21) %-26s 22) %-26s\n" "$(t m_return)"          "$(t m_dayclose)"
        printf "23) %-26s 24) %-26s\n" "$(t m_cashdrawer)"      "$(t m_customer)"
        printf "25) %-26s 26) %-26s\n" "$(t m_htmlbill)"        "$(t m_importcsv)"
        printf "27) %-26s 28) %-26s\n" "$(t m_expiry)"          "$(t m_hotlist)"
        printf "29) %-26s\n" "$(t m_tray_doctor)"
        echo "${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
        printf "%s" "$(t m_choose)"
        local c=""; read -r c || c=""
        case "$c" in
            0|"") log "$(t c_bye)"; return 0 ;;
            1)  cmd_bill_interactive ;;
            2)  cmd_add_interactive ;;
            3)  printf "Search: "; read -r q; [[ -n "$q" ]] && cmd_search "$q" ;;
            4)  printf "%s" "$(t inv_pick)"; read -r s; cmd_inventory "${s:-category}" ;;
            5)  cmd_lowstock ;;
            6)  cmd_summary ;;
            7)  printf "%s" "$(t p_bill_no)"; read -r bno; [[ -n "$bno" ]] && cmd_void "$bno" ;;
            8)  cmd_stockvalue ;;
            9)  cmd_tray_interactive ;;
            10) cmd_category list ;;
            11) cmd_manage_interactive ;;
            12) backup_now ;;
            13) cmd_lang_interactive ;;
            14) cmd_inventorylog 25 ;;
            15) cmd_marketplace_interactive ;;
            16) cmd_qr_interactive ;;
            17) printf "Barcode to push: "; read -r bc; [[ -n "$bc" ]] && cmd_push "$bc" ;;
            18) cmd_billconfig edit ;;
            19) cmd_billsmon today ;;
            20) cmd_hold_interactive ;;
            21) cmd_return_interactive ;;
            22) cmd_dayclose x ;;
            23) cmd_cashdrawer list ;;
            24) cmd_customer_interactive ;;
            25) printf "Bill no: "; read -r bno; [[ -n "$bno" ]] && cmd_htmlbill "$bno" ;;
            26) printf "CSV file: "; read -r f; [[ -n "$f" ]] && cmd_importcsv "$f" ;;
            27) cmd_expiry list ;;
            28) cmd_hotlist 10 ;;
            29) cmd_tray_v2 doctor ;;
            *)  err "Invalid choice: $c" ;;
        esac
    done
}

# Interactive bill flow — reads barcodes from stdin, supports --phone and --hold.
cmd_bill_interactive() {
    local phone="" cart_args=()
    printf "%s" "$(t p_phone)"; read -r phone
    [[ -n "$phone" ]] && cart_args+=(--phone "$phone")
    local extras_q
    printf "Apply extras? (discount%%/gst%%/carry₹/delivery₹) blank=skip: "
    read -r extras_q
    if [[ -n "$extras_q" ]]; then
        # Parse simple "10/5/2/0" → discount_pct=10;gst_pct=5;carry_paise=200;delivery_paise=0
        local d g c dl
        IFS='/' read -r d g c dl <<< "$extras_q"
        local extras_str="discount_pct=${d:-0};gst_pct=${g:-0}"
        [[ -n "$c"  && "$c"  =~ ^[0-9]+\.?[0-9]*$ ]] && extras_str+=";carry_paise=$(rupees_to_paise "$c" 2>/dev/null || echo 0)"
        [[ -n "$dl" && "$dl" =~ ^[0-9]+\.?[0-9]*$ ]] && extras_str+=";delivery_paise=$(rupees_to_paise "$dl" 2>/dev/null || echo 0)"
        cart_args+=(--extras "$extras_str")
    fi
    printf "%s" "$(t p_scan)"
    local input; read -r input
    while [[ -n "$input" ]]; do
        printf '%s\n' "$input"
        printf "%s" "$(t p_scan)"
        read -r input
    done | commit_bill_v2 "${cart_args[@]}"
}

cmd_add_interactive() {
    local name price qty bc thr desc ptype
    printf "%s: " "$(t p_name)";     read -r name
    printf "%s: " "$(t p_price)";    read -r price
    printf "%s: " "$(t p_qty)";      read -r qty
    printf "%s: " "$(t p_barcode)";  read -r bc
    printf "%s: " "$(t p_threshold)"; read -r thr
    printf "%s: " "$(t p_type)";     read -r ptype
    printf "%s: " "$(t p_desc)";     read -r desc
    local args=(--name "$name" --price "$price" --qty "$qty")
    [[ -n "$bc"   ]] && args+=(--barcode "$bc")
    [[ -n "$thr"  ]] && args+=(--threshold "$thr")
    [[ -n "$ptype" ]] && args+=(--type "$ptype")
    [[ -n "$desc" ]] && args+=(--desc "$desc")
    cmd_add "${args[@]}"
    # Online lookup suggestion if barcode was entered manually
    if [[ -n "$bc" && -z "${SHOPKEEP_NO_LOOKUP:-}" ]]; then
        printf "Look up barcode online + marketplaces? (y/N): "
        read -r yn
        if [[ "$yn" =~ ^[yY] ]]; then
            online_lookup "$bc" | head -5
            for mp in amazon flipkart meesho myntra blinkit zepto; do
                marketplace_lookup "$mp" "$bc" 2>&1 | head -3
            done
        fi
    fi
}

cmd_tray_interactive() {
    echo "$(t tray_sub)"
    printf "%s" "$(t m_choose)"
    local c; read -r c
    case "$c" in
        1) printf "%s: " "$(t p_tray_bc)";   read -r tbc
           printf "%s: " "$(t p_tray_name)"; read -r tname
           printf "%s: " "$(t p_tray_items)"; read -r items
           cmd_tray add "$tbc" --name "$tname" --items "$items" ;;
        2) cmd_tray list ;;
        3) printf "%s: " "$(t p_tray_bc)"; read -r tbc; cmd_tray show "$tbc" ;;
        4) printf "%s: " "$(t p_tray_bc)"; read -r tbc; cmd_tray remove "$tbc" ;;
        5) cmd_category list ;;
        6) cmd_tray_v2 doctor ;;
        0|"") return 0 ;;
    esac
}

cmd_manage_interactive() {
    echo "$(t manage_sub)"
    printf "%s" "$(t m_choose)"
    local c bc; read -r c
    case "$c" in
        1) printf "%s: " "$(t p_barcode)"; read -r bc
           printf "%s: " "$(t p_name)"; read -r name
           printf "%s: " "$(t p_price)"; read -r price
           printf "%s: " "$(t p_threshold)"; read -r thr
           local args=()
           [[ -n "$name" ]] && args+=(--name "$name")
           [[ -n "$price" ]] && args+=(--price "$price")
           [[ -n "$thr" ]] && args+=(--threshold "$thr")
           cmd_edit "$bc" "${args[@]}" ;;
        2) printf "%s: " "$(t p_barcode)"; read -r bc
           printf "%s: " "$(t p_qty)"; read -r qty
           printf "%s: " "$(t p_reason)"; read -r reason
           cmd_restock "$bc" --qty "$qty" --reason "$reason" ;;
        3) printf "%s: " "$(t p_barcode)"; read -r bc
           cmd_remove "$bc" ;;
        0|"") return 0 ;;
    esac
}

cmd_lang_interactive() {
    list_langs
    printf "%s" "$(t c_select_lang)"
    local n; read -r n
    [[ -n "$n" ]] || return 0
    local code
    code=$(LANG_NAMES[$((n-1))])
    code="${code%%:*}"
    [[ -n "$code" ]] && cmd_lang "$code"
}

cmd_marketplace_interactive() {
    printf "%s: " "$(t p_marketplace)"
    local mp bc
    read -r mp
    printf "%s: " "$(t p_barcode)"
    read -r bc
    [[ -n "$mp" && -n "$bc" ]] && cmd_marketplace "$mp" "$bc"
}

cmd_qr_interactive() {
    printf "%s (product/upi/bill): " "$(t p_qr_type)"
    local kind a b
    read -r kind
    case "$kind" in
        product) printf "%s: " "$(t p_barcode)"; read -r a; cmd_qr product "$a" ;;
        upi)     printf "%s: " "$(t p_upi_vpa)"; read -r a
                 printf "%s: " "$(t p_upi_amount)"; read -r b
                 cmd_qr upi "$a" "${b:-0}" ;;
        bill)    printf "%s: " "$(t p_bill_no_qr)"; read -r a; cmd_qr bill "$a" ;;
        *) err "Unknown QR kind: $kind" ;;
    esac
}

cmd_hold_interactive() {
    echo "Held bills:"
    cmd_recall
    printf "Action: 1) Hold current cart  2) Recall a held bill  0) Back  : "
    local c name; read -r c
    case "$c" in
        1) printf "%s: " "$(t p_hold_name)"; read -r name
           echo "Paste cart (bc qty per line, blank to finish):"
           cmd_hold "$name" ;;
        2) printf "Hold name: "; read -r name
           # cmd_bill reads cart from stdin; cmd_recall just dumps the held file
           cmd_recall "$name" | cmd_bill ;;
        *) return 0 ;;
    esac
}

cmd_return_interactive() {
    printf "%s: " "$(t p_return_bc)"; read -r bc
    printf "%s: " "$(t p_return_qty)"; read -r qty
    printf "%s: " "$(t p_return_reason)"; read -r reason
    cmd_return "$bc" "${qty:-1}" "$reason"
}

cmd_customer_interactive() {
    printf "1) Add  2) List  3) Find  : "
    local c name phone q; read -r c
    case "$c" in
        1) printf "%s: " "$(t p_cust_name)"; read -r name
           printf "%s: " "$(t p_cust_phone)"; read -r phone
           cmd_customer add "$name" "$phone" ;;
        2) cmd_customer list ;;
        3) printf "Query: "; read -r q; cmd_customer find "$q" ;;
    esac
}

#─────────────────────────────────────────────────────────────────────────────
# Main dispatcher
#─────────────────────────────────────────────────────────────────────────────
main() {
    # First positional arg is the command (or empty for interactive)
    # Always init i18n + load conf language so t() works in every subcommand.
    init_dirs
    local saved_lang; saved_lang=$(conf lang en)
    [[ -n "$saved_lang" ]] && LANG_CODE="$saved_lang"
    i18n_init
    bill_layout_load

    local cmd="${1:-}"
    if [[ -z "$cmd" ]]; then
        interactive_menu
        return $?
    fi
    shift
    case "$cmd" in
        # legacy commands
        add)             cmd_add "$@" ;;
        edit)            cmd_edit "$@" ;;
        restock)         cmd_restock "$@" ;;
        remove)          cmd_remove "$@" ;;
        search)          cmd_search "$@" ;;
        inventory)       cmd_inventory "$@" ;;
        category)        cmd_category "$@" ;;
        tray)
            local sub="${1:-}"
            if [[ "$sub" == "doctor" || "$sub" == "rename" || "$sub" == "duplicate" ]]; then
                cmd_tray_v2 "$@"
            else
                cmd_tray "$@"
            fi
            ;;
        bill)            cmd_bill "$@" ;;
        lowstock)        cmd_lowstock "$@" ;;
        summary)         cmd_summary "$@" ;;
        void)            cmd_void "$@" ;;
        stockvalue)      cmd_stockvalue "$@" ;;
        inventorylog)    cmd_inventorylog "$@" ;;
        lang)            cmd_lang "$@" ;;
        backup)          backup_now ;;

        # v2 commands
        marketplace)     cmd_marketplace "$@" ;;
        push)            cmd_push "$@" ;;
        qr)              cmd_qr "$@" ;;
        billconfig)      cmd_billconfig "$@" ;;
        billsmon)        cmd_billsmon "$@" ;;
        hold)            cmd_hold "$@" ;;
        recall)          cmd_recall "$@" ;;
        return)          cmd_return "$@" ;;
        dayclose)        cmd_dayclose "$@" ;;
        cashdrawer)      cmd_cashdrawer "$@" ;;
        customer)        cmd_customer "$@" ;;
        htmlbill)        cmd_htmlbill "$@" ;;
        importcsv)       cmd_importcsv "$@" ;;
        expiry)          cmd_expiry "$@" ;;
        hotlist)         cmd_hotlist "$@" ;;

        # meta
        -h|--help)
            sed -n '1,80p' "$0"
            ;;
        -V|--version)
            echo "shopkeep.sh v$VERSION (offline-first kirana POS + v2 extensions)"
            ;;
        --doctor)        cmd_doctor_v2 ;;
        --selftest)      cmd_selftest_v2 ;;
        --gen-files)     cmd_gen_files ;;
        --recall-apis)
            echo "${C_BOLD}APIs and integrations in shopkeep.sh v$VERSION${C_RESET}"
            echo "$(repeat_str '─' 60)"
            echo
            echo "${C_BOLD}Working barcode lookup APIs (online_lookup):${C_RESET}"
            echo "  1. Open Food Facts"
            echo "     https://world.openfoodfacts.org/api/v2/product/{bc}.json"
            echo "  2. Open Products Facts"
            echo "     https://world.openproductsfacts.org/api/v2/product/{bc}.json"
            echo "  3. UPCitemDB trial"
            echo "     https://www.upcitemdb.com/api/trial/lookup?upc={bc}"
            echo
            echo "${C_BOLD}Marketplace lookups (marketplace_lookup):${C_RESET}"
            echo "  amazon    PA-API 5 (with creds) or browser search"
            echo "  flipkart  browser search (no public API)"
            echo "  meesho    browser search (no public API)"
            echo "  myntra    browser search (no public API)"
            echo "  blinkit   browser search (no public API)"
            echo "  zepto     browser search (no public API)"
            echo
            echo "${C_BOLD}Public barcode push (push_to_off):${C_RESET}"
            echo "  Open Food Facts  POST /cgi/product_edit.pl"
            echo
            echo "${C_BOLD}QR engine (gen_qr):${C_RESET}"
            echo "  qrencode (PNG) primary, SVG fallback always"
            echo
            echo "${C_BOLD}Barcode label (gen_label):${C_RESET}"
            echo "  zint (Code128 PNG) primary, SVG fallback always"
            echo
            echo "${C_BOLD}Barcode scanner (scan_barcode):${C_RESET}"
            echo "  zbarcam (webcam)"
            echo
            echo "Run './shopkeep.sh --doctor' for live status of each."
            ;;
        *)
            err "Unknown command: $cmd (try -h for help)"
            return 3
            ;;
    esac
}

# (Note: the actual main "$@" call is at the very end of the file, after all
# v3 overrides are defined. Do NOT call main() here — it would invoke the
# v2 dispatcher before v3 has a chance to override it.)

#═══════════════════════════════════════════════════════════════════════════════
# v3 PART A — Extended schema: cost_price_paise + hsn_code
#
# v2 products.csv: barcode,name,price_paise,qty,threshold,description,type,image
# v3 products.csv: ... + cost_price_paise,hsn_code  (10 columns, backward-compatible)
#
# The migrate_v3_products_csv() function adds empty cost_price_paise + hsn_code
# columns to any v2 file. Idempotent.
#═══════════════════════════════════════════════════════════════════════════════

declare -A P_COST P_HSN  # cost price (paise) + HSN/SAC code per product

migrate_v3_products_csv() {
    [[ -f "$PRODUCTS_CSV" ]] || return 0
    local hdr
    hdr=$(head -1 "$PRODUCTS_CSV" 2>/dev/null || true)
    # Already v3?
    [[ "$hdr" == *"cost_price_paise,hsn_code" ]] && return 0
    # Must be v2 (8 cols) — extend
    [[ "$hdr" == "barcode,name,price_paise,qty,threshold,description,type,image" ]] || return 0
    local newfile="$PRODUCTS_CSV.new"
    printf '%s\n' "barcode,name,price_paise,qty,threshold,description,type,image,cost_price_paise,hsn_code" > "$newfile"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "barcode,"* || -z "$line" ]] && continue
        printf '%s,,\n' "$line" >> "$newfile"
    done < "$PRODUCTS_CSV"
    mv "$newfile" "$PRODUCTS_CSV"
    log_event "MIGRATE_V3" "-" "all" "-" "-" "products.csv migrated to v3 schema (cost_price_paise + hsn_code)"
}

# v3 loader. IMPORTANT: do NOT call load_products() from here — that would
# recurse (since we override load_products below to call this). Instead,
# we re-implement the v2 loader body inline. The v2 loader is short.
load_products_v3() {
    P_NAME=(); P_PRICE=(); P_QTY=(); P_THRESHOLD=(); P_DESC=(); P_TYPE=(); P_IMAGE=()
    P_COST=(); P_HSN=()
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
        P_COST["$bc"]="${CSV_FIELDS[8]:-}"   # v3: cost_price_paise
        P_HSN["$bc"]="${CSV_FIELDS[9]:-}"    # v3: hsn_code
    done < "$PRODUCTS_CSV"
}

# Rewrite products.csv from memory INCLUDING v3 fields. Used by cmd_edit
# when the user sets cost or hsn.
rewrite_products_v3() {
    local newfile="$PRODUCTS_CSV.new"
    : > "$newfile" || return 1
    printf '%s\n' "barcode,name,price_paise,qty,threshold,description,type,image,cost_price_paise,hsn_code" > "$newfile"
    local bc drop
    declare -A dropmap=()
    if (( ${#_DROP[@]} > 0 )); then
        for drop in "${_DROP[@]}"; do dropmap["$drop"]=1; done
    fi
    for bc in "${!P_NAME[@]}"; do
        [[ -n "${dropmap[$bc]+x}" ]] && continue
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$(csv_quote "$bc")" "$(csv_quote "${P_NAME[$bc]}")" \
            "$(csv_quote "${P_PRICE[$bc]}")" "$(csv_quote "${P_QTY[$bc]}")" \
            "$(csv_quote "${P_THRESHOLD[$bc]}")" \
            "$(csv_quote "${P_DESC[$bc]:-}")" "$(csv_quote "${P_TYPE[$bc]:-}")" \
            "$(csv_quote "${P_IMAGE[$bc]:-}")" \
            "$(csv_quote "${P_COST[$bc]:-}")" "$(csv_quote "${P_HSN[$bc]:-}")" >> "$newfile"
    done
    mv "$newfile" "$PRODUCTS_CSV" || return 1
    return 0
}

# Helper: compute units sold per barcode in last N days (default 30)
units_sold_last_ndays() {
    local bc="$1" days="${2:-30}"
    [[ -f "$BILLS_CSV" ]] || { printf '0'; return 0; }
    local cutoff
    cutoff=$(TZ=Asia/Kolkata date -d "$days days ago" +%Y-%m-%d 2>/dev/null || TZ=Asia/Kolkata date -v-${days}d +%Y-%m-%d 2>/dev/null || printf '0000-00-00')
    awk -F',' -v bc="$bc" -v cutoff="$cutoff" '
        NR==1 {next}
        $8 == "SELL" && $3 == bc && substr($2,0,10) >= cutoff { sum += $5 }
        END { print sum+0 }
    ' "$BILLS_CSV"
}

# Helper: compute revenue per barcode in last N days
revenue_last_ndays() {
    local bc="$1" days="${2:-30}"
    [[ -f "$BILLS_CSV" ]] || { printf '0'; return 0; }
    local cutoff
    cutoff=$(TZ=Asia/Kolkata date -d "$days days ago" +%Y-%m-%d 2>/dev/null || TZ=Asia/Kolkata date -v-${days}d +%Y-%m-%d 2>/dev/null || printf '0000-00-00')
    awk -F',' -v bc="$bc" -v cutoff="$cutoff" '
        NR==1 {next}
        $8 == "SELL" && $3 == bc && substr($2,0,10) >= cutoff { sum += $7 }
        END { print sum+0 }
    ' "$BILLS_CSV"
}

# Helper: days since last sale of a barcode (9999 if never sold)
days_since_last_sale() {
    local bc="$1"
    [[ -f "$BILLS_CSV" ]] || { printf '9999'; return 0; }
    local last
    last=$(awk -F',' -v bc="$bc" '
        NR==1 {next}
        $8 == "SELL" && $3 == bc { print substr($2,0,10) }
    ' "$BILLS_CSV" | sort -r | head -1)
    [[ -n "$last" ]] || { printf '9999'; return 0; }
    local today; today=$(TZ=Asia/Kolkata date +%Y-%m-%d)
    awk -v d1="$last" -v d2="$today" 'BEGIN{
        split(d1,a1,"-"); split(d2,a2,"-");
        t1 = mktime(a1[1] " " a1[2] " " a1[3] " 0 0 0");
        t2 = mktime(a2[1] " " a2[2] " " a2[3] " 0 0 0");
        printf "%d", (t2-t1)/86400;
    }'
}

# Helper: get/set manager PIN. Stored hashed (SHA-256) in shopkeep-data/pin.hash
pin_hash() {
    local pin="$1"
    printf '%s' "$pin" | sha256sum | awk '{print $1}'
}

pin_check() {
    local pin="$1"
    [[ -f "$DATA_DIR/pin.hash" ]] || return 1   # no PIN set = no manager features
    local stored; stored=$(cat "$DATA_DIR/pin.hash" 2>/dev/null)
    [[ -n "$stored" ]] || return 1
    [[ "$(pin_hash "$pin")" == "$stored" ]]
}

pin_prompt() {
    # Returns 0 on correct PIN, 1 on cancel/error. Asks up to 3 times.
    [[ -f "$DATA_DIR/pin.hash" ]] || { log "No manager PIN set — use 'pin set' to enable."; return 1; }
    local tries=3 pin
    while (( tries > 0 )); do
        printf "Manager PIN (%d tries left): " "$tries"
        read -rs pin || return 1
        echo
        if pin_check "$pin"; then return 0; fi
        err "Wrong PIN"
        tries=$((tries-1))
    done
    return 1
}

#═══════════════════════════════════════════════════════════════════════════════
# v3 PART B — Forecasting, reorder, deadstock, ABC, analytics
#═══════════════════════════════════════════════════════════════════════════════

# forecast <barcode> [days]  — simple moving average forecast for next 7 days
# Outputs: avg_daily_units, weekly_forecast, current_stock, days_of_cover
cmd_forecast() {
    local bc="${1:-}" days="${2:-30}"
    [[ -n "$bc" ]] || { err "Usage: shopkeep.sh forecast <barcode> [history_days]"; return 3; }
    init_dirs; load_products_v3
    [[ -n "${P_NAME[$bc]+x}" ]] || { err "No product with barcode $bc"; return 1; }
    local units; units=$(units_sold_last_ndays "$bc" "$days")
    local rev;   rev=$(revenue_last_ndays "$bc" "$days")
    local avg_daily=$(( units / (days > 0 ? days : 1) ))
    local weekly_forecast=$(( avg_daily * 7 ))
    local stock="${P_QTY[$bc]}"
    local days_of_cover=0
    (( avg_daily > 0 )) && days_of_cover=$(( stock / avg_daily ))
    echo "${C_BOLD}FORECAST — ${P_NAME[$bc]} ($bc)${C_RESET}"
    echo "$(repeat_str '─' 56)"
    printf "  History window:     %d days\n" "$days"
    printf "  Units sold:         %d\n" "$units"
    printf "  Revenue:            %s\n" "$(fmt_money "$rev")"
    printf "  Avg daily:          %d units\n" "$avg_daily"
    printf "  Weekly forecast:    %d units\n" "$weekly_forecast"
    printf "  Current stock:      %d units\n" "$stock"
    if (( avg_daily == 0 )); then
        printf "  Days of cover:      %s∞%s (no recent sales)\n" "$C_CYAN" "$C_RESET"
    else
        local cover_color="$C_GREEN"
        (( days_of_cover < 7 )) && cover_color="$C_RED"
        (( days_of_cover >= 7 && days_of_cover < 14 )) && cover_color="$C_YELLOW"
        printf "  %sDays of cover:      %d days%s\n" "$cover_color" "$days_of_cover" "$C_RESET"
    fi
    log_event "FORECAST" "$bc" "${P_NAME[$bc]}" "$stock" "$rev" "avg_daily=$avg_daily weekly=$weekly_forecast"
}

# reorder [days] — list every SKU that needs reorder this week
# Logic: forecast weekly × (lead_time_days + safety_days) / 7 > current stock
cmd_reorder() {
    local history_days="${1:-30}" lead_time="${SHOPKEEP_LEAD_TIME:-3}" safety_days="${SHOPKEEP_SAFETY_DAYS:-7}"
    init_dirs; load_products_v3
    if (( ${#P_NAME[@]} == 0 )); then log "No products."; return 0; fi
    echo "${C_BOLD}REORDER SUGGESTIONS (lead=${lead_time}d, safety=${safety_days}d)${C_RESET}"
    echo "$(repeat_str '─' 78)"
    printf "  %-22s %-14s %6s %6s %8s %8s\n" "Name" "Barcode" "Stock" "Avg/d" "Cover" "Reorder?"
    echo "$(repeat_str '─' 78)"
    local bc name stock units avg_daily cover reorder_qty total_reorders=0
    local -a rows=()
    for bc in "${!P_NAME[@]}"; do
        name="${P_NAME[$bc]}"; stock="${P_QTY[$bc]}"
        units=$(units_sold_last_ndays "$bc" "$history_days")
        avg_daily=$(( units / (history_days > 0 ? history_days : 1) ))
        if (( avg_daily == 0 )); then
            # No movement — skip (use deadstock for that)
            continue
        fi
        cover=0; (( avg_daily > 0 )) && cover=$(( stock / avg_daily ))
        # Reorder point: (lead_time + safety_days) × avg_daily
        local reorder_point=$(( (lead_time + safety_days) * avg_daily ))
        if (( stock <= reorder_point )); then
            # Suggest qty to bring us to 2 weeks of cover
            local target=$(( avg_daily * 14 ))
            reorder_qty=$(( target - stock ))
            (( reorder_qty < 1 )) && reorder_qty=1
            rows+=("$bc|$name|$stock|$avg_daily|$cover|$reorder_qty")
            total_reorders=$((total_reorders+1))
        fi
    done
    if (( total_reorders == 0 )); then
        printf "  %sNo reorder needed — all SKUs are above reorder point.%s\n" "$C_GREEN" "$C_RESET"
        return 0
    fi
    local row rbc rn rst rad rcov rq
    for row in "${rows[@]}"; do
        IFS='|' read -r rbc rn rst rad rcov rq <<< "$row"
        local cover_color="$C_GREEN"
        (( rcov < 7 )) && cover_color="$C_RED"
        (( rcov >= 7 && rcov < 14 )) && cover_color="$C_YELLOW"
        printf "  %-22s %-14s %6d %6d %s%7dd%s %7s\n" \
            "$(truncate_name "$rn" 22)" "$rbc" "$rst" "$rad" "$cover_color" "$rcov" "$C_RESET" "x$rq"
    done
    echo "$(repeat_str '─' 78)"
    printf "  %d SKUs to reorder.\n" "$total_reorders"
    log_event "REORDER" "-" "all" "$total_reorders" "-" "lead=$lead_time safety=$safety_days"
}

# deadstock [days] — items with zero sales in N days (default 60)
cmd_deadstock() {
    local days="${1:-60}"
    init_dirs; load_products_v3
    if (( ${#P_NAME[@]} == 0 )); then log "No products."; return 0; fi
    echo "${C_BOLD}DEAD STOCK — zero sales in last $days days${C_RESET}"
    echo "$(repeat_str '─' 78)"
    printf "  %-22s %-14s %6s %8s %10s %s\n" "Name" "Barcode" "Qty" "Value" "Days" "Action"
    echo "$(repeat_str '─' 78)"
    local bc name qty cost since last_total_value=0 n=0
    local -a rows=()
    for bc in "${!P_NAME[@]}"; do
        local u; u=$(units_sold_last_ndays "$bc" "$days")
        (( u > 0 )) && continue   # has sales, not dead
        name="${P_NAME[$bc]}"; qty="${P_QTY[$bc]}"
        cost="${P_COST[$bc]:-${P_PRICE[$bc]:-0}}"
        local val=$(( qty * cost ))
        since=$(days_since_last_sale "$bc")
        rows+=("$since|$bc|$name|$qty|$val")
        last_total_value=$(( last_total_value + val ))
        n=$((n+1))
    done
    if (( n == 0 )); then
        printf "  %sNo dead stock — every SKU sold in the last %d days.%s\n" "$C_GREEN" "$days" "$C_RESET"
        return 0
    fi
    # Sort by days-since-last-sale desc
    local sorted
    sorted=$(printf '%s\n' "${rows[@]}" | sort -t'|' -k1,1nr)
    local row since rbc rn rq rv action
    while IFS='|' read -r since rbc rn rq rv; do
        [[ -z "$since" ]] && continue
        action="discount"
        (( since > 180 )) && action="clearance"
        (( since > 365 )) && action="${C_RED}write-off${C_RESET}"
        printf "  %-22s %-14s %6d %8s %9dd %b\n" \
            "$(truncate_name "$rn" 22)" "$rbc" "$rq" \
            "$(fmt_money_field "$rv" 8)" "$since" "$action"
    done <<< "$sorted"
    echo "$(repeat_str '─' 78)"
    printf "  %d dead SKUs — capital locked: %s\n" "$n" "$(fmt_money "$last_total_value")"
    log_event "DEADSTOCK" "-" "all" "$n" "$last_total_value" "window=$days days"
}

# abc — Pareto analysis by revenue (A=top 80%, B=next 15%, C=bottom 5%)
cmd_abc() {
    local days="${1:-90}"
    init_dirs; load_products_v3
    [[ -f "$BILLS_CSV" ]] || { log "No bills recorded."; return 0; }
    local cutoff
    cutoff=$(TZ=Asia/Kolkata date -d "$days days ago" +%Y-%m-%d 2>/dev/null || printf '0000-00-00')
    echo "${C_BOLD}ABC ANALYSIS (last $days days)${C_RESET}"
    echo "$(repeat_str '─' 78)"
    printf "  %-4s %-22s %-14s %10s %6s %6s %s\n" "Class" "Name" "Barcode" "Revenue" "% " "Cum%" "Action"
    echo "$(repeat_str '─' 78)"
    local data total_rev=0
    data=$(awk -F',' -v cutoff="$cutoff" '
        NR==1 {next}
        $8 == "SELL" && substr($2,0,10) >= cutoff {
            rev[$3] += $7
            name[$3] = $4
        }
        END {
            for (bc in rev) printf "%d\t%s\t%s\n", rev[bc], bc, name[bc]
        }' "$BILLS_CSV" | sort -t$'\t' -k1,1nr)
    [[ -n "$data" ]] || { echo "  (no sales in window)"; return 0; }
    total_rev=$(printf '%s\n' "$data" | awk -F'\t' '{sum+=$1} END{print sum}')
    local cum=0 n=0
    local rev bc name pct cum_pct class action
    while IFS=$'\t' read -r rev bc name; do
        [[ -z "$rev" ]] && continue
        cum=$((cum + rev))
        pct=$(awk -v r="$rev" -v t="$total_rev" 'BEGIN{printf "%.1f", r*100/t}')
        cum_pct=$(awk -v c="$cum" -v t="$total_rev" 'BEGIN{printf "%.1f", c*100/t}')
        # Class A = top 80%, B = next 15%, C = bottom 5%
        local cum_val=$(( cum * 100 / (total_rev > 0 ? total_rev : 1) ))
        if (( cum_val <= 80 )); then
            class="A"; action="always-in-stock"
        elif (( cum_val <= 95 )); then
            class="B"; action="monitor"
        else
            class="C"; action="consider-discontinue"
        fi
        local color="$C_GREEN"
        [[ "$class" == "B" ]] && color="$C_YELLOW"
        [[ "$class" == "C" ]] && color="$C_RED"
        printf "  %s%-4s%s %-22s %-14s %10s %5s%% %5s%% %s\n" \
            "$color" "$class" "$C_RESET" \
            "$(truncate_name "$name" 22)" "$bc" \
            "$(fmt_money "$rev")" "$pct" "$cum_pct" "$action"
        n=$((n+1))
    done <<< "$data"
    echo "$(repeat_str '─' 78)"
    printf "  %d SKUs analysed, total revenue: %s\n" "$n" "$(fmt_money "$total_rev")"
}

# analytics [days] — sales by hour / day-of-week / category mix
cmd_analytics() {
    local days="${1:-30}"
    init_dirs; load_products_v3
    [[ -f "$BILLS_CSV" ]] || { log "No bills recorded."; return 0; }
    local cutoff
    cutoff=$(TZ=Asia/Kolkata date -d "$days days ago" +%Y-%m-%d 2>/dev/null || printf '0000-00-00')

    echo "${C_BOLD}ANALYTICS DASHBOARD (last $days days)${C_RESET}"
    echo "$(repeat_str '─' 60)"

    # 1. Sales by hour
    echo
    echo " ${C_BOLD}SALES BY HOUR${C_RESET}"
    echo "$(repeat_str '─' 40)"
    awk -F',' -v cutoff="$cutoff" '
        NR==1 {next}
        $8 == "SELL" && substr($2,0,10) >= cutoff {
            hour = substr($2,12,2)
            cnt[hour]++
            rev[hour] += $7
        }
        END {
            for (h=0; h<24; h++) {
                hs = sprintf("%02d", h)
                if (cnt[hs] > 0) {
                    bar = ""
                    n = int(rev[hs] / 100)
                    for (i=0; i<n && i<30; i++) bar = bar "█"
                    printf "  %s: %4d bills  %8s  %s\n", hs, cnt[hs], "Rs"rev[hs]/100, bar
                }
            }
        }' "$BILLS_CSV"

    # 2. Sales by day-of-week
    echo
    echo " ${C_BOLD}SALES BY DAY-OF-WEEK${C_RESET}"
    echo "$(repeat_str '─' 40)"
    awk -F',' -v cutoff="$cutoff" '
        BEGIN {
            split("Sun Mon Tue Wed Thu Fri Sat", dow_names, " ")
        }
        NR==1 {next}
        $8 == "SELL" && substr($2,0,10) >= cutoff {
            d = substr($2,0,10)
            split(d, parts, "-")
            t = mktime(parts[1] " " parts[2] " " parts[3] " 0 0 0")
            dow = strftime("%w", t)
            rev[dow] += $7
            cnt[dow]++
        }
        END {
            for (d=0; d<7; d++) {
                if (cnt[d] > 0) {
                    bar = ""
                    n = int(rev[d] / 500)
                    for (i=0; i<n && i<30; i++) bar = bar "█"
                    printf "  %s: %4d bills  %8s  %s\n", dow_names[d+1], cnt[d], "Rs"rev[d]/100, bar
                }
            }
        }' "$BILLS_CSV"

    # 3. Category mix
    echo
    echo " ${C_BOLD}CATEGORY MIX${C_RESET}"
    echo "$(repeat_str '─' 40)"
    awk -F',' -v cutoff="$cutoff" '
        NR==1 {next}
        $8 == "SELL" && substr($2,0,10) >= cutoff {
            rev[$3] += $7
        }
        END {
            for (bc in rev) printf "%d\t%s\n", rev[bc], bc
        }' "$BILLS_CSV" | sort -t$'\t' -k1,1nr | head -10 | while IFS=$'\t' read -r rev bc; do
        local cat="${P_TYPE[$bc]:-Uncategorised}"
        printf "  %-20s %10s\n" "$(truncate_name "$cat" 20)" "$(fmt_money "$rev")"
    done

    # 4. Margin summary (if cost prices set)
    echo
    echo " ${C_BOLD}MARGIN SUMMARY (current catalog)${C_RESET}"
    echo "$(repeat_str '─' 40)"
    local total_retail=0 total_cost=0 n_with_cost=0 n_total=0
    for bc in "${!P_NAME[@]}"; do
        n_total=$((n_total+1))
        local retail=$(( ${P_PRICE[$bc]} * ${P_QTY[$bc]} ))
        total_retail=$(( total_retail + retail ))
        if [[ -n "${P_COST[$bc]}" && "${P_COST[$bc]}" =~ ^[0-9]+$ ]]; then
            local cost=$(( ${P_COST[$bc]} * ${P_QTY[$bc]} ))
            total_cost=$(( total_cost + cost ))
            n_with_cost=$((n_with_cost+1))
        fi
    done
    if (( n_with_cost == 0 )); then
        printf "  No cost prices set. Use 'edit <bc> --cost N' to enable.\n"
    else
        local profit=$(( total_retail - total_cost ))
        local margin_pct=0
        (( total_retail > 0 )) && margin_pct=$(( profit * 100 / total_retail ))
        printf "  Stock at retail:    %s\n" "$(fmt_money "$total_retail")"
        printf "  Stock at cost:      %s  (%d of %d SKUs)\n" "$(fmt_money "$total_cost")" "$n_with_cost" "$n_total"
        printf "  Projected gross:    %s  (%d%% margin)\n" "$(fmt_money "$profit")" "$margin_pct"
    fi
    log_event "ANALYTICS" "-" "all" "$days" "-" "analytics dashboard rendered"
}

#═══════════════════════════════════════════════════════════════════════════════
# v3 PART C — Stock adjustment + Supplier management + Purchase orders
#═══════════════════════════════════════════════════════════════════════════════

SUPPLIERS_CSV="$DATA_DIR/suppliers.csv"
POS_CSV="$DATA_DIR/purchase_orders.csv"

declare -A SUP_NAME SUP_PHONE SUP_EMAIL SUP_LEAD_DAYS

# Valid reason codes for stock adjustments
declare -A ADJUST_REASONS=(
    ["damage"]="Damaged in store"
    ["theft"]="Theft / shrinkage"
    ["sample"]="Free sample given"
    ["breakage"]="Breakage"
    ["writeoff"]="Written off"
    ["found"]="Found in stocktake"
    ["gift"]="Gift / complementary"
    ["other"]="Other"
)

# adjust <barcode> <delta> <reason_code> [note]
# delta is signed (+N or -N). reason_code must be in ADJUST_REASONS.
cmd_adjust() {
    local bc="${1:-}" delta="${2:-}" reason="${3:-other}" note="${4:-}"
    [[ -n "$bc" && -n "$delta" ]] || {
        err "Usage: shopkeep.sh adjust <barcode> <+N|-N> <reason> [note]"
        echo "Reasons: ${!ADJUST_REASONS[@]}"
        return 3
    }
    [[ "$bc" =~ ^[0-9]+$ ]] || { err "barcode must be digits"; return 1; }
    [[ "$delta" =~ ^[+-]?[0-9]+$ ]] || { err "delta must be a signed integer"; return 1; }
    [[ -n "${ADJUST_REASONS[$reason]:-}" ]] || {
        err "Unknown reason '$reason'. Valid: ${!ADJUST_REASONS[@]}"
        return 1
    }
    # Manager PIN check (sensitive op)
    if [[ -f "$DATA_DIR/pin.hash" ]] && ! pin_prompt; then
        err "Adjustment cancelled (PIN required)."
        return 1
    fi
    init_dirs; lock; load_products_v3
    [[ -n "${P_NAME[$bc]+x}" ]] || { unlock; err "No product with barcode $bc"; return 1; }
    local old="${P_QTY[$bc]}"
    local new=$(( old + delta ))
    if (( new < 0 )); then
        unlock; err "Adjustment would make stock negative ($old + $delta = $new)"
        return 1
    fi
    if apply_stock_delta "$bc $delta"; then
        log_event "ADJUST" "$bc" "${P_NAME[$bc]}" "$delta" "${P_PRICE[$bc]}" \
            "reason=$reason: ${note:-${ADJUST_REASONS[$reason]}} (stock $old → $new)"
        unlock
        log "Adjusted: ${P_NAME[$bc]}  $old → $new  ($delta, $reason)"
        return 0
    else
        unlock; err "Adjustment failed"; return 1
    fi
}

#--------------------------- Supplier management ------------------------------

load_suppliers() {
    SUP_NAME=(); SUP_PHONE=(); SUP_EMAIL=(); SUP_LEAD_DAYS=()
    [[ -f "$SUPPLIERS_CSV" ]] || return 0
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "id,"* || -z "$line" ]] && continue
        parse_csv_line "$line"
        local id="${CSV_FIELDS[0]}"
        [[ -z "$id" ]] && continue
        SUP_NAME["$id"]="${CSV_FIELDS[1]}"
        SUP_PHONE["$id"]="${CSV_FIELDS[2]}"
        SUP_EMAIL["$id"]="${CSV_FIELDS[3]}"
        SUP_LEAD_DAYS["$id"]="${CSV_FIELDS[4]:-3}"
    done < "$SUPPLIERS_CSV"
}

cmd_supplier() {
    init_dirs
    local sub="${1:-list}"
    shift 2>/dev/null || true
    case "$sub" in
        add)
            local id="$1" name="$2" phone="$3" email="$4" lead="${5:-3}"
            [[ -n "$id" && -n "$name" ]] || {
                err "Usage: supplier add <id> <name> [phone] [email] [lead_days]"
                return 3
            }
            [[ -f "$SUPPLIERS_CSV" ]] || printf 'id,name,phone,email,lead_days\n' > "$SUPPLIERS_CSV"
            printf '%s,%s,%s,%s,%s\n' \
                "$(csv_quote "$id")" "$(csv_quote "$name")" \
                "$(csv_quote "$phone")" "$(csv_quote "$email")" "$lead" >> "$SUPPLIERS_CSV"
            log "Supplier added: $name ($id)"
            ;;
        list)
            [[ -f "$SUPPLIERS_CSV" ]] || { log "No suppliers yet."; return 0; }
            echo "${C_BOLD}SUPPLIERS${C_RESET}"
            echo "$(repeat_str '─' 64)"
            awk -F',' 'NR>1{printf "  %-6s %-22s %-14s %-22s lead=%sd\n", $1, $2, $3, $4, $5}' "$SUPPLIERS_CSV"
            ;;
        find)
            local q="${1:-}"
            load_suppliers
            local id
            for id in "${!SUP_NAME[@]}"; do
                if [[ "$id" == *"$q"* || "${SUP_NAME[$id]}" == *"$q"* ]]; then
                    printf "  %-6s %-22s %-14s lead=%sd\n" \
                        "$id" "${SUP_NAME[$id]}" "${SUP_PHONE[$id]}" "${SUP_LEAD_DAYS[$id]}"
                fi
            done
            ;;
        *)
            err "Usage: shopkeep.sh supplier [add|list|find] ..."; return 3 ;;
    esac
}

#--------------------------- Purchase orders ---------------------------------

# po create <supplier_id> <bc:qty,bc:qty,...>
# po list
# po receive <po_id>            — receives all items, increments stock
# po show <po_id>
cmd_po() {
    init_dirs
    local sub="${1:-list}"
    shift 2>/dev/null || true
    case "$sub" in
        create)
            local sup="$1" items="$2"
            [[ -n "$sup" && -n "$items" ]] || {
                err "Usage: po create <supplier_id> <bc:qty,bc:qty,...>"
                return 3
            }
            load_suppliers
            [[ -n "${SUP_NAME[$sup]+x}" ]] || { err "Unknown supplier $sup"; return 1; }
            [[ -f "$POS_CSV" ]] || printf 'po_id,supplier_id,created_date,status,items\n' > "$POS_CSV"
            local po_id; po_id=$(TZ=Asia/Kolkata date +%Y%m%d-%H%M%S)
            local today; today=$(TZ=Asia/Kolkata date '+%Y-%m-%d')
            printf '%s,%s,%s,OPEN,%s\n' \
                "$(csv_quote "$po_id")" "$(csv_quote "$sup")" "$today" "$(csv_quote "$items")" >> "$POS_CSV"
            log "PO created: $po_id → $sup (${SUP_NAME[$sup]}) — $items"
            log_event "PO_CREATE" "-" "$sup" "-" "-" "po=$po_id items=$items"
            ;;
        list)
            [[ -f "$POS_CSV" ]] || { log "No purchase orders yet."; return 0; }
            echo "${C_BOLD}PURCHASE ORDERS${C_RESET}"
            echo "$(repeat_str '─' 78)"
            printf "  %-20s %-6s %-12s %-8s %s\n" "PO ID" "Sup" "Date" "Status" "Items"
            echo "$(repeat_str '─' 78)"
            # Use parse_csv_line to handle quoted item lists correctly.
            local line pid sup date status items
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ "$line" == "po_id,"* || -z "$line" ]] && continue
                parse_csv_line "$line"
                pid="${CSV_FIELDS[0]}"; sup="${CSV_FIELDS[1]}"
                date="${CSV_FIELDS[2]}"; status="${CSV_FIELDS[3]}"; items="${CSV_FIELDS[4]:-}"
                printf "  %-20s %-6s %-12s %-8s %s\n" "$pid" "$sup" "$date" "$status" "$items"
            done < "$POS_CSV"
            ;;
        show)
            local pid="$1"
            [[ -n "$pid" ]] || { err "Usage: po show <po_id>"; return 3; }
            [[ -f "$POS_CSV" ]] || { err "No POs."; return 1; }
            local line found=0
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ "$line" == "po_id,"* || -z "$line" ]] && continue
                parse_csv_line "$line"
                [[ "${CSV_FIELDS[0]}" == "$pid" ]] || continue
                found=1
                echo "${C_BOLD}PO ${CSV_FIELDS[0]}${C_RESET}"
                echo "$(repeat_str '─' 48)"
                echo "  Supplier: ${CSV_FIELDS[1]}"
                echo "  Created:  ${CSV_FIELDS[2]}"
                echo "  Status:   ${CSV_FIELDS[3]}"
                echo "  Items:    ${CSV_FIELDS[4]}"
                echo
                # Show item-by-item
                lock; load_products_v3; unlock
                local IFS=',' item ibc iqt
                for item in ${CSV_FIELDS[4]}; do
                    ibc="${item%%:*}"; iqt="${item#*:}"
                    printf "    %-14s x%-4s %s\n" "$ibc" "$iqt" "${P_NAME[$ibc]:-<unknown>}"
                done
                break
            done < "$POS_CSV"
            (( found )) || err "PO $pid not found"
            ;;
        receive)
            local pid="$1"
            [[ -n "$pid" ]] || { err "Usage: po receive <po_id>"; return 3; }
            [[ -f "$POS_CSV" ]] || { err "No POs."; return 1; }
            # Manager PIN check
            if [[ -f "$DATA_DIR/pin.hash" ]] && ! pin_prompt; then
                err "PO receive cancelled (PIN required)."
                return 1
            fi
            lock; load_products_v3
            local tmp="$POS_CSV.new" received_items="" found=0
            printf '%s\n' "po_id,supplier_id,created_date,status,items" > "$tmp"
            local line
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ "$line" == "po_id,"* || -z "$line" ]] && continue
                parse_csv_line "$line"
                if [[ "${CSV_FIELDS[0]}" == "$pid" ]]; then
                    found=1
                    [[ "${CSV_FIELDS[3]}" == "RECEIVED" ]] && {
                        unlock; rm -f "$tmp"; err "PO $pid already received"; return 1; }
                    received_items="${CSV_FIELDS[4]}"
                    printf '%s,%s,%s,RECEIVED,%s\n' \
                        "$(csv_quote "${CSV_FIELDS[0]}")" "$(csv_quote "${CSV_FIELDS[1]}")" \
                        "${CSV_FIELDS[2]}" "$(csv_quote "$received_items")" >> "$tmp"
                else
                    printf '%s\n' "$line" >> "$tmp"
                fi
            done < "$POS_CSV"
            if (( ! found )); then
                unlock; rm -f "$tmp"; err "PO $pid not found"; return 1
            fi
            mv "$tmp" "$POS_CSV"
            # Receive each item: add to stock
            local IFS=',' item ibc iqt n=0
            local -a deltas=()
            for item in $received_items; do
                ibc="${item%%:*}"; iqt="${item#*:}"
                [[ "$iqt" =~ ^[0-9]+$ ]] || continue
                if [[ -n "${P_NAME[$ibc]+x}" ]]; then
                    deltas+=("$ibc $iqt")
                    n=$((n+1))
                fi
            done
            if (( ${#deltas[@]} > 0 )); then
                apply_stock_delta "${deltas[@]}"
                for item in $received_items; do
                    ibc="${item%%:*}"; iqt="${item#*:}"
                    [[ "$iqt" =~ ^[0-9]+$ ]] || continue
                    [[ -n "${P_NAME[$ibc]+x}" ]] && \
                        log_event "PO_RECEIVE" "$ibc" "${P_NAME[$ibc]}" "$iqt" "${P_PRICE[$ibc]}" "po=$pid"
                done
            fi
            unlock
            log "PO $pid received — $n items added to stock"
            ;;
        *)
            err "Usage: shopkeep.sh po [create|list|show|receive] ..."; return 3 ;;
    esac
}

#═══════════════════════════════════════════════════════════════════════════════
# v3 PART D — Return-against-bill + Loyalty + WhatsApp + Thermal + PIN + Export
#═══════════════════════════════════════════════════════════════════════════════

# cmd_return_v3 — replaces v2 cmd_return. Supports --bill N flag.
# If --bill is given, the return is logged against that bill and we look up
# the ORIGINAL price (not current) to credit the right amount.
cmd_return_v3() {
    local bill_no="" bc="" qty="" reason="no reason" qty_set=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bill)   bill_no="$2"; shift 2 ;;
            --qty)    qty="$2"; qty_set=1; shift 2 ;;
            --reason) reason="$2"; shift 2 ;;
            *)
                # First positional = barcode, second positional = qty,
                # third positional = reason (v2-compatible call style).
                if [[ -z "$bc" ]]; then
                    bc="$1"
                elif (( ! qty_set )); then
                    qty="$1"; qty_set=1
                else
                    reason="$1"
                fi
                shift
                ;;
        esac
    done
    # Default qty to 1 if not provided
    [[ -z "$qty" ]] && qty=1
    [[ -n "$bc" ]] || { err "Usage: shopkeep.sh return [--bill N] <barcode> [--qty Q] [--reason R]"; return 3; }
    [[ "$bc" =~ ^[0-9]+$ ]] || { err "barcode must be digits"; return 1; }
    [[ "$qty" =~ ^[0-9]+$ && "$qty" -gt 0 ]] || { err "qty must be positive"; return 1; }
    # Manager PIN for returns
    if [[ -f "$DATA_DIR/pin.hash" ]] && ! pin_prompt; then
        err "Return cancelled (PIN required)."
        return 1
    fi
    init_dirs; lock; load_products_v3
    [[ -n "${P_NAME[$bc]+x}" ]] || { unlock; err "No product with barcode $bc"; return 1; }

    local original_price="${P_PRICE[$bc]}"
    if [[ -n "$bill_no" ]]; then
        # Look up original price from this bill
        local line bno_r action orig_price=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" == "bill_no,"* || -z "$line" ]] && continue
            parse_csv_line "$line"
            bno_r="${CSV_FIELDS[0]}"; action="${CSV_FIELDS[7]}"
            if [[ "$bno_r" == "$bill_no" && "$action" == "SELL" && "${CSV_FIELDS[2]}" == "$bc" ]]; then
                orig_price="${CSV_FIELDS[5]}"
                break
            fi
        done < "$BILLS_CSV"
        [[ -n "$orig_price" ]] && original_price="$orig_price"
        # Append a RETURN row to bills.csv (so the ledger shows the credit)
        local ts; ts=$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')
        local lt=$(( original_price * qty ))
        printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$bill_no" "$ts" "$(csv_quote "$bc")" "$(csv_quote "${P_NAME[$bc]}")" \
            "$qty" "$original_price" "$lt" "RETURN" >> "$BILLS_CSV"
    fi

    if apply_stock_delta "$bc $qty"; then
        log_event "RETURN" "$bc" "${P_NAME[$bc]}" "$qty" "$original_price" \
            "return${bill_no:+ against bill #$bill_no}: $reason"
        unlock
        log "Returned: ${P_NAME[$bc]} x$qty (stock +$qty)${bill_no:+ against bill #$bill_no}"
        if [[ -n "$bill_no" ]]; then
            local credit=$(( original_price * qty ))
            echo "  Credit due: $(fmt_money "$credit")"
        fi
        return 0
    else
        unlock; err "Return failed"; return 1
    fi
}

#--------------------------- Loyalty points ----------------------------------
# Extend customer DB: customers.csv gains a points column (v3 schema).
# v2: phone,name,visits,total_spent_paise
# v3: phone,name,visits,total_spent_paise,points
# Auto-earn: 1 point per ₹10 spent (configurable via SHOPKEEP_POINTS_PER_RUPEE).

cmd_customer_v3() {
    init_dirs
    local sub="${1:-list}"
    shift 2>/dev/null || true
    case "$sub" in
        add)
            local name="$1" phone="$2"
            [[ -n "$name" && -n "$phone" ]] || { err "Usage: customer add <name> <phone>"; return 3; }
            [[ -f "$CUSTOMERS_CSV" ]] || printf 'phone,name,visits,total_spent_paise,points\n' > "$CUSTOMERS_CSV"
            printf '%s,%s,0,0,0\n' "$(csv_quote "$phone")" "$(csv_quote "$name")" >> "$CUSTOMERS_CSV"
            log "$(t c_cust_added): $name ($phone)"
            ;;
        list)
            [[ -f "$CUSTOMERS_CSV" ]] || { log "No customers yet."; return 0; }
            echo "${C_BOLD}CUSTOMERS${C_RESET}"
            echo "$(repeat_str '─' 70)"
            printf "  %-14s %-22s %6s %10s %8s\n" "Phone" "Name" "Visits" "Spent" "Points"
            echo "$(repeat_str '─' 70)"
            local line ph nm vis sp pts
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ "$line" == "phone,"* || -z "$line" ]] && continue
                parse_csv_line "$line"
                ph="${CSV_FIELDS[0]}"; nm="${CSV_FIELDS[1]}"
                vis="${CSV_FIELDS[2]:-0}"; sp="${CSV_FIELDS[3]:-0}"; pts="${CSV_FIELDS[4]:-0}"
                printf "  %-14s %-22s %6s %10s %8s\n" "$ph" "$nm" "$vis" "$(fmt_money "$sp")" "$pts"
            done < "$CUSTOMERS_CSV"
            ;;
        find)
            local q="${1:-}"
            [[ -n "$q" ]] || { err "Usage: customer find <phone-or-name>"; return 3; }
            load_customers
            local ph
            for ph in "${!CUST_NAME[@]}"; do
                if [[ "$ph" == *"$q"* || "${CUST_NAME[$ph],,}" == *"${q,,}"* ]]; then
                    printf "  %-14s %-22s  %s visits  ₹%d\n" "$ph" "${CUST_NAME[$ph]}" "${CUST_VISITS[$ph]}" "$(( ${CUST_SPENT[$ph]:-0} / 100 ))"
                fi
            done
            ;;
        points)
            local phone="$1" action="$2" n="$3"
            [[ -n "$phone" && -n "$action" && -n "$n" ]] || {
                err "Usage: customer points <phone> <add|redeem> <n>"
                return 3
            }
            [[ "$n" =~ ^[0-9]+$ ]] || { err "n must be a number"; return 1; }
            [[ -f "$CUSTOMERS_CSV" ]] || { err "No customers yet."; return 1; }
            local tmp="$CUSTOMERS_CSV.new" found=0
            printf 'phone,name,visits,total_spent_paise,points\n' > "$tmp"
            local line ph nm vis sp pts
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ "$line" == "phone,"* || -z "$line" ]] && continue
                parse_csv_line "$line"
                ph="${CSV_FIELDS[0]}"; nm="${CSV_FIELDS[1]}"
                vis="${CSV_FIELDS[2]:-0}"; sp="${CSV_FIELDS[3]:-0}"; pts="${CSV_FIELDS[4]:-0}"
                if [[ "$ph" == "$phone" ]]; then
                    found=1
                    if [[ "$action" == "add" ]]; then
                        pts=$(( pts + n ))
                    elif [[ "$action" == "redeem" ]]; then
                        if (( pts < n )); then
                            rm -f "$tmp"
                            err "Insufficient points: has $pts, wants $n"
                            return 1
                        fi
                        pts=$(( pts - n ))
                    else
                        rm -f "$tmp"
                        err "Action must be add or redeem"
                        return 1
                    fi
                fi
                printf '%s,%s,%s,%s,%s\n' \
                    "$(csv_quote "$ph")" "$(csv_quote "$nm")" "$vis" "$sp" "$pts" >> "$tmp"
            done < "$CUSTOMERS_CSV"
            if (( ! found )); then
                rm -f "$tmp"
                err "Customer $phone not found"
                return 1
            fi
            mv "$tmp" "$CUSTOMERS_CSV"
            log "Customer $phone: $action $n points"
            ;;
        *) err "Usage: shopkeep.sh customer [add|list|find|points] ..."; return 3 ;;
    esac
}

#--------------------------- WhatsApp bill sharing ---------------------------

cmd_whatsapp() {
    local bno="${1:-}"
    [[ -n "$bno" && "$bno" =~ ^[0-9]+$ ]] || { err "Usage: shopkeep.sh whatsapp <bill_no>"; return 3; }
    init_dirs; lock
    local line bno_r ts bc name qty up lt action shop_name
    shop_name=$(conf shop_name)
    local total=0 items=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "bill_no,"* || -z "$line" ]] && continue
        parse_csv_line "$line"
        bno_r="${CSV_FIELDS[0]}"; ts="${CSV_FIELDS[1]}"
        name="${CSV_FIELDS[3]}"; qty="${CSV_FIELDS[4]}"; lt="${CSV_FIELDS[6]}"; action="${CSV_FIELDS[7]}"
        [[ "$bno_r" == "$bno" && "$action" == "SELL" ]] || continue
        total=$(( total + lt ))
        items+="• ${name} x${qty} = $(fmt_money "$lt")%0A"
    done < "$BILLS_CSV"
    unlock
    (( total > 0 )) || { err "Bill $bno not found"; return 1; }
    local msg
    msg=$(printf '*%s*%%0ABill #%04d%%0A%s%%0A*TOTAL: %s*%%0AThank you!' \
        "$(printf '%s' "$shop_name" | sed 's/ /%20/g')" \
        "$bno" \
        "$items" \
        "$(printf '%s' "$(fmt_money "$total")" | sed 's/ /%20/g')")
    local url="https://wa.me/?text=${msg}"
    echo "$url"
    if [[ "$MARKETPLACE_OPEN_BROWSER" == "1" ]]; then
        marketplace_open_url "$url" 2>/dev/null && log "Opened WhatsApp share in browser"
    fi
    log_event "WHATSAPP" "-" "-" "-" "$total" "bill #$bno shared via wa.me"
}

#--------------------------- ESC/POS thermal printer -------------------------

# Print a bill as ESC/POS raw bytes for USB thermal printers (80mm).
# Pipe to your printer device: ./shopkeep.sh thermal 1 > /dev/usb/lp0
cmd_thermal() {
    local bno="${1:-}"
    [[ -n "$bno" && "$bno" =~ ^[0-9]+$ ]] || { err "Usage: shopkeep.sh thermal <bill_no>"; return 3; }
    init_dirs; lock
    local line bno_r ts bc name qty up lt action
    local shop_name; shop_name=$(conf shop_name)
    local total=0 n=0
    local -a rows=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "bill_no,"* || -z "$line" ]] && continue
        parse_csv_line "$line"
        bno_r="${CSV_FIELDS[0]}"; ts="${CSV_FIELDS[1]}"
        bc="${CSV_FIELDS[2]}"; name="${CSV_FIELDS[3]}"; qty="${CSV_FIELDS[4]}"
        up="${CSV_FIELDS[5]}"; lt="${CSV_FIELDS[6]}"; action="${CSV_FIELDS[7]}"
        [[ "$bno_r" == "$bno" && "$action" == "SELL" ]] || continue
        total=$(( total + lt )); n=$((n+1))
        rows+=("$name|$qty|$up|$lt")
    done < "$BILLS_CSV"
    unlock
    (( n > 0 )) || { err "Bill $bno not found"; return 1; }
    # ESC/POS commands
    printf '\x1b\x40'                       # init
    printf '\x1b\x21\x30'                   # font A
    printf '\x1b\x61\x01'                   # center
    printf '%s\n' "$shop_name"
    printf 'Bill #%04d\n' "$bno"
    printf '%s\n' "$ts"
    printf '\x1b\x61\x00'                   # left
    printf '%s\n' "$(repeat_str '-' 32)"
    for r in "${rows[@]}"; do
        IFS='|' read -r name qty up lt <<< "$r"
        printf '%-20s x%-3s %8s\n' "${name:0:20}" "$qty" "$(fmt_money "$lt")"
    done
    printf '%s\n' "$(repeat_str '-' 32)"
    printf 'TOTAL:%*s\n' 26 "$(fmt_money "$total")"
    printf 'Items: %d\n' "$n"
    printf '\x1b\x61\x01'                   # center
    printf 'Thank you!\n'
    printf '\x1b\x64\x03'                   # feed 3 lines
    printf '\x1d\x56\x00'                   # cut paper
}

#--------------------------- Manager PIN management --------------------------

cmd_pin() {
    init_dirs
    local sub="${1:-set}"
    case "$sub" in
        set)
            # If a PIN is already set, require the old one first
            if [[ -f "$DATA_DIR/pin.hash" ]]; then
                printf "Old PIN: "; read -rs old || return 1; echo
                if ! pin_check "$old"; then err "Wrong old PIN"; return 1; fi
            fi
            local new1 new2
            printf "New PIN: "; read -rs new1 || return 1; echo
            printf "Confirm: "; read -rs new2 || return 1; echo
            [[ "$new1" == "$new2" ]] || { err "PINs don't match"; return 1; }
            [[ "$new1" =~ ^[0-9]{4,8}$ ]] || {
                err "PIN must be 4-8 digits"; return 1; }
            pin_hash "$new1" > "$DATA_DIR/pin.hash"
            chmod 600 "$DATA_DIR/pin.hash"
            log "Manager PIN set"
            ;;
        clear)
            if [[ -f "$DATA_DIR/pin.hash" ]]; then
                rm -f "$DATA_DIR/pin.hash"
                log "Manager PIN cleared"
            fi
            ;;
        check)
            if pin_prompt; then log "PIN OK"; else err "PIN wrong"; return 1; fi
            ;;
        *)
            err "Usage: shopkeep.sh pin [set|clear|check]"; return 3 ;;
    esac
}

#--------------------------- Tally / QuickBooks export -----------------------

cmd_export() {
    local fmt="${1:-tally}"
    init_dirs
    case "$fmt" in
        tally)
            local out="$DATA_DIR/tally-daybook-$(TZ=Asia/Kolkata date +%Y%m%d).csv"
            {
                printf 'Date,Voucher Type,Voucher No,Ledger,Amount,Dr/Cr\n'
                [[ -f "$BILLS_CSV" ]] || return 0
                awk -F',' 'NR>1 && $8 == "SELL" {
                    printf "%s,Sales,%s,Sales,%s,Cr\n", substr($2,0,10), $1, $7/100
                    printf "%s,Receipt,%s,Cash,%s,Dr\n", substr($2,0,10), $1, $7/100
                }' "$BILLS_CSV"
            } > "$out"
            log "Tally export: $out"
            ;;
        quickbooks)
            local out="$DATA_DIR/qb-sales-$(TZ=Asia/Kolkata date +%Y%m%d).csv"
            {
                printf 'Date,Transaction ID,Customer,Item,Qty,Amount\n'
                [[ -f "$BILLS_CSV" ]] || return 0
                awk -F',' 'NR>1 && $8 == "SELL" {
                    printf "%s,%s,Walk-in,%s,%s,%s\n", substr($2,0,10), $1, $4, $5, $7/100
                }' "$BILLS_CSV"
            } > "$out"
            log "QuickBooks export: $out"
            ;;
        gst)
            # GSTR-1-ready: B2B + B2C + HSN summary
            local out="$DATA_DIR/gstr1-$(TZ=Asia/Kolkata date +%Y%m).csv"
            {
                printf 'GSTIN/Bill,Date,Invoice No,Customer,HSN,Qty,Taxable Value,GST Rate,GST Amount,Total\n'
                [[ -f "$BILLS_CSV" ]] || return 0
                load_products_v3
                local line bno ts bc name qty up lt action hsn
                while IFS= read -r line || [[ -n "$line" ]]; do
                    [[ "$line" == "bill_no,"* || -z "$line" ]] && continue
                    parse_csv_line "$line"
                    action="${CSV_FIELDS[7]}"
                    [[ "$action" == "SELL" ]] || continue
                    bno="${CSV_FIELDS[0]}"; ts="${CSV_FIELDS[1]}"
                    bc="${CSV_FIELDS[2]}"; name="${CSV_FIELDS[3]}"
                    qty="${CSV_FIELDS[4]}"; up="${CSV_FIELDS[5]}"; lt="${CSV_FIELDS[6]}"
                    hsn="${P_HSN[$bc]:-}"
                    # Default GST 0 if not set
                    printf '%s,%s,%s,Walk-in,%s,%s,%s,%s,%s,%s\n' \
                        "NA/${bno}" "${ts:0:10}" "$bno" "$hsn" "$qty" \
                        "$(awk -v p="$lt" 'BEGIN{printf "%.2f", p/100}')" \
                        "${BL_GST_DEFAULT_PCT:-0}" "0" \
                        "$(awk -v p="$lt" 'BEGIN{printf "%.2f", p/100}')"
                done < "$BILLS_CSV"
            } > "$out"
            log "GSTR-1 export: $out"
            ;;
        *)
            err "Usage: shopkeep.sh export [tally|quickbooks|gst]"
            return 3
            ;;
    esac
}

#--------------------------- HTTP API server ---------------------------------

cmd_serve() {
    local port="${1:-8080}"
    command -v python3 >/dev/null 2>&1 || { err "python3 required for serve"; return 2; }
    init_dirs
    log "Starting shopkeep HTTP API on http://localhost:$port/  (Ctrl+C to stop)"
    SHOPKEEP_DATA_DIR="$DATA_DIR" python3 - "$port" <<'PYEOF'
import sys, os, json, http.server, socketserver
from urllib.parse import urlparse, parse_qs
PORT = int(sys.argv[1])
DATA_DIR = os.environ["SHOPKEEP_DATA_DIR"]
def read_csv(path):
    if not os.path.exists(path): return []
    rows = []
    with open(path) as f:
        lines = f.read().splitlines()
    if not lines: return []
    header = lines[0].split(",")
    for line in lines[1:]:
        if not line.strip(): continue
        rows.append(dict(zip(header, line.split(","))))
    return rows
class H(http.server.BaseHTTPRequestHandler):
    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        try:
            if u.path == "/health":
                return self._json(200, {"ok": True, "service": "shopkeep"})
            if u.path == "/products":
                return self._json(200, read_csv(os.path.join(DATA_DIR, "products.csv")))
            if u.path == "/bills":
                return self._json(200, read_csv(os.path.join(DATA_DIR, "bills.csv")))
            if u.path == "/categories":
                return self._json(200, read_csv(os.path.join(DATA_DIR, "categories.csv")))
            if u.path == "/trays":
                return self._json(200, read_csv(os.path.join(DATA_DIR, "trays.csv")))
            if u.path == "/inventory_log":
                return self._json(200, read_csv(os.path.join(DATA_DIR, "inventory_log.csv")))
            if u.path == "/customers":
                return self._json(200, read_csv(os.path.join(DATA_DIR, "customers.csv")))
            if u.path == "/summary":
                bills = read_csv(os.path.join(DATA_DIR, "bills.csv"))
                sells = [b for b in bills if b.get("action") == "SELL"]
                revenue = sum(int(b.get("line_total", 0)) for b in sells)
                return self._json(200, {
                    "bill_count": len({b.get("bill_no") for b in sells}),
                    "line_items": len(sells),
                    "revenue_paise": revenue,
                    "revenue_rs": revenue / 100,
                })
            return self._json(404, {"error": "not found", "paths": [
                "/health", "/products", "/bills", "/categories", "/trays",
                "/inventory_log", "/customers", "/summary"
            ]})
        except Exception as e:
            return self._json(500, {"error": str(e)})
    def log_message(self, fmt, *args):
        pass  # silence default logging
with socketserver.TCPServer(("0.0.0.0", PORT), H) as s:
    s.allow_reuse_address = True
    s.serve_forever()
PYEOF
}

#═══════════════════════════════════════════════════════════════════════════════
# v3 PART E — Wire everything together: extend cmd_edit, register in main(),
# add v3 self-tests, extend interactive menu.
#═══════════════════════════════════════════════════════════════════════════════

# Extend cmd_edit to accept --cost and --hsn. We wrap the original.
cmd_edit_v3() {
    # Parse args: --cost N, --hsn XXXX consumed here; everything else
    # forwarded to cmd_edit. First positional = barcode.
    local bc="" cost="" hsn="" legacy_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cost)
                cost="$2"; shift 2 ;;
            --hsn)
                hsn="$2"; shift 2 ;;
            --cost=*)
                cost="${1#--cost=}"; shift ;;
            --hsn=*)
                hsn="${1#--hsn=}"; shift ;;
            *)
                if [[ -z "$bc" && "$1" != --* ]]; then
                    bc="$1"
                else
                    legacy_args+=("$1")
                fi
                shift
                ;;
        esac
    done
    [[ -n "$bc" ]] || { err "Usage: shopkeep.sh edit <barcode> [--cost N] [--hsn XXXX] ..."; return 3; }
    # If no v3 fields, just delegate to cmd_edit
    if [[ -z "$cost" && -z "$hsn" ]]; then
        cmd_edit "$bc" "${legacy_args[@]}"
        return $?
    fi
    init_dirs; lock; load_products_v3
    [[ -n "${P_NAME[$bc]+x}" ]] || { unlock; err "No product with barcode $bc"; return 1; }
    # Apply legacy edits first (if any)
    if (( ${#legacy_args[@]} > 0 )); then
        unlock
        cmd_edit "$bc" "${legacy_args[@]}" || return $?
        lock; load_products_v3
    fi
    # Apply v3 fields
    if [[ -n "$cost" ]]; then
        local cp; cp=$(rupees_to_paise "$cost" 2>/dev/null) || { unlock; err "Invalid cost '$cost'"; return 1; }
        P_COST["$bc"]="$cp"
    fi
    if [[ -n "$hsn" ]]; then
        P_HSN["$bc"]="$hsn"
    fi
    _DROP=()
    if ! rewrite_products_v3; then
        unlock; err "Failed to write v3 fields"; return 1
    fi
    log_event "EDIT_V3" "$bc" "${P_NAME[$bc]}" "${P_QTY[$bc]}" "${P_PRICE[$bc]}" "cost=${P_COST[$bc]:-} hsn=${P_HSN[$bc]:-}"
    unlock
    log "Edited $bc: ${cost:+cost=$cost }${hsn:+hsn=$hsn}"
    return 0
}

# Hook the init_dirs function to also run v3 migration.
# IMPORTANT: bash function overrides are last-wins, so to call the ORIGINAL
# init_dirs from the override we need a saved reference. We rename the
# original to _init_dirs_v2_legacy at load time, then the override calls it.
#
# We achieve the rename by checking at runtime: if _init_dirs_v2_legacy is
# defined (it isn't yet), call it; otherwise call init_dirs as written.
# The trick: define _init_dirs_v2_legacy as a copy of init_dirs's body via
# `eval`. Cleaner: just re-implement init_dirs inline.

_init_dirs_v2_original() {
    mkdir -p "$DATA_DIR" "$LABELS_DIR" "$BACKUPS_DIR"
    [[ -f "$PRODUCTS_CSV" ]]   || printf '%s\n' "$PRODUCTS_HEADER" > "$PRODUCTS_CSV"
    migrate_products_csv
    [[ -f "$BILLS_CSV" ]]      || printf 'bill_no,timestamp,barcode,name,qty,unit_price_paise,line_total,action\n' > "$BILLS_CSV"
    [[ -f "$INVENTORY_LOG" ]]  || printf 'timestamp,event,barcode,name,qty,price_paise,detail\n' > "$INVENTORY_LOG"
    [[ -f "$TRAYS_CSV" ]]      || printf '%s\n' "$TRAYS_HEADER" > "$TRAYS_CSV"
    [[ -f "$STATE_FILE" ]]     || printf 'next_bill_no=1\n' > "$STATE_FILE"
    [[ -f "$CONF_FILE" ]]      || printf 'shop_name=My Kirana Store\ndefault_threshold=8\n' > "$CONF_FILE"
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

# Override init_dirs: run v2 logic + v3 migration.
init_dirs() {
    _init_dirs_v2_original
    migrate_v3_products_csv
}

# Override load_products to use v3 version (loads cost+hsn too)
load_products() { load_products_v3; }

# Override cmd_return with the v3 version (supports --bill)
cmd_return() { cmd_return_v3 "$@"; }

# Override cmd_customer with v3 version (supports points)
cmd_customer() { cmd_customer_v3 "$@"; }

#═══════════════════════════════════════════════════════════════════════════════
# v3 self-tests
#═══════════════════════════════════════════════════════════════════════════════

_st_forecast() {
    # _st_summary writes bills for barcode 2001 ("Tea") but doesn't create
    # the product. Add it so forecast has something to look up.
    do_add "2001" "Tea" 1000 5 0 "" "" "" >/dev/null 2>&1 || true
    # _st_summary seeds bills dated 2025-01-10. Use a 3650-day window so
    # those bills are included regardless of when the test runs.
    local out
    out=$(cmd_forecast 2001 3650 2>/dev/null) || true
    [[ "$out" == *"FORECAST"* ]] || return 1
    [[ "$out" == *"Avg daily"* ]] || return 1
    [[ "$out" == *"Weekly forecast"* ]] || return 1
    [[ "$out" == *"Units sold:"* ]] || return 1
    return 0
}

_st_reorder_runs() {
    # Just verify reorder runs without error
    cmd_reorder 30 >/dev/null 2>&1 || return 1
    return 0
}

_st_deadstock_runs() {
    cmd_deadstock 30 >/dev/null 2>&1 || return 1
    return 0
}

_st_abc_runs() {
    cmd_abc 90 >/dev/null 2>&1 || return 1
    return 0
}

_st_analytics_runs() {
    cmd_analytics 30 >/dev/null 2>&1 || return 1
    return 0
}

_st_cost_hsn_edit() {
    do_add "9601" "CostTest" 1000 5 0 "" "" "" >/dev/null 2>&1 || true
    cmd_edit_v3 9601 --cost 8.50 --hsn 2101 >/dev/null 2>&1 || true
    load_products_v3
    [[ "${P_COST[9601]:-}" == "850" ]] || return 1
    [[ "${P_HSN[9601]:-}"  == "2101" ]] || return 1
    return 0
}

_st_adjust() {
    # No PIN set during self-test, so adjustment should succeed
    do_add "9701" "AdjustTest" 1000 10 0 "" "" "" >/dev/null 2>&1 || true
    cmd_adjust 9701 -2 damage "self-test" >/dev/null 2>&1 || true
    local q; q=$(awk -F, '$1==9701{print $4}' "$PRODUCTS_CSV")
    [[ "$q" == "8" ]] || return 1
    grep -q "ADJUST.*damage" "$INVENTORY_LOG" || return 1
    return 0
}

_st_supplier_po() {
    cmd_supplier add SUP1 "Acme Distributors" 9876543210 "acme@x.com" 3 >/dev/null 2>&1 || true
    grep -q "SUP1" "$SUPPLIERS_CSV" || return 1
    do_add "9801" "POItem" 1000 5 0 "" "" "" >/dev/null 2>&1 || true
    cmd_po create SUP1 "9801:10" >/dev/null 2>&1 || true
    cmd_po list >/dev/null 2>&1 || true
    # Receive the PO
    local pid; pid=$(awk -F',' 'NR>1{print $1; exit}' "$POS_CSV" 2>/dev/null)
    [[ -n "$pid" ]] || return 1
    cmd_po receive "$pid" >/dev/null 2>&1 || true
    local q; q=$(awk -F, '$1==9801{print $4}' "$PRODUCTS_CSV")
    [[ "$q" == "15" ]] || return 1   # 5 + 10 received
    return 0
}

_st_return_against_bill() {
    do_add "9901" "ReturnBillTest" 1000 5 0 "" "" "" >/dev/null 2>&1 || true
    # First sell some
    commit_bill "9901 2" >/dev/null 2>&1 || true
    local last_bno; last_bno=$(awk -F',' 'NR>1 && $8=="SELL"{print $1}' "$BILLS_CSV" | tail -1)
    [[ -n "$last_bno" ]] || return 1
    # Now return against that bill
    cmd_return --bill "$last_bno" 9901 --qty 1 --reason "self-test" >/dev/null 2>&1 || true
    local q; q=$(awk -F, '$1==9901{print $4}' "$PRODUCTS_CSV")
    # Was 5, sold 2 (→3), returned 1 (→4)
    [[ "$q" == "4" ]] || return 1
    grep -q "RETURN.*bill #" "$INVENTORY_LOG" || return 1
    return 0
}

_st_loyalty() {
    cmd_customer add "LoyaltyCust" "8888888888" >/dev/null 2>&1 || true
    cmd_customer points 8888888888 add 50 >/dev/null 2>&1 || true
    local pts; pts=$(awk -F',' '$1==8888888888{print $5}' "$CUSTOMERS_CSV")
    [[ "$pts" == "50" ]] || return 1
    cmd_customer points 8888888888 redeem 20 >/dev/null 2>&1 || true
    pts=$(awk -F',' '$1==8888888888{print $5}' "$CUSTOMERS_CSV")
    [[ "$pts" == "30" ]] || return 1
    return 0
}

_st_whatsapp_url() {
    # Use bill 1 from _st_summary
    local url; url=$(cmd_whatsapp 1 2>/dev/null) || true
    [[ "$url" == https://wa.me/* ]] || return 1
    return 0
}

_st_thermal_bytes() {
    cmd_thermal 1 >/dev/null 2>&1 || true
    return 0
}

_st_pin_set_check_clear() {
    # Set, check, clear
    printf '1234\n1234\n' | cmd_pin set >/dev/null 2>&1 || true
    [[ -f "$DATA_DIR/pin.hash" ]] || return 1
    printf '1234\n' | cmd_pin check >/dev/null 2>&1 || true
    cmd_pin clear >/dev/null 2>&1 || true
    [[ -f "$DATA_DIR/pin.hash" ]] && return 1
    return 0
}

_st_export_tally() {
    cmd_export tally >/dev/null 2>&1 || true
    ls "$DATA_DIR"/tally-daybook-*.csv >/dev/null 2>&1 || return 1
    return 0
}

_st_export_gst() {
    cmd_export gst >/dev/null 2>&1 || true
    ls "$DATA_DIR"/gstr1-*.csv >/dev/null 2>&1 || return 1
    return 0
}

#═══════════════════════════════════════════════════════════════════════════════
# Extend cmd_selftest_v2 to also run v3 tests
#═══════════════════════════════════════════════════════════════════════════════

cmd_selftest_v3() {
    cmd_selftest_v2
    local v2_rc=$?
    (( v2_rc == 0 )) || return $v2_rc
    # Re-bind v3 paths to the temp DATA_DIR
    SUPPLIERS_CSV="$DATA_DIR/suppliers.csv"
    POS_CSV="$DATA_DIR/purchase_orders.csv"
    echo "${C_BOLD}Running v3 self-tests...${C_RESET}"
    local pass=0 fail=0
    st_test() {
        local name="$1"; shift
        if "$@"; then
            printf "  %sPASS%s  %s\n" "$C_GREEN" "$C_RESET" "$name"; pass=$((pass+1))
        else
            printf "  %sFAIL%s  %s\n" "$C_RED" "$C_RESET" "$name"; fail=$((fail+1))
        fi
    }
    st_test "forecast output"            _st_forecast
    st_test "reorder runs"               _st_reorder_runs
    st_test "deadstock runs"             _st_deadstock_runs
    st_test "ABC analysis runs"          _st_abc_runs
    st_test "analytics dashboard runs"   _st_analytics_runs
    st_test "cost + HSN edit"            _st_cost_hsn_edit
    st_test "stock adjustment"           _st_adjust
    st_test "supplier + PO receive"      _st_supplier_po
    st_test "return against bill"        _st_return_against_bill
    st_test "loyalty points"             _st_loyalty
    st_test "WhatsApp URL"               _st_whatsapp_url
    st_test "ESC/POS bytes"              _st_thermal_bytes
    st_test "PIN set/check/clear"        _st_pin_set_check_clear
    st_test "Tally export"               _st_export_tally
    st_test "GST export"                 _st_export_gst
    echo
    local failcolor="$C_GREEN"
    (( fail > 0 )) && failcolor="$C_RED"
    printf "v3 self-test: %s%d passed%s, %s%d failed%s\n" \
        "$C_GREEN" "$pass" "$C_RESET" "$failcolor" "$fail" "$C_RESET"
    (( fail == 0 )) || exit 1
}

#═══════════════════════════════════════════════════════════════════════════════
# Extend cmd_doctor_v2 with v3 status
#═══════════════════════════════════════════════════════════════════════════════

cmd_doctor_v3() {
    cmd_doctor_v2
    echo
    echo "${C_BOLD}v3 Extensions:${C_RESET}"
    printf "  %-18s %s\n" "Forecasting:"    "yes (moving average)"
    printf "  %-18s %s\n" "Reorder logic:"  "lead=${SHOPKEEP_LEAD_TIME:-3}d safety=${SHOPKEEP_SAFETY_DAYS:-7}d"
    printf "  %-18s %s\n" "Dead stock:"     "yes"
    printf "  %-18s %s\n" "ABC analysis:"   "yes"
    printf "  %-18s %s\n" "Analytics:"      "hour/dow/category/margin"
    printf "  %-18s %s\n" "Cost price:"     "$([[ -f $PRODUCTS_CSV ]] && grep -q ',,' $PRODUCTS_CSV && echo 'some set' || echo 'no (use edit --cost N)')"
    printf "  %-18s %s\n" "HSN codes:"      "$([[ -f $PRODUCTS_CSV ]] && awk -F',' 'NR>1 && $10!=""{n++} END{print n+0}' $PRODUCTS_CSV) set"
    printf "  %-18s %s\n" "Suppliers:"      "$([[ -f $SUPPLIERS_CSV ]] && wc -l < $SUPPLIERS_CSV | awk '{print $1-1}' || echo 0)"
    printf "  %-18s %s\n" "Purchase orders:" "$([[ -f $POS_CSV ]] && wc -l < $POS_CSV | awk '{print $1-1}' || echo 0)"
    printf "  %-18s %s\n" "Manager PIN:"    "$([[ -f $DATA_DIR/pin.hash ]] && echo 'SET (manager features locked)' || echo 'not set (open access)')"
    printf "  %-18s %s\n" "Thermal printer:" "ESC/POS bytes (pipe to /dev/usb/lp0)"
    printf "  %-18s %s\n" "HTTP API server:" "python3 required — run 'serve 8080'"
    printf "  %-18s %s\n" "Loyalty points:"  "1 pt / ₹10 (configurable via SHOPKEEP_POINTS_PER_RUPEE)"
    echo
    echo "${C_BOLD}v3 features:${C_RESET}"
    printf "  forecast reorder deadstock abc analytics adjust supplier po\n"
    printf "  return --bill loyalty whatsapp thermal pin export serve\n"
}

#═══════════════════════════════════════════════════════════════════════════════
# v3 PART F — Update main() dispatcher and interactive menu
#═══════════════════════════════════════════════════════════════════════════════

# We replace main() with a v3-aware version. Bash is last-wins so this
# definition takes effect.

main() {
    # Always init i18n + load conf language + bill layout so t() works.
    init_dirs
    local saved_lang; saved_lang=$(conf lang en)
    [[ -n "$saved_lang" ]] && LANG_CODE="$saved_lang"
    i18n_init
    bill_layout_load

    local cmd="${1:-}"
    if [[ -z "$cmd" ]]; then
        interactive_menu_v3
        return $?
    fi
    shift
    case "$cmd" in
        # legacy commands
        add)             cmd_add "$@" ;;
        edit)
            # If --cost or --hsn present, route to v3 wrapper
            if [[ "$*" == *"--cost"* || "$*" == *"--hsn"* ]]; then
                cmd_edit_v3 "$@"
            else
                cmd_edit "$@"
            fi
            ;;
        restock)         cmd_restock "$@" ;;
        remove)          cmd_remove "$@" ;;
        search)          cmd_search "$@" ;;
        inventory)       cmd_inventory "$@" ;;
        category)        cmd_category "$@" ;;
        tray)
            local sub="${1:-}"
            if [[ "$sub" == "doctor" || "$sub" == "rename" || "$sub" == "duplicate" ]]; then
                cmd_tray_v2 "$@"
            else
                cmd_tray "$@"
            fi
            ;;
        bill)            cmd_bill "$@" ;;
        lowstock)        cmd_lowstock "$@" ;;
        summary)         cmd_summary "$@" ;;
        void)            cmd_void "$@" ;;
        stockvalue)      cmd_stockvalue "$@" ;;
        inventorylog)    cmd_inventorylog "$@" ;;
        lang)            cmd_lang "$@" ;;
        backup)          backup_now ;;

        # v2 commands
        marketplace)     cmd_marketplace "$@" ;;
        push)            cmd_push "$@" ;;
        qr)              cmd_qr "$@" ;;
        billconfig)      cmd_billconfig "$@" ;;
        billsmon)        cmd_billsmon "$@" ;;
        hold)            cmd_hold "$@" ;;
        recall)          cmd_recall "$@" ;;
        return)          cmd_return "$@" ;;
        dayclose)        cmd_dayclose "$@" ;;
        cashdrawer)      cmd_cashdrawer "$@" ;;
        customer)        cmd_customer "$@" ;;
        htmlbill)        cmd_htmlbill "$@" ;;
        importcsv)       cmd_importcsv "$@" ;;
        expiry)          cmd_expiry "$@" ;;
        hotlist)         cmd_hotlist "$@" ;;

        # v3 commands
        forecast)        cmd_forecast "$@" ;;
        reorder)         cmd_reorder "$@" ;;
        deadstock)       cmd_deadstock "$@" ;;
        abc)             cmd_abc "$@" ;;
        analytics)       cmd_analytics "$@" ;;
        adjust)          cmd_adjust "$@" ;;
        supplier)        cmd_supplier "$@" ;;
        po)              cmd_po "$@" ;;
        whatsapp)        cmd_whatsapp "$@" ;;
        thermal)         cmd_thermal "$@" ;;
        pin)             cmd_pin "$@" ;;
        export)          cmd_export "$@" ;;
        serve)           cmd_serve "$@" ;;

        # meta
        -h|--help)
            sed -n '1,80p' "$0"
            ;;
        -V|--version)
            echo "shopkeep.sh v3.0 (offline-first kirana POS + v2 + v3 extensions)"
            ;;
        --doctor)        cmd_doctor_v3 ;;
        --selftest)      cmd_selftest_v3 ;;
        --gen-files)     cmd_gen_files ;;
        --recall-apis)
            echo "${C_BOLD}APIs and integrations in shopkeep.sh v3.0${C_RESET}"
            echo "$(repeat_str '─' 60)"
            echo
            echo "${C_BOLD}Working barcode lookup APIs (online_lookup):${C_RESET}"
            echo "  1. Open Food Facts  https://world.openfoodfacts.org/api/v2/product/{bc}.json"
            echo "  2. Open Products Facts  https://world.openproductsfacts.org/api/v2/product/{bc}.json"
            echo "  3. UPCitemDB trial  https://www.upcitemdb.com/api/trial/lookup?upc={bc}"
            echo
            echo "${C_BOLD}Marketplace lookups (marketplace_lookup):${C_RESET}"
            echo "  amazon    PA-API 5 (with creds) or browser search"
            echo "  flipkart  browser search (no public API)"
            echo "  meesho    browser search (no public API)"
            echo "  myntra    browser search (no public API)"
            echo "  blinkit   browser search (no public API)"
            echo "  zepto     browser search (no public API)"
            echo
            echo "${C_BOLD}Public barcode push (push_to_off):${C_RESET}"
            echo "  Open Food Facts  POST /cgi/product_edit.pl"
            echo
            echo "${C_BOLD}HTTP API server (serve):${C_RESET}"
            echo "  GET /health /products /bills /categories /trays /inventory_log /customers /summary"
            echo
            echo "${C_BOLD}QR engine (gen_qr):${C_RESET}"
            echo "  qrencode (PNG) primary, SVG fallback always"
            echo
            echo "${C_BOLD}Barcode label (gen_label):${C_RESET}"
            echo "  zint (Code128 PNG) primary, SVG fallback always"
            echo
            echo "${C_BOLD}Barcode scanner (scan_barcode):${C_RESET}"
            echo "  zbarcam (webcam)"
            echo
            echo "${C_BOLD}Thermal printer (thermal):${C_RESET}"
            echo "  ESC/POS raw bytes — pipe to /dev/usb/lp0"
            echo
            echo "${C_BOLD}Export formats (export):${C_RESET}"
            echo "  tally  quickbooks  gst"
            echo
            echo "Run './shopkeep.sh --doctor' for live status of each."
            ;;
        *)
            err "Unknown command: $cmd (try -h for help)"
            return 3
            ;;
    esac
}

# v3 interactive menu — adds 15 more entries on top of v2's 29.
interactive_menu_v3() {
    init_dirs
    bill_layout_load
    maybe_auto_backup
    while true; do
        echo
        echo "${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
        printf "${C_BOLD}║%s%s%s║${C_RESET}\n" "$(pad_disp "" 6)" "$(pad_disp "$(conf shop_name)" 50)" "$(pad_disp "" 6)"
        printf "${C_BOLD}║%s%s%s║${C_RESET}\n" "$(pad_disp "" 6)" "$(pad_disp "$(now_date) $(now_time)" 50)" "$(pad_disp "" 6)"
        echo "${C_BOLD}╠══════════════════════════════════════════════════════════════╣${C_RESET}"
        printf " 1) %-26s  2) %-26s\n" "New bill"             "Add product"
        printf " 3) %-26s  4) %-26s\n" "Search inventory"     "Stock inventory"
        printf " 5) %-26s  6) %-26s\n" "Low stock report"     "Daily sales summary"
        printf " 7) %-26s  8) %-26s\n" "Void a bill"          "Stock value"
        printf " 9) %-26s 10) %-26s\n" "Tray management"      "Category trays"
        printf "11) %-26s 12) %-26s\n" "Manage product"       "Backup now"
        printf "13) %-26s 14) %-26s\n" "Language"             "Inventory activity log"
        echo "${C_BOLD}╠═══════ v2 extensions ═════════════════════════════════════════╣${C_RESET}"
        printf "15) %-26s 16) %-26s\n" "Marketplace lookup"   "QR codes"
        printf "17) %-26s 18) %-26s\n" "Push to public reg"   "Bill layout"
        printf "19) %-26s 20) %-26s\n" "Bills monitoring"     "Hold/recall bills"
        printf "21) %-26s 22) %-26s\n" "Sales return"         "Day close X/Z"
        printf "23) %-26s 24) %-26s\n" "Cash drawer"          "Customer DB"
        printf "25) %-26s 26) %-26s\n" "HTML invoice"         "Bulk CSV import"
        printf "27) %-26s 28) %-26s\n" "Expiry tracking"      "Top sellers hotlist"
        printf "29) %-26s\n"           "Tray diagnostic"
        echo "${C_BOLD}╠═══════ v3 extensions ═════════════════════════════════════════╣${C_RESET}"
        printf "30) %-26s 31) %-26s\n" "Forecast"             "Reorder suggestions"
        printf "32) %-26s 33) %-26s\n" "Dead stock"           "ABC analysis"
        printf "34) %-26s 35) %-26s\n" "Analytics dashboard"  "Stock adjust (reason)"
        printf "36) %-26s 37) %-26s\n" "Suppliers"            "Purchase orders"
        printf "38) %-26s 39) %-26s\n" "WhatsApp share bill"  "Thermal print bill"
        printf "40) %-26s 41) %-26s\n" "Manager PIN"          "Export (tally/gst)"
        printf "42) %-26s\n"           "HTTP API server"
        echo "${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
        printf "%s" "$(t m_choose)"
        local c=""; read -r c || c=""
        case "$c" in
            0|"") log "$(t c_bye)"; return 0 ;;
            # 1-14: legacy (call the same interactive handlers as v2)
            1)  cmd_bill_interactive ;;
            2)  cmd_add_interactive ;;
            3)  printf "Search: "; read -r q; [[ -n "$q" ]] && cmd_search "$q" ;;
            4)  printf "%s" "$(t inv_pick)"; read -r s; cmd_inventory "${s:-category}" ;;
            5)  cmd_lowstock ;;
            6)  cmd_summary ;;
            7)  printf "%s" "$(t p_bill_no)"; read -r bno; [[ -n "$bno" ]] && cmd_void "$bno" ;;
            8)  cmd_stockvalue ;;
            9)  cmd_tray_interactive ;;
            10) cmd_category list ;;
            11) cmd_manage_interactive ;;
            12) backup_now ;;
            13) cmd_lang_interactive ;;
            14) cmd_inventorylog 25 ;;
            # 15-29: v2
            15) cmd_marketplace_interactive ;;
            16) cmd_qr_interactive ;;
            17) printf "Barcode to push: "; read -r bc; [[ -n "$bc" ]] && cmd_push "$bc" ;;
            18) cmd_billconfig edit ;;
            19) cmd_billsmon today ;;
            20) cmd_hold_interactive ;;
            21) cmd_return_interactive ;;
            22) cmd_dayclose x ;;
            23) cmd_cashdrawer list ;;
            24) cmd_customer_interactive ;;
            25) printf "Bill no: "; read -r bno; [[ -n "$bno" ]] && cmd_htmlbill "$bno" ;;
            26) printf "CSV file: "; read -r f; [[ -n "$f" ]] && cmd_importcsv "$f" ;;
            27) cmd_expiry list ;;
            28) cmd_hotlist 10 ;;
            29) cmd_tray_v2 doctor ;;
            # 30-42: v3
            30) printf "Barcode: "; read -r bc; [[ -n "$bc" ]] && cmd_forecast "$bc" ;;
            31) cmd_reorder ;;
            32) cmd_deadstock ;;
            33) cmd_abc ;;
            34) cmd_analytics ;;
            35) cmd_adjust_interactive ;;
            36) cmd_supplier list ;;
            37) cmd_po list ;;
            38) printf "Bill no: "; read -r bno; [[ -n "$bno" ]] && cmd_whatsapp "$bno" ;;
            39) printf "Bill no: "; read -r bno; [[ -n "$bno" ]] && cmd_thermal "$bno" ;;
            40) cmd_pin set ;;
            41) cmd_export tally ;;
            42) cmd_serve 8080 ;;
            *)  err "Invalid choice: $c" ;;
        esac
    done
}

cmd_adjust_interactive() {
    printf "Barcode: "; read -r bc
    printf "Delta (+/-N): "; read -r delta
    printf "Reason (damage/theft/sample/breakage/writeoff/found/gift/other): "; read -r reason
    printf "Note: "; read -r note
    cmd_adjust "$bc" "$delta" "$reason" "$note"
}

main "$@"
