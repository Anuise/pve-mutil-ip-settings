# Single-IP multi-site operations

## Current allocation

| Role | PVE VM | Address | Published mapping |
| --- | --- | --- | --- |
| Edge | 104 `single-ip-edge` | `10.1.2.57/24`, `172.23.57.1/24` | TCP `8081` |
| Type AI UAT | 105 `type-ai-platform-backend` | `172.23.57.11/24` | `8081 -> 172.23.57.11:443 -> nginx:443` |

The current client URL is `https://10.1.2.57:8081`. It uses the UAT nginx self-signed certificate; the browser will show a certificate warning once. DNS, ACME, publicly trusted TLS, WireGuard and hostname routing are not part of this deployment.

UAT is built from application revision `25201dbf1ba3475ebe9a69356c551e6394937f26`. Its `ENV=dev` fake SSO is for trusted-network testing only; do not place real personal data in this environment.

The applied Edge ruleset is tracked at `.scratch/single-ip-multi-site-network/nftables.edge.conf`. Unallocated ports have no DNAT rule and fail closed.

## Health and status

From an approved FortiClient session:

```powershell
Test-NetConnection 10.1.2.57 -Port 8081
curl.exe -kfsS https://10.1.2.57:8081/healthz
```

Expected health body:

```json
{"status":"ok"}
```

Edge checks:

```bash
sudo systemctl status nftables single-ip-edge-health.timer
cat /proc/sys/net/ipv4/ip_forward
sudo nft list ruleset
curl -kfsS https://172.23.57.11:443/healthz
```

Backend checks, reached through the Edge SSH jump host:

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

The backend health timer extracts the certificate from
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

1. Allocate one unused TCP port and one explicit `backend_ip:backend_port`; do not create ranges or catch-all rules.
2. Prove the private endpoint is healthy from `172.23.57.1`.
3. Add all three matching rules to the Edge ruleset:
   - forward allow for the approved FortiGate source, destination and translated port;
   - prerouting DNAT from the entrance port;
   - postrouting SNAT to `172.23.57.1`, so the backend only trusts the Edge source.
4. Validate the candidate without changing the running rules:

   ```bash
   sudo nft -c -f /path/to/candidate.conf
   ```

5. Back up `/etc/nftables.conf`, install the validated candidate and reload `nftables`.
6. Confirm the allocated port returns the expected backend response, another unallocated port fails, direct backend access fails and `10.1.2.50:8006` management remains unchanged.
7. Reboot the Edge in an approved window and repeat the checks.

## Remove or roll back an entrance port

1. Remove only that service's forward, DNAT and SNAT tuple from a candidate ruleset.
2. Run `nft -c -f` before installation.
3. Back up the current rules, install the candidate and reload.
4. Prove the removed port fails closed and every retained port still reaches the correct backend.

For a failed Edge change, validate a known-good `/etc/nftables.conf.before-*` file before restoring it. Never install an unvalidated backup. The repository ruleset contains the current single 8081 mapping and can be used to reconstruct the Edge after verifying interface names and addresses.

For a failed application update, restore the previously recorded immutable Git revision, run `docker compose ... up -d --build`, apply only that revision's documented migrations and repeat private health before allowing traffic. Database rollback requires an application-specific, tested procedure; do not reverse migrations or delete volumes by assumption.

## Backup and restore scope

Backups must include:

- VM 104 and VM 105 PVE configuration and disks;
- Edge `/etc/nftables.conf`, `/etc/sysctl.d/99-zz-single-ip-edge.conf`, health script and systemd units;
- backend `/etc/fstab`, `/etc/docker/daemon.json`, deployment override, firewall and health scripts/units;
- the deployed immutable Git revision;
- `/srv/platform` Docker volumes and persistent application data.

The ignored `.secrets` hierarchy, the remote `.env.uat`, the UAT nginx
certificate volume and the root-owned fingerprint file require a separately
approved encrypted/protected backup. They must not be copied into Git, tickets,
ordinary logs or an unencrypted VM backup export. This design has no DNS API
token or ACME account key.

An actual restore drill must target an isolated VMID/network and must not overwrite VM 104 or VM 105. After restore, verify resources, private addresses, `/srv` placement and headroom, then repeat every black-box check before cutover.

## Known acceptance gaps

- FortiGate policy ID, full client pool, user group and future-change behavior remain unknown; current access is empirically validated only.
- Off-VPN/public Internet reachability has not been tested from an independent external client.
- A general service-user identity distinct from the current PVE-capable VPN session has not been used to prove FortiGate-level PVE denial.
- PVE host reboot and an isolated restore drill have not been approved or executed.
- UAT frontend, same-port frontend/API routing and the dev-login smoke flow are verified; production frontend deployment, real SSO and trusted TLS remain out of scope.
