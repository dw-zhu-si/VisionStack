# 开发说明

## 目录

- `Sources/VisionStack`：SwiftUI 应用、模型连接、持久化、媒体与创作流程。
- `Tests/VisionStackTests`：应用策略、解析、沙盒媒体、备份和队列测试。
- `Packaging`：应用元数据、隐私清单及权限模板。
- `scripts/build_macos.sh`：社区本地构建入口，不使用正式签名或公证服务。
- `windows`：Avalonia / .NET Windows 原型与锁文件，尚未具备完整创作功能。

## macOS

使用 macOS、Swift 6.2+ 和相应 Xcode 工具链：

```sh
swift test
./scripts/build_macos.sh
```

SwiftPM 没有外部包依赖。应用使用 Apple 系统框架。脚本生成签名 ZIP，先在系统临时目录组装并回验 App，避免同步盘给展开应用附加文件属性。脚本的本机 App 打包还使用 `codesign`、`plutil` 等系统工具；无需下载或执行第三方脚本。

默认社区构建使用 `studio.yeluzi.visionstack.community`、`VisionStackCommunity` 数据目录与独立 Keychain service，避免复用官方版的项目和连接凭证。首次 AI 调用需要同意；不需要模型服务即可编译和运行单元测试。真实生成需要用户自行配置服务且可能计费。

社区脚本只做构建、资源复制和 ad-hoc 签名，不安装、不启动应用、不上传、不公证。带 App Sandbox 的本机构建仍需在自己的系统验证文件授权和 Keychain 行为。源码测试或静态签名成功不代表全部 GUI 工作流验证通过。

`scripts/package_macos_app.sh` 是历史官方发行流程，含需要显式配置的正式发布身份参数、历史官方权限模板、渠道输出重建和 Apple 公证步骤，不作为社区快速入门命令。请勿把历史官方身份用于自己的发行，也不要将描述文件、私钥或公证凭证提交仓库。衍生版本须自行配置身份与发布流程。

## Windows

在 `windows` 目录执行，确保使用 `global.json` 约束的 .NET SDK 10.0.302（允许同系列更新补丁）；项目目标框架为 .NET 8。执行测试还需 .NET 8 Runtime，且必须能被所用 dotnet 主机发现；只有 SDK 10 而没有 .NET 8 Runtime 时，构建可成功但测试无法启动。依赖通过锁文件还原。

```sh
cd windows
dotnet restore VisionStack.slnx --locked-mode
dotnet build VisionStack.slnx -c Release --no-restore
dotnet test VisionStack.Windows.Tests/VisionStack.Windows.Tests.csproj -c Release --no-build
```

源码包含 x64/ARM64 目标；DPAPI 与安装行为必须在真实 Windows 验证。`scripts/package_windows.sh` 还需要 Velopack CLI 1.2.0（`vpk`），普通编译和测试不要求打包工具。生成未签名候选不等于允许公开发行。当前尚未实现真实模型连接、对话、生图、视频及项目任务流程。

## 公开源码边界

本仓库是从当前活动工程导出的公开源码快照，保留正式发行仓库的历史。它不包含私人资源目录、未获明确再分发授权的旧能力定义、开发机配置、业务数据、签名材料、缓存或安装包中间产物。公开的七项内置资源保留来源与许可证；两项自有基础资源随本次开源采用 MIT，第三方许可保持原样。

本次为源码开源，不新增或替换官方安装包。后续贡献以本仓库的源码与测试为依据。
