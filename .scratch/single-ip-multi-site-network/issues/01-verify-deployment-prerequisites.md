# 01 — 驗證部署先決條件與安全回復路徑

**What to build:** 在改動任何 PVE、VM 或 FortiGate 設定前，建立一份可稽核的部署前檢查結果，證明 `10.1.2.57`、私有網段、既有 VPN、指定入口 ports、交換器 MAC 政策、秘密來源、儲存空間與 out-of-band 回復能力都符合部署條件。任何不符合項目都必須阻止後續變更，而不是以未驗證假設繼續。

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

**Human action required:** 若無權查看或確認 DHCP、交換器／NAC、FortiGate、PVE console 或入口 port 設定，標記 `[HUMAN ACTION]`，列出需要使用者完成的具體檢查，不要求使用者提供不必要的秘密值，並等待明確完成訊息。

- [x] 確認 `10.1.2.57` 未被使用、已保留且不在 DHCP pool，並記錄核對方式。
- [x] 讀取並記錄既有 PVE 外部網路的 prefix、default gateway 與 DNS resolver；不得自行猜測。
- [x] 以目前已連線的 FortiClient SSL-VPN client 對 `10.1.2.57:8081`／`:8082` 完成 empirical connectivity validation；policy 管理細節與未來變更仍未知。
- [x] 確認交換器或 NAC 允許 Edge VM 的額外 MAC address；不以繞過 port security 作替代方案。
- [x] 證明 `172.23.57.0/24` 不與公司路由、VPN client 網路、容器網路或 site-to-site 網段重疊。
- [x] 確認 DNS、split DNS、ACME 與公開 TLS 已依使用者決策從初始部署取消，client 使用 `10.1.2.57:<port>`。
- [x] 確認 node `pve` 上的 VM 109 名稱為 `ub-26-4-srv-docker`，並記錄其 CPU、RAM、磁碟、網路與電源狀態基線。
- [x] 由 VM 109 的已驗證 full clone 磁碟基線確認 `/srv` 是獨立 20G ext4 LV，容量可量測；正式 clone 後仍須重新量測並套用至少百分之二十 headroom gate。
- [x] 確認 repository-local `.secrets` hierarchy 已被 Git 忽略且存在 backend 環境來源；只驗證結構與必要 key 是否存在，不輸出值。
- [x] 確認有實體 console、IPMI、iKVM 或等效的 out-of-band 回復路徑，並在進行網路變更前完成 `[HUMAN ACTION]` 核准。
- [x] 檢查過程未修改 PVE、VM 109、FortiGate、DNS 或任何秘密內容。

## Comments

### 2026-08-11 automated read-only preflight

- Fortinet SSL VPN 介面已連線，client address 為 `10.255.254.5`；其路由包含 `10.1.2.56/30`，因此涵蓋 `10.1.2.57`。
- VPN 介面的 DNS resolver 為 `192.168.43.30` 與 `8.8.8.8`。
- `10.1.2.50:8006` 可透過目前 VPN 連線，未對該管理端點進行任何變更。
- `10.1.2.57:80` 與 `10.1.2.57:443` 均接受 TCP 連線。HTTP 回應識別為 `nginx/1.27.5` 並重新導向 HTTPS；HTTPS 現有憑證鏈不受此 client 信任。這證明 `10.1.2.57` 目前不能視為未使用，會阻止後續部署。
- 本機 route table 未出現 `172.23.57.0/24`，但這不足以排除公司路由、container network 或 site-to-site network 的遠端重疊。
- Repository-local `.secrets` hierarchy 存在、已由 Git 忽略，且存在 backend environment source。只列舉了 key 名稱，未輸出或修改任何值；在取得應用 repository 的 environment schema 前，尚不能驗證必要 key 是否齊全。
- 此輪只執行本機唯讀檢查，未修改 PVE、VM 109、FortiGate、DNS、NAC 或 secrets。

`[HUMAN ACTION]` 請在繼續前完成並明確確認：

