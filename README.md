# Codex Ultra Relay Kit

> 让 Codex 在第三方 API 中转站上稳定使用最高推理档位的 Windows / Linux 工具包。

---

## 背景

Codex 桌面版（`OpenAI.Codex` MSIX）的模型选择器里是否出现 **Ultra** 推理档位，取决于客户端内的 Statsig 功能门禁，而不是中转站是否支持。

于是出现矛盾：

- 中转站实际只接受到 `max`（显式传 `ultra` 会返回 400），
- 但客户端因为**账号门禁不通过**，界面上只给到 `xhigh` / `max`，
- 想用最高档时，要么界面没有 Ultra，要么请求被上游拒绝。

此外网络不稳 / 后台小任务（生成标题、智能建议、commit message 等）常常使用一个你中转站没有开通的小模型，导致报错。

本工具包用三件事解决这些问题：

1. **本地代理转发**：模型原样转发，仅把中转站不接受的 `ultra` 降级为 `max`；
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
│  · ultra → max 降级      │        └────────────────────┘
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
| **本地代理**（`proxy.py`） | 监听 `127.0.0.1:8787`，模型选择原样转发；仅把中转站不支持的 `ultra` 降级为 `max`；把后台任务请求路由到最后一个主模型。上游地址从 `upstream.txt` 动态读取，支持 `/v1` 这类基础路径。 |
| **后台跟随** | 客户端生成标题 / 智能建议 / commit message 等后台请求使用的小模型，在你中转站可能不存在。代理识别请求中的提示词标记，把 `model` 换成最近一次主对话使用的模型。 |
| **官方图标守护 + CC Switch 自动修复**（`watch-codex.ps1` + `repair-config.ps1`） | 每 2 秒检查：发现 ChatGPT 进程在跑但 9333 未监听 → 自动用启动器重启；发现 `config.toml` 被外部改写 → 重新抓取真实 `base_url` 存入 `upstream.txt`，把 `base_url` 改回本地代理并补上 `[desktop]` 的 Ultra 开关。 |

---

## 功能列表

- 一键安装 / 一键卸载，全程普通用户权限，无需管理员
- Ultra 推理档位在模型选择器中可见、可用（实际执行受中转站 effort 上限限制）
- 模型选择原样保留；`ultra` → `max` 降级（当前中转站不支持 ultra）
- 后台任务自动跟随主模型，避免小模型 404 / 报错
- 上游地址动态读取（`upstream.txt`），改文件即换站，支持 `https://host/v1` 形式
- 点官方图标启动时自动接管为 Ultra 实例（无感重启）
- `config.toml` 被 CC Switch 等工具覆盖后自动修复（10 秒冷却）
- 请求体 gzip / deflate / zstd 解压后再改写
- SSE 流式响应逐块透传，错误响应完整写入日志
- 开机自启（代理 / 启动器 / 守护三项）
- 桌面快捷方式与隐藏启动（VBS），不弹黑框
- Linux：纯 Python 代理 + systemd 用户服务（无桌面版门禁注入）

---

## 环境要求

### Windows（桌面版）

- Windows 10 / 11（x64 或 arm64）
- Codex 桌面版已安装（MSIX 包名 `OpenAI.Codex`），并且至少成功登录 / 配置过一次中转站
- Python 3.9 及以上，`pythonw.exe` 在 `PATH` 中
- PowerShell 5.1（系统自带）
- 可选：CC Switch（用于切换中转站；它覆盖 `config.toml` 后本工具会自动修复）

### Linux（CLI）

- Ubuntu 20.04+ / Debian 11+（或其他带 systemd 用户会话的发行版）
- Python 3.8 及以上
- Codex CLI 已安装，并且 `~/.codex/config.toml` 里已有中转站配置
- Linux 版只包含本地代理和配置修复，不使用桌面版的 Ultra 门禁注入

---

## 安装步骤（Windows 桌面版）

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

## Linux 安装与使用（Ubuntu / Debian）

