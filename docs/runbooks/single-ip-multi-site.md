# Single-IP multi-site operations

## Current allocation

| Role | PVE VM | Address | Published mapping |
| --- | --- | --- | --- |
| Edge | 104 `single-ip-edge` | `10.1.2.57/24`, `172.23.57.1/24` | TCP `8081` |
| Type AI backend | 105 `type-ai-platform-backend` | `172.23.57.11/24` | `8081 -> 172.23.57.11:18000` |

The initial client URL is `http://10.1.2.57:8081`. It is HTTP inside the existing FortiClient VPN. DNS, ACME, public TLS, WireGuard and hostname routing are not part of this deployment.

The applied Edge ruleset is tracked at `.scratch/single-ip-multi-site-network/nftables.edge.conf`. Unallocated ports have no DNAT rule and fail closed.

## Health and status

From an approved FortiClient session:

```powershell
Test-NetConnection 10.1.2.57 -Port 8081
Invoke-WebRequest -UseBasicParsing http://10.1.2.57:8081/healthz
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
curl -fsS http://172.23.57.11:18000/healthz
```

Backend checks, reached through the Edge SSH jump host:

```bash
systemctl status docker type-ai-platform-firewall.service type-ai-platform-health.timer
docker inspect --format={{.State.Status}} \
  type-ai-platform-postgres-1 \
  type-ai-platform-clickhouse-1 \
  type-ai-platform-backend-1
curl -fsS http://172.23.57.11:18000/healthz
df -hT /srv/platform
```

Health failures and rate-limited rejects are available through `journalctl`:

```bash
journalctl -u single-ip-edge-health.service
journalctl -k -g edge-forward-drop
journalctl -u type-ai-platform-health.service
journalctl -k -g type-ai-drop
```

These checks must not print `.env`, tokens or authorization headers.

## Update Type AI Platform

1. Confirm `/srv/platform` will retain at least 20% free space.
2. Obtain the approved revision from `https://source.mobagel.com/type-ai-platform/type-ai-platform.git` using a read-only, non-interactive GitLab credential. Do not embed the credential in the remote URL or persist it in the checkout.
3. Keep the checkout at `/srv/platform/type-ai-platform` and record `git rev-parse HEAD`.
4. Compare `apps/backend/.env.example` and `Settings` with the ignored source `.secrets/apps/backend/.env`. Report key names and validation state only.
5. Transfer the environment file to `apps/backend/.env`, set mode `0600`, confirm it is Git ignored, and run Compose validation without rendering resolved values:

   ```bash
   docker compose \
     -f docker-compose.dev.yml \
     -f /srv/platform/app-data/type-ai-platform/compose.deploy.yml \
     --profile backend config -q
   ```

6. Build and start the backend stack:

   ```bash
   docker compose \
     -f docker-compose.dev.yml \
     -f /srv/platform/app-data/type-ai-platform/compose.deploy.yml \
     --profile backend up -d --build postgres clickhouse backend
   ```

7. Apply PostgreSQL and ClickHouse migrations with the same two Compose files, then pass private health from the Edge before changing any DNAT rule.
8. Re-run the VPN seam, direct-private deny, unallocated-port deny and storage checks.

The repository currently supplies development Dockerfiles and Compose configuration. A production frontend image and production manifests are not yet available; do not label this stack production-ready until those artifacts and the single-port frontend/API flow are delivered and tested.

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

The ignored `.secrets` hierarchy requires a separately approved protected backup. It must not be copied into Git, tickets, ordinary logs or an unencrypted VM backup export. This design has no DNS API token, ACME account key or Edge TLS private key.

An actual restore drill must target an isolated VMID/network and must not overwrite VM 104 or VM 105. After restore, verify resources, private addresses, `/srv` placement and headroom, then repeat every black-box check before cutover.

## Known acceptance gaps

- FortiGate policy ID, full client pool, user group and future-change behavior remain unknown; current access is empirically validated only.
- Off-VPN/public Internet reachability has not been tested from an independent external client.
- A general service-user identity distinct from the current PVE-capable VPN session has not been used to prove FortiGate-level PVE denial.
- PVE host reboot and an isolated restore drill have not been approved or executed.
- Production frontend image, same-port frontend/API routing and the full UI workflow are not available in the current application revision.
