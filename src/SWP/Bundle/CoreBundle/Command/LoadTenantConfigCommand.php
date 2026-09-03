<?php

declare(strict_types=1);

/*
 * This file is part of the Superdesk Web Publisher Core Bundle.
 *
 * For the full copyright and license information, please see the
 * AUTHORS and LICENSE files distributed with this source code.
 *
 * @license http://www.superdesk.org/license
 */

namespace SWP\Bundle\CoreBundle\Command;

use SWP\Bundle\ContentBundle\Provider\RouteProviderInterface;
use SWP\Bundle\CoreBundle\Model\RuleInterface;
use SWP\Bundle\CoreBundle\Repository\RuleRepositoryInterface;
use SWP\Bundle\CoreBundle\Theme\Generator\GeneratorInterface;
use SWP\Bundle\SettingsBundle\Manager\SettingsManagerInterface;
use SWP\Component\MultiTenancy\Context\TenantContextInterface;
use SWP\Component\MultiTenancy\Repository\TenantRepositoryInterface;
use SWP\Component\Storage\Factory\FactoryInterface;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Style\SymfonyStyle;

/**
 * Seed a tenant's tracked Publisher config (routes, rules, content lists, menus,
 * settings) from the JSON tree under etc/docker/bootstrap/publisher-config/.
 *
 * WHY THIS EXISTS
 *   Publisher tenant config lives in Postgres and is destroyed by every
 *   wipe-and-reseed (ops/aws/scripts/reset-content.sh). This command is the
 *   loader half of the tracked-JSON pattern (see the plan
 *   docs/plans/publisher-config-as-tracked-json.md in the superproject and its
 *   dump.sh/convert.py under scripts/publisher-config/): it re-applies the
 *   captured config so a fresh stack comes up with the hand-curated navigation
 *   and editorial content lists intact.
 *
 * HOW
 *   It sets the tenant context and then delegates the tree-building work to
 *   SWP's OWN theme generators (swp_core.generator.theme.{routes,menus,
 *   content_lists}) so the Gedmo nested-set bookkeeping (lft/rgt/level/root) and
 *   the RouteService boilerplate (variable_pattern, slug requirement,
 *   staticprefix) are produced by the code that owns them — not reimplemented.
 *   Rules have no theme generator, so they are created directly against the rule
 *   factory/repository, resolving each rule's route by NAME to its id.
 *
 * IDEMPOTENT & NON-DESTRUCTIVE
 *   The generators skip an entity that already exists (by name, tenant-scoped),
 *   and the rule loader skips an existing rule. Only DEFINITIONS are written —
 *   swp_content_list_item (curated / random-filled membership) is never touched,
 *   so re-running never clobbers an editor's curation.
 *
 * NOT LOADED (deny-list, see the plan): swp_api_key and swp_publish_destination
 *   (secrets / per-package runtime) and user-scoped settings (per-user runtime).
 */
class LoadTenantConfigCommand extends Command
{
    protected static $defaultName = 'swp:config:load';

    private TenantRepositoryInterface $tenantRepository;
    private TenantContextInterface $tenantContext;
    private GeneratorInterface $routesGenerator;
    private GeneratorInterface $menusGenerator;
    private GeneratorInterface $contentListsGenerator;
    private RouteProviderInterface $routeProvider;
    private RuleRepositoryInterface $ruleRepository;
    private FactoryInterface $ruleFactory;
    private SettingsManagerInterface $settingsManager;

    public function __construct(
        TenantRepositoryInterface $tenantRepository,
        TenantContextInterface $tenantContext,
        GeneratorInterface $routesGenerator,
        GeneratorInterface $menusGenerator,
        GeneratorInterface $contentListsGenerator,
        RouteProviderInterface $routeProvider,
        RuleRepositoryInterface $ruleRepository,
        FactoryInterface $ruleFactory,
        SettingsManagerInterface $settingsManager
    ) {
        $this->tenantRepository = $tenantRepository;
        $this->tenantContext = $tenantContext;
        $this->routesGenerator = $routesGenerator;
        $this->menusGenerator = $menusGenerator;
        $this->contentListsGenerator = $contentListsGenerator;
        $this->routeProvider = $routeProvider;
        $this->ruleRepository = $ruleRepository;
        $this->ruleFactory = $ruleFactory;
        $this->settingsManager = $settingsManager;

        parent::__construct();
    }

