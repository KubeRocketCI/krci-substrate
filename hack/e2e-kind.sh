#!/usr/bin/env bash
# Kind test bed: cluster krci-substrate, context kind-krci-substrate, kubeconfig .cache/kind-krci-substrate.kubeconfig.
#   cluster-create, cluster-delete  need kind and Docker.
#   install                         needs kubectl, helm and jq; no Docker.
#   smoke                           needs kubectl, jq and curl (first run downloads kubectl-ate); no Docker.
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
# Atespace the smoke creates and lists; kept between runs.
readonly SMOKE_ATESPACE="krci-substrate-smoke"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIND_DIR="${ROOT}/e2e/kind"
CHART_DIR="${ROOT}/deploy-templates"
CLUSTER="krci-substrate"
CONTEXT="kind-krci-substrate"
KUBECONFIG_FILE="${ROOT}/.cache/kind-krci-substrate.kubeconfig"
KUBECTL_ATE="${ROOT}/.cache/bin/kubectl-ate-${KUBECTL_ATE_VERSION}"
# Chart Deployments in ate-system, besides StatefulSet postgres.
readonly CONTROL_PLANE_DEPLOYMENTS=(ate-api-server ate-idp-server ate-controller)

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
  local deployment
  for deployment in "${CONTROL_PLANE_DEPLOYMENTS[@]}"; do
    k --namespace ate-system rollout status "deployment/${deployment}" --timeout 5m
  done
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
secret_exists() { k --namespace "$1" wait --for=create secret "$2" --timeout 2m; }
trust_bundle_published() {
  k wait --for=create clustertrustbundle "$1" --timeout 2m >/dev/null
  k get clustertrustbundle "$1" -o jsonpath='{.spec.trustBundle}' | grep -q -- '-----BEGIN CERTIFICATE-----'
}

# pg <sql>: runs sql as the local postgres superuser in postgres-0 (socket, trust); prints unaligned tuples.
pg() { k --namespace ate-system exec postgres-0 -c postgres -- psql -U postgres -d atepg -Atc "$1"; }
postgres_no_passwords() { [ "$(pg 'SELECT count(*) FROM pg_authid WHERE rolpassword IS NOT NULL')" = "0" ]; }
# Both logins of ate-api-server hold TLS sessions with a client certificate (pg_hba.conf: cert only).
postgres_certificate_logins() {
  local users
  users="$(pg "SELECT DISTINCT a.usename FROM pg_stat_activity a JOIN pg_stat_ssl s USING (pid)
    WHERE s.ssl AND s.client_dn IS NOT NULL ORDER BY 1")"
  echo "${users}"
  [ "${users}" = "$(printf 'substrate_owner_user\nsubstrate_readwrite_user')" ]
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

# kubectl ate port-forwards to Service ate-system/api and mints an ate-client token (bootstrap owner).
ate() { "${KUBECTL_ATE}" --kubeconfig "${KUBECONFIG_FILE}" --context "${CONTEXT}" "$@"; }
atespace_created_and_listed() {
  ate get atespace "${SMOKE_ATESPACE}" >/dev/null 2>&1 || ate create atespace "${SMOKE_ATESPACE}"
  ate get atespaces -o json | jq -e --arg n "${SMOKE_ATESPACE}" 'tostring | contains($n)' >/dev/null
}

smoke() {
  check "cluster ${CONTEXT} reachable" k version --request-timeout=10s
  check "namespace ate-system" namespace_active ate-system
  check "namespace podcertificate-controller-system" namespace_active podcertificate-controller-system
  check "crd workerpools.ate.dev" crd_established workerpools.ate.dev
  check "crd sandboxconfigs.ate.dev" crd_established sandboxconfigs.ate.dev
  check "crd csidriverconfigs.ate.dev" crd_established csidriverconfigs.ate.dev

  local secret
  for secret in service-dns-ca-pool pod-identity-ca-pool postgres-ca-pool; do
    check "secret podcertificate-controller-system/${secret}" secret_exists podcertificate-controller-system "${secret}"
  done
  for secret in actor-id-ca-pool actor-id-ca-certs actor-id-jwt-pool egress-mitm-ca-pool; do
    check "secret ate-system/${secret}" secret_exists ate-system "${secret}"
  done
  check "deployment podcertificate-controller available" \
    k --namespace podcertificate-controller-system wait --for=condition=Available deployment/podcertificate-controller --timeout 5m

  local bundle
  for bundle in servicedns podidentity postgres; do
    check "clustertrustbundle ${bundle}.podcert.ate.dev:identity:primary-bundle" \
      trust_bundle_published "${bundle}.podcert.ate.dev:identity:primary-bundle"
  done

  check "statefulset postgres ready" k --namespace ate-system rollout status statefulset/postgres --timeout 5m
  local deployment
  for deployment in "${CONTROL_PLANE_DEPLOYMENTS[@]}"; do
    check "deployment ${deployment} available" \
      k --namespace ate-system wait --for=condition=Available "deployment/${deployment}" --timeout 5m
  done
  check "postgres: no role has a password" postgres_no_passwords
  check "postgres: ate-api-server certificate logins" postgres_certificate_logins
  check "kubectl ate ${KUBECTL_ATE_VERSION}" kubectl_ate_install
  check "kubectl ate: atespace ${SMOKE_ATESPACE} created and listed" atespace_created_and_listed
}

case "${1:-}" in
  cluster-create) cluster_create ;;
  cluster-delete) cluster_delete ;;
  install) install_all ;;
  smoke) smoke ;;
  *) echo "Usage: $0 cluster-create|cluster-delete|install|smoke" >&2; exit 2 ;;
esac
