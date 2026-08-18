# 05 — repo 與文件收尾

**What to build:** 讓 repo 描述的世界與實際存在的世界一致。這一票在票 04 執行完成
**之後**做，因為要寫進 repo 的是實際結果，不是計畫。

要處理的：

- `.scratch/single-ip-multi-site-network/nftables.edge.conf`：三條 `8082` 規則從
  「已產生、尚未安裝」改為實際安裝的樣子（解除註解、移除那兩段說明註解）。
  repo 追蹤的 ruleset 不能跟 Edge 上執行的分岔 —— 以票 04 留下的
  `candidate.conf` 逐行對照，不憑印象改。
- `docs/runbooks/single-ip-multi-site.md`：
  - 配置表的 Demo 那一列改為 `CIB` / `103 cib-ai-platform` / `172.23.57.12/24` /
    `8082 -> 172.23.57.12:443`。
  - 明寫 **`8082` 的規則已安裝，但 CIB 上目前沒有任何服務在 `443`，所以
    `Test-NetConnection 10.1.2.57 -Port 8082` 會失敗，這是預期行為**（ADR-0007）。
    要重新確認入口，得再起一次臨時 listener —— 把票 04 的那段指令寫進 runbook。
  - 受保護備份清單移除舊 Demo 的憑證 volume 與 deploy key fingerprint：那些東西
    已隨票 01 永久消失（ADR-0006），清單上留著就是假的。
  - 移除「Demo 是 `/srv` 內開發 `type-ai-platform-demo`」那段：deploy key 沒了，
    repo clone 不在範圍。
- `docs/reports/`：把票 03 產生的形狀報告與票 04 的探測紀錄放進來（`report.md`
  已過 `redact_secrets`，放之前自己看過一遍）。
- ADR-0001 補一句現況：`8082` 已開通，配置對象由 Demo 改為 CIB。
- ADR-0003 確認仍然 `accepted`：臨時 listener 不是應用部署。

runbook 裡指向舊程序的那一句（`scripts/demo-rebuild-from-template/`）已改為指向
`scripts/cib-ai-platform-rebuild/` 並註明尚未執行 —— 這一票要把「尚未執行」那句換成
實際結果。

`CONTEXT.md` 的詞彙、ADR-0005 的 `superseded`、以及
`.scratch/demo-rebuild-from-template/` 票 01–07 的 `wont-do` 標記，已隨本 spec 一併
完成，不在這一票的範圍。

**Blocked by:** 04

**Status:** ready-for-agent
