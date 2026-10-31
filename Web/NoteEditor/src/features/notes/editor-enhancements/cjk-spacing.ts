export type SpacedInsertion = { from: number; to: number; insert: string; cursor: number };

/** CJK 表意文字：扩展 A、基本区、兼容区。全角标点与中日韩标点不在其中，因此标点两侧不会补空格。 */
const CJK_IDEOGRAPH = /[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/;
/**
 * 参与留白的「非中文」字符：任意语言的字母或数字（英文、重音字母、中文语境下的阿拉伯数字等）。
 * 空串、标点、空白都不匹配，所以「中文，」「中文 abc」这类位置不会再补一个空格。
 */
const NON_CJK_WORD = /[\p{L}\p{N}]/u;

/** 单个字符是否为中文表意文字；空串视为否。 */
function isCjkIdeograph(char: string): boolean {
	return CJK_IDEOGRAPH.test(char);
}

/** 单个字符是否为不属于中文的字母或数字；空串、标点、空白都视为否。 */
function isNonCjkWord(char: string): boolean {
	return !CJK_IDEOGRAPH.test(char) && NON_CJK_WORD.test(char);
}

/** 相邻两字符之间是否需要补一个空格：一侧是中文表意文字，另一侧是非中文的字母或数字。 */
function needsSpacing(left: string, right: string): boolean {
	if (isCjkIdeograph(left)) return isNonCjkWord(right);
	return isCjkIdeograph(right) && isNonCjkWord(left);
}

/**
 * 计算一次键盘输入真正要写入的内容：中文紧邻字母数字时补一个空格。
 * 无需补空格时返回 null，由 CodeMirror 走默认插入（保留其光标与选区处理）。
 */
export function spaceTypedInsertion(doc: string, from: number, to: number, typed: string): SpacedInsertion | null {
	if (!typed) return null;
	const leading = needsSpacing(doc[from - 1] ?? '', typed[0]) ? ' ' : '';
	const trailing = needsSpacing(typed[typed.length - 1], doc[to] ?? '') ? ' ' : '';
	if (!leading && !trailing) return null;
	return {
		from,
		to,
		insert: `${leading}${typed}${trailing}`,
		// 光标停在输入内容之后、尾随空格之前，继续输入时才不会与空格叠在一起。
		cursor: from + leading.length + typed.length,
	};
}
