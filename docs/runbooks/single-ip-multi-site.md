# Single-IP multi-site operations

## Current allocation

| Role | PVE VM | Address | Published mapping |
| --- | --- | --- | --- |
| Edge | 104 `single-ip-edge` | `10.1.2.57/24`, `172.23.57.1/24` | TCP `8081` |
| Type AI UAT | 105 `type-ai-platform-uat` | `172.23.57.11/24` | `8081 -> 172.23.57.11:443 -> nginx:443` |
| Type AI Demo | 103 `type-ai-platform-demo` | `172.23.57.12/24` | none — `8082` allocated, not published |

The only published client URL is `https://10.1.2.57:8081` for UAT. It uses its own nginx self-signed certificate; the browser will show a certificate warning once. DNS, ACME, publicly trusted TLS, WireGuard and hostname routing are not part of this deployment.

VM 103 is being replaced by CIB `cib-ai-platform`, cloned from template 109 `ub-26-4-srv-docker` with no preservation and no backup; see ADR-0006. The procedure is `scripts/cib-ai-platform-rebuild/`, run by hand on the PVE host, and it has not been run yet — VM 103 still holds the old Demo. `scripts/demo-rebuild-from-template/` is superseded. Nothing has listened on Demo's `443` since 2026-08-13 and the rebuilt machine will not serve it either, so the three Edge `8082` rules exist in the tracked ruleset but are **not installed** and `https://10.1.2.57:8082` does not answer. `8082` remains allocated to Demo as a permanent entrance port (ADR-0001) and can be published later without reallocating anything. Demo's purpose becomes development inside `/srv`: the `type-ai-platform-demo` monorepo is checked out at `/srv/type-ai-platform-demo`, owned by `mobagel`. Application deployment remains out of scope; see ADR-0003.

UAT is built from application revision `25201dbf1ba3475ebe9a69356c551e6394937f26`. Its `ENV=dev` fake SSO is for trusted-network testing only; do not place real personal data in this environment.

The applied Edge ruleset is tracked at `.scratch/single-ip-multi-site-network/nftables.edge.conf`. Unallocated ports have no DNAT rule and fail closed. The `8082` forward, DNAT and SNAT rules are present in that file but commented out and marked as generated-not-installed, so the file matches what actually runs on the Edge.

## Health and status

From an approved FortiClient session:

```powershell
Test-NetConnection 10.1.2.57 -Port 8081
curl.exe -kfsS https://10.1.2.57:8081/healthz
```

Expected UAT health body:

```json
{"status":"ok"}
```

`8082` has no DNAT rule installed, so `Test-NetConnection 10.1.2.57 -Port 8082` must
fail closed exactly like an unallocated port. That is the current expected result, not
a fault. It is also the check to repeat after any Demo work, to prove nothing published
the port by accident.

Edge checks:

```bash
sudo systemctl status nftables single-ip-edge-health.timer
cat /proc/sys/net/ipv4/ip_forward
sudo nft list ruleset
curl -kfsS https://172.23.57.11:443/healthz
```

There is no equivalent Demo check: nothing listens on `172.23.57.12:443`.

UAT private guest checks, reached through the Edge SSH jump host:

```bash
systemctl status docker type-ai-platform-firewall.service type-ai-platform-health.timer
docker inspect --format={{.State.Status}} \
  type-ai-platform-uat-postgres-1 \
  type-ai-platform-uat-clickhouse-1 \
  type-ai-platform-uat-backend-1 \
  type-ai-platform-uat-poller-1 \
  type-ai-platform-uat-frontend-1 \
  type-ai-platform-uat-nginx-1
iptables -C DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -C DOCKER-USER -i eth0 -s 172.23.57.1/32 -p tcp -m conntrack --ctorigdstport 443 -j ACCEPT
iptables -C DOCKER-USER -i eth0 -p tcp -m conntrack --ctorigdstport 443 -m limit --limit 5/second --limit-burst 10 -j LOG --log-prefix 'type-ai-drop '
iptables -C DOCKER-USER -i eth0 -p tcp -m conntrack --ctorigdstport 443 -j DROP
curl -kfsS https://172.23.57.11:443/healthz
df -hT /srv/platform
```

`/srv/platform` above is UAT-only — it is that guest's remounted Docker logical
volume. Demo has no `/srv/platform`: ADR-0002 applied to the machine destroyed in
the 2026-08-14 rebuild, and the replacement keeps everything directly under `/srv`.

The `ESTABLISHED,RELATED` rule must be evaluated before the service-port rules.
Docker return traffic traverses `DOCKER-USER`; without this rule, outbound
HTTPS from UAT containers can be dropped because its original destination port
is also `443`.

Health failures and rate-limited rejects are available through `journalctl`:

```bash
journalctl -u single-ip-edge-health.service
journalctl -k -g edge-forward-drop
journalctl -u type-ai-platform-health.service
journalctl -k -g type-ai-drop
```

These checks must not print `.env`, tokens or authorization headers.

Demo private guest checks once the rebuild has run, reached through the Edge SSH
jump host:

