package main

import (
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

const removedSettlementPkg = "github.com/anticorrelator/lore/tui/internal/settlement"

// TestNoFileImportsSettlementPackage pins the settlement section's removal from
// the terminal interface. A passing build is not enough on its own: the package
// could be reintroduced alongside the surviving surfaces and still compile. This
// walks every Go file in the module — production and test — and fails on the
// import path itself.
func TestNoFileImportsSettlementPackage(t *testing.T) {
	fset := token.NewFileSet()
	err := filepath.WalkDir(".", func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() || !strings.HasSuffix(path, ".go") {
			return nil
		}
		file, err := parser.ParseFile(fset, path, nil, parser.ImportsOnly)
		if err != nil {
			return err
		}
		for _, imp := range file.Imports {
			p, err := strconv.Unquote(imp.Path.Value)
			if err != nil {
				return err
			}
			if p == removedSettlementPkg {
				t.Errorf("%s: imports the removed settlement package", fset.Position(imp.Pos()))
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

// TestSettlementPackageDirectoryAbsent guards the same removal one level up: an
// import-only check passes while an unreferenced copy of the package sits in the
// tree waiting to be wired back in.
func TestSettlementPackageDirectoryAbsent(t *testing.T) {
	if _, err := os.Stat(filepath.Join("internal", "settlement")); !os.IsNotExist(err) {
		t.Fatalf("tui/internal/settlement should not exist, stat err = %v", err)
	}
}
