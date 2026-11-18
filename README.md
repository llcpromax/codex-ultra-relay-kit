# Codex Ultra Relay Kit

> 让 Codex 桌面版在第三方 API 中转站上解锁并使用 `ultra` 推理档位的 Windows 一键工具包。

---

## 背景

Codex 桌面版（`OpenAI.Codex` MSIX）的模型选择器里是否出现 **Ultra** 推理档位，取决于客户端内的 Statsig 功能门禁，而不是中转站是否支持。

于是出现矛盾：

- 你的中转站**实际支持** `ultra`（甚至只接受 `ultra`），
- 但客户端因为**账号门禁不通过**，界面上只给到 `xhigh` / `max`，
- 请求发出去是 `xhigh`，上游返回报错或降级。

此外网络不稳 / 后台小任务（生成标题、智能建议、commit message 等）常常使用一个你中转站没有开通的小模型，导致报错。

本工具包用三件事解决这些问题：

1. **本地代理改写**：把 `xhigh` / `max` 在转发前改成 `ultra`；
2. **门禁注入**：启动时通过 CDP 注入 Statsig 门禁，让 Ultra 出现在模型选择器；
3. **无感守护**：正常点官方图标启动时自动重启为 Ultra 实例，`config.toml` 被覆盖时自动修复。

---

## 原理架构

```
┌──────────────────────────┐
│  Codex 桌面版 (MSIX)     │
│  base_url = 127.0.0.1:8787│
└────────────┬─────────────┘
             │ HTTP / SSE
             ▼
┌──────────────────────────┐        ┌────────────────────┐
│  本地代理 proxy.py        │───────▶│  你的中转站        │
│  127.0.0.1:8787          │        │  https://.../v1    │
│  · xhigh/max → ultra     │        └────────────────────┘
│  · 后台任务跟随主模型     │
│  · upstream.txt 动态读取  │
└──────────────────────────┘
             ▲
             │ 由 repair-config.ps1 写入 config.toml
             │
┌────────────┴─────────────┐
│  watch-codex.ps1 守护     │
│  · 官方图标启动 → 重启为  │
│    Ultra 实例             │
│  · config.toml 变更 → 修复│
└──────────────────────────┘
```

四个部件：

| 部件 | 作用 |
| --- | --- |
| **门禁注入**（`start-codex-ultra.ps1`） | 用 `IApplicationActivationManager` 以 `--remote-debugging-port=9333` 启动 MSIX 应用，连接 CDP，等待 Statsig 初始化后注入门禁 `1186680773`，并用定时器每 5 秒保活，直到 Ultra 选项稳定出现在模型选择器。 |
| **本地代理**（`proxy.py`） | 监听 `127.0.0.1:8787`，把 `xhigh` / `max` 改写为 `ultra`（仅对支持 ultra 的模型）；把后台任务请求路由到最后一个主模型。上游地址从 `upstream.txt` 动态读取，支持 `/v1` 这类基础路径。 |
| **后台跟随** | 客户端生成标题 / 智能建议 / commit message 等后台请求使用的小模型，在你中转站可能不存在。代理识别请求中的提示词标记，把 `model` 换成最近一次主对话使用的模型。 |
| **官方图标守护 + CC Switch 自动修复**（`watch-codex.ps1` + `repair-config.ps1`） | 每 2 秒检查：发现 ChatGPT 进程在跑但 9333 未监听 → 自动用启动器重启；发现 `config.toml` 被外部改写 → 重新抓取真实 `base_url` 存入 `upstream.txt`，把 `base_url` 改回本地代理并补上 `[desktop]` 的 Ultra 开关。 |

---

## 功能列表

- 一键安装 / 一键卸载，全程普通用户权限，无需管理员
- Ultra 推理档位在模型选择器中可见、可用
- `xhigh` / `max` → `ultra` 自动改写（仅对已知支持 ultra 的模型）
- 后台任务自动跟随主模型，避免小模型 404 / 报错
- 上游地址动态读取（`upstream.txt`），改文件即换站，支持 `https://host/v1` 形式
- 点官方图标启动时自动接管为 Ultra 实例（无感重启）
- `config.toml` 被 CC Switch 等工具覆盖后自动修复（10 秒冷却）
- 请求体 gzip / deflate / zstd 解压后再改写
- SSE 流式响应逐块透传，错误响应完整写入日志
- 开机自启（代理 / 启动器 / 守护三项）
- 桌面快捷方式与隐藏启动（VBS），不弹黑框

