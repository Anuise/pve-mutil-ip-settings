# Demo 上線 entrance port 8082 與 `/srv` 儲存重整

Status: ready-for-agent

## Problem Statement

Demo（VM 103 `type-ai-platform-demo`）目前完全無法使用，而且處於一個不能自行脫離的狀態。

它的 Cloud-Init 仍設定 `10.1.2.57/24`，網卡掛在實體 bridge 上 —— 那正是 Edge 持有的對外位址。因此 Demo 一開機就會與 Edge 的入口位址衝突，打斷現行 UAT 的 `10.1.2.57:8081` 服務。目前唯一擋住這件事的是「它沒有設定開機自動啟動」，不是任何設計上的保護。這也讓 Demo 內部無法盤點：要查看它就得開機，開機就會撞。

同時，Demo 的資料放在 `/home/mobagel` 底下，與 UAT 已建立的 `/srv` 儲存慣例不一致。Demo 的 `/srv` 只有 20G，而它的 Docker 資料落在預設位置，沒有比照 UAT 把 Docker data-root、專案 checkout 與應用持久資料統一收攏到 `/srv` 之下。

使用者需要的是：只連既有 FortiClient VPN，就能以 `10.1.2.57:8082` 存取 Demo；Demo 成為一台正常的 private guest，不再持有對外位址、不再威脅 UAT 入口；其專案與應用資料落在 `/srv` 下，結構與 UAT 一致，且原始資料在驗收通過前不被刪除。

## Solution

Demo 轉為 private guest。網卡從實體 bridge 移到 private bridge，位址改為 `172.23.57.12`，以 Edge 為 default gateway。資源比照既有 spec 對 private guest 的要求調整為 8 vCPU 與 64 GiB RAM 並停用 ballooning。

網卡先移到 private bridge、之後才開機，是本方案的關鍵安全性質：private bridge 沒有實體 bridge port，所以即使 guest 內部殘留 `10.1.2.57`，該位址也只出現在私有橋接上，碰不到 Edge 的對外側。這讓「開機才能盤點」與「開機會撞 IP」的死結消解，且不需要事先猜測 guest 內部的網路設定。

guest 內部的網路設定以 `cloud-init clean` 後重新開機的方式重套，讓 Cloud-Init 依 PVE 的設定重寫網路。這會使整套 Cloud-Init 模組以 first boot 身分重跑，因此先把自動套件升級關閉，避免在一台跑著實際 Docker workload 的機器上觸發未經要求的升級；並在 clean 之前備份 guest 內由人工維護的設定，clean 之後逐項比對。進 guest 的操作走 qemu-guest-agent，它經 virtio-serial 以 root 執行，不需要網路也不需要本機密碼，因此不必為了救援而新建任何憑證。

Demo 的儲存比照 UAT。這裡要先破除一個前提：Docker 的「預設路徑」`/var/lib/docker` 本身就是 `vg_data` 上的 80G 專屬 logical volume，不是 OS 卷的一部分。所以這項工作不是把 Docker 搬離 OS 卷，而是**把同一顆 LV 的掛載點從 `/var/lib/docker` 改為 `/srv/platform`**，把原有 Docker 內容收進 `/srv/platform/docker`，並將 data-root 指向該處。因為 LV 沒換，內容隨 LV 一起移動，收進子目錄只是同檔案系統的 rename，不跨檔案系統、不需要額外空間。20G 的 `/srv` 保留，`/srv/platform` 掛在其下。理由與被拒的替代方案記於 ADR-0002。

`/home/mobagel` 底下的專案 checkout 與應用持久資料搬到 `/srv/platform` 下對應位置；家目錄本身保留原處不動。UAT 從未把家目錄搬進 `/srv`，「結構參考 UAT」指的是應用資料的擺放，不是家目錄的搬遷。

