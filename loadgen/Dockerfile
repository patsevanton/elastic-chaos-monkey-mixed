FROM golang:1.22 AS build
WORKDIR /src
COPY go.mod go.sum main.go ./
RUN go mod download && CGO_ENABLED=0 go build -o /loadgen .

FROM gcr.io/distroless/static
COPY --from=build /loadgen /loadgen
EXPOSE 8080
ENTRYPOINT ["/loadgen"]
