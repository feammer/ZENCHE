# ZENCHE TODO / 待办

> 最近更新：2026-11-08（v2.0.0 移除 AI 与账号功能）

## P0 — v2.0.0 收尾

- [ ] **macOS 账号与云端 AI 正式移除**（本版本暂缓，功能仍在）
  - 删除 `native/macos/Sources/NikonLink/AuthService.swift`
  - `main.swift`：移除 `RootView` 的 `model.auth.state` 三路守卫、`LoginView`、
    `applyAuthState`、`bootstrap`，改为直接进入 `mainWorkspace`
  - `main.swift`：移除 `EditorAdjustmentSection.aiTools`、AI 工具面板、
    `AiImageService`、`ActivationManager`、AI 生成/保存链路
  - `SettingsSheet.swift`：移除账号区与 AI 功能激活/兑换/设备码区
  - `AppModel.swift`：移除 `auth` 属性、订阅与登出清理逻辑
  - 清理 `Localizable.strings` 中不再引用的 AI/账号词条
- [ ] **HarmonyOS 死代码清理**：`Index.ets` 中登录墙方法、`AuthManager` 引入、
  AI 工作台方法、激活/兑换/设备码字段与 `Localization.ets` 词条仍在，仅入口已移除
- [ ] **五端未使用词条清理**：Windows `Localization.cs`、Android
  `Localization.java`、iOS/macOS `Localizable.strings`、Harmony `string.json`
  仍保留已下线功能的文案
- [ ] **2.0.0 应用内更新公告**：五端公告弹窗内容仍描述 1.5.15；按 AGENTS.md
  需为 2.0.0 更新为“移除账号与云端 AI”的等价文案
- [ ] **补齐被移除的测试覆盖**：AI/账号契约测试已删除；相机、监看、文件库、
  编辑器等非 AI 覆盖需补充回归测试（当前 `npm test` 295 通过 / 16 跳过）

## P1 — 发布与 CI

- [ ] `release.yml` 的六包白名单与当前四包发布范围不一致：要么补齐
  HarmonyOS/macOS 构建，要么把门禁改为可配置资产清单
- [ ] HarmonyOS CI 构建（DevEco 命令行工具链）
- [ ] macOS CI 打包：Nikon/Sony 专有 SDK 需在 runner 中以安全方式提供
- [ ] 发布 `v2.0.0` 后将官网/更新服务迁移到新清单（本版本未部署官网）

## P2 — 产品与工程

- [ ] 删除 `website/`、`website-vue/` 后同步下线外部 Pages 站点与兑换入口
- [ ] 删除 `ai-server/` 后下线外部 AI 代理、账号 API、管理台与换绑签发端
- [ ] 评估是否保留 `server.mjs` 的更新 API（当前保留，不依赖账号）
- [ ] 统一版本公告文案与 README 三语内容
