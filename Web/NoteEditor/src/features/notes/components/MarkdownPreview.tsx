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
		void import('mermaid')
			.then(({ default: mermaid }) => {
				if (cancelled) return;
				const styles = getComputedStyle(node);
				const themeColor = (name: string) => styles.getPropertyValue(`--color-station-${name}`).trim();
				const text = themeColor('text');
				const accent = themeColor('accent');
				const background = themeColor('bg');
				const surface = '#32314b';
				const secondarySurface = '#243b46';
				mermaid.initialize({
					startOnLoad: false,
					securityLevel: 'strict',
					theme: 'base',
					// Mermaid 11 读取全局 htmlLabels；仅配置 flowchart 会被视为兼容项，
					// 某些图类型仍会退回 foreignObject，清洗后就会丢失节点文字。
					htmlLabels: false,
					flowchart: { htmlLabels: false },
					themeVariables: {
						darkMode: true,
						background,
						primaryColor: surface,
						primaryTextColor: text,
						primaryBorderColor: accent,
						secondaryColor: secondarySurface,
						secondaryTextColor: text,
						secondaryBorderColor: themeColor('info'),
						tertiaryColor: '#293b35',
						tertiaryTextColor: text,
						tertiaryBorderColor: themeColor('success'),
						textColor: text,
						titleColor: text,
						lineColor: '#c9c7e3',
						edgeLabelBackground: background,
						clusterBkg: '#202131',
						clusterBorder: '#77758f',
						actorBkg: surface,
						actorBorder: accent,
						actorTextColor: text,
						actorLineColor: '#9996b8',
						signalColor: '#c9c7e3',
						signalTextColor: text,
						labelBoxBkgColor: surface,
						labelBoxBorderColor: accent,
						labelTextColor: text,
						loopTextColor: text,
						noteBkgColor: secondarySurface,
						noteTextColor: text,
						noteBorderColor: themeColor('info'),
						activationBkgColor: surface,
						activationBorderColor: accent,
						taskBkgColor: surface,
						taskBorderColor: accent,
						taskTextColor: text,
						taskTextOutsideColor: text,
						taskTextDarkColor: background,
						pieSectionTextColor: background,
						pieLegendTextColor: text,
						pieTitleTextColor: text,
						fontFamily: styles.fontFamily,
						fontSize: '14px',
					},
				});
				return Promise.all(
					Array.from(blocks).map(async (block, index) => {
						const source = block.textContent ?? '';
						try {
							const { svg } = await mermaid.render(`station-mermaid-${Date.now()}-${index}`, source);
							if (cancelled) return;
							block.classList.remove('mermaid-error');
							block.innerHTML = DOMPurify.sanitize(svg, {
								USE_PROFILES: { svg: true, svgFilters: true },
								// 保留 Mermaid 无 HTML 标签模式下的文字节点；部分图类型仍可能使用
								// foreignObject，允许其必要节点后再由 DOMPurify 统一清洗。
								ADD_TAGS: ['text', 'tspan', 'foreignObject', 'div', 'span'],
								ADD_ATTR: [
									'class',
									'style',
									'fill',
									'stroke',
									'stroke-width',
									'text-anchor',
									'dominant-baseline',
									'x',
									'y',
									'dx',
									'dy',
									'transform',
									'xmlns',
									'width',
									'height',
									'viewBox',
									'font-size',
									'font-family',
								],
							});
							// 时序图 rect 的背景来自源码，不受主题变量控制；保留色相并压暗，承托浅色文字。
							block.querySelectorAll<SVGRectElement>('svg rect.rect').forEach((rect) => {
								const fill = getComputedStyle(rect).fill;
								if (fill !== 'none') rect.style.fill = `color-mix(in srgb, ${background} 78%, ${fill})`;
							});
						} catch {
							if (cancelled) return;
							block.classList.add('mermaid-error');
							block.textContent = 'Mermaid 语法无法解析';
						}
					}),
				);
			})
			.catch(() => {
				if (!cancelled)
					blocks.forEach((block) => {
						block.classList.add('mermaid-error');
						block.textContent = 'Mermaid 渲染器加载失败';
					});
			});
		return () => {
			cancelled = true;
		};
	}, [renderedSource]);
	useEffect(() => {
		const node = article.current;
		if (!node) return;
        node.querySelectorAll('img,a').forEach(el=>{const key=el.tagName==='IMG'?'src':'href';const value=el.getAttribute(key)??'';if(value.startsWith('assets/')){el.setAttribute(key,'note-asset://local/'+value.slice(7));if(el.tagName==='A'){const ext=value.split('.').pop()?.toLowerCase();const mime:Record<string,string>={mp3:'audio/mpeg',wav:'audio/wav',ogg:'audio/ogg',m4a:'audio/mp4',mp4:'video/mp4',webm:'video/webm',mov:'video/quicktime'};if(ext&&mime[ext])el.setAttribute('data-attachment-type',mime[ext])}}});
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
