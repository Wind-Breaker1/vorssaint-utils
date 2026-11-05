import { readClipboardText, writeClipboardText } from '@/shared/clipboard';
import { ContextMenu, type ContextMenuItem } from '@/shared/components/ContextMenu';
import { createPortal } from 'react-dom';
import { addMarkdownTableColumn, addMarkdownTableRow, isMarkdownTableAtCursor } from '@/features/notes/editor-enhancements/table';
import { toast } from '@/shared/toast/toast';
import { forwardRef, useCallback, useEffect, useImperativeHandle, useLayoutEffect, useRef, useState } from 'react';
import { defaultKeymap, history, historyKeymap, indentMore, indentLess } from '@codemirror/commands';
import { bracketMatching, indentOnInput, indentUnit, syntaxTree, syntaxHighlighting, HighlightStyle } from '@codemirror/language';
import { markdown } from '@codemirror/lang-markdown';
import { EditorState, Prec } from '@codemirror/state';
import { EditorView, keymap, lineNumbers, highlightActiveLine } from '@codemirror/view';
import type { NoteCard } from '@/contracts';
import { tags } from '@lezer/highlight';
import { continueMarkdownListItem, exitEmptyRootListItem, indentMarkdownListItem } from '@/features/notes/editor-enhancements/list';
import { toggleInlineFormat } from '@/features/notes/editor-enhancements/inline-format';
import { spaceTypedInsertion } from '@/features/notes/editor-enhancements/cjk-spacing';
import { buildCalloutInsertion, continueCalloutLine } from '@/features/notes/editor-enhancements/callout';
import { externalDocumentSync, externalDocumentTransaction } from '@/features/notes/editorDocumentSync';
import {
	LINK_PICKER_CHROME,
	LINK_PICKER_GAP,
	LINK_PICKER_LIST_MAX,
	layoutLinkPicker,
	type LinkPickerAnchor,
} from '@/features/notes/linkPickerLayout';
import type { IconName } from '@/shared/components/Icon';
import { EmptyCard } from '@/shared/components/EmptyCard';
import { ScrollContainer } from '@/shared/components/ScrollContainer';

export type MarkdownLinkSuggestion = Pick<NoteCard, 'id' | 'title'>;
type LinkMatch = { from: number; to: number; query: string; targetId?: string; heading?: string };
type Props = {
	active?: boolean;
	documentKey: string;
	value: string;
	onChange: (value: string) => void;
	onAttachmentUpload?: (file: File) => Promise<string | null>;
	linkSuggestions?: MarkdownLinkSuggestion[];
	linkSuggestionsLoading?: boolean;
	onLinkQueryChange?: (query: string | null) => void;
	/** 上报编辑器视口顶部对应的源码行（含行内小数偏移），供右侧预览同步滚动。 */
	onScrollLine?: (line: number, edge?: 'top' | 'bottom') => void;
};
/** 仅暴露 NoteEditor 实际使用的方法，其余编辑动作由组件内部工具栏直接调用，不跨组件传递。 */
export type MarkdownEditorHandle = {
	insert: (text: string) => void;
	resume: () => void;
};
/** 弹层宽度（与样式里的 w-80 一致），用于把左边缘夹在容器内。 */
const LINK_PICKER_WIDTH = 320;
type LinkPickerStyle = { left: number; top: number; listMaxHeight: number };
const highlight = HighlightStyle.define([
	{ tag: tags.heading, color: 'var(--color-station-accent)', fontWeight: '700' },
	{ tag: [tags.link, tags.url], color: 'var(--color-station-info)', textDecoration: 'underline' },
	{ tag: tags.monospace, color: 'var(--color-station-warning)' },
	{ tag: tags.keyword, color: 'var(--color-station-focus)' },
	{ tag: [tags.string, tags.number, tags.bool], color: 'var(--color-station-success)' },
	{ tag: tags.comment, color: 'var(--color-station-subtle)', fontStyle: 'italic' },
]);
/** 工具栏「提示框」下拉里各类型的图标；note/tip/todo 复用已有语义图标。 */
const calloutIcons: Record<string, IconName> = {
	note: 'notes',
	info: 'info',
	tip: 'lightbulb',
	warning: 'warning',
	danger: 'danger',
	todo: 'tasks',
	example: 'property-list',
};

