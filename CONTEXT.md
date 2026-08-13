# 單一 IP 多網站內網平台

單一對外位址 `10.1.2.57` 承載多個內部網站的部署。使用者只連既有 FortiClient VPN，以 `10.1.2.57:<port>` 存取各服務；服務本身跑在不對 VPN 使用者路由的私有網段上。

## Language

### 網路角色

**Edge**：
持有對外位址 `10.1.2.57` 的專用 VM，執行防火牆、port DNAT 與私有 guest 的 outbound NAT。目前是 VM 104。
_Avoid_: gateway, router, reverse proxy, proxy

**Private guest**：
掛在私有 bridge 上、只能經 Edge 存取的 VM。沒有 `10.1.2.x` 位址。
_Avoid_: backend, 後端

**Private bridge**：
沒有實體 bridge port、PVE host 也沒有 IP 的 Linux bridge，私有 guest 都掛在上面。目前是 `vmbr3`。
_Avoid_: internal bridge, private network

**Entrance port**：
`10.1.2.57` 上一個對外 TCP port，DNAT 到恰好一個 private guest 的 `IP:port`。未配置的 port 一律拒絕。
_Avoid_: service port, published port, front port

### 環境

**UAT**：
Type AI Platform 的驗證環境，VM 105 `type-ai-platform-uat`。以 `ENV=dev` 假 SSO 運作，僅供受信任網路測試，不得放真實個人資料。
_Avoid_: backend, staging, test

**Demo**：
Type AI Platform 的展示環境，VM 103 `type-ai-platform-demo`。
_Avoid_: dev, sandbox

> 「backend」一詞曾同時指涉三件事：Edge 後面任何一台私有 guest、VM 105 的機器名稱、以及 UAT 這個環境。改用上列詞彙後不再使用它。
