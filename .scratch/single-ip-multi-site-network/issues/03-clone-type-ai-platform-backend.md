# 03 — 從 VM 109 建立 Type AI Platform backend

**What to build:** 以 node `pve` 上的 VM 109（`ub-26-4-srv-docker`）建立一台獨立的 Type AI Platform backend full clone，配置所需運算資源與私有網路，並將所有後續應用及 Docker 儲存導向 `/srv` 下容量最充足的適用 filesystem，而不改變來源 VM。

**Blocked by:** 02 — 建立私有網路與受控 outbound NAT.

**Status:** ready-for-agent

**Human action required:** 若 full clone 需要來源 VM 停機、需要人工選擇目標 storage、可用 VMID 或存在容量風險，標記 `[HUMAN ACTION]`，清楚呈現選項與影響並等待核准。不得自行停止 VM 109、刪除磁碟或覆寫既有 VMID。

- [x] 在 clone 前記錄 VM 109 的 CPU、RAM、磁碟、網路、電源狀態與識別資訊。
- [x] 建立 full clone 而非 linked clone，並使用未占用的新 VMID 與清楚的 Type AI Platform 名稱。
- [x] 新 clone 配置 8 個 virtual CPU cores 與 64 GiB RAM（`65536` MiB），並停用 memory ballooning。
- [x] 新 clone 只連接私有 bridge，使用 `172.23.57.11/24` 與 `172.23.57.1` default gateway，不取得 `10.1.2.x` 位址。
- [x] 列舉 clone 上掛載於 `/srv` 或其下方的 filesystem，選擇可用容量最大的適用 filesystem，並記錄部署前容量。
- [x] 將此專用 clone 的 Docker data-root、專案 checkout 與持久應用資料規劃在選定的 `/srv` filesystem 下，不移動或刪除無關資料。
- [x] 若預估部署會使選定 filesystem 的剩餘容量低於百分之二十，停止並標記 `[HUMAN ACTION]`；不得退回使用 root filesystem。
- [x] 驗證 clone 能透過 Edge VM NAT 使用核准的 resolver 與必要 outbound 連線。
- [x] clone 完成後再次核對 VM 109，證明其 CPU、RAM、磁碟、網路、電源狀態與識別資訊未因本操作改變。
- [x] 驗證新 clone 回報 8 vCPU、64 GiB memory、正確私有 IP 與預期 `/srv` storage 配置。

## Comments

### 2026-08-11 VM 105 backend full clone 與驗收

- Clone 前基線沿用 ticket 01 的已驗證 PVE 盤點：VM 109 是 stopped template `ub-26-4-srv-docker`，8 vCPU、8 GiB maximum／2 GiB minimum balloon memory、100G＋200G `VMdisk` disks、net0 接 `vmbr0`，Cloud-Init 使用 DHCP。
- 使用者核准在舊 2T VM 103 disk 清理後改用 `VMdisk`。Clone 前 `VMdisk` 使用 7.19/11.02 TB（65.23%），可用約 3.83 TB；以新 VMID 105、名稱 `type-ai-platform-backend` 建立 Full Clone，PVE task 於 13:36:55 顯示 `OK`。沒有使用 `local-zfs`。
- VM 105 配置 8 vCPU、65536 MiB RAM、ballooning disabled、start at boot；兩個 cloned disks 均位於 `VMdisk`，分別為 100G 與 200G。唯一 NIC 接 `vmbr3`，Cloud-Init 設為 `172.23.57.11/24`、gateway `172.23.57.1`，並停用開機套件升級。
- Guest 首次啟動後 Cloud-Init 為 `done`，回報 8 CPUs、`MemTotal=63410680 kB`、唯一業務 NIC `eth0=172.23.57.11/24`，沒有 `10.1.2.x` 位址。
- 範本原始 `/srv` 為 20G ext4；另有 80G `vg_data/lv_docker`，盤點時 Docker 為 0 containers／0 images、僅使用 228K。保留該 LV 與既有內容後，將其改掛載為 `/srv/platform`，並把 Docker data-root 設為 `/srv/platform/docker`；專案與持久資料路徑分別預留 `/srv/platform/type-ai-platform`、`/srv/platform/app-data`。
- `/etc/fstab` 備份為 `/etc/fstab.before-type-ai-platform-202608111340`，Docker 設定備份為 `/etc/docker/daemon.json.before-type-ai-platform-202608111340`。Backend 重啟後 `/srv/platform` 自動掛載，Docker active 且 root 為 `/srv/platform/docker`，原 0 containers／0 images 狀態不變。
- 選定 filesystem 容量 79G，使用 2.3M、可用 75G（1% used），高於百分之二十 headroom gate。Clone 後 `VMdisk` 使用 7.55/11.02 TB（68.46%），仍有約 3.47 TB（31.54%）可用。
- Backend 經 Edge NAT 可解析 `archive.ubuntu.com` 並取得 HTTPS 200；主動連線 `10.1.2.50:8006` 被拒絕，VPN client 直接連線 `172.23.57.11:22` 亦失敗。
- Clone 完成後再次核對 VM 109：名稱、template/stopped 狀態、8 vCPU、8 GiB／2 GiB balloon memory、100G＋200G base disks、net0 MAC `BC:24:11:6D:53:04` 與 `vmbr0` 均未改變。
