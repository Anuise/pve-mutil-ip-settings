# Demo 從範本 109 重建 — 執行腳本

> **Superseded：本序列不再執行。**
> 改跑 [`../cib-ai-platform-rebuild/`](../cib-ai-platform-rebuild/)：不保全、不備份，
> 新機器改名 `cib-ai-platform`
> （[ADR-0006](../../docs/adr/0006-replace-103-with-cib-ai-platform-no-backup.md)）。
> 這裡的 `wizard.sh` 不刪 —— 新序列 `source` 它。

規格：[`.scratch/demo-rebuild-from-template/spec.md`](../../.scratch/demo-rebuild-from-template/spec.md)
決策：[ADR-0004](../../docs/adr/0004-rebuild-demo-from-template-109.md)、[ADR-0005](../../docs/adr/0005-carry-over-existing-gitlab-deploy-key.md)

這些是**你自己執行**的互動腳本。agent 不代為執行任何 hypervisor 變更。
每一步執行後都會讀回結果；讀回不符時整個序列停止，不會繼續。

## 交付範圍

| 票 | 腳本 | 做什麼 |
| --- | --- | --- |
| 01 | `01-preserve.sh` | 取下不在 repo 裡的東西：deploy key、`/srv/typeai-demo`、Keycloak volume |
| 02 | `02-full-backup.sh` | 停機後 `vzdump` 全機備份，並驗證封存可讀 |
| 03 | `03-destroy-vm-103.sh` | **不可逆**：移除舊的 VM 103，把 VMID 空出來 |
| 04 | `04-clone-from-template.sh` | `qm clone 109 103 --full`，並在開機前設定完成 |
| 05 | `05-first-boot.sh` | 第一次開機，讀出新機器的實際形狀 |
| 06 | `06-restore-key-and-clone.sh` | 還原 deploy key，clone repo 到 `/srv/type-ai-platform-demo` |
| 07 | `07-restore-app-data.sh` | 選擇性還原應用資料，設開機自啟並重開機驗收 |
| 08 | — | repo 與文件收尾，已隨本次變更完成，不需要在 PVE 上執行 |

順序固定：`01` → `02` → `03` → `04` → `05` → `06` → `07`。
01 與 02 都是「還能回頭」的準備；**03 是分水嶺**。

## 在 PVE host 上執行

`wizard.sh` 沿用上一個 spec 的共用函式，所以兩個目錄要維持相鄰 ——
複製整個 `scripts/`，不要只複製這一個目錄：

```bash
ssh root@10.1.2.50 'mkdir -p /root/pve-scripts'
scp -r scripts/cib-ai-platform-rebuild scripts/demo-rebuild-from-template scripts/demo-entrance-and-srv-layout root@10.1.2.50:/root/pve-scripts/
```

然後在 PVE host 上以 root：

```bash
cd /root/pve-scripts/demo-rebuild-from-template && chmod +x 0*.sh && ./01-preserve.sh
```

票 01 會建立 `/root/demo-preserve-<YYYYMMDD-HHMMSS>/` 並在結尾印出完整指令。
之後每一支都要指到同一個目錄：

```bash
PRESERVE_DIR=/root/demo-preserve-20260814-120000 ./02-full-backup.sh
```

不指定時腳本會自己取最新的一個；同一天跑過兩次保全就務必明寫。

## 停止條款

spec 明訂，腳本會實作成 `abort`，不自行繞過：

- `vzdump` 備份不存在、大小為 0、或無法列出內容 → **不准銷毀 103**
- 保全清單有任何一項沒有取到 → **不准銷毀 103**
- 新機器第一次開機前 `net0` 不在 `vmbr3` 或 `ipconfig0` 不是靜態 `172.23.57.12/24`
  → **不准開機**
- 還原後 `git clone` 失敗 → 標記 `[HUMAN ACTION]`，不自行產生替代金鑰
- 儲存池可用空間低於 500 GiB → 停止，不刪任何東西騰空間

## 回復點

| 到哪一步 | 怎麼回頭 |
| --- | --- |
| 票 01 之後 | 什麼都沒動，直接不做即可 |
| 票 02 之後 | `qm start 103`，機器原封不動 |
| **票 03 之後** | **只剩 `vzdump` 封存**。快照 `pre-demo-entrance-20260813` 已隨機器消失 |
| 票 04 之後 | `qm destroy 103` 後重跑票 04（新機器還沒開過機，也還沒有資料） |
| 票 05–07 | 各 stage 的 `note` 印出具名的反向動作 |

保全產物與 `vzdump` 封存**都不刪**，留到使用者明確說可以刪為止。

## 產物

腳本會在 PVE host 留下兩份記錄，**只有一份可以進 repo**：

| 產物 | 內容 | 可否進 repo |
| --- | --- | --- |
| `/root/demo-preserve-<TS>/`（0700） | 金鑰、secret、volume 封存、`preserve-report.md` | **不可以，一個檔案都不行** |
| `/root/demo-rebuild-shape-<TS>.md` | 票 05 讀回的網路／檔案系統／Docker 形狀，每段都過 `redact_secrets` | 可以（`docs/reports/`），放之前先自己看過一遍 |

形狀報告刻意不放進保全目錄 —— 那個目錄的規則是「一個檔案都不能進 repo」，
放進去就得替它開例外，而例外正是 secret 外流的入口。

`preserve-report.md` 只記檔名、大小與 SHA-256，secret 的值一律 `<redacted>`，
腳本不讀取任何 secret 內容。

## `[HUMAN ACTION]`

需要你的 VPN session、憑證判斷或不可逆確認的步驟會標記 `[HUMAN ACTION]` 並停下來等你。
票 03 的銷毀除了 y/N 之外還要一字不差地打出 `destroy 103` —— 那一步之後沒有回頭路。

腳本不會為了繞過任何閘門而建立憑證：沒有 Cloud-Init 密碼、沒有救援帳號、
deploy key 沿用既有的那一把（ADR-0005）。

## 測試

分段傳輸、`pvesm`／`vzdump` 的輸出解析與對外網段偵測都有測試，不需要 PVE：

```bash
bash scripts/demo-rebuild-from-template/wizard.test.sh
```

涵蓋的是「錯了也不會當場爆炸」那一類：段數少算一段只是檔案短一截而每個指令都回 0、
SHA-256 複驗自己壞掉會把內容損毀當成成功、`pvesm status` 欄位取錯會讓 500 GiB
停止條款拿錯數字去比、對外網段的偵測漏掉就等於把新機器放上 `10.1.2.x` 而沒人發現。

共用函式（讀回、閘門、guest agent 通道）的測試在
[`../demo-entrance-and-srv-layout/wizard.test.sh`](../demo-entrance-and-srv-layout/wizard.test.sh)。

hypervisor 與 guest 的實際變更沒有自動化測試 —— 驗收是經兩個 seam 的手動程序：
已連上核准 VPN 的黑箱 client，以及 guest 內部的位置與資料完整性。
