# 08 — 完成備份還原與正式驗收

**What to build:** 建立並實際證明一條可恢復 Edge VM 與 Type AI Platform backend 的路徑，完成所有 VPN 使用者、儲存、安全與維運驗收，讓後續服務能以新 port 加入而不重新設計網路。

**Blocked by:** 07 — 建立自動恢復、監控與安全紀錄.

**Status:** needs-info

**Human action required:** 還原演練、停機窗口、備份目的地存取、PVE host reboot 或 production cutover 若需要使用者核准，逐項標記 `[HUMAN ACTION]` 並等待。不得覆寫唯一 production instance 或刪除未驗證的備份。

- [ ] 備份涵蓋重建 Edge VM 所需的網路、nftables port map 與服務設定，以及 Type AI Platform 的 deployment revision、Docker configuration 與 `/srv` 持久資料。
- [ ] `.secrets`、remote `.env.uat`、UAT nginx certificate volume 與 root-owned certificate fingerprint 使用核准的加密／受保護備份機制，且不進入 Git、ticket 或一般 log；此設計不建立 DNS API token 或 ACME account key。
- [ ] 在不破壞唯一正常 instance 的前提下完成 Edge VM 與 Type AI Platform 的還原演練，並記錄實際復原時間與任何人工依賴。
- [ ] 還原後新 VM 仍具備 8 vCPU、64 GiB RAM、私有 IP、正確 `/srv` placement 與至少百分之二十 storage headroom。
- [ ] 還原後重新執行 `10.1.2.57:8081` Type AI Platform health、第二驗證 port、未配置 port 拒絕及 WebSocket 驗收。
- [ ] 驗證 VPN client 仍不能直接存取 private subnet，一般服務使用者仍不能取得 `.50:8006` 權限，未連 VPN 時 allocated ports 仍不可公開存取。
- [x] 驗證 VM 109 在整個工作完成後仍保有原始 CPU、RAM、磁碟、網路、電源狀態與用途。
- [x] 交付新增服務、配置或移除 entrance port／backend、更新 `.env`、驗證設定、rollback 與重啟的維運程序。
- [x] 所有需要使用者完成的 `[HUMAN ACTION]` 都有明確完成紀錄；沒有未確認項目被標示為成功。
- [ ] spec 的所有成功條件均由黑箱結果或可稽核證據支持，Type AI Platform 可交付給核准 VPN 使用者使用。

## Comments

### 2026-08-11 operational handoff and remaining production gates

- 維運程序已交付於 `docs/runbooks/single-ip-multi-site.md`，涵蓋 health、更新 ignored env、Compose build／migration、新增／移除 port、nft preflight、rollback、重啟、監控、備份範圍與 restore acceptance。
- 完成後再次核對 VM 109，仍為 stopped template `ub-26-4-srv-docker`；8 vCPU、8 GiB／2 GiB balloon memory、100G＋200G base disks、net0 MAC／`vmbr0` 與用途均未變更。
- `[HUMAN ACTION]` 尚需指定受保護的 VM／secret backup 目的地與隔離 restore VMID/network，並核准實際 restore drill；不得覆寫目前唯一正常的 VM 104 或 VM 105。
- `[HUMAN ACTION]` PVE host reboot 尚未核准。VM-level reboot 已通過，但不能替代 host bridge／autostart 的 host-level 驗收。
- `[HUMAN ACTION]` 需使用獨立 off-VPN client 驗證 8081 不公開，並使用不具 PVE 權限的一般 FortiClient user 驗證 FortiGate-level management separation。
- Application revision `25201dbf1ba3475ebe9a69356c551e6394937f26` 已提供並驗證 UAT frontend、nginx same-origin frontend/API routing、backend API、docs、health 與 dev-login smoke flow；仍不能宣稱 production-ready，因 production SSO、trusted TLS、PVE host reboot、off-VPN test 與 restore drill 尚未完成。

### 2026-08-12 UAT cutover evidence

- VM105 已由舊 dev Compose 切換至 UAT Compose；migration、六個 containers、`/srv/platform` headroom、Edge DNAT、HTTPS frontend/API seam 均已驗證。
- UAT environment 與 Docker volumes 仍在 `/srv/platform`；`.env.uat` mode `0600`，秘密未進 Git、ticket、一般 log 或測試輸出。
- 本 ticket 尚未把人工核准的 PVE host reboot、隔離 restore drill、獨立 off-VPN client 或一般 VPN user 的 FortiGate management separation 標成成功。
