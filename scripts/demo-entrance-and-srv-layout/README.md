# Demo entrance port 8082 與 `/srv` 重整 — 執行腳本

規格：[`.scratch/demo-entrance-and-srv-layout/spec.md`](../../.scratch/demo-entrance-and-srv-layout/spec.md)

這些是**你自己執行**的互動腳本。agent 不代為執行任何 hypervisor 變更。
每一步執行後都會讀回結果；讀回不符時整個序列停止，不會繼續。

## 交付範圍

| 票 | 腳本 | 做什麼 |
| --- | --- | --- |
| 01 | `01-rename-uat-vm.sh` | VM 105 改名（repo 端的詞彙與 port 語意修正已隨變更完成） |
| 02 | `02-demo-safe-state.sh` | Demo 轉為 private guest 並安全首次開機 |
| 03 | `03-guest-cloud-init-reset.sh` | 進 guest 重套網路設定 |
| 04 | `04-inventory.sh` | 唯讀盤點與量測，產出報告 |
| 05 | — | 決策閘門，已完成：寫回 spec，ADR-0002／ADR-0003 另立 |
| 06 | `06-remount-docker-lv.sh` | Docker 的 LV 改掛到 `/srv/platform` |
| 07 | `07-migrate-app-data.sh` | checkout 自 `/home` 搬到 `/srv/platform`，來源保留 |
| 11 | `11-demo-443-endpoint.sh` | `443` 端點與 stack 定義（[`demo-stack/`](demo-stack/)） |
| 08 | `08-publish-entrance-port-8082.sh` | Edge 開通 entrance port `8082` |
| 09 | `09-reboot-acceptance.sh` | 重開機驗收，通過後才開開機自啟 |
| 10 | `10-delete-retained-source.sh` | 刪除保留的來源資料（最後一個不可逆動作） |

票 05 是閘門，不是遺漏：spec 明文禁止在票 04 的量測存在前決定 Phase 2 機制。
該閘門已於 2026-08-13 通過，執行順序因此是
`01` → `02` → `03` → `04` → `06` → `07` → `11` → `08` → `09` → `10`
（票 11 是新增的 `443` 端點與 stack 定義，票 08 的 `Blocked by` 由 07 改為 11）。

## 在 PVE host 上執行

```bash
scp -r scripts/demo-entrance-and-srv-layout root@10.1.2.50:/root/
```

然後在 PVE host 上以 root：

```bash
cd /root/demo-entrance-and-srv-layout && chmod +x 0*.sh 1*.sh demo-stack/*.sh && ./01-rename-uat-vm.sh
```

依上面的順序執行，每支腳本結尾會指出下一步。票 11 需要 `demo-stack/` 一起帶過去，
所以 `scp` 要用 `-r`。

## 回復點

票 02 的 stage 3 在**停機狀態**建立快照 `pre-demo-entrance-<YYYYMMDD>`，
那是整項工作唯一的回復點（Demo 目前沒有任何快照）。回復：

```bash
qm rollback 103 pre-demo-entrance-20260813
```

在票 09 驗收通過前不要刪除它，也不要刪除票 07 保留在 `/home/mobagel` 下的來源資料。

## 為什麼順序不能調換

票 02 的網卡先移到 private bridge、之後才第一次開機，是整套安全性的來源：
private bridge 沒有實體 bridge port，所以即使 guest 內部殘留 `10.1.2.57`，
該位址也只出現在私有橋接上，碰不到 Edge 的對外側，不會打斷 UAT 的 `8081`。

Demo 直到票 03 完成才第一次能被安全地從內部查看，所以票 04 的量測必須排在
票 03 之後 —— 這也是 Phase 1／Phase 2 分界的由來。

## `[HUMAN ACTION]`

需要你的 VPN session、憑證、基礎設施核准或不可逆確認的步驟會標記
`[HUMAN ACTION]` 並停下來等你。腳本不會代做，也不會為了繞過某個閘門而建立
任何新憑證 —— 沒有 Cloud-Init 密碼、沒有救援用帳號、沒有憑證機構、沒有 ACME
金鑰。票 11 產生的自簽 TLS 憑證是服務本身要用的（比照 UAT），不屬於這一類，
而且它自己也有一個閘門。

## 要放回 repo 的產物

腳本會在 PVE host 的工作目錄留下紀錄。其中兩份要進 repo：

| 產物 | 來自 | 放到 |
| --- | --- | --- |
| `demo-inventory-<YYYYMMDD>.md` | 票 04 | `docs/reports/` |
| `compose.keycloak.yml` | 票 11 | `demo-stack/` |

盤點報告先確認沒有任何 secret 值再放：

```bash
scp root@10.1.2.50:/root/demo-entrance-and-srv-layout/demo-inventory-20260813.md docs/reports/
```

`compose.keycloak.yml` 由 `docker inspect` 產生，環境變數留在 guest 的
`deploy/keycloak.env`（mode 0600），不進 repo。含環境變數的原始 `docker inspect`
也留在 guest。

票 08 的 nftables ruleset、runbook 配置表與 port map 已隨本次變更更新，執行時
只需比對執行狀態與 repo 是否一致（腳本會印出比對指令）。

## Phase 2 的 rollback

票 06 之後每一步都有具名的反向動作，印在該 stage 的 `note` 裡，整段不靠快照也
可逆。逐步 rollback 是主路徑，快照是最後手段。

不可逆的只有票 10 的刪除；在它之前，票 07 保留在 `/home/mobagel` 的來源一直是
可用的對照組。

## 測試

`wizard.sh` 的讀回驗證、確認閘門、設定檔改寫與 `demo-stack/` 的 compose 產生
都有測試，不需要 PVE：

```bash
bash scripts/demo-entrance-and-srv-layout/wizard.test.sh
```

涵蓋的是「寫錯了也不會當場爆炸」那一類：壞掉的 fstab 要等下次開機才發作、
壞掉的 `daemon.json` 會讓 Docker 悄悄用回舊 data-root、nftables 規則插錯 chain
是設定載得進去但行為不對、Keycloak 的 bind mount 改錯是容器起得來但 realm
匯不到。

hypervisor 與 guest 的實際變更沒有自動化測試 —— spec 記載本 repo 沒有測試套件，
驗收是經兩個 seam 的手動程序：已連上核准 VPN 的黑箱 client，以及 guest 內部的
儲存位置與資料完整性。
