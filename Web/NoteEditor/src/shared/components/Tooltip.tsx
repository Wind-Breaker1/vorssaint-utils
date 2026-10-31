import { createPortal } from 'react-dom';
import { useCallback, useLayoutEffect, useRef, useState, type ReactNode } from 'react';

type Props = {
	content: ReactNode;
	children: ReactNode;
	className?: string;
	as?: 'span' | 'div';
};

type Position = {
	top: number;
	left: number;
	maxWidth: number;
	maxHeight: number;
	placement: 'top' | 'bottom';
};

const TOOLTIP_GAP = 8;
const TOOLTIP_EDGE = 8;

function getAppBounds(): { top: number; right: number; bottom: number; left: number } {
	const app = document.getElementById('app')?.getBoundingClientRect();
	return {
		top: Math.max(0, app?.top ?? 0),
		right: Math.min(window.innerWidth, app?.right ?? window.innerWidth),
		bottom: Math.min(window.innerHeight, app?.bottom ?? window.innerHeight),
		left: Math.max(0, app?.left ?? 0),
	};
}

/** 为任意触发内容提供统一的悬停和键盘聚焦提示，并根据窗口边界动态定位。 */
export function Tooltip({ content, children, className = '', as = 'span' }: Props): React.JSX.Element {
	const triggerRef = useRef<HTMLElement | null>(null);
	const tooltipRef = useRef<HTMLSpanElement | null>(null);
	const [open, setOpen] = useState(false);
	const [position, setPosition] = useState<Position | null>(null);

	const updatePosition = useCallback(() => {
		const trigger = triggerRef.current;
		const tooltip = tooltipRef.current;
		if (!trigger || !tooltip) return;
		const triggerRect = trigger.getBoundingClientRect();
		const tooltipRect = tooltip.getBoundingClientRect();
		const bounds = getAppBounds();
		const maxWidth = Math.max(0, bounds.right - bounds.left - TOOLTIP_EDGE * 2);
		const maxHeight = Math.max(0, bounds.bottom - bounds.top - TOOLTIP_EDGE * 2);
		const belowSpace = bounds.bottom - triggerRect.bottom;
		const aboveSpace = triggerRect.top - bounds.top;
		const placement: Position['placement'] = belowSpace >= tooltipRect.height + TOOLTIP_GAP || belowSpace >= aboveSpace ? 'bottom' : 'top';
		const tooltipHeight = Math.min(tooltipRect.height, maxHeight);
		const top = placement === 'bottom' ? triggerRect.bottom + TOOLTIP_GAP : triggerRect.top - tooltipHeight - TOOLTIP_GAP;
		const centeredLeft = triggerRect.left + (triggerRect.width - tooltipRect.width) / 2;
		const rightLimit = Math.max(bounds.left + TOOLTIP_EDGE, bounds.right - TOOLTIP_EDGE - tooltipRect.width);
		const left = Math.min(Math.max(bounds.left + TOOLTIP_EDGE, centeredLeft), rightLimit);
		const clampedTop = Math.min(Math.max(bounds.top + TOOLTIP_EDGE, top), bounds.bottom - TOOLTIP_EDGE - tooltipHeight);
		setPosition({ top: clampedTop, left, maxWidth, maxHeight, placement });
	}, []);

	useLayoutEffect(() => {
		if (!open) {
			setPosition(null);
			return;
		}
		const frame = requestAnimationFrame(updatePosition);
		const handleViewportChange = () => updatePosition();
		window.addEventListener('resize', handleViewportChange);
		window.addEventListener('scroll', handleViewportChange, true);
		const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(handleViewportChange);
		if (observer) {
			if (triggerRef.current) observer.observe(triggerRef.current);
			if (tooltipRef.current) observer.observe(tooltipRef.current);
		}
		return () => {
			cancelAnimationFrame(frame);
			window.removeEventListener('resize', handleViewportChange);
			window.removeEventListener('scroll', handleViewportChange, true);
			observer?.disconnect();
		};
	}, [open, updatePosition]);

	const show = (): void => setOpen(true);
	const hide = (): void => {
		setOpen(false);
		setPosition(null);
	};
	const setTriggerRef = (element: HTMLElement | null): void => {
		triggerRef.current = element;
	};
	const hasKeyboardFocus = (): boolean =>
		Boolean(triggerRef.current?.matches(':focus-visible') || triggerRef.current?.querySelector(':focus-visible'));
	const handleMouseLeave = (): void => {
		if (!hasKeyboardFocus()) hide();
	};
	const Wrapper = as;
	const tooltip = open
		? createPortal(
				<span
					ref={tooltipRef}
					role="tooltip"
					className="station-tooltip-content"
					data-placement={position?.placement ?? 'bottom'}
					data-visible={position ? 'true' : 'false'}
					style={{
						top: position?.top ?? 0,
						left: position?.left ?? 0,
						maxWidth: position?.maxWidth ?? `calc(100vw - ${TOOLTIP_EDGE * 2}px)`,
						maxHeight: position?.maxHeight ?? `calc(100vh - ${TOOLTIP_EDGE * 2}px)`,
					}}
				>
					{content}
				</span>,
				document.body,
			)
		: null;

	return (
		<Wrapper
			ref={setTriggerRef}
			className={`station-tooltip ${className}`.trim()}
			onMouseEnter={show}
			onMouseLeave={handleMouseLeave}
			onFocusCapture={(event) => {
				if ((event.target as HTMLElement).matches(':focus-visible')) show();
			}}
			onBlurCapture={(event) => {
				if (
					!event.currentTarget.contains(event.relatedTarget as Node | null) &&
					!event.currentTarget.matches(':hover') &&
					!hasKeyboardFocus()
				)
					hide();
			}}
		>
			{children}
			{tooltip}
		</Wrapper>
	);
}
