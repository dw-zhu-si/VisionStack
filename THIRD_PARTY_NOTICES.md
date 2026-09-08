# 第三方软件与能力声明

映栈的开源源码与公开版包含以下受控、纯说明能力。应用不会执行这些上游项目的脚本、Hook、MCP、安装器或外部命令。完整许可证随 App 资源包一并分发。

| 组件 | 上游与固定版本 | 许可 | 映栈采用范围 |
|---|---|---|---|
| GC Minimal Zine Poster | `yub369302-cyber/gc-minimal-zine-poster` @ `4cb0396ad4e834019f753b37e1c4f415f5e02026` | MIT | 极简 Zine 提示词、变化配方、负向边界与质量门禁 |
| Impeccable | `pbakaus/impeccable` @ `5c5553b1d7f9e89bb833f9179cea681742a17720` | Apache-2.0 | 图片终稿品质审校的 instruction-only 适配；未采用上游 NOTICE 所述平台设计来源 |
| Photo Relic Editorial | `wnby/photo-relic-editorial` @ `2232da16afddc7940e2e2f280bfb85aa62da1bae` | MIT | 照片遗迹与纸感旧时光风格的受限提示词适配 |
| Portrait Reshoot Direction | `nuyoah-ai-works/nuyoah-xiezhen-prompt` @ `7482a14074bcffb9fed8eb8fe2ddcdc4ac2e980b` | MIT | 双参考职责、光线拓扑、表情事件与背景层级方法 |
| Taste | `Leonxlnx/taste-skill` @ `e988add20dab0fa97d7a76781c48961c8184288e` | MIT | 图片审美方向设计的 instruction-only 适配 |
| 映栈图片审美基础 | 野路子工作室，2026-08-28 | MIT | 公开版图片提示词编译基础 |
| 映栈视频导演基础 | 野路子工作室，2026-08-28 | MIT | 公开版视频提示词编译基础 |

上游来源、固定提交、适配边界与对应许可证位于 App 内 `VisionStack_VisionStack.bundle/ManagedSkills/<组件>/`。产品名称与商标归各自权利人所有。

## 开源范围

映栈自有应用代码、文档与两项基础资源使用根目录 MIT 许可证。第三方资源分别按上表及各自目录内许可证授权；根 MIT 不替代 Apache-2.0 等第三方许可。旧版私人或授权不明确资源不包含在本仓库中。

Windows 工程通过 NuGet 引用 Avalonia、CommunityToolkit.Mvvm、System.Security.Cryptography.ProtectedData、Velopack 及测试依赖。精确版本与传递依赖见各项目 `packages.lock.json`；本仓库不捆绑这些依赖的 DLL。重新分发二进制时，应随制品提供实际依赖及字体的许可声明。

MIT 软件许可不授予“映栈 / VisionStack”名称、标识或商标的权利，也不代表官方认可衍生版本。修改版请清楚标注来源与修改，避免与官方发行混淆。
