# 07 — 應用資料自 `/home` 搬至 `/srv/platform`

**What to build:** 讓 Demo 的專案 checkout 與應用持久資料落在 `/srv/platform` 下對應位置，擺放方式與 UAT 一致。

**家目錄本身留在原處不動。** UAT 從未搬過家目錄；「結構參考 UAT」指的是應用資料的擺放，不是家目錄的搬遷。搬它會動到 shell 設定、SSH 授權與 user-level services，而且沒有前例可循。

複製、驗證、延後刪除：

- 複製時保留屬性、hard link 與 sparse 特性
- 逐檔比對來源與目標的 SHA-256。複製工具的結束碼不算證據
- **來源保留不刪**。刪除由票 10 在驗收通過後執行

搬移界線依票 05 的決定，不自行擴張：

- 搬：`type-ai-platform-demo` checkout（694M）到 `/srv/platform/type-ai-platform-demo`。保留原目錄名，不改叫 UAT 的 `type-ai-platform` —— 那是另一個 checkout，同路徑會讓人誤以為同一份 revision
- 建空的 `/srv/platform/app-data`，比照 UAT 的形狀。Demo 目前的持久資料在 Docker volume 裡，隨 data-root 一起移動，本票不搬它
- 不搬：`.venvs`（465M，衍生環境，腳本內含硬編路徑，可重建）、`.claude`、`.vscode-server`、`.cache`、`.local`、`.npm`（開發工具）、`rfp-workspace`（19M，與 Demo 應用無關）

票 04 列出的引用舊絕對路徑的設定，本票只負責**列出**。唯一那一條是 Keycloak realm import 的 bind mount，改指它等於重建容器，因此改指動作交給票 11 連同 stack 定義一起做。

**Blocked by:** 06

**Status:** done —— 已執行完成，成果隨 VM 103 銷毀（見 `.scratch/demo-rebuild-from-template/spec.md`）

- [ ] `type-ai-platform-demo` checkout 存在於 `/srv/platform/type-ai-platform-demo`，`/srv/platform/app-data` 已建立
- [ ] 每一個搬移檔案的來源與目標 SHA-256 相符，且比對結果有記錄
- [ ] `/home/mobagel` 下的來源資料仍然存在
- [ ] 家目錄本身未被搬移，shell 設定、SSH 授權與 user-level services 仍可運作
- [ ] `.venvs`、開發工具目錄與 `rfp-workspace` 未被搬移
- [ ] 引用舊路徑的設定已列出並移交票 11 改指
- [ ] `/srv/platform` 剩餘空間仍至少二成
