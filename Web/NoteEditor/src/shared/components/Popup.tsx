import { createPortal } from 'react-dom';
import { ScrollContainer } from '@/shared/components/ScrollContainer';
import { useLayoutEffect, useRef, useState, type ReactNode, type RefObject } from 'react';

type Props = {
	open: boolean;
	anchorRef: RefObject<HTMLElement | null>;
	onRequestClose: () => void;
	children: ReactNode;
	className?: string;
	matchWidth?: boolean;
	matchMinWidth?: boolean;
};
type Position = { top: number; left: number; width?: number; minWidth?: number; maxWidth?: number; maxHeight?: number };

/** 挂载到 body 的通用浮层，自动选择上下方向和左右对齐方式，并跟随滚动定位。 */
export function Popup({
	open,
	anchorRef,
	onRequestClose,
	children,
	className = '',
	matchWidth = false,
	matchMinWidth = false,
}: Props): React.JSX.Element | null {
	const panelRef = useRef<HTMLDivElement>(null);
	const [position, setPosition] = useState<Position | null>(null);
	useLayoutEffect(() => {
		if (!open) {
			setPosition(null);
			return;
		}
		const updatePosition = () => {
			// 通过触发器和视口空间计算位置，避免弹层被父级 overflow 裁剪。
			const anchor = anchorRef.current;
			if (!anchor) return;
			const panel = panelRef.current;
			if (!panel) return;
			const viewport = window.visualViewport;
			const x = (viewport?.offsetLeft ?? 0) + 8;
			const y = (viewport?.offsetTop ?? 0) + 8;
			const width = Math.max(0, (viewport?.width ?? window.innerWidth) - 16);
			const bottom = y + Math.max(0, (viewport?.height ?? window.innerHeight) - 16);
			const rect = anchor.getBoundingClientRect();
			// Measure unconstrained height at the final width, never feed last maxHeight back into placement.
			panel.style.maxHeight = 'none';
			panel.style.maxWidth = `${width}px`;
			panel.style.minWidth = '';
			const naturalMin = Number.parseFloat(getComputedStyle(panel).minWidth) || 0;
			panel.style.minWidth = `${Math.min(width, Math.max(naturalMin, matchMinWidth ? rect.width : 0))}px`;
			panel.style.width = matchWidth ? `${Math.min(width, rect.width)}px` : '';
			const bounds = panel.getBoundingClientRect();
			const belowSpace = Math.max(0, bottom - rect.bottom - 4);
			const aboveSpace = Math.max(0, rect.top - y - 4);
			const below = belowSpace >= bounds.height || belowSpace >= aboveSpace;
			const maxHeight = Math.min(bottom - y, below ? belowSpace : aboveSpace);
			const height = Math.min(bounds.height, maxHeight);
			const top = Math.max(y, Math.min(below ? rect.bottom + 4 : rect.top - height - 4, bottom - height));
			const left = Math.max(
				x,
				Math.min(rect.left + bounds.width <= x + width ? rect.left : rect.right - bounds.width, x + width - bounds.width),
			);
			panel.style.maxHeight = `${maxHeight}px`;
			setPosition({
				top,
				left,
				width: matchWidth ? Math.min(width, rect.width) : undefined,
				minWidth: Number.parseFloat(panel.style.minWidth),
				maxWidth: width,
				maxHeight,
			});
		};
		let frame = requestAnimationFrame(updatePosition);
		const schedule = () => {
			cancelAnimationFrame(frame);
			frame = requestAnimationFrame(updatePosition);
		};
		const observer = new ResizeObserver(schedule);
		if (anchorRef.current) observer.observe(anchorRef.current);
		if (panelRef.current) observer.observe(panelRef.current);
		const handlePointerDown = (event: PointerEvent) => {
			// 点击触发器或弹层内部不关闭，其他位置视为外部点击。
			if (!anchorRef.current?.contains(event.target as Node) && !panelRef.current?.contains(event.target as Node)) onRequestClose();
		};
		const handleKeyDown = (event: KeyboardEvent) => {
			if (event.key === 'Escape' && !event.isComposing) {
				event.preventDefault();
				// 本监听挂在 document，而抽屉/模态的 Esc 监听挂在 window（冒泡更外层）。
				// 不截断的话，弹层打开时按一次 Esc 会把外层的抽屉/模态一起关掉。
				event.stopPropagation();
				onRequestClose();
			}
		};
		updatePosition();
		window.addEventListener('resize', schedule);
		window.addEventListener('scroll', schedule, true);
		window.visualViewport?.addEventListener('resize', schedule);
		window.visualViewport?.addEventListener('scroll', schedule);
		document.addEventListener('pointerdown', handlePointerDown);
		document.addEventListener('keydown', handleKeyDown);
		return () => {
			cancelAnimationFrame(frame);
			observer.disconnect();
			window.removeEventListener('resize', schedule);
			window.removeEventListener('scroll', schedule, true);
			window.visualViewport?.removeEventListener('resize', schedule);
			window.visualViewport?.removeEventListener('scroll', schedule);
			document.removeEventListener('pointerdown', handlePointerDown);
			document.removeEventListener('keydown', handleKeyDown);
		};
	}, [anchorRef, matchMinWidth, matchWidth, onRequestClose, open]);
	if (!open) return null;
	return createPortal(
		// z-[70]：触发式弹层必须高于一切模态（QuickModal z-[60]、抽屉/对话框 z-50），
		// 否则模态内的 Select/DatePicker 下拉会被模态自己的遮罩盖住（portal 到 body，
		// 层级低于模态时整个面板不可见）。
		<ScrollContainer
			bleed={false}
			layout="none"
			ref={panelRef}
			className={`fixed z-[70] select-none ${className}`}
			style={position ?? { visibility: 'hidden' }}
		>
			{children}
		</ScrollContainer>,
		document.body,
	);
}
