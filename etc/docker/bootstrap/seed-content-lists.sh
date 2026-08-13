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

# The target list names are defined once in the shared, sourced config, so this
# fill and the bootstrap that creates the lists always agree on the set.
. "$(dirname "$0")/content-lists.sh"

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
