FROM alpine

RUN apk add --no-cache bash coreutils jo httpie go git
RUN go get github.com/ericchiang/pup
RUN go get github.com/msoap/shell2http

ENV PATH="${PATH}:/root/go/bin"
ENV PORT=8080
ENV API_CACHE=3600

COPY ./dell_warranty.sh /app/dell_warranty.sh

EXPOSE $PORT

CMD shell2http -port ${PORT} -no-index -cache=${API_CACHE} \
               -show-errors -include-stderr -form \
               /check  '/app/dell_warranty.sh -j $v_svctag'
#CMD [ "-port", "$(echo ${PORT})", "-no-index", "-cache=3600", \
#      "-show-errors", "-include-stderr", "-form",  \
#      "/check", "/app/dell_warranty.sh -j ${v_svctag}" ]


