package work

import (
	"strings"
	"testing"
)

func TestPlanTabEmpty(t *testing.T) {
	m := NewPlanTabModel(nil, 80, 20)
	if !m.IsEmpty() {
		t.Error("should be empty when planContent is nil")
	}

	view := m.View()
	if !strings.Contains(view, "No plan document") {
		t.Errorf("empty view should say 'No plan document', got %q", view)
	}
}

func TestPlanTabEmptyString(t *testing.T) {
	empty := ""
	m := NewPlanTabModel(&empty, 80, 20)
	if !m.IsEmpty() {
		t.Error("should be empty when planContent is empty string")
	}
}

func TestPlanTabWhitespaceOnly(t *testing.T) {
	ws := "   \n\t  \n"
	m := NewPlanTabModel(&ws, 80, 20)
	if !m.IsEmpty() {
		t.Error("should be empty when planContent is whitespace only")
	}
}

func TestPlanTabWithContent(t *testing.T) {
	content := "# Test Plan\n\nSome content here.\n\n## Section\n\n- item 1\n- item 2"
	m := NewPlanTabModel(&content, 80, 20)
	if m.IsEmpty() {
		t.Error("should not be empty with content")
	}

	view := m.View()
	if view == "" {
		t.Error("view should not be empty")
	}
}

func TestRenderMarkdown(t *testing.T) {
	input := "# Hello\n\nWorld"
	result := renderMarkdown(input, 80)

	if result == "" {
		t.Error("rendered output should not be empty")
	}
	if !strings.Contains(result, "Hello") {
		t.Errorf("rendered output should contain 'Hello', got %q", result)
	}
}

func TestRenderMarkdownZeroWidth(t *testing.T) {
	input := "# Test\n\nContent"
	result := renderMarkdown(input, 0)
	if result == "" {
		t.Error("should handle zero width gracefully")
	}
}
