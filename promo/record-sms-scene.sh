#!/usr/bin/env bash
# Сцена промо «пришла SMS» → promo/out/sms-scene.mp4 (1206×2622, как iPhone 17 Pro).
#
# 1) Главный экран: SMS от банка 5800, через ~3 с — уведомление Hamyon с суммой и категорией.
# 2) Hamyon раскрывается: сумма месяца прокручивается → «Операции» → новая операция.
#
# Нужен симулятор «Hamyon Promo» (русский, уведомления разрешены UI-тестом testAllowNotifications,
# раннер UI-тестов — на второй странице главного экрана) и собранный
# `xcodebuild build-for-testing ... -derivedDataPath build-sim`. Данные — только демо (-seedExpenses).
set -euo pipefail
cd "$(dirname "$0")/.."

SIM=${SIM:-$(xcrun simctl list devices | grep "Hamyon Promo" | grep -oE '[0-9A-F-]{36}' | head -1)}
OUT=promo/out
mkdir -p "$OUT"
SMS=${SMS:-'Xarid: EVOS, UZ,04.10.26 18:42,karta ***4503. Miqdor:64 000.00 UZS Qoldiq:1 936 000.00 UZS'}
now() { python3 -c 'import time; print(time.time())'; }
calc() { python3 -c "print(max(0, $1))"; }
duration() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
encode() { local out=$1; shift; ffmpeg -v error -y "$@" -c:v libx264 -pix_fmt yuv420p -r 60 "$out"; }

xcrun simctl status_bar "$SIM" override --time 18:42 --batteryState discharging --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 --dataNetwork wifi

# Симулятор пишет кадры только при изменении экрана: видео начинается с первого изменения, а не с команды.
# Поэтому режем не по часам, а по кадрам (promo/first_change.py).
record_start() { xcrun simctl io "$SIM" recordVideo --codec=h264 --force "$1" >/dev/null 2>&1 & rec=$!; sleep 2; }
record_stop() { kill -INT $rec; wait $rec 2>/dev/null || true; }
change() { python3 promo/first_change.py "$@"; }
run_test() {
  xcodebuild test-without-building -project Hamyon.xcodeproj -scheme Hamyon -destination "id=$SIM" \
    -derivedDataPath build-sim -only-testing:"HamyonUITests/PromoTests/$1" 2>&1
}

# --- 0. Чистые демо-данные: каждый прогон снимает одно и то же ------------------------------
# Раннер UI-тестов (ставится в части 2) на главном экране не нужен.
xcrun simctl uninstall "$SIM" uz.fayzullo.hamyon.uitests.xctrunner 2>/dev/null || true
store="$(xcrun simctl get_app_container "$SIM" uz.fayzullo.hamyon group.uz.fayzullo.hamyon)/Library/Application Support/default.store"
xcrun simctl terminate "$SIM" uz.fayzullo.hamyon 2>/dev/null || true
rm -f "$store" "$store-wal" "$store-shm"
xcrun simctl launch "$SIM" uz.fayzullo.hamyon -unlocked -seedExpenses >/dev/null
sleep 5
xcrun simctl terminate "$SIM" uz.fayzullo.hamyon

# --- 1. Главный экран: SMS и уведомление Hamyon -------------------------------------------
# Приложение разбирает SMS тем же путём, что и автоматизация «Команд» (ИИ — несколько секунд),
# а уведомление ставит на заданный момент: к нему приложение уже закрыто, и баннер приходит на главный экран.
notify_at=$(calc "$(now) + 35")
xcrun simctl launch "$SIM" uz.fayzullo.hamyon -unlocked -demoSMS "$SMS" -demoNotifyAt "$notify_at" >/dev/null
for _ in $(seq 1 50); do
  [ "$(sqlite3 "$store" "SELECT COUNT(*) FROM ZEXPENSE WHERE ZRAWTEXT IS NOT NULL" 2>/dev/null || echo 0)" -gt 0 ] && break
  sleep 0.5
done
sleep 1.5  # запрос уведомления успевает дойти до системы
xcrun simctl terminate "$SIM" uz.fayzullo.hamyon
python3 -c "import time; time.sleep(max(0, $notify_at - 6 - time.time()))"
record_start "$OUT/part1-raw.mp4"
python3 -c "import time; time.sleep(max(0, $notify_at - 3 - time.time()))"
cat > "$OUT/sms.apns" <<JSON
{"Simulator Target Bundle":"com.apple.MobileSMS","aps":{"alert":{"title":"5800","body":"$SMS"},"sound":"default"}}
JSON
xcrun simctl push "$SIM" com.apple.MobileSMS "$OUT/sms.apns" >/dev/null
python3 -c "import time; time.sleep(max(0, $notify_at + 7 - time.time()))"
record_stop
# Кадры пишутся, только пока экран меняется: видео кончается сразу после появления уведомления Hamyon.
# Начало — за 1,2 с до SMS (первое изменение в верхней полосе), последний кадр держим 2,5 с — баннер успевают прочитать.
raw1="$OUT/part1-raw.mp4"
sms_t=$(change "$raw1" 0 "$(duration "$raw1")" 0 top)
encode "$OUT/part1.mp4" -ss "$(calc "$sms_t - 1.2")" -i "$raw1" -vf "tpad=stop_mode=clone:stop_duration=2.5"

# Прогрев логотипов магазинов: «Операции» открыты 4 с, картинки ложатся в кэш на диске.
xcrun simctl launch "$SIM" uz.fayzullo.hamyon -unlocked -openOps >/dev/null
sleep 4
xcrun simctl terminate "$SIM" uz.fayzullo.hamyon

# --- 2. Приложение: касания делает UI-тест testSMSScene ------------------------------------
record_start "$OUT/part2-raw.mp4"
log=$(run_test testSMSScene)
record_stop
echo "$log" | grep -q "TEST EXECUTE SUCCEEDED\|TEST SUCCEEDED" || { echo "$log" | tail -20; exit 1; }
raw="$OUT/part2-raw.mp4"
total=$(duration "$raw")
# Приложение: с первого светлого кадра (0,25 с раскрытия до него) → «Операции» (большая смена кадра) → 2 с списка,
# ожидание перед касанием вырезаем → с начала открытия экрана операции и 3 с после.
app=$(change "$raw" 0 "$total" 0.25 bright)
ops=$(change "$raw" "$(calc "$app + 2")" "$total" 0 full 12)
list_end=$(calc "$ops + 2")
sheet=$(change "$raw" "$list_end" "$total" 0.3)
end=$(python3 -c "print(min($total, $sheet + 3.3))")
echo "part2: app=$app ops=$ops sheet=$sheet end=$end" >&2
encode "$OUT/part2.mp4" -i "$raw" -filter_complex \
  "[0:v]trim=$app:$list_end,setpts=PTS-STARTPTS[a];[0:v]trim=$sheet:$end,setpts=PTS-STARTPTS[b];[a][b]concat=n=2:v=1[v]" \
  -map "[v]"

printf "file '%s'\nfile '%s'\n" part1.mp4 part2.mp4 > "$OUT/list.txt"
ffmpeg -v error -y -f concat -safe 0 -i "$OUT/list.txt" -c copy "$OUT/sms-scene.mp4"
[ -n "${KEEP_RAW:-}" ] || rm -f "$OUT/part1-raw.mp4" "$OUT/part2-raw.mp4"
rm -f "$OUT/list.txt" "$OUT/sms.apns"
echo "→ $OUT/sms-scene.mp4 ($(duration "$OUT/sms-scene.mp4") с)"
