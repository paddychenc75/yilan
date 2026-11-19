#!/bin/zsh
# 量切换速度：用仓库里的公开样张造一个「RAW 很多」的文件夹，启动一览自动连续切换，打印统计。
#
# 用法：scripts/perf-switch.sh <Yilan.app> [场景] [次数] [间隔毫秒] [每次跳几张]
#   场景：raw（默认，5 个品牌的 RAW 各 40 份，共 200 个）/ mixed（RAW 和 JPEG、HEIC 交替，共 180 个）
#         raf / nef（只放最大的单个文件：56 MB 的 RAF 或 47 MB 的 NEF，各 60 份）
#   例：scripts/perf-switch.sh app/build/release/Build/Products/Release/Yilan.app raw 25 1500 7
#       （每 1.5 秒往后跳 7 张：跳出预加载范围，量“没有预加载到”的单次切换）
#       scripts/perf-switch.sh app/build/release/Build/Products/Release/Yilan.app raw 20 100 1
#       （每 0.1 秒按一次 →，连续 20 次：量连续快速切换）
# 环境变量：
#   SLOW=1           把进程设为后台优先级（只用能效核、磁盘读取降速），模拟慢一些的电脑
#   DECODE_SIZE=3456 固定大图解码尺寸（默认 3456；不随窗口在哪块屏幕变化）
#   DEST=/tmp/yilan-rawperf 素材文件夹放在哪
# 输出里的数字由程序的 --perf-switches 打点给出（见 app/Yilan/App/Perf.swift）：
#   每次切换 = 调用切换 → 新照片（RAW 的内嵌预览或高清版，先到哪个算哪个）贴到大图区；
#   burst = 第一次切换 → 最后一张上屏。只结束这里启动的进程，不碰 /Applications 里的一览。
set -euo pipefail

APP=${1:?用法：scripts/perf-switch.sh <Yilan.app> [raw|mixed] [次数] [间隔毫秒] [每次跳几张]}
APP=${APP:A}
SCENE=${2:-raw}
COUNT=${3:-25}
INTERVAL=${4:-1500}
STEP=${5:-1}
DEST=${DEST:-/tmp/yilan-rawperf}
DECODE_SIZE=${DECODE_SIZE:-3456}
FIX="${0:A:h}/../app/Fixtures"

make_folder() {
  local dir=$1; shift
  [[ -d $dir ]] && return
  mkdir -p "$dir"
  local i=0 n f b
  for (( n = 1; n <= $1; n++ )); do
    for f in "${@:2}"; do
      i=$(( i + 1 )); b=${f:t}
      # APFS 克隆，不占额外空间；名字带序号，排序就是交替的顺序
      cp -c "$f" "$dir/P$(printf %03d $i)_${b:r}.${b:e}" 2>/dev/null || cp "$f" "$dir/P$(printf %03d $i)_${b:r}.${b:e}"
    done
  done
}

raws=("$FIX"/raw/*(N))
(( ${#raws} > 0 )) || { echo "没有找到 $FIX/raw" >&2; exit 1; }
case $SCENE in
  raw) make_folder "$DEST/raw200" 40 "${raws[@]}"; FOLDER="$DEST/raw200" ;;
  mixed) make_folder "$DEST/mixed" 20 "${raws[@]}" "$FIX/sample/aurora.jpg" "$FIX/sample/IMG_2034.jpg" \
           "$FIX/sample/IMG_2052.jpg" "$FIX/sample/IMG_2031.heic"; FOLDER="$DEST/mixed" ;;
  raf) make_folder "$DEST/raf60" 60 "$FIX"/raw/*.RAF; FOLDER="$DEST/raf60" ;;
  nef) make_folder "$DEST/nef60" 60 "$FIX"/raw/*.NEF; FOLDER="$DEST/nef60" ;;
  *) echo "场景只能是 raw、mixed、raf、nef" >&2; exit 1 ;;
esac

FIRST=$(ls "$FOLDER" | head -1)
LOG=$(mktemp -t yilan-perf)
before=$(pgrep -f "$APP/Contents/MacOS/Yilan" || true)
open -n -g -a "$APP" "$FOLDER/$FIRST" --stdout "$LOG" --stderr /dev/null --args \
  --perf-switches=$COUNT --perf-interval=$INTERVAL --perf-step=$STEP --perf-decode-size=$DECODE_SIZE
PID=""
for _ in {1..50}; do
  PID=$(pgrep -nf "$APP/Contents/MacOS/Yilan" || true)
  [[ -n $PID && " ${before//$'\n'/ } " != *" $PID "* ]] && break
  PID=""; sleep 0.1
done
[[ -n $PID ]] || { echo "程序没有启动" >&2; exit 1; }
[[ -n ${SLOW:-} ]] && taskpolicy -b -p $PID
# 等统计打印出来（程序打印后自己退出）；最多 3 分钟。期间记下内存占用（RSS）的最大值
peak=0
for _ in {1..360}; do
  rss=$(ps -o rss= -p $PID 2>/dev/null | tr -d ' ' || true)
  [[ -n $rss ]] && (( rss > peak )) && peak=$rss
  grep -q "\[perf\] burst\|no switch measured" "$LOG" 2>/dev/null && break
  kill -0 $PID 2>/dev/null || break
  sleep 0.5
done
sleep 0.5
kill -0 $PID 2>/dev/null && kill $PID
echo "文件夹：$FOLDER  次数：$COUNT  间隔：${INTERVAL}ms  每次跳：$STEP  解码尺寸：${DECODE_SIZE}px  慢速：${SLOW:-否}"
grep -E "^\[perf\] (switches=|  [a-z0-9]+=|burst|no switch)" "$LOG" || cat "$LOG"
echo "[perf] peak RSS: $(( peak / 1024 )) MB"
rm -f "$LOG"
