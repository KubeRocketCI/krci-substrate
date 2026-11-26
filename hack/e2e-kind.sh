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
# Atespace and namespace of the smoke workload (e2e/kind/smoke-*.yaml); kept between runs.
readonly SMOKE_ATESPACE="krci-substrate-smoke"
# Smoke actor: deleted and created again on every run.
readonly SMOKE_ACTOR="smoke-1"
# Local port of kubectl ate proxy actor to actor port 80.
readonly SMOKE_PROXY_PORT="18000"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIND_DIR="${ROOT}/e2e/kind"
CHART_DIR="${ROOT}/deploy-templates"
CLUSTER="krci-substrate"
CONTEXT="kind-krci-substrate"
KUBECONFIG_FILE="${ROOT}/.cache/kind-krci-substrate.kubeconfig"
KUBECTL_ATE="${ROOT}/.cache/bin/kubectl-ate-${KUBECTL_ATE_VERSION}"
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
sandboxconfig_class_default() {
  [ "$(k get sandboxconfig "$1" -o jsonpath='{.metadata.annotations.sandboxconfig\.ate\.dev/is-class-default}')" = "true" ]
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

# poll <seconds> <command...>: runs command every 5s until it succeeds; fails after <seconds>.
poll() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    [ "${SECONDS}" -lt "${deadline}" ] || return 1
    sleep 5
  done
}

workerpool_ready() {
  k apply -f "${KIND_DIR}/smoke-workerpool.yaml"
  k --namespace "${SMOKE_ATESPACE}" wait --for=jsonpath='{.status.readyReplicas}'=2 workerpool/smoke --timeout 5m
}

# golden_tag: prints the golden tag name of the smoke template; fails while there is none, exits on a golden error.
golden_tag() {
  local status
  status="$(ate get actor-template smoke -a "${SMOKE_ATESPACE}" -o json | jq -c '.status.goldenSnapshotStatus // {}')"
  if jq -e '.errorMessage // "" | length > 0' <<<"${status}" >/dev/null; then
    echo "golden snapshot failed: ${status}"
    exit 1
  fi
  jq -e -r '.goldenTag.name // empty' <<<"${status}"
}
# The first golden snapshot on a node also downloads the gVisor release.
actor_template_golden() {
  ate get actor-template smoke -a "${SMOKE_ATESPACE}" >/dev/null 2>&1 \
    || ate create actor-template -f "${KIND_DIR}/smoke-actor-template.yaml"
  poll 600 golden_tag
}

actor_json() { ate get actor "${SMOKE_ACTOR}" -a "${SMOKE_ATESPACE}" -o json; }
actor_state_is() { [ "$(actor_json | jq -r '.status.state')" = "$1" ]; }
# snapshot_completed <owner>: the actor holds a snapshot of <owner> (SNAPSHOT_OWNER_TAG, SNAPSHOT_OWNER_ACTOR),
# stored in the S3 fixture bucket; prints its URI.
snapshot_completed() {
  actor_json | jq -e -r --arg owner "$1" '.status.snapshots[]
    | select(.owner == $owner and .durableSnapshot.state == "SNAPSHOT_STORAGE_STATE_COMPLETED")
    | .durableSnapshot.object.snapshotUri | select(startswith("s3://ate-snapshots/"))'
}

# s3_object_count <s3 uri>: number of objects below the URI in the RustFS fixture, listed by a one-off aws-cli pod.
s3_object_count() {
  local image overrides
  image="$(k --namespace ate-system get job rustfs-bucket-init -o jsonpath='{.spec.template.spec.containers[0].image}')"
  overrides="$(jq -cn --arg image "${image}" --arg uri "${1%/}/" '{spec: {containers: [{
    name: "rustfs-smoke-client", image: $image, args: ["s3", "ls", "--recursive", $uri],
    envFrom: [{secretRef: {name: "rustfs-credentials"}}],
    env: [{name: "AWS_REGION", value: "us-east-1"}, {name: "AWS_ENDPOINT_URL", value: "http://rustfs.ate-system.svc:9000"}]}]}}')"
  k --namespace ate-system run rustfs-smoke-client --rm --attach --quiet --restart=Never \
    --labels app=rustfs-smoke-client --image "${image}" --overrides "${overrides}" | grep -c .
}

