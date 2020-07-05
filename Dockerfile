FROM msoap/shell2http

RUN apk add --no-cache bash coreutils jo httpie go git
RUN go get github.com/ericchiang/pup

ENV PATH="${PATH}:/root/go/bin"

COPY ./dell_warranty.sh /app/dell_warranty.sh

EXPOSE 8080
CMD [ "-no-index", "-cache=3600", \
      "-show-errors", "-include-stderr", "-form",  \
      "/check", "/app/dell_warranty.sh -j ${v_svctag}" ]

