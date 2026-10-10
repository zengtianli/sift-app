# Sift · 速寻

[English](README_EN.md)

原生 macOS 文件名搜索工具，使用 AppKit 界面和基于 [Cardinal](https://github.com/cardisoft/cardinal) 的 Rust 索引内核。窗口与 `sift` 命令行共用索引、查询语法、排序和配置。

输入即搜；支持文件夹范围、大小写、名称、大小与日期筛选，以及键盘导航、Quick Look、在 Finder 中显示和移到废纸篓。索引根据文件系统事件增量更新；发生事件缺口时保留可用索引并显示重建状态。

## 安装

需要 Apple Silicon Mac 和 macOS 14 或更新版本。[下载正式 ZIP](https://github.com/zengtianli/sift-app/releases/download/v0.1.1/Sift-0.1.1-arm64.zip)；正式包已使用 Developer ID 签名，并完成 Apple 公证和装订。新版与校验文件以 [Releases](https://github.com/zengtianli/sift-app/releases) 的实际附件为准。

下载 ZIP 后解压，将 `Sift.app` 放入「应用程序」。需要搜索受保护目录时，请本人在「系统设置 → 隐私与安全性 → 完全磁盘访问」中授权 Sift。

命令行在 App 内，可自行建立软链：

```sh
mkdir -p "$HOME/.local/bin"
ln -s /Applications/Sift.app/Contents/Resources/bin/sift "$HOME/.local/bin/sift"
sift --help
sift search readme --limit 20 --json
```

## 从源码构建

安装 Xcode Command Line Tools 和 [rustup](https://rustup.rs/)，从仓库根目录运行：

```sh
git clone https://github.com/zengtianli/sift-app.git
cd sift-app
bash build.sh
cd core
cargo test --locked -j 12
```

Rust 工具链由 `core/rust-toolchain.toml` 指定；所需 Cardinal 分支源码随仓库提供，无须访问作者的本地目录。构建产物是 `build/Sift.app`，默认使用 ad-hoc 签名，仅供本机开发。发行者可通过 `CODESIGN_IDENTITY` 指定自己的 Developer ID 身份，并在公开分发前完成 Apple 公证和装订。

## 数据与更新

文件名索引和索引配置保存在本机应用支持目录；最近搜索保存在本机偏好设置。全文内容不进入索引。全局快捷键由本人选择，默认不占用按键。可迁移设置支持导入、导出和可选的 iCloud 同步。

公开快照使用独立的 `Sift` 云端目录命名空间，不包含作者的更新目录、索引、最近搜索、真实文件列表、截图或内部记录。目前保留本地 iCloud 更新机制，公开 GitHub 自动更新渠道尚未接入；新版以 Releases 为准。

## 许可证

Sift 原创代码采用 [MIT](LICENSE)。Cardinal 的 MIT 许可保留在 `third_party/cardinal/LICENSE`；依赖说明见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
