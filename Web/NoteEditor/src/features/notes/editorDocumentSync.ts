import { Annotation, ChangeSet, Transaction, type EditorState } from '@codemirror/state';

export const externalDocumentSync = Annotation.define<boolean>();

/** Reconcile an external value without adding a user edit to the undo stack. */
export function externalDocumentTransaction(state: EditorState, value: string): Transaction | null {
	const selection = state.selection.main;
	const sync = syncDocumentChange(state.doc.toString(), value, { anchor: selection.anchor, head: selection.head });
	return sync.empty
		? null
		: state.update({
				changes: [sync.change],
				selection: sync.selection,
				annotations: [externalDocumentSync.of(true), Transaction.addToHistory.of(false)],
			});
}

export type DocumentSyncChange = { from: number; to: number; insert: string };
export type EditorSelection = { anchor: number; head: number };

/**
 * 计算把 current 改写为 next 所需的最小替换区间（掐掉公共前后缀）。
 *
 * 外部值回写编辑器时必须用最小替换，而不是 `{from: 0, to: 文档长度}` 的整篇替换：
 * CodeMirror 会把落在被替换区间内的光标映射到插入文本的开头，整篇替换就等于把光标
 * 拉回位置 0（文档第一行），用户接着输入的内容就会跑到第一行去。
 */
export function minimalDocumentChange(current: string, next: string): DocumentSyncChange {
	let prefix = 0;
	const maxPrefix = Math.min(current.length, next.length);
	while (prefix < maxPrefix && current[prefix] === next[prefix]) prefix += 1;
	let suffix = 0;
	while (
		suffix < current.length - prefix &&
		suffix < next.length - prefix &&
		current[current.length - suffix - 1] === next[next.length - suffix - 1]
	)
		suffix += 1;
	return { from: prefix, to: current.length - suffix, insert: next.slice(prefix, next.length - suffix) };
}

/**
 * 用最小替换把 current 改写成 next，并把选区一起映射过去，避免光标跳位。
 * 返回的 change 为空（from === to 且 insert 为空）说明两者本就一致，调用方可以跳过 dispatch。
 */
export function syncDocumentChange(
	current: string,
	next: string,
	selection: EditorSelection,
): { change: DocumentSyncChange; selection: EditorSelection; empty: boolean } {
	const change = minimalDocumentChange(current, next);
	const changes = ChangeSet.of([change], current.length);
	return {
		change,
		selection: { anchor: changes.mapPos(selection.anchor), head: changes.mapPos(selection.head) },
		empty: change.from === change.to && change.insert.length === 0,
	};
}
