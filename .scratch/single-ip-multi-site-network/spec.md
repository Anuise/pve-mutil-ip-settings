# PVE 單一 IP 多網站內網架構

Status: ready-for-agent

## Problem Statement

目前使用者透過既有 FortiClient VPN 存取 `10.1.2.0/24`，PVE 管理介面位於 `10.1.2.50:8006`。原本可配置給服務的位址只剩 `10.1.2.57`，但 PVE 內需要建立多台 VM 或 LXC，並在其上承載多個網站。

若每個網站或 guest 都要求一個 `10.1.2.x` 位址，現有位址空間無法支撐需求。若另外導入 WireGuard，使用者將需要第二套 VPN、金鑰及路由管理，但它仍不會解決多個 HTTP/HTTPS 網站共用單一入口 IP 的分流問題。

使用者需要的是：只連既有 FortiClient VPN，即可用一般瀏覽器及正式 HTTPS 網址存取所有內部網站；後端 guest 使用獨立私有 IP，且不對 VPN 使用者直接暴露；既有 PVE 管理路徑不受影響。

## Solution

保留 FortiClient／FortiGate 作為唯一 VPN 入口，將 `10.1.2.57` 配置給一台專用 Edge VM。Edge VM 同時提供 Caddy 反向代理、nftables 防火牆、IPv4 forwarding 與私有 guest 的 outbound NAT。

PVE 新增一個不連接實體網卡的私有 Linux bridge。Edge VM 的前端網卡連接既有實體 bridge 並使用 `10.1.2.57`；後端網卡連接私有 bridge 並使用 `172.23.57.1/24`。網站 guest 使用 `172.23.57.0/24` 的位址，以 Edge VM 作 default gateway。

所有內部網站使用組織持有正式網域下的 hostname。FortiClient 的 split DNS 將這些 hostname 解析至 `10.1.2.57`，Caddy 終止 TLS，依 HTTP Host／TLS SNI 將請求轉送到正確的私有 backend。公開信任憑證透過 ACME DNS-01 自動簽發及續期，不將網站開放至 Internet，也不要求使用者安裝私有 CA。

VPN 使用者不取得私有 subnet 的 route，只能經 Edge VM 的 80/443 存取明確登記的網站。PVE 管理介面繼續使用 `10.1.2.50:8006`，不經過 Caddy。

第一個實際 backend 是 Type AI Platform。它使用 node `pve` 上既有 VM 109（`ub-26-4-srv-docker`）建立 full clone，來源 VM 保持不變。新 VM 接入私有 bridge，專案原始碼、Docker data-root 與應用持久資料均放在 `/srv` 下可用空間最大的適用 filesystem。專案來源為使用者指定的 Type AI Platform Git repository。

部署環境檔必須以 repository-local、已被 Git 忽略的 `.secrets` hierarchy 內 backend 環境資料為依據。秘密不得出現在 Git、ticket、log 或驗收輸出中。若缺少必要值，實作者只能回報缺少的 key 名稱，標示 `[HUMAN ACTION]` 並等待使用者提供或完成操作。

## User Stories

