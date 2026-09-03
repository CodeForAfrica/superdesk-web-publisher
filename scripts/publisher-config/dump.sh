#!/usr/bin/env bash
# Dump the Publisher (SWP) tenant-config tables from a running stack into a JSON
# tarball, ready to feed to convert.py.
#
# Publisher tenant config lives in Postgres, not in the repo, and a
# wipe-and-reseed (ops/aws/scripts/reset-content.sh) destroys anything the
# bootstrap does not recreate. The fix is to track that config as JSON under
# etc/docker/bootstrap/publisher-config/ and re-seed it from there (see
# docs/plans/publisher-config-as-tracked-json.md in the superproject). This
# script is the capture half: it reads the CONFIG tables of a running instance;
# convert.py turns the dump into the tracked tree, and the diff is the review.
#
# Read-only against Postgres. Writes only ephemeral files (inside the container
# and under the OS temp dir on the host) which it cleans up.
#
# Usage:
#   ./dump.sh local   [OUT.tgz]      # local Compose stack (docker exec)
#   ./dump.sh staging [OUT.tgz]      # deployed stack over SSM
#   ./dump.sh prod    [OUT.tgz]      # deployed stack over SSM
#
# Env overrides:
#   REGION  (default eu-west-1)                  deployed only
#   LOCAL_PG_CONTAINER                           auto-detected if unset (local only)
#
# The tables dumped are the CONFIG set (tenant-authored, lost on a wipe). Runtime
# and secret tables are never touched: swp_api_key, swp_publish_destination,
# swp_content_list_item, and every article/media/package/statistics table. The
# split, and which of these convert.py actually seeds, is in the plan.
set -euo pipefail

SOURCE="${1:-}"
OUT="${2:-./publisher-config.${SOURCE}.tgz}"
REGION="${REGION:-eu-west-1}"

# CONFIG tables to capture. Faithful, whole-table dumps — convert.py strips
# volatile columns and resolves FKs, so the dump must keep ids/parent_id/route_id.
#   reference     : tenant/org — captured for context; NOT seeded (env-driven).
#   loaded        : route/rule/menu/content_list/settings — the loader seeds these.
#   latent config : webhook/output_channel/fbia/apple_news/redirect_route — empty
#                   today, dumped so the first admin change is caught on refresh.
TABLES="swp_organization swp_tenant swp_route swp_rule swp_menu swp_content_list \
swp_settings swp_webhook swp_output_channel swp_fbia_feed swp_fbia_page \
swp_apple_news_config swp_redirect_route"

log() { printf '>> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# The dump routine, run inside the postgres container's shell. Discovers DB/user
# from the container env, writes one <table>.json (a json_agg array) per table,
# and emits the tarball at /tmp/publisher-config.tgz. $SUBDIR names the folder the
# JSON lands under (cosmetic; convert.py globs for the first dir with *.json).
container_dump_script() {
  local subdir="$1"
  cat <<EOF
set -e
PGDB="\${POSTGRES_DB:-publisher}"
PGUSER="\${POSTGRES_USER:-publisher}"
OUT=/tmp/pcdump_\$\$; PKG=/tmp/pcpkg_\$\$
rm -rf "\$OUT" "\$PKG"; mkdir -p "\$OUT" "\$PKG/publisher-config/${subdir}"
for t in ${TABLES}; do
  psql -U "\$PGUSER" -d "\$PGDB" -tAc \
    "SELECT COALESCE(json_agg(row_to_json(x)), '[]'::json) FROM (SELECT * FROM \$t) x" \
    > "\$PKG/publisher-config/${subdir}/\$t.json" 2>/dev/null \
    || echo '[]' > "\$PKG/publisher-config/${subdir}/\$t.json"
done
tar czf /tmp/publisher-config.tgz -C "\$PKG" publisher-config
rm -rf "\$OUT" "\$PKG"
EOF
}

dump_local() {
  local cid
  cid="${LOCAL_PG_CONTAINER:-$(docker ps --filter name=publisher-postgres --format '{{.Names}}' | head -1)}"
  [ -n "$cid" ] || die "no local publisher-postgres container found (set LOCAL_PG_CONTAINER)"
  log "Local postgres container: $cid"
  container_dump_script local | docker exec -i "$cid" bash -s
  docker cp "$cid":/tmp/publisher-config.tgz "$OUT"
  docker exec "$cid" rm -f /tmp/publisher-config.tgz
}

# --- deployed (SSM) helpers -------------------------------------------------------
ssm_run() { # $1 = shell snippet -> stdout of the invocation
  local b64 params cid status
  b64=$(printf '%s' "$1" | base64 | tr -d '\n')
  params=$(jq -n --arg b "$b64" '{commands:[("echo " + $b + " | base64 -d | bash")]}')
  cid=$(aws ssm send-command --region "$REGION" --instance-ids "$HOST" \
    --document-name AWS-RunShellScript --parameters "$params" \
    --query 'Command.CommandId' --output text)
  while :; do
    status=$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
      --instance-id "$HOST" --query 'Status' --output text 2>/dev/null || echo Pending)
    case "$status" in
      Success) break ;;
      Failed|Cancelled|TimedOut|Undeliverable|Terminated)
        aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
          --instance-id "$HOST" --query 'StandardErrorContent' --output text >&2
        die "SSM command $status" ;;
    esac
    sleep 2
  done
  aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
    --instance-id "$HOST" --query 'StandardOutputContent' --output text
}

