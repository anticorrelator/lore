package main

import (
	"bytes"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anticorrelator/lore/tui/internal/session"
)

func captureRuntimeStderr(t *testing.T, fn func()) string {
	t.Helper()
	original := os.Stderr
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stderr = w
	defer func() { os.Stderr = original }()
	fn()
	_ = w.Close()
	var buf bytes.Buffer
	_, _ = io.Copy(&buf, r)
	_ = r.Close()
	return buf.String()
}

func copyFixture(t *testing.T, name, dest string) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", "alt-screen-stderr", name))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dest, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestAlternateScreenRuntimeContract_ZeroParentStderr(t *testing.T) {
	if !((model{}).View().AltScreen) {
		t.Fatal("root model does not advertise alternate-screen mode")
	}
	dir := t.TempDir()
	copyFixture(t, "corrupt-instance.json", filepath.Join(session.InstancesDir(dir), "bad.json"))
	copyFixture(t, "corrupt-queue-request.json", filepath.Join(session.PendingDir(dir), "bad.json"))
	copyFixture(t, "corrupt-queue-request.json", filepath.Join(session.CloseRequestsDir(dir), "bad.json"))
	copyFixture(t, "corrupt-queue-request.json", filepath.Join(session.SendRequestsDir(dir), "bad.json"))
	copyFixture(t, "corrupt-queue-request.json", filepath.Join(session.PeekRequestsDir(dir), "bad.json"))

	stderr := captureRuntimeStderr(t, func() {
		_, instanceDiagnostics := session.ListInstancesWithDiagnostics(dir)
		_, queueDiagnostics := session.ScanPendingWithDiagnostics(dir)
		_, closeDiagnostics := session.ScanCloseRequestsWithDiagnostics(dir)
		_, sendDiagnostics := session.ScanSendRequestsWithDiagnostics(dir)
		_, peekDiagnostics := session.ScanPeekRequestsWithDiagnostics(dir)
		if len(instanceDiagnostics)+len(queueDiagnostics)+len(closeDiagnostics)+len(sendDiagnostics)+len(peekDiagnostics) != 5 {
			t.Fatalf("diagnostics missing: instance=%d queue=%d close=%d send=%d peek=%d", len(instanceDiagnostics), len(queueDiagnostics), len(closeDiagnostics), len(sendDiagnostics), len(peekDiagnostics))
		}
		proc := &fakeProc{signalsBeforeExit: 1}
		_, notices, err := runCloseLadder(proc, nil, "", false, "codex", time.Millisecond, time.Millisecond)
		if err != nil || len(notices) != 1 {
			t.Fatalf("close notice = %#v, err=%v", notices, err)
		}
		if noContractNotice("codex").Class != operatorDegradation {
			t.Fatal("gate notice is not an operator degradation")
		}
	})
	if stderr != "" {
		t.Fatalf("alternate-screen runtime wrote %d parent-stderr bytes: %q", len(stderr), stderr)
	}
}

func TestRuntimeTUIProductionFilesDoNotWriteParentStderr(t *testing.T) {
	fset := token.NewFileSet()
	err := filepath.WalkDir(".", func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		clean := filepath.ToSlash(path)
		if clean == "main.go" || clean == "internal/config/cmd/parity-harness/main.go" {
			return nil
		}
		file, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			return err
		}
		ast.Inspect(file, func(node ast.Node) bool {
			switch n := node.(type) {
			case *ast.SelectorExpr:
				if id, ok := n.X.(*ast.Ident); ok && id.Name == "os" && n.Sel.Name == "Stderr" {
					t.Errorf("%s: parent stderr is outside the runtime TUI notice boundary", fset.Position(n.Pos()))
				}
			case *ast.CallExpr:
				selector, ok := n.Fun.(*ast.SelectorExpr)
				if !ok {
					break
				}
				id, ok := selector.X.(*ast.Ident)
				if ok && id.Name == "log" && strings.HasPrefix(selector.Sel.Name, "Print") {
					t.Errorf("%s: default logger output is outside the runtime TUI notice boundary", fset.Position(n.Pos()))
				}
			}
			return true
		})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
