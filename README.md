# FastZip

macOS 图形化解压工具，基于 p7zip，支持批量解压、密码管理、字典攻击破解。

## 功能

- **批量解压** — 递归扫描目录，多格式（7z / zip / rar / tar / gz / bz2 / xz），3 并发加速
- **密码管理** — macOS Keychain 加密存储，解压时自动尝试已存密码
- **字典破解** — 内置 5 套字典（中文 / 英文 / 数字 / 键盘 / 日期），支持外扩
- **Finder 右键** — 本地目录右键 → 在 FastZip 中打开，拖拽也能导入
- **中文不乱码** — GBK/GB18030 压缩包自动转 UTF-8 文件名
- **进度追踪** — 并发解压时每个文件独立进度条，实时字节级显示

## 安装

1. 安装 Homebrew（如已安装跳过）：
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

2. 安装 p7zip：
```bash
brew install p7zip
```

3. 下载 FastZip.app 拖入 `/Applications/`，首次打开右键 → 打开

## 自定密码字典

字典文件位于 `FastZip.app/Contents/Resources/Dictionaries/`，每行一个密码的 `.txt` 文件。添加新文件后重编译即可在字典下拉菜单中看到。

## 依赖

- macOS 13+
- [p7zip](https://www.7-zip.org/)
- Swift 5.9+

## License

MIT
