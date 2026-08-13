# 03 — 進入 guest 並重套網路設定

**What to build:** 讓 Demo 內部真的持有 `172.23.57.12`，而不是只有 hypervisor 的設定這樣寫。Cloud-Init 的網路設定只在 first boot 套用，所以 guest 內部目前仍是舊的。

所有 guest 內部操作走 qemu-guest-agent：它經 virtio-serial 以 root 執行，不需要網路也不需要本機密碼。Demo 沒有設定 Cloud-Init 密碼，所以 hypervisor console 不是可靠的救援路徑。**不為此建立任何新憑證** —— guest agent 不可用時 console 是 fallback，任何需要建立憑證的步驟標記 `[HUMAN ACTION]` 暫停。

重置前先備份 guest 內由人工維護的設定：authorized SSH keys、檔案系統掛載表、網路設定目錄。掛載表特別重要，因為大資料卷的掛載是人工加的，不由 Cloud-Init 管理。

同時列出存在於 guest 但不在 hypervisor sshkeys 欄位中的金鑰 —— Cloud-Init 會依該欄位重寫 authorized key 集合，沒先列出就會失去存取。

然後執行 Cloud-Init 狀態重置並重新開機，讓 Cloud-Init 依 hypervisor 的設定重寫網路。代價是全部 Cloud-Init 模組以 first boot 身分重跑；該代價由票 02 關閉自動升級、以及本票的備份所涵蓋。使用者已明確選擇這個做法，而非手改 guest 內的網路設定檔。

驗證從 guest 內部讀取實際位址，不是把 hypervisor 的設定讀回來。

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] Cloud-Init 重置前，authorized SSH keys、掛載表與網路設定目錄已備份
- [ ] 存在於 guest 但不在 hypervisor sshkeys 欄位的金鑰已明確列出
- [ ] 從 guest **內部**讀出的位址為 `172.23.57.12/24`，gateway 為 Edge 的私有位址
- [ ] 重置後的 authorized keys、掛載表與網路設定，與備份逐項比對並記錄差異
- [ ] 大資料卷仍掛在原本的路徑，且其中檔案可讀
- [ ] Demo 未被升級任何套件或作業系統版本
- [ ] Edge 可以連到 `172.23.57.12`
- [ ] UAT 的 `10.1.2.57:8081` 仍回應正常
- [ ] 過程中未建立任何新憑證
