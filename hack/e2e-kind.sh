#!/usr/bin/env bash
# Kind test bed: cluster krci-substrate, context kind-krci-substrate, kubeconfig .cache/kind-krci-substrate.kubeconfig.
#   cluster-create, cluster-delete  need kind and Docker.
#   install                         needs kubectl, helm and jq; no Docker.
#   smoke                           needs kubectl, jq, curl and chainsaw (first run downloads kubectl-ate); no Docker.
#                                   make e2e-kind-smoke installs chainsaw with Go, or passes CHAINSAW=<path>.
# Every command is idempotent. No other kubeconfig or cluster is used.
# HELM_CA_FILE: optional CA bundle for the chart registries (helm --ca-file).
set -euo pipefail

readonly CERT_MANAGER_VERSION="v1.21.2"
readonly EXTERNAL_SECRETS_VERSION="2.14.0"
readonly CERT_MANAGER_CHART="oci://quay.io/jetstack/charts/cert-manager"
readonly EXTERNAL_SECRETS_CHART="oci://ghcr.io/external-secrets/charts/external-secrets"
# kubectl-ate release binary; keep at the chart appVersion.
readonly KUBECTL_ATE_VERSION="v1.0.1"
readonly KUBECTL_ATE_RELEASES="https://github.com/agent-substrate/substrate/releases/download"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIND_DIR="${ROOT}/e2e/kind"
CHART_DIR="${ROOT}/deploy-templates"
CLUSTER="krci-substrate"
CONTEXT="kind-krci-substrate"
KUBECONFIG_FILE="${ROOT}/.cache/kind-krci-substrate.kubeconfig"
KUBECTL_ATE="${ROOT}/.cache/bin/kubectl-ate-${KUBECTL_ATE_VERSION}"
# chainsaw binary; make e2e-kind-smoke passes bin/chainsaw.
CHAINSAW="${CHAINSAW:-${ROOT}/bin/chainsaw}"
# Chart Deployments in ate-system, besides StatefulSet postgres and DaemonSet atelet.
readonly CONTROL_PLANE_DEPLOYMENTS=(ate-api-server ate-idp-server ate-controller
  k8s-credential-provider atenet-router atenet-egress)

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

# helm_upgrade <release> <namespace> <chart> <values-file> [helm flags: --wait, --version <v>]
helm_upgrade() {
  local release="$1" namespace="$2" chart="$3" values="$4"
  shift 4
  local ca=()
  [ -z "${HELM_CA_FILE:-}" ] || ca=(--ca-file "${HELM_CA_FILE}")
  h upgrade --install "${release}" "${chart}" --namespace "${namespace}" --create-namespace \
    --values "${values}" --timeout 10m ${ca[@]+"${ca[@]}"} "$@"
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
  helm_upgrade "${release}" "${release}" "${chart}" "${KIND_DIR}/${release}-values.yaml" --wait --version "${version}"
}

# The chart under test: release default/krci-substrate; skipped when its manifest equals the render.
# Helm installs crds/ on first install only: a CRD change needs a new cluster.
# No helm --wait: ate-api-server starts only after rustfs.yaml adds Secret rustfs-credentials.
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

  k --namespace podcertificate-controller-system rollout status deployment/podcertificate-controller --timeout 5m
  k --namespace ate-system rollout status statefulset/postgres --timeout 5m
  k --namespace ate-system rollout status daemonset/atelet --timeout 5m
  local deployment
  for deployment in "${CONTROL_PLANE_DEPLOYMENTS[@]}"; do
    k --namespace ate-system rollout status "deployment/${deployment}" --timeout 5m
  done
}

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

kubectl_ate_install() {
  [ ! -x "${KUBECTL_ATE}" ] || return 0
  local os arch asset want
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in
    x86_64 | amd64) arch=amd64 ;;
    arm64 | aarch64) arch=arm64 ;;
    *) echo "unsupported CPU $(uname -m)"; return 1 ;;
  esac
  asset="${KUBECTL_ATE_RELEASES}/${KUBECTL_ATE_VERSION}/kubectl-ate-${os}-${arch}"
  mkdir -p "${ROOT}/.cache/bin"
  curl -fsSL -o "${KUBECTL_ATE}.download" "${asset}"
  want="$(curl -fsSL "${asset}.sha256" | cut -d' ' -f1)"
  if [ "$(sha256 "${KUBECTL_ATE}.download")" != "${want}" ]; then
    rm -f "${KUBECTL_ATE}.download"
    echo "sha256 mismatch for ${asset}"
    return 1
  fi
  chmod +x "${KUBECTL_ATE}.download"
  mv "${KUBECTL_ATE}.download" "${KUBECTL_ATE}"
}

# Chainsaw tests of e2e/chainsaw against the installed chart. kubectl ate: kubectl plugin from .cache/bin.
# JUnit report: .cache/chainsaw-smoke.xml.
smoke() {
  kubectl_ate_install
  ln -sf "${KUBECTL_ATE}" "${ROOT}/.cache/bin/kubectl-ate"
  KUBECONFIG="${KUBECONFIG_FILE}" PATH="${ROOT}/.cache/bin:${PATH}" "${CHAINSAW}" test \
    --config "${ROOT}/e2e/chainsaw/.chainsaw.yaml" --kube-context "${CONTEXT}" \
    --report-format JUNIT-TEST --report-path "${ROOT}/.cache" --report-name chainsaw-smoke \
    "${ROOT}/e2e/chainsaw"
}

case "${1:-}" in
  cluster-create) cluster_create ;;
  cluster-delete) cluster_delete ;;
  install) install_all ;;
  smoke) smoke ;;
  *) echo "Usage: $0 cluster-create|cluster-delete|install|smoke" >&2; exit 2 ;;
esac
