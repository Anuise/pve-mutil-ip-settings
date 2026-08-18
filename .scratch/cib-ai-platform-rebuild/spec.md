# VM 103 抽換為 cib-ai-platform，並開通 8082

三件事，沒有第四件：

1. 把 VM 103 整個移除，**不保全、不備份**。
2. 從範本 109（`ub-26-4-srv-docker`）完整複製一台新的 103，名稱 `cib-ai-platform`。
3. 把 `10.1.2.57:8082` 開通到它。

理由與取捨見 [ADR-0006](../../docs/adr/0006-replace-103-with-cib-ai-platform-no-backup.md)
（不備份直接抽換、`Demo` 一詞退場）與
[ADR-0007](../../docs/adr/0007-publish-8082-before-any-service-exists.md)
（先開通、以臨時 listener 驗收）。

取代 `.scratch/demo-rebuild-from-template/`。該 spec 的票 01–07 不再執行（`wont-do`），
票 08 已完成。腳本不刪 —— `03-destroy-vm-103.sh` 之外的讀回與 clone 邏輯本 spec 沿用。

## 這是什麼

一次沒有回頭路的機器抽換。舊 103 的內容全部丟棄：GitLab deploy key、
`/srv/typeai-demo/` 的五份 secret 與 `nginx.conf`、Keycloak 的 66.65 MB volume、
快照 `pre-demo-entrance-20260813`，以及那顆從未使用的 500G 磁碟。

新機器沿用 VMID `103`、私有位址 `172.23.57.12/24`、橋接 `vmbr3`、閘道 `172.23.57.1`
（Edge）。**名稱改為 `cib-ai-platform`** —— 這是與上一個 spec 唯一的形狀差異，
也是 `CONTEXT.md` 要改詞的原因。

## 既定事實

以下在 2026-08-14 於現場量測（見 `docs/reports/demo-inventory-20260813.md` 與
`.scratch/demo-rebuild-from-template/spec.md`），不是假設：

| 項目 | 值 |
| --- | --- |
| 範本 109 | `ub-26-4-srv-docker`，`template: 1`，stopped |
| 範本規格 | 8 cores / 8192 MB / `cpu host` / `machine q35` / `ostype l26` |
| 範本磁碟 | `efidisk0` 1M、`scsi0` 100G、`scsi11` 200G、`scsi2` cloudinit |
| 範本網路 | `net0 virtio,bridge=vmbr0,firewall=1`、`ipconfig0: ip=dhcp` |
| 範本 Cloud-Init | `ciuser: mobagel`、`sshkeys:` 共用的 ci-template key、**未設 cipassword** |
| 舊 103 | 8 cores / 65536 MB，磁碟 100G + 200G + 500G + cloudinit，快照 `pre-demo-entrance-20260813` |
| 儲存池 VMdisk | zfspool，總量 10.0 TiB，可用約 3.14 TiB |
| Edge | VM 104，`10.1.2.57`（對外）／`172.23.57.1`（私有），nftables 於 `/etc/nftables.conf` |
| Edge 現行入口 | `8081 -> 172.23.57.11:443`（UAT），`8082` 的三條規則**已在設定檔中但被註解掉** |
| VPN 來源 | `192.168.255.253/32`（Edge 規則裡的 `vpn_nat_peer`） |

## 決策（已定案，執行時不再問）

- **不保全、不備份。** 銷毀是第一張票，前面沒有任何準備票。腳本以雙重確認落實，
  不以「先備份吧」擋下來（ADR-0006）。
- **VMID 沿用 103**，因此順序必然是「先銷毀、後複製」。
- **名稱 `cib-ai-platform`。** `Demo` 一詞退場，`CONTEXT.md` 改記 **CIB**。
- **完整複製**（`qm clone 109 103 --full`），不用 linked clone。
- **記憶體 65536、核心 8**，與被取代的 VM 同規格。範本預設的 8192 太小。
- **磁碟採範本原樣**（100G + 200G），不帶舊機器那顆從未使用的 500G。
- **不設 cipassword**，不新增任何憑證。存取一律走 QEMU guest agent。
- **nameserver 取自 UAT（VM 105）的 `/etc/resolv.conf`**，排除 `127.x` 的 stub。
  讀不到就停下來問人，不猜。
- **repo clone 不在範圍。** deploy key 隨舊機器消失（ADR-0006），要 clone 得先有人在
  GitLab 簽發新的金鑰。腳本不自行產生替代金鑰。
- **8082 的三條規則以「解除註解」的方式安裝**，不新增第四條、不建立 port range、
  不放寬 `policy drop`。DNAT 目的地維持 `172.23.57.12:443`。
- **臨時 listener 用後即拆。** `python3 -m http.server 443` 驗完就殺掉並刪目錄。
  不部署任何常駐服務（ADR-0003 仍然有效）。

## 停止條款

任何一條成立就停下來，不自行繞過：

- 新機器第一次開機前 `net0` 不是 `bridge=vmbr3`，或 `ipconfig0` 不是靜態
  `172.23.57.12/24` → **不准開機**。以範本預設開機會讓新機器出現在 `10.1.2.x` 上，
  撞掉 UAT 的 `8081`。
- 開機後 guest 內出現任何 `10.1.2.x` 位址 → 立刻停止，關機修正 `net0` 後重跑。
- 儲存池 `VMdisk` 可用空間低於 500 GiB → 停止，不刪任何東西騰空間。
- Edge 上已存在**未被註解**的 `8082` DNAT 規則 → 停止，不覆蓋既有配置。
- 候選 nftables 設定沒通過 `nft -c -f` → 停止，現行規則不動。一份載不進去的設定會
  同時中斷所有服務，不只是新加的那一個。