1. As a VPN user, I want to use the existing FortiClient connection, so that I do not need to install or operate a second VPN client.
2. As a VPN user, I want each internal website to have a memorable hostname, so that I do not need to remember IP addresses and ports.
3. As a VPN user, I want internal hostnames to resolve automatically after connecting to the VPN, so that I do not need to edit my local `hosts` file.
4. As a VPN user, I want browsers to trust each internal website's HTTPS certificate, so that I do not receive certificate warnings.
5. As a VPN user, I want different website hostnames to reach the correct applications even though they share `10.1.2.57`, so that all required sites remain independently usable.
6. As a VPN user, I want HTTP requests to redirect to HTTPS, so that credentials and application traffic are not sent in plaintext.
7. As a VPN user, I want common reverse-proxied features such as WebSocket connections to continue working, so that interactive applications behave normally.
8. As a VPN user, I want unknown hostnames to be rejected, so that I am never sent to an unrelated default application.
9. As a VPN user, I want internal websites to be unreachable when I am not connected to the approved VPN, so that they remain internal services.
10. As a service owner, I want each VM or LXC to have its own private IP, so that services can be isolated and addressed consistently.
11. As a service owner, I want different guests to reuse the same local service ports, so that applications do not require arbitrary port remapping.
12. As a service owner, I want to add a website by declaring its hostname and backend, so that onboarding does not consume another `10.1.2.x` address.
13. As a service owner, I want the original client protocol and address metadata to be forwarded safely, so that applications can generate correct URLs and audit requests.
14. As a service owner, I want backend access limited to the Edge VM and explicitly approved peers, so that a compromised VPN account cannot directly probe applications.
15. As a guest administrator, I want private guests to download operating-system and application updates, so that they can remain patched without receiving routable corporate IPs.
16. As a guest administrator, I want guest outbound access governed by firewall policy, so that private guests cannot freely access management systems.
17. As a PVE administrator, I want the existing `10.1.2.50:8006` management path to remain unchanged, so that deployment does not move or proxy the hypervisor management plane.
18. As a PVE administrator, I want the private bridge disconnected from physical NICs, so that private guest traffic is not accidentally exposed at Layer 2.
19. As a PVE administrator, I want the PVE host to have no IP on the private guest subnet, so that the backend network does not create another direct management surface on the hypervisor.
20. As a PVE administrator, I want network changes applied only when out-of-band recovery is available, so that a configuration error cannot permanently remove remote management access.
21. As a network administrator, I want `10.1.2.57` formally reserved and excluded from DHCP, so that the Edge VM never encounters an address conflict.
22. As a network administrator, I want the switch and NAC policy to explicitly permit the Edge VM MAC address, so that bridged guest networking works without bypassing port security.
23. As a network administrator, I want FortiGate to permit only the required VPN groups and source pools to reach `10.1.2.57:80/443`, so that the website entrance follows existing access policy.
24. As a network administrator, I want the application DNS suffix sent through VPN split DNS, so that internal queries use the approved DNS servers while unrelated DNS behavior remains unchanged.
25. As a DNS administrator, I want internal website records to point to `10.1.2.57`, so that no private backend addresses need to be published to clients.
26. As a DNS administrator, I want public DNS to expose only the records required for ACME validation, so that internal address records are not unnecessarily published.
27. As a security administrator, I want all Edge VM input and forwarding chains to default to deny, so that only explicitly allowed flows are possible.
28. As a security administrator, I want DNS API credentials scoped to the minimum required records, so that compromise of the Edge VM cannot modify unrelated DNS data.
29. As a security administrator, I want backend applications to trust proxy headers only from the Edge VM, so that clients cannot spoof identity or source information.
30. As a security administrator, I want upstream TLS verification enabled whenever TLS is used to a backend, so that backend encryption is not weakened by disabling certificate validation.
31. As an operator, I want Caddy and firewall configuration validated before reload, so that an invalid change does not interrupt every website.
32. As an operator, I want Edge VM services and networking to start automatically after reboot, so that a host restart does not require manual recovery.
33. As an operator, I want health checks for DNS, HTTPS, backend routing and certificate expiry, so that failures are detected before users report them.
34. As an operator, I want Edge VM configuration and secrets backed up through approved secure mechanisms, so that the entrance can be restored after failure.
35. As an operator, I want a documented restore and reboot verification procedure, so that recoverability is demonstrated rather than assumed.
36. As a maintainer, I want the architecture to use the minimum necessary components, so that routine changes do not require expertise in overlapping VPN and proxy systems.
37. As a maintainer, I want site routing to remain explicit, so that each hostname has an auditable backend destination.
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
- `10.1.2.50:8006` remains the PVE management endpoint and is not proxied, renamed or exposed through the website DNS suffix.
- `10.1.2.57` is the only `10.1.2.x` address allocated to the website platform and belongs to a dedicated Edge VM.
- The Edge VM is a regular VM rather than an LXC because it forms the network and firewall boundary and must control forwarding and NAT without container capability exceptions.
- The Type AI Platform backend and the Edge VM are separate machines. Application containers never share the network-boundary VM.
- The Type AI Platform backend is created as a full clone of VM 109 (`ub-26-4-srv-docker`) on node `pve`. A linked clone is not used, and the source VM's disks, configuration, power state and network settings are not modified without a separately approved human action.
- After cloning, the new Type AI Platform VM is configured with 8 virtual CPU cores and 64 GiB RAM (`65536` MiB). These resource changes apply only to the clone; memory ballooning is disabled so the assigned capacity remains predictable.
- The cloned backend receives the first application address in the private allocation range and has no `10.1.2.x` address.
- The application is checked out from `https://source.mobagel.com/type-ai-platform/type-ai-platform.git`. The deployed revision is recorded for audit and rollback. The repository is hosted on a sign-in-protected GitLab instance; if no approved non-interactive credential is already available, cloning pauses under `[HUMAN ACTION]`.
- Before deployment, the implementation enumerates filesystems mounted at or below `/srv` and chooses the suitable filesystem with the greatest available capacity. If projected deployment would leave less than twenty percent free space, deployment stops with `[HUMAN ACTION]` rather than selecting the root filesystem or deleting data.
- The project checkout, Docker data-root, bind-mounted application state and named-volume backing data for this dedicated clone are all located below the selected `/srv` filesystem. Existing unrelated data is not moved or deleted.
- Before creating or changing a deployment `.env`, implementation reads the corresponding backend environment source in the ignored `.secrets` hierarchy and compares it with the application's required environment schema or example.
- Secret values are never printed, copied into ticket text, committed, or included in test artifacts. When a required key is absent, only its key name is reported and work pauses under `[HUMAN ACTION]`; values are never invented.
- Any step that needs the user's credentials, infrastructure approval, FortiGate or DNS administration, PVE console access, destructive confirmation or missing secret is marked `[HUMAN ACTION]`. The agent must stop at that gate until the user explicitly confirms completion.
- The Edge VM uses two NICs: a front NIC on the existing PVE physical bridge and a back NIC on a new private bridge.
- The private bridge has no physical bridge ports. The PVE host has no IP address on it.
- The default private address plan is `172.23.57.0/24`, with `172.23.57.1` reserved for the Edge VM. Backend addresses begin at `172.23.57.11`; lower addresses remain reserved for infrastructure.
- Before any network mutation, implementation must check that `172.23.57.0/24` does not overlap corporate routes, VPN client networks, container networks or site-to-site networks. An overlap is a blocking condition requiring the spec's address plan to be amended; the implementation must not silently choose another subnet.
- The Edge VM front prefix, default gateway and DNS resolver are read from the existing approved `10.1.2.0/24` network configuration. They are environment inputs, not invented defaults.
- The network administrator must confirm that `10.1.2.57` is reserved outside DHCP and that the switch or NAC permits the Edge VM's MAC address. Failure of either check blocks deployment.
- Caddy is the sole HTTP/HTTPS entrance and TLS terminator. Nginx, HAProxy, Traefik and a GUI proxy manager are not added.
- Each published website has an explicit Caddy hostname-to-backend mapping. There is no automatic discovery layer or separate routing manifest.
- Website ingress is reverse proxy traffic, not DNAT. Caddy connects to each backend from its private interface.
- Caddy must reject an unrecognised hostname instead of selecting a default backend.
- Caddy forwards standard proxy metadata. Backends that consume it trust it only from the Edge VM private address.
- Edge-to-backend HTTP is permitted on the isolated subnet where the service threat model allows it. Services requiring encrypted backend transport use a verifiable certificate and trust pool; TLS verification may not be disabled.
- nftables is the firewall and NAT implementation on the Edge VM. No second firewall appliance is introduced in the initial architecture.
- Edge VM input and forward policy default to deny. Input permits loopback, required ICMP, established or related traffic, approved administrative SSH, and approved VPN sources to TCP 80/443.
- Front-to-private forwarding is denied. Website traffic terminates at Caddy rather than being generally forwarded into the guest subnet.
- Private guests may initiate only approved outbound traffic with established or related return traffic. Source NAT masquerades approved guest traffic as `10.1.2.57`.
- Each backend's PVE or guest firewall permits its web port from the Edge VM private address and denies unneeded inbound and east-west traffic.
- FortiGate policy permits only approved VPN groups and source pools to reach `10.1.2.57` on TCP 80/443. This feature does not broaden ordinary user access to `10.1.2.50:8006`.
- VPN clients receive no route for `172.23.57.0/24`. Direct backend access is intentionally unavailable.
- Internal DNS uses a subdomain of an organisation-owned registered domain. Site records, or a controlled wildcard record, resolve to `10.1.2.57` only through the internal DNS view.
- FortiClient split DNS sends queries for the chosen application suffix to the internal DNS servers. Users do not maintain local host mappings.
- Public DNS does not need an A or AAAA record for the private website entrance. It provides only the DNS-01 validation records required by the certificate authority.
- Publicly trusted HTTPS certificates are issued and renewed through ACME DNS-01. DNS credentials are narrowly scoped; delegation of the ACME challenge zone is preferred when supported.
- Caddy's internal CA and direct HTTPS access by `10.1.2.57` are not used as production entry points.
- Certificate issuance is tested against the certificate authority's staging environment before production issuance.
- DNS API tokens, ACME account keys and TLS private keys are secrets. They are never committed to the repository and are handled through the selected secure deployment mechanism.
- Edge VM networking, nftables and Caddy must be enabled for automatic startup. Configuration reloads occur only after syntax validation.
- Backups include all configuration needed to reconstruct the Edge VM and protected copies of required secrets. Restore and reboot behavior must be tested.
- The combined router and proxy role is an accepted single point of failure for the initial one-PVE, one-IP deployment. Splitting these roles is deferred until scale or threat requirements justify the extra boundary.

