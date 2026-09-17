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

use SWP\Bundle\ContentBundle\Model\ArticleInterface;
use SWP\Bundle\ContentListBundle\Services\ContentListServiceInterface;
use SWP\Component\ContentList\Model\ContentListInterface;
use SWP\Component\ContentList\Repository\ContentListRepositoryInterface;
use SWP\Component\MultiTenancy\Context\TenantContextInterface;
use SWP\Component\MultiTenancy\Repository\TenantRepositoryInterface;
use SWP\Component\Storage\Repository\RepositoryInterface;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Style\SymfonyStyle;

/**
 * Fill the CURATED content lists with their tracked article membership, resolving
 * each item's stable Superdesk GUID (swp_article.code) to the local article.
 *
 * WHY
 *   swp:config:load seeds list DEFINITIONS only; membership is content and lands
 *   asynchronously (ingest / authored-page publish), so it is seeded here, after
 *   content has drained into Publisher — the curated analogue of
 *   seed-content-lists.sh's random homepage fill. See the plan
 *   docs/plans/publisher-curated-list-membership.md.
 *
 * INPUT  content_list_items.json in the tracked config dir: { "<list name>":
 *        [ {guid, slug, sticky}, ... ] } in position order.
 *
 * IDEMPOTENT & NON-DESTRUCTIVE
 *   A list that already holds items is left untouched (an editor may have curated
 *   it, and a re-run must not duplicate) — the same "fill only empty lists" rule
 *   as the random seeder. GUIDs that do not resolve yet (article not published to
 *   Publisher) are skipped and counted, so a partial content load degrades
 *   gracefully rather than failing.
 */
class SeedContentListItemsCommand extends Command
{
    protected static $defaultName = 'swp:config:seed-list-items';

    private TenantRepositoryInterface $tenantRepository;
    private TenantContextInterface $tenantContext;
    private ContentListRepositoryInterface $contentListRepository;
    private RepositoryInterface $contentListItemRepository;
    private RepositoryInterface $articleRepository;
    private ContentListServiceInterface $contentListService;

    public function __construct(
        TenantRepositoryInterface $tenantRepository,
        TenantContextInterface $tenantContext,
        ContentListRepositoryInterface $contentListRepository,
        RepositoryInterface $contentListItemRepository,
        RepositoryInterface $articleRepository,
        ContentListServiceInterface $contentListService
    ) {
        $this->tenantRepository = $tenantRepository;
        $this->tenantContext = $tenantContext;
        $this->contentListRepository = $contentListRepository;
        $this->contentListItemRepository = $contentListItemRepository;
        $this->articleRepository = $articleRepository;
        $this->contentListService = $contentListService;

        parent::__construct();
    }

    protected function configure(): void
    {
        $this
            ->setName(self::$defaultName)
            ->setDescription('Fill curated content lists with their tracked article membership (by GUID).')
            ->addArgument('tenant', InputArgument::REQUIRED, 'Tenant code, e.g. 123abc')
            ->addArgument('dir', InputArgument::REQUIRED, 'Directory holding content_list_items.json');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $io = new SymfonyStyle($input, $output);
        $tenantCode = $input->getArgument('tenant');
        $path = rtrim($input->getArgument('dir'), '/').'/content_list_items.json';

        if (!is_file($path)) {
            $io->warning(sprintf('%s not found; nothing to seed.', $path));

            return Command::SUCCESS;
        }

        $tenant = $this->tenantRepository->findOneByCode($tenantCode);
        if (null === $tenant) {
            $io->error(sprintf('Tenant "%s" does not exist.', $tenantCode));

            return Command::FAILURE;
        }
        $this->tenantContext->setTenant($tenant);

        $membership = json_decode((string) file_get_contents($path), true, 512, JSON_THROW_ON_ERROR);
        $seeded = $skippedFull = $missing = 0;

        foreach ($membership as $listName => $items) {
            /** @var ContentListInterface|null $list */
            $list = $this->contentListRepository->findOneBy(['name' => $listName]);
            if (null === $list) {
                $io->writeln(sprintf('  <comment>list not found, skipped: %s</comment>', $listName));
                continue;
            }
            // Non-clobber: only fill lists that are currently empty.
            if (count($this->contentListItemRepository->findBy(['contentList' => $list])) > 0) {
                ++$skippedFull;
                continue;
            }
            $position = 0;
            foreach ($items as $item) {
                /** @var ArticleInterface|null $article */
                $article = $this->articleRepository->findOneBy(['code' => $item['guid']]);
                if (null === $article) {
                    ++$missing;
                    continue;
                }
                $this->contentListService->addArticleToContentList(
                    $list, $article, $position, (bool) ($item['sticky'] ?? false)
                );
                ++$position;
                ++$seeded;
            }
        }

        $io->success(sprintf(
            'Content-list membership: %d item(s) seeded, %d list(s) already populated (skipped), %d GUID(s) not resolvable yet.',
            $seeded, $skippedFull, $missing
        ));

        return Command::SUCCESS;
    }
}
