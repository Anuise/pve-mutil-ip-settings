# 06 — Docker 遷至 `/srv/platform`

**What to build:** 讓 Demo 的 Docker 資料落在 `/srv/platform` 之下，結構與 UAT 一致，且既有的 images 與 containers 不因掛載點變更而消失。

依票 05 決定的順序停妥服務，把目前掛在 Docker 預設路徑的 80G logical volume 改掛到 `/srv/platform`，既有 Docker 內容移到該掛載之下，Docker 的 data-root 指向該處，掛載表更新為開機自動掛載。20G 的 `/srv` 保留，`/srv/platform` 掛在其下。

Demo 的 Docker 不是空的 —— 這是與 UAT 當時最關鍵的差異。依票 05 的計畫與 rollback 執行，不重複 UAT 的指令序列。

**Blocked by:** 05

**Status:** ready-for-agent

- [ ] `/srv/platform` 由原本掛在 Docker 預設路徑的 80G volume 提供
- [ ] Docker 的 data-root 解析在 `/srv/platform` 之下
- [ ] remount 前存在的 images、containers 與 volumes 在之後仍然存在，數量與清單相符
- [ ] Docker 服務可正常啟動，容器可正常運行
- [ ] `/srv/platform` 剩餘空間至少二成
- [ ] 掛載在重新開機後自動恢復
- [ ] UAT 的 `10.1.2.57:8081` 全程不受影響
