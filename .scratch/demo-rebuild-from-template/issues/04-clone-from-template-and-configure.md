# 04 — 從範本 109 複製新的 103，並在開機前設定完成

**What to build:** `qm clone 109 103 --full --name type-ai-platform-demo`，然後在**第一次
開機之前**把網路與資源設定改成 Demo 該有的樣子。

順序不能調換。範本預設 `net0 bridge=vmbr0`、`ipconfig0: ip=dhcp`；以那個設定開機，新機器
會拿到對外側的位址並出現在 `10.1.2.x` 上 —— 那正是上一個 spec 票 02 整套安全性要避免的
事（Edge 的對外側是 `10.1.2.57`，衝突會打斷 UAT 的 `8081`）。所以是**複製 → 改設定 →
讀回確認 → 才開機**，開機本身屬於票 05。

要改的：

| 項目 | 目標值 |
| --- | --- |
| `net0` | `virtio,bridge=vmbr3,firewall=1`（MAC 由 clone 產生，沿用即可） |
| `ipconfig0` | `ip=172.23.57.12/24,gw=172.23.57.1` |
| `nameserver` | 比照票 01 抄回的 `/etc/resolv.conf` |
| `memory` | `65536` |
| `cores` | `8`（範本已是 8，讀回確認） |
| `onboot` | `0`（先不自啟，等票 07 驗收過再開） |

不設 `cipassword`。範本帶的 `ciuser: mobagel` 與共用 ci-template SSH key 沿用，不新增
任何憑證。

磁碟採範本原樣（`scsi0` 100G + `scsi11` 200G），不補那顆從未使用的 500G。

複製前先確認儲存池可用空間仍高於 500 GiB。

**Blocked by:** 03

**Status:** ready-for-agent

- [ ] `qm clone 109 103 --full` 完成，且新 VM 不依賴範本 109（非 linked clone）
- [ ] 範本 109 本身未被改動，仍是 `template: 1`
- [ ] `qm config 103` 讀回：`net0` 在 `vmbr3`、`ipconfig0` 為靜態 `172.23.57.12/24`、
      `gw=172.23.57.1`
- [ ] `memory=65536`、`cores=8`、`onboot=0` 均已讀回
- [ ] `cipassword` 未設定
- [ ] 磁碟為 `scsi0` 100G + `scsi11` 200G + cloudinit + efidisk，沒有多餘的磁碟
- [ ] **此時 VM 仍為 `stopped`** —— 開機是票 05 的事
- [ ] UAT 的 `10.1.2.57:8081` 不受影響
