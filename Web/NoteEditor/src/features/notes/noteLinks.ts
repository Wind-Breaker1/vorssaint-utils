/** 正文里指向另一篇笔记的一条内部链接；三个字段都能直接从链接文本读出，不必查库。 */
export type NoteLinkRef = {
	/** 目标笔记 id，已统一为小写。 */
	id: string;
	/** 链接锚定的小节标题；未指定小节时为 null。 */
	heading: string | null;
	/** 链接显示名，取自 `|` 之前的部分。 */
	label: string;
};

/**
 * 编辑器补全写入的规范内部链接：`[[显示名|<uuid>(#标题)?]]`。
 * 与 MarkdownEditor 的补全格式保持一致，`|` 是必需分隔符。
 */
const noteLinkPattern = /\[\[([^|\]\n]*)\|([0-9a-f-]{36})(?:#([^|\]]+))?\]\]/gi;

/**
 * 扫描正文，提取当前笔记指向其他笔记的内部链接。
 * 同一目标只保留首次出现；手打的 `[[标题]]` 不识别。
 * 只回传正文里写了什么，是否过滤自引用由调用方决定。
 */
export function extractNoteLinks(content: string): NoteLinkRef[] {
	const links = new Map<string, NoteLinkRef>();

	for (const match of content.matchAll(noteLinkPattern)) {
		const id = match[2].toLowerCase();
		if (links.has(id)) continue;
		links.set(id, { id, heading: match[3] ?? null, label: match[1].trim() });
	}
	return [...links.values()];
}
