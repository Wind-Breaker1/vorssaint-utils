export type InlineFormatEdit = { from: number; to: number; insert: string; anchor: number; head: number };

/** 返回同一行中完整包裹选区的一对格式标记。 */
function enclosingMarkers(
	value: string,
	selectionFrom: number,
	selectionTo: number,
	marker: string,
): { opening: number; closing: number } | null {
	const lineStart = value.lastIndexOf('\n', selectionFrom - 1) + 1;
	const nextLineBreak = value.indexOf('\n', selectionTo);
	const lineEnd = nextLineBreak === -1 ? value.length : nextLineBreak;
	const markerCharacter = marker[0];
	const positions: number[] = [];

	for (let position = lineStart; position <= lineEnd - marker.length; position += 1) {
		if (value.slice(position, position + marker.length) !== marker) continue;
		if (value[position - 1] === markerCharacter || value[position + marker.length] === markerCharacter) continue;
		positions.push(position);
	}

	for (let index = positions.length - 2; index >= 0; index -= 1) {
		const opening = positions[index];
		const closing = positions[index + 1];
		if (opening + marker.length <= selectionFrom && selectionTo <= closing) return { opening, closing };
	}
	return null;
}

/** 模拟 Obsidian 的行内格式切换：包裹选区、取消既有包裹，或在空选区插入成对标记。 */
export function toggleInlineFormat(value: string, selectionFrom: number, selectionTo: number, marker: string): InlineFormatEdit {
	const selected = value.slice(selectionFrom, selectionTo);
	if (selected.startsWith(marker) && selected.endsWith(marker) && selected.length >= marker.length * 2) {
		const content = selected.slice(marker.length, -marker.length);
		return {
			from: selectionFrom,
			to: selectionTo,
			insert: content,
			anchor: selectionFrom,
			head: selectionFrom + content.length,
		};
	}

	const hasLeadingMarker = value.slice(selectionFrom - marker.length, selectionFrom) === marker;
	const hasTrailingMarker = value.slice(selectionTo, selectionTo + marker.length) === marker;
	if (hasLeadingMarker && hasTrailingMarker) {
		const from = selectionFrom - marker.length;
		return { from, to: selectionTo + marker.length, insert: selected, anchor: from, head: from + selected.length };
	}

	const markers = enclosingMarkers(value, selectionFrom, selectionTo, marker);
	if (markers) {
		return {
			from: markers.opening,
			to: markers.closing + marker.length,
			insert: value.slice(markers.opening + marker.length, markers.closing),
			anchor: selectionFrom - marker.length,
			head: selectionTo - marker.length,
		};
	}

	if (selectionFrom === selectionTo) {
		return {
			from: selectionFrom,
			to: selectionTo,
			insert: `${marker}${marker}`,
			anchor: selectionFrom + marker.length,
			head: selectionFrom + marker.length,
		};
	}

	return {
		from: selectionFrom,
		to: selectionTo,
		insert: `${marker}${selected}${marker}`,
		anchor: selectionFrom + marker.length,
		head: selectionTo + marker.length,
	};
}
