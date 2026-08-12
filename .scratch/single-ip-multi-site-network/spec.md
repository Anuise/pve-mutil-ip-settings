# PVE 單一 IP 多網站內網架構

Status: ready-for-agent

## Problem Statement

目前使用者透過既有 FortiClient VPN 存取 `10.1.2.0/24`，PVE 管理介面位於 `10.1.2.50:8006`。原本可配置給服務的位址只剩 `10.1.2.57`，但 PVE 內需要建立多台 VM 或 LXC，並在其上承載多個網站。

若每個網站或 guest 都要求一個 `10.1.2.x` 位址，現有位址空間無法支撐需求。若另外導入 WireGuard，使用者將需要第二套 VPN、金鑰及路由管理，但它仍不會解決多個 HTTP/HTTPS 網站共用單一入口 IP 的分流問題。

使用者需要的是：只連既有 FortiClient VPN，即可用 `10.1.2.57:<port>` 存取所有內部服務；後端 guest 使用獨立私有 IP，且不對 VPN 使用者直接暴露；既有 PVE 管理路徑不受影響。使用者明確選擇取消 DNS 與公開信任 TLS，以部署速度和操作簡單為優先。UAT revision 另以 nginx 提供自簽 HTTPS；這不是公開信任 TLS，也不改變 IP＋port 入口設計。

## Solution

保留 FortiClient／FortiGate 作為唯一 VPN 入口，將 `10.1.2.57` 配置給一台專用 Edge VM。Edge VM 提供 nftables 防火牆、明確的 port DNAT、IPv4 forwarding 與私有 guest 的 outbound NAT，不部署 Caddy 或其他 hostname reverse proxy。

PVE 新增一個不連接實體網卡的私有 Linux bridge。Edge VM 的前端網卡連接既有實體 bridge 並使用 `10.1.2.57`；後端網卡連接私有 bridge 並使用 `172.23.57.1/24`。網站 guest 使用 `172.23.57.0/24` 的位址，以 Edge VM 作 default gateway。

每個內部服務配置一個獨立且可稽核的入口 TCP port。初始配置保留 `8081` 給 Type AI Platform、`8082` 給第二個驗證服務；nftables 將每個入口 port DNAT 到指定的私有 backend IP 與 service port。未配置的 port 維持拒絕。現行 UAT 將 `8081` 送至 `172.23.57.11:18000`，再由 nginx 終止自簽 HTTPS 並同源轉發 frontend/API。

VPN 使用者不取得私有 subnet 的 route，只能經 Edge VM 明確放行的 `10.1.2.57:<port>` 存取服務。UAT 入口使用自簽 HTTPS；不簽發公開信任憑證，也不要求 DNS。PVE 管理介面繼續使用 `10.1.2.50:8006`，不經過 Edge 服務入口。

第一個實際 backend 是 Type AI Platform。它使用 node `pve` 上既有 VM 109（`ub-26-4-srv-docker`）建立 full clone，來源 VM 保持不變。新 VM 接入私有 bridge，專案原始碼、Docker data-root 與應用持久資料均放在 `/srv` 下可用空間最大的適用 filesystem。專案來源為使用者指定的 Type AI Platform Git repository。

部署環境檔必須以 repository-local、已被 Git 忽略的 `.secrets` hierarchy 內 backend 環境資料為依據。秘密不得出現在 Git、ticket、log 或驗收輸出中。若缺少必要值，實作者只能回報缺少的 key 名稱，標示 `[HUMAN ACTION]` 並等待使用者提供或完成操作。

## User Stories

