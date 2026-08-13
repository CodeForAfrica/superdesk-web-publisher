#!/usr/bin/env sh
set -eu

# Apply the exported Hasura metadata. Baked into the php image (which carries the
# curl + jq CLIs) and run as the hasura-bootstrap one-shot; the local compose
# service runs this same script (curl + jq added to a throwaway alpine), so the
# apply logic lives in exactly one place. The large metadata file lives once too,
# alongside this script.
#
#   HASURA_GRAPHQL_ENDPOINT       e.g. https://graphql.<domain> (prod/staging via
#                                 the public endpoint) or http://publisher-hasura:8080 (local)
#   HASURA_GRAPHQL_ADMIN_SECRET   admin secret (ECS secret / compose env)
#   HASURA_METADATA_FILE          path to the exported metadata json

endpoint="${HASURA_GRAPHQL_ENDPOINT%/}"
admin_secret="$HASURA_GRAPHQL_ADMIN_SECRET"
metadata_file="$HASURA_METADATA_FILE"

# Wait for Hasura to answer /healthz (up to ~120s).
i=0
until curl -fsS "${endpoint}/healthz" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    echo "Timed out waiting for Hasura at ${endpoint}/healthz" >&2
    exit 1
  fi
  sleep 2
done

# Wrap the exported metadata ({resource_version, metadata}) in a replace_metadata
# call and apply it. -f makes curl exit non-zero on an HTTP error so set -e fires.
jq -n --slurpfile m "$metadata_file" \
  '{type: "replace_metadata", args: {allow_inconsistent_metadata: false, metadata: $m[0].metadata}}' \
  | curl -fsS -X POST "${endpoint}/v1/metadata" \
      -H 'Content-Type: application/json' \
      -H "X-Hasura-Admin-Secret: ${admin_secret}" \
      --data @-
echo