Linux 上的 Codex 是 CLI，没有桌面版模型选择器，因此**不需要** Statsig 门禁注入、启动器和守护进程；工具包只保留本地代理与配置修复。

```bash
git clone https://github.com/llcpromax/codex-ultra-relay-kit.git
cd codex-ultra-relay-kit
bash install.sh --upstream "https://your-relay.example.com/v1"
```

可选参数：

- `--with-catalog`：同时安装 GPT-6.2 模型目录（CLI 通常不需要，直接用 `--model gpt-6.2-astra` 即可）
- `--no-start`：只注册服务，不立即启动

安装脚本会：

- 把 `proxy.py` / `repair_config.py` 复制到 `~/.codex/relay-proxy/`
- 写入 `upstream.txt`
- 把 `config.toml` 当前 provider 的 `base_url` 改为 `http://127.0.0.1:8787`
- 创建 systemd 用户服务 `codex-relay-proxy` 并设置开机自启

管理与排查：

```bash
systemctl --user status codex-relay-proxy
journalctl --user -u codex-relay-proxy -f
cat ~/.codex/relay-proxy/proxy.log
```

使用说明：

- Linux CLI 没有 Ultra 选项，直接在 `config.toml` 设置 `model_reasoning_effort = "max"`；即使写成 `ultra`，代理也会降级为 `max`。
- 换中转站：编辑 `~/.codex/relay-proxy/upstream.txt`，代理会自动读取，无需重启。
- 如果 CC Switch 之类的工具覆盖了 `config.toml`，重新执行一次 `python3 ~/.codex/relay-proxy/repair_config.py` 即可（Linux 版没有自动守护）。

卸载：

```bash
bash uninstall.sh                 # 还原 config.toml，保留安装目录
bash uninstall.sh --remove-files  # 还原并删除安装目录
```

---

## 使用方式（Windows 桌面版）

**日常启动**：双击桌面的 **Codex Ultra**。它会静默完成：确保代理在跑 → 关闭旧实例 → 修配置 → 带调试端口启动 → 注入门禁。

**直接点官方图标**：也能用。守护进程会在 30 秒内发现「进程在跑但 9333 未监听」，自动重启为 Ultra 实例（窗口会闪一下，属正常）。

**开机自启**：代理、启动器、守护进程三项都已注册，登录后自动生效。

**使用 Ultra**：打开模型选择器，选择模型，推理强度选 **Ultra** 或 **Max**。当前中转站只支持到 `max`，代理会把显式的 `ultra` 降级为 `max`，其余档位原样转发。

### GPT-6.2 与自定义模型目录

Codex 客户端的模型选择器来自本地模型目录。仓库里的 `scripts/model-catalog-v2.json` 通过 `model_catalog_json` 注入，包含：

- 6.2 Sol / 6.2 Astra
- 6.1 Sol / 6 Astra / 6 Sol / 6 Luna / 6.1 Terra
- 5.6 Sol / 5.6 Terra / 5.6 Luna / 5.5

因此界面里可以直接选 **6.2**，6/6.1 等原有模型也保持原样，不会被替换成 6.2。

注意：

- 当前中转站只接受 `none/minimal/low/medium/high/xhigh/max`，**拒绝 `ultra`**；代理会把显式的 `ultra` 降级为 `max`，其余档位原样转发。界面里的 Ultra 档位仍然可选，实际会按中转站支持的顶档执行。
- 客户端按 `model_catalog_json` 的**路径**缓存模型列表；修改目录内容后，把文件名改成新版本（如 `model-catalog-v3.json`）并同步 `config.toml`，才能让界面刷新。
- 安装脚本会把目录放到 `~/.codex/model-catalog-v2.json`，并在 `config.toml` 写入 `model_catalog_json`。
- 卸载或换回内置目录时，删除 `config.toml` 里的 `model_catalog_json` 这一行即可。

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

## 卸载（Windows 桌面版）

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
