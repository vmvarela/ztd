// Package ztd embeds the asset bundles the install command publishes: the
// OpenCode adapter (skills) and the method templates. The root
// package stays free of logic; internal/install classifies and writes them.
package ztd

import "embed"

// OpencodeFS is the OpenCode bundle that `ztd install opencode` publishes to
// $HOME/.config/opencode, with entry paths relative to integrations/opencode.
//
//go:embed integrations/opencode/skills
var OpencodeFS embed.FS

// TemplatesFS is the bundle that `ztd install templates` publishes to
// <store-root>/templates, with entry paths relative to method.
//
//go:embed method/templates/*.md
var TemplatesFS embed.FS
