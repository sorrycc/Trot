package ocr

import "testing"

func TestJoinLines(t *testing.T) {
	cases := []struct {
		lines []string
		want  string
	}{
		{[]string{"The quick brown", "fox jumps over", "the lazy dog"}, "The quick brown fox jumps over the lazy dog"},
		{[]string{"敏捷的棕色狐狸", "跳过了懒狗"}, "敏捷的棕色狐狸跳过了懒狗"},
		{[]string{"First sentence.", "Second one"}, "First sentence.\nSecond one"},
		{[]string{"第一句。", "第二句"}, "第一句。\n第二句"},
		{[]string{"Title:", "body"}, "Title:\nbody"},
		{[]string{"", "  ", "only"}, "only"},
		{nil, ""},
		{[]string{"안녕하세요", "세계"}, "안녕하세요 세계"},
		{[]string{"Hello", "世界"}, "Hello世界"},
		{[]string{"世界", "Hello"}, "世界Hello"},
	}
	for _, c := range cases {
		if got := JoinLines(c.lines); got != c.want {
			t.Errorf("JoinLines(%q) = %q, want %q", c.lines, got, c.want)
		}
	}
}
