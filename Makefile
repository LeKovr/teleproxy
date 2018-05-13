##
## Golang application Makefile
##

SHELL      = /bin/bash
GO            ?= go

# application name
PRG        ?= teleproxy

# docker compose name
SERVICE     = $(PRG)

DIRDIST   ?= dist
ALLARCH   ?= "linux/amd64"
# linux/386 windows/amd64 darwin/386"

# Docker image build vars
# docker-compose version
DC_VER        = 1.14.0
# golang version
GO_VER        = 1.9.0-alpine3.6

# Dcape vars

# container prefix
PROJECT_NAME ?= elfire

# dcape container name prefix
DCAPE_PROJECT_NAME ?= dcape
# dcape network attach to
DCAPE_NET          ?= $(DCAPE_PROJECT_NAME)_default
# dcape postgresql container name
DCAPE_DB           ?= $(DCAPE_PROJECT_NAME)_db_1

# ------------------------------------------------------------------------------
# config vars

# Telegram bot token
TOKEN        ?= bot_token

# Telegram group ID (without -)
GROUP        ?= group_id

# Customer & message store
DSN              ?= /data/teleproxy.db

# Database name
DB_NAME            ?= teleproxy
# Database user name
DB_USER            ?= $(DB_NAME)
# Database user password
DB_PASS            ?= $(shell < /dev/urandom tr -dc A-Za-z0-9 | head -c14; echo)

# Messages template
TEMPLATE           ?= messages.en.tmpl

# ------------------------------------------------------------------------------

-include .env
export

# ------------------------------------------------------------------------------

.PHONY: all build clean lint docker up down build-docker start-hook update restart end run status dc help
.PHONY: all run ver buildall clean dist link vet

##
## Available targets are:
##

## build and run in foreground
run: build
	./$(PRG) --log_level debug --group $$GROUP --token $$TOKEN --template $$TEMPLATE --command ./commands.sh

## Build cmds
build: gen $(PRG)

## Generate protobuf/mock/bindata
gen: cmd/$(PRG)/bindata.go

cmd/$(PRG)/bindata.go: messages.tmpl messages.en.tmpl
	$(GO) generate ./cmd/$(PRG)/...

## Build command
$(PRG): cmd/$(PRG)/*.go $(SOURCES)
	[ -d .git ] && GH=`git rev-parse HEAD` || GH=nogit ; \
	  GOOS=$(OS) GOARCH=$(ARCH) $(GO) build -v -o $@ -ldflags \
	  "-X main.Build=$(STAMP) -X main.Commit=$$GH" ./cmd/$@

## Build command for scratch docker
build-standalone: lint vet gen
	[ -d .git ] && GH=`git rev-parse HEAD` || GH=nogit ; \
	  $(GO) build -a -v -o $(PRG) -ldflags \
	  "-X main.Build=$(STAMP) -X main.Commit=$$GH" ./cmd/$(PRG)

## run go lint
lint:
	@echo "*** $@ ***"
	@golint cmd/$(PRG)/*.go

## run go vet
vet:
	@echo "*** $@ ***"
	@go vet cmd/$(PRG)/*.go

# install vendor deps
vendor:
	@echo "*** $@ ***"
	which glide > /dev/null || curl https://glide.sh/get | sh
	@echo "*** $@:glide ***"
	glide install

# clean binary
clean:
	@[ -f $(PRG) ] && rm $(PRG) || true
	@[ -f cmd/$(PRG)/bindata.go ] && rm cmd/$(PRG)/bindata.go || true
	@[ -d vendor ] && rm -rf vendor || true

# ------------------------------------------------------------------------------

## Build docker image if none
docker:
	@$(MAKE) -s dc CMD="build $(SERVICE)" || echo ""

## Rebuild docker image
docker-force:
	@$(MAKE) -s dc CMD="build --no-cache --force-rm"

## Start docker container
up:
	@$(MAKE) -s dc CMD="up -d --force-recreate $(SERVICE)" || echo ""

## Stop and remove docker container
down:
	@$(MAKE) -s dc CMD="rm -f -s $(SERVICE)" || echo ""

# ------------------------------------------------------------------------------
# webhook commands

start-hook: up

update: up

stop: down

# ------------------------------------------------------------------------------
# Distro ops

## build app for all platforms
buildall:
	@pushd cmd/$(PRG) > /dev/null
	@for a in "$(ALLARCH)" ; do \
	  echo "** $${a%/*} $${a#*/}" ; \
	  P=$(PRG)_$${a%/*}_$${a#*/} ; \
	  [ "$${a%/*}" == "windows" ] && P=$$P.exe ; \
	  GOOS=$${a%/*} GOARCH=$${a#*/} $(MAKE) -s build ; \
	@done
	@popd > /dev/null

