#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf '%s <лог-файл> <ключевое_слово>\n' "$0" >&2
    exit 2
fi

log_file=$1
keyword=$2

if [[ ! -f "$log_file" || ! -r "$log_file" ]]; then
    printf 'логфайл не существует или недоступен для чтения: %s\n' "$log_file" >&2
    exit 1
fi
if [[ -z "$keyword" || "$keyword" == *$'\n'* ]]; then
    printf 'ключевое слово должно быть непустой строкой без переноса.\n' >&2
    exit 2
fi

base_name=$(basename -- "$log_file")
matches_file="${base_name}.matches.txt"
count_file="${base_name}.count.txt"

search_status=0
grep -F -- "$keyword" < "$log_file" > "$matches_file" || search_status=$?
if (( search_status > 1 )); then
    printf 'Ошибка  при поиске в лог-файле.\n' >&2
    exit 1
fi

count=$(awk 'END { print NR + 0 }' < "$matches_file")
{
    printf 'Лог-файл: %s\n' "$log_file"
    printf 'Ключевое слово: %s\n' "$keyword"
    printf 'Найдено строк: %s\n' "$count"
} > "$count_file"

printf 'Найдено строк: %s\n' "$count"
printf 'Совпадения: %s\n' "$matches_file"
printf 'Отчёт с количеством: %s\n' "$count_file"
