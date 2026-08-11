# 08 — 完成備份還原與正式驗收

**What to build:** 建立並實際證明一條可恢復 Edge VM 與 Type AI Platform backend 的路徑，完成所有 VPN 使用者、儲存、安全與維運驗收，讓後續網站能依相同模式加入而不重新設計網路。

**Blocked by:** 07 — 建立自動恢復、監控與安全紀錄.

**Status:** ready-for-agent

**Human action required:** 還原演練、停機窗口、備份目的地存取、PVE host reboot 或 production cutover 若需要使用者核准，逐項標記 `[HUMAN ACTION]` 並等待。不得覆寫唯一 production instance 或刪除未驗證的備份。

- [ ] 備份涵蓋重建 Edge VM 所需的網路、nftables、Caddy 與服務設定，以及 Type AI Platform 的 deployment revision、Docker configuration 與 `/srv` 持久資料。
- [ ] `.secrets`、DNS API token、ACME account key 與 TLS private key 使用核准的受保護備份機制，且不進入 Git、ticket 或一般 log。
- [ ] 在不破壞唯一正常 instance 的前提下完成 Edge VM 與 Type AI Platform 的還原演練，並記錄實際復原時間與任何人工依賴。
- [ ] 還原後新 VM 仍具備 8 vCPU、64 GiB RAM、私有 IP、正確 `/srv` placement 與至少百分之二十 storage headroom。
- [ ] 還原後重新執行 split DNS、公開信任 HTTPS、Type AI Platform health、多 hostname routing、未知 hostname 拒絕及 WebSocket 驗收。
- [ ] 驗證 VPN client 仍不能直接存取 private subnet，一般網站使用者仍不能取得 `.50:8006` 權限，未連 VPN 時網站仍不可公開存取。
- [ ] 驗證 VM 109 在整個工作完成後仍保有原始 CPU、RAM、磁碟、網路、電源狀態與用途。
- [ ] 交付新增網站、變更 hostname／backend、更新 `.env`、驗證設定、rollback、重啟與憑證續期的維運程序。
- [ ] 所有需要使用者完成的 `[HUMAN ACTION]` 都有明確完成紀錄；沒有未確認項目被標示為成功。
- [ ] spec 的所有成功條件均由黑箱結果或可稽核證據支持，Type AI Platform 可交付給核准 VPN 使用者使用。
