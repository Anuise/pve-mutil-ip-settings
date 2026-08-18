# 06 — 還原 deploy key，把 repo clone 進 `/srv`

**What to build:** 把票 01 保全的 GitLab 金鑰放回新機器，然後
clone `git@source.mobagel.com:type-ai-platform/type-ai-platform-demo.git`
到 `/srv/type-ai-platform-demo`，branch `main`，擁有者 `mobagel`。

這是整個重建的目的（[ADR-0005](../../../docs/adr/0005-carry-over-existing-gitlab-deploy-key.md)）。

金鑰是 secret，處理方式跟其他 secret 一樣：經 guest agent 通道送進 guest，落地後權限
必須是 `0600`（私鑰）／`0644`（公鑰），`~/.ssh` 為 `0700`，擁有者 `mobagel`。
`known_hosts` 一併還原，這樣第一次連線不需要有人回答 host key 的提示。
**金鑰內容不寫進任何報告、不進 repo**；報告只記檔名與 fingerprint。

clone 用 `mobagel` 身分做，不是 root —— 用 root clone 會留下一整棵 root 擁有的檔案，
之後每個 git 指令都要處理 `dubious ownership`（舊機器上就是這樣）。

驗證是實際動作，不是檔案存在：clone 成功、`git -C /srv/type-ai-platform-demo status`
乾淨、`git pull` 能跑完。

repo 是 monorepo，clone 後應該看得到
`type-ai-platform-{backend,frontend,infra,docs}`、`e2e`、`tools`、`deliverables`。

`/srv` 的剩餘空間在 clone 後至少要有兩成。

若金鑰無法使用（GitLab 已撤銷、權限變更），停下來標記 `[HUMAN ACTION]`，
**不自行產生替代金鑰**。

**Blocked by:** 05

**Status:** wont-do —— 使用者改為不保全、不備份直接抽換（ADR-0006）；由 `.scratch/cib-ai-platform-rebuild/` 取代

- [ ] `~mobagel/.ssh/` 為 `0700`，私鑰 `0600`、公鑰 `0644`，擁有者皆為 `mobagel`
- [ ] 金鑰 fingerprint 與票 01 記錄的相符
- [ ] `/srv/type-ai-platform-demo` 是 `main` 分支的完整 checkout，擁有者 `mobagel`
- [ ] `git status` 乾淨，`git pull` 可正常執行
- [ ] 上列七個子目錄／檔案都在
- [ ] `/srv` 剩餘空間至少兩成
- [ ] 報告不含金鑰內容（人工確認一次）
