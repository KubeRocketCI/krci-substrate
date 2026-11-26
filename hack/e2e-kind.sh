#!/usr/bin/env bash
# Kind test bed: cluster krci-substrate, context kind-krci-substrate, kubeconfig .cache/kind-krci-substrate.kubeconfig.
#   cluster-create, cluster-delete  need kind and Docker.
#   install, smoke                  need kubectl, helm and jq; no Docker.
# Every command is idempotent. No other kubeconfig or cluster is used.
# HELM_CA_FILE: optional CA bundle for the chart registries (helm --ca-file).
set -euo pipefail

# Dependency charts and versions.
readonly CERT_MANAGER_VERSION="v1.21.2"
readonly EXTERNAL_SECRETS_VERSION="2.14.0"
readonly CERT_MANAGER_CHART="oci://quay.io/jetstack/charts/cert-manager"
readonly EXTERNAL_SECRETS_CHART="oci://ghcr.io/external-secrets/charts/external-secrets"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIND_DIR="${ROOT}/e2e/kind"
CHART_DIR="${ROOT}/deploy-templates"
CLUSTER="krci-substrate"
CONTEXT="kind-krci-substrate"
KUBECONFIG_FILE="${ROOT}/.cache/kind-krci-substrate.kubeconfig"

k() { kubectl --kubeconfig "${KUBECONFIG_FILE}" --context "${CONTEXT}" "$@"; }
h() { helm --kubeconfig "${KUBECONFIG_FILE}" --kube-context "${CONTEXT}" "$@"; }

cluster_create() {
  mkdir -p "${ROOT}/.cache"
  if grep -qx "${CLUSTER}" <<<"$(kind get clusters)"; then
    kind export kubeconfig --name "${CLUSTER}" --kubeconfig "${KUBECONFIG_FILE}"
  else
    kind create cluster --config "${KIND_DIR}/cluster.yaml" --kubeconfig "${KUBECONFIG_FILE}"
  fi
  # Proxy ARP for gVisor loopback pod-to-pod networking (upstream hack/create-kind-cluster.sh).
  # Runtime sysctl: re-run after a Docker restart.
  for node in $(kind get nodes --name "${CLUSTER}"); do
    docker exec "${node}" sysctl -w net.ipv4.conf.all.proxy_arp=1
  done
}

cluster_delete() {
  kind delete cluster --name "${CLUSTER}" --kubeconfig "${KUBECONFIG_FILE}"
  rm -f "${KUBECONFIG_FILE}"
}

# helm_upgrade <release> <namespace> <chart> <values-file> [--version <v>]
helm_upgrade() {
  local release="$1" namespace="$2" chart="$3" values="$4"
  shift 4
  local ca=()
  [ -z "${HELM_CA_FILE:-}" ] || ca=(--ca-file "${HELM_CA_FILE}")
  h upgrade --install "${release}" "${chart}" --namespace "${namespace}" --create-namespace \
    --values "${values}" --wait --timeout 10m ${ca[@]+"${ca[@]}"} "$@"
}

# install_dependency <release> <chart> <version>: release <release> in namespace <release>, values
# e2e/kind/<release>-values.yaml. Skipped when deployed at <version>: a values edit needs a version
# change or a new cluster.
install_dependency() {
  local release="$1" chart="$2" version="$3"
  if h list --namespace "${release}" --deployed -o json \
    | jq -e --arg c "${release}-${version}" 'any(.[]; .chart == $c)' >/dev/null; then
    echo "${release} ${version}: unchanged"
    return
  fi
  helm_upgrade "${release}" "${release}" "${chart}" "${KIND_DIR}/${release}-values.yaml" --version "${version}"
}

# The chart under test: release default/krci-substrate; skipped when its manifest equals the render.
# Helm installs crds/ on first install only: a CRD change needs a new cluster.
install_chart() {
  if [ "$(h get manifest krci-substrate --namespace default 2>/dev/null)" = \
    "$(h template krci-substrate "${CHART_DIR}" --namespace default --values "${KIND_DIR}/values.yaml")" ]; then
    echo "krci-substrate: unchanged"
    return
  fi
  helm_upgrade krci-substrate default "${CHART_DIR}" "${KIND_DIR}/values.yaml"
}

install_all() {
  install_dependency cert-manager "${CERT_MANAGER_CHART}" "${CERT_MANAGER_VERSION}"
  install_dependency external-secrets "${EXTERNAL_SECRETS_CHART}" "${EXTERNAL_SECRETS_VERSION}"

  install_chart

  # After the chart: rustfs.yaml goes into ate-system, which the chart creates.
  k apply -f "${KIND_DIR}/rustfs.yaml"
  k --namespace ate-system rollout status deployment/rustfs --timeout 5m
  k --namespace ate-system wait --for=condition=complete job/rustfs-bucket-init --timeout 5m
}

# check <name> <command...>: prints "ok <name>", or "FAIL <name>" with the command output and exits 1.
check() {
  local name="$1" out
  shift
  if ! out="$( ("$@") 2>&1)"; then
    echo "FAIL ${name}" >&2
    [ -z "${out}" ] || echo "${out}" >&2
    exit 1
  fi
  echo "ok   ${name}"
}

namespace_active() { [ "$(k get namespace "$1" -o jsonpath='{.status.phase}')" = "Active" ]; }
crd_established() {
  [ "$(k get crd "$1" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}')" = "True" ]
}

smoke() {
  check "cluster ${CONTEXT} reachable" k version --request-timeout=10s
  check "namespace ate-system" namespace_active ate-system
  check "namespace podcertificate-controller-system" namespace_active podcertificate-controller-system
  check "crd workerpools.ate.dev" crd_established workerpools.ate.dev
  check "crd sandboxconfigs.ate.dev" crd_established sandboxconfigs.ate.dev
  check "crd csidriverconfigs.ate.dev" crd_established csidriverconfigs.ate.dev
}

case "${1:-}" in
  cluster-create) cluster_create ;;
  cluster-delete) cluster_delete ;;
  install) install_all ;;
  smoke) smoke ;;
  *) echo "Usage: $0 cluster-create|cluster-delete|install|smoke" >&2; exit 2 ;;
esac
