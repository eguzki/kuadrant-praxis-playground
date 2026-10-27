SHELL := /usr/bin/env bash
SCRIPTS := ./scripts

.PHONY: help setup cluster deps kuadrant upstream jwt-issuer istio-gateway praxis-image praxis praxis-p1 praxis-p2 test cleanup

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

jwt-issuer: ## Deploy the static-JWKS JWT test issuer + mint test tokens
	$(SCRIPTS)/deploy-jwt-issuer.sh

istio-gateway: ## Deploy the Istio-managed gateway + HTTPRoute
	$(SCRIPTS)/04-deploy-istio-gateway.sh

praxis-image: ## Build Praxis AI image from source (token-rate-limit-filter) + load into kind
	$(SCRIPTS)/05-build-praxis-image.sh

praxis: praxis-p1 praxis-p2 ## Deploy all base-image Praxis gateways (P1 + P2)

praxis-p1: ## Deploy offering P1 (rate_limit) -> ns praxis-p1, port 8081
	$(SCRIPTS)/06-deploy-praxis-p1.sh

praxis-p2: ## Deploy offering P2 (token_rate_limit) -> ns praxis-p2, port 8082
	$(SCRIPTS)/06-deploy-praxis-p2.sh

test: ## Run the token rate limit test (needs port-forward praxis)
	./test/test-token-rate-limit.sh

cleanup: ## Delete the kind cluster
	$(SCRIPTS)/cleanup.sh
