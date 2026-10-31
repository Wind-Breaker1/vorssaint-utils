import { continueMarkdownListItem } from './list';

export type CalloutInsertion = { from: number; to: number; insert: string; cursor: number };
export type CalloutLineEdit = { from: number; to: number; insert: string; cursor: number };

/** 判断光标所在引用块是否是 Callout，并返回该行信息。 */
function getCalloutLine(
	value: string,
	position: number,
): { lineStart: number; lineEnd: number; line: string; prefix: string; inFence: boolean } | null {
	const lineStart = value.lastIndexOf('\n', Math.max(0, position - 1)) + 1;
	const lineEndIndex = value.indexOf('\n', position);
	const lineEnd = lineEndIndex === -1 ? value.length : lineEndIndex;
	const line = value.slice(lineStart, lineEnd);
	const prefixMatch = line.match(/^(\s*>\s?)/);
	if (!prefixMatch) return null;

	const lines = value.split('\n');
	const currentLine = value.slice(0, lineStart).split('\n').length - 1;
	const isCalloutHeader = (text: string): boolean => /^\s*>\s*\[![a-z-]+\]/i.test(text);
	let start = currentLine;
	while (start > 0 && /^\s*>/.test(lines[start - 1])) start -= 1;
	if (!isCalloutHeader(lines[start])) return null;
	let fence: string | null = null;
	for (const quotedLine of lines.slice(start + 1, currentLine + 1)) {
		const content = quotedLine.replace(/^\s*> ?/, '');
		const marker = content.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
		if (!marker) continue;
		if (!fence) fence = marker[1];
		else if (marker[1][0] === fence[0] && marker[1].length >= fence.length && !marker[2].trim()) fence = null;
	}
	return { lineStart, lineEnd, line, prefix: prefixMatch[1], inFence: fence !== null };
}

/** Callout 内回车：正文续写引用，空引用行一次回车退出，避免多按一次并误删两行。 */
export function continueCalloutLine(value: string, position: number): CalloutLineEdit | null {
	const current = getCalloutLine(value, position);
	if (!current || position < current.lineStart + current.prefix.length) return null;

	const content = current.line.slice(current.prefix.length);
	const contentStart = current.lineStart + current.prefix.length;
	const column = position - contentStart;
	if (!current.inFence) {
		const emptyItem = content.match(/^(\s*)([-*+]|\d+[.)])\s*$/);
		if (emptyItem && position === current.lineEnd) {
			// 空列表项先退出列表，保留提示框前缀；子列表先退回上一级缩进。
			const insert = emptyItem[1] ? `${emptyItem[1].replace(/(?:\t| {1,4})$/, '')}${emptyItem[2]} ` : '';
			return { from: contentStart, to: current.lineEnd, insert, cursor: contentStart + insert.length };
		}
		const next = continueMarkdownListItem(content, column);
		if (next) {
			return {
				from: contentStart + next.from,
				to: contentStart + next.to,
				insert: next.insert.replace('\n', `\n${current.prefix}`),
				cursor: contentStart + next.cursor + current.prefix.length,
			};
		}
	}
	if (position !== current.lineEnd) return null;
	if (!content.trim() && !current.inFence) {
		// 需要保留一个真正的 Markdown 空行，避免后续无引用前缀的文字被解析成引用块的懒续行。
		return { from: current.lineStart, to: current.lineEnd, insert: '\n', cursor: current.lineStart + 1 };
	}
	return {
		from: position,
		to: position,
		insert: `\n${current.prefix}`,
		cursor: position + current.prefix.length + 1,
	};
}

/** 在引用续行中插入 Callout 时先结束现有引用，避免产生嵌套 Callout。 */
export function buildCalloutInsertion(
	value: string,
	selectionFrom: number,
	selectionTo: number,
	type: string,
	title = '标题',
): CalloutInsertion {
	const lineStart = value.lastIndexOf('\n', Math.max(0, selectionFrom - 1)) + 1;
	const lineEndIndex = value.indexOf('\n', selectionFrom);
	const lineEnd = lineEndIndex === -1 ? value.length : lineEndIndex;
	const line = value.slice(lineStart, lineEnd);
	const callout = title ? `> [!${type}] ${title}\n> ` : `> [!${type}]\n> `;
	const isQuoteLine = (text: string): boolean => /^\s*>/.test(text);
	const isCalloutHeader = (text: string): boolean => /^\s*>\s*\[![a-z-]+\]/i.test(text);

	// 光标位于已有 Callout 内时，保留当前行并把新 Callout 放到整个引用块之后，
	// 避免覆盖空的引用续行或把新 Callout 插入旧 Callout 内部。
	if (isQuoteLine(line)) {
		const lines = value.split('\n');
		const currentLine = value.slice(0, selectionFrom).split('\n').length - 1;
		let start = currentLine;
		while (start > 0 && isQuoteLine(lines[start - 1])) start -= 1;
		if (isCalloutHeader(lines[start])) {
			let end = start;
			while (end + 1 < lines.length && isQuoteLine(lines[end + 1])) end += 1;
			const blockEnd = lines.slice(0, end + 1).join('\n').length;
			const insert = `\n\n${callout}`;
			return { from: blockEnd, to: blockEnd, insert, cursor: blockEnd + insert.length };
		}
	}

	if (selectionFrom === selectionTo && /^\s*(?:>\s*)+$/.test(line)) {
		const insert = lineStart === 0 ? callout : `\n${callout}`;
		return { from: lineStart, to: lineEnd, insert, cursor: lineStart + insert.length };
	}
	return { from: selectionFrom, to: selectionTo, insert: callout, cursor: selectionFrom + callout.length };
}
