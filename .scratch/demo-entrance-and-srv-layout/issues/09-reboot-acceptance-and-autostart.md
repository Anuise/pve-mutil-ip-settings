# 09 — 重開機驗收與開機自啟

**What to build:** 證明整套設定能在重新開機後自行恢復，不需要人工介入。通過之後才開啟 Demo 的開機自啟 —— 提早開啟等於讓 hypervisor 重開機把一個未驗證的設定帶回來。

在核准的時段重開 Demo 與 Edge，然後把兩個 seam 的驗收整套重跑。

第一個 seam：一個已連上核准 VPN 的使用者，只斷言可觀察的 `IP:port` 行為，不檢查防火牆內部。第二個 seam：guest 內部的儲存位置與資料完整性。

每次探測記錄來源位址、目的與結果，且由當初建立經驗性 gate 的同一個 VPN client 執行。

`8081` 與 `8082` 的經驗性驗證是時間點限定的：只證明當下可達，不揭露 FortiGate 的 policy 範圍、client pool 或 user group，也不保證未來網路變更後仍可達。這點記錄下來，不作推論。

**Blocked by:** 08

**Status:** ready-for-agent

- [ ] Demo 與 Edge 重新開機後，`8082` 與 `8081` 皆無需人工介入即恢復
- [ ] 重開機後 Edge 的防火牆政策自動恢復
- [ ] 重開機後 Demo 的掛載與 Docker data-root 自動恢復
- [ ] 未配置 port fail closed、私有位址不可直達、未連 VPN 不可達，三項在重開機後重測通過
- [ ] Demo 可經 Edge 連到核准的外部更新來源
- [ ] Demo 無法主動連到管理端點
- [ ] `/srv/platform` 剩餘空間至少二成
- [ ] 每次探測的來源、目的與結果均有記錄
- [ ] 上述全部通過後，才開啟 Demo 的開機自啟
- [ ] 已記錄經驗性驗證僅證明當下可達，不推論 policy 範圍