## Testing Decisions

- The primary test seam is one black-box client boundary representing a user already connected to FortiClient. Tests assert observable DNS, TLS, HTTP routing and isolation behavior without inspecting Caddy or nftables internals.
- A valid application hostname must resolve through VPN split DNS to `10.1.2.57`.
- At least two distinct hostnames sharing `10.1.2.57` must return distinguishable responses from their intended private backends.
- HTTP must redirect to HTTPS, and HTTPS must present a publicly trusted, hostname-matching certificate.
- A hostname absent from the site configuration must not reach any backend.
- A VPN client must have no route to the private subnet and must fail to connect directly to backend addresses.
- A VPN user in the ordinary website access group must not gain access to the PVE management endpoint.
- A backend guest must reach approved update destinations through the Edge VM's NAT path.
- A backend guest must not initiate access to the PVE management endpoint or unapproved east-west destinations.
- A backend web port must accept the Edge VM private source and reject unapproved sources.
- Proxy metadata behavior must be tested at the application boundary, including protection against a client-supplied spoofed forwarding header.
- If an HTTPS backend is used, the test must fail when its certificate is untrusted or mismatched; disabling verification is not an acceptable fix.
- Caddy and nftables configuration validation commands are secondary preflight checks, not substitutes for black-box behavior tests.
- The Edge VM and PVE host must be rebooted during acceptance testing. DNS resolution, firewall policy, NAT and every published hostname must recover automatically.
- A restore exercise must rebuild or recover the Edge entrance from its documented backup and reproduce the same black-box results.
- Tests must also be executed without the approved VPN path. Internal application hostnames and `10.1.2.57` website services must not become publicly reachable.
- Existing tests provide no prior art because the repository currently contains documentation only. The first implementation should establish the black-box acceptance harness as the single reusable seam for later site additions.
- VM 109's configuration, disks, power state and network identity must match their pre-clone observations after the backend clone is created.
- The cloned backend must report 8 available virtual CPU cores and 64 GiB configured memory, while VM 109 retains its original CPU and memory configuration.
- The backend must report the expected source repository and record the deployed revision without exposing repository credentials.
- Storage acceptance verifies that the checkout, Docker data-root and persistent application data resolve below the selected `/srv` filesystem and that at least twenty percent free space remains after deployment.
- The application must first pass a private-backend health check before DNS or Caddy publishes it to VPN users.
- Secret-safety acceptance verifies that environment files and secret values are absent from Git changes and captured logs. Tests may report key names, presence and validation status, but never values.
- Any acceptance step requiring user action must remain pending while its `[HUMAN ACTION]` gate is unconfirmed; it may not be marked successful based on an assumption.

