# jb-local

把 `irm ckey.run | iex` 那套东西，变成本地版本。

---

## 1. 目录结构

```
src/Mint.java            身份生成 + power.conf 规则推导 + 许可证签发（Java 8+，无依赖）
src/Verify.java          自检工具：证明"带 agent 时 CA 验签翻真"
payload/                 ja-netfilter.jar + 插件 + 4 个 conf + ca-modulus.txt
scripts/install.ps1      Windows 安装器（下载→校验→安装→签 key→改 vmoptions）
scripts/install.sh       Linux / macOS 安装器
tests/smoke-test.ps1     打包后自检（CI 会跑）
build.ps1                本地打包：mint.jar → payload.zip → SHA256SUMS.txt
.github/workflows/       tag 触发，构建 + 自检 + 发 Release
```

## 2. 安装

### Windows：一条命令

```powershell
irm https://github.com/jdfcc/jb-local/releases/download/v1.0.1/install.ps1 | iex
```

校验并解包资产 → 装 agent → **在本机生成身份与 `power.conf`** → 给每个已装产品签 key → 改 vmoptions；不是管理员会弹 UAC 重跑自己（重新 `irm` 同一地址）。

`irm | iex` 不能传参，选项走环境变量（同一会话里设一次即可）：

| 需求 | 写法 |
|---|---|
| 先看流程、不落盘 | `$env:JB_LOCAL_DRYRUN=1; irm ... \| iex` |
| 不装 privacy/hideme（兼容性优先） | `$env:JB_LOCAL_SKIP_HIDING=1; irm ... \| iex` |
| 自定义安装目录 | `$env:JB_LOCAL_INSTALL_DIR='D:\jb-local'; irm ... \| iex` |
| 许可证名 / 到期 | `$env:JB_LOCAL_NAME='张三'; $env:JB_LOCAL_EXPIRY='2099-12-31'; irm ... \| iex` |
| 只写 key、不动 vmoptions | `$env:JB_LOCAL_NO_VMOPTIONS=1; irm ... \| iex` |
| 卸载 | `$env:JB_LOCAL_UNINSTALL=1; irm ... \| iex` |
| 完全离线 | `$env:JB_LOCAL_PAYLOAD='D:\dist'; irm ... \| iex` |
| 排错（打印生效配置） | `$env:JB_LOCAL_DEBUG=1; irm ... \| iex` |

其余可覆盖项：`JB_LOCAL_REPO` `JB_LOCAL_TAG` `JB_LOCAL_LAYOUT_ROOT` `JB_LOCAL_CONFIG_ROOT` `JB_LOCAL_NOELEVATE`。

### Windows：存盘执行（可先核对哈希）

