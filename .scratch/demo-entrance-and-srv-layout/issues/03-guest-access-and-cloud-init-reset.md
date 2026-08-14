# 03 — 進入 guest 並重套網路設定

**What to build:** 讓 Demo 內部真的持有 `172.23.57.12`，而不是只有 hypervisor 的設定這樣寫。Cloud-Init 的網路設定只在 first boot 套用，所以 guest 內部目前仍是舊的。

所有 guest 內部操作走 qemu-guest-agent：它經 virtio-serial 以 root 執行，不需要網路也不需要本機密碼。Demo 沒有設定 Cloud-Init 密碼，所以 hypervisor console 不是可靠的救援路徑。**不為此建立任何新憑證** —— guest agent 不可用時 console 是 fallback，任何需要建立憑證的步驟標記 `[HUMAN ACTION]` 暫停。

重置前先備份 guest 內由人工維護的設定：authorized SSH keys、檔案系統掛載表、網路設定目錄。掛載表特別重要，因為大資料卷的掛載是人工加的，不由 Cloud-Init 管理。

同時列出存在於 guest 但不在 hypervisor sshkeys 欄位中的金鑰 —— Cloud-Init 會依該欄位重寫 authorized key 集合，沒先列出就會失去存取。

然後執行 Cloud-Init 狀態重置並重新開機，讓 Cloud-Init 依 hypervisor 的設定重寫網路。代價是全部 Cloud-Init 模組以 first boot 身分重跑；該代價由票 02 關閉自動升級、以及本票的備份所涵蓋。使用者已明確選擇這個做法，而非手改 guest 內的網路設定檔。

驗證從 guest 內部讀取實際位址，不是把 hypervisor 的設定讀回來。

**Blocked by:** 02

**Status:** done —— 已執行完成，成果隨 VM 103 銷毀（見 `.scratch/demo-rebuild-from-template/spec.md`）

- [x] Cloud-Init 重置前，authorized SSH keys、掛載表與網路設定目錄已備份
- [x] 存在於 guest 但不在 hypervisor sshkeys 欄位的金鑰已明確列出
- [x] 從 guest **內部**讀出的位址為 `172.23.57.12/24`，gateway 為 Edge 的私有位址
- [x] 重置後的 authorized keys、掛載表與網路設定，與備份逐項比對並記錄差異
- [x] 大資料卷仍掛在原本的路徑，且其中檔案可讀
- [x] Demo 未被升級任何套件或作業系統版本
- [x] Edge 可以連到 `172.23.57.12`
- [x] UAT 的 `10.1.2.57:8081` 仍回應正常
- [x] 過程中未建立任何新憑證

## Comments

交付：`scripts/demo-entrance-and-srv-layout/03-guest-cloud-init-reset.sh`。

全部 guest 操作走 `qm guest exec`，不建立任何憑證；腳本最後會斷言 `qm config 103` 沒有
`cipassword`，把「未建立新憑證」變成讀回驗證而不是承諾。

備份同時留在 guest 與 PVE host 兩處，重置後逐項比對並把差異寫成檔案。`/etc/fstab` 與掛載表
出現差異時停下來要求確認，因為大資料卷的掛載是人工加的、不由 Cloud-Init 管理。

「未升級任何套件」以 `dpkg-query -W` 清單的 SHA-256 在重置前後比對，不符即停止 —— 這比
「我們關了 ciupgrade」這個承諾強。

`sshkeys` 欄位是 URL 編碼的，解碼抽成 `urldecode` 並有測試；解錯會漏列 guest 專有的金鑰，
而那正是重置後會失去存取的那些。

審查後修正：

- 位址驗證改用「含不含」而非「等不等於」。Demo 跑著 Docker，`docker0` 與 `br-*` 都是
  scope global，用相等比較會在每一次執行都停在這一步。
- 金鑰擷取改成找「看起來像金鑰本體的欄位」，涵蓋 `sk-ssh-ed25519@openssh.com` 與帶
  `command="…"` options 前綴的行；固定取第 2 欄會漏掉它們 —— 而漏掉的正是重置後會失去存取的那些。
- 備份取回改用 `pull_guest_file`：guest 上沒有該檔會明講並記為空檔，agent 出錯則停止。
  原本的 `|| true` 會靜默留下空檔，讓孤兒金鑰比對得出「沒有多餘金鑰」這個危險的錯誤結論。
- stage 7 現在比對全部三個備份目錄（netplan、network、cloud.cfg.d），不只 netplan。
- `abort` 改印到 stderr。它在 `x=$(guest_exec_or_abort …)` 底下被呼叫，印到 stdout 會被變數
  吃掉，操作者只會看到腳本無聲結束。

驗收框的勾選依據（2026-08-13）：guest 內部持有 `172.23.57.12/24` 只可能來自 stage 4 的
Cloud-Init 重置，而票 04 的報告能產出就代表它 stage 1 的 `readback_contains` 通過了。
所以本腳本至少跑到 stage 6，stage 2（備份）與 stage 3（列出孤兒金鑰）連帶成立。
大資料卷那項由報告自身佐證，不靠腳本：`findmnt` 顯示 `/data/model-cache` 掛在 `/dev/sdc1`
xfs、已用 17.9G，`/etc/fstab` 的 `UUID=238cc650…` 那行也在。

推不到的是 stage 7 之後那四項（逐項比對、dpkg SHA-256、Edge ping、UAT 入口與 cipassword
斷言）。使用者確認腳本跑到「票 03 完成」那行，據此補勾，全票通過。

其中 dpkg SHA-256 那項是強驗證：stage 9 的 `readback` 比對重置前後 `dpkg-query -W` 清單的
雜湊，不符即停止。腳本跑完等同雜湊相符，「未升級任何套件」不是承諾而是讀回結果。

事後在 PVE web UI 直接查核（2026-08-13）：

- Cloud-Init 頁的 **Password 欄為 `none`**——「過程中未建立任何新憑證」由 UI 實見，
  不再只靠腳本 stage 11 的斷言。SSH public key 欄為 `ci-template-shared`。
- Cloud-Init 的 IP Config (net0) 是 `ip=172.23.57.12/24,gw=172.23.57.1`；VM 103 的
  Summary 頁 IPs 欄顯示 `172.23.57.12`——後者是 guest agent 回報的 guest **內部**狀態，
  等同從內部確認位址已生效。
- Upgrade packages 欄為 **No**，與「未升級任何套件」相互佐證。
- Hardware 的三顆資料碟 100G／200G／500G，對得上票 04 報告裡的 `sda`／`sdb`／`sdc`，
  大資料卷 `/data/model-cache`（`sdc1`，500G）確實還在。
