package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/anticorrelator/lore/tui/internal/worktree"
)

func main() {
	if len(os.Args) < 2 {
		fail("usage: lore-worktree-guard <create|validate|transition|quarantine> [flags]")
	}
	switch os.Args[1] {
	case "create":
		create(os.Args[2:])
	case "validate":
		validate(os.Args[2:])
	case "transition":
		transition(os.Args[2:])
	case "quarantine":
		quarantine(os.Args[2:])
	default:
		fail("unknown command %q", os.Args[1])
	}
}

func create(args []string) {
	fs := flag.NewFlagSet("create", flag.ExitOnError)
	source := fs.String("source", "", "source checkout")
	path := fs.String("path", "", "new worktree path")
	epoch := fs.String("epoch", "", "worktree epoch")
	_ = fs.Parse(args)
	identity, err := worktree.Create(context.Background(), *source, *path, *epoch)
	if err != nil {
		fail("create: %v", err)
	}
	emit(identity)
}

func validate(args []string) {
	identity := readIdentity(args, "validate")
	if err := worktree.ValidateIdentity(context.Background(), identity); err != nil {
		fail("validate: %v", err)
	}
	emit(identity)
}

func transition(args []string) {
	fs := flag.NewFlagSet("transition", flag.ExitOnError)
	identityPath := fs.String("identity", "", "identity JSON file")
	state := fs.String("state", "", "next guard lifecycle state")
	_ = fs.Parse(args)
	identity := decodeIdentity(*identityPath)
	next, err := worktree.Transition(identity, worktree.LifecycleState(*state))
	if err != nil {
		fail("transition: %v", err)
	}
	emit(next)
}

func quarantine(args []string) {
	fs := flag.NewFlagSet("quarantine", flag.ExitOnError)
	identityPath := fs.String("identity", "", "identity JSON file")
	reason := fs.String("reason", "abandoned owner", "quarantine reason")
	_ = fs.Parse(args)
	identity := decodeIdentity(*identityPath)
	next, artifact, err := worktree.Quarantine(context.Background(), identity, *reason)
	if err != nil {
		fail("quarantine: %v", err)
	}
	emit(struct {
		Identity worktree.Identity       `json:"identity"`
		Artifact worktree.ResultArtifact `json:"artifact"`
	}{Identity: next, Artifact: artifact})
}

func readIdentity(args []string, name string) worktree.Identity {
	fs := flag.NewFlagSet(name, flag.ExitOnError)
	identityPath := fs.String("identity", "", "identity JSON file")
	_ = fs.Parse(args)
	return decodeIdentity(*identityPath)
}

func decodeIdentity(path string) worktree.Identity {
	if path == "" {
		fail("--identity is required")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		fail("read identity: %v", err)
	}
	var identity worktree.Identity
	if err := json.Unmarshal(data, &identity); err != nil {
		fail("decode identity: %v", err)
	}
	return identity
}

func emit(value any) {
	if err := json.NewEncoder(os.Stdout).Encode(value); err != nil {
		fail("encode result: %v", err)
	}
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "Error: "+format+"\n", args...)
	os.Exit(1)
}