dump_deployed() {
  local env="$1" cluster svc task ci total off end chunk tmpb64
  cluster="pesacheck-${env}-cluster"; svc="pesacheck-${env}-publisher-postgres"
  aws sts get-caller-identity >/dev/null 2>&1 || die "not authenticated (run: aws login)"
  log "Resolving host for $svc on $cluster ..."
  task=$(aws ecs list-tasks --cluster "$cluster" --region "$REGION" \
    --service-name "$svc" --query 'taskArns[0]' --output text)
  [ "$task" != "None" ] && [ -n "$task" ] || die "no running task for $svc"
  ci=$(aws ecs describe-tasks --cluster "$cluster" --region "$REGION" \
    --tasks "$task" --query 'tasks[0].containerInstanceArn' --output text)
  HOST=$(aws ecs describe-container-instances --cluster "$cluster" --region "$REGION" \
    --container-instances "$ci" --query 'containerInstances[0].ec2InstanceId' --output text)
  log "Host: $HOST"

  # dump inside the container on the host, copy out, base64 on the host. The
  # inner container script is base64-encoded so no quoting survives to fight the
  # SSM/docker exec layers.
  local cscript_b64 snippet
  cscript_b64=$(container_dump_script "$env" | base64 | tr -d '\n')
  snippet=$(cat <<EOF
set -e
CID=\$(docker ps --filter name=pesacheck-${env}-publisher-postgres -q | head -1)
[ -n "\$CID" ] || { echo "no postgres container" >&2; exit 1; }
echo ${cscript_b64} | base64 -d | docker exec -i "\$CID" bash
docker cp "\$CID":/tmp/publisher-config.tgz /tmp/pc.tgz
docker exec "\$CID" rm -f /tmp/publisher-config.tgz
base64 /tmp/pc.tgz | tr -d '\n' > /tmp/pc.b64
rm -f /tmp/pc.tgz
wc -c < /tmp/pc.b64
EOF
)
  log "Running pg dump (read-only) ..."
  total=$(ssm_run "$snippet" | tr -d '[:space:]')
  log "base64 length: $total; pulling in chunks (get-command-invocation caps stdout ~24KB) ..."
  chunk=18000; off=1; tmpb64=$(mktemp)
  while [ "$off" -le "$total" ]; do
    end=$(( off + chunk - 1 ))
    ssm_run "cut -c${off}-${end} /tmp/pc.b64" | tr -d '[:space:]' >> "$tmpb64"
    off=$(( end + 1 ))
  done
  ssm_run "rm -f /tmp/pc.b64" >/dev/null
  base64 -d < "$tmpb64" > "$OUT"
  rm -f "$tmpb64"
}

case "$SOURCE" in
  local)         dump_local ;;
  staging|prod)  dump_deployed "$SOURCE" ;;
  *)             die "usage: $0 <local|staging|prod> [OUT.tgz]" ;;
esac

log "Wrote $OUT"
log "Contents:"
tar tzf "$OUT" >&2