## create disro files
dist: clean-dist buildall
	@echo "*** $@ ***"
	@[ -d $(DIRDIST) ] || mkdir $(DIRDIST) ; \
	@pushd cmd/$(PRG) > /dev/null
	sha256sum $(PRG)* > ../../$(DIRDIST)/SHA256SUMS ; \
	@for a in "$(ALLARCH)" ; do \
	  echo "** $${a%/*} $${a#*/}" ; \
	  P=$(PRG)_$${a%/*}_$${a#*/} ; \
	  [ "$${a%/*}" == "windows" ] && P1=$$P.exe || P1=$$P ; \
	  zip "../../$(DIRDIST)/$$P.zip" "$$P1" README.md ; \
	done
	@popd > /dev/null

## clean generated files
clean-dist:
	@echo "*** $@ ***"
	@pushd cmd/$(PRG) > /dev/null
	@for a in "$(ALLARCH)" ; do \
	  P=$(PRG)_$${a%/*}_$${a#*/} ; \
	  [ "$${a%/*}" == "windows" ] && P=$$P.exe ; \
	  [ -f $$P ] && rm $$P || true ; \
	done ; \
	@popd > /dev/null
	@[ -d $(DIRDIST) ] && rm -rf $(DIRDIST) || true

# ------------------------------------------------------------------------------
# Setup targets

# Файл .env
define CONFIG_DEF
# config file, generated by make .env

# Telegram bot token
TOKEN=$(TOKEN)

# Telegram group ID (without -)
GROUP=$(GROUP)

# Customer & message store
DSN=$(DSN)

# Command executor
CMD_URL=

# dcape network connect to, must be set in .env
DCAPE_NET=$(DCAPE_NET)

# Messages template
TEMPLATE=$(TEMPLATE)

endef
export CONFIG_DEF

## Create .env file with default config
.env:
	@echo "*** $@ ***"
	@[ -f $@ ] || echo "$$CONFIG_DEF" > $@

# ------------------------------------------------------------------------------
# DB operations

# Database import script
# DCAPE_DB_DUMP_DEST must be set in pg container

# Wait for postgresql container start
docker-wait:
	@echo -n "Checking PG is ready..."
	@until [[ `docker inspect -f "{{.State.Health.Status}}" $$DCAPE_DB` == healthy ]] ; do sleep 1 ; echo -n "." ; done
	@echo "Ok"

# create user, db and load dump
db-create: docker-wait
	@echo "*** $@ ***" ; \
	docker exec -i $$DCAPE_DB psql -U postgres -c "CREATE USER \"$$DB_USER\" WITH PASSWORD '$$DB_PASS';" || true ; \
	docker exec -i $$DCAPE_DB psql -U postgres -c "CREATE DATABASE \"$$DB_NAME\" OWNER \"$$DB_USER\";" || db_exists=1 ; \

## drop database and user
db-drop: docker-wait
	@echo "*** $@ ***"
	@docker exec -it $$DCAPE_DB psql -U postgres -c "DROP DATABASE \"$$DB_NAME\";" || true
	@docker exec -it $$DCAPE_DB psql -U postgres -c "DROP USER \"$$DB_USER\";" || true

psql: docker-wait
	@docker exec -it $$DCAPE_DB psql -U $$DB_USER -d $$DB_NAME


# ------------------------------------------------------------------------------

# $$PWD используется для того, чтобы текущий каталог был доступен в контейнере по тому же пути
# и относительные тома новых контейнеров могли его использовать
## run docker-compose
dc: docker-compose.yml
	@docker run --rm  -i \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $$PWD:$$PWD \
  -w $$PWD \
  --env=golang_version=$$GO_VER \
  docker/compose:$$DC_VER \
  -p $$PROJECT_NAME \
  $(CMD)

all: help

help:
	@grep -A 1 "^##" Makefile | less

##
## Press 'q' for exit
##
