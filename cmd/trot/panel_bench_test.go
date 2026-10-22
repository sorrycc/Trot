package main

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"trot/internal/lang"
	"trot/internal/service"
	"trot/internal/settings"
)

// BenchmarkStreamFrame is a frame of the panel as a long translation of
// six paragraphs streams in, a few words at a time.
func BenchmarkStreamFrame(b *testing.B) {
	s := settings.Load(filepath.Join(b.TempDir(), "settings.json"), nil)
	p := newPanel(s)
	p.host = newFakeHost()
	tt := ui.NewTester(p.view, panelWidth, 600)
	tt.SetPreferences(ui.Preferences{ReduceMotion: true})
	p.begin(strings.Repeat("The quick brown fox jumps over the lazy dog. ", 20), lang.English, lang.ChineseSimplified, service.OpenAI, mygo.Point{})
	para := strings.Repeat("敏捷的棕色狐狸跳过了那只懒狗。", 25)
	p.append(strings.Repeat(para+"\n\n", 5) + para)
	tt.Frame()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		p.append("狐狸")
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
