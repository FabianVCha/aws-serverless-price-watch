SHELL := /bin/bash
STACK ?= price-watch
BUCKET ?= price-watch-artifacts

.PHONY: help up down status deploy destroy e2e build clean

help:
	@echo "make up       start the local aws-emulator and write .emulator.env"
	@echo "make deploy   package, upload and create/update the stack (needs 'make up')"
	@echo "make e2e      full cycle: up -> deploy -> acceptance tests -> down"
	@echo "make destroy  delete the stack and the artifact bucket"
	@echo "make status   is the emulator running?"
	@echo "make clean    remove build output and emulator state files"

up:
	@PORT=$${PORT:-9297} ./scripts/emulator.sh up

down:
	@./scripts/emulator.sh down

status:
	@./scripts/emulator.sh status

build:
	@mkdir -p .build
	@node --check src/api/index.mjs
	@node --check src/notifier/index.mjs
	@echo "syntax ok"

deploy: build
	@STACK=$(STACK) BUCKET=$(BUCKET) ./scripts/deploy.sh

destroy:
	@STACK=$(STACK) BUCKET=$(BUCKET) ./scripts/destroy.sh

e2e:
	@set -e; \
	./scripts/emulator.sh up; \
	trap './scripts/emulator.sh down' EXIT; \
	STACK=$(STACK) BUCKET=$(BUCKET) ./scripts/deploy.sh; \
	STACK=$(STACK) timeout 300 ./tests/e2e.sh

clean:
	@rm -rf .build .emulator.env .emulator.log
	@echo "cleaned"
