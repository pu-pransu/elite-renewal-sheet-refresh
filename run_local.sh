#!/usr/bin/env bash
# Local refresh: Snowflake (Google SSO in browser) -> Google Sheet 'Raw Data'.
# Put this folder's files + the Google service-account *.json key file together, then run:  bash run_local.sh
set -e
cd "$(dirname "$0")"

KEY_FILE="$(ls ./*.json 2>/dev/null | head -1)"
if [ -z "$KEY_FILE" ]; then echo "No service-account .json key file found in this folder."; exit 1; fi

if [ ! -d .venv ]; then python3 -m venv .venv; fi
source .venv/bin/activate
pip install -q -r requirements-local.txt

export SNOWFLAKE_ACCOUNT="JPMVCZF-RG24538"
export SNOWFLAKE_USER="PRANSU.KUMAR@POWERUP.MONEY"
export SNOWFLAKE_WAREHOUSE="PRODUCT_WH"
export SNOWFLAKE_ROLE="PRODUCT_ROLE"
export GOOGLE_SERVICE_ACCOUNT_FILE="$PWD/${KEY_FILE#./}"

python refresh.py --local
