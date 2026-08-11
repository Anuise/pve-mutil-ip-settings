# 05 — 以 IP 與 port 向 VPN 使用者發布 Type AI Platform

**What to build:** 讓核准使用者只連既有 FortiClient，即可透過 `http://10.1.2.57:8081` 存取 Type AI Platform；使用者不安裝 WireGuard、不設定 DNS 或 `hosts`，服務也不對 Internet 公開。

**Blocked by:** 04 — 在私有網路部署 Type AI Platform.

**Status:** ready-for-agent

**Human action required:** FortiGate 管理資料無法取得。正式啟用後必須由目前核准的 FortiClient session 重跑 `Test-NetConnection 10.1.2.57 -Port 8081`；若失敗，立即停止發布並回報阻擋，不擴大 port、不新增 tunnel，也不繞過公司政策。

- [x] 記錄 Type AI Platform 入口為 `http://10.1.2.57:8081`，且此 port 未被其他服務配置使用。
- [x] 目前核准的 FortiClient session 對 `10.1.2.57:8081` 重跑 empirical test 並得到 `TcpTestSucceeded=True`；記錄來源位址、目的 port 與時間點，不宣稱已知 FortiGate policy scope。
- [x] Edge nftables 將 TCP `8081` DNAT 到 `172.23.57.11` 的核准應用 endpoint，並保留 established／related 回程流量。
- [x] 未配置的 entrance ports 維持 default-deny，不存在 catch-all backend。
- [ ] 連上既有 FortiClient 的核准使用者能透過 `10.1.2.57:8081` 正常載入 Type AI Platform 的主要使用流程。
- [x] HTTP 與 WebSocket／connection upgrade 等應用協定可透明通過 DNAT，不依賴 hostname 或 proxy headers。
- [x] 使用者不需安裝 WireGuard、第二套 VPN client、DNS 設定、私有 CA 或修改 `hosts`。
- [ ] 未連 approved VPN 時，`10.1.2.57:8081` 無法透過公開網路存取。
- [x] Type AI Platform backend 仍無 VPN client 可直接連線的 route，所有使用者流量皆經 Edge 的明確 port mapping。
- [x] 驗收明確記錄初版為 VPN 內 HTTP，不宣稱具備公開信任 TLS；未來若要加入 TLS，另立設計與驗收變更。

## Comments

### 2026-08-11 backend API published on TCP 8081

- 在私網 health 通過後才啟用 Edge mapping：FortiGate empirical source peer `192.168.255.253` 的 TCP `8081` DNAT 至 `172.23.57.11:18000`，並 SNAT 成 Edge 私網位址 `172.23.57.1`；forward 規則只允許此明確 tuple 與 established／related 回程。
- nft candidate 每次先以 `nft -c -f` 驗證，成功後才備份並取代 `/etc/nftables.conf`。目前套用設定的 repo snapshot 為 `.scratch/single-ip-multi-site-network/nftables.edge.conf`。
- 2026-08-11 由目前 FortiClient interface `乙太網路 3`、client source `10.255.254.5` 執行 `Test-NetConnection 10.1.2.57 -Port 8081`，結果 `TcpTestSucceeded=True`。這仍只是時間點限定 empirical validation，不代表已知 FortiGate policy scope。
- 黑箱測試：`/healthz`、`/docs`、`/openapi.json` 均回 HTTP 200；8082、8083 fail closed；client 直接連 `172.23.57.11:18000` 失敗；既有 `10.1.2.50:8006` 管理路徑仍正常。
- 初版使用 VPN 內 HTTP，沒有 DNS、WireGuard、private CA、`hosts` 修改或公開信任 TLS。未從 off-VPN/public Internet 執行測試，因此「公開網路不可達」仍待獨立外部驗證，不能僅由私網結果推定。
- 目前發布的是 repository 已可運作的 backend API 與 API docs。Frontend 的 production static image／單埠同源 routing 尚未由來源 repo 提供，因此「主要 UI 使用流程」仍未宣稱通過。
