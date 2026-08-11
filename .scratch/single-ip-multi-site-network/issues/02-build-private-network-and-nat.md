# 02 — 建立私有網路與受控 outbound NAT

**What to build:** 建立一條從私有 guest 經 Edge VM 對外連線的完整路徑，使 guest 不需要新的 `10.1.2.x` 位址即可取得核准的更新流量，同時維持 PVE 管理路徑不變，並拒絕從前端直接轉送到私有網段。

**Blocked by:** 01 — 驗證部署先決條件與安全回復路徑.

**Status:** ready-for-agent

**Human action required:** 套用 PVE 網路變更前必須有已確認的 out-of-band 回復方式。若操作需要使用者登入 PVE、核准變更窗口或在 console 套用設定，標記 `[HUMAN ACTION]` 並等待完成；不得在缺少回復路徑時繼續。

- [x] 建立不連接實體 NIC 的私有 Linux bridge，且 PVE host 不在 `172.23.57.0/24` 配置 IP。
- [x] 建立專用 Edge VM；前端使用 `10.1.2.57`，後端使用 `172.23.57.1/24`，網站應用不得部署在 Edge VM。
- [x] Edge VM 使用已驗證的外部 prefix、gateway 與 resolver，PVE `10.1.2.50:8006` 的地址、default gateway 與管理路徑保持不變。
- [x] 啟用 IPv4 forwarding 與 nftables default-deny input／forward policy。
- [x] 只允許私有 guest 發起的核准 outbound 流量及 established／related 回程流量，並將來源 masquerade 為 `10.1.2.57`。
- [x] 前端不得一般性 forward 至 `172.23.57.0/24`；只允許 port map 明確列出的 DNAT tuples，未配置 ports 維持拒絕。
- [x] 使用隔離的 probe guest 驗證私有位址可以取得核准的 outbound 更新流量。
- [x] 驗證 probe guest 不能主動連線至 `10.1.2.50:8006`，前端來源也不能直接連入 probe guest。
- [x] 清理只為本 ticket 建立的 probe 資源，不刪除或改動任何既有 guest 資料。
- [x] 網路設定驗證通過，且 Edge VM 重新啟動後 bridge、forwarding、防火牆與 NAT 自動恢復。

## Comments

### 2026-08-11 private bridge applied

- 在 node `pve` 建立 `vmbr3` Linux bridge，設定 autostart；沒有 IPv4／IPv6 CIDR、gateway、實體 bridge port 或 VLAN-aware 設定。Comment 為 `single-ip-multi-site private bridge; no host IP`。
- 透過 PVE `Apply Configuration` 以 ifupdown2 套用後，`vmbr3` 顯示 active／autostart。既有 `vmbr0`、`vmbr1`、`vmbr2` 未修改。
- 從目前 FortiClient client（來源 `10.255.254.5`）重新測試 `10.1.2.50:8006`，`TcpTestSucceeded=True`；Chrome PVE session reload 正常，證明此次新增 isolated bridge 未中斷既有管理路徑。

### 2026-08-11 Edge VM、NAT 與隔離驗收

- 以 VM 109 建立 VM 104 `single-ip-edge` full clone，兩個磁碟均位於 `VMdisk`。配置 2 vCPU、4 GiB RAM、ballooning disabled、start at boot；`eth0` 為 `10.1.2.57/24`（gateway `10.1.2.254`），`eth1` 為 `172.23.57.1/24`。
- Edge 僅承擔網路邊界角色，沒有部署網站應用。Docker 與 containerd 已停用；nftables 與 IPv4 forwarding 已永久啟用。
- nftables input／forward policy 為 default deny。前端 SSH 僅允許目前 FortiGate 實際呈現的來源 NAT peer `192.168.255.253/32`；私網 guest 只允許 DNS、NTP、HTTP、HTTPS、ICMP outbound 與 established／related 回程，並 masquerade 到 Edge 外部位址。
- DNAT 表目前沒有映射，因此 `10.1.2.57:8081` 與 `:8082` 均 fail closed。應用通過私網健康檢查後，才會在 ticket 05 加入明確的 port tuple。
- 暫時建立 VM 105 `single-ip-probe` linked clone，私網位址 `172.23.57.254/24`。Probe 成功解析 `archive.ubuntu.com`、取得 HTTPS 200、ping `1.1.1.1`；連線 `10.1.2.50:8006` 失敗。VPN client 直接連線 `172.23.57.254:22` 亦失敗。
- Probe 正常關機後已由 PVE 永久移除，task 顯示 `VM 105 - Destroy OK`；沒有修改 VM 109、VM 103 或其他既有 guest。
- Edge 重啟後 `net.ipv4.ip_forward=1`、nftables active/enabled、Docker inactive/disabled，兩條網路與 routes 均自動恢復。VPN client 驗證 `10.1.2.57:22=True`、`:8081=False`、`:8082=False`、`10.1.2.50:8006=True`。
