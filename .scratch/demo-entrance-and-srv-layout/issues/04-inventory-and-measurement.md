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

**Status:** ready-for-agent

- [ ] 報告存在於 repo，且所有數字可由報告中記錄的指令重新覆算
- [ ] `/home/mobagel` 的大小與結構已記錄，並區分出專案 checkout 與應用持久資料
- [ ] Docker 的 containers、images、volumes 用量與現行 data-root 已記錄
- [ ] Demo 上目前提供 `443` 與 `80` 的服務已辨識
- [ ] 所有相關 volume 的容量與剩餘空間已記錄
- [ ] 引用舊路徑的設定已列成清單
- [ ] guest 狀態未被本票改動
- [ ] 報告中不含任何 secret 值
