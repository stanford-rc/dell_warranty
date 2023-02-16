#!/bin/bash
# retrive warranty and parts information about Dell equipment, using the Dell
# Warranty API

[[ $DEBUG == 1 ]] && set -x

# constants -------------------------------------------------------------------

declare -A req_urls
req_urls=(  [curl]="https://curl.se/"
            [pup]="https://github.com/ericchiang/pup"
            [jq]="http://stedolan.github.io/jq"
            [jo]="https://github.com/jpmens/jo" )


# functions -------------------------------------------------------------------
check_req() {
    for p in "$@"; do
        [[ -z ${req_urls[$p]} ]] || \
            type "$p" &> /dev/null || err "$p not found (${req_urls[$p]})"
    done
}

err() {
    if [[ "$*" != "" ]]; then
        [[ $json == 1 ]] && jo error="$*" || echo "Error: $*"
    fi
    exit 1
}

date_conv() {
    if [[ $1 =~ ^[0-9]+$ ]]; then
        date -d@"$1" -I 2>/dev/null || echo "n/a"
    else
        date -d "$1" -I 2>/dev/null || echo "n/a"
    fi
}

usage() {
    local s=${0##*/}
    cat << EOU
Usage:  $s [-j] [-e] <service_tag>

        -j  output data is serialized as a JSON object
        -e  only display the warranty expiration date
        -p  list components

API credentials must br provided either:
- in a .creds file located in the same directory as the script, containing a
  single "apikey:secret" line
- as environment variables: DELL_API_KEY and DELL_API_SEC

EOU
    err
}


# arg parse -------------------------------------------------------------------
exp_only=0 json=0 parts=0
optspec=":hdjep"
while getopts "$optspec" optchar; do
    case "${optchar}" in
        h)  usage >&2
            ;;
        e)  exp_only=1
            ;;
        j)  json=1
            ;;
        p)  parts=1
            # FIXME
            err "-p is not implemented yet"
            ;;
        d)  dump=1
            ;;
        *)  usage >&2
            ;;
    esac
done
shift $((OPTIND-1))
svctag=${1:-}

[[ "$svctag" == '' ]] && err "missing service tag"
[[ "$svctag" =~ [A-Z0-9]{7} ]] || err "invalid service tag ($svctag)"



# look for API credentials ----------------------------------------------------
script_dir="$(dirname "$(readlink -m "$0")")"
cred_file=$script_dir/.creds

if  [[ -z $DELL_API_KEY || -z $DELL_API_SEC ]]; then
    [[ -r "$cred_file" ]] && \
        IFS=: read -r DELL_API_KEY DELL_API_SEC < "$cred_file"
fi

# API credential found, using the API
if [[ -n $DELL_API_KEY ]] && [[ -n $DELL_API_SEC ]]; then

    # mic check
    check_req curl jq

    # URLs
    api_url="https://apigtwb2c.us.dell.com/PROD/sbil/eapi/v5"
    api_auth_url="https://apigtwb2c.us.dell.com/auth/oauth/v2/token"

    # get bearer token
    o=$(curl ${DEBUG:+-v} -sL --connect-timeout 5 \
             --request POST "$api_auth_url"\
             -d "client_id=$DELL_API_KEY" -d "client_secret=$DELL_API_SEC" \
             -d "grant_type=client_credentials" \
             -H "Content-Type: application/x-www-form-urlencoded" )
    [[ $(jq -r .error <<< "$o") != "null" ]] &&
        err "$(jq -r '.error+": "+.error_description' <<< "$o" )"
    token=$(jq -r .access_token <<< "$o")

    # API wrapper
    _api() { # $1: API function, $2: params
        local func=$1
        local params=$2
        curl ${DEBUG:+-v} -sL --connect-timeout 5 \
             --request GET \
             --url "$api_url/$func?$params" \
             --header "Accept: application/json" \
             --header "Authorization: Bearer $token"
    }

    # API request
    # - assets (input: servicetags)
    # - asset-entitlements (input: servicetags)
    # - asset-entitlement-components (input: servictag)
    o=$(_api "asset-entitlement-components" "servicetag=$svctag")
    [[ $(jq -r .invalid <<< "$o") == "true" ]] &&
        err "service tag not found ($svctag)"

    c_prod=$(jq -r .systemDescription <<< "$o")
    w_ctry=$(jq -r .countryCode <<< "$o")
    w_rshp=$(jq -r .shipDate <<< "$o")
    w_shpdate=$(date +%s --date="$w_rshp") # epoch

    if [[ $(jq '.entitlements | length' <<< "$o") == 0 ]]; then
        w_type="n/a"
        w_expdate="n/a"
        w_stat="n/a"
    else
        declare -A w_service w_start_d w_expir_d
        eval "$(jq -r '.entitlements[] |
            "w_service["+(.itemNumber|@sh)+"]="+(.serviceLevelDescription | @sh),
            "w_start_d["+(.itemNumber|@sh)+"]="+(.startDate),
            "w_expir_d["+(.itemNumber|@sh)+"]="+(.endDate) ' <<< "$o")"

        # last entitlement to expire
        declare w_type w_expd
        eval "$(jq -r '.entitlements | max_by(.endDate) |
                      @sh "w_type=\(.serviceLevelDescription)
                           w_expd=\(.endDate)"' <<< "$o")"

        w_expdate=$(date +%s --date="$w_expd") # epoch

        # w_stat check latest exp date compare to now
        [[ $w_expdate -ge $(date +%s) ]] && w_stat="Active" || w_stat="Expired"
    fi

