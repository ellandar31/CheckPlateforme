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
    printf 'Usage : %s (--localhost | --inventory SERVEURS.csv) [--json RAPPORT.json]\n' "$0"
}
# Appelée dans collect_packages : variables de collecte partagées par portée Bash.
collect_debian_packages() {
    local output='' line status name full epoch version release arch rest tabs
    packages=''; separator=''; count=0; rc=0; error=''; manager=dpkg
    if ! command -v dpkg-query >/dev/null 2>&1; then
        error='Repli APT impossible : dpkg-query absent'; rc=2; return
    fi
    if ! output=$(LC_ALL=C dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Architecture}\n'); then
        error='Échec de lecture de la base dpkg'; rc=2; return
    fi
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        rest=${line//$'\t'/}; tabs=$((${#line}-${#rest}))
        IFS=$'\t' read -r status name full arch <<< "$line"
        if [[ $tabs != 3 || -z $status || -z $name ]]; then
            error='Réponse dpkg invalide ou incomplète'; rc=2; return
        fi
        [[ $status == installed ]] || continue
        if [[ -z $full || -z $arch ]]; then error='Réponse dpkg invalide'; rc=2; return; fi
        epoch=0; version=$full; release=''
        if [[ $version == *:* ]]; then epoch=${version%%:*}; version=${version#*:}; fi
        if [[ $version == *-* ]]; then release=${version##*-}; version=${version%-*}; fi
        if [[ ! $epoch =~ ^[0-9]{1,9}$ || -z $version ]]; then error='Version Debian invalide'; rc=2; return; fi
        packages+="$separator"'{"name":'"$(json_string "$name")"',"epoch":'"$(json_number "$epoch")"',"version":'"$(json_string "$version")"',"release":'"$(json_string "$release")"',"architecture":'"$(json_string "$arch")"',"version_full":'"$(json_string "$full")"',"installed_at_unix":null}'
        separator=','; ((count+=1))
    done <<< "$output"
    if (( ! count )); then error='Inventaire dpkg vide : aucune collecte certifiée'; rc=2; fi
}
collect_packages() {
    local manager=rpm rpm_error='' fallback_used=false
    local output='' packages='' separator='' count=0 rc=0 error=''
    local name epoch version release arch installed extra line tabs rest
    printf '\n=== Paquets RPM : %s ===\n' "${HOSTNAME:-serveur}"
    if ! command -v rpm >/dev/null 2>&1; then
        error='Commande rpm absente : inventaire RHEL impossible'; rc=2
    elif output=$(LC_ALL=C rpm -qa --queryformat '%{NAME}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{INSTALLTIME}\n'); then
        if [[ -z $output ]]; then
            error='Inventaire RPM vide : aucune collecte certifiée'; rc=2
        else
            while IFS= read -r line; do
                # Six champs non vides ; ne pas accepter une réponse tronquée.
                rest=${line//$'\t'/}; tabs=$((${#line}-${#rest}))
                IFS=$'\t' read -r name epoch version release arch installed extra <<< "$line"
                if [[ $tabs != 5 || -z $name || -z $version || -z $release || -z $arch ||
                      ! $epoch =~ ^[0-9]+$ || ! $installed =~ ^[0-9]+$ ]]; then
                    error='Réponse RPM invalide ou incomplète'; rc=2; break
                fi
                packages+="$separator"'{"name":'"$(json_string "$name")"',"epoch":'"$(json_number "$epoch")"',"version":'"$(json_string "$version")"',"release":'"$(json_string "$release")"',"architecture":'"$(json_string "$arch")"',"installed_at_unix":'"$(json_number "$installed")"'}'
                separator=','; ((count+=1))
            done <<< "$output"
        fi
    else
        error='Échec de lecture de la base RPM'; rc=2
    fi
    if ((rc)); then
        rpm_error=$error; fallback_used=true
        printf 'AVERTISSEMENT RPM : %s ; repli vers les paquets APT/dpkg\n' "$rpm_error"
        collect_debian_packages
    fi
    if ((rc)); then
        # Ne pas présenter un inventaire partiel comme complet.
        packages=''; count=0
        printf 'ERREUR %s\n' "$error"
    fi
    printf 'Nombre de paquets : %s\n' "$count"
    {
        printf '{"hostname":'; json_string "${HOSTNAME:-serveur}"
        printf ',"package_manager":'; json_string "$manager"
        printf ',"fallback_used":%s,"rpm_error":' "$fallback_used"
        if [[ -n $rpm_error ]]; then json_string "$rpm_error"; else printf 'null'; fi
        printf ',"package_count":%s,"packages":[%s],"error":' "$count" "$packages"
        if [[ -n $error ]]; then json_string "$error"; else printf 'null'; fi
        printf ',"exit_code":%s}\n' "$rc"
    } >&3
    return "$rc"
}
main() {
    local mode='' inventory='' report='rapport-packages.json' i data rc result=0 entries='' separator='' payload
    local -a hosts=() users=() ports=() options=()
    while (( $# )); do
        case "$1" in
            --localhost) [[ -z $mode ]] || { usage >&2; return 2; }; mode=local; shift ;;
            --inventory) [[ -z $mode && $# -ge 2 && -n $2 ]] || { usage >&2; return 2; }; mode=remote; inventory=$2; shift 2 ;;
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
                data=$(collect_packages 3>&1 1>&2); rc=$? ;;
            *)
                options=(-T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -p "${ports[i]}")
                [[ -z ${users[i]} ]] || options+=(-l "${users[i]}")
                payload="$(declare -f json_string json_number collect_debian_packages collect_packages)"$'\n'
                payload+=$'collect_packages 3>&1 1>&2\n'
                data=$(ssh "${options[@]}" "${hosts[i]}" 'bash -s' <<< "$payload"); rc=$?
                case "$rc" in 0|2) ;; *) data='' ;; esac ;;
        esac
        printf 'BILAN %s : code %s\n' "${hosts[i]}" "$rc"
        entries+="$separator"'{"target":'"$(json_string "${hosts[i]}")"',"exit_code":'"$rc"',"data":'"${data:-null}"'}'
        separator=','
        (( rc == 0 )) || result=2
    done
    if ! printf '{"package_inventory":[%s],"exit_code":%s}\n' "$entries" "$result" > "$report"; then return 2; fi
    printf 'Rapport JSON : %s\n' "$report"
    return "$result"
}
main "$@"