1. As a VPN user, I want to use the existing FortiClient connection, so that I do not need to install or operate a second VPN client.
2. As a VPN user, I want each internal service to have a documented `10.1.2.57:<port>` endpoint, so that I can connect without DNS or local host mappings.
3. As a VPN user, I want different entrance ports to reach the correct applications on the shared IP, so that all required services remain independently usable.
4. As a VPN user, I want unassigned entrance ports to be rejected, so that I am never sent to an unrelated application.
5. As a VPN user, I want protocols such as HTTP and WebSocket to pass transparently through the configured port mapping, so that interactive applications behave normally.
6. As a VPN user, I accept that the IP-and-port deployment does not provide publicly trusted TLS; UAT may use a self-signed certificate and require one browser warning bypass, with its expiry and fingerprint monitored.
7. As a VPN user, I want the port map kept explicit and stable, so that bookmarks and operational documentation remain accurate.
8. As a VPN user, I want service endpoints documented without embedding credentials, so that connection instructions can be shared safely.
9. As a VPN user, I want internal websites to be unreachable when I am not connected to the approved VPN, so that they remain internal services.
10. As a service owner, I want each VM or LXC to have its own private IP, so that services can be isolated and addressed consistently.
11. As a service owner, I want different guests to reuse the same local service ports, so that applications do not require arbitrary port remapping.
12. As a service owner, I want to add a service by declaring its entrance port and backend, so that onboarding does not consume another `10.1.2.x` address.
13. As a service owner, I want DNAT to preserve the original transport without injecting proxy headers, so that application behavior is not coupled to a reverse proxy.
14. As a service owner, I want backend access limited to the Edge VM and explicitly approved peers, so that a compromised VPN account cannot directly probe applications.
15. As a guest administrator, I want private guests to download operating-system and application updates, so that they can remain patched without receiving routable corporate IPs.
16. As a guest administrator, I want guest outbound access governed by firewall policy, so that private guests cannot freely access management systems.
17. As a PVE administrator, I want the existing `10.1.2.50:8006` management path to remain unchanged, so that deployment does not move or proxy the hypervisor management plane.
18. As a PVE administrator, I want the private bridge disconnected from physical NICs, so that private guest traffic is not accidentally exposed at Layer 2.
19. As a PVE administrator, I want the PVE host to have no IP on the private guest subnet, so that the backend network does not create another direct management surface on the hypervisor.
20. As a PVE administrator, I want network changes applied only when out-of-band recovery is available, so that a configuration error cannot permanently remove remote management access.
21. As a network administrator, I want `10.1.2.57` formally reserved and excluded from DHCP, so that the Edge VM never encounters an address conflict.
22. As a network administrator, I want the switch and NAC policy to explicitly permit the Edge VM MAC address, so that bridged guest networking works without bypassing port security.
23. As a network administrator, I want the currently approved FortiClient path empirically verified against every assigned port on `10.1.2.57`, so that deployment stops if the existing FortiGate path does not carry the required traffic.
24. As a network administrator, I want the initial allowed-port set limited to `8081` and the temporary validation port `8082`, so that the deployment does not create a broad port range.
25. As an operator, I want every allocated entrance port recorded with its backend IP and service port, so that changes remain auditable.
26. As an operator, I want port collisions detected before firewall rules are applied, so that one service cannot silently replace another.
27. As a security administrator, I want all Edge VM input and forwarding chains to default to deny, so that only explicitly allowed flows are possible.
28. As a security administrator, I want no DNS API token, ACME account key or Edge TLS private key deployed for this design, so that unused secrets do not enlarge the attack surface.
29. As a security administrator, I want backend applications not to trust client-supplied proxy headers because the Edge does not generate trusted proxy metadata.
30. As a security administrator, I want the UAT self-signed TLS exception to be explicit and monitored, and any production TLS addition treated as a separately approved hardening change, so that certificate validation is not silently disabled.
31. As an operator, I want nftables configuration validated before reload, so that an invalid change does not interrupt every service.
32. As an operator, I want Edge VM services and networking to start automatically after reboot, so that a host restart does not require manual recovery.
33. As an operator, I want health checks for each allocated `IP:port`, backend routing and application response, so that failures are detected before users report them.
34. As an operator, I want Edge VM configuration and secrets backed up through approved secure mechanisms, so that the entrance can be restored after failure.
35. As an operator, I want a documented restore and reboot verification procedure, so that recoverability is demonstrated rather than assumed.
36. As a maintainer, I want the architecture to use the minimum necessary components, so that routine changes do not require expertise in overlapping VPN and proxy systems.
37. As a maintainer, I want service routing to remain explicit, so that each entrance port has an auditable backend destination.
38. As a maintainer, I want deployment to stop if the proposed private CIDR overlaps an existing network, so that routing ambiguity is not introduced silently.
39. As an auditor, I want access and error logs from the Edge VM, so that website traffic and routing failures can be investigated.
40. As an auditor, I want PVE management access separated from website access, so that publishing a site never grants hypervisor privileges.
41. As a PVE administrator, I want the first application VM created as a full clone of VM 109 on node `pve`, so that the approved Ubuntu Docker baseline is reused without coupling the new service to the source disk.
42. As a PVE administrator, I want VM 109 to remain unmodified by cloning and deployment, so that the baseline can continue serving its original purpose.
43. As a service owner, I want Type AI Platform deployed from the approved Git repository, so that the running application can be traced to the intended source.
44. As a storage administrator, I want application code, Docker storage and persistent data placed below `/srv` on the filesystem with the most suitable free capacity, so that the root filesystem is not consumed by the deployment.
45. As an operator, I want capacity measured before and after deployment, so that the selected `/srv` filesystem retains safe operating headroom.
46. As a security administrator, I want every environment-file change derived from the ignored `.secrets` source, so that credentials are not guessed, duplicated into tickets or committed.
47. As a security administrator, I want missing environment values reported by key name only, so that troubleshooting does not disclose existing secret values.
48. As a user, I want every action that requires my credentials, approval or manual infrastructure access marked `[HUMAN ACTION]`, so that the implementation pauses until I explicitly complete it.
49. As a service owner, I want the cloned Type AI Platform VM allocated 8 vCPU and 64 GiB RAM, so that the application has the required compute capacity without changing VM 109.