---

## 环境要求

- Windows 10 / 11（x64 或 arm64）
- Codex 桌面版已安装（MSIX 包名 `OpenAI.Codex`），并且至少成功登录 / 配置过一次中转站
- Python 3.9 及以上，`pythonw.exe` 在 `PATH` 中
- PowerShell 5.1（系统自带）
- 可选：CC Switch（用于切换中转站；它覆盖 `config.toml` 后本工具会自动修复）

---

## 安装步骤

```powershell
# 1. 进入仓库根目录
cd .\codex-ultra-relay-kit

# 2. 允许本地脚本执行（仅当前用户）
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

# 3. 安装（把你的中转站地址换进去）
.\install.ps1 -Upstream "https://your-relay.example.com/v1"
```

不传 `-Upstream` 时会使用 `scripts\upstream.txt.example` 的占位值，安装完成后编辑：

```
%USERPROFILE%\.codex\relay-proxy\upstream.txt
```

只装不启动（稍后手动点快捷方式）：

```powershell
.\install.ps1 -Upstream "https://your-relay.example.com/v1" -NoStart
```

安装内容：

- 文件复制到 `%USERPROFILE%\.codex\relay-proxy\`
- 生成 `upstream.txt`
- 修复 `%USERPROFILE%\.codex\config.toml`
- 注册三个 `HKCU\...\Run` 自启项
- 生成 `Launch Codex Ultra.vbs` 与桌面快捷方式 **Codex Ultra**

---

## 使用方式

**日常启动**：双击桌面的 **Codex Ultra**。它会静默完成：确保代理在跑 → 关闭旧实例 → 修配置 → 带调试端口启动 → 注入门禁。

**直接点官方图标**：也能用。守护进程会在 30 秒内发现「进程在跑但 9333 未监听」，自动重启为 Ultra 实例（窗口会闪一下，属正常）。

**开机自启**：代理、启动器、守护进程三项都已注册，登录后自动生效。

**使用 Ultra**：打开模型选择器，选择带 Ultra 档位的模型，推理强度选 **Ultra**；如果选 `xhigh` / `max`，代理也会在转发时改写为 `ultra`。

### GPT-6.2

中转站已提供 `gpt-6.2-astra` 和 `gpt-6.2-sol`，但当前 Codex 客户端的模型目录里还没有 6.2，界面不会直接列出。代理默认做映射：

- `gpt-6-astra` → `gpt-6.2-astra`
- `gpt-6-sol` → `gpt-6.2-sol`

所以界面里仍然选 **6 Astra / 6 Sol**，实际请求走的是 6.2；6.1、5.6、Luna 等模型不受影响。

注意：6.2 **不支持 `ultra`**，只支持 `none/minimal/low/medium/high/xhigh/max`。代理对 6.2 不会做 `xhigh/max → ultra` 改写；界面里的 Ultra 发给 6.2 时实际是 `xhigh`，可以正常使用。想在 6.2 上用最高档，可在界面选 **Max**。

要关闭或修改映射，编辑 `proxy.py` 里的 `MODEL_ALIASES`。

### VS Code 插件

VS Code 的 Codex 插件和桌面端共用同一个账号门禁（Statsig `1186680773`），所以默认也会隐藏 Ultra。给插件打补丁：

```powershell
python scripts\patch-vscode-extension.py
```

然后在 VS Code 命令面板执行 `Developer: Reload Window`。补丁会修改当前最新 `openai.chatgpt-*` 扩展的 webview bundle，强制包含 Ultra 档位。

注意：

- 插件升级后补丁会被覆盖，需要重新运行一次；
- 补丁只影响本地插件文件，不改账号或中转站；
- 支持 Ultra 的模型同桌面端：6 Astra、6.1 Sol、6 Sol、6.1 Terra、5.6 Sol、5.6 Terra。

**换中转站**：

1. 编辑 `%USERPROFILE%\.codex\relay-proxy\upstream.txt`，写入新地址（一行，可带 `/v1`），保存；
2. 代理会自动感知文件变更，**无需重启**。

---

## 换中转站 / CC Switch 说明

当 CC Switch 切换站点时，它会重写 `config.toml` 里的 `base_url` 指向新中转站，从而绕过本地代理。守护进程会：

1. 检测到 `config.toml` 的修改时间 / 大小变化；
2. 调用 `repair-config.ps1 -Restart`；
3. 把新的真实 `base_url` 抓取并写入 `upstream.txt`；
4. 把 `base_url` 改回 `http://127.0.0.1:8787`；
5. 确保 `[desktop]` 下有 `show-ultra-in-model-picker-slider = true`；
6. 若 Codex 正在运行，先停再写，然后重新以 Ultra 模式启动。

