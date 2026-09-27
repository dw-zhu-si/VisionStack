# 映栈 Windows 客户端

当前目标版本为 `0.9.0-beta.1`，采用 Avalonia 12、.NET 8 目标框架与 Velopack 1.2.0。项目使用 .NET 10 SDK 编译，以满足 Avalonia 12.1.1 源生成器的编译器要求；应用发布为自包含 Windows 产物。

## 当前已实现

- ModelHub 与任意厂商直连的统一配置模型。
- ModelHub 仅允许本机回环地址；厂商直连强制 HTTPS，并拒绝私网、链路本地和云元数据地址。
- 厂商元数据原子写入本机 `providers.json`。
- Windows API 密钥使用当前用户范围 DPAPI 加密，与普通配置分离。
- 厂商配置可新增、切换和删除；内置 ModelHub 入口不可删除。
- Windows Beta 的 Avalonia 模型配置与创作工作区。
- 凭证编辑明确区分保留、替换、清除；元数据保存失败时恢复旧凭证，删除也使用相同补偿流程。空输入不会删除已有密钥。
- 用户单独确认后读取真实模型目录作为连接测试；成功不代表对应模型支持所有创作能力。
- 项目新建、切换、手动保存各自模型与草稿、非流式对话及历史保存。
- OpenAI 兼容同步图片生成，支持 Base64 或公网签名 URL 下载、PNG/JPEG 保存、任务状态与绑定厂商记录。
- 将项目 JSON、对话历史及图片导出到用户指定文件夹下的新目录，不覆盖已有文件。
- 停止按钮取消本地 HTTP 请求/下载；生成请求已经发出时，厂商仍可能计费。
- 每次连接/生成都需要明确同意向当前厂商发送数据；每次生成另需费用确认，操作后同意状态清空。启动和保存不会自动联网。
- `win-x64-beta` 与 `win-arm64-beta` 独立更新通道及 Velopack 打包入口。

## 尚未实现

- 视频、参考图、Agent/Skills、素材预览编辑、完整草剪和 macOS 功能对齐。
- 异步厂商任务轮询、重启后自动恢复远端任务、流式对话；中断任务会标记待核对，绝不自动重新计费提交。
- 工作区草稿需点击“保存草稿”；创建项目和完成创作会保存工作区。
- 受信任 Authenticode、真实 Windows 安装/升级/卸载、Defender 与 SmartScreen 验收。

## 本机验证

```bash
./scripts/test_windows_core.sh
dotnet build windows/VisionStack.slnx --configuration Release
./scripts/package_windows.sh win-x64
./scripts/package_windows.sh win-arm64
```

打包脚本只生成未签名候选，输出到 `dist/windows/<RID>/0.9.0-beta.1-unsigned/`。未完成受信任签名与真实 Windows 门禁前，不得上传 GitHub Release。

签名身份获批并已建立不含明文凭证的签名包装器后，使用：

```bash
VISIONSTACK_WINDOWS_SIGN_WRAPPER=/绝对路径/可信签名包装器 \
  ./scripts/package_windows.sh win-x64 signed-candidate
VISIONSTACK_WINDOWS_SIGN_WRAPPER=/绝对路径/可信签名包装器 \
  ./scripts/package_windows.sh win-arm64 signed-candidate
```

包装器由 Velopack 在正确的打包阶段调用，并只接收待签文件路径。密码、令牌、私钥和证书口令不得写进包装器路径、命令行、模板、项目文件或日志；应使用签名服务已认证会话、硬件密钥或系统秘密存储。签名输出固定进入 `0.9.0-beta.1-signed-candidate/`，不会覆盖未签名候选。脚本仍会把 `publicReleaseAllowed` 保持为 `false`，直到真实 Windows 完成签名链、时间戳、安装、升级、卸载、Defender 与 SmartScreen 验收。

Velopack 1.2.0 稳定版当前生成的 Setup 引导程序是 x86 PE；两套应用主体分别是原生 x86-64 与 AArch64。ARM64 包必须在 Windows 11 ARM 的 x86 仿真环境中完成安装器实测，不能仅凭交叉打包宣称通过。

实际 HTTP 连接会解析全部 DNS 结果、校验目标并直接连接已验证 IP；关闭代理继承和自动重定向。直连厂商仅允许 HTTPS 公网地址；ModelHub 仅允许回环。图片下载不携带供应商密钥，仅允许 HTTPS 公网地址。JSON 响应上限 32 MiB，外链素材上限 24 MiB，全程传递取消令牌。DNS 校验保守拒绝混合公网/私网答案。

## 协议范围和验证

| 连接类型 | 模型目录 | 对话 | 图片 |
|---|---|---|---|
| OpenAI 兼容 / ModelHub | GET models | POST chat/completions，非流式 | POST images/generations，同步 Base64/URL |
| Anthropic | GET models | POST messages | 尚不支持 |
| Gemini | GET models | POST models/:id:generateContent | 尚不支持 |

这些是协议适配实现，不代表已对所有厂商做真实账户联调。模型目录分页目前只读取首批（最多 500 条），遗漏模型可手工输入。兼容厂商如果拒绝 `response_format` 或只提供异步接口，会明确失败，不伪造生成成功。

2026-09-27 本机离线验证：.NET 10 SDK Release 编译通过（0 警告、0 错误）；使用已有 .NET 8 运行时，42 项离线测试通过。新增测试覆盖凭证补偿、保留/清除语义、注入假 HTTP 的目录/对话/图片调用、取消、响应上限与重定向拒绝、响应头之后的正文超时、空生成结果、导出快照与路径边界、损坏项目结构拒绝。未进行真实模型计费调用、Windows GUI、DPAPI 真机、签名、安装及升级验证。补偿事务覆盖进程内异常；凭证与 JSON 不构成跨文件抗断电事务，断电恢复需核对并重新保存连接。

测试脚本默认使用已还原依赖，显式 `VISIONSTACK_RESTORE=1` 才执行锁文件还原；不自动安装 SDK/运行时。


补充可靠性：厂商与工作区加载分别处理错误，加载失败会阻止覆盖对应原文件及联网操作。导出在第一个异步等待前快照项目；缺失素材预先报错，中途失败清理本次新建文件，清理不完整时显示确切残留目录。请求开始时固定输入，DNS 地址依次尝试（每地址最多 10 秒），完整响应正文受 3 分钟请求时限约束。

本机真实 Windows 入口检查：2026-09-27，已有 `Codex-Windows11-ARM` 虚拟机但处于挂起；Parallels Pro 试用状态为 `EXPIRED`，到期时间 2026-08-20 23:59:59。本轮未启动虚拟机、未购买或续订；须恢复有效许可后才能进行真实 Windows 验收。
