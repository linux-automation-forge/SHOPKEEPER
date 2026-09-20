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
#   ./shopkeep.sh                      # interactive menu loop (11 options + 0 to exit)
#   ./shopkeep.sh add --name "Tata Salt 1kg" --price 25.00 --qty 24 \
#                    [--barcode 8901234567890] [--threshold 8] \
#                    [--desc "..."] [--type Grocery] [--image labels/8901.png]
#   ./shopkeep.sh edit <barcode> [--name X] [--price Y] [--threshold Z] [--desc D] [--type T] [--image I]
#   ./shopkeep.sh restock <barcode> --qty N [--reason "..."]
#   ./shopkeep.sh remove <barcode> [--reason "..."]
#   ./shopkeep.sh search <query>       # by barcode OR name, full details per match
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
LAST_BACKUP_FILE="$DATA_DIR/.last_backup_date"
LABELS_DIR="$SCRIPT_DIR/labels"
BACKUPS_DIR="$SCRIPT_DIR/backups"

BOX_WIDTH=42
MONEY_FIELD=9
MAX_NAME=22
US=$'\x1f'   # unit separator — never appears in product names

VERSION="1.0.0"

# Globals
declare -A P_NAME P_PRICE P_QTY P_THRESHOLD P_DESC P_TYPE P_IMAGE
declare -A TRAY_NAME TRAY_ITEMS   # tray_barcode -> name ; tray_barcode -> "bc:qty bc:qty ..."
declare -a CSV_FIELDS=()
declare -a BILL_LINES=()
ADDED_BARCODE=""
BILL_NO=""
BILL_TS=""
BILL_TOTAL=""
ST_TMP=""

#─────────────────────────────────────────────────────────────────────────────
# Colors (only when stdout is a TTY and NO_COLOR unset)
#─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""
fi

