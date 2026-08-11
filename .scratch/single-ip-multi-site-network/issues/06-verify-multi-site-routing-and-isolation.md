# 06 — 驗證多網站分流與端到端隔離

**What to build:** 證明 `10.1.2.57` 能依 hostname 安全承載多個獨立網站，同時阻止 VPN 使用者直接探測 backend、存取 PVE 管理面或利用偽造 proxy headers 影響應用判斷。第二個服務只作受控驗證，不得改動 VM 109 或降低 Type AI Platform 的安全邊界。

**Blocked by:** 05 — 以可信 HTTPS 向 VPN 使用者發布 Type AI Platform.

**Status:** ready-for-agent

**Human action required:** 若建立第二個受控 backend、測試 VPN 群組或執行管理面拒絕測試需要使用者核准，標記 `[HUMAN ACTION]` 並等待。不得為測試使用真實使用者密碼或關閉既有防火牆。

- [ ] 在不同於 `172.23.57.11` 的私有 IP 上建立一個最小且受控的第二測試 backend，不使用 Edge VM 作為第二 backend。
- [ ] 第二個 hostname 與 Type AI Platform hostname 都透過內部 DNS 解析為 `10.1.2.57`。
- [ ] 兩個 hostname 使用相同入口 TCP 443，但分別得到可辨識且正確的 backend 回應。
- [ ] 驗證兩個 backend 可以重複使用相同的 local service port，而不需要新增 `10.1.2.x` 位址。
- [ ] 驗證 WebSocket 或等效的 connection upgrade 能通過 Caddy 到核准 backend。
- [ ] 客戶端提供的偽造 forwarding headers 不會被當成可信來源；backend 只信任 Edge VM 提供的 proxy metadata。
- [ ] 未登記 hostname 會得到固定拒絕回應，不會落到任一 backend。
- [ ] VPN client 沒有 `172.23.57.0/24` route，且不能直接連線、掃描或繞過 Caddy 存取 backend。
- [ ] 一般網站使用者不能因本功能存取 `10.1.2.50:8006`；管理者原有管理路徑仍正常。
- [ ] backend 只允許 Edge VM 到核准 web port，且不必要的 east-west 與對管理網路連線被拒絕。
- [ ] 若第二測試 backend 不作長期使用，安全移除本 ticket 建立的資源並保留可重現的驗收方式，不影響 Type AI Platform。
