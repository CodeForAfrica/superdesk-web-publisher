FROM php:8.0-fpm-alpine

RUN apk update

RUN set -ex \
    && apk --no-cache add \
        autoconf \
        build-base \
        libmemcached-dev \
        postgresql-dev \
        rabbitmq-c-dev \
        zlib-dev \
        supervisor \
    && docker-php-ext-configure pgsql -with-pgsql=/usr/local/pgsql \
    && docker-php-ext-install pdo pdo_pgsql pgsql sockets \
    && pecl install memcached \
    && docker-php-ext-enable memcached \
    && pecl install amqp \
    && docker-php-ext-enable amqp

COPY supervisor.ini /etc/supervisor.d/supervisor.ini

CMD ["supervisord"]