#─────────────────────────────────────────────────────────────────────────────
# Cleanup trap — never leave .new files or stale locks behind
#─────────────────────────────────────────────────────────────────────────────
cleanup() {
    local rc=$?
    if [[ -n "${DATA_DIR:-}" ]]; then
        rm -f "$DATA_DIR"/*.new 2>/dev/null || true
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
    T[en.tray_sub]="Tray: 1) Add  2) List  3) Show  4) Remove  0) Back"
    T[en.p_tray_bc]="Tray barcode"
    T[en.p_tray_name]="Tray name"
    T[en.p_tray_items]="Items (bc:qty,bc:qty)"
    T[en.c_scan_tray]="→ TRAY"
    T[en.c_empty_bill]="Empty bill, nothing saved."
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
    T[hi.ls_stock]="स्टॉक"; T[hi.sv_title]="स्टॉक मूल्य"; T[hi.sv_total]="कुल स्टॉक मूल्य"
    T[hi.sv_items]="उत्पाद"
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
    T[te.m_new_bill]="కొత్త బిల్లు"; T[te.m_add_product]="ఉత్పత్తి చేర్చు"
    T[te.m_low_stock]="తక్కువ స్టాక్ నివేదిక"; T[te.m_summary]="రోజువారీ అమ్మకాల సారాంశం"
    T[te.m_void]="బిల్లు రద్దు"; T[te.m_backup]="ఇప్పుడే బ్యాకప్"
    T[te.m_stock_value]="స్టాక్ విలువ"; T[te.m_language]="భాష"
    T[te.m_exit]="నిష్క్రమణ"; T[te.m_choose]="ఎంచుకోండి: "
    T[te.p_scan]="బార్‌కోడ్ స్కాన్/టైప్ (ముగింపు ఖాళీ, వెతకడానికి s:పదం): "
    T[te.p_qty]="పరిమాణం"; T[te.p_name]="పేరు"; T[te.p_price]="ధర"
    T[te.p_threshold]="పరిమితి"; T[te.r_total]="మొత్తం"; T[te.r_items]="అంశాలు:"; T[te.r_units]="యూనిట్లు:"
    T[te.c_added]="చేర్చబడింది"; T[te.c_bill_saved]="బిల్లు సేవ్ అయింది"
    T[te.c_bye]="వీడుకోలు."; T[te.c_no_low_stock]="తక్కువ-స్టాక్ లేవు. అంతా బాగుంది!"
    T[te.c_lang_changed]="భాష మార్చబడింది:"; T[te.s_bills_processed]="బిల్లులు:"
    T[te.s_units_sold]="అమ్మిన యూనిట్లు:"; T[te.s_revenue]="ఆదాయం:"; T[te.s_avg_bill]="సగటు బిల్లు:"
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
    T[gu.s_voided_bills]="રદ બિલ્સ:"; T[gu.ls_title]="ઓછો સ્ટોક અહેવાલ"; T[gu.ls_deficit]="ઘટાક્કો"
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
    T[or.p_scan]="ବାର୍‌କୋଡ୍ ସ୍କାନ୍/ଟାଇପ୍ (ସମାପ୍ତ ଖାଲି, ଖୋଜିବା s:ଶବ୍ଦ): "
    T[or.p_qty]="ପରିମାଣ"; T[or.p_name]="ନାମ"; T[or.p_price]="ଦାମ୍"
    T[or.p_threshold]="ସୀମା"; T[or.r_total]="ସମୁଦାୟ"; T[or.r_items]="ବସ୍ତୁ:"; T[or.r_units]="ଏକକ:"
    T[or.c_added]="ଯୋଗ ହୋଇଛି"; T[or.c_bill_saved]="ବିଲ୍ ସାଇତାଗଲା"
    T[or.c_bye]="ବିଦାୟ."; T[or.c_no_low_stock]="କମ-ଷ୍ଟକ୍ ନାହିଁ. ସବୁ ଠିକ୍!"
    T[or.c_lang_changed]="ଭାଷା ବଦଳିଛି:"; T[or.s_bills_processed]="ବିଲ୍‌ଗୁଡିକ:"
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
    T[mni.m_low_stock]="য়ামনা স্টক ৰিপোর্ট"; T[mni.m_summary]="নুংঙাইবা ফল্লুপা মীতয়েক"
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
    T[sat.m_low_stock]="ᱠᱚᱢ ᱥᱴᱚᱠ ᱨᱤᱯᱚᱨᱴ"; T[sat.m_summary]="ᱫᱤᱱᱟᱹᱢ ᱵᱤᱠᱨᱤ ᱥᱟᱨᱟᱢ"
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
        printf ' %2d) %-12s  (%s)\n' "$i" "${entry#*:}" "${entry%%:*}"
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
}

#─────────────────────────────────────────────────────────────────────────────
# Inventory activity log — audit trail of stock-in / stock-out / adjustments.
#   timestamp,event,barcode,name,qty,price_paise,detail
#   events: ADD (product added), RESTOCK (qty increased), VOID (bill voided),
#           SELL (reference: bills.csv), PRICE (price changed)
#   One row per event, append-only. Opens in Excel.
#─────────────────────────────────────────────────────────────────────────────
log_event() {
    # args: event barcode name qty price_paise detail
    local event="$1" bc="$2" name="$3" qty="$4" price="$5" detail="$6"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
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
#   TRAY_NAME[tray_bc] = name ; TRAY_ITEMS[tray_bc] = "bc:qty bc:qty ..."
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
# Args: tray_barcode [count]. count defaults to 1 (each item qty * count).
# Returns 0 ok, 1 unknown tray, 2 unknown item in tray.
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
# Atomic catalog rewrite — rewrite products.csv.new then mv (all-or-nothing).
# Preserves ALL 8 columns. If a product is in the optional REMOVE list, it is
# dropped entirely. If in the deltas map (signed int), qty is adjusted.
# args: "barcode delta" ...            (stock adjustments)
# env: optional global _REWRITE_FULL=1 to fully rewrite from P_* arrays
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
        if [[ -n "${deltas[$pbc]+x}" ]]; then
            pqty=$(( pqty + deltas[$pbc] ))
        fi
        printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$(csv_quote "$pbc")" "$(csv_quote "$pname")" "$(csv_quote "$pprice")" \
            "$(csv_quote "$pqty")" "$(csv_quote "$pthr")" "$(csv_quote "$pdesc")" \
            "$(csv_quote "$ptype")" "$(csv_quote "$pimage")" >> "$newfile"
    done < "$PRODUCTS_CSV"
    mv "$newfile" "$PRODUCTS_CSV" || return 1
    return 0
}

# Fully rewrite products.csv from the in-memory P_* arrays (after edits/removes).
# Drops any barcode listed in global _DROP array. Returns 0 ok.
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
        printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$(csv_quote "$bc")" "$(csv_quote "${P_NAME[$bc]}")" "$(csv_quote "${P_PRICE[$bc]}")" \
            "$(csv_quote "${P_QTY[$bc]}")" "$(csv_quote "${P_THRESHOLD[$bc]}")" \
            "$(csv_quote "${P_DESC[$bc]:-}")" "$(csv_quote "${P_TYPE[$bc]:-}")" \
            "$(csv_quote "${P_IMAGE[$bc]:-}")" >> "$newfile"
    done
    mv "$newfile" "$PRODUCTS_CSV" || return 1
    return 0
}

#─────────────────────────────────────────────────────────────────────────────
# Optional barcode scanning (zbarcam) and label printing (zint)
#─────────────────────────────────────────────────────────────────────────────
scan_barcode() {
    command -v zbarcam >/dev/null || return 1
    local code
    code=$(timeout "${SCAN_TIMEOUT:-60}" zbarcam --raw 2>/dev/null | head -n1) || true
    code="${code%$'\n'}"
    if [[ -n "$code" ]]; then printf '%s' "$code"; return 0; fi
    return 1
}

gen_label() {
    local bc="$1" out="$2"
    command -v zint >/dev/null || return 1
    mkdir -p "$LABELS_DIR"
    zint -b CODE128 -o "$out" -d "$bc" 2>/dev/null || return 1
    [[ -f "$out" ]]
}

#─────────────────────────────────────────────────────────────────────────────
# Box-drawing receipt helpers
#─────────────────────────────────────────────────────────────────────────────
box_top()    { printf '┌%s┐\n' "$(repeat_str '─' "$BOX_WIDTH")"; }
box_mid()    { printf '├%s┤\n' "$(repeat_str '─' "$BOX_WIDTH")"; }
box_bottom() { printf '└%s┘\n' "$(repeat_str '─' "$BOX_WIDTH")"; }

box_row() {
    local content="$1" len pad
    len=${#content}
    pad=$((BOX_WIDTH - len)); (( pad >= 0 )) || pad=0
    printf '│%s%*s│\n' "$content" "$pad" ""
}

box_center() {
    local text="$1" len pad rest content
    text="$(truncate_name "$text" $BOX_WIDTH)"
    len=${#text}
    pad=$(( (BOX_WIDTH - len) / 2 ))
    (( pad >= 0 )) || pad=0
    content="$(repeat_str ' ' "$pad")$text"
    rest=$((BOX_WIDTH - ${#content})); (( rest >= 0 )) || rest=0
    content="$content$(repeat_str ' ' "$rest")"
    printf '│%s│\n' "$content"
}

box_lr() {
    local left="$1" right="$2" gap llen rlen content
    llen=${#left}; rlen=${#right}
    gap=$((BOX_WIDTH - llen - rlen)); (( gap >= 1 )) || gap=1
    content="$left$(repeat_str ' ' "$gap")$right"
    box_row "$content"
}

# title, total_label, bill_no, ts, total_paise, then line items (US-delimited)
print_receipt() {
    local title="$1" total_label="$2" bill_no="$3" ts="$4" total="$5"
    shift 5
    local lines=("$@")
    local n=${#lines[@]} units=0 line bc name up qty lt
    box_top
    box_center "$title"
    box_center "Bill #$(printf '%04d' "$bill_no")"
    box_center "$ts"
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
# 2 stock-update fail (SELL rows + VOID reversal written, bill_no consumed).
# Cart items are "barcode qty" strings.
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

    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')

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
        # stock update failed — ledger must not lie. Append VOID reversal
        # (stock was NOT decremented, so no stock change needed here).
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
    # args: bc name price_paise qty threshold [description] [type] [image]
    local bc="$1" name="$2" price="$3" qty="$4" thr="$5"
    local desc="${6:-}" ptype="${7:-}" image="${8:-}"
    init_dirs
    lock
    load_products
    if [[ -z "$bc" ]]; then bc=$(gen_internal_barcode); fi
    if [[ -n "${P_NAME[$bc]+x}" ]]; then
        unlock; err "Duplicate barcode $bc → ${P_NAME[$bc]}"; return 1
    fi
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_quote "$bc")" "$(csv_quote "$name")" "$price" "$qty" "$thr" \
        "$(csv_quote "$desc")" "$(csv_quote "$ptype")" "$(csv_quote "$image")" >> "$PRODUCTS_CSV"
    ADDED_BARCODE="$bc"
    log_event "ADD" "$bc" "$name" "$qty" "$price" "new product, threshold=$thr, type=$ptype"
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
# show_product — print full details for one barcode (the "scan reveals details").
# Args: barcode [compact]. compact=1 omits the trailing blank line.
#─────────────────────────────────────────────────────────────────────────────
show_product() {
    local bc="$1" compact="${2:-0}"
    if [[ -z "${P_NAME[$bc]+x}" ]]; then
        err "No product with barcode $bc"; return 1
    fi
    local name="${P_NAME[$bc]}" price="${P_PRICE[$bc]}" qty="${P_QTY[$bc]}"
    local thr="${P_THRESHOLD[$bc]}" desc="${P_DESC[$bc]:-}" ptype="${P_TYPE[$bc]:-}" image="${P_IMAGE[$bc]:-}"
    printf "  ${C_BOLD}📷 %s${C_RESET}\n" "$name"
    printf "     %-11s %s\n" "$(t p_barcode):" "$bc"
    printf "     %-11s %s\n" "$(t p_price):" "$(fmt_money "$price")"
    printf "     %-11s %s\n" "Stock:" "$qty   ($(t p_threshold): $thr)"
    if [[ -n "$ptype" ]]; then printf "     %-11s %s\n" "$(t p_type):" "$ptype"; fi
    if [[ -n "$desc" ]];   then printf "     %-11s %s\n" "$(t p_desc):" "$desc"; fi
    if [[ -n "$image" ]]; then
        if [[ -f "$image" ]]; then
            printf "     %-11s ${C_GREEN}%s [exists]${C_RESET}\n" "$(t p_image):" "$image"
        else
            printf "     %-11s %s (not found)\n" "$(t p_image):" "$image"
        fi
    fi
    if (( compact == 0 )); then echo; fi
    return 0
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: remove <barcode> [--reason "..."]  — delete a product (logged)
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
# CLI command: restock <barcode> --qty N [--reason "..."]  — add to existing stock
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
# CLI command: edit <barcode> [--name X] [--price Y] [--threshold Z] [--desc D] [--type T] [--image I]
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
    # apply changes to in-memory
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
# CLI command: search <query> — search by barcode OR name (substring, any case).
# Big scrollable list (all matches), shows full details per product.
#─────────────────────────────────────────────────────────────────────────────
cmd_search() {
    local query="${1:-}"
    [[ -n "$query" ]] || { err "Usage: shopkeep.sh search <query>"; exit 3; }
    init_dirs; load_products
    local q="${query,,}" bc name matches=()
    for bc in "${!P_NAME[@]}"; do
        name="${P_NAME[$bc]}"
        if [[ "$bc" == *"$query"* || "${name,,}" == *"$q"* ]]; then
            matches+=("$bc")
        fi
    done
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
# CLI command: tray — manage Blinkit-style trays (scan tray -> add all items)
#   tray add <tray_barcode> --name "Combo" --items "bc1:qty,bc2:qty,..."
#   tray list
#   tray show <tray_barcode>
#   tray remove <tray_barcode>
#─────────────────────────────────────────────────────────────────────────────
cmd_tray() {
    local sub="${1:-}"
    [[ -n "$sub" ]] || { err "Usage: shopkeep.sh tray add|list|show|remove ..."; exit 3; }
    shift
    init_dirs
    case "$sub" in
        add)
            local tbc="${1:-}" tname="" itemspec=""
            shift 2>/dev/null || true
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --name)  [[ $# -ge 2 ]] || { err "--name needs a value"; exit 3; }; tname="$2"; shift 2 ;;
                    --items) [[ $# -ge 2 ]] || { err "--items needs a value"; exit 3; }; itemspec="$2"; shift 2 ;;
                    *) err "Unknown arg: $1"; exit 3 ;;
                esac
            done
            [[ -n "$tbc" && -n "$tname" && -n "$itemspec" ]] || { err "Usage: tray add <tray_barcode> --name \"Combo\" --items \"bc1:qty,bc2:qty\""; exit 3; }
            [[ "$tbc" =~ ^[0-9]+$ ]] || { err "tray_barcode must be digits"; exit 1; }
            lock; load_products; load_trays
            # remove existing tray (if any) then rewrite trays.csv without it
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
            # validate + append items
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
            [[ -n "$tbc" ]] || { err "Usage: tray show <tray_barcode>"; exit 3; }
            lock; load_products; load_trays
            if [[ -z "${TRAY_NAME[$tbc]+x}" ]]; then unlock; err "No tray $tbc"; return 1; fi
            echo "${C_BOLD}Tray: ${TRAY_NAME[$tbc]} ($tbc)${C_RESET}"
            echo "$(repeat_str '─' 48)"
            local items="${TRAY_ITEMS[$tbc]}" item ibc iqt
            for item in $items; do
                ibc="${item%%:*}"; iqt="${item#*:}"
                printf "  %-22s x%-3s  %s\n" "$(truncate_name "${P_NAME[$ibc]}" 22)" "$iqt" "$(fmt_money "${P_PRICE[$ibc]}")"
            done
            unlock
            ;;
        remove)
            local tbc="${1:-}"
            [[ -n "$tbc" ]] || { err "Usage: tray remove <tray_barcode>"; exit 3; }
            lock; load_trays
            if [[ -z "${TRAY_NAME[$tbc]+x}" ]]; then unlock; err "No tray $tbc"; return 1; fi
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
            err "Unknown tray subcommand: $sub"; exit 3 ;;
    esac
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: bill (reads barcode/qty lines from stdin)
#─────────────────────────────────────────────────────────────────────────────
cmd_bill() {
    init_dirs
    command -v flock >/dev/null || { err "flock required"; exit 2; }
    # load trays once so tray barcodes on stdin can be expanded (Blinkit-style)
    lock; load_products; load_trays; unlock
    local cart=() line bc q
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]]; then continue; fi
        read -r bc q <<< "$line"
        if [[ -z "$q" ]]; then q=1; fi
        if ! [[ "$bc" =~ ^[0-9]+$ ]]; then err "Bad barcode: $bc"; continue; fi
        if ! [[ "$q" =~ ^[0-9]+$ ]] || (( q <= 0 )); then err "Bad qty: $q"; continue; fi
        # tray? expand to its items, multiplied by tray count
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
        print_receipt "$(conf shop_name)" "$(t r_total)" "$BILL_NO" "$BILL_TS" "$BILL_TOTAL" "${BILL_LINES[@]}"
        log "Bill #$BILL_NO saved. Total $(fmt_money "$BILL_TOTAL")"
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
    printf "%-8s  %-7s  %-10s  %-14s  %s\n" "Deficit" "Stock" "Threshold" "Barcode" "Name"
    echo "$(repeat_str '─' 64)"
    local deficit qty thr name color
    while IFS=$'\t' read -r deficit bc qty thr name; do
        if [[ -z "$deficit" ]]; then continue; fi
        if   (( qty == 0 ));   then color="$C_RED"
        elif (( qty < thr ));  then color="$C_YELLOW"
        else                       color="$C_CYAN"; fi
        printf "%s%-8s  %-7s  %-10s  %-14s  %s%s\n" \
            "$color" "$deficit" "$qty" "$thr" "$bc" "$name" "$C_RESET"
    done <<< "$sorted"
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: summary [YYYY-MM-DD]
#─────────────────────────────────────────────────────────────────────────────
cmd_summary() {
    local date="${1:-}"
    if [[ -z "$date" ]]; then date=$(date +%Y-%m-%d); fi
    [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { err "Bad date: $date (use YYYY-MM-DD)"; return 1; }
    init_dirs
    if [[ ! -s "$BILLS_CSV" ]] || (( $(wc -l < "$BILLS_CSV") <= 1 )); then
        log "No bills recorded."; return 0
    fi

    # Portable parse: bash parse_csv_line (no FPAT — works on mawk-only systems).
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
# CLI command: stockvalue — total worth of items currently in storage
#   (sum of price_paise * qty across all products). Also logs a snapshot.
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

    echo "${C_BOLD}$(t sv_title)${C_RESET}  ($(date '+%Y-%m-%d %H:%M:%S'))"
    echo "$(repeat_str '─' 56)"
    printf "  %-22s  %8s  %6s  %12s\n" "$(t p_name)" "$(t p_qty)" "$(t p_price)" "$(t sv_value)"
    echo "$(repeat_str '─' 56)"
    local row val u nm pr qt
    while IFS='|' read -r val bc nm pr qt; do
        if [[ -z "$val" ]]; then continue; fi
        printf "  %-22s  %8s  %6s  %12s\n" \
            "$(truncate_name "$nm" 22)" "$qt" "$(fmt_money "$pr")" "$(fmt_money_field "$val" 12)"
    done <<< "$sorted"
    echo "$(repeat_str '─' 56)"
    printf "  ${C_BOLD}%-22s  %8s  %6s  %12s${C_RESET}\n" "$(t sv_total) ($n $(t sv_items))" "" "" "$(fmt_money_field "$total" 12)"
    log_event "STOCKVALUE" "-" "all" "-" "$total" "inventory valuation snapshot"
}

#─────────────────────────────────────────────────────────────────────────────
# CLI command: lang [code] — get or set the UI language
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
# CLI command: inventorylog [N] — show last N inventory activity entries
#   (which item was added / voided / valued, and when). Default N = 25.
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

    # show the bill for confirmation
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

    local ts_now; ts_now=$(date '+%Y-%m-%d %H:%M:%S')

    # append VOID rows (one write each)
    for ((i=0; i<${#rbc[@]}; i++)); do
        printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$bill_no" "$ts_now" "$(csv_quote "${rbc[$i]}")" "$(csv_quote "${rname[$i]}")" \
            "${rqt[$i]}" "${rup[$i]}" "${rlt[$i]}" "VOID" >> "$BILLS_CSV"
    done

    # restore stock atomically
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
    # log each voided line to the inventory activity log (audit trail)
    for ((i=0; i<${#rbc[@]}; i++)); do
        log_event "VOID" "${rbc[$i]}" "${rname[$i]}" "${rqt[$i]}" "${rup[$i]}" "voided bill #$bill_no"
    done
    log "Bill #$bill_no voided. Stock restored."
    echo
    local -a vlines=()
    for ((i=0; i<${#rbc[@]}; i++)); do
        vlines+=("${rbc[$i]}${US}${rname[$i]}${US}${rup[$i]}${US}${rqt[$i]}${US}${rlt[$i]}")
    done
    print_receipt "VOID REVERSAL" "$(t r_reversed)" "$bill_no" "$ts_now" "$total" "${vlines[@]}"
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
    local ts; ts=$(date +%Y%m%d-%H%M%S)
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
    local today; today=$(date +%Y-%m-%d)
    local last=""
    if [[ -f "$LAST_BACKUP_FILE" ]]; then last=$(cat "$LAST_BACKUP_FILE" 2>/dev/null || true); fi
    if [[ "$last" != "$today" ]]; then
        if backup_now >/dev/null 2>&1; then
            printf '%s\n' "$today" > "$LAST_BACKUP_FILE"
        fi
    fi
}

#─────────────────────────────────────────────────────────────────────────────
# Doctor — probe dependencies, report status + install commands
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
    printf "  %-18s %s\n" "state:"          "$STATE_FILE"
    printf "  %-18s %s\n" "config:"         "$CONF_FILE"
    printf "  %-18s %s\n" "labels:"         "$LABELS_DIR"
    printf "  %-18s %s\n" "backups:"        "$BACKUPS_DIR"
    if [[ -f "$PRODUCTS_CSV" ]]; then
        local pcount; pcount=$(( $(wc -l < "$PRODUCTS_CSV") - 1 ))
        (( pcount >= 0 )) || pcount=0
        printf "  %-18s %d products\n" "Catalog size:" "$pcount"
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
    # bash 4+
    if (( BASH_VERSINFO[0] >= 4 )); then
        printf "  bash 4+          %sOK%s (%s.%s.%s)\n" "$C_GREEN" "$C_RESET" \
            "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" "${BASH_VERSINFO[2]}"
    else
        printf "  bash 4+          %sFAIL%s (%s.%s)\n" "$C_RED" "$C_RESET" \
            "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"
    fi
    # coreutils components
    local ok_core=1 missing_core=""
    for c in printf mv rm sort head cut wc date mkdir ls; do
        command -v "$c" >/dev/null || { ok_core=0; missing_core+=" $c"; }
    done
    if (( ok_core )); then
        printf "  coreutils       %sOK%s\n" "$C_GREEN" "$C_RESET"
    else
        printf "  coreutils       %sMISSING%s (%s )  install: sudo apt install coreutils\n" "$C_RED" "$C_RESET" "$missing_core"
    fi
    # awk
    if command -v awk >/dev/null; then
        local awkver; awkver=$(awk 'BEGIN{print "GNU awk " PROCINFO["version"]}' 2>/dev/null || awk --version 2>/dev/null | head -1 || echo "awk")
        printf "  awk              %sOK%s (%s)\n" "$C_GREEN" "$C_RESET" "$(command -v awk)"
    else
        printf "  awk              %sMISSING%s  install: sudo apt install gawk\n" "$C_RED" "$C_RESET"
    fi
    # flock
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
        printf "  zbarcam          %sMISSING%s  webcam scan disabled (type barcode instead)  install: sudo apt install zbar-tools\n" "$C_YELLOW" "$C_RESET"
    fi
    if command -v zint >/dev/null; then
        printf "  zint             %sOK%s (%s)  label printing (Code128 PNG)\n" "$C_GREEN" "$C_RESET" "$(command -v zint)"
    else
        printf "  zint             %sMISSING%s  label printing disabled  install: sudo apt install zint\n" "$C_YELLOW" "$C_RESET"
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
    printf "  backup: %s   webcam-scan: %s   labels: %s   languages: 23 (en + 22 Indian)\n" \
        "$(command -v tar >/dev/null && echo yes || echo no)" \
        "$(command -v zbarcam >/dev/null && echo yes || echo no)" \
        "$(command -v zint >/dev/null && echo yes || echo no)"
    echo
    echo "${C_BOLD}How barcodes/labels work:${C_RESET}"
    echo "  - Type the barcode digits, OR scan with webcam (zbarcam) if installed."
    echo "  - No barcode on the product? Leave blank -> an internal EAN-13"
    echo "    (20-prefix, the global in-store range) is auto-assigned so every"
    echo "    item is scannable."
    echo "  - 'zint' (if installed) renders a printable Code128 PNG to labels/<barcode>.png."
    echo "  - Note: there is no webcam in this sandbox, so zbarcam is OFF here;"
    echo "    you can always TYPE the barcode — both paths store the product by barcode."
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

    # 1) money math
    st_test "money math (25.5->2550, etc.)" _st_money
    # 2) CSV roundtrip with comma + quote
    st_test "CSV roundtrip (comma + quote)" _st_csv
    # 3) negative stock rejection
    st_test "negative stock rejection" _st_negstock
    # 4) atomic write + flock (two concurrent updates)
    st_test "atomic write + flock" _st_concurrency
    # 5) low stock sort order
    st_test "low stock sort order" _st_lowstock
    # 6) daily summary math
    st_test "daily summary math" _st_summary
    # 7) remove + restock (new)
    st_test "remove + restock" _st_remove_restock
    # 8) tray (Blinkit-style) expansion
    st_test "tray expansion" _st_tray

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
    # invalid must fail
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
    # restock +5 -> 15
    cmd_restock 9001 --qty 5 >/dev/null 2>&1 || return 1
    local q; q=$(awk -F, '$1==9001{print $4}' "$PRODUCTS_CSV")
    [[ "$q" == "15" ]] || return 1
    # remove (with reason, forced)
    FORCE_REMOVE=1 cmd_remove 9001 --reason "end of line" >/dev/null 2>&1 || return 1
    # product should be gone
    if grep -q "^9001," "$PRODUCTS_CSV"; then return 1; fi
    # inventory_log should have REMOVE row mentioning the reason
    if ! grep -q "REMOVE.*end of line" "$INVENTORY_LOG"; then return 1; fi
    return 0
}

_st_tray() {
    do_add "9101" "ItemA" 1000 5 0 "" "" "" >/dev/null 2>&1 || return 1
    do_add "9102" "ItemB" 2000 5 0 "" "" "" >/dev/null 2>&1 || return 1
    cmd_tray add "9900" --name "Combo" --items "9101:1,9102:2" >/dev/null 2>&1 || return 1
    # expand_tray needs P_* loaded
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
    # commit a bill built from the expanded tray
    if ! commit_bill "${traycart[@]}" >/dev/null 2>&1; then return 1; fi
    # stock should now be 9101:4, 9102:3
    local q1 q2
    q1=$(awk -F, '$1==9101{print $4}' "$PRODUCTS_CSV")
    q2=$(awk -F, '$1==9102{print $4}' "$PRODUCTS_CSV")
    [[ "$q1" == "4" ]] || return 1
    [[ "$q2" == "3" ]] || return 1
    return 0
}

#─────────────────────────────────────────────────────────────────────────────
# Generate project files: README, LICENSE, requirements.txt, .gitignore
#─────────────────────────────────────────────────────────────────────────────
cmd_gen_files() {
    cat > "$SCRIPT_DIR/shopkeep.README.md" <<'EOF'
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
 1) New bill   2) Add product   3) Low stock report
 4) Daily sales summary   5) Void a bill   6) Backup now   0) Exit
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
barcode,name,price_paise,qty,threshold
```
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
EOF
    log "Wrote $SCRIPT_DIR/shopkeep.README.md"

    cat > "$SCRIPT_DIR/LICENSE" <<'EOF'
MIT License

Copyright (c) 2025 shopkeep.sh contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
    log "Wrote $SCRIPT_DIR/LICENSE"

    cat > "$SCRIPT_DIR/shopkeep.requirements.txt" <<'EOF'
# shopkeep.sh requirements
#
# Required:
#   bash >= 4
#   coreutils (printf, mv, rm, sort, head, cut, wc, date, mkdir, ls)
#   awk (any POSIX awk; CSV quoted-field parsing is done in pure bash, so this
#        works on mawk as well as gawk)
#   flock (util-linux)
#
# Optional (degrade gracefully if missing):
#   zbarcam   # webcam barcode scan   — sudo apt install zbar-tools
#   zint      # label PNG generation  — sudo apt install zint
#   tar       # backups               — sudo apt install tar
EOF
    log "Wrote $SCRIPT_DIR/shopkeep.requirements.txt"

    cat > "$SCRIPT_DIR/.gitignore" <<'EOF'
shopkeep-data/
labels/
backups/
EOF
    log "Wrote $SCRIPT_DIR/.gitignore"
}

#─────────────────────────────────────────────────────────────────────────────
# Help
#─────────────────────────────────────────────────────────────────────────────
cmd_help() {
    cat <<EOF
${C_BOLD}shopkeep.sh${C_RESET} — offline POS + inventory for kirana stores.

${C_BOLD}USAGE${C_RESET}
  ./shopkeep.sh                       interactive menu (0 to exit)

${C_BOLD}NON-INTERACTIVE MODES${C_RESET}

  Add a product (barcode auto-assigned if omitted; type/desc/image optional):
    ./shopkeep.sh add --name "Tata Salt 1kg" --price 25.00 --qty 24 \\
                    [--barcode 8901234567890] [--threshold 8]
                    [--desc "..."] [--type Grocery] [--image labels/8901.png]

  Edit a product (any subset of fields):
    ./shopkeep.sh edit <barcode> [--name X] [--price Y] [--threshold Z] \\
                    [--desc D] [--type T] [--image I]

  Restock (add to existing stock, logged):
    ./shopkeep.sh restock <barcode> --qty N [--reason "..."]

  Remove a product (logged with reason):
    ./shopkeep.sh remove <barcode> [--reason "..."]

  Search inventory (by barcode OR name, full details for each match):
    ./shopkeep.sh search "salt"

  Tray (combo) management — scan a tray barcode to add ALL its items at once:
    ./shopkeep.sh tray add <tray_barcode> --name "Combo" --items "8901:1,8902:2"
    ./shopkeep.sh tray list
    ./shopkeep.sh tray show <tray_barcode>
    ./shopkeep.sh tray remove <tray_barcode>

  Bill (reads "barcode qty" lines from stdin; qty defaults to 1; trays expand):
    printf '8901234567890 2\\n8901234567891 1\\n' | ./shopkeep.sh bill

  Low stock report:
    ./shopkeep.sh lowstock

  Daily sales summary (default today):
    ./shopkeep.sh summary
    ./shopkeep.sh summary 2025-01-15

  Void a bill (append-only — never deletes):
    ./shopkeep.sh void 7

  Stock value (total worth of items in storage):
    ./shopkeep.sh stockvalue

  Backup now (cron-friendly):
    ./shopkeep.sh backup

  Inventory activity log (which item added / voided / restocked / removed, when):
    ./shopkeep.sh inventorylog           # last 25
    ./shopkeep.sh inventorylog 50        # last 50

  Language (23 total: English + 22 scheduled Indian languages):
    ./shopkeep.sh lang                    # show current + supported list
    ./shopkeep.sh lang hi                 # set UI to Hindi
    ./shopkeep.sh lang ta                 # Tamil; also: bn te mr ur gu kn or
                                          #         ml pa as mai sa ne sd
                                          #         kok doi mni sat brx bho

${C_BOLD}MAINTENANCE${C_RESET}
  ./shopkeep.sh --doctor      dependency probe + data file locations
  ./shopkeep.sh --selftest    offline integrity self-test
  ./shopkeep.sh --gen-files   write shopkeep.README.md, LICENSE, shopkeep.requirements.txt, .gitignore
  ./shopkeep.sh -h | --help   this help
  ./shopkeep.sh -V | --version

${C_BOLD}EXIT CODES${C_RESET}
  0  ok
  1  validation error or self-test failure
  2  missing required dependency
  3  bad usage

${C_BOLD}EXAMPLE WORKFLOW${C_RESET}
  ./shopkeep.sh add --name "Parle-G" --price 5 --qty 50 --barcode 8901 --type Snacks
  ./shopkeep.sh add --name "Amul Milk 500ml" --price 28 --qty 12 --barcode 8902
  ./shopkeep.sh tray add 9900 --name "Morning Combo" --items "8901:1,8902:2"
  printf '9900\\n' | ./shopkeep.sh bill              # tray -> both items
  ./shopkeep.sh search "amul"                       # full details on match
  ./shopkeep.sh edit 8901 --price 6 --desc "glucose biscuit"
  ./shopkeep.sh restock 8902 --qty 6 --reason "new delivery"
  ./shopkeep.sh lowstock
  ./shopkeep.sh stockvalue
  ./shopkeep.sh summary
  ./shopkeep.sh inventorylog
  ./shopkeep.sh remove 8901 --reason "discontinued"
  ./shopkeep.sh void 1

${C_BOLD}INTERACTIVE MENU${C_RESET}
  No arguments -> numbered menu with 11 options + 0 to exit:
  1 New bill  2 Add product  3 Manage product  4 Search  5 Low stock
  6 Daily summary  7 Void a bill  8 Stock value  9 Tray  10 Backup  11 Language.
  The menu shows your data directory and every CSV path. Choose 11 to
  switch the UI language (saved to shopkeep.conf). Scanning a product shows
  its full details (image/type/price/description/stock).

Data lives in ./shopkeep-data/ (CSV, opens in Excel). See shopkeep.README.md
for full schemas, the billing flow, threshold explanation, and limitations.
EOF
}

cmd_version() {
    printf 'shopkeep.sh %s\n' "$VERSION"
}

#─────────────────────────────────────────────────────────────────────────────
# Interactive menu actions
#─────────────────────────────────────────────────────────────────────────────
search_products() {
    local query="$1" bc="" name="" i=1
    declare -a matches=()
    for bc in "${!P_NAME[@]}"; do
        name="${P_NAME[$bc]}"
        if [[ "${name,,}" == *"${query,,}"* ]]; then
            printf '%d) %s  %s  stock:%s  %s\n' "$i" "$bc" "$name" "${P_QTY[$bc]}" "$(fmt_money "${P_PRICE[$bc]}")" >&2
            matches+=("$bc")
            i=$((i+1))
        fi
    done
    if (( ${#matches[@]} == 0 )); then echo "No matches." >&2; return 1; fi
    printf 'Pick number (blank to cancel): ' >&2
    local pick; read -r pick || pick=""
    [[ -n "$pick" ]] || return 1
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#matches[@]} )); then
        printf '%s' "${matches[$((pick-1))]}"
        return 0
    fi
    return 1
}

new_bill_interactive() {
    init_dirs
    command -v flock >/dev/null || { err "flock required"; return 1; }
    lock; load_products; load_trays; unlock   # snapshot for display/search/tray

    local cart=() input bc q tcount
    echo "${C_BOLD}--- $(t m_new_bill) ---${C_RESET}"
    while true; do
        printf '%s' "$(t p_scan)"
        read -r input || { echo; break; }
        if [[ -z "$input" ]]; then break; fi
        bc=""
        if [[ "$input" == s:* ]]; then
            local query="${input#s:}"
            if [[ -z "$query" ]]; then err "search needs text after s:"; continue; fi
            bc=$(search_products "$query") || { echo "  $(t c_cancelled)"; continue; }
        elif [[ "$input" =~ ^[0-9]+$ ]]; then
            bc="$input"
        else
            err "Invalid input. Use a barcode, s:<query>, or blank to finish."
            continue
        fi
        # Tray? expand to its items (Blinkit-style: scan tray -> all items listed)
        if [[ -n "${TRAY_NAME[$bc]+x}" ]]; then
            echo "  ${C_CYAN}$(t c_scan_tray): ${TRAY_NAME[$bc]} ($bc)${C_RESET}"
            local expanded
            if ! expanded=$(expand_tray "$bc" 1); then
                err "Tray $bc references an unknown item — fix in tray management."
                continue
            fi
            # validate stock per item first
            local bad=0 line ibc iqt
            while read -r ibc iqt; do
                if [[ -z "$ibc" ]]; then continue; fi
                if [[ -z "${P_NAME[$ibc]+x}" ]]; then bad=1; break; fi
                if (( iqt > ${P_QTY[$ibc]} )); then
                    err "Shortfall in tray: ${P_NAME[$ibc]} need $iqt, have ${P_QTY[$ibc]}"
                    bad=1; break
                fi
            done <<< "$expanded"
            if (( bad )); then continue; fi
            tcount=0
            while read -r ibc iqt; do
                if [[ -z "$ibc" ]]; then continue; fi
                cart+=("$ibc $iqt")
                echo "  -> $(t c_added) ${P_NAME[$ibc]} x$iqt  ($(t r_items) ${#cart[@]})"
                tcount=$((tcount+1))
            done <<< "$expanded"
            echo "  $(t c_tray_expanded): ${TRAY_NAME[$bc]} -> $tcount items"
            continue
        fi
        if [[ -z "${P_NAME[$bc]+x}" ]]; then err "Product not found: $bc"; continue; fi
        # Show FULL details on scan (name/type/price/desc/image/stock)
        show_product "$bc" 1
        echo
        printf '%s [1]: ' "$(t p_qty)"
        read -r q || q=1
        if [[ -z "$q" ]]; then q=1; fi
        if ! [[ "$q" =~ ^[0-9]+$ ]] || (( q <= 0 )); then err "Bad qty."; continue; fi
        if (( q > ${P_QTY[$bc]} )); then err "Only ${P_QTY[$bc]} in stock. Re-enter."; continue; fi
        cart+=("$bc $q")
        echo "  -> $(t c_added) x$q  ($(t r_items) ${#cart[@]})"
    done

    if (( ${#cart[@]} == 0 )); then log "$(t c_empty_bill)"; return 0; fi

    if commit_bill "${cart[@]}"; then
        echo
        print_receipt "$(conf shop_name)" "$(t r_total)" "$BILL_NO" "$BILL_TS" "$BILL_TOTAL" "${BILL_LINES[@]}"
        log "$(t c_bill_saved) #$BILL_NO  $(fmt_money "$BILL_TOTAL")"
    else
        local rc=$?
        if (( rc == 2 )); then
            err "Bill #$BILL_NO failed stock update; reversed. Check bills.csv."
        else
            err "Bill not saved (validation error — stock may have changed)."
        fi
        return 1
    fi
}

interactive_add() {
    echo "${C_BOLD}--- $(t m_add_product) ---${C_RESET}"
    local bc=""

    if command -v zbarcam >/dev/null; then
        printf '%s' "$(t p_scan_webcam)"
        local yn; read -r yn || yn=""
        if [[ "$yn" =~ ^[yY] ]]; then
            local scanned; scanned=$(scan_barcode) || scanned=""
            if [[ -n "$scanned" ]]; then bc="$scanned"; echo "Scanned: $bc"; else err "Scan failed."; fi
        fi
    fi

    if [[ -z "$bc" ]]; then
        printf '%s (blank=auto): ' "$(t p_barcode)"
        read -r bc || bc=""
        if [[ -n "$bc" ]] && ! [[ "$bc" =~ ^[0-9]+$ ]]; then err "Barcode must be digits only."; return 1; fi
    fi

    printf '%s: ' "$(t p_name)"; local name; read -r name || return 1
    [[ -n "$name" ]] || { err "Name is required."; return 1; }

    printf '%s: ' "$(t p_price)"; local price; read -r price || return 1
    printf '%s: ' "$(t p_qty)"; local qty; read -r qty || qty=0
    local dthr; dthr=$(conf default_threshold)
    printf '%s [%s]: ' "$(t p_threshold)" "$dthr"; local thr; read -r thr || thr=""
    [[ -n "$thr" ]] || thr="$dthr"
    # Optional fields (press Enter to skip)
    printf '%s (optional): ' "$(t p_type)"; local ptype; read -r ptype || ptype=""
    printf '%s (optional): ' "$(t p_desc)"; local desc; read -r desc || desc=""
    printf '%s (optional): ' "$(t p_image)"; local image; read -r image || image=""

    local ppaise
    ppaise=$(rupees_to_paise "$price") || { err "Invalid price '$price'."; return 1; }
    (( ppaise > 0 )) || { err "Price must be > 0."; return 1; }
    [[ "$qty" =~ ^[0-9]+$ ]] || { err "Qty must be >= 0."; return 1; }
    [[ "$thr" =~ ^[0-9]+$ ]] || { err "Threshold must be >= 0."; return 1; }

    do_add "$bc" "$name" "$ppaise" "$qty" "$thr" "$desc" "$ptype" "$image" || return 1

    if command -v zint >/dev/null; then
        printf '%s' "$(t p_print_label)"
        local yn2; read -r yn2 || yn2=""
        if [[ "$yn2" =~ ^[yY] ]]; then
            local out="$LABELS_DIR/$ADDED_BARCODE.png"
            if gen_label "$ADDED_BARCODE" "$out"; then log "Label: $out"; else err "Label generation failed."; fi
        fi
    fi
}

interactive_void() {
    printf '%s' "$(t p_bill_no)"
    local bno; read -r bno || return 1
    [[ -n "$bno" ]] || return 1
    [[ "$bno" =~ ^[0-9]+$ ]] || { err "Bad bill no."; return 1; }
    void_bill "$bno" 1 || return 1
}

interactive_menu() {
    command -v flock >/dev/null || die "flock required (install util-linux)"
    init_dirs
    # load saved language from conf and translate the UI
    LANG_CODE=$(conf lang en)
    i18n_init
    maybe_auto_backup
    while true; do
        echo
        echo "${C_BOLD}=== $(conf shop_name) ===${C_RESET}"
        echo " ${C_CYAN}$(t d_data_dir): $DATA_DIR${C_RESET}"
        echo " 1) $(t m_new_bill)"
        echo " 2) $(t m_add_product)"
        echo " 3) $(t m_manage)"
        echo " 4) $(t m_search)"
        echo " 5) $(t m_low_stock)"
        echo " 6) $(t m_summary)"
        echo " 7) $(t m_void)"
        echo " 8) $(t m_stock_value)"
        echo " 9) $(t m_tray)"
        echo "10) $(t m_backup)"
        echo "11) $(t m_language)"
        echo " 0) $(t m_exit)"
        printf '%s' "$(t m_choose)"
        local choice; read -r choice || { echo; break; }
        case "$choice" in
            1) new_bill_interactive ;;
            2) interactive_add ;;
            3) interactive_manage ;;
            4) interactive_search ;;
            5) cmd_lowstock ;;
            6) cmd_summary ;;
            7) interactive_void ;;
            8) cmd_stockvalue ;;
            9) interactive_tray ;;
            10) backup_now ;;
            11) interactive_lang ;;
            0) log "$(t c_bye)"; break ;;
            *) err "Invalid choice" ;;
        esac
    done
}

# Interactive manage product submenu (edit / restock / remove)
interactive_manage() {
    printf 'Barcode: '
    local bc; read -r bc || return
    if [[ -z "$bc" ]]; then return; fi
    if [[ ! "$bc" =~ ^[0-9]+$ ]]; then err "Bad barcode."; return; fi
    init_dirs; lock; load_products; unlock
    if [[ -z "${P_NAME[$bc]+x}" ]]; then err "No product with barcode $bc"; return; fi
    show_product "$bc"
    echo " $(t manage_sub)"
    printf '%s' "$(t m_choose)"
    local c; read -r c || c=""
    case "$c" in
        1) interactive_edit "$bc" ;;
        2) interactive_restock "$bc" ;;
        3) interactive_remove "$bc" ;;
        0|"") return ;;
        *) err "Invalid choice" ;;
    esac
}

interactive_edit() {
    local bc="$1"
    printf 'New name [keep "%s"]: ' "${P_NAME[$bc]}"
    local name; read -r name || name=""
    printf 'New price [keep %s]: ' "$(fmt_money "${P_PRICE[$bc]}")"
    local price; read -r price || price=""
    printf 'New threshold [keep %s]: ' "${P_THRESHOLD[$bc]}"
    local thr; read -r thr || thr=""
    printf 'New type [keep "%s"]: ' "${P_TYPE[$bc]:-}"
    local ptype; read -r ptype || ptype=""
    printf 'New description [keep "%s"]: ' "${P_DESC[$bc]:-}"
    local desc; read -r desc || desc=""
    printf 'New image path [keep "%s"]: ' "${P_IMAGE[$bc]:-}"
    local image; read -r image || image=""
    local args=("$bc")
    if [[ -n "$name" ]]; then args+=(--name "$name"); fi
    if [[ -n "$price" ]]; then args+=(--price "$price"); fi
    if [[ -n "$thr" ]]; then args+=(--threshold "$thr"); fi
    if [[ -n "$ptype" ]]; then args+=(--type "$ptype"); fi
    if [[ -n "$desc" ]]; then args+=(--desc "$desc"); fi
    if [[ -n "$image" ]]; then args+=(--image "$image"); fi
    cmd_edit "${args[@]}"
}

interactive_restock() {
    local bc="$1"
    printf 'Add how many units? '
    local addqty; read -r addqty || addqty=""
    if [[ -z "$addqty" ]]; then return; fi
    printf 'Reason (optional): '
    local reason; read -r reason || reason=""
    local args=("$bc" --qty "$addqty")
    if [[ -n "$reason" ]]; then args+=(--reason "$reason"); fi
    cmd_restock "${args[@]}"
}

interactive_remove() {
    local bc="$1"
    printf 'Reason for removing (optional): '
    local reason; read -r reason || reason=""
    local args=("$bc")
    if [[ -n "$reason" ]]; then args+=(--reason "$reason"); fi
    cmd_remove "${args[@]}"
}

interactive_search() {
    printf 'Search (barcode or name): '
    local q; read -r q || q=""
    if [[ -z "$q" ]]; then return; fi
    cmd_search "$q"
}

# Interactive tray submenu
interactive_tray() {
    echo " $(t tray_sub)"
    printf '%s' "$(t m_choose)"
    local c; read -r c || c=""
    case "$c" in
        1) interactive_tray_add ;;
        2) cmd_tray list ;;
        3) printf '%s: ' "$(t p_tray_bc)"; local t; read -r t || t=""; if [[ -n "$t" ]]; then cmd_tray show "$t"; fi ;;
        4) printf '%s: ' "$(t p_tray_bc)"; local t; read -r t || t=""; if [[ -n "$t" ]]; then cmd_tray remove "$t"; fi ;;
        0|"") return ;;
        *) err "Invalid choice" ;;
    esac
}

interactive_tray_add() {
    printf '%s: ' "$(t p_tray_bc)"
    local tbc; read -r tbc || tbc=""
    if [[ -z "$tbc" ]]; then return; fi
    printf '%s: ' "$(t p_tray_name)"
    local tname; read -r tname || tname=""
    printf '%s (e.g. 8901:1,8902:2): ' "$(t p_tray_items)"
    local items; read -r items || items=""
    if [[ -z "$tname" || -z "$items" ]]; then err "name and items required"; return; fi
    cmd_tray add "$tbc" --name "$tname" --items "$items"
}

# Interactive language picker (menu option 8)
interactive_lang() {
    echo "${C_BOLD}$(t m_language)${C_RESET}"
    list_langs
    printf '%s' "$(t c_select_lang)"
    local n; read -r n || n=""
    if [[ -z "$n" ]]; then return; fi
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#LANG_NAMES[@]} )); then
        local code="${LANG_NAMES[$((n-1))]%%:*}"
        set_lang "$code"
    else
        err "Invalid number"
    fi
}

#─────────────────────────────────────────────────────────────────────────────
# Main dispatch
#─────────────────────────────────────────────────────────────────────────────
main() {
    if (( BASH_VERSINFO[0] < 4 )); then
        echo "shopkeep.sh: bash 4+ required (have ${BASH_VERSINFO[0]})" >&2
        exit 2
    fi

    if [[ $# -eq 0 ]]; then
        interactive_menu
        exit 0
    fi

    case "$1" in
        --selftest|selftest) shift; cmd_selftest "$@"; exit $? ;;
        --doctor|doctor)     shift; cmd_doctor "$@"; exit 0 ;;
        --gen-files|gen-files) shift; cmd_gen_files "$@"; exit 0 ;;
        -h|--help)           shift; cmd_help "$@"; exit 0 ;;
        -V|--version)        cmd_version; exit 0 ;;
        add|bill|lowstock|summary|void|backup|stockvalue|lang|inventorylog|remove|restock|edit|search|tray)
            command -v flock >/dev/null || { err "flock required"; exit 2; }
            command -v awk   >/dev/null   || { err "awk required"; exit 2; }
            init_dirs
            LANG_CODE=$(conf lang en)
            i18n_init
            local cmd="$1"; shift
            case "$cmd" in
                add)          cmd_add "$@" ;;
                bill)         cmd_bill "$@" ;;
                lowstock)     cmd_lowstock "$@" ;;
                summary)      cmd_summary "$@" ;;
                void)         cmd_void "$@" ;;
                backup)       backup_now ;;
                stockvalue)   cmd_stockvalue ;;
                lang)         cmd_lang "$@" ;;
                inventorylog) cmd_inventorylog "$@" ;;
                remove)       cmd_remove "$@" ;;
                restock)      cmd_restock "$@" ;;
                edit)         cmd_edit "$@" ;;
                search)       cmd_search "$@" ;;
                tray)         cmd_tray "$@" ;;
            esac
            exit $? ;;
        *)
            err "Unknown command: $1"
            echo "Run './shopkeep.sh -h' for usage." >&2
            exit 3 ;;
    esac
}

main "$@"
