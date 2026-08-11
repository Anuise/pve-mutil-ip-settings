# PVE 單一 IP 多網站網路架構研究

> **Implementation decision (2026-08-11):** 使用者已取消 DNS、hostname routing、ACME 與公開信任 TLS，改採 `10.1.2.57:<port>`。目前 spec 以 nftables 明確 DNAT 為準：Type AI Platform 使用 TCP `8081`，第二驗證服務暫用 TCP `8082`。本文其餘 DNS／Caddy／TLS 內容保留為已捨棄方案的研究紀錄，不是目前實作要求。

研究日期：2026-08-11

## 結論

本案不新增 WireGuard。採用以下架構：

- `10.1.2.57` 是 VPN 使用者唯一會連到的網站入口。
- PVE 保留 `10.1.2.50:8006` 作管理介面，不把管理頁納入網站入口。
- PVE 新增一個不接實體網卡的私有 Linux bridge，例如 `vmbr1`；後端 VM/LXC 只使用私有位址。
- 建立一台專用 edge VM，前端網卡使用 `10.1.2.57`，後端網卡接 `vmbr1`。該 VM 執行 Caddy、nftables、IPv4 forwarding 與 outbound NAT。
- 所有網站名稱在 VPN 內解析為 `10.1.2.57`；Caddy 依 hostname 將 HTTPS 請求轉送到不同私有後端。
- TLS 使用組織持有的正式網域與 ACME DNS-01，讓瀏覽器取得公開信任的憑證，不要求每位使用者另裝私有 CA。

WireGuard 是建立另一個加密 L3 tunnel 的工具，不是單一 IP 上承載多個網站所需的分流元件。現有 FortiClient VPN 已讓使用者到達 `10.1.2.0/24`，再加 WireGuard只會增加第二套金鑰、路由與 tunnel 的管理工作。

## 假設與必須先確認的事項

目前資訊不足以直接產生可套用的網路設定；下列項目是實施的硬性先決條件：

