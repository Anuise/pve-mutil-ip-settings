---
status: accepted
---

# TCP 8082 從臨時驗收 port 改為常駐入口

spec 原本把 `10.1.2.57:8082` 定義為第二服務的*臨時*驗收 port，用來在部署前證明 FortiGate 路徑放行（見 spec 的 initial port allocation 與 empirical gate 條款）。現在 VM 103 `type-ai-platform-demo` 要長期以 `8082` 對外發佈，因此該 port 的語意改為常駐入口，spec 與 runbook 的 port map 一併更新。

## Considered Options

- **改用新 port（例如 8083），保留 8082 作驗收工具。** 語意乾淨，但 `8083` 從未經 FortiGate 驗證。issue 01 記錄 FortiGate 管理者無法聯絡、policy ID 與 client pool 至今未知，唯一可用的 gate 是從已核准 FortiClient session 實測。新 port 若不通就沒有人能調整 policy，部署直接卡死。
- **沿用 8082。** `8081` 與 `8082` 都已於 2026-08-11 由已連線的 FortiClient client 實測 `TcpTestSucceeded=True`。選確定可達的那個。

## Consequences

- 專案不再保留任何「已驗證但未使用」的探測 port。日後新增入口 port 必須重跑 empirical gate，且要接受可能因 FortiGate policy 而失敗、無人可協助調整的風險。
- `8081`／`8082` 的 empirical validation 是時間點限定的。FortiGate 任何變更後兩個 port 都需重測，這項限制不因本決策而改變。

## 現況（2026-08-14）

本決策維持 `accepted`：`8082` 仍配置給 Demo，語意仍是常駐入口。但**尚未開通** ——
自 2026-08-13 起 Demo 上就沒有任何服務在 `443`，而依
[ADR-0004](0004-rebuild-demo-from-template-109.md) 從範本 109 重建後也不會有，
Edge 的三條 `8082` 規則因此保持未安裝狀態
（`.scratch/single-ip-multi-site-network/nftables.edge.conf` 內已標記為
「已產生、尚未安裝」）。要開通時規則已經備妥，配置不必重新分配。

## 現況（2026-08-18）

本決策維持 `accepted`，但配置對象改了：`8082` 配置給 **CIB**（VM 103
`cib-ai-platform`），不再是 Demo —— 那台機器即將被未備份銷毀
（[ADR-0006](0006-replace-103-with-cib-ai-platform-no-backup.md)，程序尚未執行）。

開通的前提也改了：依 [ADR-0007](0007-publish-8082-before-any-service-exists.md)，
三條規則不再等 `443` 上有常駐服務才安裝。安裝與驗收由
`.scratch/cib-ai-platform-rebuild/` 的票 04 執行；**該票執行之前，`8082` 仍未開通**。
