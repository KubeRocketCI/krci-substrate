CHART_DIR := deploy-templates

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-25s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: helm-docs
helm-docs: helmdocs ## Generate deploy-templates/README.md from README.md.gotmpl.
	"$(HELMDOCS)" --chart-search-root $(CHART_DIR)

.PHONY: validate-docs
validate-docs: helm-docs ## Fail if the generated chart docs are out of date.
	@git diff -s --exit-code $(CHART_DIR)/README.md || (echo "Run 'make helm-docs' to address the issue." && git diff && exit 1)

.PHONY: helm-lint
helm-lint: ## Run helm lint and render the chart with each values file in deploy-templates/ci/.
	@set -e; for values in $(CHART_DIR)/ci/*-values.yaml; do \
		echo "$$values"; \
		helm lint $(CHART_DIR) --values "$$values"; \
		helm template krci-substrate $(CHART_DIR) --include-crds --values "$$values" >/dev/null; \
	done

.PHONY: ct-lint
ct-lint: ## Run chart-testing lint against the main branch (needs ct, yamllint, yamale).
	ct lint --target-branch main --charts $(CHART_DIR)/ \
		--config ct-configs/ct.yaml --lint-conf ct-configs/lintconf.yaml

E2E_KIND := bash hack/e2e-kind.sh

.PHONY: e2e-kind-cluster-create
e2e-kind-cluster-create: ## Create the kind cluster krci-substrate and set proxy ARP on its nodes (needs kind and Docker).
	$(E2E_KIND) cluster-create

.PHONY: e2e-kind-cluster-delete
e2e-kind-cluster-delete: ## Delete the kind cluster krci-substrate (needs kind and Docker).
	$(E2E_KIND) cluster-delete

.PHONY: e2e-kind-install
e2e-kind-install: ## Install cert-manager, ESO, the chart and RustFS on kind-krci-substrate.
	$(E2E_KIND) install

.PHONY: e2e-kind-smoke
e2e-kind-smoke: ## Run the smoke checks on kind-krci-substrate.
	$(E2E_KIND) smoke

.PHONY: e2e-kind
e2e-kind: e2e-kind-install e2e-kind-smoke ## Install on kind-krci-substrate, then run the smoke checks.

LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p "$(LOCALBIN)"

HELMDOCS ?= $(LOCALBIN)/helm-docs
HELMDOCS_VERSION ?= v1.14.2

.PHONY: helmdocs
helmdocs: $(HELMDOCS) ## Download helm-docs locally if necessary.
$(HELMDOCS): $(LOCALBIN)
	$(call go-install-tool,$(HELMDOCS),github.com/norwoodj/helm-docs/cmd/helm-docs,$(HELMDOCS_VERSION))

# go-install-tool <binary path> <package> <version>: installs as <binary>-<version>, links <binary> to it.
define go-install-tool
@[ -f "$(1)-$(3)" ] && [ "$$(readlink -- "$(1)" 2>/dev/null)" = "$(1)-$(3)" ] || { \
set -e; \
package=$(2)@$(3) ;\
echo "Downloading $${package}" ;\
rm -f "$(1)" ;\
GOBIN="$(LOCALBIN)" go install $${package} ;\
mv "$(LOCALBIN)/$$(basename "$(1)")" "$(1)-$(3)" ;\
} ;\
ln -sf "$$(realpath "$(1)-$(3)")" "$(1)"
endef