1. 識別 `10.1.2.57` 上現有 nginx 服務的擁有者與用途，決定安全移除／遷移該服務，或修改本 spec 的入口 IP；同時確認該 IP 已排除於 DHCP pool 並正式保留。
2. 從 PVE、FortiGate 與交換器／NAC 管理面取得 ticket 所列的外部 prefix、gateway、resolver、VPN 類型與來源 pool、policy 範圍、額外 MAC 許可，以及 `172.23.57.0/24` 的完整無重疊證明。原先要求的 DNS 欄位已由後續 IP＋port 決策取消。
3. 記錄 VM 109 的 CPU、RAM、磁碟、網路、電源狀態與 `/srv` filesystem 容量基線。
4. 確認可用的實體 console、IPMI、iKVM 或等效 out-of-band 回復路徑，並核准之後的網路變更。

### 2026-08-11 human confirmation: entrance IP released

- 使用者確認已停止原先使用 `10.1.2.57` 的機器，並授權本功能使用該 IP。
- 確認後重新探測，`10.1.2.57:80` 與 `10.1.2.57:443` 均不再接受 TCP 連線。
- 此確認解除現有 nginx 服務衝突；DHCP pool 排除與正式 reservation 仍須由管理面另外確認。

### 2026-08-11 authenticated PVE read-only audit

- 使用使用者已登入的 Chrome session 唯讀檢查 PVE VE 9.2.3；未送出任何建立、修改、套用、啟動或刪除操作。
- Node `pve` 的外部 bridge 為 `vmbr0`，設定 `10.1.2.50/24`、gateway `10.1.2.254`，bridge port 為 `nic0`。Node DNS resolver 為 `8.8.8.8`。
- `vmbr1` 與 `vmbr2` 均為 active/autostart、無 PVE host IP、無實體 bridge port，但已被現有 VM 使用：`vmbr1` 連接 VM 100、999999997、999999998、999999999；`vmbr2` 連接 VM 101、102。因此不得把任一 bridge 直接改作本功能的私有網路；需要新增專用 bridge，例如 `vmbr3`。
- VM 109 是 stopped template，名稱 `ub-26-4-srv-docker`；CPU 為 1 socket / 8 cores，memory 上限 8 GiB、balloon minimum 2 GiB；disks 為 100G 與 200G，net0 接 `vmbr0` 並啟用 PVE firewall，Cloud-Init 使用 DHCP。
- `VMdisk` 是 ZFS storage，已使用 8.67 TB / 11.02 TB（78.68%）。新增另一份名目 300G full clone 會使剩餘率低於 20%，不得依原方案再建立 clone。
- VM 103 `type-ai-platform-demo` 目前 stopped；PVE task output 證明它在 2026-08-05 由 VM 109 建立，target ID 為 103，100G 與 200G disks 均為 full clone。它另有 2T disk，因此可作為既有 backend clone 候選，避免再次複製 300G。
- VM 103 目前為 8 vCPU、32 GiB RAM，net0 接 `vmbr0`，Cloud-Init 仍設定 `10.1.2.57/24`、gateway `10.1.2.254`。在改接專用私有 bridge 並改為 `172.23.57.11/24` 前不得重新啟動，否則會和 Edge VM 的入口 IP 衝突；RAM 亦仍須調整為 spec 要求的 64 GiB 並停用 ballooning。
- PVE 管理介面沒有提供 VM 103 guest 內 `/srv` filesystem 的實際 free-space 資料；該項仍須在安全改接私有網路後從 guest 內驗證。
- Chrome 中沒有既有 FortiGate 管理頁籤，聚焦查詢近期 FortiGate／Fortinet 瀏覽紀錄亦無結果，因此 VPN source pool、FortiGate policy、DHCP reservation 與 NAC 仍無法由此次 PVE 盤點確認。DNS provider 已由後續 IP＋port 決策取消。

### 2026-08-11 human confirmation: network prerequisites and backend choice

- 使用者要求 VM 103 保持暫時關閉且不得修改；本功能必須另外建立新的 backend VM。
- 使用者確認 `172.23.57.0/24` 無環境重疊，已有可用 out-of-band recovery path，並核准後續新增專用 private bridge。
- 使用者確認 `10.1.2.57` 已排除 DHCP 並正式保留，且交換器／NAC 允許 Edge VM 的額外 MAC address。
- 新 backend 不得 clone 到目前的 `VMdisk`：名目 300G full clone 會使該 storage 剩餘率低於 spec 要求的 20%。須先找到符合 headroom 的其他適用 storage，否則停在 `[HUMAN ACTION]`。

