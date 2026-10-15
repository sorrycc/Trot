//go:build darwin

package mac

// DominantLanguage is the language NaturalLanguage recognizes text in,
// among constraints, as BCP 47 codes such as "en" or "zh-Hans"; "" when it
// can't tell.
func DominantLanguage(text string, constraints []string) string {
	var lang string
	withPool(func() {
		r := recognizer(text, constraints)
		lang = goString(send(r, "dominantLanguage"))
	})
	if lang == "und" {
		return ""
	}
	return lang
}

// LanguageHypotheses are the likelihoods of the most likely languages of
// text, among constraints, by code.
func LanguageHypotheses(text string, constraints []string, maximum int) map[string]float64 {
	out := map[string]float64{}
	withPool(func() {
		r := recognizer(text, constraints)
		dict := send(r, "languageHypothesesWithMaximum:", uintptr(maximum))
		for _, key := range arrayItems(send(dict, "allKeys")) {
			out[goString(key)] = msgFloat(send(dict, "objectForKey:", uintptr(key)), sel("doubleValue"))
		}
	})
	return out
}

func recognizer(text string, constraints []string) id {
	r := send(send(send(class("NLLanguageRecognizer"), "alloc"), "init"), "autorelease")
	if len(constraints) > 0 {
		var codes []id
		for _, c := range constraints {
			codes = append(codes, nsString(c))
		}
		send(r, "setLanguageConstraints:", uintptr(nsArray(codes...)))
	}
	send(r, "processString:", uintptr(nsString(text)))
	return r
}
