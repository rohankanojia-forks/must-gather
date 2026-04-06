.PHONY: clean help test build push lint

MUST_GATHER = gather_dev_spaces.sh
LOGS_DIR    = must-gather

# Container image settings, overwrite as needed
REGISTRY ?= quay.io
REPO     ?= rhn_support_jorbell/dev-spaces-must-gather
TAG      ?= latest
IMAGE    = $(REGISTRY)/$(REPO):$(TAG)
DOCKER_OR_PODMAN := $(shell command -v podman || command -v docker)

help:
	@echo
	@echo "Available commands:"
	@echo "  make help   - Show this usage menu"
	@echo "  make lint   - Run shellcheck on shell scripts"
	@echo "  make clean  - Clear the test files"
	@echo "  make gather - Collect must-gather (skips if exists)"
	@echo "  make test   - Run tests against must-gather"
	@echo "  make build  - Build container image"
	@echo "  make push   - Push container image"
	@echo
	@echo "Variables (override with make VAR=value):"
	@echo "  REGISTRY=$(REGISTRY)"
	@echo "  REPO=$(REPO)"
	@echo "  TAG=$(TAG)"

lint:
	@echo
	@echo "Running shellcheck"
	shellcheck *.sh

clean:
	@echo
	@echo "Cleaning test must-gather"
	rm -rf $(LOGS_DIR)

$(LOGS_DIR): $(MUST_GATHER)
	@echo
	@echo "Collecting test must-gather"
	./$(MUST_GATHER)

gather: $(LOGS_DIR)

test: $(LOGS_DIR)
	@echo
	@echo "Checking test must-gather"
	./test_must_gather.sh

build:
	@echo
	@echo "Building $(IMAGE)"
	$(DOCKER_OR_PODMAN) build -t $(IMAGE) .

push: build
	@echo
	@echo "Pushing $(IMAGE)"
	$(DOCKER_OR_PODMAN) push $(IMAGE)
