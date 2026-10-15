package lang

import (
	"strings"
	"testing"
)

func TestDetect(t *testing.T) {
	cases := []struct {
		text      string
		preferred Language
		want      Language
	}{
		{"The quick brown fox jumps over the lazy dog.", ChineseSimplified, English},
		// Short Chinese is not mistaken for Japanese.
		{"你好", ChineseSimplified, ChineseSimplified},
		{"翻译", ChineseSimplified, ChineseSimplified},
		// Ambiguous Chinese goes to the user's script.
		{"你好", ChineseTraditional, ChineseTraditional},
		{"你好", English, ChineseSimplified},
		// Script evidence wins over the preference.
		{"我们", ChineseTraditional, ChineseSimplified},
		{"我們", ChineseSimplified, ChineseTraditional},
		{"這是一段繁體中文的測試文字，用來檢查語言辨識是否正確。", ChineseSimplified, ChineseTraditional},
		{"こんにちは、世界", ChineseSimplified, Japanese},
		{"안녕하세요", ChineseSimplified, Korean},
		// Two CJK characters inside an English sentence: the sentence wins.
		{"The word 你好 means hello in Chinese, as everyone learns first.", ChineseSimplified, English},
		{"مرحبا بالعالم، هذه جملة للاختبار.", ChineseSimplified, Arabic},
		{"Привет, мир! Это предложение для проверки.", ChineseSimplified, Russian},
		{"สวัสดีชาวโลก นี่คือประโยคทดสอบ", ChineseSimplified, Thai},
		{"", ChineseSimplified, ""},
		{"   \n\t", ChineseSimplified, ""},
	}
	for _, c := range cases {
		if got := Detect(c.text, c.preferred); got != c.want {
			t.Errorf("Detect(%q, %s) = %q, want %q", c.text, c.preferred, got, c.want)
		}
	}
}

func TestDetectionReadsOnlyAPrefix(t *testing.T) {
	text := strings.Repeat("这是一个测试。", 200) + strings.Repeat("English text. ", 500)
	if got := Detect(text, ChineseSimplified); got != ChineseSimplified {
		t.Errorf("got %q", got)
	}
}

func TestScriptCertain(t *testing.T) {
	for _, l := range []Language{ChineseSimplified, Korean, Thai} {
		if !l.ScriptCertain() {
			t.Errorf("%s should be certain", l)
		}
	}
	for _, l := range []Language{English, Russian, Arabic} {
		if l.ScriptCertain() {
			t.Errorf("%s should not be certain", l)
		}
	}
}

func TestSameFamily(t *testing.T) {
	if !ChineseSimplified.SameFamily(ChineseTraditional) || !ChineseTraditional.SameFamily(ChineseSimplified) {
		t.Error("Chinese scripts are one family")
	}
	if !English.SameFamily(English) || English.SameFamily(French) {
		t.Error("family of English")
	}
}

func TestEveryLanguageHasNames(t *testing.T) {
	for _, l := range All {
		if p, ok := Parse(string(l)); !ok || p != l {
			t.Errorf("Parse(%s)", l)
		}
		if l.DisplayName() == "" || l.EnglishName() == "" || l.ShortName() == "" || l.SpeechLocale() == "" {
			t.Errorf("%s lacks a name", l)
		}
		if l.RightToLeft() != (l == Arabic) {
			t.Errorf("%s right to left", l)
		}
	}
	if _, ok := Parse("xx"); ok {
		t.Error("parsed xx")
	}
}

func TestTarget(t *testing.T) {
	for detected, want := range map[Language]Language{
		English: ChineseSimplified, Japanese: ChineseSimplified, "": ChineseSimplified,
		ChineseSimplified: English, ChineseTraditional: English,
	} {
		if got := Target(detected, ChineseSimplified, English); got != want {
			t.Errorf("Target(%q) = %s, want %s", detected, got, want)
		}
	}
}

func TestResolve(t *testing.T) {
	// The first set to what the second was: the second takes the old first.
	if f, s := Resolve(English, English, ChineseSimplified, English); f != English || s != ChineseSimplified {
		t.Errorf("got %s %s", f, s)
	}
	// The second set to what the first was: the first takes the old second.
	if f, s := Resolve(ChineseSimplified, ChineseSimplified, ChineseSimplified, English); f != English || s != ChineseSimplified {
		t.Errorf("got %s %s", f, s)
	}
	if f, s := Resolve(Japanese, English, ChineseSimplified, English); f != Japanese || s != English {
		t.Errorf("got %s %s", f, s)
	}
}

func TestPreferredChinese(t *testing.T) {
	if PreferredChinese(English, ChineseTraditional) != ChineseTraditional {
		t.Error("traditional")
	}
	if PreferredChinese(English, French) != ChineseSimplified {
		t.Error("default")
	}
}
