# 02 — 建立私有網路與受控 outbound NAT

**What to build:** 建立一條從私有 guest 經 Edge VM 對外連線的完整路徑，使 guest 不需要新的 `10.1.2.x` 位址即可取得核准的更新流量，同時維持 PVE 管理路徑不變，並拒絕從前端直接轉送到私有網段。

**Blocked by:** 01 — 驗證部署先決條件與安全回復路徑.

**Status:** ready-for-agent

**Human action required:** 套用 PVE 網路變更前必須有已確認的 out-of-band 回復方式。若操作需要使用者登入 PVE、核准變更窗口或在 console 套用設定，標記 `[HUMAN ACTION]` 並等待完成；不得在缺少回復路徑時繼續。

- [ ] 建立不連接實體 NIC 的私有 Linux bridge，且 PVE host 不在 `172.23.57.0/24` 配置 IP。
- [ ] 建立專用 Edge VM；前端使用 `10.1.2.57`，後端使用 `172.23.57.1/24`，網站應用不得部署在 Edge VM。
- [ ] Edge VM 使用已驗證的外部 prefix、gateway 與 resolver，PVE `10.1.2.50:8006` 的地址、default gateway 與管理路徑保持不變。
- [ ] 啟用 IPv4 forwarding 與 nftables default-deny input／forward policy。
- [ ] 只允許私有 guest 發起的核准 outbound 流量及 established／related 回程流量，並將來源 masquerade 為 `10.1.2.57`。
- [ ] 前端不得一般性 forward 至 `172.23.57.0/24`；網站流量未來必須在 Caddy 終止。
- [ ] 使用隔離的 probe guest 驗證私有位址可以取得核准的 outbound 更新流量。
- [ ] 驗證 probe guest 不能主動連線至 `10.1.2.50:8006`，前端來源也不能直接連入 probe guest。
- [ ] 清理只為本 ticket 建立的 probe 資源，不刪除或改動任何既有 guest 資料。
- [ ] 網路設定驗證通過，且 Edge VM 重新啟動後 bridge、forwarding、防火牆與 NAT 自動恢復。
