#!/bin/bash

[[ $DEBUG == 1 ]] && set -x

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

exp_only=0 json=0 dump=0
optspec=":hdje"
while getopts "$optspec" optchar; do
    case "${optchar}" in
        h)  usage >&2
            ;;
        e)  exp_only=1
            ;;
        j)  json=1
            ;;
        d)  dump=1
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


# URLs
url_root="https://www.dell.com/support"
url_comp="$url_root/components/dashboard/en-us"

url_w_inf="$url_root/warranty/en-us/warrantydetails/servicetag"
url_c_det="$url_comp/Configuration/GetConfiguration"
url_overview="$url_root/home/en-us/product-support/servicetag"

_abck="9BE24ADF1158FFF0CEF1DF3FEECA2461~0~YAAQnn8lF+qbzUSDAQAAmBe5YAgrRqIRBMmhg"
_abck+="gZh0Wm3kHRIvwtw/GEYIszuS+mxmdY806g9ZLOBnUrM3tWBvEVzBSW1RE3QeVk41f62Fja+"
_abck+="mlt2lAxaXpccDKacMJJYM7KlTzv/cEhwPjQP8DV4MJtxEwJP43E3tX0cjBob8FGbH+eV9sS"
_abck+="hXgWcnXOXY5dByQFGiuFGnUFEzE2UUooBCvVZlZ1Kp6v+29lqdXbUE7BAZxFmTRcfxN6du/"
_abck+="IlcsWNOAOKMlbkJfR5ccDH4Y3lEy/atcaReNNrQw2OGPyyeLmxvMy5ZSI8d1gkVySNIoV4t"
_abck+="DmGU5hw5Ipzp87tQ+3Bqhdz064UBW7sAfQs4uTS2R98ccZNFW6S3xWOLCx/7y5PB5ml2rj3"
_abck+="Kx4JsbQ80THiWvAliQ==~-1~-1~-1"

# set default HTTPie options
_http() { # $1: URL
    local url=$1
    $(which http) --check-status --follow --timeout=5 "$url" \
    Accept-Language:en-us Content-Type:application/x-www-form-urlencoded \
    Origin:https://support.dell.com Cookie:_abck=$_abck user-agent:Mozilla/5.0
}

# get general info
overview=$(_http "$url_overview/$svctag") || err

# check for invalid service tag
o_link=$(pup 'meta[rel="channel"] attr{href}' <<< "$overview")
# shellcheck disable=SC2076
[[ "$o_link" =~ "Selection=$svctag&amp;IsInvalidSelection=True" ]] && \
    err "service tag not found ($svctag)"

# retrieve encrypted service tag from overview
s_encryp=$(awk '/encryptedTag = / {print $NF}'   <<< "$overview" | tr -d "';")
## dump save output
[[ $dump == 1 ]] && {
    echo "$overview" > "overview_$svctag.html"
}
[[ ${s_encryp} == "" ]] && err "s_encryp not found"


# get warranty info
w_info=$(_http "$url_w_inf/$s_encryp/mse/IPS?_=f") || err

# get configuration details
c_details=$(http "$url_c_det?serviceTag=$s_encryp") || err

## dump save output
[[ $dump == 1 ]] && {
    echo "$w_info" > "w_info_$svctag.html"
    echo "$c_details" > "c_details_$svctag.html"
}

# extract nuggets
c_prod=$(pup '.product-info h1 text{}' <<< "$overview")
w_rexp=$(pup '#expirationDt text{}' <<< "$w_info" | \
         sed 's/^Expire[sd] \+//')
w_expdate=$(date +%s --date="$w_rexp") # epoch

w_stat=$(pup '.warrantyExpiringLabel text{}'  <<< "$w_info" | uniq)
w_type=$(pup 'p:contains("Current Support Services Plan") span text{}' \
    <<< "$w_info" | xargs)
w_rshp=$(pup ':contains("Ship Date") + div text{}' <<< "$w_info" | head -n1)
w_ctry=$(pup ':contains("Location")  + div text{}' <<< "$w_info" | head -n1)
w_shpdate=$(date +%s --date="$w_rshp") # epoch

# iterate over service types and dates
w_num=$(pup 'thead + tbody > tr' <<< "$w_info" | grep -c '<tr')
# shellcheck disable=SC2004
for i in $(seq 1 "$w_num"); do
    w_service[$i]=$(pup \
        'thead + tbody tr:nth-of-type('"$i"') td:nth-of-type(1) text{}' \
        <<< "$w_info")
    w_start_d[$i]=$(pup \
        'thead + tbody tr:nth-of-type('"$i"') td:nth-of-type(2) text{}' \
        <<< "$w_info")
    w_expir_d[$i]=$(pup \
        'thead + tbody tr:nth-of-type('"$i"') td:nth-of-type(3) text{}' \
        <<< "$w_info")
done

## json output
if [[ $json == 1 ]]; then

    if [[ $exp_only == 1 ]]; then
        jo -p warranty_expiration_date="$(date -d@"$w_expdate" -I)"
        exit
    fi

    # shellcheck disable=SC2004
    for i in ${!w_service[*]}; do
      srv[$i]=$(jo service="${w_service[$i]}" \
         start_date="$(date -d"${w_start_d[$i]}" -I)" \
         end_date="$(date -d"${w_expir_d[$i]}" -I)")
    done
    srv_jarr=$(jo -a "${srv[@]}")
    jo -p product="$c_prod" \
          svctag="$svctag" \
          ship_date="$(date -d@"$w_shpdate" -I)" \
          country="${w_ctry:-n/a}" \
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
    echo " country             | $w_ctry"
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




