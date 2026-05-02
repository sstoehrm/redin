package text

// Inline-span style. Drives font/face selection and code-bg fill in the
// span-aware text renderer.
Span_Style :: enum u8 { Regular, Bold, Italic, Code }

// One inline span: a contiguous run of text rendered in a single style.
// Produced by the markdown parser. The span-aware text renderer that
// consumes these is added in a follow-up task; for now the markdown
// package draws spans via its own render path.
Span :: struct {
	style: Span_Style,
	text:  string,
}
