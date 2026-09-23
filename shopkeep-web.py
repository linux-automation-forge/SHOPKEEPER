#!/usr/bin/env python3
"""
shopkeep-web.py — localhost web UI server for shopkeep.sh.

Python 3 STANDARD LIBRARY ONLY (no pip packages). Binds 127.0.0.1:8000 and:
  GET  /                          serve the self-contained shopkeep-dashboard.html
                                  (regenerated via `./shopkeep.sh web` so the
                                  baked-in data is fresh)
  GET  /api/products.json         JSON straight from shopkeep-data/products.csv
  GET  /api/bills.json            JSON straight from shopkeep-data/bills.csv
  GET  /api/categories.json      JSON straight from shopkeep-data/categories.csv
  GET  /api/trays.json            JSON straight from shopkeep-data/trays.csv
  GET  /api/inventorylog.json    last 100 inventory_log.csv entries, newest first

  POST /api/bill                  body: {"lines":["bc qty",...],"phone":"..","discount":"N"}
                                  -> runs `./shopkeep.sh bill --phone .. --discount ..`
                                  with the scan lines on stdin in EXACTLY the format
                                  cmd_bill already parses ("barcode qty" per line;
                                  tray barcodes auto-expand). Returns the captured
                                  stdout/stderr + exit code. shopkeep.sh stays the
                                  ONLY writer to the CSVs — Python never opens a CSV
                                  in write mode.

All responses are UTF-8 with an explicit charset. All money is integer paise.
Run:  python3 shopkeep-web.py
"""

import csv
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

# ---------------------------------------------------------------------
# Paths — resolve relative to THIS file so it runs from anywhere.
# ---------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
SHOPKEEP = os.path.join(HERE, "shopkeep.sh")
DATA_DIR = os.path.join(HERE, "shopkeep-data")
PRODUCTS_CSV = os.path.join(DATA_DIR, "products.csv")
BILLS_CSV = os.path.join(DATA_DIR, "bills.csv")
INVENTORY_LOG = os.path.join(DATA_DIR, "inventory_log.csv")
TRAYS_CSV = os.path.join(DATA_DIR, "trays.csv")
CATEGORIES_CSV = os.path.join(DATA_DIR, "categories.csv")
DASHBOARD_HTML = os.path.join(HERE, "shopkeep-dashboard.html")

HOST = "127.0.0.1"      # localhost ONLY — never 0.0.0.0
PORT = 8000
SUBPROC_TIMEOUT = 30    # seconds for ./shopkeep.sh subprocesses

