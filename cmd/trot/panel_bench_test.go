package main

import (
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"trot/internal/lang"
	"trot/internal/service"
	"trot/internal/settings"
)

// BenchmarkStreamFrame is a frame of the panel as a long translation of
// six paragraphs streams in, a few words at a time. Its last paragraph
// stays the same length, so the frames measure the same work however many
// there are.
func BenchmarkStreamFrame(b *testing.B) {
	s := settings.Load(filepath.Join(b.TempDir(), "settings.json"), nil)
	p := newPanel(s)
	p.host = newFakeHost()
	tt := ui.NewTester(p.view, panelWidth, 600)
	tt.SetPreferences(ui.Preferences{ReduceMotion: true})
	p.begin(strings.Repeat("The quick brown fox jumps over the lazy dog. ", 20), lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
	para := strings.Repeat("敏捷的棕色狐狸跳过了那只懒狗。", 25)
	p.append(strings.Repeat(para+"\n\n", 5) + para)
	full := p.result
	tt.Frame()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		// Words no frame has drawn before, so none of them is cached.
		p.result = full + strconv.Itoa(i)
		tt.Frame()
	}
}

// BenchmarkIdleFrame is a frame of a finished panel, as hovering draws.
func BenchmarkIdleFrame(b *testing.B) {
	s := settings.Load(filepath.Join(b.TempDir(), "settings.json"), nil)
	p := newPanel(s)
	p.host = newFakeHost()
	tt := ui.NewTester(p.view, panelWidth, 600)
	tt.SetPreferences(ui.Preferences{ReduceMotion: true})
	p.begin("Hello", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
	p.append(strings.Repeat("敏捷的棕色狐狸跳过了那只懒狗。", 150))
	p.finish("1.0 s")
	tt.Frame()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		tt.Move(float32(i%400), 10)
		tt.Frame()
	}
}

// BenchmarkStreamLinesFrame is a frame of the panel as a list of forty
// lines, with no blank line between them, streams in. The list stays the
// same length.
func BenchmarkStreamLinesFrame(b *testing.B) {
	s := settings.Load(filepath.Join(b.TempDir(), "settings.json"), nil)
	p := newPanel(s)
	p.host = newFakeHost()
	tt := ui.NewTester(p.view, panelWidth, 600)
	tt.SetPreferences(ui.Preferences{ReduceMotion: true})
	p.begin("A list.", lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
	p.append(strings.Repeat("- 敏捷的棕色狐狸跳过了那只懒狗。\n", 40) + "- 敏捷的棕色")
	full := p.result
	tt.Frame()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		p.result = full + strconv.Itoa(i)
		tt.Frame()
	}
}
