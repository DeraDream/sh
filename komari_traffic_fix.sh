#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE="komari-agent"

die() {
    echo "错误：$*" >&2
    exit 1
}

prompt_number() {
    local prompt="$1" value
    while true; do
        read -r -p "$prompt" value
        if [[ "$value" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
            printf '%s' "$value"
            return
        fi
        echo "请输入非负数字，例如 169.69。" >&2
    done
}

if [ "$(id -u)" -ne 0 ]; then
    die "请使用 sudo bash $0 运行"
fi

command -v systemctl >/dev/null || die "找不到 systemctl"
command -v python3 >/dev/null || die "找不到 python3"

UNIT_FILE="$(systemctl show "$SERVICE" -p FragmentPath --value 2>/dev/null || true)"
if [ ! -f "$UNIT_FILE" ]; then
    for candidate in \
        "/etc/systemd/system/${SERVICE}.service" \
        "/usr/lib/systemd/system/${SERVICE}.service" \
        "/lib/systemd/system/${SERVICE}.service"; do
        if [ -f "$candidate" ]; then
            UNIT_FILE="$candidate"
            systemctl daemon-reload
            break
        fi
    done
fi

if [ ! -f "$UNIT_FILE" ]; then
    echo "未检测到 Komari Agent，无法修正流量。"
    echo "请先安装 Komari Agent，并确认 systemd 服务名称为 ${SERVICE}.service。"
    echo "可使用以下命令检查：systemctl status ${SERVICE}"
    exit 0
fi

echo "Komari 流量修正工具"
echo
echo "1) 双向计费（入站 + 出站），服务商提供入站和出站明细"
echo "2) 双向计费（入站 + 出站），服务商只提供已使用总量"
echo "3) 单向计费，服务商提供入站和出站明细"
echo "4) 单向计费，服务商只提供已使用总量"
echo

while true; do
    read -r -p "请选择情况 [1-4]: " CASE_NO
    case "$CASE_NO" in 1|2|3|4) break ;; esac
    echo "请输入 1、2、3 或 4。"
done

STAT_MODE="sum"
DATA_TYPE="total"
USED=""
IN=""
OUT=""

case "$CASE_NO" in
    1) DATA_TYPE="directional" ;;
    2) DATA_TYPE="total" ;;
    3|4)
        [ "$CASE_NO" = "3" ] && DATA_TYPE="directional"
        echo
        echo "1) 只计算入站/下载（RX）"
        echo "2) 只计算出站/上传（TX）"
        while true; do
            read -r -p "请选择单向计费方向 [1-2]: " DIRECTION
            case "$DIRECTION" in
                1) STAT_MODE="down"; break ;;
                2) STAT_MODE="up"; break ;;
                *) echo "请输入 1 或 2。" ;;
            esac
        done
        ;;
esac

echo
while true; do
    read -r -p "流量单位 [MB/GB/TB，默认 GB]: " UNIT
    UNIT="${UNIT:-GB}"
    UNIT="${UNIT^^}"
    case "$UNIT" in MB|GB|TB) break ;; esac
    echo "单位只能是 MB、GB 或 TB。"
done

if [ "$DATA_TYPE" = "directional" ]; then
    IN="$(prompt_number "请输入已使用的入站/下载流量 ($UNIT): ")"
    OUT="$(prompt_number "请输入已使用的出站/上传流量 ($UNIT): ")"
else
    USED="$(prompt_number "请输入已使用的流量总和 ($UNIT): ")"
fi

CURRENT_RESET_DAY="$(sed -nE 's/.*--month-rotate(=|[[:space:]])([0-9]+).*/\2/p' "$UNIT_FILE" | tail -n 1)"
CURRENT_RESET_DAY="${CURRENT_RESET_DAY:-1}"
echo
read -r -p "流量重置日 [当前 $CURRENT_RESET_DAY，直接回车保持不变]: " RESET_INPUT
if [ -n "$RESET_INPUT" ]; then
    [[ "$RESET_INPUT" =~ ^[0-9]+$ ]] || die "重置日必须是 1-31 的整数"
    (( RESET_INPUT >= 1 && RESET_INPUT <= 31 )) || die "重置日必须在 1-31 之间"
    RESET_DAY="$RESET_INPUT"
    CHANGE_RESET=1
else
    RESET_DAY="$CURRENT_RESET_DAY"
    CHANGE_RESET=0
fi

echo
echo "即将写入："
case "$STAT_MODE" in
    sum)  echo "  计费方式：入站 + 出站" ;;
    down) echo "  计费方式：仅入站/下载" ;;
    up)   echo "  计费方式：仅出站/上传" ;;
esac
if [ "$DATA_TYPE" = "directional" ]; then
    echo "  入站：$IN $UNIT"
    echo "  出站：$OUT $UNIT"
else
    echo "  已使用总量：$USED $UNIT"
fi
if [ "$CHANGE_RESET" = "1" ]; then
    echo "  重置日：改为每月 $RESET_DAY 日"
else
    echo "  重置日：保持当前设置（按每月 $RESET_DAY 日计算）"
