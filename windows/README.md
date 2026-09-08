# 映栈 Windows 客户端

当前目标版本为 `0.9.0-beta.1`，采用 Avalonia 12、.NET 8 目标框架与 Velopack 1.2.0。项目使用 .NET 10 SDK 编译，以满足 Avalonia 12.1.1 源生成器的编译器要求；应用发布为自包含 Windows 产物。运行测试另需可被 dotnet 主机发现的 .NET 8 Runtime。

## 当前已实现

- ModelHub 与任意厂商直连的统一配置模型。
- ModelHub 仅允许本机回环地址；厂商直连强制 HTTPS，并拒绝私网、链路本地和云元数据地址。
- 厂商元数据原子写入本机 `providers.json`。
- Windows API 密钥使用当前用户范围 DPAPI 加密，与普通配置分离。
- 厂商配置可新增、切换和删除；内置 ModelHub 入口不可删除。
- Windows Beta 的 Avalonia 模型配置界面。
- `win-x64-beta` 与 `win-arm64-beta` 独立更新通道及 Velopack 打包入口。

## 尚未实现

- 真实连接测试和模型目录同步。
- 对话、生图、视频、参考图、Agent/Skills、项目与任务中心的 Windows 功能对齐。
- 受信任 Authenticode、真实 Windows 安装/升级/卸载、Defender 与 SmartScreen 验收。

## 本机验证

```bash
./scripts/test_windows_core.sh
(cd windows && dotnet restore VisionStack.slnx --locked-mode && dotnet build VisionStack.slnx --configuration Release --no-restore)
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

当前端点校验是保存前的本地策略，不会解析 DNS，也不会联网。后续实现真实连接时，必须在每次连接及重定向前解析并固定公网地址，阻止 DNS 重绑定及跨源重定向。
