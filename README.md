# 绿电实验室 · 全版本存档

本仓库于 **2026-10-26** 将已交付版本补入 Git。补档提交时间表示归档时间，不伪造原始开发日期。

## 从哪里开始

- **当前 Mac 版：** [1.5.1 源码](archive/mac/v1.5.1/Source/)、[使用说明](archive/mac/v1.5.1/使用说明.md)、[测试报告](archive/mac/v1.5.1/测试报告.md)。
- **全部安装包：** [releases](releases/)，包含 Mac 1.0–1.5.1、独立 IP 测试器、离线连接工具、早期接入包及网页源码包。
- **全部版本索引：** [VERSIONS.md](VERSIONS.md)。原始 ZIP 按字节保留，校验值见 [ARCHIVE_MANIFEST.json](ARCHIVE_MANIFEST.json)。
- **网页版：** 根目录 app/、lib/、db/、adapters/ 等保留原工程布局；[原网页版说明](archive/web/README-original.md)。
- **本地 n8n：** [archive/automation/n8n-local](archive/automation/n8n-local/)，包含模板、启动脚本及测试。
- **电器模型调研：** [GitHub 调研报告](archive/mac/v1.5.0/GitHub电器识别模型调研.md)。

1.5.1 修复采集按钮无反馈：没有实时数据时点击会说明原因，并提供就近连接入口。真实采样仍需先接收有效波形。

## 当前功能和限制

Mac 1.5.1 支持 192.168.1.2:8266 的已核对波形解析、本地保存、Drive 同步、手动供电/采集指令及参考瓦数。参考 W 尚未完成实物标定；6400 Hz 为配置值；继电器输出未被软件独立核实。本机学习分类器已接入，需采集人工标记的真实样本并通过按段验证后启用；尚无用户电器的实物识别验证。第三方预训练模型未接入。

历史版本的说明保留当时状态，其中旧 IP、旧协议假设和 W 留空等不代表最新版行为。早期 YS8000 网页适配器不适用于已经核对的 socket128 报文，应按版本说明使用。

## 版本与数据范围

软件源码、测试、文档、原始交付包和版本内已有的协议验证样本均存档。日常采集目录、n8n 运行数据库、私有接收路径、登录信息、密钥及未授权的厂商反编译源码不进入本仓库。安装包内保留原有测试样本。

原网页三次提交保留在本地归档仓库的祖先历史，并额外保存为 [original-web-history.bundle](archive/original-web-history.bundle)，可通过 Git 恢复原提交。GitHub 补档提交可能具有不同的提交编号。

构建 Mac 版本需 macOS 13+ 与 Xcode Command Line Tools，在相应版本目录运行 `zsh build.sh`。所有源文件按交付包内容保留，未在补档时重新标定或改写历史代码。
