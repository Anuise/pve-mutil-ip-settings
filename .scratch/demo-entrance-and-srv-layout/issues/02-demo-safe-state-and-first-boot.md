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

- [ ] 執行前已確認 Demo 無既有快照，且新快照建立於停機狀態、不含記憶體映像
- [ ] Demo 的網卡掛在 private bridge 上
- [ ] Demo 的 Cloud-Init 位址為 `172.23.57.12/24`，gateway 為 Edge 的私有位址
- [ ] Demo 設定為 8 vCPU、64 GiB RAM，ballooning 停用
- [ ] 自動套件升級已關閉
- [ ] 上述變更全部完成後，Demo 才第一次開機
- [ ] 開機後 UAT 的 `10.1.2.57:8081` 仍回應正常
- [ ] 開機後 guest agent 可從 hypervisor 取得回應
- [ ] Demo 未開啟開機自啟
- [ ] 任一步驟讀回結果不符時，腳本停止而非繼續
