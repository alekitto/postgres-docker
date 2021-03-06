SHELL=/bin/bash -o pipefail

REGISTRY ?= kubedb
BIN      ?= postgres
IMAGE    := $(REGISTRY)/$(BIN)
TAG      := $(shell git describe --tags --exact-match --abbrev=0 2>/dev/null || echo "")

.PHONY: push
push: container
	docker push $(IMAGE):$(TAG)

.PHONY: container
container:
	docker build -t $(IMAGE):$(TAG) .

.PHONY: version
version:
	@echo ::set-output name=version::$(TAG)
