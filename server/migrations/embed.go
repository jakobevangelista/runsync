package migrations

import "embed"

// Files contains the immutable forward migrations shipped with the binary.
//
//go:embed *.sql
var Files embed.FS