## Implementation Decisions

- The existing FortiClient／FortiGate tunnel remains the sole client VPN. WireGuard will not be installed for this feature.
- `10.1.2.50:8006` remains the PVE management endpoint and is not forwarded, renamed or exposed through the service port map.
- `10.1.2.57` is the only `10.1.2.x` address allocated to the website platform and belongs to a dedicated Edge VM.
- The Edge VM is a regular VM rather than an LXC because it forms the network and firewall boundary and must control forwarding and NAT without container capability exceptions.
- The Type AI Platform backend and the Edge VM are separate machines. Application containers never share the network-boundary VM.
- The Type AI Platform backend is created as a full clone of VM 109 (`ub-26-4-srv-docker`) on node `pve`. A linked clone is not used, and the source VM's disks, configuration, power state and network settings are not modified without a separately approved human action.
- After cloning, the new Type AI Platform VM is configured with 8 virtual CPU cores and 64 GiB RAM (`65536` MiB). These resource changes apply only to the clone; memory ballooning is disabled so the assigned capacity remains predictable.
- The cloned backend receives the first application address in the private allocation range and has no `10.1.2.x` address.
- The application is checked out from `https://source.mobagel.com/type-ai-platform/type-ai-platform.git`. The deployed revision is recorded for audit and rollback. The repository is hosted on a sign-in-protected GitLab instance; if no approved non-interactive credential is already available, cloning pauses under `[HUMAN ACTION]`.
- Before deployment, the implementation enumerates filesystems mounted at or below `/srv` and chooses the suitable filesystem with the greatest available capacity. If projected deployment would leave less than twenty percent free space, deployment stops with `[HUMAN ACTION]` rather than selecting the root filesystem or deleting data.
- The project checkout, Docker data-root, bind-mounted application state and named-volume backing data for this dedicated clone are all located below the selected `/srv` filesystem. Existing unrelated data is not moved or deleted.
- Before creating or changing a deployment `.env`, implementation reads the corresponding backend environment source in the ignored `.secrets` hierarchy and compares it with the application's required environment schema or example. UAT-only database passwords may be generated once at first setup when the source has no corresponding values, but must be preserved on normal updates.
- Secret values are never printed, copied into ticket text, committed, or included in test artifacts. When a required key is absent, only its key name is reported and work pauses under `[HUMAN ACTION]`; values are never invented.
- Any step that needs the user's credentials, infrastructure approval, FortiGate administration, PVE console access, destructive confirmation or missing secret is marked `[HUMAN ACTION]`. The agent must stop at that gate until the user explicitly confirms completion.
- The Edge VM uses two NICs: a front NIC on the existing PVE physical bridge and a back NIC on a new private bridge.
- The private bridge has no physical bridge ports. The PVE host has no IP address on it.
- The default private address plan is `172.23.57.0/24`, with `172.23.57.1` reserved for the Edge VM. Backend addresses begin at `172.23.57.11`; lower addresses remain reserved for infrastructure.
- Before any network mutation, implementation must check that `172.23.57.0/24` does not overlap corporate routes, VPN client networks, container networks or site-to-site networks. An overlap is a blocking condition requiring the spec's address plan to be amended; the implementation must not silently choose another subnet.
- The Edge VM front prefix, default gateway and DNS resolver are read from the existing approved `10.1.2.0/24` network configuration. They are environment inputs, not invented defaults.
- The network administrator must confirm that `10.1.2.57` is reserved outside DHCP and that the switch or NAC permits the Edge VM's MAC address. Failure of either check blocks deployment.
- Caddy, Nginx, HAProxy, Traefik and GUI proxy managers are not part of the initial entrance. nftables performs explicit destination NAT from each front-side TCP port to one private backend endpoint.
- The initial port allocation is `10.1.2.57:8081` for Type AI Platform and `10.1.2.57:8082` for the temporary second-service acceptance test. Additional services require an explicit, non-conflicting port assignment and firewall review.
- Each published service has one auditable `front_port -> backend_ip:backend_port` mapping. There is no automatic discovery or catch-all destination.
- Unassigned front ports are rejected by the default-deny policy. A request cannot fall through to another backend.
- DNAT preserves the original application protocol and does not add trusted proxy headers. Backends must not trust client-supplied `Forwarded` or `X-Forwarded-*` headers as Edge identity evidence.
- The current UAT user-facing transport is HTTPS inside the approved FortiClient VPN, using a self-signed certificate generated by the UAT nginx container. No publicly trusted certificate, DNS or internal CA is deployed.
- The UAT nginx certificate and key live in the named `type-ai-platform-uat_nginx-certs` volume. A protected expected SHA-256 fingerprint is checked by the backend health timer together with a 30-day expiry threshold; `curl -k` is documented only for this fixed UAT endpoint.
- nftables is the firewall and NAT implementation on the Edge VM. No second firewall appliance is introduced in the initial architecture.
- Edge VM input and forward policy default to deny. Input permits loopback, required ICMP, established or related traffic and approved administrative SSH. Forward permits approved VPN sources only to explicitly allocated DNAT ports.
- Front-to-private forwarding is denied except for the exact DNAT tuples declared in the port map.
- Private guests may initiate only approved outbound traffic with established or related return traffic. Source NAT masquerades approved guest traffic as `10.1.2.57`.
- Each backend's PVE or guest firewall permits its service port from approved VPN source addresses through the Edge forwarding path and denies unneeded inbound and east-west traffic.
- FortiGate administrative details are unavailable. The user has accepted an empirical gate: temporary listeners on `10.1.2.57` must produce `TcpTestSucceeded=True` for TCP `8081` and `8082` from the currently approved FortiClient session before deployment. A failure blocks deployment and must not be bypassed.
- Passing the empirical gate proves point-in-time reachability only. It does not reveal or prove least-privilege policy scope, complete client pools, user groups, destination objects or NAT behavior, and it does not guarantee future FortiGate changes will preserve access.
- VPN clients receive no route for `172.23.57.0/24`. Direct backend access is intentionally unavailable.
- DNS, split DNS, ACME and certificate automation are intentionally omitted. Users connect directly to documented `10.1.2.57:<port>` endpoints.
- DNS API tokens, ACME account keys and Edge TLS private keys must not be introduced for this design.
- Edge VM networking and nftables must be enabled for automatic startup. Rule reloads occur only after validation.
- Backups include all configuration needed to reconstruct the Edge VM and protected copies of required secrets. Restore and reboot behavior must be tested.
- The Edge router and port-forwarding role is an accepted single point of failure for the initial one-PVE, one-IP deployment. Splitting these roles is deferred until scale or threat requirements justify the extra boundary.

