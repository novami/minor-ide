FROM php:8.4-fpm AS base
# comment
RUN apt-get update && apt-get install -y git \
	unzip
ENV APP_ENV=prod
COPY . /app
