# 05 — 以可信 HTTPS 向 VPN 使用者發布 Type AI Platform

**What to build:** 讓核准使用者只連既有 FortiClient，即可用正式 hostname 與瀏覽器信任的 HTTPS 經 `10.1.2.57` 存取 Type AI Platform；使用者不安裝 WireGuard、不修改 `hosts`，服務也不對 Internet 公開。

**Blocked by:** 04 — 在私有網路部署 Type AI Platform.

**Status:** ready-for-agent

**Human action required:** 若實作者沒有 FortiGate、內部 DNS 或公開 DNS provider 的管理權，為每個必要操作建立獨立 `[HUMAN ACTION]` 指示，說明畫面／欄位、期望值與驗證方式，然後等待使用者完成。秘密 token 不得回填到 ticket。

- [ ] 選定並記錄組織正式網域下的 Type AI Platform hostname，內部 DNS 將其解析為 `10.1.2.57`。
- [ ] FortiClient split DNS 只將所選 application suffix 導向核准的內部 DNS，使用者不需維護本機 `hosts`。
- [ ] FortiGate policy 只允許核准 VPN 群組與來源 pool 到 `10.1.2.57` 的 TCP 80/443，且不擴大 `.50:8006` 權限。
- [ ] Caddy 依正式 hostname 將請求轉送到 `172.23.57.11` 的核准應用 endpoint，未知 hostname 不會落到 Type AI Platform。
- [ ] ACME DNS-01 先在 CA staging 驗證，再取得公開信任的 production certificate；DNS credential 採最小權限且不進入 Git。
- [ ] HTTP 會重新導向 HTTPS，production HTTPS certificate 的 chain、hostname 與有效期驗證成功。
- [ ] 連上既有 FortiClient 的核准使用者能正常載入 Type AI Platform 的主要使用流程。
- [ ] 使用者不需安裝 WireGuard、第二套 VPN client、私有 CA 或修改 `hosts`。
- [ ] 未連 approved VPN 時，網站無法透過公開網路存取；公開 DNS 不暴露私有入口 A／AAAA record。
- [ ] Type AI Platform backend 仍無 VPN client 可直接連線的 route，所有網站請求皆經 Caddy。
