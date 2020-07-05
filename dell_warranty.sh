#!/bin/bash


# functions
err() {
    if [[ "$*" != "" ]]; then
        [[ $json == 1 ]] && jo error="$*" || echo "Error: $*"
    fi
    exit 1
}

usage() {
    local s=${0##*/}
    cat << EOU
Usage:  $s [-j] [-e] <service_tag>

        -j  output data is serialized as a JSON object
        -e  only display the warranty expiration date

EOU
    err
}

exp_only=0 json=0 debug=0
optspec=":hdje"
while getopts "$optspec" optchar; do
    case "${optchar}" in
        h)  usage >&2
            ;;
        e)  exp_only=1
            ;;
        j)  json=1
            ;;
        d)  debug=1
            ;;
        *)  usage >&2
            ;;
    esac
done
shift $((OPTIND-1))
svctag=${1:-}

# sanity checks
type http &> /dev/null || err "HTTPie not found (https://httpie.org)"
type pup  &> /dev/null || err "pup not found (https://github.com/ericchiang/pup)"
type jo   &> /dev/null || err "jo not found (https://github.com/jpmens/jo)"

[[ "$svctag" == '' ]] && err "missing service tag"
[[ "$svctag" =~ [A-Z0-9]{7} ]] || err "invalid service tag ($svctag)"


# set default HTTPie options
http="http --check-status --follow --timeout=5"

# URLs
url_root="https://www.dell.com/support"
url_comp="$url_root/components/dashboard/en-us"
url_w_inf="$url_comp/Warranty/GetInlineWarranty"
url_w_det="$url_comp/Warranty/GetWarrantyDetails"
url_c_det="$url_comp/Configuration/GetConfiguration"
url_overview="$url_root/home/us/en/04/product-support/servicetag"


# get general info
overview=$($http "$url_overview/$svctag" Accept-Language:en-US,en) || err

# check for invalid service tag
o_link=$(pup 'link[rel="canonical"] attr{href}' <<< "$overview")
# shellcheck disable=SC2076
[[ "$o_link" =~ "Selection=$svctag&amp;IsInvalidSelection=True" ]] && \
    err "service tag not found ($svctag)"

# retrieve parameters from overview
s_encryp=$(awk '/var encryptedTag/ {print $NF}'   <<< "$overview" | tr -d "';")
w_qparam=$(awk '/var warrantyQparam/ {print $NF}' <<< "$overview" | tr -d "';")

for k in s_encryp w_qparam; do
    [[ ${!k} == "" ]] && err "$k not found"
done


# get warranty info
w_info=$(echo -n "warrantyEncryptedParams=$w_qparam" | \
    $http "$url_w_inf" Content-Type:application/x-www-form-urlencoded) || err
w_details=$(echo -n "servicetag=$s_encryp" | \
    $http "$url_w_det" Content-Type:application/x-www-form-urlencoded) || err

# get configuration details
c_details=$(http "$url_c_det?serviceTag=$s_encryp") || err

## debug save output
[[ $debug == 1 ]] && {
    echo "$overview" > "overview_$svctag.html"
    echo "$w_info" > "w_info_$svctag.html"
    echo "$w_details" > "w_details_$svctag.html"
    echo "$c_details" > "c_details_$svctag.html"
}

# extract nuggets
c_prod=$(pup '.product-info h1 text{}' <<< "$overview")
w_rexp=$(pup '#warrantyExpiringLabel text{}' <<< "$w_info" | \
         sed 's/^Expire[sd] \+//')
w_expdate=$(date +%s --date="$w_rexp") # epoch

w_stat=$(awk '/var warrantystatus/ {print $NF}'  <<< "$w_info" | tr -d "';")
w_type=$(pup 'p:parent-of(#inline-warrantytext) text{}' <<< "$w_info" | \
    xargs | awk -F: '{gsub(/[^[:alnum:]]/,"",$2); print $2}')
w_rshp=$(pup ':contains("Ship Date :") text{}' <<< "$w_details" | \
    awk -F: '{print $2}')
w_shpdate=$(date +%s --date="$w_rshp") # epoch

# iterate over service types and dates
w_num=$(pup 'thead + tbody > tr' <<< "$w_details" | grep -c '<tr>')
for i in $(seq 1 "$w_num"); do
    w_service[$i]=$(pup \
        'thead + tbody tr:nth-of-type('"$i"') td:nth-of-type(1) text{}' \
        <<< "$w_details")
    w_start_d[$i]=$(pup \
        'thead + tbody tr:nth-of-type('"$i"') td:nth-of-type(2) text{}' \
        <<< "$w_details")
    w_expir_d[$i]=$(pup \
        'thead + tbody tr:nth-of-type('"$i"') td:nth-of-type(3) text{}' \
        <<< "$w_details")
done

## json output
if [[ $json == 1 ]]; then

    if [[ $exp_only == 1 ]]; then
        jo -p warranty_expiration_date="$(date -d@"$w_expdate" -I)"
        exit
    fi

    for i in ${!w_service[*]}; do
      srv[$i]=$(jo service="${w_service[$i]}" \
         start_date="$(date -d"${w_start_d[$i]}" -I)" \
         end_date="$(date -d"${w_expir_d[$i]}" -I)")
    done
    srv_jarr=$(jo -a "${srv[@]}")
    jo -p product="$c_prod" \
          svctag="$svctag" \
          ship_date="$(date -d@"$w_shpdate" -I)" \
          warranty_type="${w_type:-n/a}" \
          warranty_status="${w_stat:-n/a}" \
          warranty_expiration_date="$(date -d@"$w_expdate" -I)" \
          support_services="$srv_jarr"
    exit
fi

## CLI output
if [[ $exp_only == 1 ]]; then
    date -d@"$w_expdate" -I
    exit
else
    echo "==========================================="
    echo " $c_prod"
    echo "==========================================="
    echo " service tag         | $svctag"
    echo " ship date           | $(date -d@"$w_shpdate" -I)"
    echo "-------------------------------------------"
    echo " warranty type       | ${w_type:-n/a}"
    echo " warranty status     | ${w_stat:-n/a}"
    echo " warranty expiration | $(date -d@"$w_expdate" -I)"
    echo "-------------------------------------------"

    for i in ${!w_service[*]}; do
        echo " ${w_service[$i]}" | fmt -w 45
        echo "   start date: $(date -d"${w_start_d[$i]}" -I)"
        echo "   end   date: $(date -d"${w_expir_d[$i]}" -I)"
    echo "-------------------------------------------"
    done
fi




