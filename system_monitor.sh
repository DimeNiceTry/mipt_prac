#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if [[ $# -ne 1 ]]; then
    printf '%s START|STOP|STATUS\n' "$0" >&2
    exit 2
fi

case "$1" in
    START|STOP|STATUS|--run) ;;
    *)
        printf 'допустимые команды — START, STOP, STATUS.\n' >&2
        exit 2
        ;;
esac

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
script_path="$script_directory/$(basename -- "${BASH_SOURCE[0]}")"
state_directory="$script_directory/.system_monitor"
pid_file="$state_directory/monitor.pid"
log_file="$state_directory/monitor.log"
interval=600

umask 077
mkdir -p -- "$state_directory"

is_running() {
    local saved_start actual_start process_state
    [[ -r "$pid_file" ]] || return 1
    read -r monitor_pid saved_start < "$pid_file" || return 1
    [[ "$monitor_pid" =~ ^[0-9]+$ && "$saved_start" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$monitor_pid" 2>/dev/null || return 1
    read -r process_state actual_start < <(
        awk '{ print $3, $22 }' "/proc/$monitor_pid/stat" 2>/dev/null
    ) || return 1
    [[ "$process_state" != Z && "$actual_start" == "$saved_start" ]]
}

read_cpu() {
    awk '/^cpu / {
        total = 0
        for (i = 2; i <= 9; i++) total += $i
        printf "%.0f %.0f\n", total, $5 + $6
        exit
    }' /proc/stat
}

collect_metrics() {
    local total_before idle_before total_after idle_after cpu_used
    local timestamp report_file memory disk_used load_average

    read -r total_before idle_before < <(read_cpu)
    sleep 1 8>&- &
    sleep_pid=$!
    wait "$sleep_pid"
    sleep_pid=''
    read -r total_after idle_after < <(read_cpu)
    cpu_used=$(awk -v total="$((total_after - total_before))" \
        -v idle="$((idle_after - idle_before))" \
        'BEGIN { printf "%.2f", (total > 0 ? 100 * (total - idle) / total : 0) }')

    memory=$(awk '
        /^MemTotal:/ { total = $2 }
        /^MemFree:/ { free = $2 }
        END {
            if (total <= 0) exit 1
            printf "%.2f;%.2f;%.2f", total / 1024, free / 1024, 100 * (total - free) / total
        }
    ' /proc/meminfo)
    disk_used=$(df -P / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')
    read -r load_average _ < /proc/loadavg
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    report_file="system_report_${timestamp:0:10}.csv"

    if [[ ! -s "$report_file" ]]; then
        printf 'timestamp;all_memory;free_memory;%%memory_used;%%cpu_used;%%disk_used;load_average_1m\n' > "$report_file"
    fi
    printf '%s;%s;%s;%s;%s\n' "$timestamp" "$memory" "$cpu_used" "$disk_used" "$load_average" >> "$report_file"
}

run_monitor() {
    exec 8> "$state_directory/monitor.lock"
    flock -n 8 || exit 1
    sleep_pid=''

    cleanup() {
        if [[ -n "$sleep_pid" ]]; then
            kill "$sleep_pid" 2>/dev/null || true
            wait "$sleep_pid" 2>/dev/null || true
        fi
        rm -f -- "$pid_file"
    }
    trap cleanup EXIT
    trap 'exit 0' TERM INT

    printf '%s %s\n' "$$" "$(awk '{ print $22 }' "/proc/$$/stat")" > "$pid_file"

    local next_run=$SECONDS delay
    while true; do
        collect_metrics
        next_run=$((next_run + interval))
        delay=$((next_run - SECONDS))
        if (( delay > 0 )); then
            sleep "$delay" 8>&- &
            sleep_pid=$!
            wait "$sleep_pid"
            sleep_pid=''
        fi
    done
}

if [[ "$1" == --run ]]; then
    run_monitor
    exit 0
fi

exec 9> "$state_directory/control.lock"
flock -x 9

case "$1" in
    START)
        if is_running; then
            printf 'Монитор уже запущен. PID: %s\n' "$monitor_pid"
            exit 0
        fi
        nohup bash "$script_path" --run 9>&- < /dev/null >> "$log_file" 2>&1 &
        launched_pid=$!
        for (( attempt = 0; attempt < 50; attempt++ )); do
            if is_running; then
                printf 'Монитор запущен. PID: %s\n' "$monitor_pid"
                exit 0
            fi
            if ! kill -0 "$launched_pid" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        printf 'Ошибка запуска. Подробности: %s\n' "$log_file" >&2
        exit 1
        ;;
    STOP)
        if ! is_running; then
            rm -f -- "$pid_file"
            printf 'Монитор не запущен.\n'
            exit 0
        fi
        stopped_pid=$monitor_pid
        kill -TERM "$stopped_pid"
        for (( attempt = 0; attempt < 50; attempt++ )); do
            if ! is_running; then
                printf 'Монитор остановлен. PID: %s\n' "$stopped_pid"
                exit 0
            fi
            sleep 0.1
        done
        printf 'Ошибка: процесс %s не завершился за 5 секунд.\n' "$stopped_pid" >&2
        exit 1
        ;;
    STATUS)
        if is_running; then
            printf 'Монитор запущен. PID: %s\n' "$monitor_pid"
        else
            printf 'Монитор не запущен.\n'
        fi
        ;;
esac
