# Impeccable 来源与适配说明

- 上游项目：`pbakaus/impeccable`
- 上游地址：https://github.com/pbakaus/impeccable
- 核验提交：`5c5553b1d7f9e89bb833f9179cea681742a17720`
- 上游 Skill 版本：`4.1.1`
- 主要参考定义：`.agents/skills/impeccable/SKILL.md`、`reference/polish.md`、`reference/craft-floor.md`、`reference/bolder.md`、`reference/quieter.md`
- 上游主定义 SHA-256：`9d124382509eb15da0862f145bca0e53be00aaddb05272e4efc9a0832de048a9`
- 许可证：Apache-2.0；上游 NOTICE 中的平台设计来源未被本图片适配采用。
- 适配状态：映栈项目内 instruction-only 图片适配，不等同于完整 Impeccable 插件或 CLI。
- 排除内容：全部运行脚本、Hook、浏览器实时模式、CLI、扩展、安装器、自动检测器、子 Agent、依赖与外部模型测试。
- 运行边界：只把本文件夹的 `SKILL.md` 作为图片提示词质量门禁注入；不执行任何第三方代码，不建立网络连接，不读取凭证，不写外部状态。
