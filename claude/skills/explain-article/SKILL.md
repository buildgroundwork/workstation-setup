---
name: explain-article
description: Explains a technical article, paper, or blog post to a smart reader who isn't an expert in its field, as a plain-language summary, a glossary of the terms colleagues will use, and what experts are likely to debate. Use when Adam asks to "summarize this article", "explain this paper", "help me understand this post", or gives a URL to summarize, especially when he says he isn't an expert in the subject.
---

# Explain article

Adam reads technical articles (AI interpretability research, for example) where his colleagues know far more than he does. He isn't trying to quote them. He wants general fluency: enough grasp of the concepts to follow the conversation and join it.

## Read the whole article

WebFetch truncates long pages and ends with a note giving an `offset` to continue from. Keep fetching from that offset until the full text is covered; a long article can take several fetches. Never summarize from the first chunk alone.

## Calibrate to the reader

Write for someone smart who isn't a subject-matter expert. Define jargon rather than avoiding it, since those are the words he'll hear. Use concrete examples from the article itself.

## Output

Keep the answer in chat (no doc, artifact, or file) unless he asks for one. Use this shape:

1. **Summary**: two or three short plain-language paragraphs covering the background (what the field believed, or the problem being addressed), what the article claims or finds, and why it matters.
2. **Glossary**: a bulleted list of the five to eight key terms he's likely to hear colleagues use, each with a one- or two-sentence plain definition and, where useful, how the article relates to it.
3. **What's being debated**: a short paragraph on why the article might be contentious or interesting to experts: what established view it pushes on or supports, and what people will likely argue about.

Keep caveats short. Flag a specific number only when it came through a lossy path, such as WebFetch's summarizing model. Adam doesn't plan to quote these articles, so don't belabor precision.

## Example

For Goodfire's "Neural Networks Are Already Clean" (https://already-clean.goodfire.com/), the glossary covered interpretability, neuron, monosemantic vs. polysemantic, superposition, sparse autoencoders / dictionary learning, features, and circuits. The debate section explained that the article challenges the widely held premise that neurons are a mess, so we need SAEs to find meaningful features.
