type TableEdit = { from: number; to: number; insert: string; cursor: number };

/** 忽略转义和行内代码里的竖线，只计算 Markdown 表格分隔符。 */
function cells(line: string): string[] {
	const parts: string[] = [];
	let start = 0;
	let codeTicks = 0;
	for (let index = 0; index < line.length; index += 1) {
		if (line[index] === '\\') {
			index += 1;
			continue;
		}
		if (line[index] === '`') {
			let end = index + 1;
			while (line[end] === '`') end += 1;
			const count = end - index;
			if (!codeTicks) codeTicks = count;
			else if (count === codeTicks) codeTicks = 0;
			index = end - 1;
		} else if (line[index] === '|' && !codeTicks) {
			parts.push(line.slice(start, index).trim());
			start = index + 1;
		}
	}
	parts.push(line.slice(start).trim());
	if (parts.length > 1 && !parts[0]) parts.shift();
	if (parts.length > 1 && !parts[parts.length - 1]) parts.pop();
	return parts;
}

type TableContext = { lines: string[]; start: number; end: number; row: number; columns: number; from: number };

/** 识别光标所在表格，忽略围栏代码里的表格文本。 */
function tableAtCursor(source: string, cursor: number): TableContext | null {
	const lines = source.split('\n');
	const row = source.slice(0, cursor).split('\n').length - 1;
	let fence: { char: string; count: number } | null = null;
	for (let index = 0; index < lines.length - 1; index += 1) {
		const marker = lines[index].match(/^ {0,3}(`{3,}|~{3,})/);
		if (marker) {
			if (!fence) fence = { char: marker[1][0], count: marker[1].length };
			else if (marker[1][0] === fence.char && marker[1].length >= fence.count) fence = null;
			continue;
		}
		if (fence || !lines[index].includes('|')) continue;
		const header = cells(lines[index]);
		const separator = cells(lines[index + 1]);
		if (header.length !== separator.length || !separator.every((cell) => /^:?-+:?$/.test(cell))) continue;
		let end = index + 2;
		while (end < lines.length && lines[end].trim() && lines[end].includes('|')) end += 1;
		if (row < index || row >= end) {
			index = end - 1;
			continue;
		}
		const from = lines.slice(0, index).reduce((offset, line) => offset + line.length + 1, 0);
		return { lines, start: index, end, row, columns: header.length, from };
	}
	return null;
}

export function isMarkdownTableAtCursor(source: string, cursor: number): boolean {
	return tableAtCursor(source, cursor) !== null;
}

/** 在光标所在表格末尾增加一列，同时更新表头、分隔行和所有正文行。 */
export function addMarkdownTableColumn(source: string, cursor: number): TableEdit | null {
	const table = tableAtCursor(source, cursor);
	if (!table) return null;
	const { lines, start, end, columns, from } = table;
	const original = lines.slice(start, end).join('\n');
	const rows = lines.slice(start, end).map((line, offset) => {
		const values = cells(line).slice(0, columns);
		while (values.length < columns) values.push('');
		values.push(offset === 0 ? '标题' : offset === 1 ? '---' : '');
		return `${line.match(/^\s*/)?.[0] ?? ''}| ${values.join(' | ')} |`;
	});
	const insert = rows.join('\n');
	return { from, to: from + original.length, insert, cursor: from + rows[0].lastIndexOf('标题') };
}

/** 在当前正文行后插入空行；表头或分隔行中则在分隔行后插入。 */
export function addMarkdownTableRow(source: string, cursor: number): TableEdit | null {
	const table = tableAtCursor(source, cursor);
	if (!table) return null;
	const { lines, start, row, columns } = table;
	const target = Math.max(start + 1, row);
	const from = lines.slice(0, target + 1).join('\n').length;
	const indent = lines[start].match(/^\s*/)?.[0] ?? '';
	const insert = `\n${indent}| ${Array(columns).fill('').join(' | ')} |`;
	return { from, to: from, insert, cursor: from + 1 + indent.length + 2 };
}
