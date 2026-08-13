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
Type AI Platform 的展示環境，VM 103 `type-ai-platform-demo`。指那台機器與它的入口，不含「已部署可用的展示應用」—— 兩者曾被同一個詞帶過。
_Avoid_: dev, sandbox

### 儲存

**Platform storage root**：
private guest 上收攏 Docker data-root、專案 checkout 與應用持久資料的單一掛載點 `/srv/platform`。由該 guest 上最大的那顆專屬 logical volume 提供，掛在 20G 的 `/srv` 之下。
_Avoid_: /srv, 大資料卷, data volume

**Model cache volume**：
Demo 上獨立的 500G xfs 卷 `/data/model-cache`，只放模型檔。不是 platform storage root 的替代品。
_Avoid_: 大資料卷, data disk

> 「backend」一詞曾同時指涉三件事：Edge 後面任何一台私有 guest、VM 105 的機器名稱、以及 UAT 這個環境。改用上列詞彙後不再使用它。
