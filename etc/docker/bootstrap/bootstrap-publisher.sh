#!/usr/bin/env sh
set -eu

# Publisher bootstrap: migrations, the default tenant, its language routes/rules,
# homepage menu + content lists, and the theme. Baked into the php image and run
# as the publisher-bootstrap one-shot (ECS RunTask) or the local compose service.
#
# Environment-driven so the one script is correct everywhere:
#   SWP_DOMAIN            default tenant's domain_name — the REGISTRABLE domain,
#                         not the full host. "localhost" locally; in staging/prod
#                         the host is split by the public-suffix resolver, so a
#                         host like publisher-staging.pesacheck.org means
#                         SWP_DOMAIN=pesacheck.org (+ SWP_SUBDOMAIN below).
#                         Always injected.
#   SWP_SUBDOMAIN         optional. default tenant's subdomain label. The
#                         TenantResolver decomposes the request Host into a
#                         subdomain + registrable domain; when the publisher is
#                         served on a subdomain (publisher-staging.pesacheck.org
#                         -> subdomain "publisher-staging", domain "pesacheck.org")
#                         it looks the tenant up by BOTH, so the row must carry the
#                         matching subdomain. Unset (empty) -> subdomain NULL, for
#                         bare-domain hosts like localhost that resolve by domain
#                         alone.
#   PUBLISHER_SEED_DEMO   "1" turns on the local-only demo bits — the second
#                         "Other Demo" tenant (456def) with the full DefaultTheme
#                         demo data, and a runtime `composer install`. Off (unset)
#                         for the baked prod/staging jobs, on for local `make seed`
#                         (the prod image already has vendor baked, so composer
#                         install is a dev convenience only).
#
# The tenant's routes, rules, content lists and menus are tracked as JSON under
# publisher-config/ (delivered alongside this script — baked into the image, bind
# mounted locally) and applied by `swp:config:load` near the end of this script.
# See scripts/publisher-config/ and docs/plans/publisher-config-as-tracked-json.md.
CONFIG_DIR="$(dirname "$0")/publisher-config"

DOMAIN="${SWP_DOMAIN:-localhost}"
SUBDOMAIN="${SWP_SUBDOMAIN:-}"
SEED_DEMO="${PUBLISHER_SEED_DEMO:-0}"

# SQL literal for the default tenant's subdomain column: a quoted string when
# SWP_SUBDOMAIN is set, otherwise the SQL NULL keyword (unquoted). Built once here
# so the INSERT and the reconciling UPDATE below stay in sync.
if [ -n "$SUBDOMAIN" ]; then
  SUBDOMAIN_SQL="'${SUBDOMAIN}'"
else
  SUBDOMAIN_SQL="NULL"
fi

# Dev convenience only: the prod image bakes --no-dev vendor at build time.
if [ "$SEED_DEMO" = 1 ]; then
  composer install --no-interaction
fi

php bin/console doctrine:database:create --if-not-exists
php bin/console doctrine:migrations:migrate --no-interaction

# Base organization + default tenant (123abc). This used to be
#   doctrine:fixtures:load --group=LoadTenantsData
# but DoctrineFixturesBundle (and doctrine/data-fixtures) is a require-dev
# dependency and its `fixtures_type` parameter is only defined in the dev
# environment, so that command simply does not exist in the baked --no-dev
# prod/staging image ("There are no commands defined in the 'doctrine:fixtures'
# namespace" -> exit 1, aborting the whole bootstrap). It only ever worked
# locally because PUBLISHER_SEED_DEMO=1 runs a runtime `composer install` above,
# pulling the dev bundle back in. We instead create the exact rows the
# LoadTenantsData fixture created (organization.yml + tenant.yml) with idempotent
# raw SQL — the same approach every other seed statement in this script already
# uses. The demo-only "Other Demo" tenant (456def) is created under
# PUBLISHER_SEED_DEMO alongside the rest of its config.
php bin/console doctrine:query:sql "INSERT INTO swp_organization (id, name, code, enabled, created_at) SELECT nextval('swp_organization_id_seq'), 'PesaCheck', '123456', true, NOW() WHERE NOT EXISTS (SELECT 1 FROM swp_organization WHERE code = '123456')"
php bin/console doctrine:query:sql "INSERT INTO swp_tenant (id, organization_id, name, code, subdomain, domain_name, enabled, amp_enabled, theme_name, created_at) SELECT nextval('swp_tenant_id_seq'), org.id, 'PesaCheck', '123abc', ${SUBDOMAIN_SQL}, '${DOMAIN}', true, true, 'swp/default-theme', NOW() FROM swp_organization org WHERE org.code = '123456' AND NOT EXISTS (SELECT 1 FROM swp_tenant WHERE code = '123abc')"
php bin/console doctrine:query:sql "UPDATE swp_tenant SET name = 'PesaCheck', subdomain = ${SUBDOMAIN_SQL}, domain_name = '${DOMAIN}', enabled = true WHERE code = '123abc'"

