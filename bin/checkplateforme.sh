#!/bin/bash
set -u
usage() {
    printf 'Usage : %s (--localhost | --inventory FICHIER) [--json RAPPORT.json]\n' "$0"
}
# Encode une chaîne JSON sans dépendre de Python ou jq.
json_string() {
    local LC_ALL=C text=$1 char i code
    printf '"'
    for ((i=0; i<${#text}; i++)); do
        char=${text:i:1}
        case "$char" in
            '"') printf '\\"' ;;
            \\) printf '\\\\' ;;
            *) printf -v code '%d' "'$char"
               if (( code < 32 )); then printf '\\u%04x' "$code"; else printf '%s' "$char"; fi ;;
        esac
    done
    printf '"'
}
json_number() {
    if [[ $1 =~ ^[0-9]+$ ]]; then printf '%d' "$((10#$1))"; else printf 'null'; fi
}
# Convertit la sortie POSIX de df (blocs de 1 kio) en objets JSON.
filesystems_json() {
    local line first=1 separator='' invalid=0
    local pattern='^(.+[^[:space:]])[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)%[[:space:]]+(.+)$'
    printf '['
    while IFS= read -r line; do
        if (( first )); then first=0; continue; fi
        [[ -n $line ]] || continue
        if [[ $line =~ $pattern ]]; then
            # Sauvegarder les captures avant tout appel modifiant BASH_REMATCH.
            local device=${BASH_REMATCH[1]} size=${BASH_REMATCH[2]}
            local used=${BASH_REMATCH[3]} available=${BASH_REMATCH[4]}
            local percent=${BASH_REMATCH[5]} mountpoint=${BASH_REMATCH[6]}
            printf '%s{"device":' "$separator"; json_string "$device"
            printf ',"mountpoint":'; json_string "$mountpoint"
            printf ',"size_kib":'; json_number "$size"
            printf ',"used_kib":'; json_number "$used"
            printf ',"available_kib":'; json_number "$available"
            printf ',"use_percent":'; json_number "$percent"
            printf '}'
            separator=','
        else
            printf 'ERREUR Ligne filesystem non interprétable : %s\n' "$line" >&2
            invalid=1
        fi
    done <<< "$1"
    printf ']'
    return "$invalid"
}
collect() {
    local id='' key value errors=0 failed=0 kernel='' disks='' filesystems='[]' system_state='' failed_units='' rc=0
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
    kernel=$(uname -srmo) || errors=1
    printf '%s\n' "$kernel"
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
    disks=$(LC_ALL=C df -Pk) || errors=1
    printf '%s\n' "$disks"
    filesystems=$(filesystems_json "$disks") || errors=1
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        system_state=$(systemctl is-system-running)
        rc=$?
        printf '%s\n' "$system_state"
        if (( rc != 0 )); then
            printf 'ECART systemd ne signale pas un système running\n'; failed=1
        fi
        failed_units=$(systemctl --failed --no-pager --no-legend) || errors=1
        printf '%s\n' "$failed_units"
    else
        printf 'ERREUR systemd indisponible : contrôle non exécuté\n'; errors=1
    fi
    rc=0
    (( failed )) && rc=1
    (( errors )) && rc=2
    # Le descripteur 3 transporte uniquement les données JSON, y compris via SSH.
    {
        printf '{"hostname":'; json_string "${HOSTNAME:-serveur}"
        printf ',"distribution":'; json_string "$id"
        printf ',"kernel":'; json_string "$kernel"
        printf ',"cpu":{"logical_count":'; json_number "$cpu_count"
        printf ',"model":'; json_string "$cpu_model"
        printf '},"ram_kib":{"total":'; json_number "$ram_total"
        printf ',"available":'; json_number "$ram_available"
        printf ',"used_estimated":'
        if [[ $ram_total =~ ^[0-9]+$ && $ram_available =~ ^[0-9]+$ ]]; then
            printf '%s' "$((ram_total - ram_available))"
        else printf 'null'; fi
        printf '},"swap_kib":{"total":'; json_number "$swap_total"
        printf ',"free":'; json_number "$swap_free"
        printf ',"used":'
        if [[ $swap_total =~ ^[0-9]+$ && $swap_free =~ ^[0-9]+$ ]]; then
            printf '%s' "$((swap_total - swap_free))"
        else printf 'null'; fi
        printf '},"filesystems":%s' "$filesystems"
        printf ',"systemd":{"state":'; json_string "$system_state"
        printf ',"failed_units_text":'; json_string "$failed_units"
        printf '},"exit_code":%s}\n' "$rc"
    } >&3
    return "$rc"
}
# CSV à trois colonnes, champs nus ou entre guillemets ; une ligne par cible.
parse_csv_line() {
    csv_fields=()
    local text=$1 field='' state=start char next i
    for ((i=0; i<${#text}; i++)); do
        char=${text:i:1}
        case "$state" in
            start)
                case "$char" in
                    ' '|$'\t') ;;
                    '"') state=quoted ;;
                    ',') csv_fields+=(""); field='' ;;
                    *) field=$char; state=bare ;;
                esac ;;
            bare)
                case "$char" in
                    '"') return 1 ;;
                    ',') field=${field%"${field##*[![:space:]]}"}; csv_fields+=("$field"); field=''; state=start ;;
                    *) field+=$char ;;
                esac ;;
            quoted)
                if [[ $char == '"' ]]; then
                    next=${text:i+1:1}
                    if [[ $next == '"' ]]; then field+='"'; ((i+=1)); else state=closed; fi
                else field+=$char; fi ;;
            closed)
                case "$char" in
                    ' '|$'\t') ;;
                    ',') csv_fields+=("$field"); field=''; state=start ;;
                    *) return 1 ;;
                esac ;;
        esac
    done
    [[ $state != quoted ]] || return 1
    [[ $state != bare ]] || field=${field%"${field##*[![:space:]]}"}
    csv_fields+=("$field")
    [[ ${#csv_fields[@]} == 3 ]]
}
main() {
    local line host user port number=0 rc result=0 i payload
    local report='rapport.json' mode='' inventory='' data='' entries='' separator=''
    while (( $# )); do
        case "$1" in
            --localhost) [[ -z $mode ]] || { usage >&2; return 2; }; mode=local; shift ;;
            --inventory) [[ -z $mode && $# -ge 2 ]] || { usage >&2; return 2; }; mode=remote; inventory=$2; shift 2 ;;
            --json) [[ $# -ge 2 && -n $2 ]] || { usage >&2; return 2; }; report=$2; shift 2 ;;
            -h|--help) usage; return 0 ;;
            *) usage >&2; return 2 ;;
        esac
    done
    [[ -n $mode ]] || { usage >&2; return 2; }
    if [[ $mode == local ]]; then
    # Ne jamais écraser un fichier existant (inventaire ou code compris).
    if ! (set -o noclobber; : > "$report") 2>/dev/null; then
        printf 'ERREUR Rapport déjà existant ou chemin inaccessible : %s\n' "$report" >&2
        return 2
    fi
        data=$(collect 3>&1 1>&2)
        rc=$?
        if ! printf '{"servers":[{"target":"localhost","exit_code":%s,"data":%s}],"exit_code":%s}\n' "$rc" "${data:-null}" "$rc" > "$report"; then return 2; fi
        printf 'Rapport JSON : %s\n' "$report"
        return "$rc"
    fi
    set -- --inventory "$inventory"
    [[ -f $2 && -r $2 ]] || { printf 'ERREUR Inventaire illisible\n' >&2; return 2; }
    local -a hosts=() users=() ports=() options=() csv_fields=()
    local first_record=1
    while IFS= read -r line || [[ -n $line ]]; do
        ((number+=1))
        line=${line%$'\r'}
        (( number != 1 )) || line=${line#$'\xef\xbb\xbf'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        if ! parse_csv_line "$line"; then
            printf 'ERREUR CSV ligne %s : trois colonnes attendues (host,user,port)\n' "$number" >&2
            return 2
        fi
        host=${csv_fields[0]}; user=${csv_fields[1]}; port=${csv_fields[2]}
        if (( first_record )) && [[ $host == host && $user == user && $port == port ]]; then
            first_record=0; continue
        fi
        first_record=0
        port=${port:-22}
        if [[ ( $host != ::1 && ! $host =~ ^[a-zA-Z0-9][a-zA-Z0-9._:-]*$ ) || ( -n $user && ! $user =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ) || ! $port =~ ^[0-9]{1,5}$ ]]; then
            printf 'ERREUR Inventaire ligne %s\n' "$number" >&2; return 2
        fi
        if ((10#$port < 1 || 10#$port > 65535)); then
            printf 'ERREUR Port ligne %s\n' "$number" >&2; return 2
        fi
        hosts+=("$host"); users+=("$user"); ports+=("$port")
    done < "$2"
    ((${#hosts[@]})) || { printf 'ERREUR Inventaire vide\n' >&2; return 2; }
    # Ne jamais écraser un fichier existant (inventaire ou code compris).
    if ! (set -o noclobber; : > "$report") 2>/dev/null; then
        printf 'ERREUR Rapport déjà existant ou chemin inaccessible : %s\n' "$report" >&2
        return 2
    fi
    payload="$(declare -f json_string json_number filesystems_json collect)"$'\ncollect 3>&1 1>&2\n'
    for ((i=0; i<${#hosts[@]}; i++)); do
        printf '\nCible : %s\n' "${hosts[i]}"
        options=(-T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -p "${ports[i]}")
        [[ -z ${users[i]} ]] || options+=(-l "${users[i]}")
        case "${hosts[i]}" in
            localhost|127.0.0.1|::1)
                printf 'INFO Contrôle local sans SSH (utilisateur et port ignorés)\n'
                data=$(collect 3>&1 1>&2)
                rc=$?
                ;;
            *)
                data=$(ssh "${options[@]}" "${hosts[i]}" 'bash -s' <<< "$payload")
                rc=$?
                ;;
        esac
        printf 'BILAN %s : code %s\n' "${hosts[i]}" "$rc"
        # Une rupture SSH peut laisser une réponse partielle : ne pas la conserver.
        case "$rc" in 0|1|2) ;; *) data='' ;; esac
        entries+="$separator"'{"target":'"$(json_string "${hosts[i]}")"',"exit_code":'"$rc"',"data":'"${data:-null}"'}'
        separator=','

        case "$rc" in 0) ;; 1) ((result < 1)) && result=1 ;; *) result=2 ;; esac
    done
    if ! printf '{"servers":[%s],"exit_code":%s}\n' "$entries" "$result" > "$report"; then return 2; fi
    printf 'Rapport JSON : %s\n' "$report"
    return "$result"
}
main "$@"
