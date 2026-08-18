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

**CIB**：
VM 103 `cib-ai-platform`，entrance port `8082`。取代 Demo 的那台機器：同一個 VMID、同一個私有位址 `172.23.57.12`、同一個 entrance port，但**不是舊機器的延續** —— 舊 Demo 未備份直接銷毀（[ADR-0006](docs/adr/0006-replace-103-with-cib-ai-platform-no-backup.md)），新機器由範本 109 重建，身上沒有任何舊資料。抽換程序在 `.scratch/cib-ai-platform-rebuild/`，**尚未執行** —— 在票 01 跑完之前，VM 103 上跑的還是舊 Demo。指那台機器與它的入口，不含「已部署可用的應用」。
_Avoid_: Demo, dev, sandbox

### 儲存

**Platform storage root**：
UAT（VM 105）上收攏 Docker data-root、專案 checkout 與應用持久資料的單一掛載點 `/srv/platform`。由該 guest 上最大的那顆專屬 logical volume 提供，掛在 20G 的 `/srv` 之下。**只適用於 UAT** —— CIB 從範本 109 重建後不再有這一層（ADR-0002 隨舊機器一併作廢）。CIB 上也沒有 checkout：deploy key 隨舊機器消失（ADR-0006）。
_Avoid_: /srv, 大資料卷, data volume

**Model cache volume**：
`/data/model-cache`，只放模型檔，不是 platform storage root 的替代品。舊 103 上那顆 500G xfs 卷從未被使用，重建時不帶過來；這個詞在重建後沒有對應的實體。
_Avoid_: 大資料卷, data disk

> 「Demo」一詞已退場：VM 103 上的環境自 2026-08-18 起由 CIB 取代（ADR-0006），舊機器與它身上的東西都不存在了。

> 「backend」一詞曾同時指涉三件事：Edge 後面任何一台私有 guest、VM 105 的機器名稱、以及 UAT 這個環境。改用上列詞彙後不再使用它。
