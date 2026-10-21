# 桌面端 asar 交换手册

DSH 桌面版把宿主代码封在 `resources/app.asar` 里。Electron 的模块解析顺序是 **`app.asar` 优先于 `resources/app` 目录**，所以只要封包还在，写在解开目录里的补丁永远不会被加载——插件面板显示"已应用"，实际运行时读的仍是封包内的原始代码。

这个手册解决的就是最后这一步：把 `app.asar` 挪开，让 Electron 改读 `resources/app`。

## 什么时候需要这一步

出现下面任意一条，说明补丁没有真正生效：

```powershell
# 1. 封包还在
Get-ChildItem 'D:\deepseek\resources' -Filter 'app.asar*'
#    看到 app.asar 而非 app.asar.bak → 未交换

# 2. 进程仍从封包加载
Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" |
  Where-Object { $_.CommandLine -match 'dsh-desktop-host' } |
  Select-Object -ExpandProperty CommandLine
#    路径里带 .asar → 未交换
```

正确的状态是加载路径为 `D:\deepseek\resources\app\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\index.js`，不含 `.asar`。

## 为什么不能靠"关掉再打开"

插件点击「应用」后，会把补丁写入 `resources/app`，然后尝试启动一个**脱离宿主进程树**的 PowerShell 脚本去完成交换。问题在于：

- 在 DSH 会话内通过工具调用启动的子进程，会被宿主自己的 Job Object 连带杀掉
- 通过 WMI `Win32_Process Create` 启动时，**命令行含中文路径会静默失败**——`ReturnValue=0` 只代表 WMI 收下了请求，不代表进程跑起来了

所以最可靠的方式是从资源管理器双击 `.cmd`，它天然不受 DSH 的 Job 约束。

## 操作步骤

### 1. 应用补丁

在插件面板点「应用」，等它显示完成。确认补丁真的写进去了：

```powershell
node -e "const m=await import('file:///C:/Users/Administrator/.dsh/profiles/desktop/node_modules/dsh-purge-plus/lib/core.js');const s=await m.patchStatus('D:/deepseek/resources/app/dsh/node_modules/@deepseek-ai');const t={};for(const v of Object.values(s))t[v]=(t[v]||0)+1;console.log(JSON.stringify(t))" --input-type=module
```

期望 `{"applied":68,"na":13,"skipped":2}` 一类结果——`applied` 应是绝大多数，`failed` 为 0。`na` 是目标插件未安装导致的不适用项，`skipped` 是可选补丁，都不是失败。

### 2. 运行交换脚本

双击 `scripts/swap-asar.cmd`。它会：

1. 按安装根路径前缀杀掉本安装的所有 `DeepSeek Harness.exe`（不用 `/IM` 全名杀，避免误伤同名第三方进程）
2. 若 `app.asar.unpacked` 有内容且 `resources/app` 缺原生模块，用 robocopy 补齐
3. 重试 80 次 `Move-Item app.asar → app.asar.bak`
4. 启动 `D:\deepseek\DeepSeek Harness.exe`

DSH 会自己关闭再打开，这是正常的。日志在 `%TEMP%\purge-swap.log`。

### 3. 验证

```powershell
Get-ChildItem 'D:\deepseek\resources' -Filter 'app.asar*'
# 期望只剩 app.asar.bak
```

再查补丁锚点是否全部命中：

```powershell
node -e "const m=await import('file:///C:/Users/Administrator/.dsh/profiles/desktop/node_modules/dsh-purge-plus/lib/core.js');const d=await m.patchDrift('D:/deepseek/resources/app/dsh/node_modules/@deepseek-ai');console.log('checked',d.checked,'drifted',d.drifted.length,'missing',d.missing.length)" --input-type=module
```

期望 `checked 78 drifted 0 missing 0`。

## 回滚

把封包挪回去即可，补丁代码会留在 `resources/app` 里不再被读取：

```powershell
Move-Item 'D:\deepseek\resources\app.asar.bak' 'D:\deepseek\resources\app.asar' -Force
```

## 两个会骗人的地方

**`selfcheck` 可能报假绿。** `bin/community.js` 的 `findAiBase()` 会扫描多份宿主副本，如果机器上同时存在 npm 全局安装（如 `%APPDATA%\npm\node_modules\@deepseek-ai\dsh`）和桌面版，它可能探到前者。那份副本的补丁状态与桌面端加载的副本无关，`selfcheck` 照样输出"所有层都在位"。判断真实状态只用两种方式：插件面板，或对 `D:\deepseek\resources\app\dsh\node_modules\@deepseek-ai` 直接调 `patchStatus`。

**Windows PowerShell 5.1 按系统代码页读脚本。** 若脚本是无 BOM 的 UTF-8 且含中文字面量（例如日志路径 `D:\deepseek工作\1\swap-asar.log`），5.1 会用 GBK 解码，路径变成 `D:\deepseek宸ヤ綔\1\swap-asar.log`，`Add-Content` 报 `ObjectNotFound`。这不影响主流程，但日志会全丢。脚本已改为 `Join-Path $env:TEMP 'purge-swap.log'`，且不含中文字面量。

## 与 DSH 版本升级的关系

DSH 自动更新会重新装上 `app.asar`，把 `resources/app` 的补丁树覆盖或弃用。升级后按「应用 → 交换 → 验证」重跑一遍即可。`patchDrift` 的 `drifted`/`missing` 会告诉你哪些锚点在新版本宿主里失效了，失效的用 `reanchor` 重新定位，或改 `lib/core.js` 里对应的补丁定义。
