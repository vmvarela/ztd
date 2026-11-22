#!/bin/sh
set -eu
gofmt -l .
test -z "$(gofmt -l .)"
go vet ./...
go test ./...
go test -race ./...
go test ./test/integration -count=1
go mod verify
go build -o ./ztd ./cmd/ztd