所以 CC Switch 换站后**不需要手动操作**，最多等 10 秒。

支持的地址形式：

```
https://your-relay.example.com
https://your-relay.example.com/v1
http://10.0.0.5:3000/openai/v1
```

`/v1` 等基础路径会被自动拼接到请求路径前面。

---

## 日志与排错

所有日志都在 `%USERPROFILE%\.codex\relay-proxy\`：

| 文件 | 内容 |
| --- | --- |
| `proxy.log` | 每条请求的方法、路径、状态码、模型、effort 改写情况、上游地址；上游错误会带前 400 字节响应 |
| `launcher.log` | 启动器：AUMID、激活返回值、CDP target、Statsig 就绪、门禁注入结果 |
| `watcher.log` | 守护：配置变更、重启决策、锁清理 |
| `repair.log` | 修复：当前 provider、发现的 upstream、写入结果 |

常见问题：

- **8787 端口未监听**：Python 不在 `PATH`，或 `proxy.py` 被安全软件拦截。手动运行 `python proxy.py` 看报错。
- **Ultra 选项不出现**：查 `launcher.log` 是否有 `statsig ready=True` 与 `inject: ok:true`；若 `no CDP target`，说明应用没有以 9333 启动，检查是否有多个 Codex 实例。
- **请求 401 / 403**：中转站 token 问题，与代理无关；先确认 `config.toml` 中该 provider 的 key 正确。
- **报错 model not found**：你的中转站没有该后台小模型，确认 `proxy.py` 里的 `BACKGROUND_MODELS` / `BACKGROUND_MARKERS` 覆盖到了对应请求。
- **端口冲突**：`8787` 被占用时改 `proxy.py` 的 `LISTEN_PORT`，并同步修改 `repair-config.ps1` 中的改写地址与 `uninstall.ps1`；`9333` 被占用时关闭调试端口的其它程序。

---

## 卸载

```powershell
# 还原 config.toml，保留安装目录
.\uninstall.ps1

# 还原 config.toml，并删除安装目录
.\uninstall.ps1 -RemoveFiles

# 什么都不改，只删自启项并停进程
.\uninstall.ps1 -KeepConfig
```

卸载脚本会：

1. 删除 `CodexRelayProxy` / `CodexUltraLauncher` / `CodexUltraWatcher` 三个自启项；
2. 结束安装目录下的 `proxy.py` 与 `watch-codex.ps1` 进程；
3. 从 `upstream.txt` 读回真实地址，把 `config.toml` 的 `base_url` 还原；
4. 删除 `show-ultra-in-model-picker-slider` 这一行；
5. （可选）删除安装目录。

完成后请重启 Codex。桌面快捷方式与 VBS 会在删除安装目录时一并移除；若未删除，可手动删除桌面上的 **Codex Ultra** 快捷方式。

---

## 安全说明

- 代理只监听 `127.0.0.1:8787`，不对外网开放。
- 调试端口 `9333` 也只绑定本机；它只在 Codex 运行期间存在。
- 本工具包不读取、不存储、不传输你的 API Key；Key 由 Codex 客户端自己放进请求头，代理仅透传。
- 请勿把 `config.toml`、`upstream.txt`、`*.log` 或任何 token 提交到公开仓库；本仓库 `.gitignore` 已排除这些文件。
- 注入的门禁只存在于当前客户端进程的内存中，不会修改应用文件，也不影响官方更新。

---

## 免责声明

本项目为**非官方**工具，与 OpenAI 无任何关联。

- 依赖客户端内部实现细节（Statsig 门禁 ID、CDP 调试接口、`config.toml` 结构），客户端更新后**可能随时失效**；
- 使用第三方中转站可能违反其服务条款，请自行确认合规性；
- 使用本工具产生的任何后果（包括但不限于账号风险、请求费用、数据问题）由使用者自行承担。

---

## License

MIT