### 2026-08-11 alternative storage and Edge installation media

- `local-zfs` 是 active ZFS storage，支援 VM disk，總容量 908.20 GB，目前僅使用 98.30 KB。將 VM 109 的 300G full clone 放在此 storage 後，名目 free-space ratio 約 67%，符合至少 20% headroom 的要求。
- `local` directory storage 總容量 920.60 GB，目前使用 12.40 GB，並已有 `ubuntu-24.04.2-live-server-amd64.iso`。可用該 server ISO 建立獨立且較小的 Edge VM，避免為 Edge role 複製 VM 109 的 300G disks。
- VM 103 在此輪保持 stopped，未讀寫其 disks、未修改 hardware、network 或 Cloud-Init。

### 2026-08-11 VM 103 storage migration (user-authorized override)

- 使用者明確取代先前「VM 103 暫時關閉且不得修改」的限制，要求啟動 VM 103，且不得把新 clone 放到 `local-zfs`；本輪沒有建立新 clone，也未修改 VM 109。
- VM 103 已啟動。其 SSH host key 已由 PVE console 顯示的 ED25519 fingerprint 交叉確認；本機舊的 `10.1.2.57` known-host entries 已移除，`ssh-keygen` 保留 `known_hosts.old` 備份。
- Guest 盤點確認原 2T `/dev/sdc` 是 `vg_data/lv_model_cache` 的主要 PV segment，XFS 掛載於 `/data/model-cache`，實際有 6 個資料檔、約 8.4G apparent data；XFS 不支援原地縮小，因此不得直接把 PVE disk size 改成 500G。
- 已在 `VMdisk` 新增 `scsi4`（`VMdisk:vm-103-disk-4`）500G raw disk，guest 內為 `/dev/sdd`。新建 `/dev/sdd1` XFS（label `mc500g`），以 `rsync -aHAXS --numeric-ids --delete` 複製資料，並以逐檔 SHA-256 驗證來源與目標 6 個檔案完全一致。
- `/data/model-cache` 已切換為 `/dev/sdd1`，容量 499.8G、已用約 17.9G、可用約 481.8G；`/etc/fstab` 使用新 UUID `238cc650-9f31-4c50-ad78-be438f271b04`，備份為 `/etc/fstab.before-model-cache-500g-20260811124743`，`mount -a` 與切換後 SHA-256 均通過。
- 使用者明確確認不可逆清除後，舊 `vg_data/lv_model_cache` 已刪除，`/dev/sdc` 已從 `vg_data` 移除並清除 PV label；PVE 的 `scsi3`（`VMdisk:vm-103-disk-3`）亦已 detach 並永久刪除。
- VM 103 已正常關機以套用 detach，隨後重新啟動。重啟後 500G 磁碟重新編號為 `/dev/sdc1`，仍由 UUID 正確掛載於 `/data/model-cache`；6 個檔案存在，Docker 正常回應，`vg_data` 僅保留 Docker、containerd 與 `/srv` 三個 LV。
- PVE `VMdisk` 刪除後使用量為 6.83 TB / 11.02 TB（61.99%），可用空間約 4.19 TB（38.01%），已恢復到高於 spec 要求的 20% headroom。
- 健康檢查顯示 Docker 正常回應（29.7.2 / overlayfs）；`grub-initrd-fallback.service` 為 failed，需另行判斷是否為既有開機狀態，本輪未修改該服務。

### 2026-08-11 partial FortiGate evidence and IP-port design decision

- 使用者提供的文件可確認既有 VPN 是 FortiClient SSL-VPN，且已定義 VPN gateway／port；連線後可存取既有內部位址 `10.1.2.3`。
- 本機實際連線觀察到 client address `10.255.254.5` 與涵蓋 `10.1.2.57` 的 `10.1.2.56/30` route，但這不足以證明 FortiGate 正式設定的完整 client pool、split-tunnel route 與 firewall policy 範圍，因此 FortiGate 先決條件仍未通過。
- `[HUMAN ACTION]` FortiGate 管理者只需提供下列非秘密欄位，不需要帳號或密碼：

```text
SSL-VPN client IP pool:
Split-tunnel route includes 10.1.2.57: yes/no
Firewall policy ID/name:
Source user group/address:
Destination includes 10.1.2.57: yes/no
Allowed TCP ports: 8081 required; 8082 temporary acceptance
NAT enabled: yes/no
```