- 安裝規則後 UAT 的 `8081` 不再回應 → 立刻以備份還原，`8082` 不算開通。
- 臨時 listener 沒有綁到非 loopback 位址 → 停止。綁在 `127.0.0.1` 的 listener
  永遠不會回答 DNAT，卻能讓「有 listener」這個檢查通過。

## 執行方式

hypervisor 端的步驟以**互動腳本**交付，由使用者自己在 PVE host 上執行，agent 不代為
執行任何 hypervisor 變更。每一步執行後讀回結果，讀回不符即停止整個序列。
腳本放 `scripts/cib-ai-platform-rebuild/`，沿用
`scripts/demo-entrance-and-srv-layout/wizard.sh` 的
`stage`／`readback`／`gate`／`abort`／guest agent 通道與 `nft_add_entrance_rules`。

執行紀錄寫在 PVE host 的 `/root/cib-ai-platform-rebuild/report.md`，每一支腳本往後
附加。該檔已過 `redact_secrets`，看過一遍即可放進 `docs/reports/`。

## 執行順序

```
01 → 02 → 03 → 04 → 05
```

**01 是不可逆的，而且前面沒有任何準備票。** 02–04 各自的反向動作寫在腳本的 `note` 裡。

## 驗收

打勾＝2026-08-18 從 client／PVE／Edge／guest 實測核對過；沒打勾的後面附了「目前查到什麼」。

- [ ] 舊 VM 103 已不存在：`qm config 103` 查不到，儲存池釋出的空間有記錄
  - 舊的確實已不存在（現在的 103 是 `cib-ai-platform`）。但**找不到儲存池釋出空間的記錄** —— `/root/cib-ai-platform-rebuild/report.md` 裡只有票 03 的段落。
- [x] 新 VM 103 名稱為 `cib-ai-platform`，由範本 109 完整複製而來
  - `qm config 103` → `name: cib-ai-platform`。「**完整**複製」沒有直接核對 `scsi0` 是不是 linked clone。
- [x] 第一次開機時就在 `vmbr3` 上、位址 `172.23.57.12`，且**沒有任何 `10.1.2.x` 位址**
  - `net0: bridge=vmbr3`；guest 內 `eth0 172.23.57.12/24`，其餘只有 `docker0 172.17.0.1`。
- [x] guest 內 `/srv` 為獨立檔案系統，Docker 的 data-root 與 storage driver 已讀回記錄
  - Docker Root Dir `/var/lib/docker`（獨立 LV `vg_data-lv_docker` ext4 79G）、driver `overlayfs`、29.7.2。
  - 附帶發現：Docker 29 的 `overlayfs` **不建同名子目錄**，實際是 `image`／`rootfs`／`containers`／`volumes`。
- [x] Docker 可用：能 pull 一個 image、跑一個用後即刪的容器、再刪掉 image
  - 實測：0/0 起點 → `docker pull hello-world` → `docker run --rm` 印出 `Hello from Docker!` → `docker image rm` → 回到 0 容器 0 image。
- [x] Edge 上三條 `8082` 規則實際執行中，且 `policy drop` 未被放寬
  - 讀的是 Edge 的 **live ruleset**（`nft list ruleset`，變數已展開成 `eth0`／`192.168.255.253`），三條都在：
    forward 的 `ct status dnat accept`、prerouting 的 `tcp dport 8082 dnat to 172.23.57.12:443`、postrouting 的 `snat to 172.23.57.1`。
  - `input` 與 `forward` 都仍是 `policy drop`。
- [ ] 臨時 listener 在跑的期間，從核准 VPN client 打 `10.1.2.57:8082` 拿得到它的回應
  - **沒有拿到過回應，但整條路已證明是通的。** 103 開著、443 沒人聽的狀態下從 client 打 8082：
    `ConnectionRefused`（10061，~2.06 秒，可重現）—— 那是 103 發的 TCP RST 穿過 SNAT／DNAT 回到 client。
    對照組：沒有規則的 9099 是 `TimedOut`（被 `policy drop` 靜靜丟掉），8081 是 6ms 連上。
  - 也就是 DNAT、forward accept、SNAT 反向轉譯都在運作，**缺的只有 443 上的服務**。
  - 票 04 原本的證據沒有成立：`probe-access.txt` 只有一行 `GET /`，那是 Edge 內部直連（不經 8082 的 DNAT），
    而票 04 數的是 `GET /entrance.txt` —— log 裡是 0，所以它停在自己這條停止條款上。
- [ ] 該次請求在 listener 的 log 裡以 `172.23.57.1` 為來源（SNAT 生效的證據）
  - 還沒有這樣的一行。SNAT 本身已由上一項的 RST 回程間接證明。
- [x] 臨時 listener 已停止、目錄已刪除，guest 上沒有殘留的 443 listener
  - 103 上 `ss -ltn` 只有 `:22` 與 loopback 的 `:53`／`:25`，80／443 都沒有 listener。
- [x] UAT 的 `10.1.2.57:8081` 全程不受影響
  - 全程測三次：`TcpTestSucceeded=True`、`healthz` 回 `{"status":"ok"}`、TCP 連線 6ms。
- [ ] repo 的 ruleset、runbook、`CONTEXT.md` 與現況一致
  - 票 05 未開始；repo 還有未提交的改動。
