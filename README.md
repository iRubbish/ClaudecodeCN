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

更新到最新版（跳过 API 配置交互）：

```bash
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/iRubbish/ClaudecodeCN/main/install.sh | bash -s -- update
```

指定优先镜像（脚本会先用它，失败再依次回退其他镜像）：

```bash
# 优先 gh-proxy.com
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/iRubbish/ClaudecodeCN/main/install.sh | CC_MIRROR=https://gh-proxy.com bash
# 优先直连 GitHub
curl -fsSL https://raw.githubusercontent.com/iRubbish/ClaudecodeCN/main/install.sh | CC_MIRROR=direct bash
```

## 配置第三方 API

首次安装（非 `update` 模式）成功后，脚本会交互式询问第三方 API 配置：

```
Optional: configure third-party API in ~/.claude/settings.json
ANTHROPIC_BASE_URL (leave empty to skip): https://your-relay.example.com
ANTHROPIC_AUTH_TOKEN: ****（静默输入，不回显）
```

- `ANTHROPIC_BASE_URL` 直接回车留空即跳过，安装照常完成。
- token 输入不回显，避免泄露到终端。
- 配置会**合并**写入 `~/.claude/settings.json` 的 `env` 块，不覆盖已有的 `model` / `permissions` / 其他 env 字段。
- 通过管道无终端（如 CI）时自动跳过，不报错。
- 需要 `jq` 或 `python3` 之一来安全合并 JSON；都没有则跳过并提示。

写入后的结构：

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://your-relay.example.com",
    "ANTHROPIC_AUTH_TOKEN": "sk-xxx"
  }
}
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

1. **解析参数** — 支持 `update` 子命令（更新并跳过 API 交互）与 `[stable|latest|VERSION]`
2. **构建镜像顺序** — `CC_MIRROR`（如设置）排首位，其余 `ghfast.top`、`gh-proxy.com`、直连 GitHub 去重后兜底
3. **检测平台** — 通过 `uname` 判断 OS 和架构，Linux 下额外检测 glibc/musl
4. **获取版本** — 逐镜像读取 `latest_version`，正则校验防代理返回的错误页
5. **下载并校验** — manifest 与二进制都逐镜像回退；二进制每个镜像下载后立即 SHA256 校验，失败则换下一镜像（curl 用 `--http1.1 --retry` 规避大文件 HTTP/2 流中断）
6. **安装二进制** — 放到 `~/.local/share/claude/versions/<version>`，在 `~/.local/bin/claude` 创建符号链接
7. **配置 PATH** — 检测当前 shell（zsh/bash/fish），如果 rc 文件中没有 `.local/bin` 则自动追加：
   - zsh → `~/.zshrc`
   - bash (macOS) → `~/.bash_profile`
   - bash (Linux) → `~/.bashrc`
   - fish → `~/.config/fish/config.fish`
8. **配置 API（可选）** — 非 update 模式下交互式注入第三方 API 到 `~/.claude/settings.json`
9. **立即生效** — 在当前进程中 export PATH，安装完直接可以运行 `claude`，不需要重启终端

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
