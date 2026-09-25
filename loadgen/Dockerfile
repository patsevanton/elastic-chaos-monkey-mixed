FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum main.go ./
RUN go mod download && CGO_ENABLED=0 go build -o /loadgen .

FROM alpine:3.21
COPY --from=build /loadgen /loadgen
EXPOSE 8080
ENTRYPOINT ["/loadgen"]