## Out of Scope

- Installing or operating WireGuard or another second client VPN.
- Giving VPN clients direct routed access to `172.23.57.0/24`.
- Publishing SSH, RDP, databases or arbitrary non-HTTP protocols through hostname-based HTTP routing.
- Exposing any website to the public Internet.
- Proxying, renaming or otherwise changing the PVE management endpoint.
- High availability, VRRP, multiple PVE nodes, multiple Edge VMs or automatic IP failover.
- Splitting the initial Edge VM into separate firewall/router and reverse-proxy appliances.
- Kubernetes, Docker label discovery, Traefik or dynamic service discovery.
- An automatic DHCP or IPAM service for backend servers; backend addresses remain explicitly assigned.
- Selecting or purchasing the organisation's registered domain or migrating its authoritative DNS provider.
- Application-level SSO, authorisation, WAF rules or changes to backend application business logic.
- Granting general Internet access to private guests beyond the outbound flows approved during deployment.
- Silently substituting a different private subnet when the selected CIDR conflicts with the environment.
- Modifying, repurposing or deleting VM 109 after taking the approved full clone.
- Placing Type AI Platform project data or Docker storage on the cloned VM's root filesystem when a suitable `/srv` filesystem is unavailable.
- Inventing missing environment values or copying secrets into tracked configuration.
- Performing a user-owned infrastructure or credential operation on the user's behalf when it has been marked `[HUMAN ACTION]`.

## Further Notes

- Deployment requires an out-of-band recovery path such as physical console, IPMI or iKVM before modifying PVE networking.
- The exact FortiOS version, VPN type, VPN client source pool, internal DNS servers, external prefix and gateway must be read from the live approved environment before generating final configuration. These values affect syntax and firewall matching but do not change the selected architecture.
- The actual application DNS suffix must be a subdomain of an organisation-owned registered domain and must support automated DNS-01 updates.
- The architecture accepts that the PVE host, Edge VM, FortiGate path, internal DNS and single entrance IP are single points of failure. WireGuard would not remove them.
- The accompanying architecture research records the primary sources behind the PVE bridge/NAT, FortiClient split DNS, Caddy reverse proxy, DNS-01 and WireGuard decisions.
- The `.secrets` directory exists locally, is ignored by Git and contains a backend environment source. Its values remain intentionally absent from this spec.
- The implementation must preserve unrelated existing `.gitignore` and `.secrets` changes.
