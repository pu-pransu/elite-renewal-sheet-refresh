"""
Daily refresh: Snowflake -> Google Sheet 'Raw Data' tab (Elite Renewal Cohorts).

Every other tab in the sheet is formulas over 'Raw Data' (whole-column ranges),
so replacing 'Raw Data' refreshes the whole sheet.

Required environment variables (set as GitHub Actions secrets):
  SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_WAREHOUSE, SNOWFLAKE_ROLE
  SNOWFLAKE_PASSWORD            (or SNOWFLAKE_PRIVATE_KEY for key-pair auth, preferred)
  GOOGLE_SERVICE_ACCOUNT_JSON   (full JSON key of a service account that has Editor access to the sheet)
Optional:
  SHEET_ID (defaults to the Elite Renewal Cohorts sheet), RAW_TAB (default 'Raw Data')

Local mode (python refresh.py --local):
  Signs in to Snowflake with your normal Google SSO (browser) instead of a password/token.
  The SSO ID token is cached in your OS keystore, so the browser only opens occasionally
  (needs ALLOW_ID_TOKEN = TRUE on the Snowflake account and `pip install -r requirements-local.txt`).
  Needs SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_WAREHOUSE, SNOWFLAKE_ROLE and
  GOOGLE_SERVICE_ACCOUNT_FILE (path to the service-account JSON key file) in the environment.
"""
import datetime as dt
import json
import os
import sys
from pathlib import Path

import gspread
import snowflake.connector
from google.oauth2.service_account import Credentials

SHEET_ID = os.environ.get("SHEET_ID", "1arlMobkuLlm8XVK8RvTtIRENbBw1A399Iq3Aa0e2tkE")
RAW_TAB = os.environ.get("RAW_TAB", "Raw Data")
QUERY = (Path(__file__).parent / "query.sql").read_text()
MIN_ROWS = 1000  # safety: don't wipe the sheet if the query returns suspiciously little


def log(msg):
    print(f"[{dt.datetime.utcnow():%Y-%m-%d %H:%M:%S}Z] {msg}", flush=True)


def snowflake_conn(local=False):
    kw = dict(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
        role=os.environ.get("SNOWFLAKE_ROLE"),
        database="REPORTS_DB",
    )
    pk = os.environ.get("SNOWFLAKE_PRIVATE_KEY")
    if local:
        kw["authenticator"] = "externalbrowser"
        kw["client_store_temporary_credential"] = True  # cache SSO ID token -> fewer browser prompts
    elif pk:
        from cryptography.hazmat.primitives import serialization
        key = serialization.load_pem_private_key(pk.encode(), password=None)
        kw["private_key"] = key.private_bytes(
            encoding=serialization.Encoding.DER,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
    else:
        kw["password"] = os.environ["SNOWFLAKE_PASSWORD"]
    return snowflake.connector.connect(**kw)


def to_cell(v):
    if v is None:
        return ""
    if isinstance(v, (dt.date, dt.datetime)):
        return v.strftime("%Y-%m-%d")  # USER_ENTERED -> Sheets parses as a real date
    return v if isinstance(v, (int, float, str)) else str(v)


def main(local=False):
    log("Running Snowflake query")
    with snowflake_conn(local) as conn:
        cur = conn.cursor()
        cur.execute(QUERY)
        header = [c[0].upper() for c in cur.description]
        rows = [[to_cell(v) for v in r] for r in cur.fetchall()]
    log(f"Fetched {len(rows):,} rows, columns: {header}")

    if len(rows) < MIN_ROWS:
        log(f"ABORT: only {len(rows)} rows (< {MIN_ROWS}); sheet left untouched")
        sys.exit(1)

    scopes = ["https://www.googleapis.com/auth/spreadsheets"]
    key_file = os.environ.get("GOOGLE_SERVICE_ACCOUNT_FILE")
    if key_file:
        creds = Credentials.from_service_account_file(key_file, scopes=scopes)
    else:
        creds = Credentials.from_service_account_info(
            json.loads(os.environ["GOOGLE_SERVICE_ACCOUNT_JSON"]), scopes=scopes
        )
    ws = gspread.authorize(creds).open_by_key(SHEET_ID).worksheet(RAW_TAB)

    needed = len(rows) + 1
    if ws.row_count < needed:
        ws.add_rows(needed - ws.row_count + 500)

    log("Writing to Google Sheet")
    ws.batch_clear(["A:J"])
    ws.update(range_name="A1", values=[header] + rows, value_input_option="USER_ENTERED")
    if ws.col_count < 12:  # make room for the timestamp cell
        ws.add_cols(12 - ws.col_count)
    ws.update_acell("L1", f"Last refreshed (UTC): {dt.datetime.utcnow():%Y-%m-%d %H:%M}")
    log("Done")


if __name__ == "__main__":
    main(local="--local" in sys.argv)
