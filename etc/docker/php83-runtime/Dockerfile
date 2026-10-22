FROM php:8.3.36-fpm-alpine@sha256:81cb692948e6de4275f7e107c50a34e963a440660f2c5b8502d11071f7d30338 AS runtime
RUN apk --no-cache add \
        postgresql-dev zlib-dev libxml2-dev curl-dev \
        freetype libpng libjpeg-turbo freetype-dev libpng-dev libjpeg-turbo-dev \
        libintl icu icu-dev git libmemcached-dev autoconf build-base linux-headers \
        rabbitmq-c-dev libzip-dev zip oniguruma-dev libwebp-dev curl jq \
    && docker-php-ext-configure intl \
    && docker-php-ext-configure pgsql -with-pgsql=/usr/local/pgsql \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j4 intl pdo pdo_pgsql pgsql opcache sockets exif bcmath zip xml gd mbstring curl \
    && pecl install memcached-3.4.0 && docker-php-ext-enable memcached
ENV COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1 APP_ENV=prod APP_DEBUG=0
WORKDIR /var/www/publisher

# Preserve the deployed application/configuration while replacing its runtime.
FROM codeforafrica/superdesk-web-publisher-php@sha256:b01233f4cfe1f063a10489d86cfd61d3101e8e95891c00be5f8b73c61d45725d AS deployed_php
FROM codeforafrica/superdesk-web-publisher-websocket@sha256:8c8bf0765c357ba7b6dca8fc098be46a968d688180cf49ceaa0fc140195ed6bf AS deployed_websocket

FROM runtime AS php
RUN pecl install amqp-1.11.0 && docker-php-ext-enable amqp
COPY --from=deployed_php /var/www/publisher/ /var/www/publisher/
COPY --from=deployed_php /usr/bin/composer /usr/bin/composer
COPY --from=deployed_php /usr/local/etc/php/conf.d/zz-production.ini /usr/local/etc/php/conf.d/zz-production.ini
RUN --mount=from=deployed_php,source=/usr/local/bin,target=/deployed-bin \
    --mount=from=deployed_php,source=/usr/local/share,target=/deployed-share \
    for file in /deployed-bin/*.sh; do [ ! -f "$file" ] || cp -p "$file" /usr/local/bin/; done; \
    if [ -d /deployed-share/hasura ]; then cp -a /deployed-share/hasura /usr/local/share/; fi
COPY composer.json composer.lock ./
RUN composer install --no-dev --classmap-authoritative --no-scripts --prefer-dist --no-progress \
    && rm -rf var/cache/* \
    && php bin/console cache:warmup --env=prod --no-debug \
    && chown -R www-data:www-data var
CMD ["php-fpm"]

FROM runtime AS websocket
RUN apk --no-cache add supervisor \
    && pecl install amqp-2.2.0 && docker-php-ext-enable amqp
COPY --from=deployed_websocket /var/www/publisher/ /var/www/publisher/
COPY --from=deployed_websocket /usr/bin/composer /usr/bin/composer
COPY --from=deployed_websocket /usr/local/etc/php/conf.d/zz-production.ini /usr/local/etc/php/conf.d/zz-production.ini
COPY --from=deployed_websocket /etc/supervisor.d/supervisor.ini /etc/supervisor.d/supervisor.ini
COPY composer.json composer.lock ./
RUN composer install --no-dev --classmap-authoritative --no-scripts --prefer-dist --no-progress \
    && rm -rf var/cache/* \
    && php bin/console cache:warmup --env=prod --no-debug \
    && chown -R www-data:www-data var
CMD ["supervisord", "-n"]
