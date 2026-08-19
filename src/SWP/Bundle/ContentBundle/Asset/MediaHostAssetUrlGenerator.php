<?php

declare(strict_types=1);

/*
 * This file is part of the Superdesk Web Publisher Content Bundle.
 *
 * Copyright 2020 Sourcefabric z.ú. and contributors.
 *
 * For the full copyright and license information, please see the
 * AUTHORS and LICENSE files distributed with this source code.
 *
 * @copyright 2020 Sourcefabric z.ú
 * @license http://www.superdesk.org/license
 */

namespace SWP\Bundle\ContentBundle\Asset;

use SWP\Bundle\ContentBundle\Model\FileInterface;

/**
 * Emits absolute public media-host URLs for assets, e.g.
 *   https://media-staging.pesacheck.org/media/<assetId>.<ext>
 *
 * PesaCheck deployment note: Publisher does not serve media itself. Its
 * local_adapter copy is never written here — publisher-php and publisher-nginx
 * are separate ECS containers with no shared filesystem, and binaries are not
 * pushed to Publisher (Superdesk publishes direct-S3 links). Every asset already
 * lives durably in Superdesk's S3 at `superdesk/<date>/<objectId>`, fronted by
 * the media host + Cloudflare Worker, which maps `/media/<date>_<objectId>.<ext>`
 * onto that key. The Publisher asset id is already the `<date>_<objectId>` form,
 * so it maps 1:1 and the extension is ignored by the Worker.
 *
 * When SWP_MEDIA_HOST is empty this falls back to the stock local relative URL
 * (`<localDirectory>/<basePath>/<assetId>.<ext>`), so local dev — where nginx and
 * php share the uploads volume — keeps working unchanged.
 */
final class MediaHostAssetUrlGenerator implements AssetUrlGeneratorInterface
{
    private ?string $mediaHost;

    private ?string $localDirectory;

    public function __construct(?string $mediaHost = null, ?string $localDirectory = null)
    {
        $this->mediaHost = null !== $mediaHost ? rtrim($mediaHost, '/') : null;
        $this->localDirectory = $localDirectory;
    }

    public function generateUrl(FileInterface $file, string $basePath): string
    {
        $filename = $file->getAssetId().'.'.$file->getFileExtension();

        if (!empty($this->mediaHost)) {
            return $this->mediaHost.'/media/'.$filename;
        }

        // Fallback: stock LocalAssetUrlGenerator relative behaviour.
        return ($this->localDirectory ? $this->localDirectory.DIRECTORY_SEPARATOR : null).
            $basePath.
            DIRECTORY_SEPARATOR.
            $filename
        ;
    }
}
