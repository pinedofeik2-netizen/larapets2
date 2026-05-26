# ============================================================================
# Stage 1: Build dependencias PHP (Composer)
# ============================================================================
FROM composer:2 AS composer-builder
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-interaction --prefer-dist --optimize-autoloader
COPY . .
RUN composer dump-autoload --optimize --no-dev

# ============================================================================
# Stage 2: Build assets frontend (Node.js)
# ============================================================================
FROM node:20 AS assets-builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
# Copiamos todo el proyecto incluyendo la carpeta vendor generada por composer
# Esto es necesario para que TailwindCSS pueda escanear las vistas de Laravel
COPY --from=composer-builder /app ./
RUN npm run build

# ============================================================================
# Stage 3: Imagen final de producción
# ============================================================================
FROM php:8.2-cli

# ── Dependencias del sistema ──────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    libpng-dev \
    libonig-dev \
    libxml2-dev \
    libzip-dev \
    libfreetype6-dev \
    libjpeg62-turbo-dev \
    libicu-dev \
    zip \
    unzip \
    curl \
    && rm -rf /var/lib/apt/lists/*

# ── Extensiones PHP ───────────────────────────────────────────────────────────
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        pdo_mysql \
        mbstring \
        exif \
        pcntl \
        bcmath \
        gd \
        zip \
        intl

# Habilitar OPcache
RUN docker-php-ext-enable opcache
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
    && echo "opcache.enable=1" >> "$PHP_INI_DIR/conf.d/opcache.ini" \
    && echo "opcache.memory_consumption=128" >> "$PHP_INI_DIR/conf.d/opcache.ini" \
    && echo "opcache.max_accelerated_files=10000" >> "$PHP_INI_DIR/conf.d/opcache.ini"

WORKDIR /var/www/html

# ── Copiar código y dependencias de los stages anteriores ─────────────────────
COPY . .
COPY --from=composer-builder /app/vendor ./vendor
COPY --from=assets-builder /app/public/build ./public/build

# ── Permisos de Laravel ───────────────────────────────────────────────────────
RUN mkdir -p storage/logs \
    storage/framework/cache/data \
    storage/framework/sessions \
    storage/framework/views \
    bootstrap/cache \
    && chown -R www-data:www-data storage bootstrap/cache \
    && chmod -R 775 storage bootstrap/cache

EXPOSE 8000

# ── Script de inicio ──────────────────────────────────────────────────────────
CMD sh -c "\
    php artisan config:cache && \
    php artisan route:cache && \
    php artisan view:cache && \
    php artisan migrate --force && \
    php artisan serve --host=0.0.0.0 --port=\${PORT:-8000}"
