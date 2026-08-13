#!/usr/bin/env sh
set -eu

# Publisher bootstrap: migrations, the default tenant, its language routes/rules,
# homepage menu + content lists, and the theme. Baked into the php image and run
# as the publisher-bootstrap one-shot (ECS RunTask) or the local compose service.
#
# Environment-driven so the one script is correct everywhere:
#   SWP_DOMAIN            default tenant's domain_name (localhost locally, the
#                         real publisher host in staging/prod). Always injected.
#   PUBLISHER_SEED_DEMO   "1" turns on the local-only demo bits — the second
#                         "Other Demo" tenant (456def) with the full DefaultTheme
#                         demo data, and a runtime `composer install`. Off (unset)
#                         for the baked prod/staging jobs, on for local `make seed`
#                         (the prod image already has vendor baked, so composer
#                         install is a dev convenience only).
#
# Homepage content list names are defined once in the shared, sourced config.
. "$(dirname "$0")/content-lists.sh"

DOMAIN="${SWP_DOMAIN:-localhost}"
SEED_DEMO="${PUBLISHER_SEED_DEMO:-0}"

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
php bin/console doctrine:query:sql "INSERT INTO swp_tenant (id, organization_id, name, code, subdomain, domain_name, enabled, amp_enabled, theme_name, created_at) SELECT nextval('swp_tenant_id_seq'), org.id, 'PesaCheck', '123abc', NULL, '${DOMAIN}', true, true, 'swp/default-theme', NOW() FROM swp_organization org WHERE org.code = '123456' AND NOT EXISTS (SELECT 1 FROM swp_tenant WHERE code = '123abc')"
php bin/console doctrine:query:sql "UPDATE swp_tenant SET name = 'PesaCheck', subdomain = NULL, domain_name = '${DOMAIN}', enabled = true WHERE code = '123abc'"

# Local-only "Other Demo" tenant (456def).
if [ "$SEED_DEMO" = 1 ]; then
  php bin/console doctrine:query:sql "INSERT INTO swp_tenant (id, organization_id, name, code, subdomain, domain_name, enabled, amp_enabled, theme_name, created_at) SELECT nextval('swp_tenant_id_seq'), org.id, 'Other Demo', '456def', 'client1', '${DOMAIN}', true, false, 'swp/default-theme', NOW() FROM swp_organization org WHERE org.code = '123456' AND NOT EXISTS (SELECT 1 FROM swp_tenant WHERE code = '456def')"
  php bin/console doctrine:query:sql "UPDATE swp_tenant SET name = 'Other Demo', subdomain = 'client1', domain_name = '${DOMAIN}', enabled = true WHERE code = '456def'"
  php bin/console doctrine:query:sql "UPDATE swp_tenant SET organization_id = (SELECT organization_id FROM swp_tenant WHERE code = '123abc') WHERE code = '456def'"