fi
read -r -p "确认执行？[y/N]: " CONFIRM
case "$CONFIRM" in y|Y|yes|YES) ;; *) echo "已取消。"; exit 0 ;; esac

STAMP="$(date +%Y%m%d-%H%M%S)"
cp -a "$UNIT_FILE" "$UNIT_FILE.bak.$STAMP"

if [ "$CHANGE_RESET" = "1" ]; then
    if grep -qE -- '--month-rotate(=|[[:space:]])' "$UNIT_FILE"; then
        sed -i -E "s/--month-rotate(=|[[:space:]])[0-9]+/--month-rotate ${RESET_DAY}/" "$UNIT_FILE"
    else
        sed -i -E "/^[[:space:]]*ExecStart=/ s|[[:space:]]*$| --month-rotate ${RESET_DAY}|" "$UNIT_FILE"
    fi
    systemctl daemon-reload
    systemctl restart "$SERVICE"
    sleep 2
fi

WORKDIR="$(systemctl show "$SERVICE" -p WorkingDirectory --value)"
[ -n "$WORKDIR" ] || WORKDIR="/opt/komari"
FILE="$WORKDIR/net_static.json"
[ -f "$FILE" ] || die "Agent 没有生成 $FILE"

AGENT_STOPPED=0
restart_agent() {
    if [ "$AGENT_STOPPED" = "1" ]; then
        systemctl start "$SERVICE" || true
    fi
}
trap restart_agent EXIT

systemctl stop "$SERVICE"
AGENT_STOPPED=1
BACKUP="$FILE.bak.$STAMP"
cp -a "$FILE" "$BACKUP"

FILE="$FILE" STAT_MODE="$STAT_MODE" DATA_TYPE="$DATA_TYPE" USED="$USED" \
IN="$IN" OUT="$OUT" UNIT="$UNIT" RESET_DAY="$RESET_DAY" python3 <<'PY'
import calendar
import json
import os
import time
from datetime import datetime
from decimal import Decimal, ROUND_HALF_UP

path = os.environ["FILE"]
mode = os.environ["STAT_MODE"]
data_type = os.environ["DATA_TYPE"]
unit = os.environ["UNIT"]
reset_day = int(os.environ["RESET_DAY"])
multipliers = {"MB": 1024**2, "GB": 1024**3, "TB": 1024**4}

def to_bytes(value):
    return int((Decimal(value) * Decimal(multipliers[unit])).to_integral_value(rounding=ROUND_HALF_UP))

now = datetime.now().astimezone()
timezone = now.tzinfo

def actual_reset(year, month):
    last_day = calendar.monthrange(year, month)[1]
    if reset_day <= last_day:
        return datetime(year, month, reset_day, tzinfo=timezone)
    if month == 12:
        return datetime(year + 1, 1, 1, tzinfo=timezone)
    return datetime(year, month + 1, 1, tzinfo=timezone)

this_month_reset = actual_reset(now.year, now.month)
if now >= this_month_reset:
    cycle_start = this_month_reset
else:
    previous_year, previous_month = ((now.year - 1, 12) if now.month == 1 else (now.year, now.month - 1))
    cycle_start = actual_reset(previous_year, previous_month)

start_timestamp = int(cycle_start.timestamp())
now_timestamp = int(time.time())
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

interfaces = data.setdefault("interfaces", {})
nics = data.get("config", {}).get("nics") or list(interfaces)
if not nics:
    raise SystemExit("错误：没有找到 Agent 统计网卡")
target_nic = nics[0]
old_tx = old_rx = 0

for name in nics:
    for record in interfaces.get(name, []):
        timestamp = int(record.get("timestamp", 0))
        if not start_timestamp <= timestamp <= now_timestamp:
            continue
        old_tx += int(record.get("tx", 0))
        old_rx += int(record.get("rx", 0))
        if data_type == "directional" or mode == "sum":
            record["tx"] = record["rx"] = 0
        elif mode == "up":
            record["tx"] = 0
        else:
            record["rx"] = 0

new_tx = new_rx = 0
if data_type == "directional":
    new_tx = to_bytes(os.environ["OUT"])
    new_rx = to_bytes(os.environ["IN"])
else:
    target_used = to_bytes(os.environ["USED"])
    if mode == "down":
        new_rx = target_used
    else:
        new_tx = target_used

interfaces.setdefault(target_nic, []).append({"timestamp": now_timestamp, "tx": new_tx, "rx": new_rx})
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, separators=(",", ":"))

final_used = new_tx if mode == "up" else new_rx if mode == "down" else new_tx + new_rx
print(f"当前周期开始：{cycle_start.isoformat()}")
print(f"修改前上传：{old_tx / 1024**3:.6f} GB")
print(f"修改前下载：{old_rx / 1024**3:.6f} GB")
print(f"修正后上传：{new_tx / 1024**3:.6f} GB")
print(f"修正后下载：{new_rx / 1024**3:.6f} GB")
print(f"修正后计费量：{final_used / 1024**3:.6f} GB")
PY

systemctl start "$SERVICE"
AGENT_STOPPED=0
trap - EXIT

echo
echo "修正完成"
echo "数据备份：$BACKUP"
echo "Agent 状态：$(systemctl is-active "$SERVICE")"
