# Claude Code 国内加速安装

从 Anthropic 官方源自动同步 Claude Code 二进制到 GitHub Releases，通过 GitHub 镜像实现国内免代理安装。

## 快速安装

```bash
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/iRubbish/ClaudecodeCN/main/install.sh | bash
```

备用镜像：

```bash
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/iRubbish/ClaudecodeCN/main/install.sh | bash
```

安装指定版本：

```bash
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/iRubbish/ClaudecodeCN/main/install.sh | bash -s -- 2.1.123
```

## 支持平台

| 平台 | 架构 |
|------|------|
| macOS | arm64 (Apple Silicon)、x64 (Intel) |
| Linux (glibc) | x64、arm64 |
| Linux (musl) | x64、arm64 |

macOS 下 Rosetta 2 转译会被自动检测，Intel 机器上运行 arm64 进程时会正确选择 arm64 二进制。

## 安装脚本做了什么

`install.sh` 的完整流程：

1. **探测镜像** — 依次尝试 `ghfast.top`、`gh-proxy.com`、直连 GitHub，选第一个通的作为下载源
2. **检测平台** — 通过 `uname` 判断 OS 和架构，Linux 下额外检测 glibc/musl
3. **获取版本** — 从仓库的 `latest_version` 文件读取最新版本号
4. **下载并校验** — 从 GitHub Release 下载对应平台的二进制和 `manifest.json`，用 SHA256 校验完整性
5. **安装二进制** — 放到 `~/.local/share/claude/versions/<version>`，在 `~/.local/bin/claude` 创建符号链接
6. **配置 PATH** — 检测当前 shell（zsh/bash/fish），如果 rc 文件中没有 `.local/bin` 则自动追加：
   - zsh → `~/.zshrc`
   - bash (macOS) → `~/.bash_profile`
   - bash (Linux) → `~/.bashrc`
   - fish → `~/.config/fish/config.fish`
7. **立即生效** — 在当前进程中 export PATH，安装完直接可以运行 `claude`，不需要重启终端

## 自动同步机制

GitHub Actions（`.github/workflows/sync.yml`）每 6 小时执行一次：

1. 从 `https://downloads.claude.ai/claude-code-releases/latest` 获取最新版本号
2. 检查本仓库是否已有对应 Release tag，有则跳过
3. 没有则运行 `sync.sh`：下载全平台二进制 → SHA256 校验 → 创建 GitHub Release → 更新 `latest_version` 文件并提交

也可以在 Actions 页面手动触发 `workflow_dispatch`。

## 目录结构

```
.
├── install.sh              # 用户侧安装脚本
├── sync.sh                 # 上游同步脚本（Actions 调用）
├── latest_version           # 当前最新版本号
├── LICENSE
└── .github/workflows/
    └── sync.yml            # 定时同步 workflow
```

## 安装后的文件布局

```
~/.local/
├── bin/
│   └── claude -> ../share/claude/versions/<version>    # 符号链接
└── share/
    └── claude/
        └── versions/
            └── <version>                                # 实际二进制
```

## 卸载

```bash
rm -f ~/.local/bin/claude
rm -rf ~/.local/share/claude
```

然后从 shell 配置文件中删除 `export PATH=$HOME/.local/bin:$PATH` 那一行（如果是脚本自动添加的）。

## License

[Apache-2.0](LICENSE)