fi
php bin/console doctrine:query:sql "UPDATE swp_rule SET name = 'Local Default Tenant Catch-all', description = 'Local bootstrap rule: send every incoming package to the default tenant.', expression = 'true == true', priority = 1, configuration = 'a:1:{s:12:\"destinations\";a:1:{i:0;a:1:{s:6:\"tenant\";s:6:\"123abc\";}}}', tenant_code = NULL, organization_id = (SELECT organization_id FROM swp_tenant WHERE code = '123abc') WHERE tenant_code IS NULL AND (name IN ('default', 'Local Default Tenant Catch-all') OR (expression = 'true == true' AND configuration LIKE '%123abc%'))"
php bin/console doctrine:query:sql "INSERT INTO swp_rule (id, expression, priority, configuration, tenant_code, organization_id, description, name) SELECT nextval('swp_rule_id_seq'), 'true == true', 1, 'a:1:{s:12:\"destinations\";a:1:{i:0;a:1:{s:6:\"tenant\";s:6:\"123abc\";}}}', NULL, organization_id, 'Local bootstrap rule: send every incoming package to the default tenant.', 'Local Default Tenant Catch-all' FROM swp_tenant WHERE code = '123abc' AND NOT EXISTS (SELECT 1 FROM swp_rule WHERE tenant_code IS NULL AND name = 'Local Default Tenant Catch-all')"
php bin/console doctrine:query:sql "INSERT INTO swp_content_list (id, name, description, type, cache_life_time, list_limit, filters, enabled, created_at, updated_at, tenant_code) SELECT nextval('swp_content_list_id_seq'), seeded.name, NULL, 'manual', NULL, NULL, 'a:0:{}', true, NOW(), NOW(), '123abc' FROM unnest(ARRAY[${CONTENT_LIST_NAMES_IN}]) AS seeded(name) WHERE NOT EXISTS (SELECT 1 FROM swp_content_list existing WHERE existing.tenant_code = '123abc' AND existing.name = seeded.name)"
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
php bin/console doctrine:query:sql "INSERT INTO swp_route (host, schemes, methods, defaults, requirements, options, variable_pattern, staticprefix, type, cache_time_in_seconds, name, position, lft, rgt, level, tenant_code, slug, paywall_secured) SELECT '', 'a:0:{}', 'a:0:{}', 'a:1:{s:4:\"slug\";N;}', 'a:1:{s:4:\"slug\";s:16:\"[a-zA-Z0-9*\-_]+\";}', 'a:0:{}', '/{slug}', '/' || seeded.slug, 'collection', 0, seeded.name, base.next_position + seeded.n - 1, base.max_rgt + (seeded.n - 1) * 2 + 1, base.max_rgt + (seeded.n - 1) * 2 + 2, 0, '123abc', seeded.slug, false FROM (SELECT candidate.name, candidate.slug, row_number() OVER (ORDER BY candidate.ord) AS n FROM (VALUES ('English', 'english', 1), ('French', 'french', 2), ('Somali', 'somali', 3), ('Kiswahili', 'kiswahili', 4), ('Amharic', 'amharic', 5), ('Afaan Oromo', 'afaan-oromo', 6)) AS candidate(name, slug, ord) WHERE NOT EXISTS (SELECT 1 FROM swp_route existing WHERE existing.tenant_code = '123abc' AND existing.name = candidate.name)) AS seeded CROSS JOIN (SELECT COALESCE(MAX(rgt), 0) AS max_rgt, COALESCE(MAX(position) + 1, 0) AS next_position FROM swp_route WHERE tenant_code = '123abc') AS base"
php bin/console doctrine:query:sql "INSERT INTO swp_rule (id, expression, priority, configuration, tenant_code, organization_id, description, name) SELECT nextval('swp_rule_id_seq'), 'article.getLocale() == \"' || lang.code || '\"', 1, 'a:2:{s:5:\"route\";i:' || route.id || ';s:9:\"published\";b:1;}', '123abc', tenant.organization_id, 'Local bootstrap rule: send ' || lang.name || ' articles to the ' || lang.name || ' route.', 'Local ' || lang.name || ' Language Route' FROM (VALUES ('en', 'English'), ('fr', 'French'), ('so', 'Somali'), ('sw', 'Kiswahili'), ('am', 'Amharic'), ('om', 'Afaan Oromo')) AS lang(code, name) JOIN swp_route route ON route.tenant_code = '123abc' AND route.name = lang.name CROSS JOIN (SELECT organization_id FROM swp_tenant WHERE code = '123abc') AS tenant WHERE NOT EXISTS (SELECT 1 FROM swp_rule existing WHERE existing.tenant_code = '123abc' AND existing.name = 'Local ' || lang.name || ' Language Route')"
php bin/console doctrine:query:sql "INSERT INTO swp_menu (id, root_id, parent_id, route_id, name, label, link_attributes, children_attributes, label_attributes, uri, attributes, extras, lft, rgt, level, position, tenant_code) SELECT nextval('swp_menu_id_seq'), NULL, NULL, NULL, 'mainNavigation', 'Main Navigation', 'a:0:{}', 'a:0:{}', 'a:0:{}', NULL, 'a:0:{}', 'a:0:{}', 1, 2, 0, 0, '123abc' WHERE NOT EXISTS (SELECT 1 FROM swp_menu WHERE tenant_code = '123abc' AND name = 'mainNavigation' AND parent_id IS NULL)"
php bin/console doctrine:query:sql "UPDATE swp_menu SET root_id = id WHERE tenant_code = '123abc' AND parent_id IS NULL AND root_id IS NULL"
php bin/console doctrine:query:sql "INSERT INTO swp_menu (id, root_id, parent_id, route_id, name, label, link_attributes, children_attributes, label_attributes, uri, attributes, extras, lft, rgt, level, position, tenant_code) SELECT nextval('swp_menu_id_seq'), root.id, root.id, seeded.route_id, seeded.slug, seeded.name, 'a:0:{}', 'a:0:{}', 'a:0:{}', seeded.uri, 'a:0:{}', 'a:1:{s:6:\"routes\";a:1:{i:0;a:2:{s:5:\"route\";s:' || octet_length(seeded.name) || ':\"' || seeded.name || '\";s:10:\"parameters\";a:0:{}}}}', base.max_rgt + (seeded.n - 1) * 2 + 1, base.max_rgt + (seeded.n - 1) * 2 + 2, 1, base.next_position + seeded.n - 1, '123abc' FROM (SELECT id FROM swp_menu WHERE tenant_code = '123abc' AND name = 'mainNavigation' AND parent_id IS NULL) AS root CROSS JOIN LATERAL (SELECT COALESCE(MAX(rgt), 1) AS max_rgt, COALESCE(MAX(position) + 1, 0) AS next_position FROM swp_menu child WHERE child.tenant_code = '123abc' AND child.parent_id = root.id) AS base CROSS JOIN LATERAL (SELECT r.id AS route_id, r.name, r.slug, r.staticprefix AS uri, row_number() OVER (ORDER BY r.position) AS n FROM swp_route r WHERE r.tenant_code = '123abc' AND r.name IN ('English', 'French', 'Somali', 'Kiswahili', 'Amharic', 'Afaan Oromo') AND NOT EXISTS (SELECT 1 FROM swp_menu item WHERE item.tenant_code = '123abc' AND item.parent_id = root.id AND item.route_id = r.id)) AS seeded"
php bin/console doctrine:query:sql "UPDATE swp_menu AS root SET rgt = COALESCE((SELECT MAX(child.rgt) FROM swp_menu child WHERE child.root_id = root.id AND child.id <> root.id), 1) + 1 WHERE root.tenant_code = '123abc' AND root.name = 'mainNavigation' AND root.parent_id IS NULL"
php bin/console sylius:theme:assets:install
php bin/console cache:clear