```powershell
irm https://github.com/jdfcc/jb-local/releases/download/v1.0.1/install.ps1 -OutFile install.ps1
Get-FileHash .\install.ps1 -Algorithm SHA256      # 与 release 说明里的值比对
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File .\install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

参数：`-Repo jdfcc/jb-local -Tag v1.0.1 -InstallDir C:\ProgramData\jb-local -LicenseName "你的名字" -Expiry 2099-12-31`
可选：`-SkipHiding`、`-NoVmOptions`、`-DryRun`、`-NoElevate`、`-LocalPayload <dir>`。

### Linux / macOS

```bash
curl -fsSL -o install.sh https://github.com/jdfcc/jb-local/releases/download/v1.0.1/install.sh
sha256sum install.sh                              # 与 release 说明比对
sudo bash install.sh                              # 或 --dry-run / --uninstall / --from-dir
```

### 完全离线

把 `payload.zip`、`SHA256SUMS.txt`、`install.ps1` 拷到目标机：

```powershell
$env:JB_LOCAL_PAYLOAD='.\dist'; irm .\install.ps1 | iex     # 或者 .\install.ps1 -LocalPayload .\dist
# Linux: sudo bash install.sh --from-dir /path/to/dist
```

### 卸载

```powershell
$env:JB_LOCAL_UNINSTALL=1; irm https://github.com/jdfcc/jb-local/releases/download/v1.0.1/install.ps1 | iex
# 或存盘：.\install.ps1 -Uninstall
# Linux: sudo bash install.sh --uninstall
```

卸载会删 key、恢复 `vmoptions` 备份、删安装目录；`disabled_plugins.txt` 里被去掉的 `com.intellij.modules.ultimate` 需要手动加回。

## 3. 关键参数

| 文件 / 参数 | 作用 | 什么时候要改 |
|---|---|---|
| `payload/config/ca-modulus.txt` | JetBrains 许可证根证书（`CN=JetProfile CA`）的 RSA 模数 | **JetBrains 轮换根证书时**——换掉这一行数字，重新打 release，用户重跑安装器即可 |
| `--expiry` / `-Expiry` | `paidUpTo` / `fallbackDate`，默认 `2099-12-31` | 想换年限 |
| `--product-codes` | 产品码，安装器按产品自动带（`II,PCWMP,PSI` 等） | 新品 |
| `--license-name` / `-LicenseName` | 许可证显示名 | 随意 |
| `-InstallDir` | 安装目录，默认 `C:\ProgramData\jb-local` | 想换位置 |

## 4. 原理

1. `ja-netfilter.jar` 作为 `-javaagent` 进 JVM，用 ASM 改写 `java.math.BigInteger.oddModPow`——RSA 验签的必经函数。
2. 安装时现场生成 4096-bit 身份和一张证书：**issuer 写成 `CN=JetProfile CA`，但用你自己的私钥签**。同时算出这张证书 TBS 的 PKCS#1 v1.5 DigestInfo，写成 `power.conf` 里那一条 `[Result]` 规则。
3. IDE 校验"证书是不是 JetProfile CA 签的"时，`sig^65537 mod n_CA` 被规则替换成上面那个常量 → 校验通过（**不需要 CA 私钥**）。
4. 许可证正文用你本机的私钥 `SHA1withRSA` 真签名，IDE 拿证书公钥验 → 真的通过；`paidUpTo` 就是你填的日期。
5. `privacy.jar` / `hideme.jar` 负责把 `-javaagent` 从 `RuntimeMXBean`、`VMOptions`、诊断上报里藏掉；`url.conf` / `dns.conf` 掐掉在线校验。

自检（CI 每次都跑，也可本地跑）：

```powershell
pwsh ./build.ps1
pwsh ./tests/smoke-test.ps1 -Dist ./dist
# 期望：without agent -> false；with agent -> true；license -> true
```

## 5. 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| `Key is invalid` | agent 没加载（检查 `<install>/bin/*.vmoptions` 与 `%APPDATA%\JetBrains\<产品><版本>\*.vmoptions` 里的 `-javaagent` 行）；或 `state/` 与 `power.conf` 不匹配（删 `state/` 重跑）；或 JBR 版本已改 `BigInteger` 实现 |
| IDE 启动报错 / 起不来 | 先 `-SkipHiding` 重装；仍是就删掉 `plugins/privacy.jar`、`plugins/hideme.jar` 再试（激活不依赖它们） |
| 升级 IDE 后失效 | 大版本会重建 `bin` 与 vmoptions，`-javaagent` 被清掉——**重跑安装器**即可，key 通常还在 |
| 提示"需要登录/在线激活" | 该版本已改为在线校验模式，本方案不适用 |
| 找不到产品 | `.home` 指向的目录里没有 `bin`；用 `-LayoutRoot` 指到真正的 `%LOCALAPPDATA%\JetBrains`，或手工把 `-javaagent` 加到对应 vmoptions |
| 两个 agent 打架 | 安装器会删掉所有 `-javaagent:*.jar` 行再加自己的；如仍有旧工具，先跑它的卸载 |



## 6. 说明

`payload/ja-netfilter.jar` 与 `payload/plugins/*.jar` 来自 ja-netfilter 项目及其社区插件，版权归各自作者；本仓库只做打包、安装器、身份/许可证生成与校验逻辑。`src/` 下的代码为本仓库新增。
