// RFC822 -> the headers and the one text body worth showing. aerc's :pipe hands
// the whole message over stdin, MIME and all.
package main

import (
	"encoding/base64"
	"io"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net/mail"
	"regexp"
	"strings"
)

type Mail struct {
	From, To, Cc, Subject, Date, DeliveredTo string
	Body                                     string
	Raw                                      string
}

func (m Mail) headerBlock() string {
	var b strings.Builder
	for _, kv := range [][2]string{
		{"Subject", m.Subject}, {"From", m.From}, {"To", m.To},
		{"Cc", m.Cc}, {"Date", m.Date},
	} {
		if kv[1] != "" {
			b.WriteString(kv[0] + ": " + kv[1] + "\n")
		}
	}
	return strings.TrimRight(b.String(), "\n")
}

var wordDec = mime.WordDecoder{CharsetReader: func(_ string, r io.Reader) (io.Reader, error) {
	return r, nil // best effort: hand the bytes back and let utf-8 do what it can
}}

func decodeHeader(v string) string {
	if s, err := wordDec.DecodeHeader(v); err == nil {
		return s
	}
	return v
}

func ParseMail(raw []byte) (Mail, error) {
	msg, err := mail.ReadMessage(strings.NewReader(string(raw)))
	if err != nil {
		return Mail{}, err
	}
	h := msg.Header
	m := Mail{
		From:        decodeHeader(h.Get("From")),
		To:          decodeHeader(h.Get("To")),
		Cc:          decodeHeader(h.Get("Cc")),
		Subject:     decodeHeader(h.Get("Subject")),
		Date:        h.Get("Date"),
		DeliveredTo: h.Get("Delivered-To"),
	}
	plain, html := walk(msg.Header.Get("Content-Type"), h.Get("Content-Transfer-Encoding"), msg.Body, 0)
	body := plain
	if strings.TrimSpace(body) == "" {
		body = stripHTML(html)
	}
	m.Body = squeeze(body)
	return m, nil
}

// walk returns the best text/plain and text/html found anywhere in the tree.
func walk(ctype, cte string, r io.Reader, depth int) (plain, html string) {
	if depth > 8 {
		return "", ""
	}
	mt, params, err := mime.ParseMediaType(ctype)
	if err != nil {
		mt = "text/plain"
	}
	if strings.HasPrefix(mt, "multipart/") {
		boundary := params["boundary"]
		if boundary == "" {
			return "", ""
		}
		mr := multipart.NewReader(r, boundary)
		for {
			p, err := mr.NextPart()
			if err != nil {
				break
			}
			sp, sh := walk(p.Header.Get("Content-Type"),
				p.Header.Get("Content-Transfer-Encoding"), p, depth+1)
			// First plain part wins; html only fills a gap.
			if plain == "" && strings.TrimSpace(sp) != "" {
				plain = sp
			}
			if html == "" && strings.TrimSpace(sh) != "" {
				html = sh
			}
			p.Close()
		}
		return plain, html
	}
	if mt != "text/plain" && mt != "text/html" {
		return "", ""
	}
	body, err := io.ReadAll(decodeBody(cte, r))
	if err != nil {
		return "", ""
	}
	if mt == "text/html" {
		return "", string(body)
	}
	return string(body), ""
}

func decodeBody(cte string, r io.Reader) io.Reader {
	switch strings.ToLower(strings.TrimSpace(cte)) {
	case "quoted-printable":
		return quotedprintable.NewReader(r)
	case "base64":
		return base64.NewDecoder(base64.StdEncoding, newLineStripper(r))
	}
	return r
}

type lineStripper struct{ r io.Reader }

func newLineStripper(r io.Reader) io.Reader { return &lineStripper{r} }

func (l *lineStripper) Read(p []byte) (int, error) {
	n, err := l.r.Read(p)
	out := p[:0]
	for _, b := range p[:n] {
		if b != '\r' && b != '\n' {
			out = append(out, b)
		}
	}
	return len(out), err
}

var (
	// No backreference: RE2 has none, so each tag gets its own alternative.
	reDrop     = regexp.MustCompile(`(?is)<script\b[^>]*>.*?</script>|<style\b[^>]*>.*?</style>|<head\b[^>]*>.*?</head>|<!--.*?-->`)
	reBreak    = regexp.MustCompile(`(?i)<br\s*/?>|</p>|</div>|</tr>|</h[1-6]>|</li>`)
	reTag      = regexp.MustCompile(`(?s)<[^>]+>`)
	reSpaces   = regexp.MustCompile(`[ \t]+`)
	reIndent   = regexp.MustCompile(`\n[ \t]+`)
	reBlanks   = regexp.MustCompile(`\n{3,}`)
	reEntities = strings.NewReplacer(
		"&nbsp;", " ", "&amp;", "&", "&lt;", "<", "&gt;", ">",
		"&quot;", `"`, "&#39;", "'", "&apos;", "'", "&mdash;", "—", "&ndash;", "–")
)

func stripHTML(s string) string {
	s = reDrop.ReplaceAllString(s, " ")
	s = reBreak.ReplaceAllString(s, "\n")
	s = reTag.ReplaceAllString(s, " ")
	return reEntities.Replace(s)
}

func squeeze(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = reSpaces.ReplaceAllString(s, " ")
	s = reIndent.ReplaceAllString(s, "\n")
	return strings.TrimSpace(reBlanks.ReplaceAllString(s, "\n\n"))
}
