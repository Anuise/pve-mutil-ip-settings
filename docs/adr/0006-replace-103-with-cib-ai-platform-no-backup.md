---
status: accepted
---

# VM 103 不備份直接抽換為 `cib-ai-platform`

[ADR-0004](0004-rebuild-demo-from-template-109.md) 決定從範本 109 重建 VM 103，
而重建的程序（`.scratch/demo-rebuild-from-template/`）把「保全舊機器上不在 repo 裡的
東西」與「全機 `vzdump` 備份」放在銷毀之前，共兩張票。那兩張票從未執行。

使用者於 2026-08-18 決定：**不保全、不備份，直接銷毀 VM 103**，從範本 109 複製一台
新的 103，名稱改為 `cib-ai-platform`，並把 `10.1.2.57:8082` 開通到它。

## Considered Options

- **照 `.scratch/demo-rebuild-from-template/` 的票 01→02→03 走。** 先取下 GitLab deploy
  key、`/srv/typeai-demo/` 的五份 secret 與 Keycloak 的 volume，再 `vzdump` 全機備份，
  才銷毀。保住了回頭路，也保住了 clone repo 的能力。代價是兩張票的執行時間，以及
  之後還要跑還原票 06、07。
- **不保全、不備份，直接銷毀。** 選這個。使用者判定舊機器上沒有值得留下的東西 ——
  Demo 的展示應用自 2026-08-13 起就沒有在跑，`/srv/typeai-demo/` 是上一輪手工搭起來
  的展示殼，Keycloak 的資料庫只服務那個殼。新機器的用途是 CIB，不是把 Demo 接回來。

## Consequences

- **GitLab deploy key 一併消失。** [ADR-0005](0005-carry-over-existing-gitlab-deploy-key.md)
  的前提（沿用既有那一把金鑰，不必請人去 GitLab 簽發）不再成立，該 ADR 隨本決策
  `superseded`。因此 **repo clone 不在新 spec 範圍**：`cib-ai-platform` 上不會有
  `/srv/type-ai-platform-demo`，要 clone 得先有人在 GitLab 簽發新的 deploy key，
  那是另一件工作。
- **沒有回頭路。** 快照 `pre-demo-entrance-20260813` 隨 `qm destroy` 消失，而這次沒有
  `vzdump` 頂上。銷毀之後，舊 103 的任何內容都無法取回。這是使用者在知道上述清單
  之後的決定，腳本以雙重確認落實它，不以「先備份吧」擋下來。
- **`Demo` 這個詞退場。** VM 103 不再是 Demo，`CONTEXT.md` 改記 **CIB**。同一個 VMID、
  同一個私有位址 `172.23.57.12`、同一個 entrance port `8082`，但不是舊機器的延續。
- `.scratch/demo-rebuild-from-template/` 的票 01–07 因此 `wont-do`，由
  `.scratch/cib-ai-platform-rebuild/` 取代。票 08（repo 收尾）已執行完成，保留 `done`。
