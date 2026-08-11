# 04 — 在私有網路部署 Type AI Platform

**What to build:** 在新的私有 backend VM 上，從核准的 Git repository 部署 Type AI Platform，使用 `.secrets` 中對應的 backend 環境資料建立可重現且不洩漏秘密的設定，並在尚未對 VPN 使用者發布前完成私有健康檢查。

**Blocked by:** 03 — 從 VM 109 建立 Type AI Platform backend.

**Status:** ready-for-agent

**Human action required:** 若私人 GitLab 尚無核准的 non-interactive credential，或應用所需環境 key 未出現在 `.secrets`，只列出所需 credential 類型或缺少的 key 名稱，標記 `[HUMAN ACTION]` 並等待。不得要求使用者把 secret value 貼入 ticket 或一般 log。

- [ ] 從 `https://source.mobagel.com/type-ai-platform/type-ai-platform.git` 取得專案，不使用未核准的 mirror 或來源。
- [ ] 記錄實際部署的 immutable commit revision，且記錄內容不包含 Git credential。
- [ ] 專案 checkout 位於 ticket 03 選定的 `/srv` filesystem，Docker image layers、container writable layers 與持久資料不消耗 root filesystem。
- [ ] 在建立或更動部署 `.env` 前，讀取 repository-local `.secrets` hierarchy 中對應的 backend 環境來源，並與專案要求的 key 集合比較。
- [ ] 既有 secret value 不出現在 terminal transcript、ticket、測試輸出、Git diff 或 commit；驗證只報告 key 名稱、存在狀態與格式結果。
- [ ] 缺少的必要 key 不以猜測值、空字串或不安全預設取代，且正確觸發 `[HUMAN ACTION]`。
- [ ] Type AI Platform 的 containers 能在 backend VM 上成功啟動，失敗服務不會被視為可發布。
- [ ] 從 Edge VM 私有介面可以連到應用的核准 backend endpoint，並取得明確的健康回應。
- [ ] VPN client 尚不能經 `10.1.2.57` 存取應用，證明此 ticket 沒有提前公開未完成服務。
- [ ] 記錄部署後 `/srv` 使用量並證明選定 filesystem 仍保有至少百分之二十可用空間。