const editorTheme = EditorView.theme(
	{
		/* 高度撑满 host：否则 .cm-editor 按内容长高，.cm-scroller 没有确定视口，内部滚动不会触发。 */
		'&': {
			height: '100%',
			color: '#f4e9e1',
			backgroundColor: 'transparent',
			fontSize: '0.82rem',
		},
		'&.cm-focused': {
			outline: 'none',
		},
		'.cm-scroller': {
			fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
			lineHeight: '1.65',
			overflow: 'auto',
			scrollbarColor: 'rgba(157, 136, 125, 0.42) transparent',
		},
		'.cm-scroller::-webkit-scrollbar': {
			width: '8px',
			height: '8px',
		},
		'.cm-scroller::-webkit-scrollbar-thumb': {
			borderRadius: '999px',
			backgroundColor: 'rgba(157, 136, 125, 0.42)',
		},
		'.cm-content': {
			padding: '0.75rem 0.85rem 3rem',
			caretColor: '#f3a36f',
		},
		'.cm-line': {
			padding: '0 0.25rem',
		},
		'.cm-gutters': {
			color: '#9d887d',
			backgroundColor: 'transparent',
			border: '0',
		},
		'.cm-lineNumbers .cm-gutterElement': {
			minWidth: '2.25rem',
			padding: '0 0.5rem 0 0.25rem',
			textAlign: 'right',
		},
		'.cm-activeLine': {
			backgroundColor: 'rgba(200, 120, 85, 0.08)',
		},
		'.cm-activeLineGutter': {
			color: '#e8a47f',
			backgroundColor: 'rgba(200, 120, 85, 0.14)',
		},
		'&.cm-focused .cm-selectionBackground, .cm-selectionBackground': {
			backgroundColor: 'rgba(200, 120, 85, 0.32)',
		},
		'.cm-cursor, .cm-dropCursor': {
			borderLeftColor: '#f3a36f',
			borderLeftWidth: '2px',
		},
		'.cm-matchingBracket': {
			color: '#f4e9e1',
			backgroundColor: 'rgba(237, 186, 105, 0.2)',
			outline: '1px solid rgba(237, 186, 105, 0.5)',
		},
	},
	{ dark: true },
);