```bash
ip -4 -o addr show scope global
systemctl status docker
findmnt /srv
docker info --format '{{.DockerRootDir}} {{.Driver}} {{.ServerVersion}}'
df -hT /srv
sudo -u mobagel git -C /srv/type-ai-platform-demo status
ls -l /srv/typeai-demo
```

The address must be `172.23.57.12/24` with no `10.1.2.x` address anywhere; `/srv`
must be its own filesystem with at least 20% free. `/srv/type-ai-platform-demo` is
the `main` checkout, owned by `mobagel` — never clone or pull it as root, or every
later `git` command has to deal with `dubious ownership`. `/srv/typeai-demo` holds
the five secrets carried over from the previous machine (mode `0600`, owner
`mobagel`), `nginx.conf`, `試用說明.md` and, if that optional step was taken,
`typeai-demo-pg-volume.tar`. That tar is the previous Keycloak database, kept as a
plain file on purpose: no Docker volume is created for it, because nothing is
running that would use it. The rebuilt Demo runs no containers and needs no
`DOCKER-USER` ruleset. The old three-container stack definition at
`scripts/demo-entrance-and-srv-layout/demo-stack/` describes the machine being
replaced and is history, not current state.

The expired `tls.crt` / `tls.key` from the previous machine are deliberately not
restored; a `443` endpoint, if it is ever wanted, gets a fresh certificate then.

### UAT certificate lifecycle

The UAT nginx container creates a self-signed certificate and key in the named
volume `type-ai-platform-uat_nginx-certs`. Recreating containers does not
replace the certificate while that volume is retained; deleting or restoring
without the volume creates a new certificate and requires a new browser
exception. The protected backup must therefore include that volume and the
root-owned fingerprint file
`/etc/type-ai-platform/uat-nginx-cert.sha256`.

Initialize that file from the certificate in the named volume, using an atomic
root-owned write, before enabling the timer:

```bash
set -euo pipefail
sudo install -d -o root -g root -m 0755 /etc/type-ai-platform
tmp=$(sudo mktemp /etc/type-ai-platform/.uat-nginx-cert.sha256.XXXXXX)
trap 'sudo rm -f "$tmp"' EXIT
fingerprint=$(sudo openssl x509 \
  -in /srv/platform/docker/volumes/type-ai-platform-uat_nginx-certs/_data/server.crt \
  -noout -fingerprint -sha256 |
  sed 's/^sha256 Fingerprint=//; s/://g')
if ! printf '%s\n' "$fingerprint" | grep -Eq '^[[:xdigit:]]{64}$'; then
  echo 'certificate fingerprint validation failed' >&2
  exit 1
fi
printf '%s\n' "$fingerprint" | sudo tee "$tmp" >/dev/null
sudo chown root:root "$tmp"
sudo chmod 0644 "$tmp"
sudo mv -f "$tmp" /etc/type-ai-platform/uat-nginx-cert.sha256
trap - EXIT
```

The UAT health timer extracts the certificate from
`172.23.57.11:443`, requires at least 30 days before expiry, and compares its
SHA-256 fingerprint with that file. `curl -k` is an explicit exception only for
this fixed private UAT endpoint because the certificate is self-signed; it does
not disable certificate validation for a future production endpoint.

## Update Type AI Platform

1. Confirm `/srv/platform` will retain at least 20% free space.
2. Obtain the approved revision from `https://source.mobagel.com/type-ai-platform/type-ai-platform.git` using a read-only, non-interactive GitLab credential. Do not embed the credential in the remote URL or persist it in the checkout.
3. Keep the checkout at `/srv/platform/type-ai-platform` and record `git rev-parse HEAD`.
4. Compare `.env.uat.example` and `Settings`. On the first setup only, create
   the ignored `.env.uat` with cryptographically random UAT-only database
   passwords and the approved `SESSION_SECRET`, then set mode `0600`. For a
   normal update, preserve the existing `.env.uat`, database passwords and
   `SESSION_SECRET`; do not regenerate or overwrite them. Validate required key
   names, `ENV=dev`, `UAT_SERVER_NAME`, mode `0600` and Git-ignore status without
   printing values. Keep partner fields empty unless separately approved UAT
   endpoints and credentials exist.
5. Keep the checkout at `25201dbf1ba3475ebe9a69356c551e6394937f26` (or a newer approved main revision) and run UAT Compose validation without rendering resolved values:

   ```bash
   docker compose --env-file .env.uat \
     -f docker-compose.uat.yml \
     -f /srv/platform/app-data/type-ai-platform/compose.uat.deploy.yml \
     config -q
   ```

6. Build and start the UAT stack:

   ```bash
   docker compose --env-file .env.uat \
     -f docker-compose.uat.yml \
     -f /srv/platform/app-data/type-ai-platform/compose.uat.deploy.yml \
     build
   docker compose --env-file .env.uat \
     -f docker-compose.uat.yml \
     -f /srv/platform/app-data/type-ai-platform/compose.uat.deploy.yml \
     run --rm backend alembic upgrade head
   docker compose --env-file .env.uat \
     -f docker-compose.uat.yml \
     -f /srv/platform/app-data/type-ai-platform/compose.uat.deploy.yml \
     run --rm backend python -m app.telemetry.clickhouse
   docker compose --env-file .env.uat \
     -f docker-compose.uat.yml \
     -f /srv/platform/app-data/type-ai-platform/compose.uat.deploy.yml \
     up -d
   ```

