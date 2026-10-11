# Elite Renewal Cohorts – daily auto-refresh

Runs `query.sql` on Snowflake every day at 08:00 IST and overwrites the **Raw Data** tab of the
Elite Renewal Cohorts Google Sheet. All other tabs are formulas on Raw Data, so they update by themselves.
Cell `Raw Data!L1` shows the last refresh time.

## One-time setup (≈20 min)

1. **GitHub repo**: create a private repo, upload these files (keep the `.github/workflows` folder).
2. **Google service account**
   - Google Cloud Console → IAM & Admin → Service Accounts → Create → Keys → Add key → JSON.
   - Enable the *Google Sheets API* for that project.
   - Share the Google Sheet with the service account's email (…@….iam.gserviceaccount.com) as **Editor**.
3. **Snowflake**: ideally a service user with read access to `REPORTS_DB` (key-pair auth preferred over password).
4. **GitHub secrets** (repo → Settings → Secrets and variables → Actions → New secret):
   `SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, `SNOWFLAKE_WAREHOUSE`, `SNOWFLAKE_ROLE`,
   `SNOWFLAKE_PASSWORD` *or* `SNOWFLAKE_PRIVATE_KEY`, `GOOGLE_SERVICE_ACCOUNT_JSON` (paste the whole JSON).
5. Repo → **Actions** → "Elite renewal sheet - daily refresh" → **Run workflow** to test once.

## Notes
- Safety check: if the query returns < 1,000 rows the job fails and the sheet is not touched.
- Failed runs email the repo owner (GitHub default).
- To change the query, edit `query.sql` (no trailing semicolon needed).

## Local mode (works today, no token needed)

Run from your own laptop with your normal Google SSO login:

```bash
pip install -r requirements-local.txt
export SNOWFLAKE_ACCOUNT="JPMVCZF-RG24538"
export SNOWFLAKE_USER="PRANSU.KUMAR@POWERUP.MONEY"
export SNOWFLAKE_WAREHOUSE="PRODUCT_WH"
export SNOWFLAKE_ROLE="PRODUCT_ROLE"
export GOOGLE_SERVICE_ACCOUNT_FILE="/path/to/service-account-key.json"
python refresh.py --local
```

(On Windows PowerShell use `$env:NAME="value"` instead of `export`.)

A browser tab opens for the Google sign-in. The ID token is then cached in the OS keystore so the
browser only reopens occasionally. Caching needs `ALTER ACCOUNT SET ALLOW_ID_TOKEN = TRUE` (ACCOUNTADMIN).
Without it the script still works, but the browser opens on every run.

The GitHub schedule is paused until a service user / network policy exists; re-enable it in
`.github/workflows/refresh.yml`.