# no API credentials, scraping the public web site
else

    # mic check
    check_req curl pup jo

    # URLs
    url_root="https://www.dell.com/support"
    url_comp="$url_root/components/dashboard/en-us"

    url_w_inf="$url_root/warranty/en-us/warrantydetails/servicetag"
    url_c_det="$url_comp/Configuration/GetConfiguration"
    url_overview="$url_root/home/en-us/product-support/servicetag"

    [[ -z $DELL_ABCK ]] && _abck="$DELL_ABCK" || \
    _abck="17D5BD1B272492D9DEB654A253A0ECD0~0~YAAQtTkZuE3yVy+GAQAAbQVYTAkUTP+O"
    _abck+="n/0FtQxI05TbVXuLNxUPbUq3G0cxEGssUhv/TqIewPjqw5SLOOmZ7Ii0Hr18GSfm0Z"
    _abck+="k7I0q6K+9lyp1xLhUbL3OgdzAffpUHtPAgDSUBMPXsIlh9otHiY7C0sBZ0DIXgDrKP"
    _abck+="ph60866aCaVFjEuZ4SnOGNi6Gp7auOOxcgOuslRChBJisvFiEMw7QUlDADbwc3Vy3v"
    _abck+="Omg6ctKmDG6HwesCsRjYCUB5TjPKveW6tudKJsEu1kKW7kKAUIg4LqpGYilGZbgYlW"
    _abck+="72uBTR7jvImCUpNMAEDd9agmBqs4DH3Vg8Vh+idLokyoKesvw1xbB5GN+WyNFC/DgE"
    _abck+="sqrTYSDZyGS8yx4PIjfsAEnzlfqMrTuB1hirvBRn87bZ28llbH~-1~-1~-1"

    # set default HTTPie options
    _http() { # $1: URL
        local url=$1
        curl  ${DEBUG:+-v} -sL --connect-timeout 5 "$url" \
             -H "Accept-Language: en-us" \
             -H "Accept-Encoding: identity" \
             -H "Content-Type: application/x-www-form-urlencoded" \
             -H "Origin: https://support.dell.com" \
             -A "Mozilla/5.0" \
             --cookie "_abck=$_abck"
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
    c_details=$(_http "$url_c_det?serviceTag=$s_encryp") || err

    ## dump save output
    [[ $dump == 1 ]] && {
        echo "$w_info" > "w_info_$svctag.html"
        echo "$c_details" > "c_details_$svctag.html"
    }

    # extract nuggets
    c_prod=$(pup '.product-info h1 text{}' <<< "$overview")
    w_rexp=$(pup '#expirationDt text{}' <<< "$w_info" | \
             sed 's/^Expire[sd] \+//')

    w_stat=$(pup '.warrantyExpiringLabel text{}'  <<< "$w_info" | uniq)
    w_type=$(pup 'p:contains("Current Support Services Plan") span text{}' \
        <<< "$w_info" | xargs)
    w_rshp=$(pup ':contains("Ship Date") + div text{}' <<< "$w_info" | head -n1)
    w_ctry=$(pup ':contains("Location")  + div text{}' <<< "$w_info" | head -n1)

    # conversion
    w_expdate=$(date +%s --date="$w_rexp") # epoch
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

fi

## display --------------------------------------------------------------------

## json output
if [[ $json == 1 ]]; then

    if [[ $exp_only == 1 ]]; then
        jo -p warranty_expiration_date="$(date_conv "$w_expdate")"
        exit
    fi

    declare -A srv
    # shellcheck disable=SC2004
    for i in ${!w_service[*]}; do
      srv[$i]=$(jo service="${w_service[$i]}" \
                   start_date="$(date -d"${w_start_d[$i]}" -I)" \
                   end_date="$(date -d"${w_expir_d[$i]}" -I)")
    done
    srv_jarr=$(jo -a "${srv[@]}")
    jo -p product="$c_prod" \
          svctag="$svctag" \
          ship_date="$(date_conv "$w_shpdate")" \
          country="${w_ctry:-n/a}" \
          warranty_type="${w_type:-n/a}" \
          warranty_status="${w_stat:-n/a}" \
          warranty_expiration_date="$(date_conv "$w_expdate")" \
          support_services="$srv_jarr"
    exit
fi

## CLI output
if [[ $exp_only == 1 ]]; then
    date_conv "$w_expdate"
    exit
else
    echo "==========================================="
    echo " $c_prod"
    echo "==========================================="
    echo " service tag         | $svctag"
    echo " ship date           | $(date_conv "$w_shpdate")"
    echo " country             | $w_ctry"
    echo "-------------------------------------------"
    echo " warranty type       | ${w_type:-n/a}"
    echo " warranty status     | ${w_stat:-n/a}"
    echo " warranty expiration | $(date_conv "$w_expdate")"
    echo "-------------------------------------------"

    for i in ${!w_service[*]}; do
        echo " ${w_service[$i]}" | fmt -w 45
        echo "   start date: $(date_conv "${w_start_d[$i]}")"
        echo "   end   date: $(date_conv "${w_expir_d[$i]}")"
    echo "-------------------------------------------"
    done
fi




