package settings

// StatusHint is one key-label pair for the host status bar.
type StatusHint struct {
	Key   string // e.g. "enter", "a", "esc", "↕"
	Label string // e.g. "save", "add", "revert"
}

// HintProvider is implemented by widgets whose hints depend on their
// internal mode. Widgets without it get generic hints from the model.
type HintProvider interface {
	StatusHints() []StatusHint
}

func hasStatusHintKey(hints []StatusHint, key string) bool {
	for _, hint := range hints {
		if hint.Key == key {
			return true
		}
	}
	return false
}

func appendStatusHintIfMissing(hints []StatusHint, hint StatusHint) []StatusHint {
	if hasStatusHintKey(hints, hint.Key) {
		return hints
	}
	return append(hints, hint)
}

func appendUnsetHint(hints []StatusHint, allowUnset, present bool) []StatusHint {
	if allowUnset && present {
		hints = append(hints, StatusHint{Key: "u", Label: "unset"})
	}
	return hints
}

func containerStatusHints(base *containerBase, children []FieldWidget) []StatusHint {
	if !base.entered {
		return []StatusHint{{Key: "enter", Label: "open"}}
	}
	hints := childStatusHints(children, base.cursor)
	if !hasStatusHintKey(hints, "esc") {
		hints = append(hints, StatusHint{Key: "esc", Label: "back"})
	}
	return hints
}

func childStatusHints(children []FieldWidget, cursor int) []StatusHint {
	if cursor < 0 || cursor >= len(children) {
		return nil
	}
	provider, ok := children[cursor].(HintProvider)
	if !ok {
		return nil
	}
	return append([]StatusHint(nil), provider.StatusHints()...)
}

func (e *EnumSelector) StatusHints() []StatusHint {
	hints := []StatusHint{{Key: "h/l", Label: "select"}}
	if e.allowUnset {
		hints = append(hints, StatusHint{Key: "u", Label: "inherit"})
	}
	return hints
}

func (t *ToggleRow) StatusHints() []StatusHint {
	return []StatusHint{{Key: "space", Label: "toggle"}}
}

func (t *TextInput) StatusHints() []StatusHint {
	if t.editing {
		return []StatusHint{
			{Key: "enter/↕", Label: "save"},
			{Key: "esc", Label: "revert"},
		}
	}
	return appendUnsetHint([]StatusHint{{Key: "enter", Label: "edit"}}, t.allowUnset, t.present)
}

func (n *NumericInput) StatusHints() []StatusHint {
	if n.editing {
		return []StatusHint{
			{Key: "enter/↕", Label: "save"},
			{Key: "esc", Label: "revert"},
		}
	}
	return appendUnsetHint([]StatusHint{{Key: "enter", Label: "edit"}}, n.allowUnset, n.present)
}

func (l *ListEditor) StatusHints() []StatusHint {
	switch {
	case l.appending:
		return []StatusHint{
			{Key: "enter", Label: "confirm"},
			{Key: "esc", Label: "cancel"},
		}
	case l.editing && l.selector:
		return []StatusHint{
			{Key: "space", Label: "toggle"},
			{Key: "↕", Label: "move"},
			{Key: "esc", Label: "done"},
		}
	case l.editing:
		return []StatusHint{
			{Key: "a", Label: "add"},
			{Key: "d", Label: "delete"},
			{Key: "↕", Label: "move"},
			{Key: "esc", Label: "done"},
		}
	default:
		return appendUnsetHint([]StatusHint{{Key: "enter", Label: "open"}}, l.allowUnset, l.present)
	}
}

func (a *ActiveHoursRangesEditor) StatusHints() []StatusHint {
	if !a.editing {
		return []StatusHint{{Key: "enter", Label: "open"}}
	}
	return []StatusHint{
		{Key: "↕", Label: "field"},
		{Key: "h/l", Label: "field"},
		{Key: "+/-", Label: "time"},
		{Key: "1-7", Label: "days"},
		{Key: "a", Label: "add"},
		{Key: "d", Label: "delete"},
		{Key: "esc", Label: "done"},
	}
}

func (p *ClosedObjectSubPanel) StatusHints() []StatusHint {
	return containerStatusHints(&p.containerBase, p.children)
}

func (kv *OpenKeysetKVEditor) StatusHints() []StatusHint {
	if !kv.editing && kv.mode == kvNavigating {
		return appendUnsetHint([]StatusHint{{Key: "enter", Label: "open"}}, kv.allowUnset, kv.present)
	}
	switch kv.mode {
	case kvAddingKey:
		return []StatusHint{
			{Key: "enter", Label: "next"},
			{Key: "esc", Label: "cancel"},
		}
	case kvAddingValue, kvEditingValue:
		return []StatusHint{
			{Key: "enter", Label: "save"},
			{Key: "esc", Label: "cancel"},
		}
	default:
		return []StatusHint{
			{Key: "a", Label: "add"},
			{Key: "e", Label: "edit"},
			{Key: "d", Label: "delete"},
			{Key: "↕", Label: "move"},
			{Key: "esc", Label: "done"},
		}
	}
}

func (a *AdvancedSection) StatusHints() []StatusHint {
	if !a.expanded {
		return []StatusHint{{Key: "enter", Label: "open"}}
	}
	if !a.entered {
		return []StatusHint{
			{Key: "enter", Label: "open"},
			{Key: "esc", Label: "back"},
		}
	}
	return containerStatusHints(&a.containerBase, []FieldWidget{a.child})
}

func (r *PrimaryRadio) StatusHints() []StatusHint {
	return []StatusHint{{Key: "h/l", Label: "select"}}
}

func (h *HarnessBlockPanel) StatusHints() []StatusHint {
	return containerStatusHints(&h.containerBase, h.children())
}

func (t *harnessEnabledToggle) StatusHints() []StatusHint {
	return []StatusHint{{Key: "space", Label: "toggle"}}
}
