# Demo 從範本 109 重建

> **Superseded by [`../cib-ai-platform-rebuild/spec.md`](../cib-ai-platform-rebuild/spec.md)。**
> 使用者於 2026-08-18 決定不保全、不備份，直接抽換為 `cib-ai-platform`
> （[ADR-0006](../../docs/adr/0006-replace-103-with-cib-ai-platform-no-backup.md)）。
> 票 01–07 因此 `wont-do`；票 08（repo 收尾）已執行完成。
> 腳本不刪：`wizard.sh` 的讀回、閘門與分段傳輸由新 spec 沿用。

VM 103（Demo）改由範本 109（`ub-26-4-srv-docker`）重建，用途從「展示既有部署」轉為
「在 `/srv` 內開發 `type-ai-platform-demo`」。理由與取捨見
[ADR-0004](../../docs/adr/0004-rebuild-demo-from-template-109.md)。

取代 `.scratch/demo-entrance-and-srv-layout/`。該 spec 的票 01–04、06、07 已執行完成，
成果隨 VM 103 一起銷毀；票 05 的決策由 ADR-0004 推翻；票 08–11 不再執行。

## 這是什麼

一次不可逆的機器抽換。舊機器上唯一有價值的是**不在 repo 裡的東西**：GitLab deploy key、
`/srv/typeai-demo/` 底下手工放的 secret 與設定、Keycloak 的資料庫 volume。其餘全部丟棄。

新機器沿用 VMID `103`、名稱 `type-ai-platform-demo`、私有位址 `172.23.57.12/24`、
橋接 `vmbr3`、閘道 `172.23.57.1`（Edge）。repo 內的 nftables ruleset、runbook 配置表與
ADR-0001 因此完全不需要改。

## 既定事實

以下在 2026-08-14 於現場量測，不是假設：

| 項目 | 值 |
| --- | --- |
| 範本 109 | `ub-26-4-srv-docker`，`template: 1`，stopped |
| 範本規格 | 8 cores / 8192 MB / `cpu host` / `machine q35` / `ostype l26` |
| 範本磁碟 | `efidisk0` 1M、`scsi0` 100G、`scsi11` 200G、`scsi2` cloudinit |
| 範本網路 | `net0 virtio,bridge=vmbr0,firewall=1`、`ipconfig0: ip=dhcp` |
| 範本 Cloud-Init | `ciuser: mobagel`、`sshkeys:` 共用的 ci-template key、**未設 cipassword** |
| 舊 103 規格 | 8 cores / 65536 MB，磁碟 100G + 200G + 500G + cloudinit |
| 舊 103 快照 | `pre-demo-entrance-20260813`（2026-08-13 14:23:36，停機狀態） |
| 儲存池 VMdisk | zfspool，總量 10.0 TiB，可用 **3.14 TiB**（68.69% 已用） |
| repo | `git@source.mobagel.com:type-ai-platform/type-ai-platform-demo.git`，branch `main` |
| repo 內容 | `type-ai-platform-{backend,frontend,infra,docs}` + `e2e` `tools` `deliverables` |
| 對外通路 | 私有橋接上 `default via 172.23.57.1`，DNS 解得到 `source.mobagel.com`（211.75.236.153），`ping 8.8.8.8` 通 |
| deploy key | `/home/mobagel/.ssh/id_ed25519_mobagel_gitlab`（+ `.pub`、`known_hosts`） |
| 要保全的 secret | `/srv/typeai-demo/` 底下 `demo-password`、`kc-admin-password`、`kc-token`、`seed-client-secret`、`service-token-secret` |
| 要保全的資料 | `typeai-demo-pg` 的 volume（66.65 MB）、`/srv/typeai-demo/nginx.conf`、`試用說明.md` |

## 決策（已定案，執行時不再問）

- **VMID 沿用 103**，名稱沿用 `type-ai-platform-demo`。因此順序必然是「先銷毀、後複製」，
  中間有一段沒有 Demo 的空窗。
- **完整複製**（`qm clone 109 103 --full`），不用 linked clone。新機器不依賴範本 109 的
  存續。儲存池有 3.14 TiB，空間不是限制。
- **記憶體 65536、核心 8、`cpu host`**，與被取代的 VM 同一個規格範圍。範本預設的 8192
  對這個 stack 太小。
- **磁碟採範本原樣**（100G + 200G），不帶舊機器那顆從未使用的 500G。
- **不設 cipassword**，不新增任何憑證。deploy key 沿用既有的
  （[ADR-0005](../../docs/adr/0005-carry-over-existing-gitlab-deploy-key.md)）。
- **repo clone 到 `/srv/type-ai-platform-demo`**，擁有者 `mobagel`。不再有 `/srv/platform`
  這一層 —— 那是 ADR-0002 的產物，已隨之作廢。
- **8082 入口不在本 spec**。新機器上沒有服務在 443，Edge 的規則維持未安裝。ADR-0001 的
  配置保留給 Demo。
- **應用本體的部署不在本 spec**。本 spec 到「repo 在 `/srv`、可 `git pull`、Docker 可用」
  為止。

## 停止條款

任何一條成立就停下來，不自行繞過：

- `vzdump` 備份不存在、大小為 0、或無法列出內容 → **不准銷毀 103**。
- 保全清單有任何一項沒有取到（deploy key、五個 secret 檔、pg volume）→ **不准銷毀 103**。
- 新機器第一次開機前 `net0` 不是 `bridge=vmbr3` 或 `ipconfig0` 不是靜態
  `172.23.57.12/24` → **不准開機**。
- 還原後 `git clone` 失敗 → 標記 `[HUMAN ACTION]`，不自行產生替代金鑰。
- 儲存池可用空間低於 500 GiB → 停止，不刪任何東西騰空間。

## 執行方式

比照上一個 spec：hypervisor 端的步驟以**互動腳本**交付，由使用者自己執行，agent 不代為
執行任何 hypervisor 變更。每一步執行後讀回結果，讀回不符即停止整個序列。
腳本放 `scripts/demo-rebuild-from-template/`，沿用 `wizard.sh` 的
`stage`／`readback`／`gate`／`abort` 與 guest agent 通道處理。

保全產物放 PVE host 的 `/root/demo-preserve-<YYYYMMDD-HHMMSS>/`（mode 0700）。
**其中沒有任何一個檔案可以進 repo。** 報告只記檔名、大小與 SHA-256，值一律 `<redacted>`。

## 執行順序

```
01 → 02 → 03 → 04 → 05 → 06 → 07 → 08
```

01 與 02 都是「還能回頭」的準備；03 是不可逆的分水嶺。

## 驗收

- [ ] 舊機器上不在 repo 裡的東西，在新機器可用或已妥善保存，且逐項有 SHA-256 佐證
- [ ] 新 VM 103 由範本 109 完整複製而來，第一次開機時就在 `vmbr3` 上、位址 `172.23.57.12`
- [ ] guest 內 `/srv` 為獨立檔案系統，Docker 的 data-root 與 image 儲存落點已讀回記錄
- [ ] `/srv/type-ai-platform-demo` 是 `main` 分支的完整 checkout，`git pull` 可用
- [ ] Docker 可用：能 pull 一個 image 並跑一個用後即刪的容器
- [ ] UAT 的 `10.1.2.57:8081` 全程不受影響
- [ ] 重新開機後上述狀態自動恢復
- [ ] repo 內對舊 spec 的引用已標記 superseded，runbook 與 port map 與現況一致
