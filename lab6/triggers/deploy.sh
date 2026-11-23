#!/usr/bin/env bash
# Bucket (public) -> service account -> function -> Object Storage trigger -> test.
# Requires: yc (initialized), jq, zip, curl, aws CLI configured with an Object Storage
# static access key (aws configure set endpoint_url https://storage.yandexcloud.net/).
set -euo pipefail

# ---------------------------------------------------------------- parameters
FOLDER_ID="${FOLDER_ID:-b1g43f7nrtlmptnmu1rr}"
BUCKET="${BUCKET:-os-trigger-demo-$RANDOM}"
SA_NAME="${SA_NAME:-s3-trigger-sa}"
FN_NAME="${FN_NAME:-os-trigger-fn}"
TRIGGER_NAME="${TRIGGER_NAME:-os-trigger}"
RUNTIME="${RUNTIME:-python312}"          # check: yc serverless function version create --help
ENTRYPOINT="${ENTRYPOINT:-handler.handler}"
HANDLER_FILE="${HANDLER_FILE:-handler.py}"
ZIP_FILE="${ZIP_FILE:-function.zip}"
TEST_FILE="${TEST_FILE:-test.txt}"
ENDPOINT="https://storage.yandexcloud.net"

log() { printf '\n=== %s\n' "$*"; }

for bin in yc jq zip curl aws; do
  command -v "$bin" >/dev/null || { echo "missing required tool: $bin" >&2; exit 1; }
done
[[ -f "$HANDLER_FILE" ]] || { echo "handler file not found: $HANDLER_FILE" >&2; exit 1; }

# ------------------------------------------------------------ 1. public bucket
log "Creating bucket $BUCKET with public access"
if yc storage bucket get "$BUCKET" >/dev/null 2>&1; then
  echo "bucket already exists, enabling public access"
  yc storage bucket update --name "$BUCKET" \
    --public-read --public-list --public-config-read
else
  yc storage bucket create \
    --name "$BUCKET" \
    --folder-id "$FOLDER_ID" \
    --public-read --public-list --public-config-read
fi

# ------------------------------------------- 2. service account for the trigger
log "Ensuring service account $SA_NAME"
SA_ID=$(yc iam service-account get --name "$SA_NAME" --folder-id "$FOLDER_ID" \
          --format json 2>/dev/null | jq -r '.id // empty')
if [[ -z "$SA_ID" ]]; then
  SA_ID=$(yc iam service-account create --name "$SA_NAME" --folder-id "$FOLDER_ID" \
            --format json | jq -r '.id')
fi
echo "service account id: $SA_ID"

# role needed to invoke the function from the trigger
yc resource-manager folder add-access-binding "$FOLDER_ID" \
  --role functions.functionInvoker \
  --subject "serviceAccount:$SA_ID" >/dev/null
echo "granted functions.functionInvoker"

# ------------------------------------------------------------- 3. function
log "Ensuring function $FN_NAME"
FN_ID=$(yc serverless function get --name "$FN_NAME" --folder-id "$FOLDER_ID" \
          --format json 2>/dev/null | jq -r '.id // empty')
if [[ -z "$FN_ID" ]]; then
  FN_ID=$(yc serverless function create --name "$FN_NAME" --folder-id "$FOLDER_ID" \
            --format json | jq -r '.id')
fi
echo "function id: $FN_ID"

log "Packaging and deploying version"
rm -f "$ZIP_FILE"
zip -q -j "$ZIP_FILE" "$HANDLER_FILE"

yc serverless function version create \
  --function-id "$FN_ID" \
  --folder-id "$FOLDER_ID" \
  --runtime "$RUNTIME" \
  --entrypoint "$ENTRYPOINT" \
  --memory 128m \
  --execution-timeout 5s \
  --source-path "./$ZIP_FILE" \
  --service-account-id "$SA_ID"

# ------------------------------------------------------------- 4. trigger
log "Ensuring Object Storage trigger $TRIGGER_NAME"
if yc serverless trigger get --name "$TRIGGER_NAME" --folder-id "$FOLDER_ID" >/dev/null 2>&1; then
  echo "trigger already exists, skipping creation"
else
  yc serverless trigger create object-storage \
    --name "$TRIGGER_NAME" \
    --folder-id "$FOLDER_ID" \
    --bucket-id "$BUCKET" \
    --events 'create-object' \
    --batch-size 1 \
    --batch-cutoff 10s \
    --invoke-function-id "$FN_ID" \
    --invoke-function-service-account-id "$SA_ID"
fi

# ------------------------------------------------------------- 5. test
log "Testing: uploading $TEST_FILE to s3://$BUCKET/"
echo "hello from trigger $(date -u +%FT%TZ)" > "$TEST_FILE"
aws --endpoint-url "$ENDPOINT" s3 cp "$TEST_FILE" "s3://$BUCKET/$TEST_FILE"

log "Trigger state"
yc serverless trigger get "$TRIGGER_NAME" --folder-id "$FOLDER_ID"

log "Waiting for the function to be invoked"
sleep 20
yc serverless function logs "$FN_NAME" --folder-id "$FOLDER_ID" --since 5m || true

log "Anonymous read check (public access)"
curl -fsS "$ENDPOINT/$BUCKET/$TEST_FILE" && echo

log "Done"
cat <<EOF
bucket:      $BUCKET
function:    $FN_NAME ($FN_ID)
trigger:     $TRIGGER_NAME
service acc: $SA_NAME ($SA_ID)
EOF
