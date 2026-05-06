#!/bin/bash
# FastZip 依赖安装脚本
# 安装 p7zip，使 SwiftUI 应用能调用 7z 命令

set -e

echo "=== FastZip 依赖检查与安装 ==="
echo ""

# 检查 Homebrew
if ! command -v brew &> /dev/null; then
    echo "❌ 未找到 Homebrew。"
    echo "请先安装 Homebrew："
    echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    exit 1
fi
echo "✅ Homebrew 已安装"

# 检查 7z
if command -v 7z &> /dev/null; then
    echo "✅ p7zip 已安装 (版本: $(7z | head -2 | tail -1))"
    exit 0
fi

# 安装 p7zip
echo ""
echo "正在安装 p7zip..."
brew install p7zip

echo ""
echo "✅ p7zip 安装完成！"
echo "现在可以在 Xcode 中打开 FastZip 项目并运行了。"
echo ""
echo "打开项目："
echo "  open \(dirname "$0")/Package.swift"
