#!/bin/bash
# retrieve warranty and parts information about Dell equipment, using the Dell
# Warranty API (or the public support site as a fallback when no API creds)

[[ $DEBUG == 1 ]] && set -x

# constants -------------------------------------------------------------------

declare -A req_urls
req_urls=(  [curl]="https://curl.se/"
            [pup]="https://github.com/ericchiang/pup"
            [jq]="http://stedolan.github.io/jq"
            [jo]="https://github.com/jpmens/jo"
            [curl-impersonate]="https://github.com/lexiforest/curl-impersonate" )


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

API credentials are optional; for the API path, provide them either:
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
    # - asset-entitlement-components (input: servicetag)
    o=$(_api "asset-entitlement-components" "servicetag=$svctag")

    # Check if response is valid JSON
    if ! jq empty <<< "$o" 2>/dev/null; then
        # Check for common error responses
        if [[ "$o" =~ "429" ]] && [[ "$o" =~ "Ratelimit" ]]; then
            err "API rate limit exceeded. Please try again later."
        elif [[ "$o" =~ "<soapenv:Fault>" ]]; then
            fault=$(grep -oP '(?<=<faultstring>)[^<]+' <<< "$o" 2>/dev/null || echo "Unknown API error")
            err "API error: $fault"
        else
            err "Invalid API response (not JSON)"
        fi
    fi

    [[ $(jq -r .invalid <<< "$o") == "true" ]] &&
        err "service tag not found ($svctag)"

    c_prod=$(jq -r .systemDescription <<< "$o")
    [[ "$c_prod" == "null" ]] && {
        c_prod=$(jq -r .productLineDescription <<< "$o")
    }
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

    # Extract components if requested
    if [[ $parts == 1 ]]; then
        # Check if components exist in the response
        if [[ $(jq '.components | length' <<< "$o") -gt 0 ]]; then
            declare -A comp_desc comp_part comp_qty comp_tech
            eval "$(jq -r '.components[] |
                "comp_desc["+(.itemNumber|@sh)+"]="+(.itemDescription | @sh) + "\n" +
                "comp_tech["+(.itemNumber|@sh)+"]="+(.partDescription | @sh) + "\n" +
                "comp_part["+(.itemNumber|@sh)+"]="+(.partNumber | @sh) + "\n" +
                "comp_qty["+(.itemNumber|@sh)+"]="+(.partQuantity|tostring | @sh)' <<< "$o")"
        fi
    fi

# no API credentials: fall back to scraping Dell's support site. This needs
# curl-impersonate (browser TLS fingerprint) and an _abck session cookie from
# DELL_ABCK, or the hardcoded default below. The cookie is short-lived and
# Akamai may block once it degrades, so this path is best-effort.
else

    # mic check
    check_req pup jo

    # curl-impersonate cannot complete Dell's Akamai challenge. A real Chrome
    # window can. dell_browser.js opens that window and saves the warranty HTML.
    w_info=""
    fetched=0
    if command -v node >/dev/null 2>&1 && [[ -f "$script_dir/dell_browser.js" ]]; then
        browser_dir=$(mktemp -d 2>/dev/null || mktemp -d -t dellw)
        if node "$script_dir/dell_browser.js" "$svctag" "$browser_dir"; then
            if [[ -s "$browser_dir/details.html" ]]; then
                w_info=$(cat "$browser_dir/details.html")
                [[ -s "$browser_dir/product.txt" ]] && c_prod=$(cat "$browser_dir/product.txt")
                fetched=1
            fi
        fi
        rm -rf "$browser_dir"
    fi

    if [[ $fetched -eq 0 ]]; then

    # Plain curl is denied by Dell's Akamai Bot Manager on a TLS/HTTP2
    # fingerprint basis (a correct User-Agent and the cookie are not enough).
    # curl-impersonate presents a genuine Chrome (BoringSSL) fingerprint, which
    # clears the bot check. https://github.com/lexiforest/curl-impersonate
    ci_target=${DELL_IMPERSONATE_TARGET:-chrome146}

    # locate curl-impersonate: $DELL_CURL_IMPERSONATE, then $PATH, then next to
    # this script (you can just drop the release binary in this directory).
    ci_bin=$DELL_CURL_IMPERSONATE
    [[ -z $ci_bin ]] && command -v curl-impersonate >/dev/null 2>&1 && ci_bin=curl-impersonate
    [[ -z $ci_bin && -x "$script_dir/curl-impersonate" ]] && ci_bin="$script_dir/curl-impersonate"
    if ! command -v "${ci_bin:-/nonexistent}" >/dev/null 2>&1 && [[ ! -x ${ci_bin:-/nonexistent} ]]; then
        err "curl-impersonate not found. The scrape path needs it (plain curl is
