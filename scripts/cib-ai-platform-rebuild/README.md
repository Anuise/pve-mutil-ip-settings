# VM 103 抽換為 cib-ai-platform — 執行腳本

規格：[`.scratch/cib-ai-platform-rebuild/spec.md`](../../.scratch/cib-ai-platform-rebuild/spec.md)
決策：[ADR-0006](../../docs/adr/0006-replace-103-with-cib-ai-platform-no-backup.md)（不備份直接抽換）、
[ADR-0007](../../docs/adr/0007-publish-8082-before-any-service-exists.md)（先開通、以臨時 listener 驗收）

這些是**你自己執行**的互動腳本。agent 不代為執行任何 hypervisor 變更。
每一步執行後都會讀回結果；讀回不符時整個序列停止，不會繼續。

## 交付範圍

| 票 | 腳本 | 做什麼 |
| --- | --- | --- |
| 01 | `01-destroy-vm-103.sh` | **不可逆、無備份**：銷毀舊的 VM 103，把 VMID 空出來 |
| 02 | `02-clone-from-template.sh` | `qm clone 109 103 --full --name cib-ai-platform`，並在開機前設定完成 |
| 03 | `03-first-boot.sh` | 第一次開機，讀出新機器的實際形狀 |
| 04 | `04-publish-entrance-port-8082.sh` | Edge 開通 8082，並用臨時 listener 證明整條路徑 |
| 05 | — | repo 與文件收尾，票 04 執行完之後交給 agent 做，不在 PVE 上執行 |

順序固定：`01` → `02` → `03` → `04`。**01 是分水嶺，而且前面沒有任何準備票。**

## 在 PVE host 上執行

`wizard.sh` 沿用前兩個 spec 的共用函式，所以三個目錄要維持相鄰 ——
複製整個 `scripts/`，不要只複製這一個目錄：

```bash
ssh root@10.1.2.50 'mkdir -p /root/pve-scripts'
scp -r scripts/cib-ai-platform-rebuild scripts/demo-rebuild-from-template scripts/demo-entrance-and-srv-layout root@10.1.2.50:/root/pve-scripts/
```

然後在 PVE host 上以 root：

```bash
cd /root/pve-scripts/cib-ai-platform-rebuild && chmod +x 0*.sh && ./01-destroy-vm-103.sh
```

四支腳本共用同一份紀錄 `/root/cib-ai-platform-rebuild/report.md`，往後附加，
不需要傳任何環境變數。

## 停止條款

spec 明訂，腳本會實作成 `abort`，不自行繞過：

- 新機器第一次開機前 `net0` 不在 `vmbr3`，或 `ipconfig0` 不是靜態 `172.23.57.12/24`
  → **不准開機**
- 開機後 guest 內出現任何 `10.1.2.x` 位址 → 停止，關機修正後重跑票 03
- 儲存池 `VMdisk` 可用空間低於 500 GiB → 停止，不刪任何東西騰空間
- Edge 上已有**未被註解**的 8082 DNAT → 停止，不覆蓋既有配置
- 候選 nftables 設定沒通過 `nft -c -f` → 停止，現行規則不動
- 臨時 listener 沒綁到非 loopback 位址 → 停止（綁 `127.0.0.1` 的 listener
  永遠不會回答 DNAT，卻能讓「有 listener」這個檢查通過）
- `443` 上已經有別人在聽 → 停止，臨時 listener 不搶 port

## 回復點

| 到哪一步 | 怎麼回頭 |
| --- | --- |
| 票 01 之前 | 什麼都沒動，不做即可 |
| **票 01 之後** | **沒有回頭路。** 這一輪沒有 vzdump，快照也隨機器消失（ADR-0006） |
| 票 02 之後 | `qm destroy 103` 後重跑票 02（新機器還沒開過機，也還沒有資料） |
| 票 03 之後 | 關機、修 `net0`／`ipconfig0`、重跑票 03 |
| 票 04 之後 | Edge 上 `nft -c -f /etc/nftables.conf.before-<TS>` 驗過再還原它並 reload。**不驗證就不還原** |

## 票 04 之後 8082 的狀態

規則裝好了，但 CIB 上沒有人在聽 `443`，所以
`Test-NetConnection 10.1.2.57 -Port 8082` 會**失敗** —— DNAT 送到沒人聽的 port，
guest 回 RST，client 端看起來與未開通一模一樣。**這是預期行為，不是故障**（ADR-0007）。

要重新確認入口，再起一次臨時 listener（在 CIB 內以 root）：

```bash
mkdir -p /tmp/cib-entrance-probe && cd /tmp/cib-entrance-probe
printf 'cib-ai-platform entrance probe\n' > entrance.txt
setsid sh -c 'exec timeout 300 python3 -m http.server 443 --bind 0.0.0.0' \
  > server.log 2>&1 < /dev/null &
```

從核准的 VPN client `curl.exe -sS http://10.1.2.57:8082/entrance.txt`，
驗完 `pkill -f 'http.server 443'; rm -rf /tmp/cib-entrance-probe`。

## 產物

| 產物 | 內容 | 可否進 repo |
| --- | --- | --- |
| `/root/cib-ai-platform-rebuild/report.md` | 銷毀、新機器設定、形狀、開通紀錄，每段都過 `redact_secrets` | 可以（`docs/reports/`），放之前先自己看過一遍 |
| `/root/cib-ai-platform-rebuild/edge-nftables-<TS>/` | Edge 的前後設定、執行中規則、探測 log | `candidate.conf` 用來與 repo 的 ruleset 對照 |
| `/etc/nftables.conf.before-<TS>`（Edge 上） | 變更前的設定 | 不進 repo，留在 Edge 上當回復點 |

這一輪**沒有保全目錄** —— 沒有東西要保全（ADR-0006）。

## `[HUMAN ACTION]`

需要你的 VPN session 或不可逆確認的步驟會標記 `[HUMAN ACTION]` 並停下來等你。
票 01 的銷毀除了 y/N 之外還要一字不差地打出 `destroy 103 without backup`。

腳本不會為了繞過任何閘門而建立憑證：沒有 Cloud-Init 密碼、沒有救援帳號。
deploy key 隨舊機器消失，**腳本不會自行產生替代金鑰** —— 要 clone repo，
得有人去 GitLab 簽發新的一把，那是另一件工作。

## 測試

解除註解與 listener 檢查都有測試，不需要 PVE：

```bash
bash scripts/cib-ai-platform-rebuild/wizard.test.sh
```

涵蓋的是「錯了也不會當場爆炸」那一類：三條規則只解開兩條，`nft -c -f` 仍會通過而
症狀是「裝好了卻打不通」；listener 檢查認了 loopback，就會在最貴的一步（人已經連上
VPN 在等）才失敗。

共用函式的測試在
[`../demo-entrance-and-srv-layout/wizard.test.sh`](../demo-entrance-and-srv-layout/wizard.test.sh)
與 [`../demo-rebuild-from-template/wizard.test.sh`](../demo-rebuild-from-template/wizard.test.sh)。

hypervisor 與 guest 的實際變更沒有自動化測試 —— 驗收是經兩個 seam 的手動程序：
已連上核准 VPN 的黑箱 client，以及 guest 內部的位置與 listener 狀態。
