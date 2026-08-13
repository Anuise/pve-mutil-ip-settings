# Demo entrance port 8082 與 `/srv` 重整 — Phase 1 腳本

規格：[`.scratch/demo-entrance-and-srv-layout/spec.md`](../../.scratch/demo-entrance-and-srv-layout/spec.md)

這些是**你自己執行**的互動腳本。agent 不代為執行任何 hypervisor 變更。
每一步執行後都會讀回結果；讀回不符時整個序列停止，不會繼續。

## 交付範圍

| 票 | 腳本 | 狀態 |
| --- | --- | --- |
| 01 | `01-rename-uat-vm.sh` | 可執行（repo 端的詞彙與 port 語意修正已隨本次變更完成） |
| 02 | `02-demo-safe-state.sh` | 可執行 |
| 03 | `03-guest-cloud-init-reset.sh` | 可執行（需票 02 先跑完） |
| 04 | `04-inventory.sh` | 可執行（需票 03 先跑完） |
| 05 | — | 已完成：決策寫回 spec，ADR-0002／ADR-0003 另立 |
| 06–11 | — | 可開始撰寫，依 spec 已定的順序與 rollback |

票 05 是閘門，不是遺漏：spec 明文禁止在票 04 的量測存在前決定 Phase 2 機制。
該閘門已於 2026-08-13 通過，執行順序改為 `06` → `07` → `11` → `08` → `09` → `10`
（票 11 是新增的 `443` 端點與 stack 定義，票 08 的 `Blocked by` 由 07 改為 11）。

## 在 PVE host 上執行

```bash
scp -r scripts/demo-entrance-and-srv-layout root@10.1.2.50:/root/
```

然後在 PVE host 上以 root：

```bash
cd /root/demo-entrance-and-srv-layout && chmod +x 0*.sh && ./01-rename-uat-vm.sh
```

依序 `01` → `02` → `03` → `04`。每支腳本結尾會指出下一步。

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
`[HUMAN ACTION]` 並停下來等你。腳本不會代做，也不會為了繞過而建立任何新憑證。

## 票 04 的報告

`04-inventory.sh` 產出 `demo-inventory-<YYYYMMDD>.md`。確認裡面沒有任何
secret 值後放進 repo：

```bash
scp root@10.1.2.50:/root/demo-entrance-and-srv-layout/demo-inventory-20260813.md docs/reports/
```

`docs/reports/` 目前不存在，複製時一併建立。

## 測試

`wizard.sh` 的讀回驗證、確認閘門與字串處理有測試，不需要 PVE：

```bash
bash scripts/demo-entrance-and-srv-layout/wizard.test.sh
```

hypervisor 與 guest 的實際變更沒有自動化測試 —— spec 記載本 repo 沒有測試套件，
驗收是經兩個 seam 的手動程序：已連上核准 VPN 的黑箱 client，以及 guest 內部的
儲存位置與資料完整性。
