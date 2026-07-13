FROM golang:1.26.5-alpine3.23 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /runsync ./cmd/runsync

FROM alpine:3.23.3
RUN addgroup -S runsync && adduser -S -G runsync runsync
COPY --from=build /runsync /usr/local/bin/runsync
USER runsync:runsync
EXPOSE 8080
ENTRYPOINT ["runsync"]
CMD ["serve"]
