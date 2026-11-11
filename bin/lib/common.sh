#!/bin/bash
# Fonctions sans effet de bord à l'import : JSON, CSV et lecture de l'inventaire.
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
