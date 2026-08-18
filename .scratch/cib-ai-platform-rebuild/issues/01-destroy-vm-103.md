# 01 — 銷毀 VM 103（不保全、不備份）

**What to build:** 移除 VM 103，連同它的四顆磁碟與快照，把 VMID `103` 空出來。

**這是不可逆的一步，而且前面沒有任何準備票。**
[ADR-0006](../../../docs/adr/0006-replace-103-with-cib-ai-platform-no-backup.md)
明確捨棄了保全與備份：使用者判定舊機器上沒有值得留下的東西。腳本以雙重確認落實
這個決定，不以「先備份吧」擋下來。

執行前把**將永久消失的東西**逐項印出來給人看，不是只印磁碟清單：

- 磁碟 `scsi0` 100G、`scsi11` 200G、`scsi4` 500G、`scsi2` cloudinit、`efidisk0`
- 快照 `pre-demo-entrance-20260813`
- GitLab deploy key `/home/mobagel/.ssh/id_ed25519_mobagel_gitlab`
  —— 沒有備份，之後要 clone repo 必須有人去 GitLab 簽發新的
- `/srv/typeai-demo/` 的五份 secret（`demo-password`、`kc-admin-password`、`kc-token`、
  `seed-client-secret`、`service-token-secret`）與 `nginx.conf`、`試用說明.md`
- Keycloak 的 `typeai-demo-pg` volume（66.65 MB）

先 `qm shutdown`，確認 `stopped` 之後才 `qm destroy --purge`。停機不是為了備份一致性
（沒有備份），而是為了不在執行中的 guest 底下抽磁碟。

驗收不看 `qm destroy` 的結束碼：`qm config 103` 要**查不到**，並記錄儲存池釋出多少
空間。若儲存池上留下未被 config 引用的 `vm-103-disk-*`，印出來但不動它們 ——
clone 會配置新名字，不受影響。

前後各驗一次 UAT 的 `8081`：這台機器與 UAT 共用同一個 Edge 與同一個儲存池。

**Blocked by:** 無

**Status:** done —— 舊 VM 103 已不存在；儲存池釋出空間的記錄沒有留下
