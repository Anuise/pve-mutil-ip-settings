# 04 — 在私有網路部署 Type AI Platform

**What to build:** 在新的私有 backend VM 上，從核准的 Git repository 部署 Type AI Platform，使用 `.secrets` 中對應的 backend 環境資料建立可重現且不洩漏秘密的設定，並在尚未對 VPN 使用者發布前完成私有健康檢查。

**Blocked by:** 03 — 從 VM 109 建立 Type AI Platform backend.

**Status:** ready-for-agent

**Human action required:** 若私人 GitLab 尚無核准的 non-interactive credential，或應用所需環境 key 未出現在 `.secrets`，只列出所需 credential 類型或缺少的 key 名稱，標記 `[HUMAN ACTION]` 並等待。不得要求使用者把 secret value 貼入 ticket 或一般 log。

- [x] 從 `https://source.mobagel.com/type-ai-platform/type-ai-platform.git` 取得專案，不使用未核准的 mirror 或來源。
- [x] 記錄實際部署的 immutable commit revision，且記錄內容不包含 Git credential。
- [x] 專案 checkout 位於 ticket 03 選定的 `/srv` filesystem，Docker image layers、container writable layers 與持久資料不消耗 root filesystem。
- [x] 在建立或更動部署 `.env` 前，讀取 repository-local `.secrets` hierarchy 中對應的 backend 環境來源，並與專案要求的 key 集合比較。
- [x] 既有 secret value 不出現在 terminal transcript、ticket、測試輸出、Git diff 或 commit；驗證只報告 key 名稱、存在狀態與格式結果。
- [x] 缺少的必要 key 不以猜測值、空字串或不安全預設取代，且正確觸發 `[HUMAN ACTION]`。
- [x] Type AI Platform 的 containers 能在 backend VM 上成功啟動，失敗服務不會被視為可發布。
- [x] 從 Edge VM 私有介面可以連到應用的核准 backend endpoint，並取得明確的健康回應。
- [x] VPN client 尚不能經 `10.1.2.57` 存取應用，證明此 ticket 沒有提前公開未完成服務。
- [x] 記錄部署後 `/srv` 使用量並證明選定 filesystem 仍保有至少百分之二十可用空間。

## Comments

### 2026-08-11 `[HUMAN ACTION]` private GitLab credential required

- Backend VM 105 已符合 ticket 03 先決條件，checkout 目標為 `/srv/platform/type-ai-platform`。
- 在 VM 105 使用 `GIT_TERMINAL_PROMPT=0` 對核准來源 `https://source.mobagel.com/type-ai-platform/type-ai-platform.git` 執行唯讀 `git ls-remote ... HEAD`，GitLab 回覆需要 Username；未顯示密碼提示、未送出 credential，也未使用 mirror。
- 請在 VM 105 配置公司核准的 non-interactive GitLab credential（例如 read-only deploy key 或 project access token，由公司密碼管理流程傳遞）。不要把 secret value 貼入本 ticket 或一般對話。完成後只需回覆「GitLab credential 已配置」，即可繼續部署與環境 key schema 驗證。

### 2026-08-11 `[HUMAN ACTION]` GitLab token rotation required

- 使用者指定本機 ignored secret file 作為 GitLab token 來源。第一次 clone 嘗試使用的臨時 `.netrc` 未被 Git 採用；檔案已由 trap 清除。第二次嘗試的 credential-helper 格式錯誤，使 Git 的錯誤訊息將 credential material 編碼後帶入工具輸出。
- 該 token 必須視為已洩漏並立即在 GitLab 撤銷／輪替；不得繼續使用。請以新 token 覆寫原 secret file，且不要將值貼入對話或 ticket。
- VM 105 已驗證沒有 `~/.netrc`、`~/.git-credentials`、臨時 credential directory 或 partial Git repository；`/srv/platform/type-ai-platform` 尚未部署任何程式碼。

### 2026-08-11 repository checkout completed; `[HUMAN ACTION]` environment correction required

- 使用者已輪替 GitLab token。新 token 透過 SSH stdin 與短生命週期 `GIT_ASKPASS` 使用，未放入 URL、process argument、remote URL 或永久 credential store；clone 後再次驗證沒有臨時 askpass directory、`~/.netrc` 或 `~/.git-credentials`。
- 核准來源初始 clone 到 `/srv/platform/type-ai-platform` 的 revision 為 `0f1816f4585668847c0c7e1f9fe348a8327d1dde`；2026-08-12 UAT cutover 已 fast-forward 到 `25201dbf1ba3475ebe9a69356c551e6394937f26`，working tree clean，origin 不含 credential。
- 已在不輸出 value 的前提下，比對 `apps/backend/.env.example`、`Settings` schema 與 repository-local `.secrets/apps/backend/.env`。必填 `ENV`、`DATABASE_URL`、`CLICKHOUSE_URL`、`SESSION_SECRET` 均存在；URL scheme 與 `ENV` enum 格式通過。
- `SESSION_SECRET` 未達此次部署採用的 32 字元最低安全門檻，因此停止在啟動 containers 之前。請在 ignored source `.secrets/apps/backend/.env` 更新為至少 32 字元的強隨機值，不要將 value 貼入對話或 ticket。
- `LEADTEK_API_KEY` 未出現在 secret source，但目前程式 schema 定義為 optional，不是本階段啟動阻擋；其餘 optional keys 依 source 保持原狀。

