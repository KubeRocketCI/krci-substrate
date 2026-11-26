# ADR-0002: PostgreSQL setup SQL at database init

Status: accepted

## Context

The bundled PostgreSQL needs the Substrate roles, logins and schema before ate-api-server starts. Upstream `ate-setup` waits for the StatefulSet rollout, then runs `pkg/postgressetup/setup.sql` through `kubectl exec` as the local superuser, on every deploy. The SQL is idempotent.

A Helm chart under GitOps cannot exec into a pod.

## Decision

ConfigMap `postgres-setup` holds a script that runs the upstream setup SQL with the variables of `postgressetup.DefaultConfig()` in one transaction. The StatefulSet mounts it at `/docker-entrypoint-initdb.d`. The image entrypoint runs it once, against its socket-only init server, when the data directory is empty.

`files/postgres/setup.sql` is the upstream file, byte for byte.

## Rejected

- Helm hook Job that connects as `postgres`: pg_hba.conf rejects `postgres` over TCP (`hostssl all postgres all reject`); changing that weakens the upstream access rules.
- Run the SQL on every start from the `postStart` hook: a second edit of an upstream object; a failed hook kills the container.
- Sidecar that runs the SQL: an extra long-running container for a one-time step.

## Consequences

- An existing data volume keeps its roles and schema. A setup SQL change in a later upstream release does not reach it until the script runs again.
- A failed first init leaves an initialized data directory without roles or schema. Recovery: `kubectl -n ate-system exec postgres-0 -c postgres -- sh /docker-entrypoint-initdb.d/substrate-setup.sh`. The SQL is idempotent and keeps data.