## Testing Decisions

- The primary test seam is one black-box client boundary representing a user already connected to FortiClient. Tests assert observable `IP:port` routing and isolation behavior without inspecting nftables internals.
- `10.1.2.57:8081` must return the Type AI Platform response through the approved VPN path.
- `10.1.2.57:8082` must return a distinguishable response from the temporary second backend during multi-service acceptance.
- Before permanent publication, the same approved FortiClient client must repeat `Test-NetConnection` against each allocated port. Both temporary preflight probes and final service probes must be recorded with source address, destination and result.
- An unassigned entrance port must fail closed and must not reach any backend.
- No DNS lookup or hostname is required by this design. UAT HTTPS uses an IP and port and may show a self-signed certificate warning; a publicly trusted certificate is not a requirement.
- A VPN client must have no route to the private subnet and must fail to connect directly to backend addresses.
- A VPN user in the ordinary website access group must not gain access to the PVE management endpoint.
- A backend guest must reach approved update destinations through the Edge VM's NAT path.
- A backend guest must not initiate access to the PVE management endpoint or unapproved east-west destinations.
- A backend web port must accept the Edge VM private source and reject unapproved sources.
- The application must not treat client-supplied proxy headers as authenticated Edge metadata because the DNAT path does not inject trusted headers.
- nftables configuration validation commands are secondary preflight checks, not substitutes for black-box behavior tests.
- The Edge VM and PVE host must be rebooted during acceptance testing. Firewall policy, NAT and every allocated entrance port must recover automatically.
- A restore exercise must rebuild or recover the Edge entrance from its documented backup and reproduce the same black-box results.
- Tests must also be executed without the approved VPN path. Allocated `10.1.2.57` service ports must not become publicly reachable.
- Existing tests provide no prior art because the repository currently contains documentation only. The first implementation should establish the black-box acceptance harness as the single reusable seam for later site additions.
- VM 109's configuration, disks, power state and network identity must match their pre-clone observations after the backend clone is created.
- The cloned backend must report 8 available virtual CPU cores and 64 GiB configured memory, while VM 109 retains its original CPU and memory configuration.
- The backend must report the expected source repository and record the deployed revision without exposing repository credentials.
- Storage acceptance verifies that the checkout, Docker data-root and persistent application data resolve below the selected `/srv` filesystem and that at least twenty percent free space remains after deployment.
- The application must first pass a private-backend health check before its DNAT port is enabled for VPN users.
- Secret-safety acceptance verifies that environment files and secret values are absent from Git changes and captured logs. Tests may report key names, presence and validation status, but never values.
- Any acceptance step requiring user action must remain pending while its `[HUMAN ACTION]` gate is unconfirmed; it may not be marked successful based on an assumption.