    protected function configure(): void
    {
        $this
            ->setName(self::$defaultName)
            ->setDescription('Seed a tenant\'s tracked Publisher config (routes, rules, content lists, menus, settings) from a JSON tree.')
            ->addArgument('tenant', InputArgument::REQUIRED, 'Tenant code, e.g. 123abc')
            ->addArgument('dir', InputArgument::REQUIRED, 'Directory holding the tracked config JSON files');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $io = new SymfonyStyle($input, $output);
        $tenantCode = $input->getArgument('tenant');
        $dir = rtrim($input->getArgument('dir'), '/');

        if (!is_dir($dir)) {
            $io->error(sprintf('Config directory not found: %s', $dir));

            return Command::FAILURE;
        }

        $tenant = $this->tenantRepository->findOneByCode($tenantCode);
        if (null === $tenant) {
            // The tenant is env-driven and created by bootstrap-publisher.sh before
            // this command runs; a missing one means the bootstrap ordering broke.
            $io->error(sprintf('Tenant "%s" does not exist. Run the tenant bootstrap first.', $tenantCode));

            return Command::FAILURE;
        }
        $this->tenantContext->setTenant($tenant);

        // Order matters: routes before rules (rules resolve a route by name) and
        // before menus (a menu item may bind a route).
        $routes = $this->readJson($dir, 'routes.json');
        if (null !== $routes) {
            $this->routesGenerator->generate($routes, false);
            $io->writeln(sprintf('routes: %d processed', count($routes)));
        }

        $rules = $this->readJson($dir, 'rules.json');
        if (null !== $rules) {
            $created = $this->loadRules($rules, $tenant);
            $io->writeln(sprintf('rules: %d processed, %d created', count($rules), $created));
        }

        $contentLists = $this->readJson($dir, 'content_lists.json');
        if (null !== $contentLists) {
            $this->contentListsGenerator->generate($this->prepareContentLists($contentLists), false);
            $io->writeln(sprintf('content lists: %d processed', count($contentLists)));
        }

        $menus = $this->readJson($dir, 'menus.json');
        if (null !== $menus) {
            $this->menusGenerator->generate($menus, false);
            $io->writeln(sprintf('menus: %d root(s) processed', count($menus)));
        }

        $settings = $this->readJson($dir, 'settings.json');
        if (null !== $settings) {
            $applied = $this->loadSettings($settings, $tenant, $io);
            $io->writeln(sprintf('settings: %d processed, %d applied', count($settings), $applied));
        }

        // Latent-config files are captured by dump.sh but the loader has no seeder
        // for them yet (all empty on staging/prod). Fail loudly rather than
        // silently dropping data if one ever shows up with rows.
        foreach (self::UNSUPPORTED_FILES as $file) {
            if (is_file($dir.'/'.$file)) {
                $io->error(sprintf('Found %s but the loader has no seeder for it yet. Add one before shipping this config.', $file));

                return Command::FAILURE;
            }
        }

        $io->success(sprintf('Publisher config loaded for tenant %s.', $tenantCode));

        return Command::SUCCESS;
    }

    private const UNSUPPORTED_FILES = [
        'webhooks.json',
        'output_channels.json',
        'fbia_feeds.json',
        'fbia_pages.json',
        'apple_news_configs.json',
        'redirect_routes.json',
    ];

    private function readJson(string $dir, string $file): ?array
    {
        $path = $dir.'/'.$file;
        if (!is_file($path)) {
            return null;
        }
        $data = json_decode((string) file_get_contents($path), true, 512, JSON_THROW_ON_ERROR);
        if (!is_array($data)) {
            throw new \RuntimeException(sprintf('%s did not decode to a JSON array', $file));
        }

        return $data;
    }

    /**
     * Content lists carry an extra `seed` key (ours, consumed by
     * seed-content-lists.sh, not a ContentListType field) and store `filters` as
     * a decoded object for readability. Strip the former and re-encode the latter
     * to the JSON string the generator/form expects.
     */
    private function prepareContentLists(array $contentLists): array
    {
        $prepared = [];
        foreach ($contentLists as $list) {
            unset($list['seed']);
            $list += ['description' => null, 'limit' => null, 'cacheLifeTime' => null];
            $list['filters'] = empty($list['filters']) ? null : json_encode($list['filters'], JSON_THROW_ON_ERROR);
            $prepared[] = $list;
        }

        return $prepared;
    }

    private function loadRules(array $rules, $tenant): int
    {
        $created = 0;
        foreach ($rules as $ruleData) {
            $name = $ruleData['name'];
            $tenantCode = $ruleData['tenant_code'] ?? null;
            if (null === $tenantCode) {
                // Organization-scoped rules (the catch-all) are routing infra owned
                // by bootstrap-publisher.sh, and the tenant-scoped rule repository
                // cannot see them while a tenant context is set — so seeding one
                // here would duplicate it on every run. convert.py already drops
                // them; skip defensively if one slips into a file.
                continue;
            }
            if (null !== $this->ruleRepository->findOneBy(['name' => $name, 'tenantCode' => $tenantCode])) {
                continue;
            }

            $configuration = $ruleData['configuration'] ?? [];
            // The route inside a rule's configuration is tracked by NAME; resolve
            // it to the local route id. Doctrine's `array` column type serializes
            // the resulting PHP array, reproducing the original blob exactly.
            if (isset($configuration['route']) && is_string($configuration['route'])) {
                $route = $this->routeProvider->getOneByName($configuration['route']);
                if (null === $route) {
                    throw new \RuntimeException(sprintf(
                        'Rule "%s" references route "%s", which was not found. Load routes.json first.',
                        $name,
                        $configuration['route']
                    ));
                }
                $configuration['route'] = $route->getId();
            }

            /** @var RuleInterface $rule */
            $rule = $this->ruleFactory->create();
            $rule->setName($name);
            $rule->setDescription($ruleData['description'] ?? null);
            $rule->setExpression($ruleData['expression']);
            $rule->setPriority((int) ($ruleData['priority'] ?? 0));
            $rule->setConfiguration($configuration);
            $rule->setOrganization($tenant->getOrganization());
            $rule->setTenantCode($tenantCode);
            $this->ruleRepository->add($rule);
            ++$created;
        }
        $this->ruleRepository->flush();

        return $created;
    }

    private function loadSettings(array $settings, $tenant, SymfonyStyle $io): int
    {
        $applied = 0;
        foreach ($settings as $setting) {
            $scope = $setting['scope'] ?? null;
            if ('user' === $scope) {
                // Per-user runtime state — never seeded (defence in depth; convert
                // already drops these).
                continue;
            }
            if ('global' === $scope) {
                $this->settingsManager->set($setting['name'], $setting['value'], 'global');
            } elseif ('tenant' === $scope) {
                $this->settingsManager->set($setting['name'], $setting['value'], 'tenant', $tenant);
            } else {
                throw new \RuntimeException(sprintf(
                    'Setting "%s" has scope "%s", which the loader does not support yet.',
                    $setting['name'] ?? '?',
                    (string) $scope
                ));
            }
            ++$applied;
        }

        return $applied;
    }
}
