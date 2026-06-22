FROM golang:1.24-alpine AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/diary-server ./cmd/diary-server

FROM alpine:3.21

RUN adduser -D -H -u 10001 diary
USER diary
WORKDIR /app
COPY --from=build /out/diary-server /app/diary-server

EXPOSE 8080
ENTRYPOINT ["/app/diary-server"]
