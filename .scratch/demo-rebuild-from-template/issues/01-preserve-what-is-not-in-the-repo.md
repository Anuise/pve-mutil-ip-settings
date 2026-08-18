# 01 — 保全舊機器上不在 repo 裡的東西

**What to build:** 在 VM 103 被銷毀之前，把它身上**唯一有價值的部分**取下來 —— 也就是
repo 裡沒有、重建後拿不回來的東西。

三類：

1. **GitLab deploy key** —— `/home/mobagel/.ssh/` 的 `id_ed25519_mobagel_gitlab`、
   `.pub`、`known_hosts`。沒有它，新機器 clone 不了 repo，而重新簽發要人去 GitLab
   操作（[ADR-0005](../../../docs/adr/0005-carry-over-existing-gitlab-deploy-key.md)）。
2. **`/srv/typeai-demo/` 整包** —— `demo-password`、`kc-admin-password`、`kc-token`、
   `seed-client-secret`、`service-token-secret`、`nginx.conf`、`試用說明.md`，以及
   `screenshots/`、`smoke-shots/`。這些是手工放上去的，沒有任何一份在 repo 裡。
3. **Keycloak 的資料庫** —— `typeai-demo-pg` 那顆 66.65 MB 的 volume。容器目前是
   `Exited`，直接把 volume 目錄打包即可，不需要啟動容器。

另外抄一份**參考資料**，新機器要對照：`/etc/resolv.conf`、`/etc/netplan/`、
`/etc/fstab`、`/etc/docker/daemon.json`、`docker images` 與 `docker ps -a` 的清單、
`lsblk`／`lvs`／`df -hT` 的輸出。這些不是 secret，用來確認新機器的形狀對不對。

產物放 PVE host 的 `/root/demo-preserve-<YYYYMMDD-HHMMSS>/`，目錄 mode `0700`。
**沒有任何一個檔案可以進 repo。** 產出的報告只記檔名、大小與 SHA-256；secret 的值一律
寫 `<redacted>`，agent 不讀取內容。

檔案要經 guest agent 通道帶回主機。上一輪的教訓：這條通道是 base64 的 JSON，數 MB 就
會失敗，而失敗訊息只說「讀不到」。因此**先在 guest 內打包成一個 tar 並算 SHA-256，
再分段取回並在主機端重算比對** —— 複製工具的結束碼不算證據。

**Blocked by:** —

**Status:** wont-do —— 使用者改為不保全、不備份直接抽換（ADR-0006）；由 `.scratch/cib-ai-platform-rebuild/` 取代

- [ ] `/root/demo-preserve-<TS>/` 存在，mode `0700`，擁有者 root
- [ ] deploy key 三個檔案都在，主機端重算的 SHA-256 與 guest 內相符
- [ ] `/srv/typeai-demo/` 的封存內含上列七個檔名，逐檔 SHA-256 相符
- [ ] `typeai-demo-pg` 的 volume 已封存，大小與 `docker system df` 報的 66.65 MB 相符
- [ ] 參考資料六項都已取回
- [ ] 產出的報告不含任何 secret 值（人工確認一次）
- [ ] 保全期間未對 VM 103 做任何變更（全程唯讀）
