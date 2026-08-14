# 04 — 盤點與量測

**What to build:** 產出 Phase 2 決策所需的真實數字。在此之前任何關於容量與搬移機制的判斷都是猜測 —— Demo 直到票 03 完成才第一次能被安全地從內部查看。

唯讀，不改動 guest 任何狀態。經 guest agent 收集，結果寫成一份報告放進 repo。

要量的東西：

- `/home/mobagel` 的總大小與目錄結構，區分專案 checkout、應用持久資料、以及與本工作無關的內容
- Docker 現況：containers、images、volumes 的數量與大小、目前的 data-root 位置、以及目前在 `443` 與 `80` 上聽的是什麼
- 各 logical volume 與檔案系統的容量與剩餘空間，含目前掛在 Docker 預設路徑的 80G volume、20G 的 `/srv`、以及大資料卷
- 引用 `/home/mobagel` 底下絕對路徑的設定：container bind mounts、service units、環境檔

報告不得包含任何 secret 值、token 或授權標頭 —— 只記錄鍵名。

**Blocked by:** 03

**Status:** done —— 已執行完成，成果隨 VM 103 銷毀（見 `.scratch/demo-rebuild-from-template/spec.md`）

- [x] 報告存在於 repo，且所有數字可由報告中記錄的指令重新覆算
- [x] `/home/mobagel` 的大小與結構已記錄，並區分出專案 checkout 與應用持久資料
- [x] Docker 的 containers、images、volumes 用量與現行 data-root 已記錄
- [x] Demo 上目前提供 `443` 與 `80` 的服務已辨識
- [x] 所有相關 volume 的容量與剩餘空間已記錄
- [x] 引用舊路徑的設定已列成清單
- [x] guest 狀態未被本票改動
- [x] 報告中不含任何 secret 值

## Comments

交付：`scripts/demo-entrance-and-srv-layout/04-inventory.sh`，唯讀，產出 Markdown 報告。

報告把**指令與輸出寫在一起**，所以每個數字都能重新覆算 —— 這是票上「可由報告中記錄的
指令重新覆算」的直接作法。

secret 防護做在收集端而非事後清洗：引用舊路徑的部分用 `grep -o` 只輸出被引用的路徑本身、
不輸出整行；環境檔只列鍵名與檔案 mode，不讀值。收尾另有一次高熵字串掃描供人工複核
（image ID 與 checksum 會被誤判，屬正常）。

報告產在 PVE host 上，需使用者 `scp` 進 repo 的 `docs/reports/`；該目錄尚不存在，複製時建立。

審查後修正：`cat /etc/fstab` 與 `cat /etc/docker/daemon.json` 的輸出在寫進報告前先過
`redact_secrets`。fstab 可帶 CIFS `password=`／`credentials=`，daemon.json 可帶 registry 認證 ——
原本宣稱「防護做在收集端」，這兩個 probe 卻是逐字照抄。遮蔽有測試。

高熵字串掃描原本的 `grep | head` 在 `pipefail` 下會因 SIGPIPE 回非 0，命中超過 20 筆時反而印出
「（無符合項）」—— 對一個 secret 掃描來說是最糟的失敗方向。已改成先收集再截斷。

實跑完成，報告在 `docs/reports/demo-inventory-20260813.md`（629 行，產生時間 2026-08-13T14:31:19+08:00）。
七節齊全，末尾的 `readback` 確認 Demo 仍是 running，全程唯讀。報告只出現環境檔的**鍵名**，
`/etc/fstab` 與 `daemon.json` 實際上沒有可遮蔽的欄位（無 CIFS 掛載、無 registry 認證）。

報告的量測結果推翻了票 05 與票 06 的兩項前提，已寫入票 05 的 `## Comments`。