1. `10.1.2.57` 已正式保留，不在 DHCP pool 中，也沒有其他設備使用。
2. 確認實際 subnet mask、default gateway、DNS server、FortiOS/FortiClient 版本與 VPN 類型（SSL VPN 或 IPsec）。
3. FortiGate 的 VPN route 與 firewall policy 確實允許目標 `10.1.2.57` 的 TCP `80/443`。能到 `10.1.2.50` 不代表 policy 必然也涵蓋 `.57`。
4. PVE 所接交換器埠允許 edge VM 的額外 MAC address。PVE bridged networking 會讓外部網路看見每台 VM 自己的 MAC；若有 port security，只允許 PVE 主機 MAC，本方案不能直接套用。[Proxmox VE Network Configuration](https://pve.proxmox.com/wiki/Network_Configuration)
5. 選定的私有 CIDR 不得與公司路由、VPN client 本地網路、Docker/容器網路或其他 site-to-site 網段重疊。本文暫用 `172.23.57.0/24`，實施前必須完成衝突檢查。
6. 組織能管理一個已註冊網域的公開 DNS，以及 VPN 使用的內部 DNS/split DNS。
7. DNS provider 有可自動更新 TXT record 的 API，並有對應的 Caddy DNS provider module；否則必須改用組織既有 ACME/憑證自動化流程。
8. 所有要共用 `80/443` 的服務是 HTTP/HTTPS，或明確支援 reverse proxy。SSH、RDP、資料庫等任意非 HTTP 協定不能靠 HTTP hostname 無限制共用同一個 port。
9. 變更 PVE 網路前有實體 console、IPMI/iKVM 或其他 out-of-band 回復方式；錯誤網路設定可能讓 PVE 遠端失聯。Proxmox 官方亦建議透過 GUI/ifupdown2 套用並先檢查 staged configuration。[Proxmox VE Network Configuration](https://pve.proxmox.com/wiki/Network_Configuration)

## 已選架構

```text
FortiClient 使用者
        |
        | 既有 VPN；只需到 10.1.2.57:443
        v
FortiGate / 10.1.2.0/24
        |
        v
PVE vmbr0 ── PVE 管理：10.1.2.50:8006
        |
        └── Edge VM front：10.1.2.57
              - Caddy：TLS termination + hostname routing
              - nftables：default-deny firewall
              - NAT/router：僅供私有 guest 對外連線
              |
              | Edge VM back：172.23.57.1/24
              v
PVE vmbr1（bridge-ports none；PVE host 不配此網段 IP）
        ├── app1：172.23.57.11:8080
        ├── app2：172.23.57.12:3000
        └── appN：172.23.57.x:port
```

Proxmox 將 Linux bridge 描述為虛擬交換器；`bridge-ports none` 可建立只供 guests 使用的私有 L2 segment。官方也把單一外部 IP、私有 guest、masquerading 與 incoming port forwarding 列為標準網路模型。[Proxmox VE Network Configuration](https://pve.proxmox.com/wiki/Network_Configuration)

本案將 NAT/router 放在 edge VM 而非 PVE host，原因是這樣只需在 PVE 新增被動的私有 bridge，不必讓網站流量的轉送與防火牆規則直接進入 PVE 管理作業系統。這是基於安全邊界與回復難度的設計選擇；NAT 本身仍使用 Linux 標準功能。

### 封包路徑

網站請求不使用 DNAT：

1. VPN client 解析 `app1.apps.example.com`，得到 `10.1.2.57`。
2. client 連到 edge VM 的 `10.1.2.57:443`。
3. Caddy 終止 TLS，依 hostname 選擇 backend。
4. Caddy 由私有介面連到 `172.23.57.11:8080`。

guest 對外更新套件才使用 L3 forwarding 與 source NAT：

1. guest 的 default gateway 是 `172.23.57.1`。
2. edge VM 開啟 IPv4 forwarding。
3. nftables 只允許私有網段主動對外，以及對應的 `established/related` 回程封包。
4. nftables 在 postrouting 將 `172.23.57.0/24` masquerade 成 `10.1.2.57`。

nftables 官方文件定義 masquerade 是 postrouting 的特殊 SNAT，也提供 stateful forwarding/NAT 的 router 範例。[nftables NAT](https://wiki.nftables.org/wiki-nftables/index.php/Performing_Network_Address_Translation_%28NAT%29)、[nftables simple router ruleset](https://wiki.nftables.org/wiki-nftables/index.php/Simple_ruleset_for_a_home_router)

## 為何一個 IP 能承載很多網站

HTTP request 帶有目標 host；TLS 則可透過 SNI 在握手時指出 server name。反向代理因此可以讓多個 hostname 共用同一個 `IP:443`，再將它們送往不同 backend。[RFC 9110：Host and :authority](https://www.rfc-editor.org/rfc/rfc9110.html#name-host-and-authority)、[RFC 6066：Server Name Indication](https://www.rfc-editor.org/rfc/rfc6066.html#section-3)

Caddy 的 site address 可為不同 hostname 建立 site block，`reverse_proxy` 可把各 site 送往不同 upstream，並支援 WebSocket upgrade。[Caddyfile concepts](https://caddyserver.com/docs/caddyfile/concepts)、[Caddy reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)

概念設定如下，實際名稱、位址與 port 應由服務清單產生：

```caddyfile
app1.apps.example.com {
    reverse_proxy 172.23.57.11:8080
}

app2.apps.example.com {
    reverse_proxy 172.23.57.12:3000
}
```

未知 hostname 應回傳固定錯誤，不可落到任一網站；backend 若依 `X-Forwarded-*` 判斷 client identity 或權限，必須只信任 edge VM，不可直接信任 client 傳入的同名 header。

## DNS 與憑證決策

### DNS

使用組織持有的正式網域子區，例如 `apps.example.com`：

- VPN 內部 DNS：`app1.apps.example.com`、`app2.apps.example.com` 等 A record 全部指向 `10.1.2.57`；若命名規則固定，可用 wildcard A record。
- 公開 DNS：不必公開私有 A record；只需讓 ACME CA 能查到 `_acme-challenge` TXT record。
- FortiGate/FortiClient：將 `apps.example.com` 設為 split DNS suffix，讓該 suffix 的查詢在 VPN 內送往指定的內部 DNS。Fortinet 官方文件明載 SSL VPN portal 可按 domain/suffix 指派 DNS server；實際欄位須以現場 FortiOS 與 VPN 類型為準。[FortiGate SSL VPN split DNS](https://docs.fortinet.com/document/fortigate/7.2.11/administration-guide/988717)

不採用每位使用者手改 `hosts`，因為不可集中更新、不可擴充，也無法可靠管理大量網站。

### TLS

選擇公開信任的憑證與 ACME DNS-01：

- DNS-01 透過 `_acme-challenge.<domain>` 的 TXT record 證明網域控制，不要求 CA 連到內部 web server，並可簽發 wildcard certificate。[ACME RFC 8555 §8.4](https://www.rfc-editor.org/rfc/rfc8555.html#section-8.4)、[Let's Encrypt challenge types](https://letsencrypt.org/docs/challenge-types/#dns-01-challenge)
- Caddy 可使用 DNS provider module 自動完成 DNS challenge；這不要求開放外部 port，但需要安全保存 DNS API credential。[Caddy automatic HTTPS：DNS challenge](https://caddyserver.com/docs/automatic-https#dns-challenge)
- DNS API token 僅授權 challenge 所需的 zone/record；若 provider 支援，將 `_acme-challenge` 以 CNAME/NS 委派到獨立驗證 zone，避免把整個 production DNS 的權限放在 edge VM。Let's Encrypt 官方確認 DNS-01 可用 CNAME 或 NS 委派。[Let's Encrypt challenge types](https://letsencrypt.org/docs/challenge-types/#dns-01-challenge)

不選 Caddy internal CA。Caddy 官方說明，其他裝置若要信任 local HTTPS，必須安裝其 root CA；這不符合「使用者只連既有 VPN 即可用瀏覽器」的目標。[Caddy local HTTPS](https://caddyserver.com/docs/automatic-https#local-https)

不要以 `https://10.1.2.57` 作正式入口。公開 CA 不得為 Internal Name 或 Reserved IP Address 發證；正式入口必須使用可驗證的 DNS name。[CA/Browser Forum Baseline Requirements](https://cabforum.org/working-groups/server/baseline-requirements/requirements/)

## WireGuard 決策

**不採用 WireGuard。**

WireGuard 的 `AllowedIPs` 在送出方向近似 routing table、在接收方向近似 ACL；使用它仍需建立介面、交換金鑰、配置 peer、route 與可能的 NAT/firewall traversal。[WireGuard Cryptokey Routing](https://www.wireguard.com/#cryptokey-routing)、[WireGuard Quick Start](https://www.wireguard.com/quickstart/)

本案的 client 已透過 FortiClient 到達 `10.1.2.57`，而多網站問題由 DNS + HTTP Host/TLS SNI + reverse proxy 解決。WireGuard不會增加可供網站分流的外部 IP，也不會取代 DNS 或 reverse proxy。

WireGuard 只有在下列需求改變時才重新評估：

- client 必須直接存取每個私有 VM 的 SSH/RDP/DB 等非 HTTP 服務；
- 無法調整 FortiGate/upstream route，且可接受每位使用者安裝並維護第二個 VPN client；
- 需要跨不同站點或不受信任網路建立 site-to-site 加密 overlay。

即使要讓既有 FortiClient 使用者直接存取私有 subnet，優先方案也是由 FortiGate/upstream 加入到該 subnet 的 L3 route 與 firewall policy；這不需要 client 再裝 WireGuard。

## L2/L3 條件與替代路徑

### 已選方案的條件

- L2：edge VM 的 front NIC 接 `vmbr0`，以自己的 MAC 使用 `10.1.2.57`。交換器與 NAC/port-security 必須允許該 MAC。
- L3：VPN client 只需有到 `10.1.2.57` 的既有 route；不需要知道 `172.23.57.0/24`。
- 回程：edge VM 的 front default gateway 使用 `10.1.2.0/24` 現場既有 gateway；私有 guests 的 default gateway 使用 edge VM 的 `172.23.57.1`。
- `vmbr1` 不接實體 NIC；PVE host 不在該 subnet 配 IP，避免讓 backend 直接碰到 PVE host 的 L3 management surface。

### 未選的直接 routed subnet

若 VPN user 要直接連 `172.23.57.x`，FortiGate/upstream 必須有 `172.23.57.0/24` 的 route、VPN split-tunnel 必須下發該 route、兩側需有正確回程，並要新增精細 firewall policy。這會擴大 VPN user 可見的攻擊面；純網站需求沒有必要採用。

若交換器不允許 edge VM 的額外 MAC，不能偷偷改成另一種 L2 假設。此時要由網路管理者在 upstream 建立 `/32` route，或讓 PVE host 接管 `.57` 並做 routing/DNAT；兩者都會改變安全邊界，應另行評估而非視為原方案的小修改。

## 安全邊界

- FortiGate：VPN 到 `10.1.2.57` 僅允許 TCP `80/443`，並以實際使用者群組與來源 pool 限制；一般網站使用者不得因此取得 `10.1.2.50:8006` 權限。
- Edge VM input：default deny；允許 loopback、必要 ICMP、`established/related`、指定 VPN/LAN 來源的 `80/443`。SSH 僅允許管理來源與金鑰驗證。
- Edge VM forward：default deny；不允許 front 主動 forward 到 private subnet。只允許 private guests 必要的 outbound 流量及回程。
- Edge VM/Caddy 到 backend：只開各網站實際 port。每個 guest 的 PVE/guest firewall 僅允許 edge VM 私有 IP 連入 web port。
- Backend east-west：預設不互信；需要互通的應用再明列規則。單一 flat `vmbr1` 的 guests 在 L2 上相鄰，必須依靠 PVE per-guest firewall 或 guest firewall 落實。
- PVE 管理：維持獨立的 `.50:8006`，不經 Caddy、不使用公開網站 hostname，也不把 PVE API credential 放進 edge VM。
- TLS 到 backend：若 backend segment 的威脅模型要求加密，使用可驗證的 upstream certificate/trust pool；不要使用 `tls_insecure_skip_verify`。Caddy 官方明確警告該選項會關閉 TLS 驗證。[Caddy reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#https)
- Credential：DNS API token、ACME account key、Caddy private key 與備份均視為機密；限制檔案權限並避免寫入 repo。

edge VM 同時是 reverse proxy 與 router，是為了在目前小型、VPN-only、單 PVE 的條件下保持最少元件。接受的代價是 edge VM 被入侵或停止時，入口與 guest outbound 會一起受影響；若風險或規模提升，再拆成 firewall/router VM 與 proxy VM，並切分 DMZ/backend segment。

## 單點失效

在「一台 PVE + 一個入口 IP」限制下，以下都是單點：

- PVE 實體主機、NIC、交換器 uplink；
- edge VM、Caddy、nftables 設定與 `10.1.2.57`；
- VPN/FortiGate path；
- 內部 DNS；
- ACME renewal 所需的公開 DNS API。

WireGuard不會消除任何上述單點。現階段可做的是：edge VM 設定開機自動啟動、備份 VM 與 Caddy/nftables 設定、保存可重建文件、監控 DNS/HTTPS/backend/憑證到期日，並定期做還原演練。

真正的高可用需要至少第二台 PVE/edge instance、可移動或可負載平衡的入口 IP、同步設定及避免 split-brain 的機制；這超出目前資源條件。

## 工具選擇簡表

| 工具 | 官方能力 | 本案決策 |
|---|---|---|
| Caddy | hostname site blocks、reverse proxy、自動 HTTPS/DNS challenge | 採用；靜態 VM/LXC backend 的設定最直接 |
| Nginx | `server_name` 選擇 virtual server，`proxy_pass` 到 backend | 可行，但憑證自動化需另組流程；不採用。[Nginx server names](https://nginx.org/en/docs/http/server_names.html)、[proxy module](https://nginx.org/en/docs/http/ngx_http_proxy_module.html) |
| HAProxy | ACL/content switching 與進階 L4/L7 load balancing | 可行，但目前需求不需其較進階的 LB 配置；不採用。[HAProxy proxying essentials](https://www.haproxy.com/documentation/haproxy-configuration-tutorials/proxying-essentials/) |
| Traefik | Host rules、動態 provider/service discovery、TLS routers | 若網站全由 Docker/Kubernetes labels 動態管理才較有優勢；混合 PVE VM/LXC 不採用。[Traefik routers](https://doc.traefik.io/traefik/routing/routers/) |
| WireGuard | 加密 L3 tunnel、cryptokey routing | 不解決單 IP hostname 分流，且與既有 VPN 重疊；不採用 |

## 實施順序與驗收

1. 盤點與保留資源：確認 `.57`、CIDR、gateway、額外 MAC、FortiGate route/policy、DNS 控制權與非 HTTP 服務。
2. 建立 `vmbr1` 與 edge VM，但不改動 PVE `.50` 的 management address/default gateway。
3. 在 edge VM 完成 nftables、forwarding 與 NAT；先驗證一台測試 guest 能對外、不能由 front 直接進入。
4. 安裝 Caddy，先以測試 hostname/backend 驗證 routing，再接正式 DNS-01。正式簽發前使用 CA staging environment，避免反覆測試觸發 rate limit。
5. 設定內部 DNS 與 FortiClient split DNS，最後才逐站加入 Caddy。
6. 啟用 PVE/guest firewall、備份、監控與自動啟動；完成 reboot/restore 測試。

完成標準：

- 使用者只連既有 FortiClient，不裝 WireGuard、不改 `hosts`。
- `app1`、`app2` 等名稱都解析為 `10.1.2.57`，但分別抵達正確 backend。
- 瀏覽器顯示公開信任、hostname 相符且可自動續期的 HTTPS 憑證。
- 未知 hostname 不會落到任一 backend。
- VPN client 沒有到私有 subnet 的 route，也不能直接掃描/連線 backend。
- guest 能做必要的 outbound 更新，但不能主動存取 PVE `10.1.2.50:8006`。
- PVE 管理頁仍只在原有 `.50:8006` 管理路徑上使用。
- PVE/edge VM reboot 後，bridge、firewall、NAT、Caddy、DNS 與所有必要服務能自動恢復。
