# jb-local

把 `irm ckey.run | iex` 那套东西，变成**你自己的、可审计、可校验、不依赖任何第三方服务器**的本地版本。

- 只从**你自己的 GitHub Release** 下载资产，不再访问 ckey.run；
- 下载全部走 `SHA256SUMS.txt` 校验，装之前就能发现被换包；
- **私钥不出本机**：每台机器首次安装时现场生成 4096-bit 身份并推导 `power.conf`，发布物里没有任何密钥；
- 许可证离线签发，没有 `generateLicense` 接口、没有遥测；
- 安装/卸载可回滚，`vmoptions` 会留 `.bak-jblocal` 备份。

原理见第 6 节。

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

## 2. 三步变成"你的"

1. **默认值已填好**：`jdfcc/jb-local`、`v1.0.0`（`scripts/install.ps1` 的 `$Repo`/`$Tag`、`scripts/install.sh` 的 `REPO_DEFAULT`/`TAG_DEFAULT`）。换仓库/换版本时才需要改。
2. **出包**：本地 `pwsh ./build.ps1`，或 `git tag v1.0.0 && git push --tags` 让 Actions 出 Release。
3. **安装**（见下）。

## 3. 安装

> 想直接管道执行也可以（**注意：这又回到了你担心的投毒面**）：
> `curl -fsSL https://github.com/jdfcc/jb-local/releases/download/v1.0.0/install.sh | sudo bash -s -- --repo jdfcc/jb-local --tag v1.0.0`
> 更稳的是下面这种"下载→核对哈希→执行"。

### Windows（推荐：下载→核对哈希→执行）

```powershell
$u = 'https://github.com/jdfcc/jb-local/releases/download/v1.0.0/install.ps1'
irm $u -OutFile install.ps1
Get-FileHash .\install.ps1 -Algorithm SHA256      # 与 release 说明里的值比对
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

参数：`-Repo jdfcc/jb-local -Tag v1.0.0 -InstallDir C:\ProgramData\jb-local -LicenseName "你的名字" -Expiry 2099-12-31`
可选：`-SkipHiding`（不装 privacy/hideme，隐蔽性下降但兼容性最好）、`-NoVmOptions`（只写 key 和 agent，不动 vmoptions）、`-DryRun`。

### Linux / macOS

```bash
curl -fsSL -o install.sh https://github.com/jdfcc/jb-local/releases/download/v1.0.0/install.sh
sha256sum install.sh                              # 与 release 说明比对
sudo bash install.sh --repo jdfcc/jb-local --tag v1.0.0
```

### 完全离线

把 `payload.zip`、`SHA256SUMS.txt`、`install.ps1` 拷到目标机：

```powershell
.\install.ps1 -LocalPayload .\dist
# Linux: sudo bash install.sh --from-dir /path/to/dist
```

### 卸载

```powershell
.\install.ps1 -Uninstall
# Linux: sudo bash install.sh --uninstall
```

卸载会删 key、恢复 `vmoptions` 备份、删安装目录；`disabled_plugins.txt` 里被去掉的 `com.intellij.modules.ultimate` 需要手动加回（脚本不猜）。

## 4. 为什么不用 `curl ... | bash`

你来这套东西的初衷就是"怕有人投毒"，而 `curl | bash` 恰好把信任交给**执行那一刻的响应**：DNS/CDN/仓库权限任何一环变了，你都在以管理员权限跑别人的代码。

更稳的链路是：

1. 固定 `--tag`（不要 `latest`），最好固定到 **commit SHA** 的资产地址；
2. 下载到本地，**核对 SHA256**，再执行；
3. 仓库侧开 **tag protection**、用 **immutable releases**，并把每个版本的 `SHA256SUMS.txt` **提交进 git**（`checksums/v1.0.0.txt`）——资产可以被有写权限的人替换，但被 tag 冻结的提交不行；能再加上 `git tag -s` 签名更好。

`install.ps1` / `install.sh` 本身也会把校验值打出来，方便你核对：

```
[jb-local] sha256 ok: payload.zip <hash>
[jb-local] installer sha256: <hash>
```

## 5. 关键参数

| 文件 / 参数 | 作用 | 什么时候要改 |
|---|---|---|
| `payload/config/ca-modulus.txt` | JetBrains 许可证根证书（`CN=JetProfile CA`）的 RSA 模数 | **JetBrains 轮换根证书时**——换掉这一行数字，重新打 release，用户重跑安装器即可 |
| `--expiry` / `-Expiry` | `paidUpTo` / `fallbackDate`，默认 `2099-12-31` | 想换年限 |
| `--product-codes` | 产品码，安装器按产品自动带（`II,PCWMP,PSI` 等） | 新品 |
| `--license-name` / `-LicenseName` | 许可证显示名 | 随意 |
| `-InstallDir` | 安装目录，默认 `C:\ProgramData\jb-local` | 想换位置 |

## 6. 它到底怎么工作（30 秒版）

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

## 7. 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| `Key is invalid` | agent 没加载（检查 `<install>/bin/*.vmoptions` 与 `%APPDATA%\JetBrains\<产品><版本>\*.vmoptions` 里的 `-javaagent` 行）；或 `state/` 与 `power.conf` 不匹配（删 `state/` 重跑）；或 JBR 版本已改 `BigInteger` 实现 |
| IDE 启动报错 / 起不来 | 先 `-SkipHiding` 重装；仍是就删掉 `plugins/privacy.jar`、`plugins/hideme.jar` 再试（激活不依赖它们） |
| 升级 IDE 后失效 | 大版本会重建 `bin` 与 vmoptions，`-javaagent` 被清掉——**重跑安装器**即可，key 通常还在 |
| 提示"需要登录/在线激活" | 该版本已改为在线校验模式，本方案不适用 |
| 找不到产品 | `.home` 指向的目录里没有 `bin`；用 `-LayoutRoot` 指到真正的 `%LOCALAPPDATA%\JetBrains`，或手工把 `-javaagent` 加到对应 vmoptions |
| 两个 agent 打架 | 安装器会删掉所有 `-javaagent:*.jar` 行再加自己的；如仍有旧工具，先跑它的卸载 |

## 8. 安全边界（说清楚）

- **发布资产可被替换**：有仓库写权限的人能重传同一 tag 的资产。对策见第 4 节（tag 保护 + checksums 进 git + 签名）。
- **脚本以管理员运行**：它要改 `%ProgramData%`、`%APPDATA%`、安装目录的 vmoptions；执行前请自己读一遍（全仓库不到 2000 行，无混淆）。
- **agent 拥有 JVM 内全权限**：它能读写 IDE 进程里的源码、凭据、剪贴板。本仓库的版本除安装期下载外不联网，也没有遥测代码，但这是"你信这个仓库"而不是"技术上不可能"。
- **不含任何密钥**：`state/` 里的私钥只在本机生成；发布物只有公开的 CA 模数。

## 9. 第三方组件

`payload/ja-netfilter.jar` 与 `payload/plugins/*.jar` 来自 ja-netfilter 项目及其社区插件，版权归各自作者；本仓库只做打包、安装器、身份/许可证生成与校验逻辑。`src/` 下的代码为本仓库新增。
