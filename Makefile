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

.PHONY: changelog
changelog: git-chglog ## Generate CHANGELOG.md; NEXT_RELEASE_TAG=X.Y.Z puts unreleased commits under vX.Y.Z.
ifneq ($(NEXT_RELEASE_TAG),)
	"$(GITCHGLOG)" --next-tag v$(NEXT_RELEASE_TAG) -o CHANGELOG.md
else
	"$(GITCHGLOG)" -o CHANGELOG.md
endif

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
e2e-kind-cluster-create: kind ## Create the kind cluster krci-substrate and set proxy ARP on its nodes (needs Docker).
	KIND="$(KIND)" $(E2E_KIND) cluster-create

.PHONY: e2e-kind-cluster-delete
e2e-kind-cluster-delete: kind ## Delete the kind cluster krci-substrate (needs Docker).
	KIND="$(KIND)" $(E2E_KIND) cluster-delete

.PHONY: e2e-kind-install
e2e-kind-install: ## Install cert-manager, ESO, the chart and RustFS on kind-krci-substrate.
	$(E2E_KIND) install

.PHONY: e2e-kind-smoke
e2e-kind-smoke: chainsaw kubectl-ate ## Run the Chainsaw smoke tests (e2e/chainsaw) on kind-krci-substrate.
	CHAINSAW="$(CHAINSAW)" $(E2E_KIND) smoke

.PHONY: e2e-kind
e2e-kind: e2e-kind-install e2e-kind-smoke ## Install on kind-krci-substrate, then run the smoke checks.

LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p "$(LOCALBIN)"

HELMDOCS_VERSION ?= v1.14.2
# Same version as the operator repos.
GITCHGLOG_VERSION ?= v0.15.4
# Same version as the operator repos.
CHAINSAW_VERSION ?= v0.2.15
# Supports the node image of e2e/kind/cluster.yaml.
KIND_VERSION ?= v0.33.0
HELMDOCS := $(LOCALBIN)/helm-docs
GITCHGLOG := $(LOCALBIN)/git-chglog
# CHAINSAW=<path>, KIND=<path>: use that binary, install nothing.
CHAINSAW ?= $(LOCALBIN)/chainsaw
KIND ?= $(LOCALBIN)/kind

.PHONY: helmdocs
helmdocs: $(LOCALBIN) ## Install helm-docs into bin/ if necessary.
	$(call go-install-tool,$(HELMDOCS),github.com/norwoodj/helm-docs/cmd/helm-docs,$(HELMDOCS_VERSION))

.PHONY: git-chglog
git-chglog: $(LOCALBIN) ## Install git-chglog into bin/ if necessary.
	$(call go-install-tool,$(GITCHGLOG),github.com/git-chglog/git-chglog/cmd/git-chglog,$(GITCHGLOG_VERSION))

.PHONY: chainsaw
chainsaw: $(LOCALBIN) ## Install chainsaw into bin/ if necessary.
ifeq ($(CHAINSAW),$(LOCALBIN)/chainsaw)
	$(call go-install-tool,$(CHAINSAW),github.com/kyverno/chainsaw,$(CHAINSAW_VERSION))
endif

.PHONY: kind
kind: $(LOCALBIN) ## Install kind into bin/ if necessary.
ifeq ($(KIND),$(LOCALBIN)/kind)
	$(call go-install-tool,$(KIND),sigs.k8s.io/kind,$(KIND_VERSION))
endif

.PHONY: kubectl-ate
kubectl-ate: ## Install kubectl-ate into .cache/bin/ if necessary.
	$(E2E_KIND) kubectl-ate

TOOL_VERSION_helmdocs = $(HELMDOCS_VERSION)
TOOL_VERSION_git-chglog = $(GITCHGLOG_VERSION)
TOOL_VERSION_chainsaw = $(CHAINSAW_VERSION)
TOOL_VERSION_kind = $(KIND_VERSION)
TOOL_VERSION_kubectl-ate = $(shell $(E2E_KIND) kubectl-ate-version)

.PHONY: tools-key
tools-key: ## Print <tool>-<version> of each tool target in TOOLS, joined by '-' (CI cache key).
	@echo $(foreach tool,$(or $(TOOLS),$(error TOOLS is required)),$(tool)-$(or $(TOOL_VERSION_$(tool)),$(error no version for tool $(tool)))) | tr ' ' '-'

# go-install-tool <binary path> <package> <version>: installs as <binary>-<version> when absent, links <binary> to it.
define go-install-tool
@[ -f "$(1)-$(3)" ] || { \
set -e; \
package=$(2)@$(3) ;\
echo "Downloading $${package}" ;\
rm -f "$(1)" ;\
GOBIN="$(LOCALBIN)" go install $${package} ;\
mv "$(LOCALBIN)/$$(basename "$(1)")" "$(1)-$(3)" ;\
} ;\
ln -sf "$$(realpath "$(1)-$(3)")" "$(1)"
endef
