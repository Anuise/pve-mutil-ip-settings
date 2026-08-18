# 02 — 從範本 109 複製 103 `cib-ai-platform`，開機前設定完成

**What to build:** `qm clone 109 103 --full --name cib-ai-platform`，然後在**第一次開機
之前**把網路與資源改成該有的樣子。

順序不能調換。範本預設 `net0 bridge=vmbr0`、`ipconfig0: ip=dhcp`；以那個設定開機，
新機器會拿到對外側的位址並出現在 `10.1.2.x` 上 —— 而 Edge 的對外側就是 `10.1.2.57`，
衝突會打斷 UAT 的 `8081`。所以是**複製 → 改設定 → 讀回確認 → 才開機**，開機屬於票 03。

要改的：

| 項目 | 目標值 |
| --- | --- |
| `name` | `cib-ai-platform` |
| `net0` | `virtio,bridge=vmbr3,firewall=1`（MAC 由 clone 產生，沿用即可） |
| `ipconfig0` | `ip=172.23.57.12/24,gw=172.23.57.1` |
| `nameserver` | 取自 UAT（VM 105）的 `/etc/resolv.conf`，排除 `127.x` |
| `memory` | `65536` |
| `cores` | `8`（範本已是 8，讀回確認） |
| `onboot` | `0`（先不自啟，等票 04 驗收過再由人決定） |
| `agent` | `1`（票 03、04 唯一的通道；範本沒開就補上） |

**nameserver 不猜。** 舊機器上那份 `/etc/resolv.conf` 隨票 01 消失，所以改從 UAT 讀 ——
它掛在同一個私有 bridge、走同一個 Edge 出去，上游 DNS 必然相同。`127.0.0.53` 是
systemd-resolved 的 stub，不能用。UAT 也讀不到就停下來問人。

不設 `cipassword`，不新增任何憑證。`ciuser` 與範本的共用 ci-template key 沿用。

磁碟採範本原樣：讀回確認只有 `efidisk0` + `scsi0` 100G + `scsi11` 200G + cloudinit
四項，舊機器那顆從未使用的 500G 不帶過來。

反向動作：`qm destroy 103` 後重跑本票（此時新機器還沒開過機，也還沒有資料）。

**Blocked by:** 01

**Status:** done —— qm config 103 讀到 name: cib-ai-platform
