# 01 — 驗證部署先決條件與安全回復路徑

**What to build:** 在改動任何 PVE、VM、FortiGate 或 DNS 設定前，建立一份可稽核的部署前檢查結果，證明 `10.1.2.57`、私有網段、既有 VPN、DNS、交換器 MAC 政策、秘密來源、儲存空間與 out-of-band 回復能力都符合部署條件。任何不符合項目都必須阻止後續變更，而不是以未驗證假設繼續。

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

**Human action required:** 若無權查看或確認 DHCP、交換器／NAC、FortiGate、DNS provider、PVE console 或正式網域設定，標記 `[HUMAN ACTION]`，列出需要使用者完成的具體檢查，不要求使用者提供不必要的秘密值，並等待明確完成訊息。

- [ ] 確認 `10.1.2.57` 未被使用、已保留且不在 DHCP pool，並記錄核對方式。
- [ ] 讀取並記錄既有 PVE 外部網路的 prefix、default gateway 與 DNS resolver；不得自行猜測。
- [ ] 確認 FortiClient 使用的 VPN 類型、來源 pool、到 `10.1.2.57` 的 route 與可套用的 FortiGate policy 範圍。
- [ ] 確認交換器或 NAC 允許 Edge VM 的額外 MAC address；不以繞過 port security 作替代方案。
- [ ] 證明 `172.23.57.0/24` 不與公司路由、VPN client 網路、容器網路或 site-to-site 網段重疊。
- [ ] 確認組織持有可用的正式網域子區、內部 split DNS 管理權及支援自動 DNS-01 的公開 DNS provider。
- [ ] 確認 node `pve` 上的 VM 109 名稱為 `ub-26-4-srv-docker`，並記錄其 CPU、RAM、磁碟、網路與電源狀態基線。
- [ ] 確認 VM 109 的 `/srv` 儲存配置具備可判斷容量的 filesystem，且部署後保留至少百分之二十空間的規則可被驗證。
- [ ] 確認 repository-local `.secrets` hierarchy 已被 Git 忽略且存在 backend 環境來源；只驗證結構與必要 key 是否存在，不輸出值。
- [ ] 確認有實體 console、IPMI、iKVM 或等效的 out-of-band 回復路徑，並在進行網路變更前完成 `[HUMAN ACTION]` 核准。
- [ ] 檢查過程未修改 PVE、VM 109、FortiGate、DNS 或任何秘密內容。
