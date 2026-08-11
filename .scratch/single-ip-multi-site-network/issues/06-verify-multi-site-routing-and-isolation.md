# 06 — 驗證多服務 port 分流與端到端隔離

**What to build:** 證明 `10.1.2.57` 能以不同 TCP ports 安全承載多個獨立服務，同時阻止 VPN 使用者直接探測 backend 或存取 PVE 管理面。第二個服務只作受控驗證，不得改動 VM 109 或降低 Type AI Platform 的安全邊界。

**Blocked by:** 05 — 以 IP 與 port 向 VPN 使用者發布 Type AI Platform.

**Status:** ready-for-agent

**Human action required:** 若建立第二個受控 backend、暫時放行 TCP `8082`、測試 VPN 群組或執行管理面拒絕測試需要使用者核准，標記 `[HUMAN ACTION]` 並等待。不得為測試使用真實使用者密碼或關閉既有防火牆。

- [x] 在不同於 `172.23.57.11` 的私有 IP 上建立一個最小且受控的第二測試 backend，不使用 Edge VM 作為第二 backend。
- [x] Type AI Platform 使用 `10.1.2.57:8081`，第二測試 backend 使用 `10.1.2.57:8082`。
- [x] 兩個 entrance ports 分別得到可辨識且正確的 backend 回應。
- [x] 驗證兩個 backend 可以重複使用相同的 local service port，而不需要新增 `10.1.2.x` 位址。
- [x] 驗證 WebSocket 或等效 connection upgrade 能透明通過 DNAT 到核准 backend。
- [x] client 提供的 `Forwarded` 或 `X-Forwarded-*` headers 不會被 backend 當成 Edge 產生的可信身份資訊。
- [x] 未配置的 entrance port 會被拒絕，不會落到任一 backend。
- [x] VPN client 沒有 `172.23.57.0/24` route，且不能直接連線或繞過 Edge 存取 backend。
- [ ] 一般服務使用者不能因本功能存取 `10.1.2.50:8006`；管理者原有管理路徑仍正常。
- [x] backend 只允許核准來源到 service port，且不必要的 east-west 與管理網路連線被拒絕。
- [x] 若第二測試 backend 不作長期使用，移除 TCP `8082` FortiGate／nftables 規則並安全清理測試資源，不影響 Type AI Platform。

## Comments

### 2026-08-11 controlled second-backend acceptance and cleanup

- 在 backend VM 105 暫時加入 `172.23.57.12/24`，以具 600 秒上限的 transient systemd unit 綁定 `172.23.57.12:18000`；它不在 Edge VM 上，回應 `{"service":"second-test-backend"}`，並支援最小 WebSocket handshake。
- 正式 Type AI backend 綁定 `172.23.57.11:18000`；暫時將 8082 映射到 `.12:18000`，證明兩個 private IP 可重用相同 local port。8081 回 `{"status":"ok"}`，8082 回第二服務識別內容。
- 透過 8082 送出標準 WebSocket upgrade headers，取得 `101 Switching Protocols` 與 `Upgrade: websocket`，證明 DNAT 不改寫 connection upgrade。
- 對 8081 加入 client-supplied `Forwarded`／`X-Forwarded-For` 後 health response 不變；backend app code 亦沒有 proxy-header identity reference。Edge 使用 L3/L4 DNAT，不產生可信 proxy metadata。
- 8083 被拒絕；VPN client 直連 `.11:18000` 與 `.12:18000` 均失敗。Type AI backend 的 `DOCKER-USER` 只接受 Edge `.1`，暫時來源 `.99` 被 drop；backend 主動連 `10.1.2.50:8006` 亦被 Edge outbound policy 拒絕。
- 驗收後移除 8082 nft forward／DNAT／SNAT tuples，停止並清除 transient unit、`/run` script 與 `.12` secondary IP。最終 8081 仍回 200，8082／8083 與 `.12` 均不可達。
- 此功能未新增任何指向 PVE `10.1.2.50:8006` 的 mapping，管理者既有路徑仍正常；但缺少一般服務使用者的獨立 FortiGate identity，故不能以目前具管理權限的 VPN session 證明該 user group 本身無 PVE access。
