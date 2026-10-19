#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    printf '%s <репозиторий> <ветка_1> <ветка_2>\n' "$0" >&2
    exit 2
fi

repository=$1
branch_1=$2
branch_2=$3

if [[ -z "$repository" ]]; then
    printf 'адрес репозитория не должен быть пустым.\n' >&2
    exit 2
fi

for branch in "$branch_1" "$branch_2"; do
    if ! git check-ref-format "refs/heads/$branch"; then
        printf 'некорректное имя ветки: %s\n' "$branch" >&2
        exit 2
    fi
done

temporary_directory=$(mktemp -d)
trap 'rm -rf -- "$temporary_directory"' EXIT

if ! git clone --quiet --bare --no-tags -- "$repository" "$temporary_directory/repository.git"; then
    printf 'не удалось получить репозиторий.\n' >&2
    exit 1
fi

for branch in "$branch_1" "$branch_2"; do
    if ! git --git-dir="$temporary_directory/repository.git" show-ref --verify --quiet "refs/heads/$branch"; then
        printf 'ветка %s не найдена в репозитории.\n' "$branch" >&2
        exit 1
    fi
done

git -c core.quotePath=false --git-dir="$temporary_directory/repository.git" diff \
    --no-ext-diff --no-renames --name-status \
    "refs/heads/$branch_1" "refs/heads/$branch_2" -- > "$temporary_directory/changes.txt"

read -r total added deleted modified other < <(
    awk '
        $1 == "A" { added++ }
        $1 == "D" { deleted++ }
        $1 == "M" { modified++ }
        END { print NR, added+0, deleted+0, modified+0, NR-added-deleted-modified }
    ' "$temporary_directory/changes.txt"
)

safe_branch_1=${branch_1//\//_}
safe_branch_2=${branch_2//\//_}
report_file="diff_report_${safe_branch_1}_vs_${safe_branch_2}.txt"

{
    printf 'Отчёт о различиях между ветками\n\n'
    printf '================================\n'
    printf 'Репозиторий:    %s\n' "$repository"
    printf 'Ветка 1:        %s\n' "$branch_1"
    printf 'Ветка 2:        %s\n' "$branch_2"
    printf 'Дата генерации: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '================================\n\n'
    printf 'СПИСОК ИЗМЕНЁННЫХ ФАЙЛОВ:\n'
    if [[ "$total" -eq 0 ]]; then
        printf 'Различий нет.\n'
    else
        cat -- "$temporary_directory/changes.txt"
    fi
    printf '\nСТАТИСТИКА:\n'
    printf 'Всего изменённых файлов: %s\n' "$total"
    printf 'Добавлено (A):    %s\n' "$added"
    printf 'Удалено (D):      %s\n' "$deleted"
    printf 'Изменено (M):     %s\n' "$modified"
    printf 'Другие изменения: %s\n' "$other"
} > "$report_file"

printf 'Отчёт сохранён: %s\n' "$report_file"
