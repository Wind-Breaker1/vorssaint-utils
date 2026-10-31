/**
 * 预览与编辑器滚动同步的映射工具。
 *
 * 预览渲染时会给每个块级元素标注 `data-source-line`（源码行号，1 基，与编辑器行号一致）。
 * 编辑器把「视口顶部对应的源码行」上报过来，这里把行号映射成预览的滚动位移：
 * 以块级元素为锚点做线性插值，块之间连续、块内部平滑，不会像纯比例同步那样累积漂移。
 */
export const SOURCE_LINE_ATTRIBUTE = 'data-source-line';

export type SourceAnchor = { line: number; top: number };

/** 读取元素上的源码行号；缺失或非法时返回 null。 */
export function parseSourceLine(value: string | null | undefined): number | null {
	if (!value) return null;
	const line = Number(value);
	return Number.isFinite(line) ? line : null;
}

/**
 * 归一化锚点：按行号升序、同一行只保留最内层元素，再剔除位置非递增的锚点。
 * 嵌套结构（如 `ul` 与其首个 `li`）会落在同一行，保留后者位置更精确；
 * 非递增（折叠内容、负外边距等）会让插值倒退，直接丢弃。
 */
export function normalizeAnchors(anchors: SourceAnchor[]): SourceAnchor[] {
	const sorted = [...anchors].sort((left, right) => left.line - right.line);
	const deduped: SourceAnchor[] = [];
	for (const anchor of sorted) {
		if (deduped.length && deduped[deduped.length - 1].line === anchor.line) deduped[deduped.length - 1] = anchor;
		else deduped.push(anchor);
	}
	const monotonic: SourceAnchor[] = [];
	for (const anchor of deduped) {
		if (!monotonic.length || anchor.top > monotonic[monotonic.length - 1].top) monotonic.push(anchor);
	}
	return monotonic;
}

/** 把源码行号（可含小数）映射为预览滚动位移；无锚点时返回 null。 */
export function offsetForSourceLine(anchors: SourceAnchor[], line: number): number | null {
	if (!anchors.length) return null;
	const first = anchors[0];
	// 首个块之前（文档开头的空行）停在预览顶部：标题自带 margin-top，按锚点对齐会先下移一截。
	if (line <= first.line) return 0;
	const last = anchors[anchors.length - 1];
	if (line >= last.line) return last.top;
	for (let index = anchors.length - 1; index >= 0; index -= 1) {
		if (anchors[index].line > line) continue;
		const current = anchors[index];
		const next = anchors[index + 1];
		if (!next) return current.top;
		const span = next.line - current.line;
		const ratio = span <= 0 ? 0 : (line - current.line) / span;
		return current.top + ratio * (next.top - current.top);
	}
	return first.top;
}

/** 采集预览容器内的锚点：位置换算成相对滚动内容的偏移，供 scrollTop 直接使用。 */
export function collectSourceAnchors(container: HTMLElement): SourceAnchor[] {
	const containerTop = container.getBoundingClientRect().top - container.scrollTop;
	const anchors: SourceAnchor[] = [];
	for (const element of container.querySelectorAll<HTMLElement>(`[${SOURCE_LINE_ATTRIBUTE}]`)) {
		const line = parseSourceLine(element.getAttribute(SOURCE_LINE_ATTRIBUTE));
		if (line === null) continue;
		anchors.push({ line, top: element.getBoundingClientRect().top - containerTop });
	}
	return normalizeAnchors(anchors);
}