- 使用者已明確取消 DNS，採用 `10.1.2.57:<port>`。初始 port map 保留 TCP `8081` 給 Type AI Platform、TCP `8082` 給第二驗證服務；不部署 Caddy hostname routing、split DNS、ACME 或公開信任 TLS。
- 初版使用 VPN 內 HTTP。這是使用者為快速方便所接受的取捨；FortiGate 解密後至 Edge／backend 的內部路徑沒有應用層 TLS。FortiGate 管理者仍須明確確認 TCP `8081`／`8082` 的 policy，不能以能連 `10.1.2.3` 或本機 route 推定已放行。
- 使用者指出外部 AIDMS 登入教學文件含明文 VPN 與應用帳密。本輪不開啟、不讀取、不複製該文件內容；建議由擁有者立即輪替相關憑證並遷移至公司核准的密碼管理工具。

### 2026-08-11 empirical FortiGate path validation

- 使用者無法聯絡 VPN／FortiGate 管理員，無法取得完整 SSL-VPN client pool、policy ID、source group、destination object 或 NAT 設定；使用者明確核准以目前 VPN client 的實際連線測試作為本次部署 gate。
- 在目前持有 `10.1.2.57` 的 VM 103 上，以具 180 秒自動失效期限的 transient systemd units 暫時建立 TCP `8081` 與 `8082` listeners。兩個 listeners 均確認綁定 `0.0.0.0`，未寫入永久服務或防火牆設定。
- 從目前已連線 FortiClient SSL-VPN 的 Windows client 執行 `Test-NetConnection`。來源介面為 `乙太網路 3`、來源位址為 `10.255.254.5`；`10.1.2.57:8081` 與 `10.1.2.57:8082` 的 `TcpTestSucceeded` 均為 `True`。
- 測試證明目前 VPN route、現行 FortiGate path、目的 guest/PVE firewall 與回程路由可支援 TCP `8081`／`8082`。這是時間點限定的 empirical validation，不揭示實際 policy ID、完整 source pool、user group、destination object 或 NAT 行為，也不能保證 FortiGate 未來變更後仍維持可達。
- 測試完成後已停止並清除 `codex-vpn-probe-8081.service` 與 `codex-vpn-probe-8082.service`；`ss` 確認兩個 ports 均無 listener，兩個 units 均為 inactive，沒有殘留的 transient unit。
- 若日後任一 port 從核准 VPN client 無法連線且沒有管理員可調整 policy，部署必須停止並回報阻擋；不得擴大 port 範圍、改用未核准 tunnel 或繞過公司網路政策。

### 2026-08-11 clone-derived `/srv` capacity evidence

- PVE task history 證明 VM 103 是 2026-08-05 從 template VM 109 建立的 100G＋200G full clone；VM 109 保持 stopped template，未在本功能中啟動或修改。
- VM 103 guest 的 cloned 200G disk 顯示 `vg_data/lv_srv` 為 20G ext4，掛載 `/srv`，盤點時約 18.5G 可用。這提供 VM 109 template disk layout 的可量測基線，但不是新 backend clone 完成後容量的替代驗收。
- Ticket 03 建立正式 backend clone 後必須再次直接列舉 `/srv` 或其下 filesystem，記錄部署前後容量；若預估或實際剩餘低於百分之二十，仍須停止部署。

### 2026-08-11 backend storage override completed

- 先前「新 backend 不得 clone 到 `VMdisk`」的判斷已被後續事件取代：使用者核准清理 VM 103 的舊 2T disk，`VMdisk` 可用空間恢復至約 4.19 TB，之後明確要求 VM 109 Full Clone 到 `VMdisk`、不使用 `local-zfs`。
- Ticket 03 的新 VM 105 Full Clone 完成後，`VMdisk` 使用 7.55/11.02 TB（68.46%），仍有約 3.47 TB（31.54%）可用，符合至少百分之二十的 headroom gate。
- Edge 上觀察到目前 VPN SSH 連線的 server-side peer 為 `192.168.255.253`，可推定現行 FortiGate path 至少對此 session 執行來源 NAT；實際 policy ID、完整 pool 與未來變更仍未知，empirical validation 的限制不變。
