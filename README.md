# inceptech

ArgoCD **App-of-Apps** for the inceptech cluster — GitOps manifests only, no
application code.

- `root-app.yaml` — ArgoCD `Application` pointing at `apps/`, creating one
  `Application` per top-level `apps/*.yaml` (`include: '*.yaml'`, no recursion).
- `apps/<name>/` — manifests and/or Helm values for one service.
- `apps/<name>.yaml` — its ArgoCD `Application` wrapper.
- Sync policy is automated (`prune: true`, `selfHeal: true`) for every app
  **except** `siyuan-app.yaml` (`prune: false` — intentional, do not "fix").

## Secrets architecture

No secret values live in git:

```
OpenBao (KV v2, mount "secret")
   ↑  kubernetes auth: role eso-role, bound SA external-secrets/external-secrets
External Secrets Operator  →  native Kubernetes Secrets  →  workloads
```

- Single entry point: `ClusterSecretStore/openbao-backend`
  (`apps/openbao-conf/secretstore-openbao.yaml`).
- One `ExternalSecret` per consumer namespace (see `apps/*/…-external-secret…`).

## OpenBao bootstrap (manual)

The `openbao` ArgoCD app installs chart `openbao:0.30.4`
(`apps/openbao/values.yaml`): persistence ON, agent injector OFF.
The chart does **not** initialize or unseal the server, and the auth method,
role, policy and KV data are **not** managed by git — bootstrap them once per
fresh install.

> **`init` and `unseal` are always done by hand** — there is no auto-unseal
> (Shamir seal). After init, store the unseal keys and root token **outside the
> cluster** (password manager / external KMS).

All commands run through the CLI inside the server pod (binary is `bao`):

```bash
kubectl -n openbao exec -it openbao-0 -- bao
```

### 1. Init — once, on fresh storage only

```bash
kubectl -n openbao exec -it openbao-0 -- bao operator init
```

Prints **5 Shamir keys (threshold 3)** and a **root token**.
Losing ≥3 keys means losing all secrets permanently.

### 2. Unseal — after every pod / node restart

```bash
kubectl -n openbao exec -it openbao-0 -- bao operator unseal   # key 1
kubectl -n openbao exec -it openbao-0 -- bao operator unseal   # key 2
kubectl -n openbao exec -it openbao-0 -- bao operator unseal   # key 3 of 5 → unsealed
```

### 3. Login as root

```bash
kubectl -n openbao exec -it openbao-0 -- bao login   # paste the root token
```

### 4. KV v2 mount

`ClusterSecretStore` expects `path: "secret"`, `version: "v2"`:

```bash
kubectl -n openbao exec -it openbao-0 -- bao secrets enable -path=secret -version=2 kv
```

### 5. Kubernetes auth method

```bash
kubectl -n openbao exec -it openbao-0 -- bao auth enable kubernetes

# Dedicated reviewer SA allowed to call the TokenReview API
kubectl -n openbao create serviceaccount openbao-auth-reviewer
kubectl create clusterrolebinding openbao-auth-reviewer \
  --clusterrole=system:auth-delegator \
  --serviceaccount=openbao:openbao-auth-reviewer

# Long-lived reviewer token — TokenRequest tokens (kubectl create token)
# expire after ~1h and would silently break auth
kubectl -n openbao apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: openbao-auth-reviewer-token
  annotations:
    kubernetes.io/service-account.name: openbao-auth-reviewer
type: kubernetes.io/service-account-token
EOF

REVIEWER_JWT=$(kubectl -n openbao get secret openbao-auth-reviewer-token \
  -o jsonpath='{.data.token}' | base64 -d)

kubectl -n openbao exec -it openbao-0 -- \
  bao write auth/kubernetes/config \
      kubernetes_host="https://kubernetes.default.svc" \
      kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
      token_reviewer_jwt="$REVIEWER_JWT"
```

### 6. Policy + role

The role name **must match** `apps/openbao-conf/secretstore-openbao.yaml`
(`eso-role`), and the bound SA must match the ClusterSecretStore's
`serviceAccountRef`:

```bash
kubectl -n openbao exec -i openbao-0 -- bao policy write eso-policy - <<'EOF'
# KV v2 read for the External Secrets Operator
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["list", "read"]
}
EOF

kubectl -n openbao exec -it openbao-0 -- bao write auth/kubernetes/role/eso-role \
    bound_service_account_names="external-secrets" \
    bound_service_account_namespaces="external-secrets" \
    policies="eso-policy" \
    ttl=1h
```

### 7. Secret data

KV keys consumed by the `ExternalSecret`s:

| KV key (`secret/data/…`)     | ExternalSecret          | Namespace         |
|------------------------------|-------------------------|-------------------|
| `siyuan` (accessAuthCode)    | `siyuan-secrets`        | siyuan            |
| `watchly-api` (api-key)      | `watchly-api-secret`    | watchly           |
| `watchly-3d-models`          | `watchly-3d-models-secret` | watchly-3d-models |
| `savely`                     | `savely-secret`         | savely            |
| `displayify`                 | `displayify-secrets`, `displayify-lb-secrets` | displayify, nginx-load-balancer |

```bash
kubectl -n openbao exec -it openbao-0 -- bao kv put secret/siyuan accessAuthCode="..."
```

### 8. Verify

```bash
kubectl get clustersecretstore openbao-backend   # Ready=True
kubectl get externalsecret -A                    # STATUS=SecretSynced, READY=True
```
