FROM alpine

RUN apk add --no-cache bash coreutils jo httpie go git
RUN apk add py-setuptools # missing httpie dependency as of 20210818
RUN go get github.com/ericchiang/pup
RUN go get github.com/msoap/shell2http

ENV PATH="${PATH}:/root/go/bin"

ENV PORT=8080
ENV API_CACHE=3600

COPY ./dell_warranty.sh /app/dell_warranty.sh

EXPOSE $PORT

CMD shell2http -port ${PORT} -no-index -cache=${API_CACHE} \
               -show-errors -include-stderr -form \
               /check '/app/dell_warranty.sh -j $v_svctag'
