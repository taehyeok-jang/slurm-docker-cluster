# Slurm REST API Authentication Guide

The Slurm REST API (`slurmrestd`) requires authentication. This guide covers the three authentication methods, JWT setup and usage, how JWT works in this cluster, and when you need an external auth layer for restricted access (e.g. login-only or group-based token issuance).

---

## Table of Contents

1. [Summary](#1-summary)
2. [JWT Key Setup](#2-jwt-key-setup)
3. [Authentication Methods](#3-authentication-methods)
4. [How JWT Works in This Cluster](#4-how-jwt-works-in-this-cluster)
5. [Restricted Access: Auth Layer](#5-restricted-access-auth-layer)
6. [Troubleshooting](#6-troubleshooting)
7. [API Version](#7-api-version)
8. [References](#8-references)

---

## 1. Summary

| Topic | Summary |
|-------|---------|
| **Auth methods** | (1) Unix socket inside container (MUNGE/local), (2) MUNGE over network (limited), (3) JWT over network (recommended). |
| **JWT key** | `/var/lib/slurm/jwt_hs256.key` — symmetric shared secret (HS256). Not auto-generated; created by `init-jwt-key.sh` or manually. |
| **Key permissions** | `slurm:slurmjwt`, `0640` so slurmctld/slurmdbd and slurmrestd can read it; external users must **never** have the key. |
| **Token issuance** | `./generate-jwt-token.sh` (calls `scontrol token` in slurmctld) or a trusted service; clients use `X-SLURM-USER-NAME` and `X-SLURM-USER-TOKEN`. |
| **Restricted access** | To allow only logged-in users or group-based access, add an **auth layer** (login, groups, token issuance or proxy) in front of slurmrestd; Slurm only verifies JWTs. |

---

## 2. JWT Key Setup

**The `jwt_hs256.key` file is NOT auto-generated.** Create it in the StateSaveLocation (`/var/lib/slurm`). In this setup the entrypoint can create it automatically on first run; you can also create it manually.

### Create the key

```bash
# Option A: Use the provided script (recommended)
docker exec -it slurmctld init-jwt-key.sh

# Option B: Manual (as root in container)
docker exec -it slurmctld bash -c "
  cd /var/lib/slurm
  dd if=/dev/urandom of=jwt_hs256.key bs=32 count=1
  chown slurm:slurmjwt jwt_hs256.key
  chmod 0640 jwt_hs256.key
"
```

This creates a 32-byte (256-bit) random key. In this cluster the key uses group `slurmjwt` and mode `0640` so both slurmctld/slurmdbd (user `slurm`) and slurmrestd (user `slurmrest`) can read it, without slurmrestd running as SlurmUser's group (which Slurm forbids).

### slurm.conf

Ensure `slurm.conf` (e.g. `config/25.05/slurm.conf`) contains:

```ini
AuthType=auth/munge
AuthAltTypes=auth/jwt
AuthAltParameters=jwt_key=/var/lib/slurm/jwt_hs256.key
```

After creating or changing the key, restart if needed:

```bash
docker compose restart slurmctld slurmrestd
```

---

## 3. Authentication Methods

### Method 1: Unix Socket (Inside Container) — MUNGE/Local

Passwordless access from inside a container; no JWT required.

```bash
docker exec -it slurmrestd bash
curl --unix-socket /var/run/slurmrestd/slurmrestd.socket http://localhost/slurm/v0.0.40/ping
curl --unix-socket /var/run/slurmrestd/slurmrestd.socket http://localhost/slurm/v0.0.40/nodes
```

The Unix socket is only accessible from inside containers, not from the host.

### Method 2: MUNGE (Network)

MUNGE works best with the Unix socket. For TCP from the host, JWT (Method 3) is preferred.

### Method 3: JWT Tokens (Network — Recommended)

For access from the host or external clients, use JWT.

**Step 1 — Create JWT key (if not done):** See [JWT Key Setup](#2-jwt-key-setup).

**Step 2 — Generate a token:**

```bash
./generate-jwt-token.sh           # default: 1 hour
./generate-jwt-token.sh 7200      # 2 hours
```

**Step 3 — Use the token:**

```bash
TOKEN="<output-from-script>"
USERNAME="root"

curl -H "X-SLURM-USER-NAME: $USERNAME" \
     -H "X-SLURM-USER-TOKEN: $TOKEN" \
     http://localhost:6820/slurm/v0.0.40/ping

curl -H "X-SLURM-USER-NAME: $USERNAME" \
     -H "X-SLURM-USER-TOKEN: $TOKEN" \
     http://localhost:6820/slurm/v0.0.40/nodes

curl -H "X-SLURM-USER-NAME: $USERNAME" \
     -H "X-SLURM-USER-TOKEN: $TOKEN" \
     http://localhost:6820/slurm/v0.0.40/jobs
```

---

## 4. How JWT Works in This Cluster

- **Flow:** slurmctld signs tokens with `jwt_hs256.key` (e.g. via `scontrol token`). slurmrestd verifies tokens with the same key and forwards requests to slurmctld. The key is shared via the `var_lib_slurm` volume.
- **Key type:** `jwt_hs256.key` is a **symmetric shared secret** (HS256): the same key signs and verifies. It is not an RSA-style private key; treat it as highly confidential.
- **Who must not have the key:** External users (e.g. groups A, B, C, D using the REST API) must **never** have the key. Anyone with it can create valid JWTs for any user and gain full REST API control. Only Slurm services (slurmctld, slurmdbd, slurmrestd) and trusted token-issuance services should have it; external users receive only **tokens**.

---

## 5. Restricted Access: Auth Layer

Slurm does **not** decide *who* gets a token; it only verifies that a JWT is **valid**. If you want:

- only **logged-in** users to get a 1-hour JWT, or  
- **group-based** Slurm access (e.g. groups A, B, C, D with different permissions),

you need a **separate auth layer** in front of slurmrestd that:

1. Authenticates the user (login, SSO, OIDC).
2. Optionally maps them to a Slurm user and enforces group/policy.
3. Either **issues** a short-lived JWT (e.g. by calling `scontrol token` or signing with the key in a secure service) or **proxies** requests to slurmrestd with a token the client never sees.

**Two patterns:**

- **Authenticating proxy:** Users log in; they do not receive a Slurm JWT. A proxy validates the session and forwards to slurmrestd with `X-SLURM-USER-NAME` and `X-SLURM-USER-TOKEN`. JWT stays on the server.
- **Token issuance service:** Users log in; an auth service verifies login (and optionally group), then calls `scontrol token` or signs a JWT and returns a short-lived token (e.g. 1 hour) to the client. Client uses that token with slurmrestd.

**Kubernetes / Ingress options:** Ingress + OAuth2 Proxy / Dex / Keycloak; API Gateway (Kong, APISIX); or a dedicated token-service pod that issues JWTs after login/group check.

---

## 6. Troubleshooting

### Authentication failure (JWT)

- Ensure JWT plugin is available and token is valid: `./generate-jwt-token.sh`
- Ensure slurmrestd is started with `SLURM_JWT=daemon` (set in docker-compose for this project).
- Check key exists and permissions: `docker exec slurmctld ls -la /var/lib/slurm/jwt_hs256.key`

### Authentication failure (Unix socket)

- Use the socket from inside the container:
  ```bash
  docker exec -it slurmrestd bash
  curl --unix-socket /var/run/slurmrestd/slurmrestd.socket http://localhost/slurm/v0.0.40/ping
  ```

### Check plugins and MUNGE

```bash
docker logs slurmrestd | grep -i "authentication plugin\|auth plugin"
docker exec slurmrestd pidof munged
```

### JWT plugin not available

- Use Unix socket (Method 1) from inside containers, or rebuild the image with Slurm JWT support (libjwt and auth_jwt/rest_auth/jwt).

---

## 7. API Version

The API version in the URL (e.g. `v0.0.40`) should match your Slurm version:

```bash
docker exec slurmctld scontrol --version
```

Common versions: Slurm 24.11.x → `v0.0.38`; Slurm 25.05.x → `v0.0.40`.

---

## 8. References

- [Slurm REST API](https://slurm.schedmd.com/rest_api.html)
- [Slurm JWT Authentication](https://slurm.schedmd.com/jwt.html)