# ---------------------------------------------------------------------
# CSV -> JSON readers (read-only; Python never writes a CSV).
# Mirrors shopkeep.sh's parse_csv_line (RFC-4180-ish: quoted fields,
# doubled quotes -> one quote). Uses the stdlib csv module.
# Money fields stay integer paise strings/ints — no floating point.
# ---------------------------------------------------------------------
def _read_csv(path):
    """Yield dict rows of a CSV file (header-driven). Empty file -> no rows."""
    if not os.path.isfile(path):
        return []
    rows = []
    with open(path, "r", encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        header = None
        for row in reader:
            if not row:
                continue
            if header is None:
                header = row
                continue
            # pad/truncate to header length
            r = row[:len(header)]
            while len(r) < len(header):
                r.append("")
            rows.append(dict(zip(header, r)))
    return rows


def _num(v):
    """Coerce to int for JSON; non-numeric (e.g. '-') -> 0. Mirrors web_num()."""
    if v is None:
        return 0
    s = str(v).strip()
    if s.startswith("-"):
        rest = s[1:]
    else:
        rest = s
    if rest.isdigit():
        try:
            return int(s)
        except ValueError:
            return 0
    return 0


def products_json():
    out = []
    for r in _read_csv(PRODUCTS_CSV):
        pr = _num(r.get("price_paise"))
        q = _num(r.get("qty"))
        out.append({
            "barcode": r.get("barcode", ""),
            "name": r.get("name", ""),
            "pricePaise": pr,
            "qty": q,
            "threshold": _num(r.get("threshold")),
            "description": r.get("description", "") if "description" in r else "",
            "type": r.get("type", "") if "type" in r else "",
            "image": r.get("image", "") if "image" in r else "",
            "valuePaise": pr * q,
        })
    return out


def bills_json():
    out = []
    for r in _read_csv(BILLS_CSV):
        out.append({
            "billNo": r.get("bill_no", ""),
            "timestamp": r.get("timestamp", ""),
            "barcode": r.get("barcode", ""),
            "name": r.get("name", ""),
            "qty": _num(r.get("qty")),
            "unitPricePaise": _num(r.get("unit_price_paise")),
            "lineTotal": _num(r.get("line_total")),
            "action": r.get("action", ""),
        })
    return out


def categories_json():
    out = []
    for r in _read_csv(CATEGORIES_CSV):
        out.append({
            "name": r.get("name", ""),
            "emoji": r.get("emoji", ""),
            "trayBarcode": r.get("tray_barcode", ""),
        })
    return out


def trays_json():
    out = []
    for r in _read_csv(TRAYS_CSV):
        out.append({
            "trayBarcode": r.get("tray_barcode", ""),
            "name": r.get("name", ""),
            "itemBarcode": r.get("item_barcode", ""),
            "itemName": r.get("item_name", ""),
            "itemQty": _num(r.get("item_qty")) or 1,
            "itemPricePaise": _num(r.get("item_price_paise")),
        })
    return out


def inventorylog_json(limit=100):
    """Last `limit` entries, NEWEST first."""
    rows = _read_csv(INVENTORY_LOG)
    rows = rows[-limit:] if limit else rows
    rows = list(reversed(rows))  # newest first
    out = []
    for r in rows:
        out.append({
            "timestamp": r.get("timestamp", ""),
            "event": r.get("event", ""),
            "barcode": r.get("barcode", ""),
            "name": r.get("name", ""),
            "qty": r.get("qty", ""),
            "pricePaise": r.get("price_paise", ""),
            "detail": r.get("detail", ""),
        })
    return out


# ---------------------------------------------------------------------
# Billing: subprocess to shopkeep.sh. Python NEVER writes a CSV.
# Sends the scan lines on stdin in exactly the format cmd_bill parses:
# one "barcode qty" per line (qty optional, defaults to 1).
# Tray barcodes are passed through raw — cmd_bill expands them itself.
# ---------------------------------------------------------------------
def commit_bill(payload):
    """payload: dict with lines (list[str]), phone (str), discount (str)."""
    lines = payload.get("lines") or []
    if not isinstance(lines, list) or not lines:
        return {"ok": False, "exitCode": 1,
                "stdout": "", "stderr": "No lines in request."}
    phone = str(payload.get("phone") or "").strip()
    discount = str(payload.get("discount") or "0").strip()
    # validate discount looks like an int 0-100
    if not discount.isdigit() or not (0 <= int(discount) <= 100):
        return {"ok": False, "exitCode": 1,
                "stdout": "", "stderr": "discount must be an integer 0-100"}

    stdin_text = "\n".join(str(l) for l in lines) + "\n"
    cmd = [SHOPKEEP, "bill", "--phone", phone, "--discount", discount]
    try:
        proc = subprocess.run(
            cmd,
            input=stdin_text,
            capture_output=True,
            text=True,
            timeout=SUBPROC_TIMEOUT,
            cwd=HERE,
        )
        ok = (proc.returncode == 0)
        return {
            "ok": ok,
            "exitCode": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
        }
    except subprocess.TimeoutExpired:
        return {"ok": False, "exitCode": -1,
                "stdout": "", "stderr": "shopkeep.sh bill timed out"}
    except FileNotFoundError:
        return {"ok": False, "exitCode": -1,
                "stdout": "", "stderr": "shopkeep.sh not found at " + SHOPKEEP}


def regenerate_dashboard():
    """Run `./shopkeep.sh web` to (re)generate shopkeep-dashboard.html.
    Returns the generated HTML bytes (utf-8). Falls back to the existing
    file if generation fails."""
    try:
        subprocess.run(
            [SHOPKEEP, "web"],
            capture_output=True, text=True,
            timeout=SUBPROC_TIMEOUT, cwd=HERE,
        )
    except Exception:
        pass
    try:
        with open(DASHBOARD_HTML, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return (b"<!doctype html><html><body><h2>Run <code>./shopkeep.sh web</code>"
                b" first to generate the dashboard.</h2></body></html>")


# ---------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "shopkeep-web/1.0"

    def log_message(self, fmt, *args):
        # keep the console quiet-ish but visible
        sys.stderr.write("  %s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, status, body_bytes, content_type, charset="utf-8"):
        if isinstance(body_bytes, str):
            body_bytes = body_bytes.encode(charset)
        self.send_response(status)
        # explicit charset on every response
        self.send_header("Content-Type", content_type + "; charset=" + charset)
        self.send_header("Content-Length", str(len(body_bytes)))
        # file:// dashboards are self-contained; this is just localhost
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body_bytes)

    def _send_json(self, obj, status=200):
        self._send(status, json.dumps(obj, ensure_ascii=False),
                   "application/json")

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/" or path == "/index.html":
            html = regenerate_dashboard()
            self._send(200, html, "text/html")
            return
        if path == "/api/products.json":
            self._send_json(products_json()); return
        if path == "/api/bills.json":
            self._send_json(bills_json()); return
        if path == "/api/categories.json":
            self._send_json(categories_json()); return
        if path == "/api/trays.json":
            self._send_json(trays_json()); return
        if path == "/api/inventorylog.json":
            self._send_json(inventorylog_json(100)); return
        # static fallback: nothing else is served (zero external requests by design)
        self._send(404, '{"error":"not found","path":' +
                   json.dumps(path) + '}', "application/json", )

    def do_POST(self):
        path = urlparse(self.path).path
        if path != "/api/bill":
            self._send_json({"ok": False, "error": "unknown POST endpoint"}, 404)
            return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(raw.decode("utf-8") or "{}")
        except Exception as e:
            self._send_json({"ok": False, "error": "bad JSON: " + str(e)}, 400)
            return
        result = commit_bill(payload)
        self._send_json(result, 200 if result.get("ok") else 500)


def main():
    # make sure shopkeep.sh is executable-ish; if not, still try (python calls it
    # via `shopkeep.sh` which the OS runs with the shebang). We also chmod +x for
    # the case the file lost its exec bit.
    try:
        os.chmod(SHOPKEEP, 0o755)
    except Exception:
        pass
    # ensure data dir + a dashboard exist so the first GET / is instant
    if not os.path.isdir(DATA_DIR):
        subprocess.run([SHOPKEEP, "inventory"], capture_output=True,
                       text=True, timeout=SUBPROC_TIMEOUT, cwd=HERE)
    if not os.path.isfile(DASHBOARD_HTML):
        regenerate_dashboard()

    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print("shopkeep-web serving on http://%s:%d/" % (HOST, PORT))
    print("  dashboard:  open the URL above (billing enabled)")
    print("  offline:    double-click shopkeep-dashboard.html (read-only)")
    print("  Ctrl-C to stop")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye.")
        srv.shutdown()


if __name__ == "__main__":
    main()