與 UAT 的差異已在盤點後具體化。UAT 當時是 0 containers、0 images 的空環境，Demo 是 3 containers、7 images、1 volume，共 65M，但全部 `Exited`、0 running。tutorial 的警告針對「有活的 workload、且內容需跨檔案系統複製」，這兩件在 Demo 皆不成立，因此照 tutorial 的安全順序執行是可行的；額外要求是搬移前後逐項比對 images、containers 與 volumes 的數量與清單，並具備逐步 rollback。

搬移採複製、驗證、延後刪除：以保留屬性的方式複製，逐檔 SHA-256 比對來源與目標，來源保留不刪，等 `10.1.2.57:8082` 服務驗收通過後才移除。Demo 目前沒有任何快照，因此在改動任何設定前先建立一個停機狀態的快照，作為整項工作唯一的回復點。

Edge 新增一個 entrance port：`8082` DNAT 到 `172.23.57.12:443`，並依既有慣例同時建立對應的 forward 放行與來源 NAT，使 Demo 只信任 Edge 的私有側位址。`8082` 原本在既有 spec 中是臨時驗收 port，本功能將其語意改為常駐 entrance port，理由與代價記錄於 ADR-0001。Demo 舊有的對外直連（實體 bridge 上的 `10.1.2.57` 直接提供 80/443）整組移除。`443` 由什麼服務提供已依盤點決定：盤點顯示 Demo 目前沒有任何 listener，而且應用本體從未部署 —— 只有手動起的 nginx、Keycloak、PostgreSQL 三顆容器，全部 `Exited`，repo 沒有它們的定義。因此 `443` 由 Demo stack 的 nginx 提供，其定義改寫成 repo 追蹤的 compose，TLS 自簽憑證放具名 volume 並提供 `/healthz`，比照 UAT；而部署 Type AI Platform Demo 應用本體不屬於本 spec。`8082` 的驗收語意因此是「可達、TLS、回應可與 UAT 區分」，不是「Demo 應用可用」。理由與代價記於 ADR-0003。

VM 105 一併改名為 `type-ai-platform-uat`，使機器名稱與 `CONTEXT.md` 的環境詞彙一致。這是純標籤變更，不需重啟、不動網路與執行狀態。

## User Stories

