import { useLayoutEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Icon, type IconName } from '@/shared/components/Icon';
import { ScrollContainer } from '@/shared/components/ScrollContainer';

export type ContextMenuItem = {
	label: string;
	icon?: IconName;
	disabled?: boolean;
	divider?: boolean;
	onClick?: () => void | Promise<void>;
	children?: ContextMenuItem[];
};
type Point = { x: number; y: number };

function MenuPanel({
	items,
	point,
	parentRect,
	onClose,
}: {
	items: ContextMenuItem[];
	point: Point;
	parentRect?: DOMRect;
	onClose: () => void;
}): React.JSX.Element {
	const panel = useRef<HTMLDivElement>(null);
	const [position, setPosition] = useState(point);
	const [active, setActive] = useState<{ index: number; rect: DOMRect } | null>(null);
	useLayoutEffect(() => {
		const rect = panel.current?.getBoundingClientRect();
		if (!rect) return;
		const x = parentRect && point.x + rect.width > window.innerWidth - 8 ? parentRect.left - rect.width : point.x;
		setPosition({
			x: Math.max(8, Math.min(x, window.innerWidth - rect.width - 8)),
			y: Math.max(8, Math.min(point.y, window.innerHeight - rect.height - 8)),
		});
	}, [point.x, point.y, parentRect]);
	return (
		<>
			<ScrollContainer
				ref={panel}
				role="menu"
				layout="none"
				bleed={false}
				gutter={false}
				className="station-popup fixed z-[90] flex flex-col gap-1 max-h-[calc(100vh-1rem)] w-44 max-w-[calc(100vw-1rem)] select-none p-1"
				style={{ left: position.x, top: position.y }}
				onContextMenu={(event) => event.preventDefault()}
			>
				{items.map((item, index) => (
					<button
						key={item.label}
						type="button"
						role="menuitem"
						disabled={item.disabled}
						aria-haspopup={item.children ? 'menu' : undefined}
						aria-expanded={item.children ? active?.index === index : undefined}
						className={`flex w-full shrink-0 items-center gap-2 rounded-lg px-2 py-1.5 text-left text-xs text-station-text transition hover:bg-white/10 disabled:opacity-40 ${item.divider ? 'mt-1 border-t border-white/10' : ''} ${active?.index === index ? 'bg-white/10' : ''}`}
						onMouseDown={(event) => event.preventDefault()}
						onMouseEnter={(event) => setActive(item.children ? { index, rect: event.currentTarget.getBoundingClientRect() } : null)}
						onClick={(event) => {
							if (item.children) {
								setActive({ index, rect: event.currentTarget.getBoundingClientRect() });
								return;
							}
							onClose();
							void Promise.resolve(item.onClick?.()).catch(() => undefined);
						}}
					>
						{item.icon && <Icon name={item.icon} className="size-3.5 shrink-0" />}
						<span className="flex-1">{item.label}</span>
						{item.children && <Icon name="chevron-right" className="size-3 shrink-0" />}
					</button>
				))}
			</ScrollContainer>
			{active && items[active.index].children && (
				<MenuPanel
					key={active.index}
					items={items[active.index].children!}
					point={{ x: active.rect.right, y: active.rect.top }}
					parentRect={active.rect}
					onClose={onClose}
				/>
			)}
		</>
	);
}

/** 菜单挂载到 body，二级菜单独立定位，避免裁剪；仅处理指针操作。 */
export function ContextMenu({ items, point, onClose }: { items: ContextMenuItem[]; point: Point; onClose: () => void }): React.JSX.Element {
	useLayoutEffect(() => {
		const close = () => onClose();
		const onScroll = (event: Event) => {
			if (event.target instanceof Element && event.target.closest('[role="menu"]')) return;
			onClose();
		};
		window.addEventListener('resize', close);
		window.addEventListener('scroll', onScroll, true);
		return () => {
			window.removeEventListener('resize', close);
			window.removeEventListener('scroll', onScroll, true);
		};
	}, [onClose]);
	return createPortal(
		<>
			<div
				className="fixed inset-0 z-[89]"
				onPointerDown={onClose}
				onContextMenu={(event) => {
					event.preventDefault();
					onClose();
				}}
			/>
			<MenuPanel items={items} point={point} onClose={onClose} />
		</>,
		document.body,
	);
}
