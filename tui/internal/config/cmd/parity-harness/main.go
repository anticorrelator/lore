// parity-harness is a small CLI used by tests/frameworks/harness_args.bats
// (T12) to drive the Go-side dual-implementation helpers and produce output
// byte-equivalent to the bash side (scripts/lib.sh). The bats test runs both
// sides against the same $LORE_DATA_DIR and asserts the outputs match.
//
// Usage:
//
//	parity-harness <helper> [arg]...
//
// Supported helpers (one row per dual-impl helper named in adapters/README.md;
// helpers added in T7 are wired now, helpers added in T10 print
// "T10-pending" until that task lands):
//
//	resolve_active_framework        — print active framework id
//	framework_capability <cap>      — print support level (T10-pending)
//	framework_model_routing_shape   — print "single" | "multi" (T10-pending)
//	resolve_harness_install_path <kind>
//	                                — print absolute path or "unsupported"
//	resolve_agent_template <name>   — print absolute path
//	resolve_model_for_role <role>   — print model id (T10-pending)
//	load_harness_args [framework]   — print args, one per line (T10-pending)
//	migrate_claude_args_to_harness_args
//	                                — print "ok" on success (T10-pending)
//
// On success the harness writes its result to stdout and exits 0. On error
// it writes a one-line message to stderr and exits non-zero — matching the
// bash side's error contract from scripts/lib.sh. Helpers not yet exported
// from package config print "T10-pending" on stdout and exit 0 so bats can
// skip cleanly until T10 lands.
package main

import (
	"fmt"
	"os"

	"github.com/anticorrelator/lore/tui/internal/config"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "Error: parity-harness requires a helper name")
		os.Exit(1)
	}

	helper := os.Args[1]
	args := os.Args[2:]

	switch helper {
	case "resolve_active_framework":
		out, err := config.ResolveActiveFramework()
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(1)
		}
		fmt.Println(out)

	case "resolve_harness_install_path":
		if len(args) != 1 {
			fmt.Fprintln(os.Stderr, "Error: resolve_harness_install_path requires <kind>")
			os.Exit(1)
		}
		path, supported, err := config.ResolveHarnessInstallPath(args[0])
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(1)
		}
		if !supported {
			fmt.Println("unsupported")
			return
		}
		fmt.Println(path)

	case "harness_path_or_empty":
		if len(args) != 1 {
			fmt.Fprintln(os.Stderr, "Error: harness_path_or_empty requires <kind>")
			os.Exit(1)
		}
		// HarnessPathOrEmpty collapses unsupported + error into "". Print the
		// result raw — empty stdout is the bash-side signal too.
		fmt.Println(config.HarnessPathOrEmpty(args[0]))

	case "resolve_agent_template":
		if len(args) != 1 {
			fmt.Fprintln(os.Stderr, "Error: resolve_agent_template requires <name>")
			os.Exit(1)
		}
		out, err := config.ResolveAgentTemplate(args[0])
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(1)
		}
		fmt.Println(out)

	case "load_harness_args":
		// Optional positional <framework>; empty means "use active framework".
		harness := ""
		if len(args) >= 1 {
			harness = args[0]
		}
		for _, a := range config.LoadHarnessArgs(harness) {
			fmt.Println(a)
		}

	case "migrate_claude_args_to_harness_args":
		if err := config.MigrateClaudeArgsToHarnessArgs(); err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(1)
		}
		// Match bash side: silent on success.

	case "resolve_model_for_role":
		if len(args) != 1 {
			fmt.Fprintln(os.Stderr, "Error: resolve_model_for_role requires <role>")
			os.Exit(1)
		}
		out, err := config.ResolveModelForRole(args[0])
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(1)
		}
		fmt.Println(out)

	case "framework_capability",
		"framework_model_routing_shape":
		// These bash-only helpers were added in T6 but were not part of T10's
		// Go-side scope (T10 is harness-args + ResolveModelForRole only). They
		// remain Go-side TODOs; the harness keeps a stable sentinel so bats
		// can skip the parity row without failing the suite.
		fmt.Println("T10-pending")

	default:
		fmt.Fprintf(os.Stderr, "Error: unknown helper %q\n", helper)
		os.Exit(1)
	}
}