export const MarkdownEditor = forwardRef<MarkdownEditorHandle, Props>(function MarkdownEditor(
	{
		documentKey,
		active = true,
		value,
		onChange,
		onAttachmentUpload,
		linkSuggestions = [],
		linkSuggestionsLoading = false,
		onLinkQueryChange,
		onScrollLine,
	},
	ref,
): React.JSX.Element {
	const host = useRef<HTMLDivElement>(null);
	const rootRef = useRef<HTMLDivElement>(null);
	const [inTable, setInTable] = useState(false);
	const viewRef = useRef<EditorView | null>(null);
	const createStateRef = useRef<((content: string) => EditorState) | null>(null);
	const documentKeyRef = useRef(documentKey);
	const linkMatchRef = useRef<LinkMatch | null>(null);
	const linkSuggestionsRef = useRef(linkSuggestions);
	const suggestionsLoadingRef = useRef(linkSuggestionsLoading);
	suggestionsLoadingRef.current = linkSuggestionsLoading;
	const pendingInsertions = useRef(new Set<{ position: number; cancelled: boolean }>());
	const [linkSearch, setLinkSearch] = useState('');
	const [linkMatch, setLinkMatch] = useState<LinkMatch | null>(null);
	const [linkPickerAnchor, setLinkPickerAnchor] = useState<LinkPickerAnchor | null>(null);
	const [linkPickerStyle, setLinkPickerStyle] = useState<LinkPickerStyle | null>(null);
	const linkPickerRef = useRef<HTMLDivElement>(null);
	const linkListRef = useRef<HTMLDivElement>(null);
	const [selectedLinkIndex, setSelectedLinkIndex] = useState(0);
	const selectedLinkIndexRef = useRef(0);
	const onChangeRef = useRef(onChange);
	const onAttachmentUploadRef = useRef(onAttachmentUpload);
	const onLinkQueryChangeRef = useRef(onLinkQueryChange);
	const onScrollLineRef = useRef(onScrollLine);
	onChangeRef.current = onChange;
	onAttachmentUploadRef.current = onAttachmentUpload;
	onLinkQueryChangeRef.current = onLinkQueryChange;
	onScrollLineRef.current = onScrollLine;
	linkSuggestionsRef.current = linkSuggestions;
	selectedLinkIndexRef.current = selectedLinkIndex;
	function protectedSyntax(view: EditorView): boolean {
		for (let node = syntaxTree(view.state).resolveInner(view.state.selection.main.head, -1); node; node = node.parent!) {
			if (/Code|Link|URL|Image|Autolink/.test(node.name)) return true;
		}
		return false;
	}
	async function uploadFiles(files: File[], position?: number): Promise<void> {
		const view = viewRef.current;
		const upload = onAttachmentUploadRef.current;
		if (!view || !upload) return;
		const pending = { position: position ?? view.state.selection.main.head, cancelled: false };
		pendingInsertions.current.add(pending);
		try {
			for (const file of files) {
				if (pending.cancelled) break;
				const text = await upload(file);
				if (pending.cancelled || viewRef.current !== view) break;
				if (text) view.dispatch({ changes: { from: pending.position, insert: text + '\n' }, userEvent: 'input' });
			}
		} catch {
			toast('附件插入失败，请重试', { variant: 'error' });
		} finally {
			pendingInsertions.current.delete(pending);
		}
	}
	function findLinkMatch(view: EditorView): LinkMatch | null {
		const selection = view.state.selection.main;
		if (!selection.empty || protectedSyntax(view)) return null;
		const line = view.state.doc.lineAt(selection.head);
		const offset = selection.head - line.from;
		const before = line.text.slice(0, offset);
		const start = before.lastIndexOf('[[');
		if (start < 0) return null;
		const prefix = before.slice(start);
		if (/[\]\n]/.test(prefix)) return null;
		const remainder = line.text.slice(start);
		const closingOffset = remainder.indexOf(']]', Math.max(0, offset - start));
		const to = closingOffset >= 0 ? line.from + start + closingOffset + 2 : selection.head;
		const token = line.text.slice(start, Math.max(offset, to) - line.from);
        const canonical = token.match(/^\[\[([^|\]]*)\|([0-9a-f-]{36})(?:#([^\]]+))?/i);
        if (canonical) return {from:line.from+start,to,query:canonical[1],targetId:canonical[2],heading:canonical[3]};

		return { from: line.from + start, to, query: prefix.slice(2) };
	}
	/** 依据当前光标坐标重算弹层锚点；编辑器滚动后光标位置会变，需要跟着刷新。 */
	function positionLinkPicker(view: EditorView): void {
		const coords = linkMatchRef.current ? view.coordsAtPos(view.state.selection.main.head) : null;

		const hostRect = coords ? host.current?.getBoundingClientRect() : null;
		if (coords && hostRect) {
			// Portal 使用视口坐标，以光标为锚点，仅在窗口边缘避让。
			const below = coords.bottom + LINK_PICKER_GAP;
			setLinkPickerAnchor({
				left: Math.max(8, Math.min(coords.left, window.innerWidth - LINK_PICKER_WIDTH - 8)),
				below,
				above: coords.top - LINK_PICKER_GAP,
				spaceBelow: window.innerHeight - coords.bottom - LINK_PICKER_GAP,
				spaceAbove: coords.top - LINK_PICKER_GAP,
			});
		} else {
			setLinkPickerAnchor(null);
		}
	}
	function updateLinkMatch(view: EditorView): void {
		const next = findLinkMatch(view);
		linkMatchRef.current = next;
		setLinkMatch(next);
        setLinkSearch(next?.query ?? '');
		selectedLinkIndexRef.current = 0;
		setSelectedLinkIndex(0);
		positionLinkPicker(view);
		onLinkQueryChangeRef.current?.(next?.query ?? null);
	}
	function chooseLink(suggestion: MarkdownLinkSuggestion): void {
		const view = viewRef.current;
		const match = linkMatchRef.current;
		if (!view || !match || suggestionsLoadingRef.current) return;
		const heading = match.heading && match.targetId === suggestion.id ? `#${match.heading}` : '';
		const replacement = `[[${suggestion.title}|${suggestion.id}${heading}]]`;
		view.dispatch({
			changes: { from: match.from, to: match.to, insert: replacement },
			selection: { anchor: match.from + replacement.length },
		});
		view.focus();
		linkMatchRef.current = null;
		setLinkMatch(null);
		setLinkPickerAnchor(null);
		onLinkQueryChangeRef.current?.(null);
	}
	useEffect(() => {
		if (!host.current) return;
		const continueList = (view: EditorView): boolean => {
			// 回车续写当前列表项，并把光标放到新标记后的内容位置。
			const selection = view.state.selection.main;
			if (!selection.empty) return false;
            for (let node = syntaxTree(view.state).resolveInner(selection.head, -1); node; node = node.parent!) {
                if (node.name === 'FencedCode') return false;
            }
			const result = continueMarkdownListItem(view.state.doc.toString(), selection.head);
			if (!result) return false;
			view.dispatch({ changes: { from: result.from, to: result.to, insert: result.insert }, selection: { anchor: result.cursor } });
			return true;
		};
		const outdentList = (view: EditorView): boolean => {
			if (!indentLess(view)) return false;
			return true;
		};
		const exitList = (view: EditorView): boolean => {
			// 空的一级列表项再次回车时退出列表，但保留当前空行。
			const selection = view.state.selection.main;
			if (!selection.empty || protectedSyntax(view)) return false;
			const result = exitEmptyRootListItem(view.state.doc.toString(), selection.head);
			if (!result) return false;
			view.dispatch({ changes: { from: result.from, to: result.to, insert: result.insert ?? '' }, selection: { anchor: result.cursor } });
			return true;
		};
		const continueCallout = (view: EditorView): boolean => {
			const selection = view.state.selection.main;
			if (!selection.empty || protectedSyntax(view)) return false;
			const result = continueCalloutLine(view.state.doc.toString(), selection.head);
			if (!result) return false;
			view.dispatch({ changes: { from: result.from, to: result.to, insert: result.insert }, selection: { anchor: result.cursor } });
			return true;
		};
		const indentList = (view: EditorView): boolean => {
			const selection = view.state.selection.main;
			if (!selection.empty || protectedSyntax(view)) return false;
			const edit = indentMarkdownListItem(view.state.doc.toString(), selection.head);
			if (!edit) return false;
			view.dispatch({ changes: { from: edit.from, to: edit.to, insert: edit.insert }, selection: { anchor: edit.cursor } });
			return true;
		};
		const toggle = (view: EditorView, marker: string): boolean => {
			// 粗体、高亮和行内代码均由纯函数处理，可在已有标记内再次取消。
			const selection = view.state.selection.main;
			const edit = toggleInlineFormat(view.state.doc.toString(), selection.from, selection.to, marker);
			view.dispatch({
				changes: { from: edit.from, to: edit.to, insert: edit.insert },
				selection: { anchor: edit.anchor, head: edit.head },
			});
			return true;
		};
		const normalizeWikiLinkBrackets = (view: EditorView): boolean => {
			// 中文输入法通常会把连续的英文左中括号输入为「【【」或「［［」。
			// 只在光标正好位于这两个字符之后替换，避免改动正文中已有的普通文本。
			const selection = view.state.selection.main;
			if (view.composing || protectedSyntax(view) || !selection.empty || selection.head < 2) return false;
			const before = view.state.doc.sliceString(selection.head - 2, selection.head);
			const replacement = before === '【【' || before === '［［' ? '[[' : before === '】】' || before === '］］' ? ']]' : null;
			if (!replacement) return false;
			view.dispatch({
				changes: { from: selection.head - 2, to: selection.head, insert: replacement },
				selection: { anchor: selection.head },
			});
			return true;
		};
		const isSupportedAttachment = (type: string): boolean =>
			type.startsWith('image/') ||
			type === 'application/pdf' ||
			type === 'audio/mpeg' ||
			type === 'audio/wav' ||
			type === 'audio/ogg' ||
			type === 'video/mp4' ||
			type === 'video/webm';
		const attachmentFromClipboard = (event: ClipboardEvent): File[] => {
			const items = Array.from(event.clipboardData?.items ?? []).filter(
				(candidate) => candidate.kind === 'file' && isSupportedAttachment(candidate.type),
			);
			return items.map((item) => item.getAsFile()).filter((file): file is File => file !== null);
		};
		const attachmentFromDrop = (event: DragEvent): File[] => {
			const files = Array.from(event.dataTransfer?.files ?? []).filter((candidate) => isSupportedAttachment(candidate.type));
			return files;
		};
		/**
		 * 视口顶部对应的源码行：使用 CodeMirror 的行块布局和行内偏移，
		 * 这样预览能逐行连续跟随，而不是每次跨块才跳一下。
		 */
		const topVisibleSourceLine = (view: EditorView): number => {
			// lineBlockAtHeight 使用 CodeMirror 的实际布局，避免行号栏、左右 padding
			// 和自动换行导致 posAtCoords 在编辑区顶部取错行。
			const block = view.lineBlockAtHeight(view.scrollDOM.scrollTop);
			const line = view.state.doc.lineAt(block.from);
			const height = Math.max(1, block.height);
			const fraction = Math.min(1, Math.max(0, (view.scrollDOM.scrollTop - block.top) / height));
			return line.number + fraction;
		};
		let scrollFrame = 0;
		/** 滚动与输入都会触发上报，用一帧节流避免高频 setState。 */
		const emitScrollLine = (): void => {
			if (scrollFrame) return;
			scrollFrame = window.requestAnimationFrame(() => {
				scrollFrame = 0;
				const view = viewRef.current;
				if (!view) return;
				const viewport = view.scrollDOM;
				const maximum = viewport.scrollHeight - viewport.clientHeight;
				const edge = viewport.scrollTop <= 1 ? 'top' : maximum > 1 && viewport.scrollTop >= maximum - 2 ? 'bottom' : undefined;
				onScrollLineRef.current?.(topVisibleSourceLine(view), edge);
				// 输入时 CodeMirror 会把光标滚进视野，弹层锚点要跟着刷新，否则会压住正在输入的那一行。
				if (linkMatchRef.current) positionLinkPicker(view);
			});
		};
		const createState = (content: string): EditorState =>
			EditorState.create({
				doc: content,
				extensions: [
					lineNumbers(),
					history(),
					indentOnInput(),
					indentUnit.of('\t'),
					bracketMatching(),
					syntaxHighlighting(highlight),
					editorTheme,
					markdown(),
					highlightActiveLine(),
					EditorView.lineWrapping,
					// 中文与字母数字相邻时自动补一个空格；输入法组词期间一律放行，否则会打断候选词上屏。
					EditorView.inputHandler.of((view, from, to, text) => {
						if (view.composing || protectedSyntax(view)) return false;
						const insertion = spaceTypedInsertion(view.state.doc.toString(), from, to, text);
						if (!insertion) return false;
						view.dispatch({
							changes: { from: insertion.from, to: insertion.to, insert: insertion.insert },
							selection: { anchor: insertion.cursor },
							// 沿用默认输入的事件名，撤销时才能和相邻输入合并成一步。
							userEvent: 'input.type',
							scrollIntoView: true,
						});
						return true;
					}),
					EditorView.domEventHandlers({
						paste: (event) => {
							const file = attachmentFromClipboard(event);
							if (!file.length || !onAttachmentUploadRef.current) return false;
							event.preventDefault();
							void uploadFiles(file);
							return true;
						},
						dragover: (event) => {
							if (!Array.from(event.dataTransfer?.items ?? []).some((item) => item.kind === 'file' && isSupportedAttachment(item.type)))
								return false;
							event.preventDefault();
							return true;
						},
						drop: (event, view) => {
							const file = attachmentFromDrop(event);
							if (!file.length || !onAttachmentUploadRef.current) return false;
							event.preventDefault();
							void uploadFiles(file, view.posAtCoords({ x: event.clientX, y: event.clientY }) ?? undefined);
							return true;
						},
					}),
					Prec.highest(
						keymap.of([
							{
								key: 'ArrowDown',
								run: () => {
									if (suggestionsLoadingRef.current || !linkMatchRef.current || !linkSuggestionsRef.current.length) return false;
									setSelectedLinkIndex((index) => Math.min(linkSuggestionsRef.current.length - 1, index + 1));
									return true;
								},
							},
							{
								key: 'ArrowUp',
								run: () => {
									if (suggestionsLoadingRef.current || !linkMatchRef.current || !linkSuggestionsRef.current.length) return false;
									setSelectedLinkIndex((index) => Math.max(0, index - 1));
									return true;
								},
							},
							{
								key: 'Enter',
								run: () => {
									if (suggestionsLoadingRef.current || !linkMatchRef.current || !linkSuggestionsRef.current[selectedLinkIndexRef.current])
										return false;
									chooseLink(linkSuggestionsRef.current[selectedLinkIndexRef.current]);
									return true;
								},
							},
							{
								key: 'Escape',
								run: () => {
									if (!linkMatchRef.current) return false;
									linkMatchRef.current = null;
									setLinkMatch(null);
									setLinkPickerAnchor(null);
									onLinkQueryChangeRef.current?.(null);
									return true;
								},
							},
                            { key: 'Tab', run: indentList, preventDefault: true },
                            { key: 'Tab', run: indentMore, preventDefault: true },
                            { key: 'Shift-Tab', run: outdentList, preventDefault: true },
                            { key: 'Enter', run: exitList },
							{ key: 'Enter', run: continueList },
							{ key: 'Enter', run: continueCallout },
						]),
					),
					keymap.of([
						{ key: 'Mod-b', run: (view) => toggle(view, '**') },
						{ key: 'Mod-Shift-h', run: (view) => toggle(view, '==') },
						{ key: 'Mod-`', run: (view) => toggle(view, '`') },
						...defaultKeymap,
						...historyKeymap,
					]),
					EditorView.updateListener.of((update) => {
						for (const pending of pendingInsertions.current) pending.position = update.changes.mapPos(pending.position, 1);
						if (update.selectionSet || update.docChanged)
							setInTable(isMarkdownTableAtCursor(update.state.doc.toString(), update.state.selection.main.head));
						if (update.transactions.some((transaction) => transaction.annotation(externalDocumentSync))) return;
						if (update.transactions.some((transaction) => transaction.isUserEvent('input.type')) && normalizeWikiLinkBrackets(update.view))
							return;
						if (update.selectionSet || update.docChanged) updateLinkMatch(update.view);
						// 只上报实际编辑，不改写文档其它位置。
						if (!update.docChanged) return;
						const source = update.state.doc.toString();

						onChangeRef.current(source);
						// 输入会改变文档高度并可能带着视口滚动，重新上报顶部行让预览跟上。
						emitScrollLine();
					}),
				],
			});
		createStateRef.current = createState;
		const editor = new EditorView({ state: createState(value), parent: host.current });
		viewRef.current = editor;
        const jump=(event:Event)=>{const line=editor.state.doc.line(Math.min(editor.state.doc.lines,Math.max(1,(event as CustomEvent).detail)));editor.dispatch({selection:{anchor:line.from},effects:EditorView.scrollIntoView(line.from,{y:'center'})});editor.focus()};
        editor.contentDOM.addEventListener('note-jump',jump);

		setInTable(isMarkdownTableAtCursor(editor.state.doc.toString(), editor.state.selection.main.head));
		updateLinkMatch(editor);
		editor.scrollDOM.addEventListener('scroll', emitScrollLine, { passive: true });
		return () => {
			onLinkQueryChangeRef.current?.(null);
			linkMatchRef.current = null;
			setLinkMatch(null);
			setLinkPickerAnchor(null);
			editor.scrollDOM.removeEventListener('scroll', emitScrollLine);
			if (scrollFrame) window.cancelAnimationFrame(scrollFrame);
			for (const pending of pendingInsertions.current) pending.cancelled = true;
			pendingInsertions.current.clear();
            editor.contentDOM.removeEventListener('note-jump',jump);
			editor.destroy();
			viewRef.current = null;
		};
	}, []);
	// 工具栏与 useImperativeHandle 共用的编辑动作，避免两套重复实现。
	const insert = useCallback((text: string): void => {
		// 普通插入替换当前选择，并将光标移动到插入内容之后。
		const view = viewRef.current;
		if (!view) return;
		const selection = view.state.selection.main;
		view.dispatch({
			changes: { from: selection.from, to: selection.to, insert: text },
			selection: { anchor: selection.from + text.length },
		});
		view.focus();
	}, []);
	const insertBlock = useCallback((text: string): void => {
		// 块级插入不覆盖当前行：有内容时从下一行开始。
		const view = viewRef.current;
		if (!view) return;
		const selection = view.state.selection.main;
		const line = view.state.doc.lineAt(selection.head);
		const hasContent = line.text.trim().length > 0;
		const from = hasContent ? line.to : selection.from;
		const to = hasContent ? line.to : selection.to;
		const content = hasContent ? `\n${text}` : text;
		view.dispatch({ changes: { from, to, insert: content }, selection: { anchor: from + content.length } });
		view.focus();
	}, []);
	const insertCallout = useCallback((type: string, titleOverride?: string): void => {
		// 光标位于 Callout 引用块内时交给纯函数处理，保留当前行并在整个块后插入。
		const view = viewRef.current;
		if (!view) return;
		const title = titleOverride ?? '';
		const selection = view.state.selection.main;
		const source = view.state.doc.toString();
		const line = view.state.doc.lineAt(selection.head);
		const callout = title ? `> [!${type}] ${title}\n> ` : `> [!${type}]\n> `;
		const separator = /^\s*>/.test(line.text) ? '\n\n' : '\n';
		const insertion = /^\s*>/.test(line.text)
			? buildCalloutInsertion(source, selection.from, selection.to, type, title)
			: line.text.trim().length > 0
				? { from: line.to, to: line.to, insert: `${separator}${callout}`, cursor: line.to + callout.length + separator.length }
				: buildCalloutInsertion(source, selection.from, selection.to, type, title);
		view.dispatch({
			changes: { from: insertion.from, to: insertion.to, insert: insertion.insert },
			selection: { anchor: insertion.cursor },
		});
		view.focus();
	}, []);
	useImperativeHandle(ref, () => ({ insert, resume: () => {
		const view = viewRef.current;
		if (!view) return;
		view.requestMeasure();
		view.focus();
	} }), [insert]);
	useLayoutEffect(() => {
		const view = viewRef.current;
		if (!view) return;
		if (documentKeyRef.current !== documentKey && createStateRef.current) {
			for (const pending of pendingInsertions.current) pending.cancelled = true;
			pendingInsertions.current.clear();
			documentKeyRef.current = documentKey;
			view.setState(createStateRef.current(value));
			view.scrollDOM.scrollTop = 0;
			linkMatchRef.current = null;
			setLinkMatch(null);
			setLinkPickerAnchor(null);
			onLinkQueryChangeRef.current?.(null);
			return;
		}
		const transaction = externalDocumentTransaction(view.state, value);
		if (transaction) view.dispatch(transaction);
	}, [documentKey, value]);
	/**
	 * 决定弹层落在光标上方还是下方，并在两侧都放不下时压缩列表高度。
	 * 放在 layout 阶段测量，React 会在浏览器绘制前同步重渲染，不会看到「先出现在下方再跳上去」。
	 */
	useLayoutEffect(() => {
		if (!linkMatch || !linkPickerAnchor) {
			setLinkPickerStyle(null);
			return;
		}
        // Reserve a stable viewport for search results. Filtering must not change
        // the placement or move the search field while the user types.
        const layout = layoutLinkPicker(linkPickerAnchor, LINK_PICKER_LIST_MAX + LINK_PICKER_CHROME + 36);
		const next: LinkPickerStyle = {
			left: linkPickerAnchor.left,
			top: layout.top,
			listMaxHeight: Math.max(0, layout.listMaxHeight - 36),
		};
		// 值没变时返回原对象，避免每轮渲染都因为新对象而再次进入本效果。
		setLinkPickerStyle((prev) =>
			prev && prev.left === next.left && prev.top === next.top && prev.listMaxHeight === next.listMaxHeight ? prev : next,
		);
	}, [!!linkMatch, linkPickerAnchor]);
	useEffect(() => {
		const update = () => {
			if (viewRef.current && linkMatchRef.current) positionLinkPicker(viewRef.current);
		};
		window.addEventListener('resize', update);
		window.addEventListener('scroll', update, true);
		return () => {
			window.removeEventListener('resize', update);
			window.removeEventListener('scroll', update, true);
		};
	}, []);
	function editTable(kind: 'column' | 'row'): void {
		const view = viewRef.current;
		if (!view) return;
		const edit = (kind === 'column' ? addMarkdownTableColumn : addMarkdownTableRow)(
			view.state.doc.toString(),
			view.state.selection.main.head,
		);
		if (!edit) {
			toast('请先将光标放在表格内');
			return;
		}
		view.dispatch({ changes: { from: edit.from, to: edit.to, insert: edit.insert }, selection: { anchor: edit.cursor } });
		view.focus();
	}
	const attachmentRef = useRef<HTMLInputElement>(null);
	const [contextPoint, setContextPoint] = useState<{ x: number; y: number } | null>(null);
	const closeContextMenu = useCallback(() => setContextPoint(null), []);
	useEffect(() => {
		if (active) return;
		setContextPoint(null);
		linkMatchRef.current = null;
		setLinkMatch(null);
		setLinkPickerAnchor(null);
		onLinkQueryChangeRef.current?.(null);
	}, [active]);
	const codeOptions = [
		{ value: 'inline', label: '行内' },
		{ value: 'block', label: '代码块' },
	];
	const calloutOptions = [
		{ value: 'note', label: '笔记', icon: calloutIcons.note },
		{ value: 'info', label: '信息', icon: calloutIcons.info },
		{ value: 'tip', label: '提示', icon: calloutIcons.tip },
		{ value: 'warning', label: '警告', icon: calloutIcons.warning },
		{ value: 'danger', label: '危险', icon: calloutIcons.danger },
		{ value: 'todo', label: '待办', icon: calloutIcons.todo },
		{ value: 'example', label: '示例', icon: calloutIcons.example },
	];
	const insertCode = (kind: string): void => {
		if (kind === 'inline') insert('`代码`');
		else insertBlock('```js\n\n```');
	};
	const insertTable = (): void => insertBlock('| 标题 | 标题 |\n| --- | --- |\n| 内容 | 内容 |');
	const insertMermaid = (): void => insertBlock('```mermaid\n\ngraph TD\n    A[开始] --> B[结束]\n```');
	async function clipboardAction(action: 'cut' | 'copy' | 'paste'): Promise<void> {
		const view = viewRef.current;
		if (!view) return;
		const selection = view.state.selection.main;
		const state = view.state;
		const key = documentKeyRef.current;
		const current = () => viewRef.current === view && documentKeyRef.current === key && view.state === state;
		try {
			if (action === 'paste') {
				const text = await readClipboardText();
				if (!current()) return;
				view.dispatch(view.state.replaceSelection(text));
			} else {
				if (selection.empty) return;
				await writeClipboardText(view.state.sliceDoc(selection.from, selection.to));
				if (!current()) return;
				if (action === 'cut')
					view.dispatch({ changes: { from: selection.from, to: selection.to, insert: '' }, selection: { anchor: selection.from } });
			}
			view.focus();
		} catch {
			toast('无法访问剪贴板，请使用系统复制粘贴快捷键', { variant: 'error' });
		}
	}
	const hasSelection = !(viewRef.current?.state.selection.main.empty ?? true);
	const contextItems: ContextMenuItem[] = [
		{ label: '剪切', disabled: !hasSelection, onClick: () => clipboardAction('cut') },
		{ label: '复制', disabled: !hasSelection, onClick: () => clipboardAction('copy') },
		{ label: '粘贴', onClick: () => clipboardAction('paste') },
		{ label: '代码', divider: true, children: codeOptions.map((item) => ({ label: item.label, onClick: () => insertCode(item.value) })) },
		{
			label: '提示框',
			children: calloutOptions.map((item) => ({ label: item.label, icon: item.icon, onClick: () => insertCallout(item.value) })),
		},
		{
			label: '表格',
			children: [
				{ label: '插入表格', onClick: insertTable },
				{ label: '添加列', disabled: !inTable, onClick: () => editTable('column') },
				{ label: '添加行', disabled: !inTable, onClick: () => editTable('row') },
			],
		},
		{ label: 'Mermaid', onClick: insertMermaid },
		...(onAttachmentUpload ? [{ label: '附件', onClick: () => attachmentRef.current?.click() }] : []),
	];
	return (
		<div ref={rootRef} className="relative flex h-full min-h-0 min-w-0 flex-col">
			{onAttachmentUpload && (
				<input
					ref={attachmentRef}
					type="file"
					className="hidden"
					accept="image/png,image/jpeg,image/gif,image/webp,application/pdf,audio/mpeg,audio/wav,audio/ogg,video/mp4,video/webm"
					multiple
					onChange={(event) => {
						void uploadFiles(Array.from(event.target.files ?? []));
						event.target.value = '';
					}}
				/>
			)}

			{active && linkMatch &&
				linkPickerAnchor &&
				createPortal(
					<div
						ref={linkPickerRef}
						className="station-popup fixed z-[80] flex w-80 max-w-[calc(100vw-1rem)] select-none flex-col p-2"
						style={{ left: linkPickerStyle?.left ?? linkPickerAnchor.left, top: linkPickerStyle?.top ?? linkPickerAnchor.below, height: (linkPickerStyle?.listMaxHeight ?? LINK_PICKER_LIST_MAX - 36) + LINK_PICKER_CHROME + 36 }}
					>
                        <input aria-label="搜索引用笔记" placeholder="搜索笔记…" className="station-input-field mb-2 w-full shrink-0 px-2 py-1 text-xs" value={linkSearch}
                            onChange={event=>{setLinkSearch(event.target.value);setSelectedLinkIndex(0);selectedLinkIndexRef.current=0;onLinkQueryChangeRef.current?.(event.target.value);}}
                            onKeyDown={event=>{
                                if(event.nativeEvent.isComposing)return;
                                if(event.key==='ArrowDown'||event.key==='ArrowUp'){event.preventDefault();const count=linkSuggestions.length;if(count){const index=(selectedLinkIndexRef.current+(event.key==='ArrowDown'?1:-1)+count)%count;selectedLinkIndexRef.current=index;setSelectedLinkIndex(index);}}
                                if(event.key==='Enter'){event.preventDefault();const target=linkSuggestions[selectedLinkIndexRef.current];if(target)chooseLink(target);}
                                if(event.key==='Escape'){event.preventDefault();linkMatchRef.current=null;setLinkMatch(null);setLinkPickerAnchor(null);onLinkQueryChangeRef.current?.(null);viewRef.current?.focus();}
                            }}/>
						{linkSuggestionsLoading ? (
							<div className="px-2 py-2 text-xs text-station-subtle">搜索笔记中…</div>
						) : linkSuggestions.length ? (
							<ScrollContainer
								bleed={false}
								className="pr-0"
								ref={linkListRef}
								style={{ maxHeight: linkPickerStyle?.listMaxHeight ?? LINK_PICKER_LIST_MAX }}
							>
								{linkSuggestions.map((suggestion, index) => (
									<button
										key={suggestion.id}
										type="button"
										className={`flex w-full min-w-0 flex-col gap-2 rounded-xl px-2 py-2 text-left text-xs text-station-text transition hover:bg-white/10 ${index === selectedLinkIndex ? 'bg-white/10 ring-1 ring-inset ring-white/20' : ''}`}
										onMouseDown={(event) => event.preventDefault()}
										onClick={() => chooseLink(suggestion)}
									>
										<span className="truncate">{suggestion.title}</span>

									</button>
								))}
							</ScrollContainer>
						) : (
							<EmptyCard variant="plain" icon="notes">
								没有匹配的笔记
							</EmptyCard>
						)}
					</div>,
					document.body,
				)}
			{active && contextPoint && <ContextMenu point={contextPoint} items={contextItems} onClose={closeContextMenu} />}
			<div
				ref={host}
				className="markdown-editor select-text min-h-0 min-w-0 flex-1 overflow-hidden"
				onContextMenu={(event) => {
					const view = viewRef.current;
					if (!view) return;
					event.preventDefault();
					const position = view.posAtCoords({ x: event.clientX, y: event.clientY });
					const selection = view.state.selection.main;
					if (position !== null && (selection.empty || position < selection.from || position > selection.to))
						view.dispatch({ selection: { anchor: position } });
					view.focus();
					setLinkMatch(null);
					linkMatchRef.current = null;
					setLinkPickerAnchor(null);
					onLinkQueryChangeRef.current?.(null);
					setContextPoint({ x: event.clientX, y: event.clientY });
				}}
			/>
		</div>
	);
});
