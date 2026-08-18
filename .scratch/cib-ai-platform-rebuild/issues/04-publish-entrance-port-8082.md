# 04 — Edge 開通 8082，並用臨時 listener 證明整條路徑

**What to build:** 把 Edge 上那三條被註解掉的 `8082` 規則實際裝上去，然後以一個
**用後即拆的臨時 listener** 證明 `10.1.2.57:8082` 真的到得了 `172.23.57.12:443`。

依 [ADR-0007](../../../docs/adr/0007-publish-8082-before-any-service-exists.md)：
不等 CIB 上有常駐服務。規則現在裝，路徑現在驗。

## 安裝

三條規則一起，不拆：forward 放行、prerouting DNAT、postrouting SNAT。它們
**已經在 `/etc/nftables.conf` 裡，只是被註解掉了** —— 所以動作是**解除註解**，
而不是新增第四條。腳本先辨識這件事：

- 有未被註解的 `8082` DNAT → 停止，不覆蓋既有配置。
- 找到恰好三條被註解的規則 → 解除註解。
- 一條都找不到（設定檔換過）→ 退回 `nft_add_entrance_rules` 產生它們。

安裝前先 `nft -c -f` 驗候選設定，並 `cp -a` 備份現行設定。載不進去的設定會同時中斷
**所有**服務，不只是新加的那一個。`policy drop` 的數量在候選與現行之間必須相等。

## 驗收

規則讀得到不等於路徑通。這個專案已經有過「驗收通過但實際落點不對」的教訓，
所以要有一次真的請求走完全程。

臨時 listener：在 guest 內 `python3 -m http.server 443`，綁 `0.0.0.0`，內容是一行
可辨識的字串，以 `timeout` 限時，並確認它**綁在非 loopback 位址上** ——
綁 `127.0.0.1` 的 listener 永遠不會回答 DNAT，卻能讓「有 listener」這個檢查通過。

然後依序證明：

1. 從 Edge 內部 `curl http://172.23.57.12:443/` → 拿到那行字串（私有段通）。
2. `[HUMAN ACTION]` 從已連上核准 FortiClient VPN 的 client 打
   `http://10.1.2.57:8082/` → 拿到同一行字串（DNAT + FortiGate policy 通）。
3. listener 的 log 裡，那一次請求的來源是 `172.23.57.1` → **SNAT 生效的證據**。
   CIB 因此不需要信任 client 提供的任何 proxy header。
4. UAT 的 `8081` 仍回 `{"status":"ok"}`。
5. 未配置的 port（`8099`）與私有位址直連（`172.23.57.12:443`）都必須 fail closed。

驗完就拆：殺掉 listener、刪掉目錄、讀回 `ss -ltn` 確認 `443` 沒有殘留 listener。

## 拆掉之後

`8082` 的規則留著，但沒有人在 `443` 上聽。此時
`Test-NetConnection 10.1.2.57 -Port 8082` 會**失敗** —— DNAT 送到沒人聽的 port，
guest 回 RST，client 端看起來與未開通一模一樣。**這是預期行為，不是故障。**
腳本要把這句話印出來，票 05 要把它寫進 runbook，否則下一個人會把它當成迴歸。

**Blocked by:** 03

**Status:** needs-rerun —— live ruleset 已確認三條規則執行中、policy drop 未被放寬，且從 client 打 8082 收到 103 回的 TCP RST（ConnectionRefused，證明 DNAT／forward／SNAT 都在運作）。但自己的停止條款仍未通過：listener log 裡沒有經 8082 進來的 GET /entrance.txt
