#!/bin/bash
# 跑全部单元测试（在 app/ 里执行 xcodebuild test）。
# 先把 app/Fixtures 镜像到 /tmp（RAW 用 APFS 克隆，不占空间），评星写入测试从镜像读：
# 测试宿主每次重新编译后第一次访问“桌面”下的文件，系统可能要等授权，会让测试卡住几十秒，甚至一直不退出；
# 所以镜像和构建产物都放在 /tmp。
# 用法：scripts/run-tests.sh [额外的 xcodebuild 参数，例如 -only-testing:YilanTests/SidecarTests]
set -e
cd "$(dirname "$0")/../app"
# 同一时间只跑一份：两份同时跑会互相删掉 /tmp 里的镜像、共用 build/test 和同一个测试宿主，
# 结果是测试随机失败，或者测试宿主挂住不退出。后来的一份在这里等（最多 20 分钟）
LOCK=/tmp/yilan-run-tests.lock
for i in $(seq 1 1200); do
  if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; break; fi
  owner=$(cat "$LOCK/pid" 2>/dev/null || true)
  # 持有者已经不在了（被强行结束）：接手
  if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then echo $$ > "$LOCK/pid"; break; fi
  [ "$i" = 1 ] && echo "另一份测试（pid $owner）正在跑，等它结束…" >&2
  sleep 1
done
[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] || { echo "等不到另一份测试结束，放弃" >&2; exit 1; }
trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true' EXIT
M=/tmp/yilan-fixtures-mirror
# 构建产物放在 /tmp，不放在仓库（桌面）下：测试里一旦出现运行时问题（runtime issue），XCTest 会去读构建产物里的
# 调试信息来标出代码位置；测试宿主没有「桌面」文件夹的访问授权，这一读会一直等授权，测试全部通过后宿主也不退出
DERIVED=${YILAN_TEST_DERIVED:-/tmp/yilan-test-build}
rm -rf "$M"; mkdir -p "$M"
cp -R Fixtures/sample "$M/sample"
if [ -d Fixtures/raw ]; then mkdir -p "$M/raw"; cp -c Fixtures/raw/* "$M/raw/" 2>/dev/null || true; fi
mkdir -p "$M/resources"; cp Yilan/Resources/*.xcstrings "$M/resources/"
mkdir -p "$M/docs/docs" "$M/docs/dist"; cp ../docs/release-notes-template.md "$M/docs/docs/"; cp ../dist/RELEASE_NOTES.md "$M/docs/dist/"
TEST_RUNNER_YILAN_DOCS_DIR="$M/docs" TEST_RUNNER_YILAN_RESOURCES_DIR="$M/resources" TEST_RUNNER_YILAN_FIXTURES_DIR="$M" xcodebuild -project Yilan.xcodeproj -scheme Yilan -destination 'platform=macOS' -derivedDataPath "$DERIVED" test "$@" &
XC=$!
# 被 timeout、Ctrl-C 结束时连同 xcodebuild 一起结束，不留下没人管的 xcodebuild 和测试宿主
trap 'kill $XC 2>/dev/null; wait $XC 2>/dev/null; exit 143' TERM INT
wait $XC
