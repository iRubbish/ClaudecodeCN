# Claude Code 国内加速安装

从 Anthropic 官方源同步 Claude Code 二进制文件到 GitHub Releases，通过 GitHub 镜像实现国内免代理安装。

## 安装

```bash
# 一键安装（推荐）
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/iRubbish/ClaudecodeCN/main/install.sh | bash

# 备用镜像
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/iRubbish/ClaudecodeCN/main/install.sh | bash

# 指定版本安装
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/iRubbish/ClaudecodeCN/main/install.sh | bash -s -- 2.1.117
```

脚本会自动检测可用的镜像源，无需手动配置代理。

## 支持平台

| 平台 | 架构 |
|------|------|
| macOS | arm64 (Apple Silicon)、x64 (Intel) |
| Linux | x64、arm64 |
| Linux (musl) | x64、arm64 |

## 工作原理

- GitHub Actions 每 6 小时自动检查 Anthropic 官方源是否有新版本
- 检测到新版本后，下载全平台二进制文件并校验 SHA256
- 上传到 GitHub Releases，历史版本持续保留
- 安装脚本通过 GitHub 镜像加速下载，国内直连可用
