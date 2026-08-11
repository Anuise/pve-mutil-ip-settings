# 03 — 從 VM 109 建立 Type AI Platform backend

**What to build:** 以 node `pve` 上的 VM 109（`ub-26-4-srv-docker`）建立一台獨立的 Type AI Platform backend full clone，配置所需運算資源與私有網路，並將所有後續應用及 Docker 儲存導向 `/srv` 下容量最充足的適用 filesystem，而不改變來源 VM。

**Blocked by:** 02 — 建立私有網路與受控 outbound NAT.

**Status:** ready-for-agent

**Human action required:** 若 full clone 需要來源 VM 停機、需要人工選擇目標 storage、可用 VMID 或存在容量風險，標記 `[HUMAN ACTION]`，清楚呈現選項與影響並等待核准。不得自行停止 VM 109、刪除磁碟或覆寫既有 VMID。

- [ ] 在 clone 前記錄 VM 109 的 CPU、RAM、磁碟、網路、電源狀態與識別資訊。
- [ ] 建立 full clone 而非 linked clone，並使用未占用的新 VMID 與清楚的 Type AI Platform 名稱。
- [ ] 新 clone 配置 8 個 virtual CPU cores 與 64 GiB RAM（`65536` MiB），並停用 memory ballooning。
- [ ] 新 clone 只連接私有 bridge，使用 `172.23.57.11/24` 與 `172.23.57.1` default gateway，不取得 `10.1.2.x` 位址。
- [ ] 列舉 clone 上掛載於 `/srv` 或其下方的 filesystem，選擇可用容量最大的適用 filesystem，並記錄部署前容量。
- [ ] 將此專用 clone 的 Docker data-root、專案 checkout 與持久應用資料規劃在選定的 `/srv` filesystem 下，不移動或刪除無關資料。
- [ ] 若預估部署會使選定 filesystem 的剩餘容量低於百分之二十，停止並標記 `[HUMAN ACTION]`；不得退回使用 root filesystem。
- [ ] 驗證 clone 能透過 Edge VM NAT 使用核准的 resolver 與必要 outbound 連線。
- [ ] clone 完成後再次核對 VM 109，證明其 CPU、RAM、磁碟、網路、電源狀態與識別資訊未因本操作改變。
- [ ] 驗證新 clone 回報 8 vCPU、64 GiB memory、正確私有 IP 與預期 `/srv` storage 配置。
