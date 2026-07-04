FROM golang:1.21-alpine AS builder

WORKDIR /app

# Copy the entire source code first so 'go mod tidy' can see all imports
COPY . .

# Now resolve dependencies and build
RUN go mod tidy
RUN go build -o evaluation-service .

FROM alpine:latest

WORKDIR /app

COPY --from=builder /app/evaluation-service .

EXPOSE 8004

CMD ["./evaluation-service"]
