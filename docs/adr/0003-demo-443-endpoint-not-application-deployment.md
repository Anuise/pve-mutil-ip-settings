---
status: accepted
---

# Demo 的 `443` 由 repo 追蹤的 nginx 端點提供，應用本體部署不在本 spec

票 04 的盤點顯示 Demo 不只「搬移前沒有 listener」，而是**應用本體從未部署**：images 裡沒有 frontend／backend，只有手動起的 `typeai-demo-proxy`（nginx:1.27-alpine）、`typeai-demo-kc`（keycloak:26.0）、`typeai-demo-pg`（postgres:18-alpine）三顆，全部 `Exited`，且 repo 沒有它們的定義、也沒有重啟策略。因此本專案決定：`443` 由 Demo stack 的 nginx 提供，其定義改寫成 **repo 追蹤的 compose**，TLS 自簽憑證放具名 volume 並提供 `/healthz`，比照 UAT，使 runbook 一套涵蓋兩個環境；而**部署 Type AI Platform Demo 應用本體（build images、secrets、資料庫 migration、Keycloak realm）不屬於本 spec**。

## Considered Options

- **原樣重啟既有的手動容器。** 最省事，但那組容器沒有 repo 追蹤的定義、沒有重啟策略，票 09 要求的「重開機後無需人工介入即恢復」無法成立，且下一個人無法重建。
- **在本 spec 內一併把 Demo 應用部署完成。** 使用者拿到 `8082` 就看到 demo 應用，但需要 build frontend／backend images、產生 `.env` 與密碼、跑資料庫 migration、匯入 Keycloak realm 與處理 model cache —— 這是另一份 spec 的份量，且原 spec 從未把它列入範圍或驗收。
- **`443` 交給 repo 追蹤的 nginx 端點，應用部署另立 spec。** 選這個：entrance port 立即可驗收且可在重開機後恢復，應用部署的份量與風險不被塞進一份講網路與儲存的 spec。

## Consequences

- `10.1.2.57:8082` 的驗收語意是「可達、TLS、回應可與 UAT 區分」，**不是「Demo 應用可用」**。spec 的 user story 1 與票 08 的第一個驗收框都依此讀。
- 使用者若期待 `8082` 打開就是 demo 應用，那是後續另一份 spec 的工作，不是本工作的缺陷。
- Demo 的自簽憑證與 UAT 一樣需要瀏覽器例外一次；憑證放具名 volume，重建容器不會換憑證，刪掉 volume 才會（見 runbook 的 UAT certificate lifecycle）。
- 三顆容器裡有兩顆會被重建：`typeai-demo-kc`（bind mount 的來源路徑要改指）與 `typeai-demo-proxy`（要以具名 volume 的憑證提供 `443` 的 TLS 並開出 `/healthz`，手動起的那顆兩者都沒有）。兩顆都沒有 volume，重建不會丟掉資料。
- 既有三顆容器的定義在重建前必須先以 `docker inspect` 完整記錄並入 repo。其中 `typeai-demo-pg` 不得重建：那顆 66.65MB 的匿名 volume 是唯一且使用中的 volume，重建會產生新的空 volume，等於刪掉資料庫。重開機恢復以 `docker update --restart unless-stopped` 達成，不靠重建。