actor_exists() { ate get actor "${SMOKE_ACTOR}" -a "${SMOKE_ATESPACE}" >/dev/null 2>&1; }
actor_absent() { ! actor_exists; }

actor_created_from_golden() {
  if actor_exists; then
    ate delete actor "${SMOKE_ACTOR}" -a "${SMOKE_ATESPACE}"
    poll 120 actor_absent
  fi
  ate create actor "${SMOKE_ACTOR}" -a "${SMOKE_ATESPACE}" --template smoke
  poll 60 actor_state_is ACTOR_STATE_SUSPENDED
  snapshot_completed SNAPSHOT_OWNER_TAG
}

actor_resumed() {
  ate resume actor "${SMOKE_ACTOR}" -a "${SMOKE_ATESPACE}"
  actor_state_is ACTOR_STATE_RUNNING
}

actor_suspended_to_s3() {
  local uri count
  ate suspend actor "${SMOKE_ACTOR}" -a "${SMOKE_ATESPACE}" --mode=sync
  actor_state_is ACTOR_STATE_SUSPENDED
  uri="$(snapshot_completed SNAPSHOT_OWNER_ACTOR)"
  count="$(s3_object_count "${uri}")"
  echo "${uri}: ${count} objects"
  [ "${count}" -gt 0 ]
}

# kubectl ate proxy actor authenticates to atenet-router as atenet-client (router.ingressAllowedSpiffeIds).
# traefik/whoami answers with its hostname.
http_through_router() {
  local proxy body=""
  # The binary itself, not the ate function: kill must reach the process. Output to a file: a background
  # process on the check output pipe keeps check waiting.
  "${KUBECTL_ATE}" --kubeconfig "${KUBECONFIG_FILE}" --context "${CONTEXT}" \
    proxy actor "${SMOKE_ACTOR}" "${SMOKE_PROXY_PORT}:80" -a "${SMOKE_ATESPACE}" >"${ROOT}/.cache/smoke-proxy.log" 2>&1 &
  proxy=$!
  if poll 60 curl -fsS -o /dev/null --max-time 10 --noproxy 127.0.0.1 "http://127.0.0.1:${SMOKE_PROXY_PORT}/"; then
    body="$(curl -fsS --max-time 10 --noproxy 127.0.0.1 "http://127.0.0.1:${SMOKE_PROXY_PORT}/")" || true
  fi
  kill "${proxy}" 2>/dev/null || true
  wait "${proxy}" 2>/dev/null || true
  echo "${body:-no response; proxy log:}"
  [ -n "${body}" ] || cat "${ROOT}/.cache/smoke-proxy.log"
  grep -q '^Hostname: ' <<<"${body}"
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
  check "sandboxconfig gvisor-default is the gvisor class default" sandboxconfig_class_default gvisor-default
  check "daemonset atelet ready" k --namespace ate-system rollout status daemonset/atelet --timeout 5m
  check "postgres: no role has a password" postgres_no_passwords
  check "postgres: ate-api-server certificate logins" postgres_certificate_logins
  check "kubectl ate ${KUBECTL_ATE_VERSION}" kubectl_ate_install
  check "kubectl ate: atespace ${SMOKE_ATESPACE} created and listed" atespace_created_and_listed
  check "workerpool ${SMOKE_ATESPACE}/smoke ready" workerpool_ready
  check "actor template smoke: golden snapshot" actor_template_golden
  check "actor ${SMOKE_ACTOR}: created suspended from the golden snapshot in S3" actor_created_from_golden
  check "actor ${SMOKE_ACTOR}: resumed" actor_resumed
  check "actor ${SMOKE_ACTOR}: suspended, snapshot in the S3 fixture" actor_suspended_to_s3
  check "actor ${SMOKE_ACTOR}: resumed from its snapshot" actor_resumed
  check "actor ${SMOKE_ACTOR}: HTTP request through atenet-router" http_through_router
}

case "${1:-}" in
  cluster-create) cluster_create ;;
  cluster-delete) cluster_delete ;;
  install) install_all ;;
  smoke) smoke ;;
  *) echo "Usage: $0 cluster-create|cluster-delete|install|smoke" >&2; exit 2 ;;
esac
