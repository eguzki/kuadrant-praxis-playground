SHELL := /usr/bin/env bash
SCRIPTS := ./scripts

.PHONY: help setup cluster deps kuadrant upstream istio-gateway praxis-image praxis test cleanup

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

setup: ## Full setup (cluster -> istio -> kuadrant -> upstream -> gateways -> praxis)
	$(SCRIPTS)/setup.sh

cluster: ## Create the kind cluster
	$(SCRIPTS)/00-create-cluster.sh

deps: ## Install Gateway API, cert-manager, Istio (helm)
	$(SCRIPTS)/01-install-istio.sh

kuadrant: ## Install Kuadrant operator + CR (helm)
	$(SCRIPTS)/02-install-kuadrant.sh

upstream: ## Deploy shared upstream (inference-sim + mockserver)
	$(SCRIPTS)/03-deploy-upstream.sh

istio-gateway: ## Deploy the Istio-managed gateway + HTTPRoute
	$(SCRIPTS)/04-deploy-istio-gateway.sh

praxis-image: ## Build Praxis AI image from source (token-rate-limit-filter) + load into kind
	$(SCRIPTS)/05-build-praxis-image.sh

praxis: ## Deploy the Praxis AI gateway
	$(SCRIPTS)/06-deploy-praxis.sh

test: ## Run the token rate limit test (needs port-forward praxis)
	./test/test-token-rate-limit.sh

cleanup: ## Delete the kind cluster
	$(SCRIPTS)/cleanup.sh
