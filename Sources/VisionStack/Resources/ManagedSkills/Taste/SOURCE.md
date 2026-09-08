# Taste 来源与适配说明

- 上游项目：`Leonxlnx/taste-skill`
- 上游地址：https://github.com/Leonxlnx/taste-skill
- 核验提交：`e988add20dab0fa97d7a76781c48961c8184288e`
- 主要参考定义：`skills/imagegen-frontend-web/SKILL.md`
- 上游定义 SHA-256：`6b5c2256522fdba1e3313eafa3d743b960a7b13ec029d3e6586e04b23327c1f8`
- 许可证：MIT
- 适配状态：映栈项目内 instruction-only 图片适配，不等同于完整上游包。
- 排除内容：上游安装脚本、仓库维护脚本、前端代码生成要求以及与映栈通用图片生成无关的网页分段输出约束。
- 运行边界：只把本文件夹的 `SKILL.md` 作为图片提示词方法注入；不执行上游或本地脚本，不建立网络连接，不读取凭证，不写外部状态。
