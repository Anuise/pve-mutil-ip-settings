---
status: accepted
---

# 沿用既有的 GitLab deploy key，不重新簽發

新的 Demo 要在 `/srv` 內 clone
`git@source.mobagel.com:type-ai-platform/type-ai-platform-demo.git`。那是 SSH remote，
需要一把私鑰。舊 VM 103 的 `/home/mobagel/.ssh/` 有
`id_ed25519_mobagel_gitlab`／`.pub` 與 `known_hosts`，就是現在在用的那一把。

決定：**把既有的金鑰對與 `known_hosts` 從舊機器保全下來，原樣還原到新機器**，不重新
簽發、不新增任何憑證。

## Considered Options

- **在新機器上產生新的金鑰對，到 GitLab 註冊。** 乾淨，且能讓舊機器的存取權隨銷毀失效。
  但這是**建立新憑證**，需要有人登入 GitLab 操作，而本專案的既定界線是「不為了推進
  某個步驟而建立新憑證」。而且新舊交接期間若註冊失敗，重建就卡在一個沒有回頭路的
  狀態上 —— 舊機器已經沒了。
- **改用 HTTPS remote 加 token。** 一樣是新憑證，而且 token 比金鑰更難妥善保管。
- **沿用既有金鑰。** 選這個：不新增憑證、不需要任何外部系統的操作、重建過程不依賴
  第三方可用性。

## Consequences

- **金鑰是 secret，處理方式與其他 secret 相同。** 保全的副本放在 PVE host 的
  `/root/demo-preserve-<TS>/`（mode 0700），還原後檔案權限必須是 `0600`（私鑰）／
  `0644`（公鑰），擁有者 `mobagel`。**任何情況下都不進 repo**，也不寫進報告 —— 報告
  只記檔名與 fingerprint。
- **舊機器銷毀後金鑰仍然有效。** 這把金鑰在 GitLab 上的授權不會因為 VM 消失而改變，
  所以保全副本本身就是一份可用的憑證，必須當成憑證保管。要讓它失效必須另外到 GitLab
  撤銷，那是本次範圍之外、需要人操作的事。
- **還原後要用實際動作驗證**，不是看檔案在不在：一次真正成功的 `git clone` 才算數。
- 若保全的金鑰無法還原或已失效，重建會停在 clone 這一步，標記 `[HUMAN ACTION]`
  等人去 GitLab 處理 —— 腳本不會自己產生替代金鑰。
