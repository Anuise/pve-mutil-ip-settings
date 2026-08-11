# 07 — 建立自動恢復、監控與安全紀錄

**What to build:** 讓 Edge VM 與 Type AI Platform 在核准的重啟後自動恢復，並提供足以發現 entrance port、backend、storage 與 routing 問題的監控和安全紀錄，使單一入口故障不會只能依賴使用者回報。

**Blocked by:** 06 — 驗證多服務 port 分流與端到端隔離.

**Status:** ready-for-agent

**Human action required:** Edge VM、backend VM 或 PVE host 的重啟測試必須在核准窗口進行。需要使用者排定窗口或操作實體 console 時，標記 `[HUMAN ACTION]`，列出預期中斷範圍並等待完成。

- [x] Edge VM 的 networking、IPv4 forwarding 與 nftables 均設為自動啟動，Type AI Platform containers 依正確依賴順序自動恢復。
- [x] nftables 變更在 reload 前完成規則驗證；無效變更不會取代目前正常設定。
- [ ] 監控從 VPN 使用者 seam 驗證 `10.1.2.57:8081`、每個仍在使用的其他 entrance port、正確 backend response 與未配置 port 拒絕。
- [x] 監控 Edge VM 到 Type AI Platform 的私有連線、Docker container health 與必要 outbound NAT。
- [x] 監控 `/srv` filesystem 使用率，並在接近保留百分之二十 headroom 前產生可行動告警。
- [x] 監控不要求 DNS、certificate expiry 或 ACME renewal；若未來加入 TLS，必須另行擴充監控與驗收。
- [x] nftables 必要拒絕紀錄與應用 health failure 可供稽核，且不記錄 `.env` value、token 或 authorization secret。
- [x] 經 `[HUMAN ACTION]` 核准後重啟 Edge VM 與 Type AI Platform backend，所有必要服務無人工介入自動恢復。
- [ ] 若 PVE host reboot 被核准，完成後 private bridge、兩台 VM、NAT 與所有 allocated ports 自動恢復；若未核准，明確記錄為 ticket 08 的待驗證項目而不假裝通過。
- [ ] 重啟後重新執行多 port、未配置 port、direct-backend deny 與 PVE management separation 黑箱測試。

## Comments

### 2026-08-11 recovery, health timers, and rejection logs

- Edge 已建立並啟用 `single-ip-edge-health.timer`（每分鐘）：驗證 IPv4 forwarding、nftables active、8081 DNAT tuple 與 `.11:18000/healthz`。Backend 已建立並啟用 `type-ai-platform-health.timer`（每五分鐘）：驗證 Docker、三個 containers、backend health、outbound HTTPS 與 `/srv/platform` 使用率不超過 80%。兩個 oneshot service 的立即執行結果均為 `success`。
- Edge forward default deny 前加入 rate-limited `edge-forward-drop` journal log；backend `DOCKER-USER` 對未核准 original port 18000 流量先以 `type-ai-drop` rate-limited log，再 drop。監控與拒絕紀錄不讀取或輸出 env/token/authorization values。
- Edge 與 backend 都已實際 reboot。Edge 的 forwarding、nftables、DNAT／SNAT 與 health timer自動恢復；backend 的 Docker、三個 `unless-stopped` containers、source firewall、mounts 與 health timer 自動恢復。最終 VPN seam 的 8081 health 亦自動恢復。
- PVE host reboot 未取得明確核准，因此未執行，保留給 ticket 08；不能把 VM-level reboot 結果當作 PVE host reboot 驗收。
- 已從目前 VPN client 手動執行 entrance health、8082／8083 fail-closed、direct-private deny 與 PVE 管理路徑黑箱檢查；尚未建立常駐的 VPN-client-side monitor，也沒有在重啟後再次臨時開啟 8082，因此對應兩個 checklist 保持未勾選。
