#!/bin/bash
# 跑全部单元测试（在 app/ 里执行 xcodebuild test）。
# 先把 app/Fixtures 镜像到 /tmp（RAW 用 APFS 克隆，不占空间），评星写入测试从镜像读：
# 测试宿主每次重新编译后第一次访问“桌面”下的文件，系统可能要等授权，会让测试卡住几十秒。
# 用法：scripts/run-tests.sh [额外的 xcodebuild 参数，例如 -only-testing:YilanTests/SidecarTests]
set -e
cd "$(dirname "$0")/../app"
M=/tmp/yilan-fixtures-mirror
rm -rf "$M"; mkdir -p "$M"
cp -R Fixtures/sample "$M/sample"
if [ -d Fixtures/raw ]; then mkdir -p "$M/raw"; cp -c Fixtures/raw/* "$M/raw/" 2>/dev/null || true; fi
mkdir -p "$M/resources"; cp Yilan/Resources/*.xcstrings "$M/resources/"
mkdir -p "$M/docs/changes" "$M/docs/dist"; cp ../changes/release-notes-template.md "$M/docs/changes/"; cp ../dist/RELEASE_NOTES.md "$M/docs/dist/"
TEST_RUNNER_YILAN_DOCS_DIR="$M/docs" TEST_RUNNER_YILAN_RESOURCES_DIR="$M/resources" TEST_RUNNER_YILAN_FIXTURES_DIR="$M" xcodebuild -project Yilan.xcodeproj -scheme Yilan -destination 'platform=macOS' -derivedDataPath build/test test "$@"
