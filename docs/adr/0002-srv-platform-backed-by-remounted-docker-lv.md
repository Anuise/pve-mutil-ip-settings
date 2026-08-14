---
status: superseded by ADR-0004
---

# `/srv/platform` 由原 Docker LV 改掛提供

> 已由 [ADR-0004](0004-rebuild-demo-from-template-109.md) 取代。此決策確實執行了
> （票 06 完成），但事後發現 Demo 的 Docker 使用 containerd image store，image layer
> 位於 `/var/lib/containerd` 而非 data-root 底下 —— 改掛 data-root 沒有把 image 移出
> OS 磁碟。VM 103 現改為從範本重建，本 ADR 保留為歷史。

Demo（VM 103）的 `/var/lib/docker` 本身就是 `vg_data` 上的 80G 專屬 LV（`lv_docker`，curtin 安裝時寫入 `/etc/fstab`），而 `/srv` 只有 20G（`lv_srv`）。要讓 Docker data-root、專案 checkout 與應用持久資料一起落在 `/srv/platform` 之下，本專案決定**把 `lv_docker` 的掛載點從 `/var/lib/docker` 改為 `/srv/platform`**，並把原有 Docker 內容 rename 進 `/srv/platform/docker`，data-root 指向該處。`lv_srv` 保留掛在 `/srv`，`/srv/platform` 掛在其下。這與 UAT 的作法相同（見 tutorial 第 7 節）。

## Considered Options

- **擴大 `lv_srv`，把 `/srv/platform` 放在 20G 那顆上。** `vg_data` 尚有 <50G 未配置，技術上可行，但要多一次 LVM 擴充與檔案系統 resize，而且 Docker 的 65M 內容得跨檔案系統複製；`lv_docker` 那條路是同一顆 LV 改掛載點，內容隨 LV 移動，只需同檔案系統 rename。
- **用 `/data/model-cache`（`/dev/sdc1`，500G xfs，已用 18G）。** 空間最充裕，但該卷是 model cache 專用，混放平台資料破壞其用途，spec 也未要求。
- **`lv_docker` 改掛 `/srv/platform`。** 選這個：零複製、與 UAT 同形、80G 對搬移後約 0.76G 的用量有 98% 餘裕。

## Consequences

- Demo 的 Docker 資料不再位於 `/var/lib/docker`。`umount` 後那個路徑變成 `lv_var` 上的空目錄並保留；任何假設「Docker 在預設路徑」的指令或文件都會查到空目錄而非資料。
- fstab 中 `lv_docker` 那行的掛載選項維持 `defaults`。不可比照 `/var` 套 `nodev,nosuid` —— Docker 需要在 data-root 上建立裝置節點與 setuid 檔案。
- `/srv/platform` 依賴 `/srv` 先掛載。掛載順序由 systemd 依路徑推導，不需要額外的 unit 設定，但重開機後兩層掛載都要讀回驗證。
- `/var/lib/containerd`（50G LV）不動。data-root 在 `/srv/platform/docker`、containerd 狀態在 `/var/lib/containerd` 是 UAT 現況，不視為不一致。
- 改掛本身可逆（還原 fstab 與 `daemon.json`、反向 rename），但一旦 data-root 生效並產生新內容，回退成本隨時間上升。票 02 的停機快照 `pre-demo-entrance-20260813` 建立於票 02／03 之前，回退到它會連 private bridge 遷移與 Cloud-Init 重置一起退掉，因此逐步 rollback 是主路徑，快照只是最後手段。
