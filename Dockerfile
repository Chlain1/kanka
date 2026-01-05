# syntax=docker/dockerfile:1.6

###############################
# Base PHP image with extensions
###############################
FROM php:8.4-fpm-bookworm AS php-base

ARG WWWGROUP=1000
ARG WWWUSER=1000
ENV DEBIAN_FRONTEND=noninteractive \
    APP_DIR=/var/www/html

RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    unzip \
    curl \
    libzip-dev \
    libpng-dev \
    libjpeg62-turbo-dev \
    libfreetype6-dev \
    libicu-dev \
    libonig-dev \
    libxml2-dev \
    libssl-dev \
    libcurl4-openssl-dev \
    pkg-config \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql gd intl zip opcache pcntl \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && usermod -u "${WWWUSER}" www-data && groupmod -g "${WWWGROUP}" www-data \
    && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Reasonable opcache defaults for production
RUN printf "opcache.enable=1\nopcache.enable_cli=1\nopcache.memory_consumption=256\nopcache.interned_strings_buffer=16\nopcache.max_accelerated_files=20000\nopcache.validate_timestamps=0\nopcache.revalidate_freq=0\n" > /usr/local/etc/php/conf.d/opcache-recommended.ini

WORKDIR ${APP_DIR}

###############################
# Install PHP dependencies
###############################
FROM php-base AS composer-deps
WORKDIR ${APP_DIR}

COPY composer.json composer.lock ./
RUN composer install \
    --no-dev \
    --no-progress \
    --no-interaction \
    --prefer-dist \
    --optimize-autoloader \
    --no-scripts

###############################
# Build frontend assets
###############################
FROM node:22-bookworm AS frontend
WORKDIR /app

RUN corepack enable && corepack prepare yarn@1.22.22 --activate

COPY package.json yarn.lock vite.config.js tailwind.config.js ./
COPY resources ./resources
COPY public ./public

ENV YARN_PRODUCTION=false \
    NODE_ENV=development
RUN yarn install --frozen-lockfile --non-interactive --production=false

# Build assets in production mode
ENV NODE_ENV=production
RUN yarn build

###############################
# Final PHP runtime image
###############################
FROM php-base AS php-runtime
ENV APP_ENV=production \
    APP_DEBUG=false
WORKDIR ${APP_DIR}

COPY . .
COPY --from=composer-deps ${APP_DIR}/vendor ./vendor
COPY --from=frontend /app/public/build ./public/build

RUN mkdir -p storage/framework/cache storage/framework/sessions storage/framework/views storage/app/public bootstrap/cache \
    && ln -sfn /var/www/html/storage/app/public /var/www/html/public/storage \
    && chown -R www-data:www-data storage bootstrap/cache \
    && find storage bootstrap/cache -type d -exec chmod 775 {} \; \
    && find storage bootstrap/cache -type f -exec chmod 664 {} \;

EXPOSE 9000
CMD ["php-fpm"]

###############################
# Nginx image serving the app
###############################
FROM nginx:1.26-alpine AS nginx-runtime
WORKDIR /var/www/html

COPY --from=php-runtime /var/www/html/public /var/www/html/public
COPY docker/deploy/nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
