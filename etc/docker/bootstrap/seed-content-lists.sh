#!/usr/bin/env sh
#
# One-time backfill of the Default tenant's manual homepage content lists with
# real published articles.
#
# The homepage lists are seeded as MANUAL by bootstrap-publisher.sh, so editors
# curate them from the Publisher pane in Superdesk. That leaves them empty on a
# fresh stack. This script fills each one with N randomly-chosen published
# articles — a fresh, independent random sample per list, so the homepage shows
# diverse real content immediately after a Ghost ingest and repeated resets
# surface different stories.
#
# Why a separate step, not part of bootstrap-publisher.sh: content lists live in
# Publisher's Postgres, but articles only arrive there AFTER Ghost ingest
# auto-publishes them and Superdesk pushes them over HTTP — which happens
# asynchronously, well after publisher-bootstrap has run. Run this once the
# ingest has drained into Publisher (see `make seed-content-lists`).
#
# Idempotent and non-destructive: it only fills lists that are currently EMPTY,
# so re-running never duplicates items and never clobbers a list an editor has
# already curated. To re-seed a list, clear it in the Publisher pane first.
#
# Settings (overridable via env vars):
#   SEED_CONTENT_LIST_LIMIT   how many articles to put in each list (default: 10)
#
set -eu

LIMIT="${SEED_CONTENT_LIST_LIMIT:-10}"
TENANT="123abc"

case "$LIMIT" in
'' | *[!0-9]*)
  echo "SEED_CONTENT_LIST_LIMIT must be a positive integer, got: '$LIMIT'" >&2
  exit 1
  ;;
esac

# Which lists to random-fill comes from the tracked config: every content list
# with "seed": "random" (the homepage lists). The About/Media Centre editorial
# lists carry "seed": "empty" and are intentionally left for editors to curate,
# so they are excluded here. bootstrap-publisher.sh creates all of them from the
# same file, so the two always agree on the set. See publisher-config/ and
# scripts/publisher-config/.
CONFIG_DIR="$(dirname "$0")/publisher-config"
LISTS_JSON="$CONFIG_DIR/content_lists.json"
[ -f "$LISTS_JSON" ] || { echo "content list config not found: $LISTS_JSON" >&2; exit 1; }

# Build the SQL IN-list of random-fill names: one quoted, comma-joined literal
# per name (single quotes doubled for SQL). Same shape the old content-lists.sh
# derived, now sourced from the tracked JSON. Read with `php` (always present in
# this image) rather than jq (which the dev image does not carry); php prints the
# names newline-separated and the shell loop does the SQL quoting. IFS is pinned
# to newline so names containing spaces ("Homepage — Hero") are not word-split.
CONTENT_LIST_NAMES_IN=""
_sep=""
_old_ifs="$IFS"
IFS='
'
for _name in $(php -r '$l=json_decode(file_get_contents($argv[1]),true)?:[];foreach($l as $x){if(($x["seed"]??null)==="random")echo $x["name"],"\n";}' "$LISTS_JSON"); do
  [ -n "$_name" ] || continue
  _esc=$(printf '%s' "$_name" | sed "s/'/''/g")
  CONTENT_LIST_NAMES_IN="${CONTENT_LIST_NAMES_IN}${_sep}'${_esc}'"
  _sep=", "
done
IFS="$_old_ifs"
unset _sep _name _esc _old_ifs

if [ -z "$CONTENT_LIST_NAMES_IN" ]; then
  echo "No content lists marked \"seed\": \"random\" in $LISTS_JSON; nothing to fill."
  exit 0
fi

echo "Seeding manual homepage content lists for tenant '$TENANT' with up to $LIMIT random published article(s) each."

# Fill every empty target list with LIMIT randomly-chosen published articles.
# `tgt` is the set of target lists still empty; for each one the LATERAL join
# draws its OWN random sample (`ORDER BY random() LIMIT`), so the lists get
# different stories rather than four copies of the same set. `rn` numbers each
# list's sample 1..LIMIT and lands them at positions 0..LIMIT-1. A list that
# already holds items (curated, or seeded by an earlier run) is excluded by the
# NOT EXISTS, so nothing is duplicated or overwritten.
#
# The `a.id <> tgt.id * -1` predicate is always true (ids are positive), but it
# references `tgt`, which forces Postgres to treat the LATERAL as correlated and
# re-evaluate it — random draw and all — once PER list. Without it the planner
# sees an uncorrelated subquery, runs it a single time, and every list gets the
# identical sample.
php bin/console doctrine:query:sql "INSERT INTO swp_content_list_item
    (id, position, enabled, sticky, content_id, content_list_id, created_at, updated_at)
SELECT
    nextval('swp_content_list_item_id_seq'),
    art.rn - 1,
    true,
    false,
    art.id,
    tgt.id,
    NOW(),
    NOW()
FROM (
    SELECT cl.id
    FROM swp_content_list cl
    WHERE cl.tenant_code = '${TENANT}'
      AND cl.type = 'manual'
      AND cl.name IN (${CONTENT_LIST_NAMES_IN})
      AND NOT EXISTS (
          SELECT 1 FROM swp_content_list_item existing
          WHERE existing.content_list_id = cl.id
            AND existing.deleted_at IS NULL
      )
) AS tgt
CROSS JOIN LATERAL (
    SELECT a.id, row_number() OVER () AS rn
    FROM swp_article a
    WHERE a.tenant_code = '${TENANT}'
      AND a.status = 'published'
      AND a.deleted_at IS NULL
      AND a.id <> tgt.id * -1
    ORDER BY random()
    LIMIT ${LIMIT}
) AS art
"

# Report the resulting sizes so an empty run (ingest not drained yet) is obvious.
echo "Content list sizes now:"
php bin/console doctrine:query:sql "SELECT cl.name, count(item.id) AS items
FROM swp_content_list cl
LEFT JOIN swp_content_list_item item
    ON item.content_list_id = cl.id AND item.deleted_at IS NULL
WHERE cl.tenant_code = '${TENANT}'
  AND cl.type = 'manual'
  AND cl.name IN (${CONTENT_LIST_NAMES_IN})
GROUP BY cl.name
ORDER BY cl.name
"