1. As a VPN user, I want to reach Demo at `10.1.2.57:8082`, so that I can use the demo environment without a second VPN or any DNS setup.
2. As a VPN user, I want Demo and UAT to be reachable at different entrance ports on the same address, so that both environments stay independently usable.
3. As a VPN user, I want the existing UAT entrance at `10.1.2.57:8081` to keep working unchanged throughout this work, so that publishing Demo never costs me UAT.
4. As a VPN user, I want unassigned entrance ports to keep failing closed, so that a mistyped port never lands me on an unrelated application.
5. As a VPN user, I want HTTP and WebSocket traffic to pass transparently through the new entrance port, so that interactive parts of Demo behave normally.
6. As a VPN user, I accept that Demo is reached over an IP and port without publicly trusted TLS, and that a self-signed certificate may require one browser warning bypass.
7. As a VPN user, I want Demo unreachable when I am not connected to the approved VPN, so that it remains an internal service.
8. As a VPN user, I want no route to the private guest subnet, so that I cannot reach Demo except through the Edge entrance port.
9. As a PVE administrator, I want Demo to stop holding the Edge's external address, so that starting Demo can never break the UAT entrance again.
10. As a PVE administrator, I want Demo's network moved to the private bridge before it is ever started, so that a stale internal address cannot collide with the Edge.
11. As a PVE administrator, I want Demo to have no `10.1.2.x` address at all once this work completes, so that the single-entrance design is not quietly violated.
12. As a PVE administrator, I want the existing management endpoint to remain unchanged and unproxied, so that this work does not touch the hypervisor management plane.
13. As a PVE administrator, I want UAT's configuration, disks, power state and network identity untouched apart from its name, so that publishing Demo cannot damage the working environment.
14. As a PVE administrator, I want the template VM used to create both environments left unmodified, so that the approved baseline stays reusable.
15. As a PVE administrator, I want Demo's machine name and the project's environment vocabulary to agree, so that documentation and the hypervisor do not describe the same machine differently.
16. As an operator, I want a restore point created before the first configuration change, so that every subsequent step is reversible.
17. As an operator, I want to know that Demo currently has no snapshot at all, so that the restore point is understood as newly created rather than assumed to exist.
18. As an operator, I want each step to read back the resulting state before the next step runs, so that a failed step stops the sequence instead of compounding.
19. As an operator, I want the new entrance port recorded with its private guest address and service port, so that the port map stays auditable.
20. As an operator, I want port collisions detected before firewall rules are applied, so that Demo cannot silently displace UAT.
21. As an operator, I want firewall configuration validated before it is loaded, so that an invalid change cannot interrupt every service at once.
22. As an operator, I want the previous firewall configuration backed up before the new one is installed, so that a failed change can be rolled back to a known-good file.
23. As a guest administrator, I want to enter Demo without a local password or working network, so that recovery does not depend on a credential that may not exist.
24. As a guest administrator, I want automatic package upgrades disabled before the Cloud-Init state is reset, so that resetting the network does not also upgrade Docker or the operating system.
25. As a guest administrator, I want human-maintained files backed up before the Cloud-Init state is reset, so that anything Cloud-Init rewrites can be restored.
26. As a guest administrator, I want the backed-up files compared against their post-reset versions, so that silent overwrites are detected rather than discovered later.
27. As a guest administrator, I want the hand-added filesystem mount for the large data volume preserved across the reset, so that existing data stays mounted at the expected path.
28. As a guest administrator, I want any SSH keys not present in the hypervisor's key field identified before the reset, so that access is not lost when Cloud-Init rewrites the authorized key set.
29. As a guest administrator, I want Demo's actual address verified from inside the guest after the reset, so that the change is proven rather than assumed from the hypervisor's configuration.
30. As a guest administrator, I want Demo to reach approved update destinations through the Edge's outbound NAT, so that it can stay patched without a routable corporate address.
31. As a guest administrator, I want Demo unable to initiate access to the management endpoint or unapproved east-west destinations, so that a private guest cannot probe infrastructure.
32. As a storage administrator, I want Demo's Docker data-root, project checkout and persistent application data placed below `/srv`, so that the layout matches UAT and the root filesystem is not consumed.
33. As a storage administrator, I want the existing large logical volume reused for `/srv/platform` rather than data forced into the small existing `/srv`, so that capacity is adequate.
34. As a storage administrator, I want capacity measured before the migration is planned, so that the target is known to fit before anything is moved.
35. As a storage administrator, I want the migration to stop rather than proceed if the target would be left with less than twenty percent free space.
36. As a storage administrator, I want existing Docker content preserved when the volume is remounted, so that images and containers are not lost to a mount-point change.
37. As a storage administrator, I want Demo's non-empty Docker state treated as a migration with its own plan and rollback, so that the empty-environment procedure written for UAT is not applied blindly.
38. As a service owner, I want project and application data moved out of the home directory, so that Demo's data lives where the project's conventions say it should.
39. As a service owner, I want the home directory itself left in place, so that shell configuration, SSH authorization and user-level services keep working.
40. As a service owner, I want data copied and verified rather than moved, so that a failed migration cannot destroy the only copy.
41. As a service owner, I want every migrated file's checksum compared between source and target, so that completeness is proven rather than inferred from the copy tool's exit status.
42. As a service owner, I want the original data retained until the entrance port passes acceptance, so that configuration referencing old paths can be diagnosed against a live source.
43. As a service owner, I want configuration referencing the old paths identified before the source is deleted, so that deletion does not break the service later.
44. As a service owner, I want Demo's old direct external listeners removed, so that the environment is reached only through the audited entrance port.
45. As a security administrator, I want the Edge's default-deny input and forward policy preserved, so that adding an entrance port does not widen the firewall beyond one tuple.
46. As a security administrator, I want the new forwarding rule limited to the approved VPN source, the one private guest address and the one translated port, so that the addition is least-privilege.
47. As a security administrator, I want Demo to see the Edge's private address as the traffic source, so that it does not need to trust client-supplied proxy headers.
48. As a security administrator, I want no new secret, certificate authority, DNS token or ACME key introduced, so that the attack surface does not grow.
49. As a security administrator, I want no new credential created to enable recovery, so that this work does not leave a password behind as a side effect.
50. As a security administrator, I want the promotion of a temporary validation port to a permanent entrance recorded with its consequences, so that the loss of a verified spare probe port is a known trade-off.
51. As a network administrator, I want the new entrance port empirically verified from the currently approved VPN session, so that reachability is demonstrated on the real path.
52. As a network administrator, I want it understood that the empirical check proves point-in-time reachability only, so that policy scope is not inferred from a successful connection.
53. As a network administrator, I want the private address confirmed unused before assignment, so that Demo does not collide with the Edge or UAT.
54. As a maintainer, I want the port map, allocation table and firewall configuration in the repository updated together, so that the documented state matches the running state.
55. As a maintainer, I want the existing spec's description of the temporary validation port corrected, so that a future reader is not misled about the port's status.
56. As a maintainer, I want the environment vocabulary applied consistently in documentation, so that one word does not describe three different things.
57. As a user, I want every action requiring my credentials, approval or manual infrastructure access marked `[HUMAN ACTION]`, so that the work pauses until I explicitly complete it.
58. As a user, I want the hypervisor-side steps delivered as a script I run myself, so that I retain control of irreversible infrastructure changes.
59. As a user, I want the work split so that measurement happens before the migration is designed, so that decisions about capacity and layout rest on real numbers.
60. As an operator, I want automatic startup enabled only after acceptance passes, so that a reboot cannot bring back a broken or conflicting configuration.
61. As an auditor, I want the Edge's access and rejection logs to cover the new entrance port, so that Demo traffic and routing failures can be investigated.
62. As an auditor, I want management access and Demo access to remain separate, so that publishing an environment never grants hypervisor privileges.

