# 11 — Demo `443` 端點與 stack 定義入 repo

**What to build:** 讓 `172.23.57.12:443` 有一個可驗收、重開機能自行恢復、且定義在 repo 裡的 nginx 端點，作為票 08 的 DNAT 目的地。

票 04 的盤點顯示 Demo 沒有任何 listener，而且應用本體從未部署 —— 只有手動起的 nginx、Keycloak、PostgreSQL 三顆容器，全部 `Exited`，repo 沒有它們的定義，也沒有重啟策略。**本票不部署應用本體**（見 ADR-0003），只做兩件事：把 `443` 端點立起來，並把既有 stack 的定義落成 repo 追蹤的 compose，讓下一個人能重建。

開工前先跑一次唯讀補查。三個分支的處置已在 spec 預先決定，不在執行時才想：

- 三顆容器是 Compose 還是手動 `docker run` 建的、checkout 裡有沒有現成的部署定義 —— 有就沿用，沒有就用 `docker inspect` 產生
- nginx 有無 TLS 設定與憑證、憑證在哪 —— 有就沿用並記錄 fingerprint，沒有就照 UAT 模式產生自簽憑證放具名 volume
- Keycloak 的 realm 狀態在 PostgreSQL 還是容器內 —— 在 PostgreSQL 可安全重建；在容器內先匯出 realm，匯不出則以 `[HUMAN ACTION]` 停止

**不得重建 `typeai-demo-pg`。** 唯一那顆 66.65MB 匿名 volume 就是它的資料，重建會拿到一顆新的空 volume，等於刪掉資料庫。重開機恢復用 `docker update --restart unless-stopped`，不靠重建。

票 07 列出的舊絕對路徑引用（Keycloak realm import 的 bind mount）在本票改指新位置 —— 因為那個改指等於重建容器，必須連同 stack 定義一起做。重建前先以 `docker inspect` 把完整定義存進 repo。

不引入 DNS、hostname routing、憑證機構或公開信任憑證。自簽憑證比照 UAT，瀏覽器例外一次。

**Blocked by:** 07

**Status:** ready-for-agent

- [ ] 開工前的唯讀補查已執行，三個分支各按 spec 的預先決定處置
- [ ] `172.23.57.12:443` 由 nginx 提供、TLS 終結，回應可與 UAT 區分
- [ ] `/healthz` 可由 Edge 的私有位址取得
- [ ] 自簽憑證放具名 volume，fingerprint 已記錄為 root 擁有的檔案
- [ ] Demo stack 的定義已進 repo，可據以重建；重建前的 `docker inspect` 原始定義也已保存
- [ ] `typeai-demo-pg` 未被重建，那顆匿名 volume 與其資料仍在
- [ ] Keycloak 的 realm import bind mount 已改指 `/srv/platform/type-ai-platform-demo` 下的新路徑
- [ ] 三顆容器在 Demo 重開機後自動恢復，無需人工介入
- [ ] 本票未部署應用本體，也未建立任何新的憑證機構或公開信任憑證
- [ ] UAT 的 `10.1.2.57:8081` 全程不受影響
