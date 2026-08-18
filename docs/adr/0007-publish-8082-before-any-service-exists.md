---
status: accepted
---

# 先開通 8082，再談誰在 443 上聽

[ADR-0001](0001-8082-becomes-permanent-entrance-port.md) 把 `10.1.2.57:8082` 定為 Demo
的常駐入口，但把它的**開通**綁在「Demo 上有服務在 443」之上：Edge 的三條規則因此
產生了卻從未安裝，`.scratch/single-ip-multi-site-network/nftables.edge.conf` 裡標記為
「已產生、尚未安裝」。

`cib-ai-platform` 從範本 109 複製而來，範本上沒有任何東西在聽 443，而應用本體的部署
依 [ADR-0003](0003-demo-443-endpoint-not-application-deployment.md) 不在範圍內。
使用者要的是「掛在 `10.1.2.57:8082`」這件事本身先成立。

決定：**把三條規則裝上去，不等服務。** 驗收改用一個**用後即拆的臨時 listener**
證明整條路徑通，而不是部署任何常駐服務。

## Considered Options

- **等到 CIB 上有 443 服務再裝規則。** 維持「規則與服務同時到位」的既有慣例。但那讓
  「入口是否可用」永遠取決於一件不在本工作範圍內的事，而 FortiGate 路徑的可達性
  又是時間點限定的（ADR-0001）—— 拖越久，越可能在真正要用的時候才發現不通。
- **裝規則，並以臨時 listener 驗收。** 選這個。臨時 listener 在 guest 內跑
  `python3 -m http.server 443`，驗完就殺掉、連目錄一起刪。它證明的是 DNAT、SNAT 與
  FortiGate policy 三段都通，而這三段正是規則本身能不能生效的全部。
- **裝規則，不驗收。** `nft list ruleset` 讀得到規則不等於路徑通。這個專案已經有過
  「驗收通過但實際落點不對」的教訓（ADR-0004 的重建原因），不再接受以結束碼代替證據。

## Consequences

- 規則裝上之後、CIB 上沒有 listener 的期間，`Test-NetConnection 10.1.2.57 -Port 8082`
  會**失敗**。DNAT 送到一個沒人聽的 port，guest 回 RST，client 端看起來與未開通完全
  一樣。這是預期行為，不是故障 —— runbook 必須這樣寫，否則下一個人會把它當成迴歸。
- 唯一能證明入口已開通的證據在 Edge 上（`nft list ruleset` 的三條規則）與票 04 那一次
  臨時 listener 的紀錄裡。之後任何人要重新確認，就得再起一次臨時 listener。
- `.scratch/single-ip-multi-site-network/nftables.edge.conf` 的三條 `8082` 規則從
  「已產生、尚未安裝」改為實際安裝，repo 追蹤的 ruleset 與 Edge 上執行的那一份
  重新對齊。