# Local-only "Other Demo" tenant (456def).
if [ "$SEED_DEMO" = 1 ]; then
  php bin/console doctrine:query:sql "INSERT INTO swp_tenant (id, organization_id, name, code, subdomain, domain_name, enabled, amp_enabled, theme_name, created_at) SELECT nextval('swp_tenant_id_seq'), org.id, 'Other Demo', '456def', 'client1', '${DOMAIN}', true, false, 'swp/default-theme', NOW() FROM swp_organization org WHERE org.code = '123456' AND NOT EXISTS (SELECT 1 FROM swp_tenant WHERE code = '456def')"
  php bin/console doctrine:query:sql "UPDATE swp_tenant SET name = 'Other Demo', subdomain = 'client1', domain_name = '${DOMAIN}', enabled = true WHERE code = '456def'"
  php bin/console doctrine:query:sql "UPDATE swp_tenant SET organization_id = (SELECT organization_id FROM swp_tenant WHERE code = '123abc') WHERE code = '456def'"
fi
php bin/console doctrine:query:sql "UPDATE swp_rule SET name = 'Local Default Tenant Catch-all', description = 'Local bootstrap rule: send every incoming package to the default tenant.', expression = 'true == true', priority = 1, configuration = 'a:1:{s:12:\"destinations\";a:1:{i:0;a:1:{s:6:\"tenant\";s:6:\"123abc\";}}}', tenant_code = NULL, organization_id = (SELECT organization_id FROM swp_tenant WHERE code = '123abc') WHERE tenant_code IS NULL AND (name IN ('default', 'Local Default Tenant Catch-all') OR (expression = 'true == true' AND configuration LIKE '%123abc%'))"
php bin/console doctrine:query:sql "INSERT INTO swp_rule (id, expression, priority, configuration, tenant_code, organization_id, description, name) SELECT nextval('swp_rule_id_seq'), 'true == true', 1, 'a:1:{s:12:\"destinations\";a:1:{i:0;a:1:{s:6:\"tenant\";s:6:\"123abc\";}}}', NULL, organization_id, 'Local bootstrap rule: send every incoming package to the default tenant.', 'Local Default Tenant Catch-all' FROM swp_tenant WHERE code = '123abc' AND NOT EXISTS (SELECT 1 FROM swp_rule WHERE tenant_code IS NULL AND name = 'Local Default Tenant Catch-all')"
# Content lists, routes, rules and menus for 123abc are seeded from the tracked
# JSON tree by `swp:config:load` below, after the theme is installed.
# Install the DefaultTheme for the default tenant WITHOUT any of its demo
# generated data. swp:theme:install ALWAYS runs the required-data processor, and
# only ThemeRoutesGenerator even looks at -p/--processGeneratedData — there it
# gates fake demo articles, NOT the routes. The menu and content-list generators
# ignore the flag entirely. So omitting -p does not stop the DefaultTheme's demo
# routes (politics/business/scitech/health/entertainment/sports/football), its
# demo mainNavigation + footerPrim menus, or its "Example automatic list" from
# being created. The only way to keep them off 123abc is to install from a copy
# of the theme with the whole generatedData block dropped — the theme config
# treats it as optional (TenantAwareThemeLoader only sets it when present) but
# rejects an empty routes/menus/contentLists list, so it must be removed, not
# emptied. 456def still installs from the original with -p and gets the full set.
bare_theme_dir="$(mktemp -d)/DefaultTheme"
cp -r src/SWP/Bundle/FixturesBundle/Resources/themes/DefaultTheme "$bare_theme_dir"
php -r '$f = $argv[1]; $t = json_decode(file_get_contents($f), true); unset($t["generatedData"]); file_put_contents($f, json_encode($t, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));' "$bare_theme_dir/theme.json"
php bin/console swp:theme:install 123abc "$bare_theme_dir" -f
rm -rf "$(dirname "$bare_theme_dir")"
if [ "$SEED_DEMO" = 1 ]; then
  php bin/console swp:theme:install 456def src/SWP/Bundle/FixturesBundle/Resources/themes/DefaultTheme/ -f -p
fi

# Seed the default tenant's tracked config — routes, language rules, content
# lists and the whole navigation tree — from publisher-config/. Idempotent, and
# it reuses SWP's own generators so the Gedmo nested-set (route/menu lft/rgt) and
# the RouteService boilerplate are maintained by the code that owns them. This
# replaces the hand-rolled nested-set SQL that used to live here. The
# organization-scoped catch-all rule above stays put — it is routing infra tied
# to tenant creation, not tenant content (see the loader's docblock).
php bin/console swp:config:load 123abc "$CONFIG_DIR"

php bin/console sylius:theme:assets:install
php bin/console cache:clear
