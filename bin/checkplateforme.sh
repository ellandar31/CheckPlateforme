#!/bin/bash
set -u
usage() {
    printf 'Usage : %s --localhost | --inventory FICHIER\n' "$0"
}
collect() {
    local id='' key value errors=0 failed=0
    printf '\n=== %s ===\n' "${HOSTNAME:-serveur}"
    if [[ -r /etc/os-release ]]; then
        while IFS='=' read -r key value; do
            value=${value#\"}; value=${value%\"}
            case "$key" in
                ID) id=$value ;;
                PRETTY_NAME) printf 'INFO OS : %s\n' "$value" ;;
            esac
        done < /etc/os-release
        if [[ $id == rhel ]]; then
            printf 'OK Distribution RHEL\n'
        else
            printf 'ECART Distribution attendue : RHEL\n'; failed=1
        fi
    else
        printf 'ERREUR /etc/os-release illisible\n'; errors=1
    fi
    printf 'INFO Noyau et architecture\n'
    uname -srmo || errors=1
    local cpu_count=0 cpu_model='' field
    if [[ -r /proc/cpuinfo ]]; then
        while IFS=: read -r key value; do
            # Retirer les espaces autour du nom du champ et devant sa valeur.
            key=${key//[[:space:]]/}
            value=${value#"${value%%[![:space:]]*}"}
            case "$key" in
                processor) ((cpu_count+=1)) ;;
                modelname|Processor|cpu) [[ -n $cpu_model ]] || cpu_model=$value ;;
            esac
        done < /proc/cpuinfo
        if (( cpu_count > 0 )); then
            printf 'INFO CPU : %s processeur(s) logique(s) en ligne\n' "$cpu_count"
        else
            printf 'ERREUR Nombre de CPU indéterminé\n'; errors=1
        fi
        printf 'INFO Modèle CPU : %s\n' "${cpu_model:-non renseigné}"
    else
        printf 'ERREUR /proc/cpuinfo illisible\n'; errors=1
    fi
    local ram_total='' ram_available='' swap_total='' swap_free=''
    if [[ -r /proc/meminfo ]]; then
        while read -r key value unit; do
            case "$key" in
                MemTotal:) ram_total=$value ;;
                MemAvailable:) ram_available=$value ;;
                SwapTotal:) swap_total=$value ;;
                SwapFree:) swap_free=$value ;;
            esac
        done < /proc/meminfo
        for field in ram_total ram_available swap_total swap_free; do
            if [[ ! ${!field} =~ ^[0-9]+$ ]]; then
                printf 'ERREUR Champ mémoire absent ou invalide : %s\n' "$field"
                errors=1
            fi
        done
        if [[ $ram_total =~ ^[0-9]+$ && $ram_available =~ ^[0-9]+$ ]]; then
            printf 'INFO RAM (kio) : totale=%s disponible=%s utilisée (estimée)=%s\n' \
                "$ram_total" "$ram_available" "$((ram_total - ram_available))"
        fi
        if [[ $swap_total =~ ^[0-9]+$ && $swap_free =~ ^[0-9]+$ ]]; then
            printf 'INFO SWAP (kio) : totale=%s libre=%s utilisée=%s\n' \
                "$swap_total" "$swap_free" "$((swap_total - swap_free))"
            (( swap_total > 0 )) || printf 'INFO Aucun swap configuré\n'
        fi
    else
        printf 'ERREUR /proc/meminfo illisible\n'; errors=1
    fi
    printf 'INFO Systèmes de fichiers\n'
    df -Pk || errors=1
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        if ! systemctl is-system-running; then
            printf 'ECART systemd ne signale pas un système running\n'; failed=1
        fi
        systemctl --failed --no-pager --no-legend || errors=1
    else
        printf 'ERREUR systemd indisponible : contrôle non exécuté\n'; errors=1
    fi
    (( errors )) && return 2
    (( failed )) && return 1
    return 0
}
main() {
    local line host user port extra number=0 rc result=0 i payload
    case "${1:-}" in
        --help|-h) usage; return 0 ;;
        --localhost) [[ $# == 1 ]] || { usage >&2; return 2; }; collect; return $? ;;
        --inventory) [[ $# == 2 ]] || { usage >&2; return 2; } ;;
        *) usage >&2; return 2 ;;
    esac
    [[ -f $2 && -r $2 ]] || { printf 'ERREUR Inventaire illisible\n' >&2; return 2; }
    command -v ssh >/dev/null || { printf 'ERREUR Client SSH absent\n' >&2; return 2; }
    local -a hosts=() users=() ports=() options=()
    while IFS= read -r line || [[ -n $line ]]; do
        ((number+=1)); line=${line%%#*}
        read -r host user port extra <<< "$line"
        [[ -n $host ]] || continue
        port=${port:-22}
        if [[ ! $host =~ ^[a-zA-Z0-9][a-zA-Z0-9._:-]*$ || ( -n $user && ! $user =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ) || ! $port =~ ^[0-9]{1,5}$ || -n $extra ]]; then
            printf 'ERREUR Inventaire ligne %s\n' "$number" >&2; return 2
        fi
        if ((10#$port < 1 || 10#$port > 65535)); then
            printf 'ERREUR Port ligne %s\n' "$number" >&2; return 2
        fi
        hosts+=("$host"); users+=("$user"); ports+=("$port")
    done < "$2"
    ((${#hosts[@]})) || { printf 'ERREUR Inventaire vide\n' >&2; return 2; }
    payload="$(declare -f collect)"$'\ncollect\n'
    for ((i=0; i<${#hosts[@]}; i++)); do
        printf '\nCible : %s\n' "${hosts[i]}"
        options=(-T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -p "${ports[i]}")
        [[ -z ${users[i]} ]] || options+=(-l "${users[i]}")
        ssh "${options[@]}" "${hosts[i]}" 'bash -s' <<< "$payload"
        rc=$?
        printf 'BILAN %s : code %s\n' "${hosts[i]}" "$rc"
        case "$rc" in 0) ;; 1) ((result < 1)) && result=1 ;; *) result=2 ;; esac
    done
    return "$result"
}
main "$@"
