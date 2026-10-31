import DOMPurify from 'dompurify';
import hljs from 'highlight.js/lib/core';
import bash from 'highlight.js/lib/languages/bash';
import css from 'highlight.js/lib/languages/css';
import javascript from 'highlight.js/lib/languages/javascript';
import json from 'highlight.js/lib/languages/json';
import sql from 'highlight.js/lib/languages/sql';
import typescript from 'highlight.js/lib/languages/typescript';
import xml from 'highlight.js/lib/languages/xml';
import MarkdownIt from 'markdown-it';
const SOURCE_LINE_ATTRIBUTE = 'data-source-line';
const ATTACHMENT_BASE_URL = 'note-asset://local';
const attachmentUrl = (id: string, _type: string) => `${ATTACHMENT_BASE_URL}/${id}`;

export interface MarkdownHeading {
	offset: number;
	level: number;
	text: string;
}

export interface RenderedMarkdown {
	html: string;
	headings: MarkdownHeading[];
}

const calloutTypes = new Set(['note', 'info', 'tip', 'warning', 'danger', 'todo']);
const calloutLabels: Record<string, string> = {
	note: '笔记',
	info: '信息',
	tip: '提示',
	warning: '警告',
	danger: '危险',
	todo: '待办',
};
const calloutPaths: Record<string, string> = {
	note: 'M6 3.5h9l3 3v14H6z M9 11h6 M9 15h6',
	info: 'M12 11v6 M12 7v1 M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0',
	tip: 'M9 18h6 M10 21h4 M8.5 14.5a7 7 0 1 1 7 0c-.9.65-1.5 1.5-1.5 2.5h-4c0-1-.6-1.85-1.5-2.5Z',
	warning: 'm12 3 10 18H2Z M12 9v5 M12 17v1',
	danger: 'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0 M8 8l8 8 M16 8l-8 8',
	todo: 'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0 m-13 0 2.5 2.5L16 9',
};
const stationNotePattern = /^\[\[([^|\]\n]+)\|([0-9a-f-]{36})(?:#([^|\]]+))?\]\]/i;

const defaultCodeLanguage = 'js';

/**
 * 给块级元素标注源码起始行（1 基，与编辑器行号一致），预览滚动同步靠它把行号映射成滚动位移。
 * markdown-it 的 token.map 是块级 token 在源码中的 0 基行区间，内联 token 没有该字段。
 */
function sourceLineAttribute(map: readonly [number, number] | null | undefined): string {
	return map ? ` ${SOURCE_LINE_ATTRIBUTE}="${map[0] + 1}"` : '';
}

/** 只注册 Station 常用语言，未知语言继续以安全纯文本展示。 */
hljs.registerLanguage('bash', bash);
hljs.registerLanguage('css', css);
hljs.registerLanguage('html', xml);
hljs.registerLanguage('javascript', javascript);
hljs.registerLanguage('json', json);
hljs.registerLanguage('sql', sql);
hljs.registerLanguage('typescript', typescript);
hljs.registerAliases(['js'], { languageName: 'javascript' });
hljs.registerAliases(['sh', 'shell'], { languageName: 'bash' });
hljs.registerAliases(['ts'], { languageName: 'typescript' });

/** Station 共用 Markdown 解析器：支持内部链接与受控扩展，禁止原始 HTML。 */
const markdown = new MarkdownIt({
	html: false,
	linkify: true,
	breaks: false,
	typographer: false,
	highlight(code: string, language: string): string {
		const label = `<span class="markdown-code-language">${markdown.utils.escapeHtml(language || defaultCodeLanguage)}</span>`;
		const className = language ? ` class="language-${markdown.utils.escapeHtml(language)}"` : '';
		if (language && hljs.getLanguage(language)) {
			return `<pre class="hljs">${label}<code${className}>${hljs.highlight(code, { language, ignoreIllegals: true }).value}</code></pre>`;
		}
		return `<pre class="hljs">${label}<code${className}>${markdown.utils.escapeHtml(code)}</code></pre>`;
	},
});

const defaultNormalizeLink = markdown.normalizeLink.bind(markdown);
/** 附件 Markdown 只存稳定资源 ID，渲染时解析为后端受控地址。 */
markdown.normalizeLink = (url: string): string => {
	if (url.startsWith('attachment://')) {
		const match = url
			.slice('attachment://'.length)
			.match(/^([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})(?:\?type=([^&]+))?$/i);
		if (!match) return '';
		try {
			const mediaType = match[2] ? decodeURIComponent(match[2]) : '';
			return attachmentUrl(match[1], mediaType);
		} catch {
			return ''; // 损坏的附件参数不能中断整篇笔记渲染。
		}
	}
	return defaultNormalizeLink(url);
};

/** 将稳定笔记引用解析为应用内链接，避免标题重名或重命名造成关系失效。 */
markdown.inline.ruler.before('link', 'station_note_link', (state, silent) => {
	const match = state.src.slice(state.pos).match(stationNotePattern);
	if (!match) return false;
	if (!silent) {
		const [, rawLabel, id, heading] = match;
		const label = rawLabel || '打开笔记';
		const open = state.push('link_open', 'a', 1);
		open.attrSet('href', `station-note:${id}${heading ? `#${encodeURIComponent(heading)}` : ''}`);
		open.attrSet('data-note-id', id);
		if (heading) open.attrSet('data-note-heading', heading);
		const text = state.push('text', '', 0);
		text.content = label;
		state.push('link_close', 'a', -1);
	}
	state.pos += match[0].length;
	return true;
});

/** 支持 ==高亮==，但不将空文本视为高亮。 */
markdown.inline.ruler.before('emphasis', 'highlight', (state, silent) => {
	if (state.src.slice(state.pos, state.pos + 2) !== '==') return false;
	const close = state.src.indexOf('==', state.pos + 2);
	if (close < 0 || close === state.pos + 2) return false;
	if (!silent) {
		state.push('mark_open', 'mark', 1);
		const text = state.push('text', '', 0);
		text.content = state.src.slice(state.pos + 2, close);
		state.push('mark_close', 'mark', -1);
	}
	state.pos = close + 2;
	return true;
});

/** 将 Obsidian 风格 Callout 转为 Station 固定语义样式，不开放用户自定义 CSS。 */
markdown.core.ruler.after('inline', 'station_callouts', (state) => {
	const blockquoteStack: boolean[] = [];
	for (let index = 0; index < state.tokens.length; index += 1) {
		if (state.tokens[index].type === 'blockquote_close') {
			blockquoteStack.pop();
			continue;
		}
		const open = state.tokens[index];
		if (open.type !== 'blockquote_open') continue;
		const nestedInCallout = blockquoteStack.includes(true);
		blockquoteStack.push(false);
		if (nestedInCallout) continue;
		const paragraph = state.tokens[index + 1];
		const inline = state.tokens[index + 2];
		if (paragraph?.type !== 'paragraph_open' || inline?.type !== 'inline') continue;
		const match = inline.content.match(/^\[!([a-z-]+)]([+-])?(?:[^\S\r\n]+([^\n]+))?(?:\n|$)/i);
		if (!match || !calloutTypes.has(match[1].toLowerCase())) continue;
		const type = match[1].toLowerCase();
		const title = match[3] || '';
		const body = inline.content.slice(match[0].length);
		const parsed = state.md.parseInline(body, state.env)[0];
		inline.content = body;
		inline.children = parsed?.children ?? [];
		open.meta = { callout: { type, title, fold: match[2] ?? null } };
		blockquoteStack[blockquoteStack.length - 1] = true;
		for (let closeIndex = index + 1; closeIndex < state.tokens.length; closeIndex += 1) {
			if (state.tokens[closeIndex].type === 'blockquote_close' && state.tokens[closeIndex].level === open.level) {
				state.tokens[closeIndex].meta = open.meta;
				break;
			}
		}
	}
});

const defaultLinkOpen =
	markdown.renderer.rules.link_open ?? ((tokens, index, options, _env, renderer) => renderer.renderToken(tokens, index, options));
const defaultBlockquoteOpen =
	markdown.renderer.rules.blockquote_open ?? ((tokens, index, options, _env, renderer) => renderer.renderToken(tokens, index, options));
const defaultBlockquoteClose =
	markdown.renderer.rules.blockquote_close ?? ((tokens, index, options, _env, renderer) => renderer.renderToken(tokens, index, options));

/** 仅让外部链接离开应用，内部链接由预览组件接管。 */
markdown.renderer.rules.link_open = (tokens, index, options, env, renderer) => {
	const href = String(tokens[index].attrGet('href') ?? '');
	if (/^https?:\/\//i.test(href)) {
		tokens[index].attrSet('target', '_blank');
		tokens[index].attrSet('rel', 'noopener noreferrer');
	}
	if (href.startsWith(`${ATTACHMENT_BASE_URL}/`)) {
		tokens[index].attrSet('target', '_blank');
		tokens[index].attrSet('rel', 'noopener noreferrer');
		const type = href.match(/[?&]type=([^&]+)/i)?.[1];
		if (type) tokens[index].attrSet('data-attachment-type', decodeURIComponent(type));
		tokens[index].attrSet('class', 'markdown-attachment-link');
	}
	return defaultLinkOpen(tokens, index, options, env, renderer);
};

markdown.renderer.rules.blockquote_open = (tokens, index, options, env, renderer) => {
	const callout = tokens[index].meta?.callout as { type: string; title: string; fold: '+' | '-' | null } | undefined;
	if (!callout) return defaultBlockquoteOpen(tokens, index, options, env, renderer);
	const label = calloutLabels[callout.type] ?? callout.type;
	const icon = `<span class="markdown-callout-kind" role="img" aria-label="${label}"><svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${calloutPaths[callout.type]}" /></svg></span>`;
	const header = `${icon}<span class="markdown-callout-title">${markdown.utils.escapeHtml(callout.title)}</span>`;
	const attribute = sourceLineAttribute(tokens[index].map);
	if (callout.fold)
		return `<details class="markdown-callout markdown-callout-${callout.type}"${attribute}${callout.fold === '+' ? ' open' : ''}><summary class="markdown-callout-header">${header}</summary>\n`;
	return `<aside class="markdown-callout markdown-callout-${callout.type}"${attribute}><div class="markdown-callout-header">${header}</div>\n`;
};
markdown.renderer.rules.blockquote_close = (tokens, index, options, env, renderer) => {
	const callout = tokens[index].meta?.callout as { fold: '+' | '-' | null } | undefined;
	if (callout) return callout.fold ? '</details>\n' : '</aside>\n';
	return defaultBlockquoteClose(tokens, index, options, env, renderer);
};

/** Mermaid 块交给受控预览组件渲染，避免在 Markdown 字符串中执行脚本。 */
markdown.renderer.rules.fence = (tokens, index): string => {
	const token = tokens[index];
	const attribute = sourceLineAttribute(token.map);
	if (token.info.trim() === 'mermaid') return `<pre class="mermaid"${attribute}>${markdown.utils.escapeHtml(token.content)}</pre>\n`;
	const language = token.info.trim().split(/\s+/g)[0] || defaultCodeLanguage;
	const highlighted = markdown.options.highlight?.(token.content, language, '') ?? '';
	return attribute ? highlighted.replace(/^<pre/, `<pre${attribute}`) : highlighted;
};

/** 缩进代码块没有语言声明，同样使用默认 JavaScript 高亮。 */
markdown.renderer.rules.code_block = (tokens, index): string => {
	const token = tokens[index];
	const attribute = sourceLineAttribute(token.map);
	const highlighted = markdown.options.highlight?.(token.content, defaultCodeLanguage, '') ?? '';
	return attribute ? highlighted.replace(/^<pre/, `<pre${attribute}`) : highlighted;
};

// 其余块级 token 走默认渲染，统一在这里补上源码行号（标题、段落、列表、表格、引用等）。
const defaultRenderToken = markdown.renderer.renderToken.bind(markdown.renderer);
markdown.renderer.renderToken = (tokens, index, options) => {
	const token = tokens[index];
	if (token.block && token.nesting !== -1 && token.map) token.attrSet(SOURCE_LINE_ATTRIBUTE, String(token.map[0] + 1));
	return defaultRenderToken(tokens, index, options);
};

/** 将 Markdown 解析为尚未清洗的 HTML，仅供测试和安全渲染流程内部使用。 */
export function parseMarkdown(markdownSource: string): string {
	return markdown.render(markdownSource);
}

/** 将 Markdown 转换成经过白名单清洗、可安全交给 v-html 的 HTML。 */
export function renderMarkdown(markdownSource: string): string {
	return sanitizeMarkdown(parseMarkdown(markdownSource));
}

/** Share one parse between the preview and its source-positioned outline. */
export function renderMarkdownDocument(markdownSource: string): RenderedMarkdown {
	const environment = {};
	const tokens = markdown.parse(markdownSource, environment);
	return {
		html: sanitizeMarkdown(markdown.renderer.render(tokens, markdown.options, environment)),
		headings: headingsFromTokens(markdownSource, tokens),
	};
}

/** Apply the same allowlist to every Markdown render path. */
function sanitizeMarkdown(html: string): string {
	return DOMPurify.sanitize(html, {
		USE_PROFILES: { html: true, svg: true },
		// SVG 路径是绘图数据，不应使用链接协议白名单校验。
		ADD_URI_SAFE_ATTR: ['d'],
		ADD_ATTR: ['viewBox', 'd', 'target', 'data-note-id', 'data-note-heading', 'data-attachment-type', SOURCE_LINE_ATTRIBUTE],
		ADD_TAGS: ['details', 'summary', 'mark', 'svg', 'path'],
		FORBID_TAGS: ['style'],
		FORBID_ATTR: ['style'],
		ALLOWED_URI_REGEXP:
			/^(?:(?:https?|mailto|tel|station-note):|note-asset:\/\/local\/[^\s]+|[^a-z]|[a-z+.-]+(?:[^a-z+.-:]|$))/i,
	});
}

/** 根据解析 token 提取真实标题，避免把代码块中的井号误判为目录。 */
export function extractMarkdownHeadings(markdownSource: string): MarkdownHeading[] {
	return headingsFromTokens(markdownSource, markdown.parse(markdownSource, {}));
}

/** Token maps keep fenced code out of the outline and preserve exact source offsets. */
function headingsFromTokens(markdownSource: string, tokens: ReturnType<typeof markdown.parse>): MarkdownHeading[] {
	const lineOffsets: number[] = [0];
	for (let index = 0; index < markdownSource.length; index += 1) {
		if (markdownSource[index] === '\n') lineOffsets.push(index + 1);
	}

	const headings: MarkdownHeading[] = [];
	for (let index = 0; index < tokens.length; index += 1) {
		const token = tokens[index];
		if (token.type !== 'heading_open' || !token.map) continue;
		const inline = tokens[index + 1];
		if (inline?.type !== 'inline') continue;
		headings.push({
			offset: lineOffsets[token.map[0]] ?? 0,
			level: Number(token.tag.slice(1)),
			text: inline.content,
		});
	}
	return headings;
}
