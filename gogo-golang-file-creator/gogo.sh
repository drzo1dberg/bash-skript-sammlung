#!/usr/bin/env bash

if [[ $# -ne 1 ]]; then
  echo "Usage: $(basename "$0") <dir>"
  exit 1
fi

DIR="$1"

mkdir -p "$DIR"
pushd "$DIR" >/dev/null

# main.go mit Heredoc erzeugen
cat > main.go <<'EOF'
package main

func main () {}
EOF

go mod init main.go
go mod tidy

ls
popd >/dev/null

nvim "./$DIR/main.go"
