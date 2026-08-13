# 07 — 應用資料自 `/home` 搬至 `/srv/platform`

**What to build:** 讓 Demo 的專案 checkout 與應用持久資料落在 `/srv/platform` 下對應位置，擺放方式與 UAT 一致。

**家目錄本身留在原處不動。** UAT 從未搬過家目錄；「結構參考 UAT」指的是應用資料的擺放，不是家目錄的搬遷。搬它會動到 shell 設定、SSH 授權與 user-level services，而且沒有前例可循。

複製、驗證、延後刪除：

- 複製時保留屬性、hard link 與 sparse 特性
- 逐檔比對來源與目標的 SHA-256。複製工具的結束碼不算證據
- **來源保留不刪**。刪除由票 10 在驗收通過後執行

票 04 列出的、引用舊絕對路徑的設定（container bind mounts、service units、環境檔）在此改指新位置。

**Blocked by:** 06

**Status:** ready-for-agent

- [ ] 專案 checkout 與應用持久資料存在於 `/srv/platform` 下對應位置
- [ ] 每一個搬移檔案的來源與目標 SHA-256 相符，且比對結果有記錄
- [ ] `/home/mobagel` 下的來源資料仍然存在
- [ ] 家目錄本身未被搬移，shell 設定、SSH 授權與 user-level services 仍可運作
- [ ] 引用舊路徑的設定已全部改指新位置
- [ ] 應用可自新位置正常啟動
- [ ] `/srv/platform` 剩餘空間仍至少二成