### 2026-08-11 backend deployment completed

- 使用者授權直接產生新 `SESSION_SECRET`，且沒有既有 session 需保留。以 cryptographic RNG 產生 32 random bytes 後寫入 ignored `.secrets/apps/backend/.env`；只驗證單一 key 存在、長度至少 32 字元與 `git check-ignore=True`，value 未出現在對話、terminal、issue、Git diff 或 log。
- Env source 以 SCP 傳入 VM 105 的 `apps/backend/.env`，mode `0600`；remote repo 亦確認該檔被 Git ignore。Compose `config -q` 通過，沒有輸出 resolved environment。
- 初始部署時 repository 只提供 development Dockerfiles／Compose；2026-08-12 UAT revision 新增 `Dockerfile.prod`、UAT Compose 與 nginx。現行 VM 使用 UAT frontend、backend、poller、Postgres、ClickHouse、nginx，但仍未標示為 production-ready。
- 建立 Git 之外的 `/srv/platform/app-data/type-ai-platform/compose.deploy.yml`：Postgres `15432` 與 ClickHouse `8123` 只綁 `127.0.0.1`；backend 只綁 `172.23.57.11:18000`；三個 containers 使用 `unless-stopped`。
- Repository 的 dev Compose 對 ClickHouse 設密碼但原 backend URL 未帶認證，第一次 telemetry migration 因此 fail closed。Deployment override 使用 repo 既有 dev credential 修正 URL 後，PostgreSQL Alembic revisions 與 ClickHouse telemetry schema 均成功套用。
- Backend VM 本機與 Edge `172.23.57.1` 均取得 `172.23.57.11:18000/healthz` 的 `{"status":"ok"}`。在 DNAT 啟用前，VPN client 的 `10.1.2.57:8081` 仍為 closed，符合先私網驗收再發布的順序。
- Docker `DOCKER-USER` 只允許 Edge `172.23.57.1` 進入 original destination port `18000`，其餘來源 rate-limited log 後 drop。以 Edge 暫時來源 `172.23.57.99` 驗證被拒絕，正式來源 `.1` 通過；systemd unit 使規則在 Docker 啟動後自動恢復。
- 部署後 `/srv/platform` 使用約 308M／79G，可用約 74G（1% used）；checkout、Docker root、named volumes 與 app data 均位於此 filesystem，遠高於百分之二十 headroom gate。

### 2026-08-12 UAT Docker deployment completed

- 以短生命週期 GitLab askpass 從本機 ignored token source fetch／fast-forward 到 `25201dbf1ba3475ebe9a69356c551e6394937f26`；remote URL 不含 credential，working tree clean。
- 遠端新增的 UAT 定義包含 `docker-compose.uat.yml`、`apps/backend/Dockerfile.prod`、`apps/frontend/Dockerfile.prod` 與 nginx entrypoint。UAT `.env.uat` 為 mode `0600`，資料庫密碼與 `SESSION_SECRET` 以 cryptographic RNG 產生；值未出現在對話、log、ticket 或 Git。
- 建立 Git 之外的 `/srv/platform/app-data/type-ai-platform/compose.uat.deploy.yml`，將 nginx 的 container `443` 綁定至 `172.23.57.11:18000`；UAT 使用 `ENV=dev` 假 SSO，partner 欄位留空，沒有帶入未核准環境憑證。
- UAT frontend、backend、poller、Postgres、ClickHouse、nginx 全部 running；PostgreSQL Alembic 與 ClickHouse telemetry migrations 成功。`/srv/platform` Docker root 與 UAT volumes 均在 `/srv/platform`，使用率約 2%。
- UAT nginx certificate volume `type-ai-platform-uat_nginx-certs` 已建立；其 certificate fingerprint 由 volume 內的 `server.crt` 初始化至 root-owned `/etc/type-ai-platform/uat-nginx-cert.sha256`，backend health timer 已通過 30-day expiry 與 fingerprint check。
- Backend 與 Edge 私網 `https://172.23.57.11:18000/healthz` 回 `{"status":"ok"}`；UAT 入口透過既有 `10.1.2.57:8081` DNAT 提供 frontend、`/healthz`、`/docs`、`/openapi.json` HTTP 200，並以測試 email 完成 dev-login 與 `/internal/v1/me` 200。
