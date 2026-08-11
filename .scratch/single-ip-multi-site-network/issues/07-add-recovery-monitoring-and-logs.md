# 07 — 建立自動恢復、監控與安全紀錄

**What to build:** 讓 Edge VM 與 Type AI Platform 在核准的重啟後自動恢復，並提供足以發現 DNS、TLS、backend、storage 與 routing 問題的監控和安全紀錄，使單一入口故障不會只能依賴使用者回報。

**Blocked by:** 06 — 驗證多網站分流與端到端隔離.

**Status:** ready-for-agent

**Human action required:** Edge VM、backend VM 或 PVE host 的重啟測試必須在核准窗口進行。需要使用者排定窗口或操作實體 console 時，標記 `[HUMAN ACTION]`，列出預期中斷範圍並等待完成。

- [ ] Edge VM 的 networking、IPv4 forwarding、nftables 與 Caddy 均設為自動啟動，Type AI Platform containers 依正確依賴順序自動恢復。
- [ ] Caddy 與 nftables 變更在 reload 前完成語法或規則驗證；無效變更不會取代目前正常設定。
- [ ] 監控從 VPN 使用者 seam 驗證 split DNS、HTTPS、certificate chain、hostname routing 與主要 backend health。
- [ ] 監控 Edge VM 到 Type AI Platform 的私有連線、Docker container health 與必要 outbound NAT。
- [ ] 監控 `/srv` filesystem 使用率，並在接近保留百分之二十 headroom 前產生可行動告警。
- [ ] 監控 production certificate 到期日與自動續期結果，不在監控輸出中暴露 DNS credential。
- [ ] Caddy access／error log、nftables 必要拒絕紀錄與應用 health failure 可供稽核，且不記錄 `.env` value、token 或 authorization secret。
- [ ] 經 `[HUMAN ACTION]` 核准後重啟 Edge VM 與 Type AI Platform backend，所有必要服務無人工介入自動恢復。
- [ ] 若 PVE host reboot 被核准，完成後 private bridge、兩台 VM、NAT、DNS 與 HTTPS 自動恢復；若未核准，明確記錄為 ticket 08 的待驗證項目而不假裝通過。
- [ ] 重啟後重新執行多 hostname、未知 hostname、direct-backend deny 與 PVE management separation 黑箱測試。
