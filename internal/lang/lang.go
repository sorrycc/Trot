// Package lang holds the languages Trot translates between, detects which
// one a text is in, and picks the target by the two-language rule.
package lang

import (
	"strings"
	"unicode"

	"trot/internal/mac"
)

// Language is a language Trot translates from or to, by its BCP 47 code,
// as NaturalLanguage names it.
type Language string

const (
	English            Language = "en"
	ChineseSimplified  Language = "zh-Hans"
	ChineseTraditional Language = "zh-Hant"
	Japanese           Language = "ja"
	Korean             Language = "ko"
	French             Language = "fr"
	German             Language = "de"
	Spanish            Language = "es"
	Portuguese         Language = "pt"
	Italian            Language = "it"
	Russian            Language = "ru"
	Arabic             Language = "ar"
	Vietnamese         Language = "vi"
	Thai               Language = "th"
)

// All are the languages, in the order menus list them.
var All = []Language{
	English, ChineseSimplified, ChineseTraditional, Japanese, Korean, French, German,
	Spanish, Portuguese, Italian, Russian, Arabic, Vietnamese, Thai,
}

type info struct {
	display, english, short, speech string
}

var infos = map[Language]info{
	English:            {"English", "English", "EN", "en-US"},
	ChineseSimplified:  {"简体中文", "Simplified Chinese", "简", "zh-CN"},
	ChineseTraditional: {"繁體中文", "Traditional Chinese", "繁", "zh-TW"},
	Japanese:           {"日本語", "Japanese", "日", "ja-JP"},
	Korean:             {"한국어", "Korean", "한", "ko-KR"},
	French:             {"Français", "French", "FR", "fr-FR"},
	German:             {"Deutsch", "German", "DE", "de-DE"},
	Spanish:            {"Español", "Spanish", "ES", "es-ES"},
	Portuguese:         {"Português", "Portuguese", "PT", "pt-BR"},
	Italian:            {"Italiano", "Italian", "IT", "it-IT"},
	Russian:            {"Русский", "Russian", "RU", "ru-RU"},
	Arabic:             {"العربية", "Arabic", "AR", "ar-SA"},
	Vietnamese:         {"Tiếng Việt", "Vietnamese", "VI", "vi-VN"},
	Thai:               {"ไทย", "Thai", "TH", "th-TH"},
}

// Parse returns the language of a code, and whether it is one.
func Parse(code string) (Language, bool) {
	l := Language(code)
	_, ok := infos[l]
	return l, ok
}

// DisplayName is the language as menus show it, in the language itself.
func (l Language) DisplayName() string { return infos[l].display }

// EnglishName is the language as prompts name it.
func (l Language) EnglishName() string { return infos[l].english }

// ShortName is a two or three letter tag for a compact chip.
func (l Language) ShortName() string { return infos[l].short }

// SpeechLocale is the voice to read the language with.
func (l Language) SpeechLocale() string { return infos[l].speech }

// RightToLeft reports whether it is written from the right, so its
// paragraphs start there.
func (l Language) RightToLeft() bool { return l == Arabic }

// ScriptCertain reports whether no other language here shares its script,
// so detection is never a guess. Cyrillic and Arabic script are not:
// Ukrainian or Persian would be called Russian or Arabic.
func (l Language) ScriptCertain() bool {
	switch l {
	case ChineseSimplified, ChineseTraditional, Japanese, Korean, Thai:
		return true
	}
	return false
}

// SameFamily reports whether the two are the same language apart from
// script, so Chinese detected as traditional still counts as the user's
// Chinese.
func (l Language) SameFamily(other Language) bool {
	chinese := func(x Language) bool { return x == ChineseSimplified || x == ChineseTraditional }
	return l == other || (chinese(l) && chinese(other))
}

// DetectionLimit is how much of a text detection reads.
const DetectionLimit = 600

// Detect returns the language text is written in, "" when it can't tell.
// Short strings lean on the script since the recognizer has little to go
// on. Chinese without a character that belongs to one script only, such
// as 你好, is preferredChinese.
func Detect(text string, preferredChinese Language) Language {
	// The first few hundred characters say what language a text is in;
	// reading a whole article would only make a long selection slower.
	trimmed := strings.TrimSpace(prefix(text, DetectionLimit+64))
	trimmed = prefix(trimmed, DetectionLimit)
	if trimmed == "" {
		return ""
	}
	if l := detectByScript(trimmed, preferredChinese); l != "" {
		return l
	}
	codes := make([]string, len(All))
	for i, l := range All {
		codes[i] = string(l)
	}
	l, _ := Parse(mac.DominantLanguage(trimmed, codes))
	return l
}

// prefix is s cut to n runes.
func prefix(s string, n int) string {
	i := 0
	for pos := range s {
		if i == n {
			return s[:pos]
		}
		i++
	}
	return s
}

// detectByScript: kana means Japanese, Hangul means Korean, and Han
// without either means Chinese, which the recognizer gets wrong on short
// strings.
func detectByScript(text string, preferredChinese Language) Language {
	var han, kana, hangul, letters int
	for _, r := range text {
		switch {
		case r >= 0x3040 && r <= 0x30FF:
			kana++
		case r >= 0xAC00 && r <= 0xD7AF, r >= 0x1100 && r <= 0x11FF:
			hangul++
		case r >= 0x4E00 && r <= 0x9FFF, r >= 0x3400 && r <= 0x4DBF:
			han++
		default:
			if unicode.IsLetter(r) {
				letters++
			}
		}
	}
	cjk := han + kana + hangul
	if cjk == 0 || cjk*2 < letters {
		return ""
	}
	if kana > 0 {
		return Japanese
	}
	if hangul > 0 {
		return Korean
	}
	// The recognizer is sure (1.0) when a character exists in one script
	// only and guesses otherwise; a guess goes to the user's own Chinese.
	h := mac.LanguageHypotheses(text, []string{string(ChineseSimplified), string(ChineseTraditional)}, 2)
	if h[string(ChineseTraditional)] >= 0.9 {
		return ChineseTraditional
	}
	if h[string(ChineseSimplified)] >= 0.9 {
		return ChineseSimplified
	}
	if preferredChinese.SameFamily(ChineseSimplified) {
		return preferredChinese
	}
	return ChineseSimplified
}

// Target is where text in detected goes under the two-language rule: text
// in the first language goes into the second, anything else into the
// first.
func Target(detected, first, second Language) Language {
	if detected == "" || !detected.SameFamily(first) {
		return first
	}
	return second
}

// PreferredChinese is the Chinese the user reads, of first and second,
// for text that could be either script.
func PreferredChinese(first, second Language) Language {
	for _, l := range []Language{first, second} {
		if l.SameFamily(ChineseSimplified) {
			return l
		}
	}
	return ChineseSimplified
}

// Resolve returns first and second as they are stored: when the new pair
// is one language twice, the one that moved takes its place and the other
// steps over to where it was, so the rule always has two places to go.
func Resolve(first, second, oldFirst, oldSecond Language) (Language, Language) {
	if first != second {
		return first, second
	}
	if first == oldFirst {
		return oldSecond, second
	}
	return first, oldFirst
}
