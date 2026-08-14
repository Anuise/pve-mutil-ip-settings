# 08 — repo 與文件收尾

**What to build:** 讓 repo 描述的世界與實際存在的世界一致。重建之後有一批文件在講一台
已經不存在的機器。

要處理的：

- `.scratch/demo-entrance-and-srv-layout/spec.md` 頂端加一段 superseded 註記，指向
  `.scratch/demo-rebuild-from-template/spec.md`；票 08–11 標為 `wont-do` 並寫明原因。
  票 01–04、06、07 保留 `done`，它們確實做完了，只是成果隨機器銷毀。
- `scripts/demo-entrance-and-srv-layout/README.md` 加同樣的註記。腳本本身不刪 ——
  `08-publish-entrance-port-8082.sh` 的 nftables 規則產生器與 `wizard.sh` 日後仍要用。
- `docs/runbooks/single-ip-multi-site.md`：Demo 那一列改成現況。**目前 `8082` 尚未開通、
  Demo 上沒有 443 服務**，配置表要誠實反映這件事，不能繼續寫得像已經在跑。受保護備份
  清單移除舊的 Demo 憑證 volume 與 fingerprint，改成新機器的 `/srv/typeai-demo/`
  與 deploy key。
- `.scratch/single-ip-multi-site-network/nftables.edge.conf`：上一輪已把 8082 的三條
  規則寫進去，但 Edge 上從未安裝。改回未開通狀態，或明確標記為「已產生、尚未安裝」
  —— repo 裡的 ruleset 不能跟 Edge 上實際跑的分岔。
- ADR-0001 維持 `accepted`，並補一句現況：8082 配置給 Demo，尚未開通。

保全產物（`/root/demo-preserve-<TS>/` 與 `vzdump` 封存）在這一票**不刪**。把它們的位置
與保留條件寫進 runbook，等使用者明確說可以刪為止。

**Blocked by:** 07

**Status:** ready-for-agent

- [ ] 舊 spec 與舊 README 都有 superseded 註記，指向新的 spec
- [ ] 舊票 08–11 標為 `wont-do` 並寫明原因
- [ ] runbook 的配置表與現況一致（8082 未開通、Demo 無 443 服務）
- [ ] runbook 的受保護備份清單已更新為新機器的實際內容
- [ ] repo 內的 nftables ruleset 與 Edge 上實際跑的規則一致，或明確標記為未安裝
- [ ] 保全產物與 `vzdump` 的位置、保留條件已寫進 runbook，且都還沒被刪
- [ ] 全 repo 搜尋 `/srv/platform` 與 `lv_docker`，殘留的引用都已修正或標為歷史