## Implementation Decisions

- The work is split into two phases with a decision point between them. Phase 1 establishes a safe state and produces measurements. Phase 2 performs the storage migration and publishes the entrance port. Phase 2's detailed decisions are deliberately not fixed in this spec because they depend on Phase 1's measurements.
- Hypervisor-side steps are delivered as an interactive script the user runs themselves. The agent does not execute hypervisor mutations. Each step reads back the resulting state and stops the sequence on mismatch rather than continuing.
- Demo's network interface is moved to the private bridge **before** Demo is ever started. This is the ordering that makes the first boot safe: the private bridge has no physical bridge port, so a stale internal address cannot reach the Edge's external side. No assumption is made about what the guest's internal configuration currently holds.
- Demo's Cloud-Init address becomes `172.23.57.12/24` with the Edge's private address as gateway. This address was confirmed unused: the private bridge carries only the Edge and UAT.
- Demo is configured with 8 virtual CPU cores and 64 GiB RAM with ballooning disabled, matching the existing requirement for a private guest of this platform. Demo already has 8 cores; memory and ballooning change.
- Automatic package upgrade is disabled on Demo before the Cloud-Init state is reset. Demo's configuration currently omits this setting, and the hypervisor's default enables it, so resetting Cloud-Init would otherwise trigger an unrequested upgrade on a machine running a live Docker workload. UAT already has it disabled; Demo is brought in line.
- Guest-internal network configuration is re-applied by resetting Cloud-Init state and rebooting, so that Cloud-Init rewrites the network from the hypervisor's configuration. The user chose this over hand-editing the network configuration file. The known cost is that all Cloud-Init modules re-run as a first boot; that cost is contained by disabling the automatic upgrade and by taking backups first.
- All guest-internal operations go through the guest agent, which runs as root over a virtual serial channel and requires neither network nor a local password. Demo has no Cloud-Init password set, so the hypervisor console alone would not be a dependable recovery path; the guest agent removes that dependency and avoids creating a credential. The console remains the fallback if the guest agent is unavailable.
- Before the Cloud-Init reset, the guest's authorized SSH keys, filesystem mount table and network configuration directory are backed up. After the reset they are compared item by item. The mount table matters specifically because the large data volume's mount was added by hand and is not managed by Cloud-Init.
- Any authorized SSH key present in the guest but absent from the hypervisor's key field is identified before the reset, because Cloud-Init rewrites the authorized key set from that field.
- A snapshot of Demo is taken in the stopped state, before any configuration change. Demo currently has no snapshot; this is the only restore point for the whole effort. The stopped state is used so the snapshot carries no memory image.
- Demo's `/var/lib/docker` is already a dedicated 80G logical volume in `vg_data`, not part of the OS volume group. The storage work is therefore a mount-point change for that same volume, not a relocation of data between volumes: the volume is remounted at `/srv/platform`, the existing Docker tree is renamed into `/srv/platform/docker` within the same filesystem, and Docker's data-root points there. The small existing 20G `/srv` volume remains, with `/srv/platform` mounted below it. Growing the 20G volume instead, and using the 500G model cache volume, were considered and rejected in ADR-0002.
- That volume's mount options stay `defaults`. The `nodev,nosuid` options used for `/var` must not be copied onto it: Docker creates device nodes and setuid files below its data-root.
- After the unmount, `/var/lib/docker` becomes an empty directory on the `/var` volume and is retained. It is verified empty first. If content appears there it was shadowed by the earlier mount, and the sequence stops for a human decision rather than deleting or merging it.
- Demo's Docker state is not empty — 3 containers, 7 images, 1 volume, 65M — but nothing is running. The tutorial's warning addresses a live workload whose content must be copied across filesystems, and neither condition holds here, so the tutorial's safe ordering is followed rather than replaced. The addition is a recorded inventory of images, containers and volumes before the stop, compared item by item after the start.
- The stop ordering is fixed: record the pre-state outside the volume being moved; stop `docker.socket` before `docker.service` and `containerd.service`, because socket activation would otherwise restart the daemon; back up `/etc/fstab` and `/etc/docker/daemon.json`; change the fstab mount point; unmount; mount `/srv/platform`; rename the Docker tree into `docker/`; create the sibling directories; merge `data-root` into `daemon.json` without overwriting the existing log settings; then start `containerd` and `docker` and read back data-root, object counts and free space. Each step has a named reverse action, so the whole sequence is reversible without the snapshot.
- The snapshot `pre-demo-entrance-20260813` is the last resort, not the primary rollback. It predates the private bridge move and the Cloud-Init reset, so restoring it discards those as well.
- Daemon health after the remount is proven with a throwaway container from an image that already exists, not by starting the three retained containers. They were `Exited` before the migration, and the storage work does not change workload state.
- Exactly one thing moves out of `/home/mobagel`: the `type-ai-platform-demo` checkout, 694M, to `/srv/platform/type-ai-platform-demo`. It keeps its own directory name instead of being renamed to UAT's `/srv/platform/type-ai-platform`, because it is a different checkout and a shared path would imply a shared revision. `/srv/platform/app-data` is created empty to match UAT's shape; Demo's persistent application data currently lives inside a Docker volume and travels with the data-root.
- Developer tooling and unrelated workspaces stay in `/home/mobagel`: `.venvs` (465M, a derived environment with its own paths baked into its scripts and cheap to rebuild), `.claude` (4.5G), `.vscode-server` (1.5G), `.cache` (665M), `.local` and `.npm` (319M together), and `rfp-workspace` (19M, unrelated to Demo's application).
- Retained containers are not recreated in order to gain restart behavior; `docker update --restart unless-stopped` is used instead. `typeai-demo-pg` must never be recreated: the single 66.65MB anonymous volume holds its data, and a recreated container would be given a new empty volume. Two containers are recreated: Keycloak, because its bind mount source path changes; and the nginx proxy, because it must serve TLS on `443` from a certificate in a named volume and expose `/healthz`, none of which the hand-started container has. Neither holds a volume, so recreation loses nothing, and both definitions are captured with `docker inspect` before it happens.
- Rewriting the one configuration that references an old absolute path — the Keycloak realm import bind mount — belongs with the stack definition work rather than with the data copy, because that rewrite is a container recreation.
- Only project checkout and persistent application data move out of `/home/mobagel`. The home directory itself stays where it is. UAT never relocated a home directory; "match UAT's structure" refers to where application data lives, not to moving the home directory. Relocating it would touch shell configuration, SSH authorization and user-level services with no precedent to follow.
- Migration is copy, verify, then delayed delete. Copying preserves attributes, hard links and sparseness; verification compares per-file SHA-256 between source and target. The source is retained until the entrance port passes acceptance, because configuration referencing old absolute paths only surfaces once the service runs.
- Configuration referencing the old paths — container bind mounts, service units, environment files — is enumerated before the source is deleted.
- Projected free space was computed from Phase 1's measurements rather than assumed. `/srv/platform` holds about 0.76G of 79G usable once both the Docker tree and the checkout are there, leaving roughly 98% free, so the twenty-percent stop clause is not triggered. `/home` stays at 58% while the source is retained and falls to about 50% once it is deleted. The clause itself stands: if a projection ever falls below twenty percent, the migration stops as a `[HUMAN ACTION]` rather than proceeding or deleting data to make room.
- Three facts inside the guest could not be read without the user's credentials, so each is resolved by a read-only preflight before the stack definition work starts, and both branches are decided in advance. Whether the three containers were created by Compose or by hand, and whether the checkout already holds a Demo deployment definition: adopt an existing definition if there is one, otherwise generate one from `docker inspect`. Whether nginx already has a TLS certificate and where it lives: reuse it and record its fingerprint the way UAT does, otherwise generate a self-signed certificate into a named volume. Whether Keycloak's realm state lives in PostgreSQL or inside the container: recreating the container is safe if the state is in PostgreSQL, otherwise the realm is exported first, and the step stops as a `[HUMAN ACTION]` if it cannot be exported.
- The Edge publishes Demo as entrance port `8082` translated to Demo's private address on port `443`. Following the established pattern, three matching rules are added together: a forward permit for the approved VPN source, destination and translated port; the destination NAT from the entrance port; and a source NAT to the Edge's private address so Demo only ever sees the Edge as the source.
- `8082` was previously designated a temporary validation port. It becomes a permanent entrance port. It was chosen over allocating a fresh port because it is one of only two ports empirically proven to traverse the current VPN path, and no administrator is available to adjust policy for an unproven port. Rationale and consequences are recorded in ADR-0001; the existing spec's description of the port is corrected as part of this work.
- Demo's previous direct external listeners on the physical bridge are removed; Demo is reached only through the entrance port.
- Port `443` is served by the Demo stack's nginx, whose definition becomes a repository-tracked Compose file with a self-signed certificate in a named volume and a `/healthz` endpoint, matching UAT so that one runbook covers both environments. Phase 1 found no listener at all and no deployed application: only three hand-started containers, all `Exited`, with no definition in the repository and no restart policy. Deploying the Type AI Platform Demo application itself — building images, creating secrets, running database migrations, importing the Keycloak realm — is not part of this spec. The consequence is that `8082`'s acceptance means reachable, TLS-terminated and distinguishable from UAT, not "the Demo application works". Recorded in ADR-0003.
- Firewall changes are validated before being loaded, and the previous configuration is backed up first. The repository's tracked ruleset, the runbook allocation table and the port map are updated in the same change as the running configuration.
- Automatic startup for Demo is enabled only after acceptance passes. Enabling it earlier would let a hypervisor reboot restore a conflicting or unverified configuration.
- UAT's VM is renamed to `type-ai-platform-uat`. This is a label change requiring no restart and touching neither networking nor power state. Documentation referring to the old machine name is updated in the same change. The user's local SSH client alias is outside this repository and is not modified.
- Documentation uses the environment vocabulary from `CONTEXT.md`: Edge, private guest, private bridge, entrance port, UAT, Demo. The previously overloaded term is retired.
- No DNS, hostname routing, publicly trusted certificate, certificate authority, ACME key or second VPN is introduced. No new credential is created; where one would be required, the step stops as a `[HUMAN ACTION]`.
- Any step needing the user's credentials, infrastructure approval, destructive confirmation or a missing secret is marked `[HUMAN ACTION]` and pauses until the user confirms completion.

## Testing Decisions

- Good tests here assert observable behavior at a boundary a real user occupies. They do not inspect firewall internals, mount tables as a proxy for behavior, or the copy tool's exit status. Firewall validation commands and configuration read-backs are preflight checks, not substitutes for behavior tests.
- The primary seam is the existing one and no new seam is introduced: **a single black-box client boundary representing a user already connected to the approved VPN**. This is the seam the platform's existing spec established, and it is reused unchanged so that adding environments does not multiply test surfaces.
- Prior art for this seam is the existing acceptance set for the UAT entrance: reachability probes against each allocated port from the approved VPN session, an application response check through the entrance, a direct-private-access deny check, an unallocated-port deny check, and an off-VPN reachability check. Demo's acceptance is the same set pointed at the new port.
- Through this seam: `10.1.2.57:8082` must return Demo's response; `10.1.2.57:8081` must continue returning UAT's response, distinguishable from Demo's; an unallocated port must fail closed and reach no environment; Demo's private address must be unreachable directly from a VPN client; and the allocated ports must not be reachable without the approved VPN path.
- Each probe is recorded with source address, destination and result, repeated from the same approved VPN client that established the original empirical gate.
- The management endpoint must be verified unchanged and unproxied after the entrance port is added.
- "Demo's response" through that seam means the nginx endpoint's TLS-terminated response, distinguishable from UAT's, per ADR-0003. It does not mean a working Demo application, and no acceptance check asserts application behavior.
- The secondary seam is also an existing one: **in-guest verification of storage placement and data integrity**, as used for UAT's storage acceptance. Through it: Docker's data-root must resolve to `/srv/platform/docker`, the checkout to `/srv/platform/type-ai-platform-demo`; the image, container and volume inventory recorded before the stop must match after the start; and at least twenty percent free space must remain.
- Migration completeness is asserted by per-file SHA-256 comparison between source and target, following the method already used and recorded for this machine's earlier data volume migration. A successful copy exit status is not accepted as evidence.
- The Cloud-Init reset is verified by reading Demo's actual address from inside the guest, not by reading the hypervisor's configuration back. The backed-up authorized keys, mount table and network configuration are compared against their post-reset state, and the large data volume must remain mounted at its expected path with its files present.
- Demo must reach approved outbound destinations through the Edge, and must fail to initiate access to the management endpoint.
- Demo must observe the Edge's private address as the connection source, confirming the source NAT rather than assuming it.
- Both Demo and the Edge are rebooted during acceptance. Every allocated entrance port, the firewall policy, the mounts and Docker's data-root must recover without manual intervention. Automatic startup is enabled only after this passes.
- Deletion of the migrated source is itself gated on acceptance passing; until then the retained source is available for comparison.
- The repository contains no automated test suite; acceptance is a recorded manual procedure through the two seams above, consistent with how the platform's existing acceptance was captured.

## Out of Scope

- Changing UAT's configuration, disks, power state, network identity or deployed revision. Only its machine name changes.
- Modifying or repurposing the template VM the environments were cloned from.
- Moving `/home/mobagel` itself, or changing the user's home directory path, shell configuration or user-level services.
- Deleting the migrated source data before the entrance port passes acceptance.
- Deleting or reorganising data unrelated to Demo's project and application state.
- Deploying the Type AI Platform Demo application: building frontend or backend images, creating application secrets, running database migrations, importing the Keycloak realm, or populating the model cache. See ADR-0003.
- Moving `.venvs`, `.claude`, `.vscode-server`, `.cache`, `.local`, `.npm` or `rfp-workspace` out of `/home/mobagel`.
- Recreating `typeai-demo-pg`, or otherwise replacing the anonymous Docker volume that holds its data.
- Changing `/var/lib/containerd` or the model cache volume `/data/model-cache`.
- Upgrading Demo's operating system, Docker or application packages. Any upgrade is separate, deliberate work.
- Creating a Cloud-Init password or any other new credential for Demo.
- Allocating entrance ports beyond `8082`, or creating port ranges or catch-all destinations.
- Giving VPN clients a route to the private guest subnet.
- Publishing SSH, RDP, databases or other sensitive protocols.
- Exposing any environment to the public Internet.
- Proxying, renaming or changing the management endpoint.
- Introducing DNS, split DNS, hostname routing, ACME, publicly trusted certificates or an internal certificate authority.
- Adding a reverse proxy, second firewall appliance or service discovery to the Edge.
- Installing a second client VPN.
- High availability, additional Edge instances or automatic address failover.
- Deciding Phase 2's migration mechanics before Phase 1's measurements exist.
- Executing hypervisor mutations on the user's behalf; they run the delivered script.
- Modifying the user's local SSH client configuration.

## Further Notes

- Demo currently has no snapshot, and the only thing preventing an address collision is the absence of an automatic-startup setting. Both are treated as facts to correct, not as safeguards to rely on.
- Demo cannot be inspected from inside until it starts, and starting it is only safe after its network interface moves to the private bridge. This dependency dictates the phase split; any plan that measures before re-networking is guessing.
- Demo's earlier state is recorded in the existing feature's prerequisites issue, including the address conflict warning, the guest's logical volume layout, the large data volume migration with its checksum method, and a pre-existing failed boot-related service unit that was left untouched and is not addressed here.
- The empirical VPN validation that covered both `8081` and `8082` is point-in-time. It does not reveal policy scope, client pools, user groups, destination objects or translation behavior, and it does not guarantee reachability after any future network change. Re-testing is required after such changes.
- The existing runbook's allocation table describes UAT's entrance as translating to port `443`, while the tutorial and the health check use host port `18000`. This inconsistency is in the existing documentation, is not introduced here, and should be corrected when UAT's entry is next touched; Demo's mapping is specified independently as `443`.
- The Edge remains an accepted single point of failure for this one-hypervisor, one-address deployment. Publishing a second environment behind it does not change that assessment.
- Phase 1's inventory overturned two of Phase 2's stated premises. Docker was never on the OS volume, so there is nothing to relocate off it; and nothing served `443` before the migration, so the gap is pre-existing rather than a side effect of moving storage. Both corrections are reflected above; the report is `docs/reports/demo-inventory-20260813.md`.
- Only one configuration in the guest references an old absolute path: the Keycloak realm import bind mount. Systemd units, Compose files and `.conf` files scanned clean, and there are no user-level units, so the path rewrite is narrow.
- `vg_data` has under 50G unallocated and `vg_os` under 3.95G. Growing `/srv` is possible; growing `/home` effectively is not. This is why the layout puts application data on the `vg_data` side rather than expanding the home volume.
