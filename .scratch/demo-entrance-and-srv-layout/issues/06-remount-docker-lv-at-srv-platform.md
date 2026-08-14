# 06 — 把 Docker 的 LV 改掛到 `/srv/platform`

**What to build:** 讓 Demo 的 Docker 資料落在 `/srv/platform` 之下，結構與 UAT 一致，且既有的 images 與 containers 不因掛載點變更而消失。

這不是把 Docker 搬離 OS 卷 —— `/var/lib/docker` 本身就是 `vg_data` 上的 80G 專屬 LV。要做的是**把同一顆 LV 的掛載點從 `/var/lib/docker` 改成 `/srv/platform`**，把原有 Docker 內容收進 `/srv/platform/docker`，data-root 指向該處，掛載表更新為開機自動掛載。因為 LV 沒換，內容隨 LV 一起移動，收進子目錄只是同檔案系統的 rename，不跨檔案系統、不需要額外空間。20G 的 `/srv` 保留，`/srv/platform` 掛在其下。理由見 ADR-0002。

Demo 的 Docker 不是空的（3 containers、7 images、1 volume，共 65M），但 0 running。tutorial 的警告針對「有活的 workload 且內容需跨檔案系統複製」，兩者皆不成立，所以照 tutorial 的安全順序做，額外要求是搬移前後逐項比對數量與清單。依票 05 寫回 spec 的順序與逐步 rollback 執行。

`umount` 後先確認 `/var/lib/docker` 是空的；非空代表 LV 掛載前底下就有被遮蔽的內容，記錄後停止，不自行刪除或合併。

**Blocked by:** 05

**Status:** done —— 已執行完成，成果隨 VM 103 銷毀（見 `.scratch/demo-rebuild-from-template/spec.md`）

- [ ] `/srv/platform` 由原本掛在 `/var/lib/docker` 的 80G LV 提供，掛載選項仍為 `defaults`
- [ ] Docker 的 data-root 解析為 `/srv/platform/docker`
- [ ] 停機前記錄的 images、containers 與 volumes 清單與數量，在啟動後逐項相符
- [ ] `umount` 後的 `/var/lib/docker` 已確認為空並保留
- [ ] Docker 服務可正常啟動，且以既有 image 跑一個用後即刪的容器驗證儲存可用（不啟動那三顆原本 `Exited` 的容器）
- [ ] `/srv/platform` 剩餘空間至少二成
- [ ] 掛載在重新開機後自動恢復，`findmnt` 與 data-root 均重新讀回
- [ ] UAT 的 `10.1.2.57:8081` 全程不受影響
