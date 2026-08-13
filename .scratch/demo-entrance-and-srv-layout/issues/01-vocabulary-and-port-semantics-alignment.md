# 01 — 詞彙與 port 語意對齊

**What to build:** 讓 hypervisor 上的機器名稱與 repo 文件使用同一套環境詞彙，並讓既有 spec 對 `8082` 的描述與已 accepted 的 ADR-0001 一致。使用者讀 runbook 或看 PVE 時，同一台機器不會有兩個名字，同一個 port 不會有兩種身分。

VM 105 改名為 `type-ai-platform-uat`。純標籤變更，不重啟、不動網路與電源狀態。這是 hypervisor 變更，由使用者執行交付的腳本。

repo 端：既有 spec 中把 `10.1.2.57:8082` 描述為臨時驗收 port 的段落改正為常駐 entrance port 並指向 ADR-0001；runbook 配置表的機器名稱更新；文件中作為「Edge 後面的私有 guest」或「UAT 環境」使用的 backend 一詞，改用 `CONTEXT.md` 的詞彙。

這是後續所有票的 prefactor：先把語言弄乾淨，之後的票都用它來寫。

使用者本機的 SSH client alias 在 repo 之外，不修改。

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] PVE 上 VM 105 顯示名稱為 `type-ai-platform-uat`
- [ ] VM 105 的電源狀態、網路設定與磁碟在改名前後一致
- [ ] UAT 的 `10.1.2.57:8081` 在改名前後都回應正常
- [ ] 既有 spec 不再宣稱 `8082` 是臨時／可拋棄的驗收 port，並引用 ADR-0001
- [ ] runbook 配置表使用新機器名稱
- [ ] repo 文件中不再以 backend 指稱私有 guest 或 UAT 環境（應用程式自身的 backend 容器名稱除外）
- [ ] 使用者本機 SSH 設定未被修改