7. Pass private UAT health from the Edge before changing any DNAT rule.
8. Re-run the VPN seam, frontend/login smoke test, direct-private deny, unallocated-port deny and storage checks.

The UAT frontend/API flow is now available through the same nginx port. It is still not production-ready: UAT uses a self-signed certificate and `ENV=dev` fake SSO; production Kubernetes manifests and real SSO remain separate work.

## Add an entrance port

1. Allocate one unused TCP port and one explicit `private_guest_ip:service_port`; do not create ranges or catch-all rules.
2. Prove the private endpoint is healthy from `172.23.57.1`.
3. Add all three matching rules to the Edge ruleset:
   - forward allow for the approved FortiGate source, destination and translated port;
   - prerouting DNAT from the entrance port;
   - postrouting SNAT to `172.23.57.1`, so the private guest only trusts the Edge source.
4. Validate the candidate without changing the running rules:

   ```bash
   sudo nft -c -f /path/to/candidate.conf
   ```

5. Back up `/etc/nftables.conf`, install the validated candidate and reload `nftables`.
6. Confirm the allocated port returns the expected private guest response, another unallocated port fails, direct private guest access fails and `10.1.2.50:8006` management remains unchanged.
7. Reboot the Edge in an approved window and repeat the checks.

## Remove or roll back an entrance port

1. Remove only that service's forward, DNAT and SNAT tuple from a candidate ruleset.
2. Run `nft -c -f` before installation.
3. Back up the current rules, install the candidate and reload.
4. Prove the removed port fails closed and every retained port still reaches the correct private guest.

For a failed Edge change, validate a known-good `/etc/nftables.conf.before-*` file before restoring it. Never install an unvalidated backup. The repository ruleset contains the current single 8081 mapping and can be used to reconstruct the Edge after verifying interface names and addresses.

For a failed application update, restore the previously recorded immutable Git revision, run `docker compose ... up -d --build`, apply only that revision's documented migrations and repeat private health before allowing traffic. Database rollback requires an application-specific, tested procedure; do not reverse migrations or delete volumes by assumption.

## Backup and restore scope

Backups must include:

- VM 103, VM 104 and VM 105 PVE configuration and disks;
- Edge `/etc/nftables.conf`, `/etc/sysctl.d/99-zz-single-ip-edge.conf`, health script and systemd units;
- UAT `/etc/fstab`, `/etc/docker/daemon.json`, deployment override, firewall and health scripts/units;
- the deployed immutable Git revision;
- `/srv/platform` Docker volumes and persistent application data.

The ignored `.secrets` hierarchy, the remote `.env.uat`, the UAT nginx certificate
volume and its root-owned fingerprint file, Demo's `/srv/typeai-demo/` secrets
(`demo-password`, `kc-admin-password`, `kc-token`, `seed-client-secret`,
`service-token-secret`) and Demo's GitLab deploy key
`/home/mobagel/.ssh/id_ed25519_mobagel_gitlab` require a separately approved
encrypted/protected backup. They must not be copied into Git, tickets, ordinary
logs or an unencrypted VM backup export. The Demo nginx certificate volume is no
longer in this list: the rebuilt machine has no `443` service and the previous
certificate was not carried over. This design has no DNS API token or ACME
account key.

### Rebuild artifacts, retained until explicitly released

Running the rebuild procedure leaves two things on the PVE host, and **neither is
deleted until the user says so**:

- `/root/demo-preserve-<YYYYMMDD-HHMMSS>/`, mode `0700` — the deploy key, the five
  Demo secrets, `nginx.conf`, `試用說明.md`, the Keycloak database volume tar, and
  `preserve-report.md` (names, sizes and SHA-256 only; values `<redacted>`).
- the `vzdump` archive of the replaced VM 103 on storage `local`; its path, size and
  SHA-256 are recorded in that same report.

**Nothing in the preserve directory may enter Git — not one file, no exceptions.**
The readback of the new machine is written outside it, to
`/root/demo-rebuild-shape-<YYYYMMDD-HHMMSS>.md`, with every section passed through
the redaction filter; that file may be copied to `docs/reports/` after a look.

An actual restore drill must target an isolated VMID/network and must not overwrite VM 104 or VM 105. After restore, verify resources, private addresses, `/srv` placement and headroom, then repeat every black-box check before cutover.

## Known acceptance gaps

- FortiGate policy ID, full client pool, user group and future-change behavior remain unknown; current access is empirically validated only.
- Off-VPN/public Internet reachability has not been tested from an independent external client.
- A general service-user identity distinct from the current PVE-capable VPN session has not been used to prove FortiGate-level PVE denial.
- PVE host reboot and an isolated restore drill have not been approved or executed.
- UAT frontend, same-port frontend/API routing and the dev-login smoke flow are verified; production frontend deployment, real SSO and trusted TLS remain out of scope.