blocked by Dell's Akamai bot manager). Download the binary for your platform
from ${req_urls[curl-impersonate]} and drop it in this directory ($script_dir),
put it on \$PATH, or set \$DELL_CURL_IMPERSONATE to its path."
    fi

    # browser-fingerprinted fetch helper (adds the captured session cookie).
    # --compressed is required: --impersonate sets a br/zstd Accept-Encoding, so
    # curl must be told to decompress the reply (else the body is binary).
    _ci() { "$ci_bin" --compressed --impersonate "$ci_target" ${DEBUG:+-v} -sL \
                      --connect-timeout 15 -H "Cookie: _abck=$_abck" "$@"; }

    # The data endpoints also need an _abck cookie captured from a real browser
    # session (DELL_ABCK). A captured cookie is short-lived and rate-limited; if
    # requests start returning "Access Denied", recapture it from a fresh session.
    _abck=${DELL_ABCK:-'A3AAA92DFCBA5AC8BB1D164241B2B44A~0~YAAQTAw0F+M411+eAQAAjy+DdQ/0fur+OOuwiMl/Sr+1yU0hX95bBUnm57of7I7bpEW/wk7+XN844C/oyfkNVp0GseR6GLaakVtLDUON57vRKsN2SZWiZdL3qxXCflOuJf9wp8PHuILGydMyIGFVhgeMlKMjjmVuonhes1KxR40lhJTZKmQHEMAKwVoACN8mNKeT/ESLKfZVbhi1lrgtxPADTAHcPORAXsWxQftJ4Mj7BtpLE9JIG+/EOKqkazXxLO2jSDc31eG5u1PQaHqbRUPw7p5HHQCYbgODHZQOFIsR/G7LIZRKgHM4vsXxroxbAT6wfSI9/BkzOuAWMGSNSwD0cJD5XTa8uuOvKHj7v2YiUOUgBxua/55vGoCkMMeTcntsc/YVVQRqy5iDXxZSFy4VJ13blsTqxvTrkCEID3K/wbyOmP1klwk7wB/j3BYownGb6p65ZCt1xJugWdDOPXDfKw7//lfrwye3IH8qIcanLliEShJLre3J9P5XSjdYHfWeS5zmNzQAO2EjQ2sviTZBUz3R5FVKH3907dktOoDmIk1R536peBjwnk9m3PCIJCalv3VgtNilC5B+8xQ+5py8OX0Ov1kk6+Neq70mQK5LWfhyEZEcpRnsMyncXk8HE9/47E9pwUsPMGuwYUb7q1WTBYi1sEmQhvrtdUVDiGEVXcnLNfuM1wIKI5qJ2MAX3x4iF2d8CRTuZDKw8RkKQS2qJ1oWCZlgLLZEelqfcngzRexJPCJmW8yx+tisKLvPk0+F1pzxHkfmjRo7tvS62zr8JVhxU7U5RxHon+h1EppseZFWvZfj5Mh3X0xM+kvJl38xSE17twXmeVKbhzjF7ilX09w5d18occE5AUdCRb6ZqzZE2oPKwCaH/Xj/HA/h3cn/5+BMLcuzQBMA+ZCJRjKg1O77z7dzAlY5pcg=~-1~-1~-1~AAQAAAAF%2f%2f%2f%2f%2f1ttIB1CVGbdRMwA4ln4EPGc7G+Erf4gSx4UBbEgwhRlk0lFwi%2fA3qfIzDz1S6HVL80VgaIAsj3dKztkStyk5CHgEzvRFv6t77ElFN2PKsZQCNMbR2bcQQTryX9EvSPcmQ%2fdl8w%3d~-1'}

    url_root="https://www.dell.com/support"
    tag_url="$url_root/product-details/en-us/servicetag"

    # The warranty endpoints key off Dell's encrypted asset id (no longer
    # 0-base64(servicetag)). The overview page embeds it as "ServiceTag":"0-...",
    # so resolve it from the raw service tag first.
    overview=$(_ci "$tag_url/$svctag/overview")
    if [[ "$overview" =~ "Access Denied" ]] && [[ "$overview" =~ "Reference" ]]; then
        err "Akamai blocked the request (fingerprint or _abck rate-limit). Recapture DELL_ABCK from a fresh browser session."
    fi
    ident=$(grep -oE '"ServiceTag":"0-[^"]+"' <<< "$overview" | head -1 | grep -oE '0-[^"]+')
    [[ -z $ident ]] && err "could not resolve asset id for $svctag (invalid tag or blocked)"
    referer="$tag_url/$ident/overview"

    # Product name comes from the overview page; the warranty endpoints no
    # longer carry it.
    c_prod=$(grep -oE '"ProductName":"[^"]+"' <<< "$overview" | head -1 | sed -E 's/.*:"(.*)"/\1/')
    [[ -z "$c_prod" ]] && c_prod=$(pup 'title text{}' <<< "$overview" | sed -E 's/ *\|.*//' | xargs)

    # Warranty data now lives behind the "View Details" XHR (entitlement/details,
    # found in the dep-hero.js bundle). It returns an HTML fragment with two
    # tables: asset info (#WarrantyCmsViewModel-table: Service Tag | Express
    # Service Code | Ship Date | Location) and per-service entitlements
    # (#WarrantyCmsViewModel-table3: Service | Start Date | Expiration Date).
    # The dep-hero JS posts the encrypted asset id without its "0-" prefix.
    assetid=${ident#0-}
    w_info=$(_ci -H "Accept: */*" \
                 -H "Content-Type: application/json" \
                 -H "X-Robots-Tag: noindex" \
                 -H "Origin: https://www.dell.com" \
                 -H "Referer: $referer" \
                 -X POST \
                 --data "{\"assetFormat\":\"ServiceTag\",\"assetId\":\"$assetid\",\"appName\":\"DEP\",\"loadScript\":true,\"useDds\":true}" \
                 "$url_root/contractservices/en-us/entitlement/details")
    _rc=$?
    [[ $_rc -ne 0 ]] && \
        err "request failed (curl-impersonate exit $_rc); check network or DELL_ABCK value"

    [[ $dump == 1 ]] && echo "$w_info" > "w_info_$svctag.html"

    # Akamai gate
    if [[ "$w_info" =~ "Access Denied" ]] && [[ "$w_info" =~ "Reference" ]]; then
        err "Akamai blocked the request (fingerprint or _abck rate-limit). Recapture DELL_ABCK from a fresh browser session."
    fi
    [[ -z "$w_info" ]] && err "no warranty data returned for $svctag"

    fi

    # asset info table (col 3 = Ship Date, col 4 = Location)
    asset_row='#WarrantyCmsViewModel-table tr:nth-of-type(2)'
    w_rshp=$(pup "$asset_row td:nth-of-type(3) text{}" <<< "$w_info" | xargs)
    w_ctry=$(pup "$asset_row td:nth-of-type(4) text{}" <<< "$w_info" | xargs)
    w_shpdate=$(date +%s --date="$w_rshp" 2>/dev/null) || w_shpdate="n/a"

    # per-service entitlements (Service | Start Date | Expiration Date)
    svc_body='#WarrantyCmsViewModel-table3 tbody'
    w_num=$(pup "$svc_body tr" <<< "$w_info" | grep -c '<tr')
    # shellcheck disable=SC2004
    for i in $(seq 1 "$w_num"); do
        w_service[$i]=$(pup "$svc_body tr:nth-of-type($i) td:nth-of-type(1) text{}" <<< "$w_info" | xargs)
        w_start_d[$i]=$(pup "$svc_body tr:nth-of-type($i) td:nth-of-type(2) text{}" <<< "$w_info" | xargs)
        w_expir_d[$i]=$(pup "$svc_body tr:nth-of-type($i) td:nth-of-type(3) text{}" <<< "$w_info" | xargs)
    done

    # headline fields: type = primary (first) plan; expiration = latest end date;
    # status derived by comparing to now (mirrors the API path).
    w_type=${w_service[1]:-n/a}
    w_expdate=0
    for i in "${!w_expir_d[@]}"; do
        _e=$(date +%s --date="${w_expir_d[$i]}" 2>/dev/null) || _e=0
        (( _e > w_expdate )) && w_expdate=$_e
    done
    if [[ $w_expdate -gt 0 ]]; then
        [[ $w_expdate -ge $(date +%s) ]] && w_stat="Active" || w_stat="Expired"
    else
        w_stat="n/a"
        w_expdate="n/a"
    fi

    # no entitlements parsed: mirror the API path's n/a handling
    if [[ $w_num -eq 0 ]]; then w_type="n/a"; w_stat="n/a"; w_expdate="n/a"; fi

    if [[ $parts == 1 ]]; then
        echo "Warning: -p (parts listing) requires API credentials; skipping." >&2
    fi

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
                   start_date="$(date_conv "${w_start_d[$i]}")" \
                   end_date="$(date_conv "${w_expir_d[$i]}")")
    done
    srv_jarr=$(jo -a "${srv[@]}")

    # Add components to JSON output if -p flag was used
    if [[ $parts == 1 ]] && [[ ${#comp_desc[@]} -gt 0 ]]; then
        declare -A cmp
        for i in ${!comp_desc[*]}; do
            cmp[$i]=$(jo description="${comp_desc[$i]}" \
                         reference="${comp_tech[$i]:-n/a}" \
                         part_number="${comp_part[$i]:-n/a}" \
                         quantity="${comp_qty[$i]:-1}")
        done
        comp_jarr=$(jo -a "${cmp[@]}")

        jo -p product="$c_prod" \
              svctag="$svctag" \
              ship_date="$(date_conv "$w_shpdate")" \
              country="${w_ctry:-n/a}" \
              warranty_type="${w_type:-n/a}" \
              warranty_status="${w_stat:-n/a}" \
              warranty_expiration_date="$(date_conv "$w_expdate")" \
              support_services="$srv_jarr" \
              components="$comp_jarr"
    else
        jo -p product="$c_prod" \
              svctag="$svctag" \
              ship_date="$(date_conv "$w_shpdate")" \
              country="${w_ctry:-n/a}" \
              warranty_type="${w_type:-n/a}" \
              warranty_status="${w_stat:-n/a}" \
              warranty_expiration_date="$(date_conv "$w_expdate")" \
              support_services="$srv_jarr"
    fi
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

    # Display components if -p flag was used
    if [[ $parts == 1 ]] && [[ ${#comp_desc[@]} -gt 0 ]]; then
        echo " Components"
        echo "-------------------------------------------"
        for i in ${!comp_desc[*]}; do
            echo " ${comp_desc[$i]}" | fmt -w 45
            [[ -n ${comp_tech[$i]} ]] && echo "   ref: ${comp_tech[$i]}"
            [[ -n ${comp_part[$i]} ]] && echo "   p/n: ${comp_part[$i]}"
            [[ -n ${comp_qty[$i]}  ]] && echo "   qty: ${comp_qty[$i]}"
            echo "-------------------------------------------"
        done
    fi
fi
