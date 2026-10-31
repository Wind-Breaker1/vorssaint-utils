export type ChildListItemDeletion = { from: number; to: number; cursor: number };
export type ListItemContinuation = { from: number; to: number; insert: string; cursor: number };
export type EmptyListItemExit = { from: number; to: number; insert?: string; cursor: number };
export type ListIndentEdit = { from: number; to: number; insert: string; cursor: number };

/** 缩进列表项时建立新的子列表；有序子列表从 1 重新开始。 */
export function indentMarkdownListItem(value: string, position: number): ListIndentEdit | null {
	const lineStart = value.lastIndexOf('\n', Math.max(0, position - 1)) + 1;
	const lineEndIndex = value.indexOf('\n', position);
	const lineEnd = lineEndIndex === -1 ? value.length : lineEndIndex;
	const line = value.slice(lineStart, lineEnd);
	const match = line.match(/^(\s*)([-*+]|\d+[.)])(\s+)(.*)$/);
	if (!match) return null;
	const [, , marker, spacing, content] = match;
	const nextMarker = /^\d+[.)]$/.test(marker) ? `1${marker[marker.length - 1]}` : marker;
	const replacement = `\t${nextMarker}${spacing}${content}`;
	return { from: lineStart, to: lineEnd, insert: replacement, cursor: lineStart + replacement.length };
}

/** 退出空的一级列表项时仅移除标记，保留当前空行。 */
export function exitEmptyRootListItem(value: string, position: number): EmptyListItemExit | null {
	const lineStart = value.lastIndexOf('\n', Math.max(0, position - 1)) + 1;
	const lineEndIndex = value.indexOf('\n', position);
	const lineEnd = lineEndIndex === -1 ? value.length : lineEndIndex;
	const line = value.slice(lineStart, lineEnd);
	if (position !== lineEnd) return null;
	const match = line.match(/^(\s*)([-*+]|\d+[.)])(\s*)$/);
	if (!match) return null;
	const indent = match[1];
	if (indent.length === 0) return { from: lineStart, to: lineEnd, insert: '', cursor: lineStart };
	// 二级空项再次回车：退出当前子列表，在最近的上级有序列表继续编号。
	const before = value.slice(0, lineStart);
	const lines = before.split('\n');
	const parentIndentWidth = indent.replace(/\t/g, '    ').length > 0 ? Math.max(0, indent.replace(/\t/g, '    ').length - 4) : 0;
	let parentMarker: RegExpMatchArray | null = null;
	for (let index = lines.length - 1; index >= 0; index -= 1) {
		const candidate = lines[index].match(/^(\s*)(\d+)([.)])(\s+).*/);
		if (candidate && candidate[1].replace(/\t/g, '    ').length <= parentIndentWidth) {
			parentMarker = candidate;
			break;
		}
	}
	// 行尾为空时，上面的宽松 Markdown 行匹配可能没有正文；仍按最近的根级编号退出。
	if (!parentMarker) {
		const roots = [...before.matchAll(/(?:^|\n)(\d+)([.)])\s/g)];
		const root = roots.at(-1);
		if (root) parentMarker = ['', root[1], root[2]] as unknown as RegExpMatchArray;
	}
	if (!parentMarker) {
		for (let index = lines.length - 1; index >= 0; index -= 1) {
			const candidate = lines[index].match(/^(\s*)(\d+)([.)])/);
			if (candidate && candidate[1].replace(/\t/g, '    ').length < indent.replace(/\t/g, '    ').length) {
				parentMarker = candidate;
				break;
			}
		}
	}
	if (!parentMarker) return { from: lineStart, to: lineEnd, insert: '', cursor: lineStart };
	const next = Number.parseInt(parentMarker[2], 10) + 1;
	const replacement = `${parentMarker[1]}${next}${parentMarker[3]} `;
	return { from: lineStart, to: lineEnd, insert: replacement, cursor: lineStart + replacement.length };
}

/** 续写非空列表项，始终生成紧凑的下一项。 */
export function continueMarkdownListItem(value: string, position: number): ListItemContinuation | null {
	const lineStart = value.lastIndexOf('\n', Math.max(0, position - 1)) + 1;
	const lineEndIndex = value.indexOf('\n', position);
	const lineEnd = lineEndIndex === -1 ? value.length : lineEndIndex;
	const line = value.slice(lineStart, lineEnd);
	const match = line.match(/^(\s*)([-*+]|\d+[.)])(\s+)(.*)$/);
	if (!match) return null;

	const [, indent, marker, spacing, content] = match;
	const contentStart = indent.length + marker.length + spacing.length;
	const column = position - lineStart;
	if (!content.trim() || column < contentStart) return null;

	const nextMarker = /^\d+[.)]$/.test(marker) ? `${Number.parseInt(marker, 10) + 1}${marker[marker.length - 1]}` : marker;
	const trailingContent = line.slice(column);
	const insert = `\n${indent}${nextMarker} ${trailingContent}`;
	return { from: position, to: lineEnd, insert, cursor: position + 1 + indent.length + nextMarker.length + 1 };
}

/** 计算删除二级列表项标记时的整行删除范围。 */
export function childListItemDeletion(
	value: string,
	head: number,
	selectionFrom: number,
	selectionTo: number,
	direction: 'backward' | 'forward',
): ChildListItemDeletion | null {
	const lineStart = value.lastIndexOf('\n', Math.max(0, head - 1)) + 1;
	const lineEndIndex = value.indexOf('\n', head);
	const lineEnd = lineEndIndex === -1 ? value.length : lineEndIndex;
	const marker = value.slice(lineStart, lineEnd).match(/^(\t)(?:[-*+]|\d+[.)])\s*/);
	if (!marker) return null;

	const markerStart = lineStart + marker[1].length;
	const markerEnd = lineStart + marker[0].length;
	const touchesMarker =
		selectionFrom === selectionTo
			? head === (direction === 'backward' ? markerEnd : markerStart)
			: selectionFrom < markerEnd && selectionTo > markerStart;
	if (!touchesMarker) return null;

	if (lineEndIndex !== -1) {
		return { from: lineStart, to: lineEnd + 1, cursor: Math.max(0, lineStart - 1) };
	}
	const from = lineStart === 0 ? lineStart : lineStart - 1;
	return { from, to: lineEnd, cursor: from };
}