## Out of Scope

- Installing or operating WireGuard or another second client VPN.
- Giving VPN clients direct routed access to `172.23.57.0/24`.
- Publishing SSH, RDP, databases or other sensitive protocols without a separately approved port assignment and firewall policy.
- Exposing any website to the public Internet.
- Proxying, renaming or otherwise changing the PVE management endpoint.
- High availability, VRRP, multiple PVE nodes, multiple Edge VMs or automatic IP failover.
- Adding a reverse-proxy appliance to the initial Edge VM design.
- Kubernetes, Docker label discovery, Traefik or dynamic service discovery.
- An automatic DHCP or IPAM service for backend servers; backend addresses remain explicitly assigned.
- Internal or public DNS, split DNS, hostname routing, ACME, public certificates or certificate-provider selection.
- Application-level SSO, authorisation, WAF rules or changes to backend application business logic.
- Granting general Internet access to private guests beyond the outbound flows approved during deployment.
- Silently substituting a different private subnet when the selected CIDR conflicts with the environment.
- Modifying, repurposing or deleting VM 109 after taking the approved full clone.
- Placing Type AI Platform project data or Docker storage on the cloned VM's root filesystem when a suitable `/srv` filesystem is unavailable.
- Inventing missing environment values or copying secrets into tracked configuration.
- Performing a user-owned infrastructure or credential operation on the user's behalf when it has been marked `[HUMAN ACTION]`.

## Further Notes

- Deployment requires an out-of-band recovery path such as physical console, IPMI or iKVM before modifying PVE networking.
- The VPN type is confirmed as FortiClient SSL-VPN, but the exact FortiOS version, complete client pool, policy objects and NAT behavior are unavailable. User-authorized empirical tests from the current VPN session are the accepted deployment gate for TCP `8081`／`8082`; this limitation remains documented and requires retesting after any network change.
- The architecture accepts that the PVE host, Edge VM, FortiGate path and single entrance IP are single points of failure. WireGuard would not remove them.
- The accompanying architecture research retains the original DNS/Caddy/TLS option as historical research, but the 2026-08-11 user decision supersedes it for implementation.
- The `.secrets` directory exists locally, is ignored by Git and contains a backend environment source. Its values remain intentionally absent from this spec.
- The implementation must preserve unrelated existing `.gitignore` and `.secrets` changes.
