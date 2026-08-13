# 02 — Demo 轉為 private guest 並安全首次開機

**What to build:** 讓 Demo 可以被開機，而且開機不會打斷 UAT。

目前 Demo 的 Cloud-Init 仍設定 Edge 的對外位址、網卡掛在實體 bridge，一開機就撞掉 UAT 的入口。唯一擋著這件事的是它沒有設定開機自啟 —— 那不是設計上的保護。

交付一份互動 wizard 腳本，由使用者自行在 PVE 上執行。agent 不代為執行 hypervisor 變更。每一步執行後讀回結果，不符就停止整個序列，不繼續。

順序不可調換：

1. 確認 Demo 目前確實沒有任何快照
2. 在**停機狀態**建立快照，作為整項工作唯一的回復點（停機狀態使快照不含記憶體映像）
3. 關閉自動套件升級
4. 網卡移到 private bridge
5. Cloud-Init 位址改為 `172.23.57.12/24`，gateway 指向 Edge 的私有位址
6. 記憶體改為 64 GiB，停用 ballooning（vCPU 已是 8 核，不動）
7. **最後才第一次開機**

網卡先移、之後才開機是本票的關鍵安全性質：private bridge 沒有實體 bridge port，所以即使 guest 內部殘留 Edge 的對外位址，該位址也只出現在私有橋接上，碰不到 Edge 的對外側。不對 guest 內部目前的設定做任何假設。

自動套件升級在此關閉，是為票 03 的 Cloud-Init 重置預先拆彈：hypervisor 預設會開啟它，Demo 目前沒有這項設定，重置後會在一台跑著實際 Docker workload 的機器上觸發未經要求的升級。

`172.23.57.12` 已確認未被使用：private bridge 上目前只有 Edge 與 UAT。

不開啟開機自啟 —— 那是票 09 通過驗收後才做的事。

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [x] 執行前已確認 Demo 無既有快照，且新快照建立於停機狀態、不含記憶體映像
- [x] Demo 的網卡掛在 private bridge 上
- [x] Demo 的 Cloud-Init 位址為 `172.23.57.12/24`，gateway 為 Edge 的私有位址
- [x] Demo 設定為 8 vCPU、64 GiB RAM，ballooning 停用
- [x] 自動套件升級已關閉
- [x] 上述變更全部完成後，Demo 才第一次開機
- [x] 開機後 UAT 的 `10.1.2.57:8081` 仍回應正常
- [x] 開機後 guest agent 可從 hypervisor 取得回應
- [x] Demo 未開啟開機自啟
- [x] 任一步驟讀回結果不符時，腳本停止而非繼續

## Comments

交付：`scripts/demo-entrance-and-srv-layout/02-demo-safe-state.sh`，由使用者在 PVE host 以 root 執行。

腳本的 10 個 stage 對應票上的順序，不可調換。每個 `qm set` 之後都以 `qm config` 讀回比對；
不符即 `abort`，整個序列停止而不繼續（`wizard.test.sh` 對這個行為有測試）。

實作上的兩個判斷：

- 網卡改寫只替換 `bridge=` 欄位，model、MAC 與 `firewall=`／`tag=`／`mtu=` 原樣保留，
  避免重建 net0 字串時漏掉旗標。這段抽成 `net0_bridge_set`，有測試。
- Demo 若不是停機狀態，腳本以 `[HUMAN ACTION]` 停止而不代為關機 —— 快照必須在停機狀態
  建立才不含記憶體映像，而關機是使用者該自己下的決定。

前置檢查另外驗證 `vmbr3` 沒有實體 bridge port、PVE host 在其上沒有 IP，以及此 PVE 版本的
`qm set` 支援 `--ciupgrade`（需 8.2 以上）；缺任一項就停止，因為那是「開機安全」的前提。

審查後修正：`ciupgrade` 支援度改用 `qm_supports_option`。原本的 `qm set --help | grep -q` 在
`pipefail` 下會被 `qm` 自己的非 0 結束碼誤判成「不支援」而無故停止；而傳進去的 `--` 又讓 grep
永遠命中，使這道守衛形同虛設。兩種錯法都有測試。

實機回報：stage 1 在真實 PVE 上被 ciupgrade 守衛擋下。PVE 的 `qm set --help` 把選項印成
單破折號（`-ciupgrade <boolean>`），呼叫時卻是雙破折號，只比對雙破折號會誤判成「不支援」。
改成兩種都認，並在真的找不到時印出 `pveversion` 與說明中所有 upgrade 相關選項，讓下一次
執行能分辨「偵測寫錯」與「PVE 版本真的太舊」。

實機為 PVE 9.2.3，遠超過 8.2，卻仍被擋下。真正原因是 `qm set --help` 只印 USAGE 摘要，
一個選項名都沒有；選項清單要問 `qm help set --verbose`。

驗收框的勾選依據（2026-08-13）：腳本以 `set -euo pipefail` 加每個 stage 的 `abort` 串起來，
所以「跑到第 N 個 stage」等同「第 1 到 N-1 個 stage 的讀回全部相符」。Demo 現在是 running
（票 04 報告的 stage 1 讀回），代表 stage 9 的 `qm start` 執行過，因此 stage 1–8 全數通過。
其中網卡 bridge、`ipconfig0`、`ciupgrade=0` 三項另由票 03 腳本的前置檢查獨立再讀回一次。
guest agent 可回應由票 04 的 `qm agent ping` 直接證實。

唯一推不到的是 stage 10 的 `verify_uat_entrance`——它在 `qm start` **之後**，Demo running
無法回推它跑過。使用者確認腳本跑到「票 02 完成」那行，據此補勾，全票通過。

改法有兩層。`qm_set_options` 從 `qm help set --verbose` 取清單，問不到時輸出空字串；
前置檢查因此能分辨「確定沒有 ciupgrade」與「問不到清單」，後者只示警不停止。決定性的
檢查本來就是 stage 4 實際 `qm set --ciupgrade 0` 之後的讀回 —— 前置檢查只是提早示警，
不該因為問不到而擋住一台其實支援的機器。
