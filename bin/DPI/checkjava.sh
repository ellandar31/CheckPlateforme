#!/bin/bash
set -u
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
# CSV séparé par des points-virgules, à nombre de colonnes attendu, champs nus ou entre guillemets ; une ligne par cible.
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
                    ';') csv_fields+=(""); field='' ;;
                    *) field=$char; state=bare ;;
                esac ;;
            bare)
                case "$char" in
                    '"') return 1 ;;
                    ';') field=${field%"${field##*[![:space:]]}"}; csv_fields+=("$field"); field=''; state=start ;;
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
                    ';') csv_fields+=("$field"); field=''; state=start ;;
                    *) return 1 ;;
                esac ;;
        esac
    done
    [[ $state != quoted ]] || return 1
    [[ $state != bare ]] || field=${field%"${field##*[![:space:]]}"}
    csv_fields+=("$field")
    [[ ${#csv_fields[@]} == ${2:-3} ]]
}
load_inventory() {
    local inventory=$1 line host user port number=0
    local -a csv_fields=()
    [[ -f $inventory && -r $inventory ]] || { printf 'ERREUR Inventaire illisible\n' >&2; return 2; }
    local first_record=1
    while IFS= read -r line || [[ -n $line ]]; do
        ((number+=1))
        line=${line%$'\r'}
        (( number != 1 )) || line=${line#$'\xef\xbb\xbf'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        if ! parse_csv_line "$line"; then
            printf 'ERREUR CSV ligne %s : trois colonnes attendues (host;user;port)\n' "$number" >&2
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
    done < "$inventory"
    ((${#hosts[@]})) || { printf 'ERREUR Inventaire vide\n' >&2; return 2; }
}
usage() {
    printf 'Usage : %s (--localhost | --inventory SERVEURS.csv) [--json RAPPORT.json] [--include-command-line]\n' "$0"
}
collect_java() {
    local include_args=${1:-0} proc_root=${2:-/proc}
    local directory pid name parent uid state rss threads key value rest executable username arg
    local collected_at
    collected_at=$(TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T' -1)
    local processes='' separator='' count=0 unreadable=0 vanished=0 rc=0 error='' args args_separator
    local -A users_by_uid=()
    printf '\n=== Processus Java : %s ===\n' "${HOSTNAME:-serveur}"
    if [[ ! -d $proc_root/self ]]; then
        error='/proc indisponible : collecte impossible'; rc=2
    else
        for directory in "$proc_root"/[0-9]*; do
            [[ -d $directory ]] || continue
            pid=${directory##*/}; [[ $pid =~ ^[0-9]+$ ]] || continue
            name=''; parent=''; uid=''; state=''; rss=''; threads=''
            if ! {
                while read -r key value rest; do
                    case "$key" in
                        Name:) name="$value${rest:+ $rest}" ;;
                        PPid:) parent=$value ;;
                        Uid:) uid=$value ;;
                        State:) state=$value ;;
                        VmRSS:) rss=$value ;;
                        Threads:) threads=$value ;;
                    esac
                done < "$directory/status"
            } 2>/dev/null; then
                if [[ -d $directory ]]; then ((unreadable+=1)); else ((vanished+=1)); fi
                continue
            fi
            executable=''
            if command -v readlink >/dev/null 2>&1; then
                executable=$(readlink -- "$directory/exe" 2>/dev/null) || executable=''
            fi
            # Name est tronqué par Linux ; l'exécutable confirme les JVM java renommées via prctl.
            case "${executable% (deleted)}" in */java|*/java.bin) ;; *) [[ $name == java || $name == java.bin ]] || continue ;; esac
            if [[ ! $parent =~ ^[0-9]+$ || ! $uid =~ ^[0-9]+$ || ! $threads =~ ^[0-9]+$ || -z $state ]]; then
                if [[ -d $directory ]]; then ((unreadable+=1)); else ((vanished+=1)); fi
                continue
            fi
            username=''
            if [[ ${users_by_uid[$uid]+known} ]]; then
                username=${users_by_uid[$uid]}
            elif command -v getent >/dev/null 2>&1; then
                username=$(getent passwd "$uid" 2>/dev/null) || username=''
                username=${username%%:*}; users_by_uid[$uid]=$username
            fi
            args=null
            if (( include_args )); then
                args='['; args_separator=''
                if ! {
                    while IFS= read -r -d '' arg; do
                        args+="$args_separator$(json_string "$arg")"; args_separator=','
                    done < "$directory/cmdline"
                } 2>/dev/null; then
                    args=null; ((unreadable+=1))
                else args+=']'; fi
            fi
            processes+="$separator"'{"pid":'"$(json_number "$pid")"',"ppid":'"$(json_number "$parent")"',"uid":'"$(json_number "$uid")"',"user":'"$(json_string "$username")"',"name":'"$(json_string "$name")"',"state":'"$(json_string "$state")"',"rss_kib":'"$(json_number "$rss")"',"threads":'"$(json_number "$threads")"',"executable":'"$(json_string "$executable")"',"arguments":'"$args"'}'
            separator=','; ((count+=1))
            printf 'PID=%s PPID=%s UID=%s utilisateur=%s état=%s RAM=%s kio threads=%s\n' "$pid" "$parent" "$uid" "${username:-inconnu}" "$state" "${rss:-inconnue}" "$threads"
            printf 'Exécutable : %s\n' "${executable:-non accessible}"
            if ((include_args)); then printf 'Arguments JSON : %s\n' "$args"; fi
        done
        if ((unreadable)); then
            error='Collecte partielle : certains processus ou arguments sont illisibles'; rc=2
        fi
    fi
    [[ -z $error ]] || printf 'ERREUR %s\n' "$error"
    printf 'Processus Java détectés : %s ; entrées illisibles : %s ; disparus pendant la collecte : %s\n' "$count" "$unreadable" "$vanished"
    {
        printf '{"hostname":'; json_string "${HOSTNAME:-serveur}"
        printf ',"collected_at_utc":'; json_string "$collected_at"
        printf ',"scope":"visible_processes","process_count":%s,"processes":[%s],"unreadable_count":%s,"vanished_count":%s,"error":' "$count" "$processes" "$unreadable" "$vanished"
        if [[ -n $error ]]; then json_string "$error"; else printf 'null'; fi
        printf ',"exit_code":%s}\n' "$rc"
    } >&3
    return "$rc"
}
main() {
    local include_command_line=0
    local mode='' inventory='' report='rapport-java.json' i data rc result=0 entries='' separator='' payload
    local -a hosts=() users=() ports=() options=()
    while (( $# )); do
        case "$1" in
            --localhost) [[ -z $mode ]] || { usage >&2; return 2; }; mode=local; shift ;;
            --inventory) [[ -z $mode && $# -ge 2 && -n $2 ]] || { usage >&2; return 2; }; mode=remote; inventory=$2; shift 2 ;;
            --include-command-line) include_command_line=1; shift ;;
            --json) [[ $# -ge 2 && -n $2 ]] || { usage >&2; return 2; }; report=$2; shift 2 ;;
            -h|--help) usage; return 0 ;;
            *) usage >&2; return 2 ;;
        esac
    done
    [[ -n $mode ]] || { usage >&2; return 2; }
    if [[ $mode == local ]]; then
        hosts=(localhost); users=(''); ports=(22)
    else
        load_inventory "$inventory" || return 2
    fi
    if ! (set -o noclobber; : > "$report") 2>/dev/null; then
        printf 'ERREUR Rapport déjà existant ou chemin inaccessible : %s\n' "$report" >&2; return 2
    fi
    for ((i=0; i<${#hosts[@]}; i++)); do
        printf '\nCible : %s\n' "${hosts[i]}"
        case "${hosts[i]}" in
            localhost|127.0.0.1|::1)
                data=$(collect_java "$include_command_line" 3>&1 1>&2); rc=$? ;;
            *)
                options=(-T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -p "${ports[i]}")
                [[ -z ${users[i]} ]] || options+=(-l "${users[i]}")
                payload="$(declare -f json_string json_number collect_java)"$'\n'
                printf -v payload '%scollect_java %q 3>&1 1>&2\n' "$payload" "$include_command_line"
                data=$(ssh "${options[@]}" "${hosts[i]}" 'bash -s' <<< "$payload"); rc=$?
                case "$rc" in 0|2) ;; *) data='' ;; esac ;;
        esac
        printf 'BILAN %s : code %s\n' "${hosts[i]}" "$rc"
        entries+="$separator"'{"target":'"$(json_string "${hosts[i]}")"',"exit_code":'"$rc"',"data":'"${data:-null}"'}'
        separator=','
        (( rc == 0 )) || result=2
    done
    if ! printf '{"java_inventory":[%s],"exit_code":%s}\n' "$entries" "$result" > "$report"; then return 2; fi
    printf 'Rapport JSON : %s\n' "$report"
    return "$result"
}
main "$@"
