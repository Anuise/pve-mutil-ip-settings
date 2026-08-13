# 08 — Edge 開通 entrance port 8082

**What to build:** 一個已連上既有 FortiClient VPN 的使用者，以 `10.1.2.57:8082` 就能存取 Demo；同時 `10.1.2.57:8081` 仍然是 UAT，兩者可區分。

先移除 Demo 舊有的對外直連 listener —— Demo 只能經 entrance port 被存取。

依既有慣例，三條規則一起加，不拆：

- forward 放行：限定核准的 VPN 來源、單一私有 guest 位址、單一轉譯 port
- destination NAT：`8082` 到 `172.23.57.12:443`
- source NAT 到 Edge 的私有位址，使 Demo 只會看到 Edge 為來源，不需要信任 client 提供的 proxy header

不建立 port range 或 catch-all。Edge 的 input 與 forward 預設拒絕政策不放寬。

安裝前先驗證候選設定，並備份現行設定。repo 追蹤的 ruleset、runbook 配置表與 port map 在同一次變更中一併更新，讓文件狀態與執行狀態一致。

不引入 DNS、hostname routing、反向代理、憑證機構或公開信任憑證。Demo 使用自簽憑證，瀏覽器可能需要一次例外。

DNAT 的目的地在票 11 已經有人在聽。「回應 Demo」指的是那個 nginx 端點的 TLS 回應且可與 UAT 區分，不是「Demo 應用可用」—— 應用本體部署不在本 spec，見 ADR-0003。

**Blocked by:** 11

**Status:** ready-for-agent

- [ ] `10.1.2.57:8082` 回應 Demo 的 nginx 端點，且可與 UAT 的回應區分
- [ ] `10.1.2.57:8081` 仍回應 UAT，行為不變
- [ ] HTTP 與 WebSocket 流量可透明通過 `8082`
- [ ] 未配置的 port fail closed，且不會落到任何環境
- [ ] 從 VPN client 無法直接連到 `172.23.57.12`
- [ ] 未連 VPN 時 `8082` 與 `8081` 皆不可達
- [ ] Demo 觀察到的連線來源為 Edge 的私有位址
- [ ] Demo 原有的對外直連 listener 已移除
- [ ] Edge 的預設拒絕政策未被放寬，僅新增這一組規則
- [ ] 候選設定在安裝前通過驗證，且現行設定已備份
- [ ] repo 的 ruleset、runbook 配置表與 port map 與執行狀態一致
- [ ] 管理端點 `10.1.2.50:8006` 未被改動或代理
- [ ] Edge 的 log 涵蓋新 entrance port 的拒絕與轉送失敗
