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
helm-lint: ## Run helm lint and render the chart.
	helm lint $(CHART_DIR)
	helm template krci-substrate $(CHART_DIR) --include-crds >/dev/null

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

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p "$(LOCALBIN)"

## Tool Binaries
HELMDOCS ?= $(LOCALBIN)/helm-docs

## Tool Versions
HELMDOCS_VERSION ?= v1.14.2

.PHONY: helmdocs
helmdocs: $(HELMDOCS) ## Download helm-docs locally if necessary.
$(HELMDOCS): $(LOCALBIN)
	$(call go-install-tool,$(HELMDOCS),github.com/norwoodj/helm-docs/cmd/helm-docs,$(HELMDOCS_VERSION))

# go-install-tool installs a Go package as <binary>-<version> and links <binary> to it.
# $1 - target path with name of binary
# $2 - package url which can be installed
# $3 - specific version of package
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
