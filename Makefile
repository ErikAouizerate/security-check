LOCAL_IMAGE  ?= security-check:local
GHCR_IMAGE   ?= ghcr.io/erikaouizerate/security-check:latest
IMAGE        ?= $(LOCAL_IMAGE)
REPORTS_DIR  ?= security-reports
CACHE_DIR    ?= $(HOME)/.cache/security-audit

DOCKER_RUN = docker run --rm \
	-u "$$(id -u):$$(id -g)" \
	-v "$(CURDIR):/workspace" \
	-v "$(CACHE_DIR):/cache" \
	-w /workspace \
	$(IMAGE)

.PHONY: help build pull audit secrets sast iac sca clean

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  %-10s %s\n", $$1, $$2}'

$(CACHE_DIR):
	@mkdir -p $@

build: ## Build the image locally (amd64)
	docker buildx build --load -t $(LOCAL_IMAGE) -f Dockerfile.security .

pull: ## Pull the pinned image from GHCR
	docker pull $(GHCR_IMAGE)

audit: $(CACHE_DIR) ## Run the full audit
	$(DOCKER_RUN) audit all

secrets: $(CACHE_DIR) ## Run secret scanning (Gitleaks)
	$(DOCKER_RUN) audit secrets

sast: $(CACHE_DIR) ## Run static analysis (OpenGrep)
	$(DOCKER_RUN) audit sast

iac: $(CACHE_DIR) ## Run IaC scanning (Checkov + trivy config)
	$(DOCKER_RUN) audit iac

sca: $(CACHE_DIR) ## Run dependency scanning (OSV-Scanner + trivy fs)
	$(DOCKER_RUN) audit sca

clean: ## Remove reports and the local image
	rm -rf $(REPORTS_DIR)
	-docker rmi $(LOCAL_IMAGE)
