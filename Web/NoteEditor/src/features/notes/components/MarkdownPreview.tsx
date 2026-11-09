import { forwardRef, useCallback, useEffect, useImperativeHandle, useLayoutEffect, useRef } from 'react';
import DOMPurify from 'dompurify';
import type { RenderedMarkdown } from '@/markdown';
import { collectSourceAnchors, offsetForSourceLine, type SourceAnchor } from '@/features/notes/previewScrollSync';
import { ScrollContainer } from '@/shared/components/ScrollContainer';


type Props = { document: RenderedMarkdown; onOpenNote?: (id: string, heading: string | null) => void; className?: string };
/** 编辑态由 NoteEditor 驱动：把编辑器视口顶部的源码行同步过来。 */
export type MarkdownPreviewHandle = { scrollToLine: (line: number, edge?: 'top' | 'bottom') => void };
export const MarkdownPreview = forwardRef<MarkdownPreviewHandle, Props>(function MarkdownPreview(
	{ document: markdownDocument, onOpenNote, className = '' },
	ref,
): React.JSX.Element {
	const article = useRef<HTMLElement>(null);
	const scrollHost = useRef<HTMLDivElement>(null);
	const { html: renderedSource, headings } = markdownDocument;
	/** 编辑器上来的源码行；预览重渲染会整体替换 innerHTML，需要缓存并按渲染后重新校正。 */
	const syncEdge = useRef<'top' | 'bottom' | undefined>(undefined);
	const syncLine = useRef<number | null>(null);
	/**
	 * 锚点缓存：只在内容更新或尺寸变化后重建。
	 * 纯滚动时只写 scrollTop，不再读一遍全量元素位置，避免每帧强制重排。
	 */
	const anchorsRef = useRef<SourceAnchor[] | null>(null);
	const scrollToLine = useCallback((line: number, edge?: 'top' | 'bottom'): void => {
		const content = article.current;
		const viewport = scrollHost.current;
		if (!content || !viewport) return;
		const anchors = anchorsRef.current ?? collectSourceAnchors(content);
		anchorsRef.current = anchors;
		const offset = offsetForSourceLine(anchors, line);
		if (offset === null) return;
		const maximum = Math.max(0, viewport.scrollHeight - viewport.clientHeight);
		const target = edge === 'bottom' ? maximum : edge === 'top' ? 0 : offset;
		viewport.scrollTop = Math.min(Math.max(0, target), maximum);
	}, []);
	const applySync = useCallback((): void => {
		if (syncLine.current !== null) scrollToLine(syncLine.current, syncEdge.current);
	}, [scrollToLine]);
	useImperativeHandle(
		ref,
		() => ({
			scrollToLine: (line: number, edge?: 'top' | 'bottom') => {
				syncEdge.current = edge;
				syncLine.current = line;
				scrollToLine(line, edge);
			},
		}),
		[scrollToLine],
	);
	useLayoutEffect(() => {
		// 内容更新后先作废锚点缓存，再在 layout 阶段校正，避免滚动位置先闪回顶部。
		anchorsRef.current = null;
		applySync();
	}, [renderedSource, applySync]);
	useEffect(() => {
		// 面板尺寸变化会改变锚点的像素位置，作废缓存并重新对齐。
		const invalidate = () => {
			anchorsRef.current = null;
			applySync();
		};
		let frame = 0;
		const schedule = () => {
			if (!frame)
				frame = requestAnimationFrame(() => {
					frame = 0;
					invalidate();
				});
		};
		const observer = new ResizeObserver(schedule);
		if (article.current) observer.observe(article.current);
		if (scrollHost.current) observer.observe(scrollHost.current);
		article.current?.addEventListener('load', schedule, true);
		window.addEventListener('resize', schedule);
		return () => {
			observer.disconnect();
			article.current?.removeEventListener('load', schedule, true);
			window.removeEventListener('resize', schedule);
			cancelAnimationFrame(frame);
		};
	}, [applySync]);
	useEffect(() => {
		// 使用事件代理处理内部笔记链接，避免为每个链接单独绑定监听器。
		const node = article.current;
		if (!node) return;
		const handleClick = (event: MouseEvent) => {
			const target = event.target as HTMLElement;
			const link = target.closest<HTMLAnchorElement>('a[data-note-id]');
			if (!link?.dataset.noteId) {
				const external = target.closest<HTMLAnchorElement>('a[href]');
				if (!external) return;
				event.preventDefault();
				const href = external.getAttribute('href') ?? '';
				if (href.startsWith('#')) {
					let anchor = href.slice(1);
					try { anchor = decodeURIComponent(anchor); } catch {}
					const destination = Array.from(node.querySelectorAll<HTMLElement>('[id]')).find(element => element.id === anchor);
					destination?.scrollIntoView({ block: 'start', behavior: 'smooth' });
					return;
				}
				(window as any).webkit?.messageHandlers.notes.postMessage({ type: 'openLink', url: href });
				return;
			}
			event.preventDefault();
			onOpenNote?.(link.dataset.noteId, link.dataset.noteHeading ?? null);
		};
		node.addEventListener('click', handleClick);
		return () => node.removeEventListener('click', handleClick);
	}, [onOpenNote]);
	useEffect(() => {
		// 渲染完成后把解析出的标题偏移写回 DOM，供目录点击定位。
		const node = article.current;
		if (!node) return;
		node.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach((heading, index) => {
			const offset = headings[index]?.offset;
			if (offset !== undefined) heading.setAttribute('data-heading-offset', String(offset));
		});
	}, [headings]);
	useEffect(() => {
		const node = article.current;
		const blocks = node?.querySelectorAll<HTMLElement>('pre.mermaid');
		if (!node || !blocks?.length) return;
		let cancelled = false;
		const diagrams: Array<{ destroy(): void }> = [];
		void import('pele')
			.then(({ mount }) => {
				if (cancelled) return;
				for (const block of blocks) {
					const source = block.textContent ?? '';
					diagrams.push(mount(block, source, {
						fontFamily: getComputedStyle(node).fontFamily,
						fontSize: 14,
						images: false,
						zoom: false,
						sanitize: (svg) => DOMPurify.sanitize(svg, {
							USE_PROFILES: { svg: true, svgFilters: true },
							RETURN_DOM_FRAGMENT: true,
						}),
					}));
				}
			})
			.catch(() => {
				if (cancelled) return;
				blocks.forEach((block) => {
					block.classList.add('mermaid-error');
					block.textContent = '图表渲染器加载失败';
				});
			});
		return () => {
			cancelled = true;
			diagrams.forEach((diagram) => diagram.destroy());
		};
	}, [renderedSource]);
	useEffect(() => {
		const node = article.current;
		if (!node) return;
		node.querySelectorAll<HTMLAnchorElement>('a[data-attachment-type]').forEach((anchor) => {
			const type = anchor.dataset.attachmentType ?? '';
			if (!type.startsWith('audio/') && !type.startsWith('video/')) return;
			const figure = document.createElement('figure');
			figure.className = 'markdown-attachment-media';
			const caption = document.createElement('figcaption');
			caption.textContent = anchor.textContent ?? '附件';
			const media = document.createElement(type.startsWith('audio/') ? 'audio' : 'video');
			media.className = 'markdown-attachment-player';
			media.setAttribute('controls', '');
			media.setAttribute('preload', 'metadata');
			media.setAttribute('src', anchor.href);
			figure.append(caption, media);
			anchor.replaceWith(figure);
		});
	}, [renderedSource]);
	return (
		<ScrollContainer ref={scrollHost} horizontal className={className}>
			<article ref={article} className="markdown-preview select-text" dangerouslySetInnerHTML={{ __html: renderedSource }} />
		</ScrollContainer>
	);
});
