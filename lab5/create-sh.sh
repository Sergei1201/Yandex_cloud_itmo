#!/usr/bin/env bash

# Creates a Yandex Cloud service account, grants it the 'editor' role on a folder
# # issues an autorhized JSON key and a static access key, and sets up a CLI profile
set -euo pipefail

# ------------------- Parameters (override via environment variables) -------------------- 
FOLDER_ID="${FOLDER_ID:-b1g43f7nrtlmptnmu1rr}"
SA_NAME="${SA_NAME:-my-sa}"
ROLE="${ROLE:-editor}"
PROFILE_NAME="${PROFILE_NAME:-sa-profile}"
KEY_FILE="${KEY_FILE:-sa-key-${SA_NAME}.json}"
OUT_DIR="${OUT_DIR:-.}"

command -v yc >/dev/null || { echo "yc CLI not found"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }

mkdir -p "$OUT_DIR"

# ------------------ 1. Create the service account (reuse if it already exists) --------------
if yc iam service-account get --name "$SA_NAME" --folder-id "$FOLDER_ID" > /dev/null 2>&1; then
	echo "[1/5] Service account '$SA_NAME' already exists, reusing it."
else
	echo "[1/5} Creating service account '$SA_NAME' in folder $FOLDER_ID..."
	yc iam service-account create --name "$SA_NAME" --folder-id "$FOLDER_ID"
fi

SA_ID=$(yc iam service-account get --name "$SA_NAME" --folder-id "$FOLDER_ID" \
	--format json | jq -r .id)
echo " Service account ID: $SA_ID"

# ----------------- 2. GRANT the role on the folder -------------------------
echo "[2/5] Granting role '$ROLE' on folder $FOLDER_ID..."
yc resource-manager folder add-access-binding "$FOLDER_ID" \
	--role "$ROLE" \
	--service-account-id "$SA_ID"

echo " Current bindings for this service accoount: "
yc resource-manager folder list-access-bindings "$FOLDER_ID" --format json \
	| jq --arg id "$SA_ID" '.[] | select(.subject.id == $id)'

# ------------------ 3. Autorhized JSON key - for CLI/SDK authentication -----------
echo "[3/5] Creating authorized key -> $OUT_DIR/$KEY_FILE"
yc iam key create \
	--service-account-id "$SA_ID" \
	--output "$OUT_DIR/$KEY_FILE" 
chmod 600 "$OUT_DIR/$KEY_FILE"

# ------------------ 4. Static access key - for Object Storage/S3 API --------------
echo "[4/5] Creating static accesss key (secret is shown only once)... "
ACCESS_KEY_JSON=$(yc iam access-key create --service-account-id "$SA_ID" --format json)
echo "$ACCESS_KEY_JSON" > "$OUT_DIR/sa-access-key-${SA_NAME}.json"
chmod 600 "$OUT_DIR/sa-access-key-${SA_NAME}.json"
echo " key_id: $(echo "$ACCESS_KEY_JSON" | jq- r .access_key.key_id)"
echo " secret: $(echo "$ACCESS_KEY_JSON" | jq -r .secret)"

# ------------------- 5. CLI profile that authenticates as the service account ----------
echo "[5/5] Creating CLI profile '$PROFILE_NAME'..."
yc config profile create "$PROFILE_NAME" || true
yc config profile activate "$PROFILE_NAME"
yc config set service-account-key "$OUT_DIR/$KEY_FILE"
yc config set folder-id "$FOLDER_ID"

echo
echo "Done. "
echo " Service account : $SA_NAME ($SA_ID)"
echo " Role : $ROLE on folder $FOLDER_ID"
echo " JSON key : $OUT_DIR/$KEY_FILE"
echo " Static key $OUT_DIR/sa-access-key-${SA_NAME}.json"
echo " CLI profile : $PROFILE_NAME"
echo
echo "Verify with: yc iam service-account list --folder-id $FOLDER_ID"
echo " yc resource-manager folder list-access-bindings $FOLDER_ID"


