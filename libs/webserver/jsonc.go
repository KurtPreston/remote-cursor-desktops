package webserver

import "encoding/json"

// unmarshalJSONC parses JSON-with-comments (// and /* */) plus trailing commas
// into v. String literals are preserved, so a URI like "vscode-remote://..."
// inside a value is never mistaken for a comment.
func unmarshalJSONC(data []byte, v any) error {
	return json.Unmarshal(stripJSONC(data), v)
}

func stripJSONC(in []byte) []byte {
	out := make([]byte, 0, len(in))

	const (
		normal = iota
		inString
		inLineComment
		inBlockComment
	)
	state := normal
	var escaped bool

	for i := 0; i < len(in); i++ {
		c := in[i]
		var next byte
		if i+1 < len(in) {
			next = in[i+1]
		}

		switch state {
		case normal:
			switch {
			case c == '"':
				state = inString
				out = append(out, c)
			case c == '/' && next == '/':
				state = inLineComment
				i++
			case c == '/' && next == '*':
				state = inBlockComment
				i++
			default:
				out = append(out, c)
			}
		case inString:
			out = append(out, c)
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				state = normal
			}
		case inLineComment:
			if c == '\n' {
				state = normal
				out = append(out, c)
			}
		case inBlockComment:
			if c == '*' && next == '/' {
				state = normal
				i++
			}
		}
	}

	return stripTrailingCommas(out)
}

// stripTrailingCommas removes commas that immediately precede a closing } or ]
// (ignoring whitespace), outside of string literals.
func stripTrailingCommas(in []byte) []byte {
	out := make([]byte, 0, len(in))
	inString := false
	var escaped bool

	for i := 0; i < len(in); i++ {
		c := in[i]
		if inString {
			out = append(out, c)
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				inString = false
			}
			continue
		}
		if c == '"' {
			inString = true
			out = append(out, c)
			continue
		}
		if c == ',' {
			j := i + 1
			for j < len(in) && (in[j] == ' ' || in[j] == '\t' || in[j] == '\n' || in[j] == '\r') {
				j++
			}
			if j < len(in) && (in[j] == '}' || in[j] == ']') {
				continue // drop the trailing comma
			}
		}
		out = append(out, c)
	}
	return out
}
